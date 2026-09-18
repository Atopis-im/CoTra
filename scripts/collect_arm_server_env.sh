#!/usr/bin/env bash

# Collect the Linux/AArch64, NUMA, RDMA, network, toolchain, and dependency
# information needed to port and validate CoTra on an ARM server or cluster.
#
# This script is read-only. It does not install packages, change sysctls,
# configure network devices, start services, or run RDMA traffic tests.

set -u
set -o pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)"
DEFAULT_SOURCE_DIR="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd -P)"
SOURCE_DIR="${DEFAULT_SOURCE_DIR}"
OUTPUT_FILE=""
FULL_PACKAGES=0
RUN_CMAKE_PROBE=1
declare -a PEERS=()
declare -a STORAGE_PATHS=()

usage() {
  printf '%s\n' \
    "Usage: $0 [options]" \
    "" \
    "Options:" \
    "  --output FILE         Write the report to FILE as well as stdout." \
    "  --source DIR          CoTra source directory (default: repository root)." \
    "  --peer HOST           Probe DNS, ping, route, and path to a cluster peer." \
    "                        May be supplied more than once." \
    "  --storage-path PATH   Inspect a dataset/index/shared-filesystem path." \
    "                        May be supplied more than once." \
    "  --full-packages       Include the complete installed package list." \
    "  --skip-cmake          Skip the temporary CMake configure probe." \
    "  -h, --help            Show this help." \
    "" \
    "For the fullest report, run as root (for example with sudo)." \
    "The report contains hostnames, IP/MAC addresses, routes, and RDMA GIDs."
}

while (($# > 0)); do
  case "$1" in
    --output)
      [[ $# -ge 2 ]] || { printf 'Missing value for --output\n' >&2; exit 2; }
      OUTPUT_FILE="$2"
      shift 2
      ;;
    --source)
      [[ $# -ge 2 ]] || { printf 'Missing value for --source\n' >&2; exit 2; }
      SOURCE_DIR="$2"
      shift 2
      ;;
    --peer)
      [[ $# -ge 2 ]] || { printf 'Missing value for --peer\n' >&2; exit 2; }
      PEERS+=("$2")
      shift 2
      ;;
    --storage-path)
      [[ $# -ge 2 ]] || { printf 'Missing value for --storage-path\n' >&2; exit 2; }
      STORAGE_PATHS+=("$2")
      shift 2
      ;;
    --full-packages)
      FULL_PACKAGES=1
      shift
      ;;
    --skip-cmake)
      RUN_CMAKE_PROBE=0
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 'Unknown option: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "${OUTPUT_FILE}" ]]; then
  REPORT_HOST="$(hostname -s 2>/dev/null || printf 'unknown-host')"
  REPORT_TIME="$(date -u +%Y%m%dT%H%M%SZ)"
  OUTPUT_FILE="${PWD}/cotra-arm-env-${REPORT_HOST}-${REPORT_TIME}.txt"
fi

if ! touch "${OUTPUT_FILE}" 2>/dev/null; then
  printf 'Cannot write report file: %s\n' "${OUTPUT_FILE}" >&2
  exit 1
fi

exec > >(tee "${OUTPUT_FILE}") 2>&1

section() {
  printf '\n\n===== %s =====\n' "$1"
}

subsection() {
  printf '\n--- %s ---\n' "$1"
}

have() {
  command -v "$1" >/dev/null 2>&1
}

run() {
  printf '\n$'
  printf ' %q' "$@"
  printf '\n'
  "$@"
  local status=$?
  if ((status != 0)); then
    printf '[exit status: %d]\n' "${status}"
  fi
  return 0
}

read_file() {
  local path="$1"
  if [[ -r "${path}" ]]; then
    subsection "${path}"
    sed -n '1,400p' "${path}"
  else
    printf '\n[not readable or not present: %s]\n' "${path}"
  fi
}

run_if_present() {
  local command_name="$1"
  shift
  if have "${command_name}"; then
    run "${command_name}" "$@"
  else
    printf '\n[command not installed: %s]\n' "${command_name}"
  fi
}

print_version() {
  local command_name="$1"
  shift
  if have "${command_name}"; then
    subsection "${command_name}"
    "${command_name}" "$@" 2>&1 | sed -n '1,20p'
    printf '[executable: %s]\n' "$(command -v "${command_name}")"
  else
    printf '\n[command not installed: %s]\n' "${command_name}"
  fi
}

collect_globbed_files() {
  local pattern="$1"
  local path
  shopt -s nullglob
  for path in ${pattern}; do
    read_file "${path}"
  done
  shopt -u nullglob
}

printf '%s\n' \
  "CoTra ARM/RDMA server environment report" \
  "Generated: $(date --iso-8601=seconds 2>/dev/null || date)" \
  "Output: ${OUTPUT_FILE}" \
  "Source: ${SOURCE_DIR}" \
  "Effective UID: ${EUID}" \
  "NOTICE: this report contains hostnames, IP/MAC addresses, routes, and RDMA GIDs."

section "Operating system and host"
run date
run hostname
run uname -a
run uname -m
run_if_present hostnamectl
run_if_present uptime
read_file /etc/os-release
read_file /etc/lsb-release
read_file /proc/version
read_file /proc/cmdline
read_file /proc/uptime
run_if_present systemd-detect-virt
run_if_present virt-what
run_if_present arch
run_if_present getconf LONG_BIT
run_if_present getconf PAGESIZE

subsection "Firmware and platform identity"
for platform_file in \
  /sys/class/dmi/id/sys_vendor \
  /sys/class/dmi/id/product_name \
  /sys/class/dmi/id/product_version \
  /sys/class/dmi/id/board_vendor \
  /sys/class/dmi/id/board_name \
  /sys/class/dmi/id/bios_vendor \
  /sys/class/dmi/id/bios_version \
  /sys/firmware/devicetree/base/model; do
  [[ -r "${platform_file}" ]] && printf '%s: %s\n' "${platform_file}" "$(tr -d '\0' < "${platform_file}")"
done
if ((EUID == 0)) && have dmidecode; then
  run dmidecode --type system
  run dmidecode --type baseboard
  run dmidecode --type bios
else
  printf '\n[run as root with dmidecode installed for complete DMI data]\n'
fi

section "CPU architecture and features"
run_if_present lscpu
run_if_present lscpu --extended=CPU,NODE,SOCKET,CORE,CACHE,ONLINE,MAXMHZ,MINMHZ
read_file /proc/cpuinfo
run_if_present nproc --all
run_if_present getconf _NPROCESSORS_ONLN
run_if_present getconf LEVEL1_DCACHE_LINESIZE
collect_globbed_files '/sys/devices/system/cpu/cpu*/cpufreq/scaling_driver'
collect_globbed_files '/sys/devices/system/cpu/cpu*/cpufreq/scaling_governor'
collect_globbed_files '/sys/devices/system/cpu/cpu*/cpufreq/scaling_available_governors'
collect_globbed_files '/sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq'
read_file /proc/sys/abi/sve_default_vector_length
run_if_present tuned-adm active

subsection "Compiler predefined architecture macros"
if have gcc; then
  printf '\n$ gcc -dM -E - < /dev/null\n'
  gcc -dM -E - < /dev/null 2>&1 | grep -E '__aarch64__|__arm__|__ARM_|__ARM_FEATURE|__linux__|__GNUC__' | sort
fi
if have g++; then
  printf '\n$ g++ -march=native -Q --help=target\n'
  g++ -march=native -Q --help=target 2>&1 | sed -n '1,300p'
fi

section "NUMA, memory, huge pages, and process limits"
run_if_present numactl --hardware
run_if_present numastat
run_if_present lstopo-no-graphics
run_if_present hwloc-info
read_file /sys/devices/system/node/online
collect_globbed_files '/sys/devices/system/node/node*/cpulist'
collect_globbed_files '/sys/devices/system/node/node*/distance'
collect_globbed_files '/sys/devices/system/node/node*/meminfo'
run_if_present free -h
read_file /proc/meminfo
read_file /proc/sys/kernel/numa_balancing
read_file /proc/sys/vm/nr_hugepages
read_file /proc/sys/vm/nr_overcommit_hugepages
read_file /proc/sys/vm/overcommit_memory
read_file /proc/sys/vm/overcommit_ratio
read_file /proc/sys/vm/max_map_count
read_file /proc/sys/vm/zone_reclaim_mode
read_file /sys/kernel/mm/transparent_hugepage/enabled
read_file /sys/kernel/mm/transparent_hugepage/defrag
run_if_present findmnt -t hugetlbfs
run_if_present ulimit -a
read_file /proc/self/limits
read_file /etc/security/limits.conf
collect_globbed_files '/etc/security/limits.d/*.conf'
run_if_present sysctl fs.aio-max-nr
run_if_present sysctl fs.aio-nr
run_if_present sysctl kernel.threads-max
run_if_present sysctl kernel.pid_max

section "Cgroups, scheduling, and interrupt placement"
run_if_present systemd-cgls --no-pager
read_file /proc/self/cgroup
read_file /proc/self/status
read_file /sys/fs/cgroup/cgroup.controllers
read_file /sys/fs/cgroup/cpuset.cpus.effective
read_file /sys/fs/cgroup/cpuset.mems.effective
run_if_present taskset -pc "$$"
run_if_present sysctl kernel.sched_migration_cost_ns
run_if_present sysctl kernel.sched_autogroup_enabled
printf '\n--- RDMA/network-related interrupts ---\n'
grep -Ei 'mlx|hns|rdma|infiniband|eth|enp|ens|eno|irq' /proc/interrupts 2>/dev/null | sed -n '1,500p' || true

section "Network interfaces, addressing, and routing"
run_if_present ip -details -statistics link show
run_if_present ip -details address show
run_if_present ip rule show
run_if_present ip route show table all
run_if_present ip -6 route show table all
run_if_present ip neighbor show
run_if_present ip netns list
run_if_present ss -s
run_if_present ss -lntup
run_if_present resolvectl status
read_file /etc/resolv.conf
read_file /etc/hosts
run_if_present networkctl list
run_if_present networkctl status --all
run_if_present nmcli --terse general status
run_if_present nmcli --terse device status
run_if_present nmcli connection show

subsection "Relevant network sysctls"
for sysctl_key in \
  net.core.rmem_default \
  net.core.rmem_max \
  net.core.wmem_default \
  net.core.wmem_max \
  net.core.netdev_max_backlog \
  net.core.somaxconn \
  net.ipv4.tcp_rmem \
  net.ipv4.tcp_wmem \
  net.ipv4.tcp_mtu_probing \
  net.ipv4.conf.all.rp_filter \
  net.ipv4.conf.default.rp_filter; do
  run_if_present sysctl "${sysctl_key}"
done

subsection "Per-interface Ethernet configuration"
if [[ -d /sys/class/net ]]; then
  for net_path in /sys/class/net/*; do
    [[ -e "${net_path}" ]] || continue
    netdev="${net_path##*/}"
    [[ "${netdev}" == "lo" ]] && continue
    subsection "network interface ${netdev}"
    run_if_present ethtool "${netdev}"
    run_if_present ethtool -i "${netdev}"
    run_if_present ethtool -k "${netdev}"
    run_if_present ethtool -l "${netdev}"
    run_if_present ethtool -g "${netdev}"
    run_if_present ethtool -c "${netdev}"
    run_if_present ethtool -a "${netdev}"
    run_if_present ethtool -S "${netdev}"
    run_if_present tc -s qdisc show dev "${netdev}"
    run_if_present tc -s class show dev "${netdev}"
    run_if_present tc -s filter show dev "${netdev}" ingress
    run_if_present dcb app show dev "${netdev}"
    run_if_present dcb buffer show dev "${netdev}"
    run_if_present dcb ets show dev "${netdev}"
    run_if_present dcb maxrate show dev "${netdev}"
    run_if_present dcb pfc show dev "${netdev}"
    run_if_present lldptool -t -i "${netdev}" -V PFC -c
    run_if_present lldptool -t -i "${netdev}" -V ETS-CFG -c
    run_if_present lldptool -t -i "${netdev}" -V APP -c
    run_if_present mlnx_qos -i "${netdev}"
  done
fi

subsection "DCB, PFC, ECN, and LLDP (important for RoCE)"
run_if_present lldpctl
run_if_present lldptool -t -n
run_if_present mlnx_qos -a

section "RDMA devices, ports, GIDs, and resources"
print_version rdma -V
print_version ibv_devinfo --version
print_version ibstat --version
print_version rping --version
print_version ib_write_bw --version
print_version ib_read_bw --version
print_version ib_send_bw --version
print_version ibv_rc_pingpong --help
print_version ibv_ud_pingpong --help
print_version ofed_info -s
run_if_present rdma system show
run_if_present rdma dev show
run_if_present rdma link show
run_if_present rdma resource show
run_if_present rdma statistic show
run_if_present ibv_devices
run_if_present ibv_devinfo -v
run_if_present ibstat
run_if_present ibstatus
run_if_present ibdev2netdev
run_if_present show_gids
run_if_present ofed_info -s
run_if_present mst status -v
run_if_present devlink dev show
run_if_present devlink port show
read_file /etc/infiniband/info
read_file /etc/rdma/rdma.conf

subsection "RDMA sysfs"
collect_globbed_files '/sys/class/infiniband/*/node_type'
collect_globbed_files '/sys/class/infiniband/*/fw_ver'
collect_globbed_files '/sys/class/infiniband/*/hca_type'
collect_globbed_files '/sys/class/infiniband/*/ports/*/state'
collect_globbed_files '/sys/class/infiniband/*/ports/*/phys_state'
collect_globbed_files '/sys/class/infiniband/*/ports/*/rate'
collect_globbed_files '/sys/class/infiniband/*/ports/*/link_layer'
collect_globbed_files '/sys/class/infiniband/*/ports/*/lid'
collect_globbed_files '/sys/class/infiniband/*/ports/*/sm_lid'
collect_globbed_files '/sys/class/infiniband/*/ports/*/gids/*'
collect_globbed_files '/sys/class/infiniband/*/ports/*/gid_attrs/types/*'
collect_globbed_files '/sys/class/infiniband/*/ports/*/gid_attrs/ndevs/*'
collect_globbed_files '/sys/class/infiniband/*/ports/*/pkeys/*'

section "PCI devices, kernel modules, and driver logs"
run_if_present lspci -nnk
read_file "/boot/config-$(uname -r)"
if have lspci; then
  printf '\n--- Detailed Ethernet/InfiniBand PCI devices ---\n'
  while IFS= read -r pci_slot; do
    [[ -n "${pci_slot}" ]] && run lspci -s "${pci_slot}" -vv
  done < <(lspci -D 2>/dev/null | awk 'BEGIN{IGNORECASE=1} /Ethernet|Network|InfiniBand/{print $1}')
fi
run_if_present lsmod
for module_name in mlx5_core mlx5_ib hns_roce ib_core ib_uverbs rdma_cm iw_cm; do
  have modinfo && run modinfo "${module_name}"
done
if have dmesg; then
  printf '\n--- Kernel messages related to ARM, NUMA, networking, and RDMA ---\n'
  dmesg 2>&1 | grep -Ei 'arm|aarch64|numa|huge|iommu|smmu|mlx|hns|rdma|infiniband|roce|ib_core|ib_uverbs|link.*(up|down)|firmware' | tail -n 1000 || true
fi
if have journalctl; then
  printf '\n--- Current-boot kernel journal related to RDMA/network ---\n'
  journalctl -k -b --no-pager 2>&1 | grep -Ei 'mlx|hns|rdma|infiniband|roce|ib_core|ib_uverbs|numa|huge|iommu|smmu' | tail -n 1000 || true
fi

section "Time synchronization"
run_if_present timedatectl status
run_if_present timedatectl timesync-status
run_if_present chronyc tracking
run_if_present chronyc sources -v
run_if_present ntpq -pn

section "Storage and shared filesystem visibility"
run_if_present lsblk -e7 -o NAME,KNAME,TYPE,SIZE,FSTYPE,MOUNTPOINTS,MODEL,ROTA,NUMA,TRAN
run_if_present findmnt --real --output TARGET,SOURCE,FSTYPE,OPTIONS
run_if_present df -Th
run_if_present mount
if ((${#STORAGE_PATHS[@]} == 0)); then
  STORAGE_PATHS+=("${SOURCE_DIR}")
fi
for storage_path in "${STORAGE_PATHS[@]}"; do
  subsection "storage path ${storage_path}"
  run stat "${storage_path}"
  run stat -f "${storage_path}"
  run_if_present findmnt -T "${storage_path}" -o TARGET,SOURCE,FSTYPE,OPTIONS
  run_if_present df -Th "${storage_path}"
  run_if_present namei -l "${storage_path}"
done

section "Compiler, build tools, and runtimes"
print_version gcc --version
print_version g++ --version
print_version clang --version
print_version clang++ --version
print_version cmake --version
print_version ctest --version
print_version make --version
print_version ninja --version
print_version pkg-config --version
print_version python3 --version
print_version git --version
print_version git-lfs --version
print_version ld --version
print_version as --version
print_version ar --version
print_version objdump --version
print_version mpicxx --version
print_version spack --version
print_version conan --version
print_version vcpkg version

section "Required library and header discovery"
subsection "pkg-config modules"
if have pkg-config; then
  pkg-config --list-all 2>&1 | grep -Ei 'ibverbs|rdma|numa|memcached|boost|fmt|openblas|blas|lapack|aio|tcmalloc|gperftools|openmp' | sort || true
  for module_name in \
    libibverbs librdmacm libnuma libmemcached libmemcachedutil \
    fmt openblas blas lapack lapacke libaio libunwind libglog \
    libgflags tcmalloc; do
    printf '\n--- pkg-config %s ---\n' "${module_name}"
    pkg-config --modversion "${module_name}" 2>&1 || true
    pkg-config --cflags --libs "${module_name}" 2>&1 || true
  done
fi

subsection "Dynamic linker cache"
if have ldconfig; then
  ldconfig -p 2>&1 | grep -Ei 'ibverbs|rdmacm|numa|memcached|boost|fmt|openblas|blas|lapack|aio|tcmalloc|gperftools|gomp|omp|stdc\+\+' | sort || true
fi

subsection "Expected headers"
for header_path in \
  /usr/include/infiniband/verbs.h \
  /usr/include/rdma/rdma_cma.h \
  /usr/include/numa.h \
  /usr/include/libmemcached/memcached.h \
  /usr/include/cblas.h \
  /usr/include/openblas/cblas.h \
  /usr/include/aarch64-linux-gnu/cblas.h \
  /usr/include/lapacke.h \
  /usr/include/fmt/core.h \
  /usr/include/libaio.h \
  /usr/include/gperftools/malloc_extension.h; do
  if [[ -e "${header_path}" ]]; then
    ls -l "${header_path}"
  else
    printf '[missing: %s]\n' "${header_path}"
  fi
done

section "Installed package versions"
PACKAGE_PATTERN='rdma|ibverbs|infiniband|ofed|mlx|hns|numa|memcached|boost|fmt|openblas|blas|lapack|mkl|armpl|libaio|tcmalloc|gperftools|openmp|gcc|g\+\+|clang|cmake|ninja|linux-image|linux-headers|kernel'
if have dpkg-query; then
  subsection "Debian/Ubuntu relevant packages"
  dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' 2>&1 | grep -Ei "${PACKAGE_PATTERN}" | sort || true
  if ((FULL_PACKAGES)); then
    subsection "Complete Debian/Ubuntu package list"
    dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' 2>&1 | sort
  fi
elif have rpm; then
  subsection "RPM relevant packages"
  rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n' 2>&1 | grep -Ei "${PACKAGE_PATTERN}" | sort || true
  if ((FULL_PACKAGES)); then
    subsection "Complete RPM package list"
    rpm -qa --qf '%{NAME}\t%{VERSION}-%{RELEASE}\t%{ARCH}\n' 2>&1 | sort
  fi
else
  printf '[No dpkg-query or rpm package database found]\n'
fi

section "Services and security controls"
run_if_present systemctl --no-pager --full status memcached
run_if_present systemctl --no-pager --full status rdma
run_if_present systemctl --no-pager --full status openibd
run_if_present systemctl --no-pager --full status NetworkManager
run_if_present systemctl --no-pager --full status systemd-networkd
run_if_present systemctl --no-pager --full status chronyd
run_if_present systemctl --no-pager --full status systemd-timesyncd
run_if_present getenforce
run_if_present sestatus
run_if_present aa-status
if ((EUID == 0)); then
  run_if_present nft list ruleset
  run_if_present iptables-save
  run_if_present ip6tables-save
else
  printf '\n[run as root to collect firewall rules and privileged service details]\n'
fi

section "Cluster peer reachability"
if ((${#PEERS[@]} == 0)); then
  printf 'No --peer values supplied. Add one --peer per other CoTra node.\n'
else
  for peer in "${PEERS[@]}"; do
    subsection "peer ${peer}"
    run_if_present getent ahosts "${peer}"
    run_if_present ip route get "${peer}"
    run_if_present ping -c 3 -W 2 "${peer}"
    run_if_present tracepath -n -m 8 "${peer}"
  done
fi

section "CoTra repository state"
if [[ -d "${SOURCE_DIR}/.git" ]]; then
  run git -C "${SOURCE_DIR}" status --short --branch
  run git -C "${SOURCE_DIR}" log -1 --decorate --oneline
  run git -C "${SOURCE_DIR}" remote -v
  run git -C "${SOURCE_DIR}" submodule status --recursive
else
  printf '[Not a Git repository: %s]\n' "${SOURCE_DIR}"
fi
for build_file in \
  "${SOURCE_DIR}/CMakeLists.txt" \
  "${SOURCE_DIR}/third_party/CMakeLists.txt" \
  "${SOURCE_DIR}/include/rdma/rdma_config.h"; do
  if [[ -r "${build_file}" ]]; then
    subsection "${build_file}"
    sed -n '1,360p' "${build_file}"
  fi
done

section "Read-only compile and link probes"
PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cotra-env-probe.XXXXXX")"
cleanup_probe() {
  rm -rf -- "${PROBE_DIR}"
}
trap cleanup_probe EXIT

if have g++; then
  printf '%s\n' \
    '#include <coroutine>' \
    '#include <thread>' \
    '#include <atomic>' \
    '#include <iostream>' \
    'int main() {' \
    '  std::atomic<int> value{0};' \
    '  std::thread worker([&] { value.fetch_add(1); });' \
    '  worker.join();' \
    '  std::cout << value.load() << "\\n";' \
    '  return value.load() == 1 ? 0 : 1;' \
    '}' > "${PROBE_DIR}/cxx20.cpp"
  run g++ -std=c++20 -pthread "${PROBE_DIR}/cxx20.cpp" -o "${PROBE_DIR}/cxx20"
  [[ -x "${PROBE_DIR}/cxx20" ]] && run "${PROBE_DIR}/cxx20"

  printf '%s\n' \
    '#include <omp.h>' \
    '#include <iostream>' \
    'int main() { std::cout << _OPENMP << "\\n"; return 0; }' > "${PROBE_DIR}/openmp.cpp"
  run g++ -std=c++20 -fopenmp "${PROBE_DIR}/openmp.cpp" -o "${PROBE_DIR}/openmp"
  [[ -x "${PROBE_DIR}/openmp" ]] && run "${PROBE_DIR}/openmp"

  printf '%s\n' \
    '#include <infiniband/verbs.h>' \
    '#include <rdma/rdma_cma.h>' \
    'int main() { return ibv_get_device_list(nullptr) == nullptr; }' > "${PROBE_DIR}/rdma.cpp"
  run g++ -std=c++20 "${PROBE_DIR}/rdma.cpp" -libverbs -lrdmacm -o "${PROBE_DIR}/rdma"

  printf '%s\n' \
    '#include <numa.h>' \
    'int main() { return numa_available() < 0; }' > "${PROBE_DIR}/numa.cpp"
  run g++ -std=c++20 "${PROBE_DIR}/numa.cpp" -lnuma -o "${PROBE_DIR}/numa"

  printf '%s\n' \
    '#include <libmemcached/memcached.h>' \
    'int main() { auto *m = memcached_create(nullptr); memcached_free(m); return 0; }' > "${PROBE_DIR}/memcached.cpp"
  run g++ -std=c++20 "${PROBE_DIR}/memcached.cpp" -lmemcached -o "${PROBE_DIR}/memcached"

  printf '%s\n' \
    '#if __has_include(<cblas.h>)' \
    '#include <cblas.h>' \
    '#elif __has_include(<openblas/cblas.h>)' \
    '#include <openblas/cblas.h>' \
    '#else' \
    '#error no CBLAS header' \
    '#endif' \
    'int main() { float x[2] = {3, 4}; return cblas_snrm2(2, x, 1) == 5 ? 0 : 1; }' > "${PROBE_DIR}/blas.cpp"
  run g++ -std=c++20 "${PROBE_DIR}/blas.cpp" -lopenblas -o "${PROBE_DIR}/blas"
  [[ -x "${PROBE_DIR}/blas" ]] && run "${PROBE_DIR}/blas"

  printf '%s\n' \
    '#include <lapacke.h>' \
    'int main() { return LAPACK_ROW_MAJOR == 101 ? 0 : 1; }' > "${PROBE_DIR}/lapacke.cpp"
  run g++ -std=c++20 "${PROBE_DIR}/lapacke.cpp" -llapacke -llapack -lblas -o "${PROBE_DIR}/lapacke"
  [[ -x "${PROBE_DIR}/lapacke" ]] && run "${PROBE_DIR}/lapacke"
else
  printf '[g++ is not installed; compile probes skipped]\n'
fi

if ((RUN_CMAKE_PROBE)) && have cmake && [[ -r "${SOURCE_DIR}/CMakeLists.txt" ]]; then
  section "Temporary CoTra CMake configure probe"
  run cmake -S "${SOURCE_DIR}" -B "${PROBE_DIR}/cmake-build" -DCMAKE_BUILD_TYPE=Release -DCMAKE_EXPORT_COMPILE_COMMANDS=ON
  if [[ -r "${PROBE_DIR}/cmake-build/CMakeCache.txt" ]]; then
    subsection "Selected CMake cache entries"
    grep -E '^(CMAKE_|Boost_|NUMA_|FMT_|MEMCACHED_|IBVERBS_|RDMACM_|BLAS_|LAPACK_|OpenMP_|MKL_|OMP_|FAISS_)' \
      "${PROBE_DIR}/cmake-build/CMakeCache.txt" | sed -n '1,600p' || true
  fi
fi

section "Collection summary"
printf '%s\n' \
  "Report complete: ${OUTPUT_FILE}" \
  "Run the script on every non-identical node." \
  "For homogeneous nodes, run it on one node and use --peer for all other nodes." \
  "No RDMA traffic test was run; pairwise ib_write_bw/rping tests require coordinated endpoints." \
  "Review the report before sharing because it contains network and hardware identifiers."
