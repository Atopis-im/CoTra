
# CoTra: Towards Efficient and Scalable Distributed Vector Search with RDMA

This project is an implementation of a high-performance distributed similarity vector retrieval system using **Remote Direct Memory Access (RDMA)**. The system is designed to achieve arge-scale vector searches by leveraging RDMA's high performance communication capabilities and efficient memory management.

---

## Key Features

- **High Throughput & Scalable Architecture**: RDMA-based direct memory access minimizes CPU overhead and network round trips, supports distributed deployment across multiple nodes for large-scale data.  
- **Efficient Memory Utilization**: Implements a custom memory management system to handle vector storage and retrieval efficiently.  
- **C++ Implementation**: The system is built in C++ for maximum performance and fine-grained control over RDMA operations.

---

## Requirements

- **Operating System**: Linux with a working InfiniBand or RoCE device.
- **Architecture**: x86-64 or AArch64. The AArch64 path does not require AVX,
  Intel MKL, or FAISS.
- **Build tools**: CMake 3.16+ and GCC 10.3+ (C++20 coroutines are required).
- **Libraries**: libibverbs, librdmacm, libnuma, libmemcached, Boost
  (serialization, iostreams, program_options, system, filesystem), fmt,
  OpenMP, OpenBLAS/CBLAS, LAPACK, LAPACKE, and libaio.

---

## Installation

1. **Install Dependencies**

We use **memcached** to manage server metadata and
**[DiskANN](https://github.com/microsoft/DiskANN)** as the default graph index.
On Debian/Ubuntu, install the development packages with:

```bash
sudo apt update
sudo apt install \
  build-essential cmake memcached netcat-openbsd \
  libaio-dev libboost-all-dev libfmt-dev libibverbs-dev liblapacke-dev \
  libmemcached-dev libnuma-dev libopenblas-dev librdmacm-dev
```

On Kylin/RHEL-like systems, ask the administrator to provide the equivalent
`-devel` RPMs. Package names normally include `libibverbs-devel`,
`librdmacm-devel`, `numactl-devel`, `libmemcached-devel`, `boost-devel`,
`fmt-devel`, `openblas-devel`, `lapack-devel`, `lapacke-devel`, and
`libaio-devel`. A site module, Software Collections, or Spack compiler is fine;
the compiler selected by CMake must be GCC 10.3 or newer. GCC 10 builds add
the required experimental `-fcoroutines` flag automatically; GCC 11 and newer
use their normal C++20 coroutine mode.

2. **Build the Project**

`COTRA_MACHINE_NUM` is a compile-time layout setting and must match the number
of participating nodes. All nodes must run binaries built with the same value.

```bash
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release \
  -DCOTRA_MACHINE_NUM=<node-count> \
  -DCOTRA_MAX_THREAD_NUM=128
cmake --build build -j 24
```

If the default compiler is too old, select the newer compiler explicitly on a
clean build directory:

```bash
cmake -S . -B build-arm -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=/path/to/gcc \
  -DCMAKE_CXX_COMPILER=/path/to/g++ \
  -DCOTRA_MACHINE_NUM=<node-count> \
  -DCOTRA_MAX_THREAD_NUM=128
cmake --build build-arm -j 24
```

For the reported Kunpeng 920 server, GCC 7.3 is not sufficient and CMake is not
currently installed. Upgrade those two tools before building; the installed
libibverbs/librdmacm runtime libraries alone are also insufficient without
their development headers.

## Download Datasets
SIFT, DEEP, and Text2Image dataset (From Neurips21 BIGANN Contest): 
https://big-ann-benchmarks.com/neurips21.html

LAION dataset:
https://the-eye.eu/public/AI/cah/laion400m-met-release/laion400m-embeddings/images/

All dataset files (raw vector, ground truth, and query file follows the same format in Neurips21 BIGANN Contest).

# Usage

## Manage Server Connection
Edit <your_config>.conf file in ./scripts

The first and second lines are the leader machine's ip and port, please select one machine of cluster as the leader.
We use **machine ID** to identify each machine, which should be user defined, and the leader machine's ID must be 0.
Then write the IPs and IDs of every machine in cluster on the following lines.
e.g.,
```bash
<leadr_machine_ip>
<leadr_machine_port>
<machine0_IP>=0
<machine1_IP>=1
<machine2_IP>=2
...
```

### AArch64 + RoCE configuration

The reported Kunpeng server uses `mlx5_0` port 1 with Ethernet link layer, so
it is RoCE rather than native InfiniBand. CoTra now exchanges GIDs and creates
global route headers for RoCE. It auto-selects a non-empty GID, preferring a
RoCE v2 IPv4 GID that matches the node address in the config file. Override the
choice with `--gid-index <index>` if needed.

Use the management address for the first line only when that is where
memcached listens. Use one consistent RoCE subnet for the machine entries. For
example, the reported first node can start as:

```text
71.54.52.21
18516
33.40.10.121=0
<node-1-RoCE-IP>=1
...
```

Do not mix `33.40.*` and `33.41.*` machine entries unless routing and the GID
selection are deliberately configured for that topology. To inspect the GID
table on each node:

```bash
for f in /sys/class/infiniband/mlx5_0/ports/1/gids/*; do
  i=${f##*/}
  printf '%s gid=%s type=%s netdev=%s\n' "$i" "$(cat "$f")" \
    "$(cat "/sys/class/infiniband/mlx5_0/ports/1/gid_attrs/types/$i")" \
    "$(cat "/sys/class/infiniband/mlx5_0/ports/1/gid_attrs/ndevs/$i")"
done
```

Pass the device settings through any CoTra executable or dataset script:

```bash
./build/tests/scala_anns ... -d mlx5_0 --ib-port 1
# If automatic selection is not correct:
./build/tests/scala_anns ... -d mlx5_0 --ib-port 1 --gid-index <index>
```

Metadata exchange and build barriers now time out instead of waiting forever.
Build barriers also carry a monotonically increasing round number and report
the missing machine IDs. The default timeout is 1800 seconds; change it with
`--barrier-timeout <seconds>` for unusually imbalanced index builds.

The included memcached helper supports a non-root CoTra user and checks all
local IPv4 interfaces when deciding whether the current host is the leader.

For a first correctness run on the 96-core Kunpeng host, start with 8 or 16
worker threads. This keeps the initial QP, completion-queue, and registered
memory footprint modest; scale up only after the multi-node run is stable.

The index output directory must be visible at the same path on all nodes (for
example, a shared NFS or parallel filesystem), because the coordinator reads
the shard files written by the other nodes during index merging.

### Two-node Kunpeng GIST 1M smoke run

`scripts/arm_roce_2node.sh` checks the compiler and development headers,
prints the RoCE GID table, validates the GIST bin headers and sizes, generates
the two-node configuration, builds CoTra, and runs indexing or search. It uses
the reported node 0 defaults `71.54.52.21` (memcached) and `33.40.10.121`
(RoCE). Supply node 1's RoCE address on both hosts:

See the complete Chinese runbook, including the exact server paths, shared
build workflow, thread settings, launch order, validation, and troubleshooting:
[Kunpeng ARM/RoCE two-node runbook](docs/ARM_ROCE_2NODE_RUNBOOK.md).

```bash
export NODE1_RDMA_IP=<node-1-33.40.x.x-address>

# Run on both nodes. Rerun check after both have written the shared-path marker.
bash scripts/arm_roce_2node.sh check

# If the source and build directory are shared, build once on node 0. Otherwise
# use a separate build directory on each node.
bash scripts/arm_roce_2node.sh build --build-dir <shared-or-local-build-dir>

# Start on node 0 first, then node 1; wait for both commands to exit.
bash scripts/arm_roce_2node.sh index

# Only after indexing succeeded on both: start search on node 0, then node 1.
bash scripts/arm_roce_2node.sh search
```

The default dataset directory is
`/home/team/alg_mathlib/c30061081/gist_1M_960`. Exact `base.bin`,
`query.bin`, and `gt.bin` names are preferred; otherwise the script selects a
single matching file for each role. Use `--base-file`, `--query-file`, or
`--gt-file` when a role has multiple matches. The default shared output is the
`cotra_2node_index` subdirectory of the dataset directory, and the first run
uses eight worker threads. Run `bash scripts/arm_roce_2node.sh --help` for all
overrides, including a fixed GID index.

User can edit the scripts in ./scripts/dataset/ to adjust system configuration.
We provide different implementations discribed in paper, including **single_machine**, **global_index**, 
**shard_index(Random)**, **shard_index(Kmeans)**, and **CoTra**.

## Build Index Scripts & Options
An index script format example:
```bash
# This for restart memcache server
source ../scripts/restart_memcache.sh 
# Your server metadata file.
CONF_FILE="../scripts/<your_config>.conf"
# Clear memcache based on your config file.
clear_memcache "$CONF_FILE"

dataset_path=<Path_to_your_data_file_dir>
million=10 # Size of dataset in millions.
base_file=${dataset_path}/<Path_to_base_file_dir> # Path to the base vector data.
num_threads=<Thread_num>
index_save_path=<Path_to_index_save_path>

R=48 # Define the max degree of graph index, default is 48.
L=500 # build queue size, equivalent to efConstruction
index_save_dir=${index_save_path}/scalagraph/test_${million}M_16P

# graph_type [index option]: vamana, shared_nothing, Kshared_nothing, scalagraph_v3
# data_type [dataset type option]: uint8, int8, float
# dist_fn [distance function option]: l2, mips, cosine
for m in 1
do
    mkdir -p ${index_save_dir}
    ./tests/scala_index \
    --config_file ${CONF_FILE} \
    --graph_type shared_nothing \
    --data_type float \
    --dist_fn l2 \
    --data_path ${base_file} \
    --index_path_prefix ${index_save_dir}/merged_index \
    -R ${R} -L ${L} -B 100 -M 120 -T ${num_threads} \
    --scala_v3 -s ${million} -t ${num_threads}
done
```


## Vector Search Scripts & Options
An anns scripts format example:
```bash
# This for restart memcache server
source ../scripts/restart_memcache.sh 
# Your server metadata file.
CONF_FILE="../scripts/<your_config>.conf"
# Clear memcache based on your config file.
clear_memcache "$CONF_FILE"

dataset_path=<Path_to_your_data_file_dir>
million=10 # Size of dataset in millions.
base_file=${dataset_path}/<Path_to_base_file_dir> # Path to the base vector data.
gt_file=${dataset_path}/<Path_to_gt_file_dir>
query_path=${dataset_path}/<Path_to_query_file_dir>
num_threads=<Thread_num>
index_save_path=<Path_to_index_save_path>

R=48 # degree limit.
index_save_dir=${index_save_path}/<Path_to_index_save_file_dir>

# Note: app_type option should be aligned with graph_type respectively.
# app_type [implementation option]: single, b2, scala_v3 
# graph_type [index option]: vamana, shared_nothing, Kshared_nothing, scalagraph_v3
# data_type [dataset type option]: uint8, int8, float
# dist_fn [distance function option]: l2, mips, cosine
for m in 1
do
    mkdir -p ${index_save_dir}
    ./tests/scala_anns \
    --config_file ${CONF_FILE} \
    --app_type b2 \
    --graph_type shared_nothing \
    --data_type float \
    --dist_fn l2 \
    --data_path ${base_file} \
    --query_path ${query_path} \
    --gt_path ${gt_file} \
    --index_path_prefix ${index_save_dir}/merged_index \
    -R ${R} -L 500 -B 100 -M 120 -T ${num_threads} \
    --scala_v3 --scalagraph_v2 -s ${million} -t ${num_threads}
done

```

## Build Index & Run ANNS
```bash
# All scripts can execute simultaneously, so we suggest to use terminal tools like tmux.
# For each server, run: 
./scripts/<your_scripts>.sh
```

Huge pages are optional. CoTra uses 2 MiB allocation blocks and falls back to
normal pages automatically. Do not copy a fixed huge-page count from another
machine: the reported ARM server has a 512 MiB default huge-page size, so the
old `echo 8000` example would request about 4 TiB and is unsafe. Leave the
current count at zero for the first correctness run.

Inspect the host before doing any later performance tuning:

```bash
grep -i huge /proc/meminfo
```

# License
This project is licensed under the MIT License. See the LICENSE file for more details.
