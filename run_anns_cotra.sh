#!/bin/bash

cd /home/team/alg_mathlib/c30061081/CoTra

source ~/m00613325/tools/env.sh
export PATH=/home/team/alg_mathlib/m00613325/tools/cmake-3.29.3-linux-aarch64/bin:$PATH
FMT_PREFIX="/home/team/alg_mathlib/local" 
export CMAKE_PREFIX_PATH="${FMT_PREFIX}${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}" 
export CPATH="${FMT_PREFIX}/include${CPATH:+:${CPATH}}" 
export LIBRARY_PATH="${FMT_PREFIX}/lib64:${FMT_PREFIX}/lib${LIBRARY_PATH:+:${LIBRARY_PATH}}" 
export LD_LIBRARY_PATH="${FMT_PREFIX}/lib64:${FMT_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

# export NODE1_RDMA_IP=33.40.10.122
export GID_INDEX=3


# # 只看 recall/QPS
export COTRA_STAGE_TIMING=0
export COTRA_AVG_LAT=0

# # 只看 有 POST合计 但没有4个子项
# export COTRA_STAGE_TIMING=1

# # 只看 有 POST合计 有4个子项
# export COTRA_STAGE_TIMING=2


pkill -9 -f scala_anns
# taskset -c 0-11,48-59 
bash scripts/arm_roce_8node.sh search \
  --node0-rdma-ip 33.40.10.121 \
  --node1-rdma-ip 33.40.10.122 \
  --node2-rdma-ip 33.40.10.123 \
  --node3-rdma-ip 33.40.10.124 \
  --node4-rdma-ip 33.40.10.125 \
  --node5-rdma-ip 33.40.10.126 \
  --node6-rdma-ip 33.40.10.127 \
  --node7-rdma-ip 33.40.10.128 \
  --deps-dir       /home/team/alg_mathlib/c30061081/shared_deps \
  --build-dir      /home/team/alg_mathlib/c30061081/CoTra/build-arm-8node-agent \
  --dataset-dir    /home/team/alg_mathlib/c30061081/dataset/bigann100m_128 \
  --base-file      /home/team/alg_mathlib/c30061081/dataset/bigann100m_128/base.100M.fbin \
  --query-file     /home/team/alg_mathlib/c30061081/dataset/bigann100m_128/query.public.100M.fbin \
  --gt-file        /home/team/alg_mathlib/c30061081/dataset/bigann100m_128/groundtruth.public.100M.IB \
  --output-dir     /home/team/alg_mathlib/c30061081/dataset/bigann100m_128/cotra_8node_index_R48_L500 \
  --search-ef-list "70, 71, 72, 73, 74, 75, 80, 250, 260" \
  --app-mode       cotra \
  --res-knn        10 \
  --max-degree     48 \
  --build-l        500 \
  --index-threads  8 \
  --rdma-threads   48 \
  --build-dram-gb  120 \
  --search-dram-gb 100 \
  --num_runs       10 \
  --warmup_runs    5 \
  --warmup_ef      100

# 快速验证（单次，无预热，等同旧行为）
  # --num_runs       1 \
  # --warmup_runs    0 \
# 精确测量：20 次取中位数，ef=500 预热 2 次，指定 ef 列表
  # --num_runs       20 \
  # --warmup_runs    2 \
  # --warmup_ef      500 \
  # --search_ef_list "50,100,200" \
# 只调 num_runs，其他用默认
  # --num_runs       20 \
# -----------------------------------------------------------------
#   --rdma-threads   96 72 64 48 32 24 \

# laion100m_512
  # --dataset-dir    /home/team/alg_mathlib/c30061081/dataset/laion100m/laion_512d \
  # --base-file      /home/team/alg_mathlib/c30061081/dataset/laion100m/laion_512d/laion100m_base.512d.fbin \
  # --query-file     /home/team/alg_mathlib/c30061081/dataset/laion100m/laion_512d/laion100m_query.512d.fbin \
  # --gt-file        /home/team/alg_mathlib/c30061081/dataset/laion100m/laion_512d/gt.10k.512d.bin \
  # --output-dir     /home/team/alg_mathlib/c30061081/dataset/laion100m/laion_512d/cotra_8node_index_R48_L500 \
  # --search-ef-list "50, 60, 65, 70, 400, 500" \

# gist_1M_960
  # --dataset-dir    /home/team/alg_mathlib/c30061081/dataset/gist_1M_960 \
  # --base-file      /home/team/alg_mathlib/c30061081/dataset/gist_1M_960/base.bin \
  # --query-file     /home/team/alg_mathlib/c30061081/dataset/gist_1M_960/query.bin \
  # --gt-file        /home/team/alg_mathlib/c30061081/dataset/gist_1M_960/gt.bin \
  # --output-dir     /home/team/alg_mathlib/c30061081/dataset/gist_1M_960/cotra_8node_index_R48_L500 \
  # --search-ef-list "160, 170, 180, 410, 420, 430, 440, 450, 460, 470" \

# bge10m_1024
  # --dataset-dir    /home/team/alg_mathlib/c30061081/dataset/bge10m_1024 \
  # --base-file      /home/team/alg_mathlib/c30061081/dataset/bge10m_1024/base.bin \
  # --query-file     /home/team/alg_mathlib/c30061081/dataset/bge10m_1024/query.bin \
  # --gt-file        /home/team/alg_mathlib/c30061081/dataset/bge10m_1024/gt.bin \
  # --output-dir     /home/team/alg_mathlib/c30061081/dataset/bge10m_1024/cotra_8node_index_R48_L500 \
  # --search-ef-list "45, 46, 47, 48, 49, 50, 51, 52, 220, 230, 240, 245, 250" \

# bigann100m_128
  # --dataset-dir    /home/team/alg_mathlib/c30061081/dataset/bigann100m_128 \
  # --base-file      /home/team/alg_mathlib/c30061081/dataset/bigann100m_128/base.100M.fbin \
  # --query-file     /home/team/alg_mathlib/c30061081/dataset/bigann100m_128/query.public.100M.fbin \
  # --gt-file        /home/team/alg_mathlib/c30061081/dataset/bigann100m_128/groundtruth.public.100M.IB \
  # --output-dir     /home/team/alg_mathlib/c30061081/dataset/bigann100m_128/cotra_8node_index_R48_L500 \
  # --search-ef-list "70, 71, 72, 73, 74, 75, 80, 250, 260" \

# pkill -9 -f scala_anns
