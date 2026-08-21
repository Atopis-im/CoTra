#!/bin/bash
# CoTra 8节点索引构建脚本（论文参数：R=48, L=500, T=32, t=32, B=100, M=120）
# 注意：行末反斜杠后面不能有任何空格/制表符，否则续行失败。
# 注意：--build-dir 必须按节点区分，否则 8 节点同时编译到同一目录会冲突。
# 兼容性：用环境变量传参，旧版/新版 arm_roce_8node.sh 都能跑。

set -e

cd /home/team/alg_mathlib/c30061081/CoTra

source ~/m00613325/tools/env.sh
export PATH=/home/team/alg_mathlib/m00613325/tools/cmake-3.29.3-linux-aarch64/bin:$PATH
FMT_PREFIX="/home/team/alg_mathlib/local"
export CMAKE_PREFIX_PATH="${FMT_PREFIX}${CMAKE_PREFIX_PATH:+:${CMAKE_PREFIX_PATH}}"
export CPATH="${FMT_PREFIX}/include${CPATH:+:${CPATH}}"
export LIBRARY_PATH="${FMT_PREFIX}/lib64:${FMT_PREFIX}/lib${LIBRARY_PATH:+:${LIBRARY_PATH}}"
export LD_LIBRARY_PATH="${FMT_PREFIX}/lib64:${FMT_PREFIX}/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"

export GID_INDEX=3
# barrier 超时设为 2 小时，覆盖 1800 秒默认值
export BARRIER_TIMEOUT=7200

# 索引构建参数（论文配置）
export MAX_DEGREE=48        # -R，图最大出度
export BUILD_L=500          # -L，efConstruction
export INDEX_THREADS=32     # -T，构建期OpenMP/BLAS线程数
export RDMA_THREADS=32      # -t，构建期RDMA协程线程数（论文=32）
export BUILD_DRAM_GB=120    # -M，构建内存上限(GB)
export SEARCH_DRAM_GB=100   # -B，搜索内存上限(GB)

# 每个节点独立 build 目录，避免共享磁盘竞争
SHARED_BUILD_DIR="/home/team/alg_mathlib/c30061081/CoTra/build-arm-8node-$(hostname -s)"
RUN_OUTPUT="/home/team/alg_mathlib/c30061081/dataset/laion100m/cotra_8node_index_512d_R48_L500"

bash scripts/arm_roce_8node.sh index \
  --node0-rdma-ip  33.40.10.121 \
  --node1-rdma-ip  33.40.10.122 \
  --node2-rdma-ip  33.40.10.123 \
  --node3-rdma-ip  33.40.10.124 \
  --node4-rdma-ip  33.40.10.125 \
  --node5-rdma-ip  33.40.10.126 \
  --node6-rdma-ip  33.40.10.127 \
  --node7-rdma-ip  33.40.10.128 \
  --deps-dir       /home/team/alg_mathlib/c30061081/shared_deps \
  --dataset-dir    /home/team/alg_mathlib/c30061081/dataset/laion100m/laion_512d \
  --base-file      /home/team/alg_mathlib/c30061081/dataset/laion100m/laion_512d/laion100m_base.512d.fbin \
  --build-dir      "$SHARED_BUILD_DIR" \
  --output-dir     "$RUN_OUTPUT"
