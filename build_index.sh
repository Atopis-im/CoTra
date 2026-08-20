#!/bin/bash

cd /home/team/alg_mathlib/c30061081/CoTra

source ~/m00613325/tools/env.sh
export PATH=/home/team/alg_mathlib/m00613325/tools/cmake-3.29.3-linux-aarch64/bin:$PATH
FMT_PREFIX="/home/team/alg_mathlib/local" 
export CMAKE_PREFIX_PATH="${FMT_PREFIX}${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}" 
export CPATH="${FMT_PREFIX}/include${CPATH:+:${CPATH}}" 
export LIBRARY_PATH="${FMT_PREFIX}/lib64:${FMT_PREFIX}/lib${LIBRARY_PATH:+:${LIBRARY_PATH}}" 
export LD_LIBRARY_PATH="${FMT_PREFIX}/lib64:${FMT_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"


export NODE1_RDMA_IP=33.40.10.122
export GID_INDEX=3

# DiskANN 索引构建使用 96 个物理核心，CoTra/RDMA 保持 8 个工作线程。
export INDEX_THREADS=96
export RDMA_THREADS=8
export OPENBLAS_NUM_THREADS=96

export MAX_DEGREE=64   # M
export BUILD_L=40     # efC


# SHARED_BUILD_DIR="/home/team/alg_mathlib/c30061081/CoTra/build"
# RUN_OUTPUT="/home/team/alg_mathlib/c30061081/CoTra/index_cyy"
SHARED_BUILD_DIR="/home/team/alg_mathlib/c30061081/CoTra/build-arm-8node-agent-23"
# RUN_OUTPUT="/home/team/alg_mathlib/c30061081/dataset/gist_1M_960/cotra_8node_index"
RUN_OUTPUT="/home/team/alg_mathlib/c30061081/dataset/laion100m/cotra_8node_index"


bash scripts/arm_roce_8node.sh index \
  --deps-dir /home/team/alg_mathlib/c30061081/shared_deps \
  --dataset-dir /home/team/alg_mathlib/c30061081/dataset/laion100m \
  --node0-rdma-ip 33.40.10.121 \
  --node1-rdma-ip 33.40.10.122 \
  --node2-rdma-ip 33.40.10.123 \
  --node3-rdma-ip 33.40.10.124 \
  --node4-rdma-ip 33.40.10.125 \
  --node5-rdma-ip 33.40.10.126 \
  --node6-rdma-ip 33.40.10.127 \
  --node7-rdma-ip 33.40.10.128 \
  --build-dir "$SHARED_BUILD_DIR" \
  --output-dir "$RUN_OUTPUT" 