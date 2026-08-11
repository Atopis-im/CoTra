#!/bin/bash

cd /home/team/alg_mathlib/c30061081/CoTra

export NODE1_RDMA_IP=33.40.10.122
export GID_INDEX=3

# DiskANN 索引构建使用 96 个物理核心，CoTra/RDMA 保持 8 个工作线程。
export INDEX_THREADS=96
export RDMA_THREADS=8
export OPENBLAS_NUM_THREADS=96

export MAX_DEGREE=64   # M
export BUILD_L=40     # efC

SHARED_BUILD_DIR="/home/team/alg_mathlib/c30061081/CoTra/build"
RUN_OUTPUT="/home/team/alg_mathlib/c30061081/CoTra/index_cyy"

bash scripts/arm_roce_2node.sh search \
  --build-dir "$SHARED_BUILD_DIR" \
  --output-dir "$RUN_OUTPUT"