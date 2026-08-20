#!/usr/bin/env python3
"""
为降维后的 LAION 数据集重新生成 Ground Truth (暴力 L2 搜索)。

支持大数据集 (如 100M × 512d, 200GB)，使用分片搜索 + 全局 top-K 合并，
峰值内存约 8-16GB (取决于 shard-size)。

降维后向量距离关系改变，必须用新维度数据重新计算 GT。

用法:
  python3 scripts/laion/gen_gt_faiss.py \
      --base  /path/to/base.100M.512d.fbin \
      --query /path/to/query.10k.512d.fbin \
      --k 100 \
      --out /path/to/gt.10k.512d.bin \
      [--shard-size 2000000]   # 每个 base 分片大小 (默认 2M, 约 4GB)
      [--query-batch 1000]     # query 批大小 (默认 1000)
      [--gpu]                  # 使用 GPU 加速 (需要 faiss-gpu)

输出文件:
  <out>  (格式: header(n_query, k) + indices (uint32, n_query×k))

依赖:
  pip install faiss-cpu    # CPU 版 (内存友好，100M稍慢)
  pip install faiss-gpu    # GPU 版 (大幅加速)
  pip install numpy
"""

import os
import sys
import struct
import time
import argparse
import numpy as np
import heapq

try:
    import faiss
except ImportError:
    print("请安装 faiss:  pip install faiss-cpu  或  pip install faiss-gpu", file=sys.stderr)
    sys.exit(1)


def read_fbin_header(path):
    """读取 fbin header: (n, d)"""
    with open(path, "rb") as f:
        n = struct.unpack("<i", f.read(4))[0]
        d = struct.unpack("<i", f.read(4))[0]
    return n, d


def read_fbin(path, offset_n=0, count_n=None, dtype=np.float32):
    """
    从 fbin 文件读取指定范围的数据。
    offset_n: 起始向量编号
    count_n:  读取的向量数，None 表示读到文件末尾
    返回: (data_np, actual_n, dim)
    """
    with open(path, "rb") as f:
        n = struct.unpack("<i", f.read(4))[0]
        d = struct.unpack("<i", f.read(4))[0]
        start = offset_n
        if count_n is None:
            end = n
        else:
            end = min(offset_n + count_n, n)
        actual = end - start
        if actual <= 0:
            return np.empty((0, d), dtype=dtype), 0, d
        # seek to vector start
        f.seek(8 + start * d * np.dtype(dtype).itemsize, 0)
        data = np.fromfile(f, dtype=dtype, count=actual * d)
        if data.size < actual * d:
            actual = data.size // d
            data = data[: actual * d]
        return data.reshape(actual, d), actual, d


def write_gt_bin(path, n_query, k, indices):
    """写入 GT 文件: header(n, k) + indices (uint32, n_query×k)"""
    with open(path, "wb") as f:
        f.write(struct.pack("<i", n_query))
        f.write(struct.pack("<i", k))
        indices.astype(np.uint32).tofile(f)


def make_gpu_index(dim):
    """创建 GPU IndexFlatL2"""
    res = faiss.StandardGpuResources()
    cfg = faiss.GpuIndexFlatConfig()
    cfg.device = 0
    return faiss.GpuIndexFlatL2(res, dim, cfg)


def make_cpu_index(dim):
    return faiss.IndexFlatL2(dim)


def main():
    parser = argparse.ArgumentParser(description="生成 GT (分片暴力 L2 搜索 + top-k 合并)")
    parser.add_argument("--base", required=True, help="base fbin (降维后)")
    parser.add_argument("--query", required=True, help="query fbin (降维后)")
    parser.add_argument("--k", type=int, default=100, help="GT 的 K 值 (默认100)")
    parser.add_argument("--out", required=True, help="输出 GT 文件路径")
    parser.add_argument("--gpu", action="store_true", help="使用 GPU 加速")
    parser.add_argument("--shard-size", type=int, default=2_000_000,
                        help="base 分片大小向量数 (默认2M，约 2M*512*4=4GB/片)")
    parser.add_argument("--query-batch", type=int, default=1000,
                        help="query 批大小 (默认1000)")
    args = parser.parse_args()

    base_n, base_d = read_fbin_header(args.base)
    query_n, query_d = read_fbin_header(args.query)
    print(f"Base:  {base_n} x {base_d}  ({args.base})")
    print(f"Query: {query_n} x {query_d} ({args.query})")
    print(f"K={args.k}, Shard size={args.shard_size:,}, Query batch={args.query_batch}")

    if base_d != query_d:
        print(f"ERROR: 维度不匹配 base={base_d} query={query_d}", file=sys.stderr)
        sys.exit(1)

    # ---- 读入全部 query (通常 10K 条，很小) ----
    print("\n加载 query 到内存...")
    query_all, _, _ = read_fbin(args.query, 0, query_n)
    query_all = np.ascontiguousarray(query_all)
    print(f"  query 加载完成: {query_n} x {query_d}")

    # ---- 为每个 query 初始化一个 top-K 最大堆 ----
    # 堆元素: (-dist, global_idx) 用负距离实现最大堆 (heapq 是最小堆)
    # 但我们需要保留距离用于比较，用: (dist, idx)，heapq 弹出最小的，我们要保最小距离？
    # 需求: 保全局最小的 K 个距离。用最大堆（保存 top-K 里最大的作为哨兵）
    # 实现: heaps[q] = [(-dist, idx), ...], 堆顶=当前top-K中距离最大(值最小)的元素
    #       新候选如果距离 < -堆顶 距离，则替换。
    K = args.k
    heaps = [[] for _ in range(query_n)]

    shard_size = args.shard_size
    num_shards = (base_n + shard_size - 1) // shard_size
    print(f"\nBase 分片数: {num_shards}")
    print(f"设备: {'GPU' if args.gpu else 'CPU'}")

    t_total_start = time.time()

    for shard_id in range(num_shards):
        shard_start = shard_id * shard_size
        shard_end = min(shard_start + shard_size, base_n)
        actual_shard = shard_end - shard_start

        # ---- 加载 base 分片 ----
        t0 = time.time()
        shard, _, _ = read_fbin(args.base, shard_start, actual_shard)
        shard = np.ascontiguousarray(shard)
        t_load = time.time() - t0
        mem_mb = shard.nbytes / (1024 * 1024)
        print(f"\n[Shard {shard_id+1}/{num_shards}] offset={shard_start:,} "
              f"size={actual_shard:,} ({mem_mb:.0f} MB) load={t_load:.1f}s")

        # ---- 搜索该分片 ----
        # 逐 query 批次搜，避免距离矩阵过大同时复用 Index
        shard_topk_idx = np.zeros((query_n, K), dtype=np.uint32)
        shard_topk_dis = np.full((query_n, K), np.inf, dtype=np.float32)

        t_search_start = time.time()
        # 创建索引 (一次用整个 shard)
        if args.gpu:
            index = make_gpu_index(base_d)
        else:
            index = make_cpu_index(base_d)
        index.add(shard)
        t_add = time.time() - t_search_start

        for qb in range(0, query_n, args.query_batch):
            qe = min(qb + args.query_batch, query_n)
            q_slice = np.ascontiguousarray(query_all[qb:qe])
            distances, local_indices = index.search(q_slice, K)
            # local_indices 是 shard 内部编号 (0..actual_shard-1)
            # 映射到全局: local_indices + shard_start
            global_indices = local_indices + shard_start
            shard_topk_idx[qb:qe] = global_indices
            shard_topk_dis[qb:qe] = distances
        t_search = time.time() - t_search_start

        print(f"  索引 add={t_add:.1f}s, 搜索={t_search-t_add:.1f}s, 共{ t_search:.1f}s")

        # 释放索引和 shard，降低内存峰值
        del index
        del shard

        # ---- 合并 top-K 到全局堆 ----
        t_merge_start = time.time()
        for q in range(query_n):
            h = heaps[q]
            for ki in range(K):
                d = float(shard_topk_dis[q, ki])
                if not np.isfinite(d):
                    continue
                idx = int(shard_topk_idx[q, ki])
                if len(h) < K:
                    heapq.heappush(h, (-d, idx))
                else:
                    # 最大堆: 堆顶是 top-K 中距离最大的 (值最小的负数)
                    if d < -h[0][0]:
                        heapq.heapreplace(h, (-d, idx))
        t_merge = time.time() - t_merge_start
        elapsed = time.time() - t_total_start
        eta = elapsed / (shard_id + 1) * (num_shards - shard_id - 1) if shard_id < num_shards - 1 else 0
        print(f"  合并={t_merge:.1f}s, 进度 {(shard_id+1)/num_shards*100:.0f}% "
              f"({shard_id+1}/{num_shards}), 总用时={elapsed:.0f}s, ETA≈{eta:.0f}s")

    # ---- 从堆提取最终结果 (按距离升序) ----
    print(f"\n生成最终 GT...")
    final_indices = np.zeros((query_n, K), dtype=np.uint32)
    for q in range(query_n):
        h = heaps[q]
        # 按距离升序排序: 从小负数(-最大距离)到大负数(-最小距离)
        h_sorted = sorted(h, key=lambda x: x[0], reverse=True)  # 反序: 最大负数(-最小距离)在前
        for ki in range(min(K, len(h_sorted))):
            final_indices[q, ki] = h_sorted[ki][1]

    print(f"写入 GT: {args.out}")
    write_gt_bin(args.out, query_n, K, final_indices)
    total = time.time() - t_total_start
    print(f"完成! GT: {query_n} x {K} (uint32), 总耗时 {total:.0f}s ({total/60:.1f}min)")
    print(f"输出文件: {args.out}")
    print(f"  大小: {os.path.getsize(args.out)/1024/1024:.2f} MB")
    print("\n下一步: 用新数据集构建索引并运行搜索。")


if __name__ == "__main__":
    main()
