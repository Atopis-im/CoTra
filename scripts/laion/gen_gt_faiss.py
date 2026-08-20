#!/usr/bin/env python3
"""
为降维后的 LAION 数据集重新生成 Ground Truth (暴力 L2 搜索)。

降维后向量距离关系改变，必须用新维度数据重新计算 GT。

用法:
  python3 scripts/laion/gen_gt_faiss.py \
      --base  /path/to/base.100M.512d.fbin \
      --query /path/to/query.10k.512d.fbin \
      --k 100 \
      --out /path/to/gt.10k.512d.bin \
      [--gpu]            # 使用 GPU (需要 faiss-gpu)
      [--batch-size 256] # query 批次大小

输出文件:
  <out>  (格式: n_query x k, uint32, 紧跟8字节header: n,k)

依赖:
  pip install faiss-cpu          # CPU 版
  # 或
  pip install faiss-gpu          # GPU 版 (推荐，100M暴力搜索快很多)
  pip install numpy
"""

import os
import sys
import struct
import argparse
import numpy as np

try:
    import faiss
except ImportError:
    print("请安装 faiss:  pip install faiss-cpu  或  pip install faiss-gpu", file=sys.stderr)
    sys.exit(1)


def read_fbin(path):
    """读取整个 fbin 文件为 numpy 数组"""
    with open(path, "rb") as f:
        n = struct.unpack("<i", f.read(4))[0]
        d = struct.unpack("<i", f.read(4))[0]
        data = np.fromfile(f, dtype=np.float32, count=n * d).reshape(n, d)
    return data, n, d


def write_gt_bin(path, n_query, k, indices):
    """写入 GT 文件: header(n, k) + indices (uint32)"""
    with open(path, "wb") as f:
        f.write(struct.pack("<i", n_query))
        f.write(struct.pack("<i", k))
        indices.astype(np.uint32).tofile(f)


def main():
    parser = argparse.ArgumentParser(description="生成 GT (暴力 L2 搜索)")
    parser.add_argument("--base", required=True, help="base fbin (降维后)")
    parser.add_argument("--query", required=True, help="query fbin (降维后)")
    parser.add_argument("--k", type=int, default=100, help="GT 的 K 值 (默认100)")
    parser.add_argument("--out", required=True, help="输出 GT 文件路径")
    parser.add_argument("--gpu", action="store_true", help="使用 GPU 加速")
    parser.add_argument("--batch-size", type=int, default=256,
                        help="query 处理批次大小 (默认256)")
    args = parser.parse_args()

    print(f"读取 base: {args.base}")
    base, base_n, base_d = read_fbin(args.base)
    print(f"  base: {base_n} x {base_d}")

    print(f"读取 query: {args.query}")
    query, query_n, query_d = read_fbin(args.query)
    print(f"  query: {query_n} x {query_d}")

    if base_d != query_d:
        print(f"ERROR: 维度不匹配 base={base_d} query={query_d}", file=sys.stderr)
        sys.exit(1)

    # 确保连续内存 (faiss 要求)
    base = np.ascontiguousarray(base)
    query = np.ascontiguousarray(query)

    # 构建 faiss 索引 (flat = 暴力搜索)
    if args.gpu:
        print("使用 GPU...")
        res = faiss.StandardGpuResources()
        index = faiss.IndexFlatL2(base_d)
        index = faiss.index_cpu_to_gpu(res, 0, index)
    else:
        print("使用 CPU (100M数据会较慢，建议用 --gpu)...")
        index = faiss.IndexFlatL2(base_d)

    print(f"添加 {base_n} 条 base 向量到索引...")
    # 分批添加，避免一次性内存爆炸
    add_batch = 1_000_000
    for i in range(0, base_n, add_batch):
        end = min(i + add_batch, base_n)
        index.add(np.ascontiguousarray(base[i:end]))
        print(f"  已添加 {end}/{base_n}")

    print(f"\n搜索 {query_n} 条 query, K={args.k}...")

    # 分批搜索
    all_indices = np.zeros((query_n, args.k), dtype=np.uint32)
    for i in range(0, query_n, args.batch_size):
        end = min(i + args.batch_size, query_n)
        _, indices = index.search(np.ascontiguousarray(query[i:end]), args.k)
        all_indices[i:end] = indices
        if (i // args.batch_size) % 10 == 0:
            print(f"  已搜索 {end}/{query_n}")

    print(f"\n写入 GT: {args.out}")
    write_gt_bin(args.out, query_n, args.k, all_indices)
    print(f"完成! GT: {query_n} x {args.k} (uint32)")
    print("\n下一步: 用新数据集构建索引并运行搜索。")


if __name__ == "__main__":
    main()
