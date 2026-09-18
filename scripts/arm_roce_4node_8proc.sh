#!/usr/bin/env bash
# =============================================================================
# arm_roce_4node_8proc.sh
#
# 4 nodes x 2 processes = 8 CoTra ranks, sharing one RoCE NIC per node.
#
# This is the multi-process-per-node counterpart of arm_roce_8node.sh.
# Differences from the 8-node (1 process/node) script:
#   * CMake is configured with -DCOTRA_MACHINE_NUM=8  (== TOTAL_PROCS, the
#     number of CoTra processes/ranks), NOT the number of physical nodes (4).
#     All MACHINE_NUM-sized RDMA arrays are indexed by the per-process rank.
#   * The config file (write_config) emits 8 lines: ranks 0..3 are the first
#     process on nodes 0..3, ranks 4..7 are the second process on nodes 0..3.
#     Each node IP therefore appears twice; that is intentional and is only
#     valid because every process is launched with an explicit --rank.
#   * Each node launches TWO scala_index/scala_anns processes, one with
#     --rank <LOCAL_NODE_ID> and one with --rank <LOCAL_NODE_ID + 4>.
#     memcached metadata is reset once per node before either process starts.
#
# Run this script LOCALLY on every node (it does not ssh). Start node 0 first
# (its two processes), then nodes 1..3.
#
# --index-threads / --rdma-threads are PER-PROCESS. With NUMA binding on (the
# default) each process owns one socket, so pass that socket's core count (e.g.
# 48 on Kunpeng 4x24), NOT half the machine. With --no-numa-bind the two
# processes share the whole node, so pass roughly half the node each.
# =============================================================================

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd -P)

MODE=""
DATASET_DIR=""
OUTPUT_DIR=""
BUILD_DIR=""
BASE_FILE=""
QUERY_FILE=""
GT_FILE=""
DATA_TYPE="${DATA_TYPE:-float}"
DISTANCE="${DISTANCE:-l2}"
NODE0_RDMA_IP="${NODE0_RDMA_IP:-33.40.10.121}"
NODE1_RDMA_IP="${NODE1_RDMA_IP:-33.40.10.122}"
NODE2_RDMA_IP="${NODE2_RDMA_IP:-33.40.10.123}"
NODE3_RDMA_IP="${NODE3_RDMA_IP:-33.40.10.124}"
MAX_THREAD_NUM="${MAX_THREAD_NUM:-128}"
LEADER_IP="${LEADER_IP:-71.54.52.21}"
MEMCACHED_PORT="${MEMCACHED_PORT:-18516}"
RDMA_DEVICE="${RDMA_DEVICE:-mlx5_0}"
IB_PORT="${IB_PORT:-1}"
GID_INDEX="${GID_INDEX:-}"
THREADS="${THREADS:-8}"
INDEX_THREADS="${INDEX_THREADS:-$THREADS}"
RDMA_THREADS="${RDMA_THREADS:-$THREADS}"
BUILD_JOBS="${BUILD_JOBS:-24}"
ENABLE_LAT="${ENABLE_LAT:-0}"
BARRIER_TIMEOUT="${BARRIER_TIMEOUT:-1800}"
SEARCH_DRAM_GB="${SEARCH_DRAM_GB:-16}"
BUILD_DRAM_GB="${BUILD_DRAM_GB:-64}"
MAX_DEGREE="${MAX_DEGREE:-48}"
BUILD_L="${BUILD_L:-500}"
RESULT_K="${RESULT_K:-10}"
APP_MODE="${APP_MODE:-cotra}"
APP_TYPE="${APP_TYPE:-scala_v3}"
GRAPH_TYPE="${GRAPH_TYPE:-scalagraph_v3}"
DEPS_DIR="${DEPS_DIR:-}"
SEARCH_EF_LIST="${SEARCH_EF_LIST:-}"
WARMUP_RUNS="${WARMUP_RUNS:-1}"
WARMUP_EF="${WARMUP_EF:-0}"
NUM_RUNS="${NUM_RUNS:-10}"
# NUMA binding for the two per-node processes. The first process on each node
# (rank < NUM_NODES, e.g. 0..3) is pinned to NUMA_FIRST; the second process
# (rank >= NUM_NODES, e.g. 4..7) to NUMA_SECOND. On the reported Kunpeng 920
# (4 NUMA nodes x 24 cores) this gives each process a dedicated 48-core socket,
# matching the baseline mpirun --map-by ppr:2:node:pe=48 layout. Override with
# --numa-first/--numa-second, or disable with --no-numa-bind.
NUMA_BIND="${NUMA_BIND:-1}"
NUMA_FIRST="${NUMA_FIRST:-0,1}"
NUMA_SECOND="${NUMA_SECOND:-2,3}"
LOCAL_NODE_ID=""
CMAKE_BIN=""
CC_BIN=""
CXX_BIN=""
CONFIG_FILE=""
BASE_ROWS=0
BASE_DIM=0
QUERY_ROWS=0
QUERY_DIM=0
GT_ROWS=0
GT_K=0
MILLION=0
RESULT_QSIZE=""

NUM_NODES=4
PROCS_PER_NODE=2
TOTAL_PROCS=$((NUM_NODES * PROCS_PER_NODE))   # = 8 = COTRA_MACHINE_NUM

usage() {
  printf '%s\n' \
    "Usage:" \
    "  bash scripts/arm_roce_4node_8proc.sh <mode> [options]" \
    "" \
    "Modes:" \
    "  check    Detect local node, write the 8-rank config, check toolchain/RDMA/dataset." \
    "  build    Run check, configure CMake with -DCOTRA_MACHINE_NUM=8, and compile." \
    "  index    Distributed index build. Start node 0 (both its ranks) first, then 1..3." \
    "  search   Search the completed index. Start node 0 first, then 1..3." \
    "" \
    "Important options:" \
    "  --node0-rdma-ip IP .. --node3-rdma-ip IP   RoCE IPs of the 4 nodes." \
    "       Defaults: 33.40.10.121 .. 33.40.10.124" \
    "  --leader-ip IP       Memcached/leader address (on node 0). Default: 71.54.52.21" \
    "  --memcached-port N   Default: 18516" \
    "  --dataset-dir PATH / --base-file / --query-file / --gt-file PATH" \
    "  --output-dir PATH    Shared index directory (must be visible on all 4 nodes)." \
    "  --build-dir PATH     Per-host CMake build directory." \
    "  --deps-dir PATH      Bundled deps (boost/fmt/openblas/...) for nodes without sudo." \
    "  --index-threads N    PER-PROCESS DiskANN/OpenMP build threads." \
    "  --rdma-threads N     PER-PROCESS CoTra/RDMA worker threads." \
    "  --max-threads N      Compile-time thread array cap. Default: 128" \
    "  --max-degree R / --build-l L / --search-dram-gb / --build-dram-gb" \
    "  --res-knn K / --query-size N / --search-ef-list \"a,b,c\"" \
    "  --num-runs N / --warmup-runs N / --warmup-ef N" \
    "  --numa-first N,N     NUMA nodes for the first per-node process (default 0,1)." \
    "  --numa-second N,N    NUMA nodes for the second per-node process (default 2,3)." \
    "  --no-numa-bind       Disable NUMA pinning (both processes run unbound)." \
    "  --app-mode MODE      cotra|shard|kshard|single|global  (default cotra)" \
    "  --gid-index N / --barrier-timeout S / --build-jobs N / --lat" \
    "  --help"
}

die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
warn() { printf 'WARN: %s\n' "$*" >&2; }
note() { printf '\n=== %s ===\n' "$*"; }

is_positive_integer()    { [[ $1 =~ ^[1-9][0-9]*$ ]]; }
is_nonnegative_integer() { [[ $1 =~ ^[0-9]+$ ]]; }
is_ipv4() {
  local a b c d extra
  IFS=. read -r a b c d extra <<<"$1"
  [[ -n ${a:-} && -n ${d:-} && -z ${extra:-} ]] || return 1
  for v in "$a" "$b" "$c" "$d"; do
    is_nonnegative_integer "$v" || return 1
    ((v <= 255)) || return 1
  done
}

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    check|build|index|search) MODE=$1; shift ;;
    --node0-rdma-ip) NODE0_RDMA_IP=${2:?missing value}; shift 2 ;;
    --node1-rdma-ip) NODE1_RDMA_IP=${2:?missing value}; shift 2 ;;
    --node2-rdma-ip) NODE2_RDMA_IP=${2:?missing value}; shift 2 ;;
    --node3-rdma-ip) NODE3_RDMA_IP=${2:?missing value}; shift 2 ;;
    --leader-ip)      LEADER_IP=${2:?missing value}; shift 2 ;;
    --memcached-port) MEMCACHED_PORT=${2:?missing value}; shift 2 ;;
    --dataset-dir)    DATASET_DIR=${2:?missing value}; shift 2 ;;
    --base-file)      BASE_FILE=${2:?missing value}; shift 2 ;;
    --query-file)     QUERY_FILE=${2:?missing value}; shift 2 ;;
    --gt-file)        GT_FILE=${2:?missing value}; shift 2 ;;
    --output-dir)     OUTPUT_DIR=${2:?missing value}; shift 2 ;;
    --build-dir)      BUILD_DIR=${2:?missing value}; shift 2 ;;
    --deps-dir)       DEPS_DIR=${2:?missing value}; shift 2 ;;
    --data-type)      DATA_TYPE=${2:?missing value}; shift 2 ;;
    --dist-fn)        DISTANCE=${2:?missing value}; shift 2 ;;
    --rdma-device)    RDMA_DEVICE=${2:?missing value}; shift 2 ;;
    --ib-port)        IB_PORT=${2:?missing value}; shift 2 ;;
    --gid-index)      GID_INDEX=${2:?missing value}; shift 2 ;;
    --barrier-timeout) BARRIER_TIMEOUT=${2:?missing value}; shift 2 ;;
    --index-threads)  INDEX_THREADS=${2:?missing value}; shift 2 ;;
    --rdma-threads)   RDMA_THREADS=${2:?missing value}; shift 2 ;;
    --max-threads)    MAX_THREAD_NUM=${2:?missing value}; shift 2 ;;
    --build-jobs)     BUILD_JOBS=${2:?missing value}; shift 2 ;;
    --lat)            ENABLE_LAT=1; shift ;;
    --max-degree)     MAX_DEGREE=${2:?missing value}; shift 2 ;;
    --build-l)        BUILD_L=${2:?missing value}; shift 2 ;;
    --search-dram-gb) SEARCH_DRAM_GB=${2:?missing value}; shift 2 ;;
    --build-dram-gb)  BUILD_DRAM_GB=${2:?missing value}; shift 2 ;;
    --res-knn)        RESULT_K=${2:?missing value}; shift 2 ;;
    --query-size)     RESULT_QSIZE=${2:?missing value}; shift 2 ;;
    --search-ef-list) SEARCH_EF_LIST=${2:?missing value}; shift 2 ;;
    --num-runs|--num_runs)       NUM_RUNS=${2:?missing value}; shift 2 ;;
    --warmup-runs|--warmup_runs) WARMUP_RUNS=${2:?missing value}; shift 2 ;;
    --warmup-ef|--warmup_ef)     WARMUP_EF=${2:?missing value}; shift 2 ;;
    --numa-first)     NUMA_FIRST=${2:?missing value}; shift 2 ;;
    --numa-second)    NUMA_SECOND=${2:?missing value}; shift 2 ;;
    --no-numa-bind)   NUMA_BIND=0; shift ;;
    --app-mode)
      APP_MODE=${2:?missing value}
      case "$APP_MODE" in
        cotra)  APP_TYPE="scala_v3";      GRAPH_TYPE="scalagraph_v3" ;;
        shard)  APP_TYPE="b2";            GRAPH_TYPE="shared_nothing" ;;
        kshard) APP_TYPE="b2kmeansbatch"; GRAPH_TYPE="shared_nothing" ;;
        single) APP_TYPE="single";        GRAPH_TYPE="vamana" ;;
        global) APP_TYPE="single";        GRAPH_TYPE="vamana" ;;
        *) die "unknown --app-mode: $APP_MODE (cotra|shard|kshard|single|global)" ;;
      esac
      shift 2 ;;
    --app-type)   APP_TYPE=${2:?missing value}; shift 2 ;;
    --graph-type) GRAPH_TYPE=${2:?missing value}; shift 2 ;;
    --help|-h)    usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[[ -n $MODE ]] || { usage; exit 1; }

HOST_SHORT=$(hostname -s)

if [[ -z $BUILD_DIR ]]; then
  BUILD_DIR="${REPO_ROOT}/build-4node-8proc-${HOST_SHORT}"
fi
if [[ -z $OUTPUT_DIR ]]; then
  OUTPUT_DIR="${DATASET_DIR}/cotra_4node_8proc_index"
fi
CONFIG_FILE="${BUILD_DIR}/cotra_4node_8proc.conf"

ALL_NODE_IPS=("$NODE0_RDMA_IP" "$NODE1_RDMA_IP" "$NODE2_RDMA_IP" "$NODE3_RDMA_IP")

# If --deps-dir is given, prepend its bin/sbin to PATH before toolchain probing.
if [[ -n $DEPS_DIR ]]; then
  [[ -d ${DEPS_DIR}/bin ]]  && export PATH="${DEPS_DIR}/bin${PATH:+:${PATH}}"
  [[ -d ${DEPS_DIR}/sbin ]] && export PATH="${DEPS_DIR}/sbin${PATH:+:${PATH}}"
fi

# -----------------------------------------------------------------------------
# Validation
# -----------------------------------------------------------------------------
validate_arguments() {
  local i j
  for i in "${!ALL_NODE_IPS[@]}"; do
    [[ -n ${ALL_NODE_IPS[$i]} ]] || die "node $i RoCE IP is empty (use --node${i}-rdma-ip)"
    is_ipv4 "${ALL_NODE_IPS[$i]}" || die "invalid node $i RoCE IP: ${ALL_NODE_IPS[$i]}"
  done
  is_ipv4 "$LEADER_IP" || die "invalid leader IP: $LEADER_IP"
  # The 4 node IPs must be distinct (the config intentionally repeats each IP
  # for the two ranks, but the 4 physical nodes are different hosts).
  for i in "${!ALL_NODE_IPS[@]}"; do
    for ((j = i + 1; j < NUM_NODES; j++)); do
      [[ ${ALL_NODE_IPS[$i]} != "${ALL_NODE_IPS[$j]}" ]] ||
        die "node $i and node $j share the same RoCE IP ${ALL_NODE_IPS[$i]}"
    done
  done

  local kv
  for kv in \
    "memcached port:${MEMCACHED_PORT}" "barrier timeout:${BARRIER_TIMEOUT}" \
    "max degree:${MAX_DEGREE}" "build L:${BUILD_L}" \
    "search dram:${SEARCH_DRAM_GB}" "build dram:${BUILD_DRAM_GB}" \
    "result knn:${RESULT_K}" "index threads:${INDEX_THREADS}" \
    "rdma threads:${RDMA_THREADS}" "max threads:${MAX_THREAD_NUM}" \
    "build jobs:${BUILD_JOBS}" "num runs:${NUM_RUNS}" "warmup runs:${WARMUP_RUNS}"; do
    local name=${kv%%:*} value=${kv#*:}
    is_positive_integer "$value" || die "${name} must be a positive integer"
  done
  is_nonnegative_integer "$WARMUP_EF" || die "warmup ef must be non-negative"
  ((MEMCACHED_PORT <= 65535)) || die "memcached port is too large"
  ((INDEX_THREADS <= MAX_THREAD_NUM)) || die "index threads must not exceed MAX_THREAD_NUM=${MAX_THREAD_NUM}"
  ((RDMA_THREADS <= MAX_THREAD_NUM))  || die "rdma threads must not exceed MAX_THREAD_NUM=${MAX_THREAD_NUM}"
  if [[ -n $GID_INDEX ]]; then
    is_nonnegative_integer "$GID_INDEX" || die "GID index must be non-negative"
  fi
  if [[ -n $DEPS_DIR ]]; then
    [[ -d $DEPS_DIR ]] || die "--deps-dir does not exist: ${DEPS_DIR}"
    [[ -d ${DEPS_DIR}/include ]] || die "--deps-dir is missing ${DEPS_DIR}/include"
    mkdir -p "${DEPS_DIR}/lib64" 2>/dev/null || true
  fi
  if (( NUMA_BIND )); then
    [[ -n $NUMA_FIRST && -n $NUMA_SECOND ]] ||
      die "--numa-first and --numa-second must be non-empty when NUMA binding is on (or pass --no-numa-bind)"
  fi
}

has_local_ipv4() {
  ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fqx -- "$1"
}

detect_local_node() {
  command -v ip >/dev/null 2>&1 || die "the ip command is not installed"
  local match_cnt=0 i
  for i in "${!ALL_NODE_IPS[@]}"; do
    if has_local_ipv4 "${ALL_NODE_IPS[$i]}"; then
      LOCAL_NODE_ID=$i
      match_cnt=$((match_cnt + 1))
    fi
  done
  if ((match_cnt != 1)); then
    printf 'Configured node addresses:\n' >&2
    for i in "${!ALL_NODE_IPS[@]}"; do
      printf '  node %s: %s\n' "$i" "${ALL_NODE_IPS[$i]}" >&2
    done
    printf 'Local IPv4 addresses:\n' >&2
    ip -4 -o addr show >&2
    die "exactly one configured RoCE IP must exist on this host (matched ${match_cnt})"
  fi
}

# 8 config lines: rank r -> node (r % NUM_NODES). Ranks 0..3 = first process on
# nodes 0..3; ranks 4..7 = second process on nodes 0..3.
write_config() {
  mkdir -p "$BUILD_DIR"
  {
    printf '%s\n' "$LEADER_IP"
    printf '%s\n' "$MEMCACHED_PORT"
    local r node_idx
    for ((r = 0; r < TOTAL_PROCS; r++)); do
      node_idx=$((r % NUM_NODES))
      printf '%s=%s\n' "${ALL_NODE_IPS[$node_idx]}" "$r"
    done
  } >"$CONFIG_FILE"
}

# -----------------------------------------------------------------------------
# Toolchain / RDMA / dataset checks
# -----------------------------------------------------------------------------
find_toolchain() {
  note "TOOLCHAIN"
  CMAKE_BIN=${CMAKE:-$(command -v cmake || true)}
  CC_BIN=${CC:-$(command -v gcc || true)}
  CXX_BIN=${CXX:-$(command -v g++ || true)}
  [[ -n $CMAKE_BIN ]] || die "cmake not found (set CMAKE or add it to PATH)"
  [[ -n $CC_BIN ]]   || die "gcc not found"
  [[ -n $CXX_BIN ]]  || die "g++ not found"
  "$CMAKE_BIN" --version | head -1
  "$CXX_BIN" --version | head -1
}

check_rdma() {
  note "RDMA"
  # Match the probe used by arm_roce_2node/4node/8node/16node.sh: a sysfs
  # directory check. The previous ibv_devinfo -d <dev> -p <port> probe was
  # wrong - this rdma-core build of ibv_devinfo has no -p option (port is -i),
  # so it exited non-zero on a usage error even when the device was fine.
  local port_root="/sys/class/infiniband/${RDMA_DEVICE}/ports/${IB_PORT}"
  [[ -d $port_root ]] ||
    die "RDMA port not found: ${RDMA_DEVICE}/${IB_PORT} (pass --rdma-device / --ib-port)"
  printf 'Device/port: %s/%s\n' "$RDMA_DEVICE" "$IB_PORT"
  printf 'Local RoCE IP: %s (node %s)\n' "${ALL_NODE_IPS[$LOCAL_NODE_ID]}" "$LOCAL_NODE_ID"
}

validate_numa_nodes() {
  local list=$1 max=$2
  [[ -n $list ]] || die "empty NUMA node list"
  local IFS=,
  local n
  for n in $list; do
    [[ $n =~ ^[0-9]+$ ]] || die "invalid NUMA node '$n' in '$list'"
    (( n <= max )) ||
      die "NUMA node $n not online (max online node is $max); pass --numa-first/--numa-second with valid nodes, or --no-numa-bind"
  done
}

check_numa() {
  note "NUMA BINDING"
  if (( ! NUMA_BIND )); then
    printf 'NUMA binding disabled (--no-numa-bind); both per-node processes run unbound\n'
    return
  fi
  command -v numactl >/dev/null 2>&1 ||
    die "numactl not found; install numactl, or pass --no-numa-bind"
  local online maxnode nic_numa
  online=$(cat /sys/devices/system/node/online 2>/dev/null || echo "0")
  maxnode=${online##*-}
  [[ $maxnode =~ ^[0-9]+$ ]] || maxnode=0
  validate_numa_nodes "$NUMA_FIRST"  "$maxnode"
  validate_numa_nodes "$NUMA_SECOND" "$maxnode"
  printf 'Online NUMA nodes: %s\n' "$online"
  printf 'Rank %s (first proc)  -> NUMA %s\n' "$LOCAL_NODE_ID"               "$NUMA_FIRST"
  printf 'Rank %s (second proc) -> NUMA %s\n' "$((LOCAL_NODE_ID + NUM_NODES))" "$NUMA_SECOND"
  # RoCE NIC sits on one NUMA node; a process bound to the other socket crosses
  # the inter-socket link for every RDMA op. Unavoidable with one NIC shared by
  # two processes, but worth knowing for interpreting latency.
  nic_numa=$(cat "/sys/class/infiniband/${RDMA_DEVICE}/device/numa_node" 2>/dev/null || echo "?")
  printf 'RoCE NIC %s is on NUMA node %s\n' "$RDMA_DEVICE" "$nic_numa"
}

read_bin_header() {
  local file=$1 values rows columns
  values=$(od -An -N8 -tu4 "$file")
  read -r rows columns <<<"$values"
  [[ ${rows:-} =~ ^[0-9]+$ && ${columns:-} =~ ^[0-9]+$ ]] ||
    die "cannot read uint32 row/dimension header from ${file}"
  printf '%s %s\n' "$rows" "$columns"
}

validate_vector_file() {
  local label=$1 file=$2 rows=$3 columns=$4 width=$5
  local actual_size expected_size
  actual_size=$(stat -c '%s' "$file")
  expected_size=$((8 + rows * columns * width))
  ((actual_size == expected_size)) ||
    die "${label} size mismatch: got ${actual_size}, expected ${expected_size} bytes (assumes float32)"
}

check_dataset() {
  note "DATASET CHECK"
  [[ -d $DATASET_DIR ]] || die "dataset directory does not exist: ${DATASET_DIR}"
  command -v od >/dev/null 2>&1 || die "od is required to inspect bin headers"
  command -v stat >/dev/null 2>&1 || die "stat is required to inspect bin files"
  [[ -n $BASE_FILE ]]  || die "--base-file is required"
  [[ -n $QUERY_FILE ]] || die "--query-file is required"
  [[ -n $GT_FILE ]]    || die "--gt-file is required"
  [[ -f $BASE_FILE ]]  || die "base file not found: $BASE_FILE"
  [[ -f $QUERY_FILE ]] || die "query file not found: $QUERY_FILE"
  [[ -f $GT_FILE ]]    || die "gt file not found: $GT_FILE"

  read -r BASE_ROWS BASE_DIM  <<<"$(read_bin_header "$BASE_FILE")"
  read -r QUERY_ROWS QUERY_DIM <<<"$(read_bin_header "$QUERY_FILE")"
  read -r GT_ROWS GT_K        <<<"$(read_bin_header "$GT_FILE")"

  validate_vector_file base  "$BASE_FILE"  "$BASE_ROWS"  "$BASE_DIM"  4
  validate_vector_file query "$QUERY_FILE" "$QUERY_ROWS" "$QUERY_DIM" 4
  validate_vector_file gt    "$GT_FILE"    "$GT_ROWS"    "$GT_K"      4

  ((BASE_ROWS > 0))   || die "base row count is 0"
  ((QUERY_DIM == BASE_DIM)) || die "query dim ${QUERY_DIM} != base dim ${BASE_DIM}"
  ((GT_ROWS >= QUERY_ROWS)) || die "GT contains fewer queries than query.bin"
  ((GT_K >= RESULT_K)) || die "GT K=${GT_K} < requested K=${RESULT_K}"

  MILLION=$(( (BASE_ROWS + 999999) / 1000000 ))
  printf 'Base:  %s (%s x %s float32)\n' "$BASE_FILE" "$BASE_ROWS" "$BASE_DIM"
  printf 'Query: %s (%s x %s float32)\n' "$QUERY_FILE" "$QUERY_ROWS" "$QUERY_DIM"
  printf 'GT:    %s (%s x K=%s)\n' "$GT_FILE" "$GT_ROWS" "$GT_K"
}

check_shared_output() {
  note "OUTPUT PATH"
  mkdir -p "$OUTPUT_DIR"
  [[ -w $OUTPUT_DIR ]] || die "output directory is not writable: ${OUTPUT_DIR}"
  printf 'Output: %s\n' "$OUTPUT_DIR"
  df -T "$OUTPUT_DIR" | sed -n '1,2p'
  local marker="${OUTPUT_DIR}/.cotra-shared-node${LOCAL_NODE_ID}"
  printf 'host=%s node=%s time=%s\n' "$HOST_SHORT" "$LOCAL_NODE_ID" \
    "$(date +%s)" >"$marker"
}

run_preflight() {
  validate_arguments
  detect_local_node
  write_config
  note "HOST"
  printf 'Host:       %s\n' "$HOST_SHORT"
  printf 'Node ID:    %s\n' "$LOCAL_NODE_ID"
  printf 'Ranks here: %s and %s\n' "$LOCAL_NODE_ID" "$((LOCAL_NODE_ID + NUM_NODES))"
  printf 'Arch:       %s\n' "$(uname -m)"
  printf 'Config:     %s\n' "$CONFIG_FILE"
  printf 'Build dir:  %s\n' "$BUILD_DIR"
  printf 'Nodes:      %d   Procs/node: %d   Total ranks: %d (COTRA_MACHINE_NUM)\n' \
    "$NUM_NODES" "$PROCS_PER_NODE" "$TOTAL_PROCS"
  find_toolchain
  check_rdma
  check_numa
  check_dataset
  check_shared_output
  note "PREFLIGHT COMPLETE"
  printf 'Node %s is ready for mode %s.\n' "$LOCAL_NODE_ID" "$MODE"
}

# -----------------------------------------------------------------------------
# Build
# -----------------------------------------------------------------------------
configure_and_build() {
  run_preflight
  note "CMAKE CONFIGURE"
  if [[ -f ${BUILD_DIR}/CMakeCache.txt ]]; then
    local cached_machine_count
    cached_machine_count=$(sed -n 's/^COTRA_MACHINE_NUM:STRING=//p' "${BUILD_DIR}/CMakeCache.txt")
    if [[ -n $cached_machine_count && $cached_machine_count != $TOTAL_PROCS ]]; then
      die "existing build dir was configured for COTRA_MACHINE_NUM=${cached_machine_count}; this script needs ${TOTAL_PROCS}. Use a different --build-dir."
    fi
  fi

  local cmake_extra=()
  if [[ -n $DEPS_DIR ]]; then
    cmake_extra+=(
      "-DCMAKE_INCLUDE_PATH=${DEPS_DIR}/include;${DEPS_DIR}/include/openblas;${DEPS_DIR}/include/openblas-pthread;${DEPS_DIR}/include/aarch64-linux-gnu"
      "-DCMAKE_LIBRARY_PATH=${DEPS_DIR}/lib64"
      "-DCMAKE_PREFIX_PATH=${DEPS_DIR}"
    )
    if [[ -d ${DEPS_DIR}/include/boost ]]; then
      cmake_extra+=("-DBoost_ROOT=${DEPS_DIR}" "-DBOOST_ROOT=${DEPS_DIR}"
        "-DBOOST_INCLUDEDIR=${DEPS_DIR}/include" "-DBOOST_LIBRARYDIR=${DEPS_DIR}/lib64"
        "-DBoost_NO_SYSTEM_PATHS=ON" "-DBoost_INCLUDE_DIR=${DEPS_DIR}/include"
        "-DBoost_LIBRARY_DIR_RELEASE=${DEPS_DIR}/lib64")
    fi
    local deps_rpath="-Wl,-rpath,${DEPS_DIR}/lib64"
    cmake_extra+=("-DCMAKE_BUILD_RPATH=${DEPS_DIR}/lib64" "-DCMAKE_INSTALL_RPATH=${DEPS_DIR}/lib64"
      "-DCMAKE_SKIP_BUILD_RPATH=OFF" "-DCMAKE_BUILD_WITH_INSTALL_RPATH=ON"
      "-DCMAKE_EXE_LINKER_FLAGS=${deps_rpath} ${CMAKE_EXE_LINKER_FLAGS:-}"
      "-DCMAKE_SHARED_LINKER_FLAGS=${deps_rpath} ${CMAKE_SHARED_LINKER_FLAGS:-}")
    export LDFLAGS="${deps_rpath} ${LDFLAGS:-}"
  fi
  local lat_cmake=()
  (( ENABLE_LAT )) && lat_cmake=(-DCOTRA_LAT=ON)

  # KEY: MACHINE_NUM is the number of CoTra processes (8), not physical nodes (4).
  "$CMAKE_BIN" -S "$REPO_ROOT" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC_BIN" \
    -DCMAKE_CXX_COMPILER="$CXX_BIN" \
    -DCOTRA_MACHINE_NUM=$TOTAL_PROCS \
    -DCOTRA_MAX_THREAD_NUM=$MAX_THREAD_NUM \
    "${lat_cmake[@]}" "${cmake_extra[@]}"

  note "BUILD"
  "$CMAKE_BIN" --build "$BUILD_DIR" -j "$BUILD_JOBS"
  [[ -x ${BUILD_DIR}/tests/scala_index ]] || die "scala_index was not built"
  [[ -x ${BUILD_DIR}/tests/scala_anns ]]  || die "scala_anns was not built"
  printf 'Build completed on node %s (COTRA_MACHINE_NUM=%d).\n' "$LOCAL_NODE_ID" "$TOTAL_PROCS"
}

# -----------------------------------------------------------------------------
# Runtime preflight (index/search)
# -----------------------------------------------------------------------------
runtime_preflight() {
  run_preflight
  [[ -x ${BUILD_DIR}/tests/scala_index ]] || die "scala_index missing; run 'build' on this node first"
  [[ -x ${BUILD_DIR}/tests/scala_anns ]]  || die "scala_anns missing; run 'build' on this node first"
  local locked
  locked=$(ulimit -l)
  [[ $locked == unlimited ]] ||
    die "max locked memory must be unlimited for RDMA; found ${locked}"

  local _sys_paths=(/usr/lib64 /lib64 /usr/lib/aarch64-linux-gnu /lib/aarch64-linux-gnu
    /usr/lib/gcc/aarch64-linux-gnu/10 /usr/lib/gcc/aarch64-linux-gnu/10.3.0 /usr/local/lib64)
  local _ld=""
  [[ -n $DEPS_DIR && -d ${DEPS_DIR}/lib64 ]] && _ld="${DEPS_DIR}/lib64"
  for p in "${_sys_paths[@]}"; do
    [[ -d $p ]] || continue
    if [[ -n $_ld ]]; then _ld="${_ld}:${p}"; else _ld="$p"; fi
  done
  [[ -n ${LD_LIBRARY_PATH:-} ]] && _ld="${_ld}:${LD_LIBRARY_PATH}"
  [[ -n $_ld ]] && export LD_LIBRARY_PATH="$_ld"

  local _bin _missing
  for _bin in "${BUILD_DIR}/tests/scala_index" "${BUILD_DIR}/tests/scala_anns"; do
    _missing=$(LD_LIBRARY_PATH="$LD_LIBRARY_PATH" ldd -r "$_bin" 2>&1 \
               | awk '/not found/{print $1}' | sort -u | tr '\n' ' ')
    if [[ -n ${_missing// } ]]; then
      die "Runtime libraries missing for ${_bin} (node ${LOCAL_NODE_ID}): ${_missing}
  Copy the missing .so files into --deps-dir/lib64 and rsync --deps-dir to all nodes."
    fi
  done

  # OMP/BLAS threads are PER-PROCESS here (each of the 2 processes inherits this).
  local omp_threads=$RDMA_THREADS
  [[ $MODE == index ]] && omp_threads=$INDEX_THREADS
  export OMP_NUM_THREADS=$omp_threads
  export OMP_THREAD_LIMIT=$omp_threads
  export OMP_DYNAMIC=FALSE
  export OMP_PROC_BIND=FALSE
  unset GOMP_CPU_AFFINITY
  export OPENBLAS_NUM_THREADS=${OPENBLAS_NUM_THREADS:-$omp_threads}
}

reset_metadata() {
  # shellcheck source=scripts/restart_memcache.sh
  source "${SCRIPT_DIR}/restart_memcache.sh"
  clear_memcache "$CONFIG_FILE"
}

rdma_arguments() {
  RDMA_ARGS=(-d "$RDMA_DEVICE" --ib-port "$IB_PORT" --barrier-timeout "$BARRIER_TIMEOUT")
  [[ -n $GID_INDEX ]] && RDMA_ARGS+=(--gid-index "$GID_INDEX")
}

print_command() { printf 'Command:'; printf ' %q' "$@"; printf '\n'; }

# -----------------------------------------------------------------------------
# Index build: two processes per node
# -----------------------------------------------------------------------------
run_one_index() {
  local rank=$1 log=$2 numa_nodes=${3:-}
  local bind=()
  if [[ -n $numa_nodes ]]; then
    bind=(numactl --cpunodebind="$numa_nodes" --membind="$numa_nodes")
  fi
  "${bind[@]}" "${BUILD_DIR}/tests/scala_index" \
    --config_file "$CONFIG_FILE" \
    --rank "$rank" \
    --graph_type "$GRAPH_TYPE" \
    --data_type "$DATA_TYPE" --dist_fn "$DISTANCE" \
    --data_path "$BASE_FILE" \
    --index_path_prefix "${OUTPUT_DIR}/merged_index" \
    -R "$MAX_DEGREE" -L "$BUILD_L" -B "$SEARCH_DRAM_GB" -M "$BUILD_DRAM_GB" \
    -T "$INDEX_THREADS" -t "$RDMA_THREADS" -s "$MILLION" \
    --scala_v3 --scalagraph_v2 \
    "${RDMA_ARGS[@]}" 2>&1 | tee "$log"
}

run_index() {
  runtime_preflight
  reset_metadata           # once per node, before either process registers
  rdma_arguments
  local r0=$LOCAL_NODE_ID
  local r1=$((LOCAL_NODE_ID + NUM_NODES))
  local log0="${OUTPUT_DIR}/index-rank${r0}.log"
  local log1="${OUTPUT_DIR}/index-rank${r1}.log"
  local numa0="" numa1=""
  if (( NUMA_BIND )); then numa0="$NUMA_FIRST"; numa1="$NUMA_SECOND"; fi
  note "${NUM_NODES}-NODE ${TOTAL_PROCS}-PROC INDEX BUILD (node ${LOCAL_NODE_ID}: ranks ${r0},${r1})"
  printf 'Start node 0 (both ranks) first, then nodes 1..%d.\n' "$((NUM_NODES - 1))"
  if (( NUMA_BIND )); then
    printf 'NUMA: rank %s -> %s, rank %s -> %s\n' "$r0" "$numa0" "$r1" "$numa1"
  fi
  print_command "${BUILD_DIR}/tests/scala_index" --rank "$r0" ...
  run_one_index "$r0" "$log0" "$numa0" &
  local pid0=$!
  run_one_index "$r1" "$log1" "$numa1" &
  local pid1=$!
  local st=0 rc
  wait "$pid0" || st=$?
  wait "$pid1" || st=$?
  if (( st != 0 )); then
    printf 'Index build failed on node %s (status %s). See %s / %s\n' \
      "$LOCAL_NODE_ID" "$st" "$log0" "$log1" >&2
    return "$st"
  fi
  printf 'Index build completed on node %s (ranks %s,%s).\n' "$LOCAL_NODE_ID" "$r0" "$r1"
}

# -----------------------------------------------------------------------------
# Search: two processes per node
# -----------------------------------------------------------------------------
run_one_search() {
  local rank=$1 log=$2 numa_nodes=${3:-}
  local bind=()
  if [[ -n $numa_nodes ]]; then
    bind=(numactl --cpunodebind="$numa_nodes" --membind="$numa_nodes")
  fi
  # Build the optional --search_ef_list arg as an array so the comma/space
  # value stays a single argument (an inline ${var:+--opt "$var"} would be
  # word-split and corrupt the ef list).
  local ef_args=()
  if [[ -n $SEARCH_EF_LIST ]]; then
    ef_args+=(--search_ef_list "$SEARCH_EF_LIST")
  fi
  "${bind[@]}" "${BUILD_DIR}/tests/scala_anns" \
    --config_file "$CONFIG_FILE" \
    --rank "$rank" \
    --app_type "$APP_TYPE" \
    --graph_type "$GRAPH_TYPE" \
    --data_type "$DATA_TYPE" --dist_fn "$DISTANCE" \
    --data_path "$BASE_FILE" \
    --query_path "$QUERY_FILE" \
    --gt_path "$GT_FILE" \
    --query_size "${RESULT_QSIZE:-$QUERY_ROWS}" \
    --res_knn "$RESULT_K" \
    "${ef_args[@]}" \
    --index_path_prefix "${OUTPUT_DIR}/merged_index" \
    -R "$MAX_DEGREE" -L "$BUILD_L" -B "$SEARCH_DRAM_GB" -M "$BUILD_DRAM_GB" \
    -T "$INDEX_THREADS" -t "$RDMA_THREADS" -s "$MILLION" \
    --scala_v3 \
    --warmup_runs "${WARMUP_RUNS:-1}" --warmup_ef "${WARMUP_EF:-0}" \
    --num_runs "${NUM_RUNS:-10}" \
    "${RDMA_ARGS[@]}" 2>&1 | tee "$log"
}

run_search() {
  runtime_preflight
  local r0=$LOCAL_NODE_ID
  local r1=$((LOCAL_NODE_ID + NUM_NODES))
  local req0="${OUTPUT_DIR}/merged_index${r0}_final_scala.index"
  local req1="${OUTPUT_DIR}/merged_index${r1}_final_scala.index"
  [[ -f $req0 ]] || warn "index file not found: $req0 (expected after index mode on all ranks)"
  [[ -f $req1 ]] || warn "index file not found: $req1 (expected after index mode on all ranks)"
  reset_metadata           # once per node, before either process registers
  rdma_arguments
  local log0="${OUTPUT_DIR}/search-rank${r0}.log"
  local log1="${OUTPUT_DIR}/search-rank${r1}.log"
  local numa0="" numa1=""
  if (( NUMA_BIND )); then numa0="$NUMA_FIRST"; numa1="$NUMA_SECOND"; fi
  note "${NUM_NODES}-NODE ${TOTAL_PROCS}-PROC SEARCH (node ${LOCAL_NODE_ID}: ranks ${r0},${r1})"
  printf 'Start node 0 (both ranks) first, then nodes 1..%d.\n' "$((NUM_NODES - 1))"
  if (( NUMA_BIND )); then
    printf 'NUMA: rank %s -> %s, rank %s -> %s\n' "$r0" "$numa0" "$r1" "$numa1"
  fi
  print_command "${BUILD_DIR}/tests/scala_anns" --rank "$r0" ...
  run_one_search "$r0" "$log0" "$numa0" &
  local pid0=$!
  run_one_search "$r1" "$log1" "$numa1" &
  local pid1=$!
  local st=0
  wait "$pid0" || st=$?
  wait "$pid1" || st=$?
  if (( st != 0 )); then
    printf 'Search failed on node %s (status %s). See %s / %s\n' \
      "$LOCAL_NODE_ID" "$st" "$log0" "$log1" >&2
    return "$st"
  fi
  printf 'Search completed on node %s (ranks %s,%s).\n' "$LOCAL_NODE_ID" "$r0" "$r1"
}

case "$MODE" in
  check)  run_preflight ;;
  build)  configure_and_build ;;
  index)  run_index ;;
  search) run_search ;;
esac
