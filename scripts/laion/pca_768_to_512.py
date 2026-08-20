#!/usr/bin/env python3
"""
PCA 降维: 将 LAION 768维向量降至 512维，对齐论文实验条件。

用法:
  python3 scripts/laion/pca_768_to_512.py \
      --base  /path/to/base.100M.fbin \
      --query /path/to/query.10k.fbin \
      --out-dir /path/to/laion_512d \
      [--batch-size 100000]

输出文件:
  <out-dir>/base.100M.512d.fbin
  <out-dir>/query.10k.512d.fbin
  <out-dir>/pca_model_768to512.pkl   (PCA 模型，便于复现/调试)

依赖:
  pip install numpy scikit-learn
"""

import os
import sys
import struct
import argparse
import numpy as np
from sklearn.decomposition import IncrementalPCA
import pickle


def read_fbin_header(path):
    """读取 fbin 文件头: 返回 (n, dim)"""
    with open(path, "rb") as f:
        n = struct.unpack("<i", f.read(4))[0]
        d = struct.unpack("<i", f.read(4))[0]
    return n, d


def fbin_iter(path, batch_size, dtype=np.float32):
    """
    分批迭代读取 fbin 文件，避免一次性载入全部数据到内存。
    yield (batch_array, offset)
    """
    n, d = read_fbin_header(path)
    header_bytes = 8
    with open(path, "rb") as f:
        f.seek(header_bytes)
        offset = 0
        while offset < n:
            cur = min(batch_size, n - offset)
            data = np.fromfile(f, dtype=dtype, count=cur * d)
            if data.size < cur * d:
                break  # 文件可能不完整
            yield data.reshape(cur, d), offset
            offset += cur


def write_fbin(path, n, dim, data):
    """写入 fbin 文件 (一次性写入，适合 query 等小文件)"""
    with open(path, "wb") as f:
        f.write(struct.pack("<i", n))
        f.write(struct.pack("<i", dim))
        data.astype(np.float32).tofile(f)


def write_fbin_stream(path, n, dim, data_iter):
    """
    流式写入 fbin 文件，适合 base 这种大文件。
    data_iter 每次 yield 一个 (batch, batch_offset)。
    """
    with open(path, "wb") as f:
        f.write(struct.pack("<i", n))
        f.write(struct.pack("<i", dim))
        for batch, _ in data_iter:
            batch.astype(np.float32).tofile(f)


def main():
    parser = argparse.ArgumentParser(description="PCA 768->512 for LAION dataset")
    parser.add_argument("--base", required=True, help="原始 base fbin (768d)")
    parser.add_argument("--query", required=True, help="原始 query fbin (768d)")
    parser.add_argument("--out-dir", required=True, help="输出目录")
    parser.add_argument("--target-dim", type=int, default=512, help="目标维度 (默认512)")
    parser.add_argument("--batch-size", type=int, default=100000,
                        help="IncrementalPCA 批次大小 (默认100000)")
    parser.add_argument("--n-samples", type=int, default=0,
                        help="PCA 训练采样数，0=使用全部 (默认0，即全部)")
    args = parser.parse_args()

    os.makedirs(args.out_dir, exist_ok=True)

    base_n, base_d = read_fbin_header(args.base)
    query_n, query_d = read_fbin_header(args.query)
    print(f"Base:  {base_n} x {base_d}")
    print(f"Query: {query_n} x {query_d}")

    if base_d != args.target_dim and base_d == query_d:
        src_dim = base_d
    else:
        src_dim = base_d
    if src_dim <= args.target_dim:
        print(f"源维度 {src_dim} <= 目标维度 {args.target_dim}，无需降维，退出。")
        sys.exit(0)

    print(f"降维: {src_dim} -> {args.target_dim}")

    # ================================================================
    # 第1步: 用 base 数据训练 IncrementalPCA
    # ================================================================
    print("\n=== Step 1: 训练 IncrementalPCA ===")
    pca = IncrementalPCA(n_components=args.target_dim, batch_size=args.batch_size)

    # 采样控制
    train_max = args.n_samples if args.n_samples > 0 else base_n

    sample_count = 0
    for batch, offset in fbin_iter(args.base, args.batch_size):
        if sample_count >= train_max:
            break
        # 截断到训练采样上限
        remaining = train_max - sample_count
        if len(batch) > remaining:
            batch = batch[:remaining]

        pca.partial_fit(batch)
        sample_count += len(batch)
        if sample_count % (args.batch_size * 10) == 0 or sample_count >= train_max:
            evr = pca.explained_variance_ratio_.sum()
            print(f"  已训练 {sample_count}/{train_max} 样本, "
                  f"累计方差保留率={evr:.4f}")

    evr_total = pca.explained_variance_ratio_.sum()
    print(f"PCA 训练完成，方差保留率={evr_total:.4f}")

    # 保存模型
    model_path = os.path.join(args.out_dir, f"pca_model_{src_dim}to{args.target_dim}.pkl")
    with open(model_path, "wb") as f:
        pickle.dump(pca, f)
    print(f"PCA 模型已保存: {model_path}")

    # ================================================================
    # 第2步: 转换 base 并流式写入
    # ================================================================
    print("\n=== Step 2: 转换 base (流式) ===")
    base_out = os.path.join(args.out_dir,
                            os.path.basename(args.base).replace(".fbin", f".{args.target_dim}d.fbin"))

    def transform_base_iter():
        written = 0
        for batch, offset in fbin_iter(args.base, args.batch_size):
            transformed = pca.transform(batch)
            written += len(transformed)
            if written % (args.batch_size * 10) == 0:
                print(f"  base 已转换 {written}/{base_n}")
            yield transformed, offset
        print(f"  base 转换完成: {written}/{base_n}")

    write_fbin_stream(base_out, base_n, args.target_dim, transform_base_iter())
    print(f"base 已保存: {base_out}")

    # ================================================================
    # 第3步: 转换 query (小文件，直接载入)
    # ================================================================
    print("\n=== Step 3: 转换 query ===")
    query_out = os.path.join(args.out_dir,
                             os.path.basename(args.query).replace(".fbin", f".{args.target_dim}d.fbin"))

    # query 较小，直接全部读取
    with open(args.query, "rb") as f:
        f.read(8)  # skip header
        q_data = np.fromfile(f, dtype=np.float32, count=query_n * query_d).reshape(query_n, query_d)

    q_transformed = pca.transform(q_data)
    write_fbin(query_out, query_n, args.target_dim, q_transformed)
    print(f"query 已保存: {query_out}")

    print("\n=== 完成 ===")
    print(f"base:  {base_out} ({base_n} x {args.target_dim})")
    print(f"query: {query_out} ({query_n} x {args.target_dim})")
    print(f"model: {model_path}")
    print(f"方差保留率: {evr_total:.4f}")
    print("\n下一步: 用 base_512d 和 query_512d 重新生成 Ground Truth。")


if __name__ == "__main__":
    main()
