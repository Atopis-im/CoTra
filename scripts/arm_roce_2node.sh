#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
REPO_ROOT=$(cd "${SCRIPT_DIR}/.." && pwd -P)

MODE="check"
DATASET_DIR="/home/team/alg_mathlib/c30061081/gist_1M_960"
OUTPUT_DIR=""
BUILD_DIR=""
BASE_FILE=""
QUERY_FILE=""
GT_FILE=""
DATA_TYPE="float"
DISTANCE="l2"
NODE0_RDMA_IP="${NODE0_RDMA_IP:-33.40.10.121}"
NODE1_RDMA_IP="${NODE1_RDMA_IP:-}"
LEADER_IP="${LEADER_IP:-71.54.52.21}"
MEMCACHED_PORT="${MEMCACHED_PORT:-18516}"
RDMA_DEVICE="${RDMA_DEVICE:-mlx5_0}"
IB_PORT="${IB_PORT:-1}"
GID_INDEX="${GID_INDEX:-}"
THREADS="${THREADS:-8}"
INDEX_THREADS="${INDEX_THREADS:-$THREADS}"
RDMA_THREADS="${RDMA_THREADS:-$THREADS}"
BUILD_JOBS="${BUILD_JOBS:-24}"
BARRIER_TIMEOUT="${BARRIER_TIMEOUT:-1800}"
SEARCH_DRAM_GB="${SEARCH_DRAM_GB:-16}"
BUILD_DRAM_GB="${BUILD_DRAM_GB:-64}"
MAX_DEGREE="${MAX_DEGREE:-48}"
BUILD_L="${BUILD_L:-500}"
RESULT_K="${RESULT_K:-10}"
LOCAL_NODE_ID=""
CMAKE_BIN=""
CC_BIN=""
CXX_BIN=""
CXX_COMPAT_FLAGS=()
CONFIG_FILE=""
BASE_ROWS=0
BASE_DIM=0
QUERY_ROWS=0
QUERY_DIM=0
GT_ROWS=0
GT_K=0
MILLION=0

usage() {
  printf '%s\n' \
    "Usage:" \
    "  NODE1_RDMA_IP=<node-1-roce-ip> bash scripts/arm_roce_2node.sh <mode> [options]" \
    "" \
    "Modes:" \
    "  check    Check toolchain, headers, RDMA, routes, dataset, and shared path." \
    "  build    Run check, configure CMake for two nodes, and compile." \
    "  index    Run the distributed GIST index build. Start node 0, then node 1." \
    "  search   Search the completed index. Start node 0, then node 1 after both" \
    "           index commands have exited successfully." \
    "" \
    "Important options:" \
    "  --node0-rdma-ip IP   Default: 33.40.10.121" \
    "  --node1-rdma-ip IP   Required; may also use NODE1_RDMA_IP." \
    "  --leader-ip IP       Memcached address on node 0. Default: 71.54.52.21" \
    "  --dataset-dir PATH   Default: ${DATASET_DIR}" \
    "  --base-file PATH     Override automatic base bin discovery." \
    "  --query-file PATH    Override automatic query bin discovery." \
    "  --gt-file PATH       Override automatic GT bin discovery." \
    "  --output-dir PATH    Shared index directory." \
    "  --build-dir PATH     Per-host CMake build directory." \
    "  --threads N          Set both index and RDMA threads (legacy)." \
    "  --index-threads N    DiskANN/OpenMP build threads. Default: 8" \
    "  --rdma-threads N     CoTra/RDMA worker threads. Default: 8" \
    "  --build-jobs N       Parallel compile jobs. Default: 24" \
    "  --lat                Enable per-query latency measurement (avg_lat column)." \
    "  --gid-index N        Override automatic RoCE GID selection." \
    "  --help               Show this message." \
    "" \
    "Do not run index and search back-to-back automatically. Wait until the" \
    "index command has completed on both nodes before starting search."
}

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
}

note() {
  printf '\n=== %s ===\n' "$*"
}

is_positive_integer() {
  [[ $1 =~ ^[1-9][0-9]*$ ]]
}

is_nonnegative_integer() {
  [[ $1 =~ ^[0-9]+$ ]]
}

is_ipv4() {
  local ip=$1
  local a b c d extra
  IFS=. read -r a b c d extra <<<"${ip}"
  [[ -z ${extra:-} && -n ${a:-} && -n ${b:-} && -n ${c:-} && -n ${d:-} ]] ||
    return 1
  for part in "$a" "$b" "$c" "$d"; do
    [[ $part =~ ^[0-9]+$ ]] || return 1
    ((10#$part >= 0 && 10#$part <= 255)) || return 1
  done
}

while (($# > 0)); do
  case "$1" in
    check|build|index|search)
      MODE=$1
      shift
      ;;
    --node0-rdma-ip)
      NODE0_RDMA_IP=${2:?missing value for --node0-rdma-ip}
      shift 2
      ;;
    --node1-rdma-ip)
      NODE1_RDMA_IP=${2:?missing value for --node1-rdma-ip}
      shift 2
      ;;
    --leader-ip)
      LEADER_IP=${2:?missing value for --leader-ip}
      shift 2
      ;;
    --memcached-port)
      MEMCACHED_PORT=${2:?missing value for --memcached-port}
      shift 2
      ;;
    --dataset-dir)
      DATASET_DIR=${2:?missing value for --dataset-dir}
      shift 2
      ;;
    --base-file)
      BASE_FILE=${2:?missing value for --base-file}
      shift 2
      ;;
    --query-file)
      QUERY_FILE=${2:?missing value for --query-file}
      shift 2
      ;;
    --gt-file)
      GT_FILE=${2:?missing value for --gt-file}
      shift 2
      ;;
    --output-dir)
      OUTPUT_DIR=${2:?missing value for --output-dir}
      shift 2
      ;;
    --build-dir)
      BUILD_DIR=${2:?missing value for --build-dir}
      shift 2
      ;;
    --threads)
      THREADS=${2:?missing value for --threads}
      INDEX_THREADS=$THREADS
      RDMA_THREADS=$THREADS
      shift 2
      ;;
    --index-threads)
      INDEX_THREADS=${2:?missing value for --index-threads}
      shift 2
      ;;
    --rdma-threads)
      RDMA_THREADS=${2:?missing value for --rdma-threads}
      shift 2
      ;;
    --build-jobs)
      BUILD_JOBS=${2:?missing value for --build-jobs}
      shift 2
      ;;
    --lat)
      ENABLE_LAT=1
      shift 1
      ;;
    --gid-index)
      GID_INDEX=${2:?missing value for --gid-index}
      shift 2
      ;;
    --device)
      RDMA_DEVICE=${2:?missing value for --device}
      shift 2
      ;;
    --ib-port)
      IB_PORT=${2:?missing value for --ib-port}
      shift 2
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

HOST_SHORT=$(hostname -s 2>/dev/null || hostname)
if [[ -z $BUILD_DIR ]]; then
  BUILD_DIR="${REPO_ROOT}/build-arm-2node-${HOST_SHORT}"
fi
if [[ -z $OUTPUT_DIR ]]; then
  OUTPUT_DIR="${DATASET_DIR}/cotra_2node_index"
fi
CONFIG_FILE="${BUILD_DIR}/cotra_2node.conf"

validate_arguments() {
  [[ -n $NODE1_RDMA_IP ]] ||
    die "node 1 RoCE IP is required; set NODE1_RDMA_IP or --node1-rdma-ip"
  is_ipv4 "$NODE0_RDMA_IP" || die "invalid node 0 RoCE IP: ${NODE0_RDMA_IP}"
  is_ipv4 "$NODE1_RDMA_IP" || die "invalid node 1 RoCE IP: ${NODE1_RDMA_IP}"
  is_ipv4 "$LEADER_IP" || die "invalid leader IP: ${LEADER_IP}"
  [[ $NODE0_RDMA_IP != "$NODE1_RDMA_IP" ]] || die "the two RoCE IPs are equal"
  [[ ${NODE0_RDMA_IP%.*} == "${NODE1_RDMA_IP%.*}" ]] ||
    die "use one RoCE /24 for the first run: ${NODE0_RDMA_IP}, ${NODE1_RDMA_IP}"

  for pair in \
    "index threads:${INDEX_THREADS}" \
    "RDMA threads:${RDMA_THREADS}" \
    "build jobs:${BUILD_JOBS}" \
    "memcached port:${MEMCACHED_PORT}" \
    "IB port:${IB_PORT}" \
    "barrier timeout:${BARRIER_TIMEOUT}"; do
    local name=${pair%%:*}
    local value=${pair#*:}
    is_positive_integer "$value" || die "${name} must be a positive integer"
  done
  ((MEMCACHED_PORT <= 65535)) || die "memcached port is too large"
  ((INDEX_THREADS <= 128)) || die "index threads must not exceed 128"
  ((RDMA_THREADS <= 128)) ||
    die "RDMA threads must not exceed COTRA_MAX_THREAD_NUM=128"
  if [[ -n $GID_INDEX ]]; then
    is_nonnegative_integer "$GID_INDEX" || die "GID index must be non-negative"
  fi
  [[ $DATA_TYPE == float ]] || die "this GIST script currently expects float vectors"
  [[ $DISTANCE == l2 ]] || die "this GIST script currently expects L2 distance"
}

has_local_ipv4() {
  ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | grep -Fqx -- "$1"
}

detect_local_node() {
  command -v ip >/dev/null 2>&1 || die "the ip command is not installed"
  local node0_local=0
  local node1_local=0
  has_local_ipv4 "$NODE0_RDMA_IP" && node0_local=1
  has_local_ipv4 "$NODE1_RDMA_IP" && node1_local=1
  if ((node0_local + node1_local != 1)); then
    printf 'Configured node addresses:\n  node 0: %s\n  node 1: %s\n' \
      "$NODE0_RDMA_IP" "$NODE1_RDMA_IP" >&2
    printf 'Local IPv4 addresses:\n' >&2
    ip -4 -o addr show >&2
    die "exactly one configured RoCE IP must exist on this host"
  fi
  if ((node0_local)); then
    LOCAL_NODE_ID=0
  else
    LOCAL_NODE_ID=1
  fi
}

write_config() {
  mkdir -p "$BUILD_DIR"
  printf '%s\n%s\n%s=0\n%s=1\n' \
    "$LEADER_IP" "$MEMCACHED_PORT" "$NODE0_RDMA_IP" "$NODE1_RDMA_IP" \
    >"$CONFIG_FILE"
}

version_at_least() {
  local actual=$1
  local required_major=$2
  local required_minor=$3
  local major minor rest
  IFS=. read -r major minor rest <<<"${actual}"
  [[ ${major:-} =~ ^[0-9]+$ && ${minor:-0} =~ ^[0-9]+$ ]] || return 1
  ((major > required_major ||
    (major == required_major && ${minor:-0} >= required_minor)))
}

resolve_executable() {
  local value=$1
  if [[ $value == */* ]]; then
    printf '%s\n' "$value"
  else
    command -v "$value" || true
  fi
}

find_toolchain() {
  note "TOOLCHAIN"
  CC_BIN=${CC:-$(command -v gcc || true)}
  CXX_BIN=${CXX:-$(command -v g++ || true)}
  if [[ -n ${CMAKE:-} ]]; then
    CMAKE_BIN=$CMAKE
  elif command -v cmake >/dev/null 2>&1; then
    CMAKE_BIN=$(command -v cmake)
  elif command -v cmake3 >/dev/null 2>&1; then
    CMAKE_BIN=$(command -v cmake3)
  fi

  CC_BIN=$(resolve_executable "$CC_BIN")
  CXX_BIN=$(resolve_executable "$CXX_BIN")
  CMAKE_BIN=$(resolve_executable "$CMAKE_BIN")

  [[ -n $CC_BIN && -x $CC_BIN ]] || die "GCC was not found; load/install GCC 10.3+"
  [[ -n $CXX_BIN && -x $CXX_BIN ]] || die "G++ was not found; load/install GCC 10.3+"
  [[ -n $CMAKE_BIN && -x $CMAKE_BIN ]] ||
    die "CMake was not found; load/install CMake 3.16+"

  local gcc_version gcc_major
  gcc_version=$("$CXX_BIN" -dumpfullversion -dumpversion)
  gcc_major=${gcc_version%%.*}
  [[ $gcc_major =~ ^[0-9]+$ ]] || die "unable to determine G++ version"
  version_at_least "$gcc_version" 10 3 ||
    die "G++ 10.3+ is required; found ${gcc_version}"
  if ((gcc_major == 10)); then
    CXX_COMPAT_FLAGS=(-fcoroutines)
  fi

  local cmake_version
  cmake_version=$("$CMAKE_BIN" --version | awk 'NR == 1 {print $3}')
  version_at_least "$cmake_version" 3 16 ||
    die "CMake 3.16+ is required; found ${cmake_version}"

  printf 'CC:    %s\n' "$CC_BIN"
  printf 'CXX:   %s\n' "$CXX_BIN"
  printf 'CMake: %s\n' "$CMAKE_BIN"
  "$CXX_BIN" --version | sed -n '1p'
  "$CMAKE_BIN" --version | sed -n '1p'

  if ! printf '%s\n' \
    '#include <concepts>' \
    '#include <coroutine>' \
    'static_assert(std::convertible_to<int, long>);' \
    'struct task {' \
    '  struct promise_type {' \
    '    task get_return_object() { return {}; }' \
    '    std::suspend_never initial_suspend() { return {}; }' \
    '    std::suspend_never final_suspend() noexcept { return {}; }' \
    '    void return_void() {}' \
    '    void unhandled_exception() {}' \
    '  };' \
    '};' \
    'task probe() { co_return; }' \
    'int main() { probe(); }' |
    "$CXX_BIN" -std=c++20 "${CXX_COMPAT_FLAGS[@]}" -fopenmp \
      -x c++ -fsyntax-only - \
      >/dev/null 2>&1; then
    die "the selected compiler cannot compile C++20 coroutines with OpenMP"
  fi
}

check_headers() {
  note "DEVELOPMENT HEADERS"
  local headers=(
    infiniband/verbs.h
    rdma/rdma_cma.h
    numa.h
    libmemcached/memcached.h
    boost/program_options.hpp
    fmt/core.h
    cblas.h
    lapacke.h
    libaio.h
  )
  local include_arguments=()
  local include_dir
  for include_dir in \
    /usr/include/openblas \
    /usr/include/openblas-pthread \
    /usr/include/aarch64-linux-gnu \
    /usr/local/include/openblas; do
    if [[ -d $include_dir ]]; then
      include_arguments+=(-I "$include_dir")
    fi
  done
  local header
  local missing=0
  for header in "${headers[@]}"; do
    if printf '#include <%s>\n' "$header" |
      "$CXX_BIN" -std=c++20 -fopenmp "${include_arguments[@]}" \
        "${CXX_COMPAT_FLAGS[@]}" \
        -x c++ -fsyntax-only - \
        >/dev/null 2>&1; then
      printf 'OK      %s\n' "$header"
    else
      printf 'MISSING %s\n' "$header"
      missing=1
    fi
  done
  ((missing == 0)) ||
    die "development headers are missing; load modules or ask the administrator for the corresponding -devel packages"
}

read_text_file() {
  local path=$1
  local value
  if [[ ! -r $path ]]; then
    printf 'unknown'
    return
  fi
  if ! value=$(cat -- "$path" 2>/dev/null); then
    printf 'unavailable'
    return
  fi
  printf '%s' "${value//$'\n'/}"
}

check_rdma() {
  note "RDMA / ROCE"
  local port_root="/sys/class/infiniband/${RDMA_DEVICE}/ports/${IB_PORT}"
  [[ -d $port_root ]] || die "RDMA port not found: ${RDMA_DEVICE}/${IB_PORT}"
  printf 'Device/port: %s/%s\n' "$RDMA_DEVICE" "$IB_PORT"
  printf 'State:       %s\n' "$(read_text_file "${port_root}/state")"
  printf 'Link layer:  %s\n' "$(read_text_file "${port_root}/link_layer")"
  grep -q 'ACTIVE' "${port_root}/state" || die "RDMA port is not active"
  grep -qi 'Ethernet' "${port_root}/link_layer" ||
    die "the selected port is not an Ethernet/RoCE port"

  printf '\nGID table:\n'
  local gid_file index gid type netdev
  local gid_count=0
  for gid_file in "${port_root}"/gids/*; do
    [[ -e $gid_file ]] || continue
    index=${gid_file##*/}
    gid=$(read_text_file "$gid_file")
    if [[ ! $gid =~ ^([[:xdigit:]]{4}:){7}[[:xdigit:]]{4}$ ||
      $gid == 0000:0000:0000:0000:0000:0000:0000:0000 ]]; then
      continue
    fi
    type=$(read_text_file "${port_root}/gid_attrs/types/${index}")
    netdev=$(read_text_file "${port_root}/gid_attrs/ndevs/${index}")
    printf '%s gid=%s type=%s netdev=%s\n' "$index" "$gid" "$type" "$netdev"
    gid_count=$((gid_count + 1))
  done
  ((gid_count > 0)) || die "the selected RoCE port has no non-empty GID"

  printf '\nLocal IPv4 addresses:\n'
  ip -4 -o addr show
  local peer_ip
  if [[ $LOCAL_NODE_ID == 0 ]]; then
    peer_ip=$NODE1_RDMA_IP
    has_local_ipv4 "$LEADER_IP" ||
      die "node 0 does not own the configured memcached leader IP ${LEADER_IP}"
  else
    peer_ip=$NODE0_RDMA_IP
  fi
  printf '\nRoute to peer %s:\n' "$peer_ip"
  ip route get "$peer_ip" || die "there is no route to peer RoCE IP ${peer_ip}"
  if command -v ping >/dev/null 2>&1; then
    ping -c 1 -W 2 "$peer_ip" >/dev/null 2>&1 ||
      warn "peer ${peer_ip} did not answer ping; continue only if ICMP is intentionally blocked"
  fi
}

discover_file() {
  local kind=$1
  local explicit=$2
  if [[ -n $explicit ]]; then
    [[ -f $explicit ]] || die "${kind} file does not exist: ${explicit}"
    printf '%s\n' "$explicit"
    return
  fi

  local exact="${DATASET_DIR}/${kind}.bin"
  if [[ -f $exact ]]; then
    printf '%s\n' "$exact"
    return
  fi

  local matches=()
  local path
  case "$kind" in
    base)
      while IFS= read -r path; do matches+=("$path"); done < <(
        find "$DATASET_DIR" -maxdepth 1 -type f -iname '*base*bin' | sort)
      ;;
    query)
      while IFS= read -r path; do matches+=("$path"); done < <(
        find "$DATASET_DIR" -maxdepth 1 -type f -iname '*query*bin' | sort)
      ;;
    gt)
      while IFS= read -r path; do matches+=("$path"); done < <(
        find "$DATASET_DIR" -maxdepth 1 -type f \
          \( -iname '*gt*bin' -o -iname '*ground*truth*bin' \) | sort)
      ;;
  esac
  ((${#matches[@]} == 1)) || {
    printf 'Candidates for %s:\n' "$kind" >&2
    printf '  %s\n' "${matches[@]:-<none>}" >&2
    die "unable to select one ${kind} file; pass --${kind}-file explicitly"
  }
  printf '%s\n' "${matches[0]}"
}

read_bin_header() {
  local file=$1
  local values rows columns
  values=$(od -An -N8 -tu4 "$file")
  read -r rows columns <<<"$values"
  [[ ${rows:-} =~ ^[0-9]+$ && ${columns:-} =~ ^[0-9]+$ ]] ||
    die "cannot read uint32 row/dimension header from ${file}"
  printf '%s %s\n' "$rows" "$columns"
}

validate_vector_file() {
  local label=$1
  local file=$2
  local rows=$3
  local columns=$4
  local width=$5
  local actual_size expected_size
  actual_size=$(stat -c '%s' "$file")
  expected_size=$((8 + rows * columns * width))
  ((actual_size == expected_size)) ||
    die "${label} size mismatch: got ${actual_size}, expected ${expected_size} bytes"
}

check_dataset() {
  note "GIST DATASET"
  [[ -d $DATASET_DIR ]] || die "dataset directory does not exist: ${DATASET_DIR}"
  command -v od >/dev/null 2>&1 || die "od is required to inspect bin headers"
  command -v stat >/dev/null 2>&1 || die "stat is required to inspect bin files"

  BASE_FILE=$(discover_file base "$BASE_FILE")
  QUERY_FILE=$(discover_file query "$QUERY_FILE")
  GT_FILE=$(discover_file gt "$GT_FILE")
  [[ $BASE_FILE != "$QUERY_FILE" && $BASE_FILE != "$GT_FILE" &&
    $QUERY_FILE != "$GT_FILE" ]] || die "base, query, and GT must be different files"

  read -r BASE_ROWS BASE_DIM < <(read_bin_header "$BASE_FILE")
  read -r QUERY_ROWS QUERY_DIM < <(read_bin_header "$QUERY_FILE")
  read -r GT_ROWS GT_K < <(read_bin_header "$GT_FILE")

  validate_vector_file base "$BASE_FILE" "$BASE_ROWS" "$BASE_DIM" 4
  validate_vector_file query "$QUERY_FILE" "$QUERY_ROWS" "$QUERY_DIM" 4
  ((BASE_ROWS == 1000000)) || die "expected GIST 1M base rows, found ${BASE_ROWS}"
  ((BASE_DIM == 960)) || die "expected GIST dimension 960, found ${BASE_DIM}"
  ((QUERY_DIM == BASE_DIM)) || die "query dimension does not match base dimension"
  ((GT_ROWS >= QUERY_ROWS)) || die "GT contains fewer queries than query.bin"
  ((GT_K >= RESULT_K)) || die "GT K=${GT_K} is smaller than requested K=${RESULT_K}"

  local gt_size minimum_gt_size
  gt_size=$(stat -c '%s' "$GT_FILE")
  minimum_gt_size=$((8 + GT_ROWS * GT_K * 4))
  ((gt_size >= minimum_gt_size)) ||
    die "GT file is too short for ${GT_ROWS}x${GT_K} uint32 neighbor IDs"
  ((BASE_ROWS % 1000000 == 0)) || die "base row count is not an integer number of millions"
  MILLION=$((BASE_ROWS / 1000000))

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
  local peer_marker="${OUTPUT_DIR}/.cotra-shared-node$((1 - LOCAL_NODE_ID))"
  printf 'host=%s node=%s time=%s\n' "$HOST_SHORT" "$LOCAL_NODE_ID" \
    "$(date -Iseconds)" >"$marker"
  if [[ -f $peer_marker ]]; then
    printf 'Shared-path marker from the peer is visible: %s\n' "$peer_marker"
  else
    warn "peer shared-path marker is not visible yet; run check on the other node, then rerun check here"
  fi
}

run_preflight() {
  validate_arguments
  detect_local_node
  write_config
  note "HOST"
  printf 'Host:       %s\n' "$HOST_SHORT"
  printf 'Node ID:    %s\n' "$LOCAL_NODE_ID"
  printf 'Arch:       %s\n' "$(uname -m)"
  printf 'Config:     %s\n' "$CONFIG_FILE"
  printf 'Build dir:  %s\n' "$BUILD_DIR"
  [[ $(uname -m) == aarch64 ]] || warn "this script was designed for the reported aarch64 hosts"
  find_toolchain
  check_headers
  check_rdma
  check_dataset
  check_shared_output
  note "PREFLIGHT COMPLETE"
  printf 'Node %s is ready for mode %s.\n' "$LOCAL_NODE_ID" "$MODE"
}

configure_and_build() {
  run_preflight
  note "CMAKE CONFIGURE"
  if [[ -f ${BUILD_DIR}/CMakeCache.txt ]]; then
    local cached_machine_count
    cached_machine_count=$(
      sed -n 's/^COTRA_MACHINE_NUM:STRING=//p' "${BUILD_DIR}/CMakeCache.txt")
    if [[ -n $cached_machine_count && $cached_machine_count != 2 ]]; then
      die "existing build directory was configured for ${cached_machine_count} nodes; choose a new --build-dir"
    fi
  fi
  "$CMAKE_BIN" -S "$REPO_ROOT" -B "$BUILD_DIR" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="$CC_BIN" \
    -DCMAKE_CXX_COMPILER="$CXX_BIN" \
    -DCOTRA_MACHINE_NUM=2 \
    -DCOTRA_MAX_THREAD_NUM=128 \
    ${ENABLE_LAT:+-DCOTRA_LAT=ON}

  note "BUILD"
  "$CMAKE_BIN" --build "$BUILD_DIR" -j "$BUILD_JOBS"
  [[ -x ${BUILD_DIR}/tests/scala_index ]] || die "scala_index was not built"
  [[ -x ${BUILD_DIR}/tests/scala_anns ]] || die "scala_anns was not built"
  printf 'Build completed on node %s.\n' "$LOCAL_NODE_ID"
}

runtime_preflight() {
  run_preflight
  [[ -x ${BUILD_DIR}/tests/scala_index ]] ||
    die "scala_index is missing; run this script in build mode on this node first"
  [[ -x ${BUILD_DIR}/tests/scala_anns ]] ||
    die "scala_anns is missing; run this script in build mode on this node first"
  local locked
  locked=$(ulimit -l)
  [[ $locked == unlimited ]] ||
    die "max locked memory must be unlimited for this first RDMA run; found ${locked}"
  local omp_threads=$RDMA_THREADS
  if [[ $MODE == index ]]; then
    omp_threads=$INDEX_THREADS
  fi
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
  RDMA_ARGS=(
    -d "$RDMA_DEVICE"
    --ib-port "$IB_PORT"
    --barrier-timeout "$BARRIER_TIMEOUT"
  )
  if [[ -n $GID_INDEX ]]; then
    RDMA_ARGS+=(--gid-index "$GID_INDEX")
  fi
}

print_command() {
  printf 'Command:'
  printf ' %q' "$@"
  printf '\n'
}

run_index() {
  runtime_preflight
  reset_metadata
  rdma_arguments
  local log_file="${OUTPUT_DIR}/index-node${LOCAL_NODE_ID}.log"
  local command=(
    "${BUILD_DIR}/tests/scala_index"
    --config_file "$CONFIG_FILE"
    --graph_type scalagraph_v3
    --data_type "$DATA_TYPE"
    --dist_fn "$DISTANCE"
    --data_path "$BASE_FILE"
    --index_path_prefix "${OUTPUT_DIR}/merged_index"
    -R "$MAX_DEGREE"
    -L "$BUILD_L"
    -B "$SEARCH_DRAM_GB"
    -M "$BUILD_DRAM_GB"
    -T "$INDEX_THREADS"
    -t "$RDMA_THREADS"
    -s "$MILLION"
    --scala_v3
    --scalagraph_v2
    "${RDMA_ARGS[@]}"
  )
  note "TWO-NODE INDEX BUILD"
  printf 'Start node 0 first, then start node 1. Log: %s\n' "$log_file"
  print_command "${command[@]}"
  if "${command[@]}" 2>&1 | tee "$log_file"; then
    printf 'Index build completed successfully on node %s.\n' "$LOCAL_NODE_ID"
  else
    local status=${PIPESTATUS[0]}
    printf 'Index build failed on node %s with status %s.\n' \
      "$LOCAL_NODE_ID" "$status" >&2
    return "$status"
  fi
}

run_search() {
  runtime_preflight
  local required_index="${OUTPUT_DIR}/merged_index${LOCAL_NODE_ID}_final_scala.index"
  [[ -f $required_index ]] ||
    die "local index is missing: ${required_index}; finish index mode on both nodes first"
  reset_metadata
  rdma_arguments
  local log_file="${OUTPUT_DIR}/search-node${LOCAL_NODE_ID}.log"
  local command=(
    "${BUILD_DIR}/tests/scala_anns"
    --config_file "$CONFIG_FILE"
    --app_type scala_v3
    --graph_type scalagraph_v3
    --data_type "$DATA_TYPE"
    --dist_fn "$DISTANCE"
    --data_path "$BASE_FILE"
    --query_path "$QUERY_FILE"
    --gt_path "$GT_FILE"
    --query_size "$QUERY_ROWS"
    --res_knn "$RESULT_K"
    --index_path_prefix "${OUTPUT_DIR}/merged_index"
    -R "$MAX_DEGREE"
    -L "$BUILD_L"
    -B "$SEARCH_DRAM_GB"
    -M "$BUILD_DRAM_GB"
    -T "$INDEX_THREADS"
    -t "$RDMA_THREADS"
    -s "$MILLION"
    --scala_v3
    "${RDMA_ARGS[@]}"
  )
  note "TWO-NODE SEARCH"
  printf 'Start node 0 first, then start node 1. Log: %s\n' "$log_file"
  print_command "${command[@]}"
  if "${command[@]}" 2>&1 | tee "$log_file"; then
    printf 'Search completed successfully on node %s.\n' "$LOCAL_NODE_ID"
  else
    local status=${PIPESTATUS[0]}
    printf 'Search failed on node %s with status %s.\n' \
      "$LOCAL_NODE_ID" "$status" >&2
    return "$status"
  fi
}

case "$MODE" in
  check)
    run_preflight
    ;;
  build)
    configure_and_build
    ;;
  index)
    run_index
    ;;
  search)
    run_search
    ;;
esac
