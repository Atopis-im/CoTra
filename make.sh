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

# 4节点8进程 = 4物理节点 x 2进程/节点 = 8 rank，COTRA_MACHINE_NUM=8（由脚本自动传）。
# 注意 --node0..3-rdma-ip 只能传 4 个节点；每个节点会自动起 rank<id> 和 rank<id+4> 两个进程。
#
# --index-threads / --rdma-threads / --*-dram-gb 都是“每进程”的值；2进程每节点时大约取
# 单进程时的一半。build 模式只做 cmake 配置+编译，这些运行期参数在此仅参与预检校验、
# 不会被真正使用，但写上后把 mode 换成 index/search 即可直接复用本块参数。

# 临时启用LAT（编译时打开，输出avg_lat）：在下面命令里加 --lat
bash scripts/arm_roce_4node_8proc.sh build \
  --deps-dir       /home/team/alg_mathlib/c30061081/shared_deps \
  --node0-rdma-ip  33.40.10.121 \
  --node1-rdma-ip  33.40.10.122 \
  --node2-rdma-ip  33.40.10.123 \
  --node3-rdma-ip  33.40.10.124 \
  --build-dir      /home/team/alg_mathlib/c30061081/CoTra/build-arm-4node-8proc \
  --dataset-dir    /home/team/alg_mathlib/c30061081/dataset/laion100m/laion_512d \
  --base-file      /home/team/alg_mathlib/c30061081/dataset/laion100m/laion_512d/laion100m_base.512d.fbin \
  --query-file     /home/team/alg_mathlib/c30061081/dataset/laion100m/laion_512d/laion100m_query.512d.fbin \
  --gt-file        /home/team/alg_mathlib/c30061081/dataset/laion100m/laion_512d/gt.10k.512d.bin \
  --output-dir     /home/team/alg_mathlib/c30061081/dataset/laion100m/laion_512d/cotra_4node8proc_index_R48_L500 \
  --max-degree     48 \
  --build-l        500 \
  --res-knn        10 \
  --index-threads  8 \
  --rdma-threads   24 \
  --build-dram-gb  60 \
  --search-dram-gb 50

# 让 4节点8进程真正跑通，还需要先打 --rank 补丁（同节点两进程靠 --rank 区分 machine_id，
# 否则按 IP 查 id 会撞车），再重新 build：
#   python3 scripts/apply_8p4n_cxx_edits.py
# 补丁向后兼容：无 --rank 时回退原 IP 查找，不影响 8node 脚本。
#
# 若 --build-dir 是共享文件系统，只在 node0 build 一次即可；否则每个节点各自 build
# （可省去 --build-dir，脚本会默认用 build-4node-8proc-<hostname>）。

# -----------------------------------------------------------------
# 备选数据集（build 预检只校验文件存在和头部，不读数据；若本机没有 laion100m 的
# 200GB base，可换成小数据集 gist_1M_960 只为过预检完成编译）：
#   --dataset-dir    /home/team/alg_mathlib/c30061081/dataset/gist_1M_960 \
#   --base-file      /home/team/alg_mathlib/c30061081/dataset/gist_1M_960/base.bin \
#   --query-file     /home/team/alg_mathlib/c30061081/dataset/gist_1M_960/query.bin \
#   --gt-file        /home/team/alg_mathlib/c30061081/dataset/gist_1M_960/gt.bin \
#   --output-dir     /home/team/alg_mathlib/c30061081/dataset/gist_1M_960/cotra_4node8proc_index_R48_L500 \
