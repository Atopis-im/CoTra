#!/bin/sh

# Collect the minimum environment information needed for the first CoTra
# Linux/AArch64 and RDMA portability pass. This script is read-only and is
# intentionally POSIX sh compatible.

set -u

REPORT_HOST=$(hostname -s 2>/dev/null || printf 'unknown-host')
REPORT_TIME=$(date -u +%Y%m%dT%H%M%SZ)
OUTPUT_FILE="/tmp/cotra-arm-min-${REPORT_HOST}-${REPORT_TIME}.txt"

usage() {
  printf '%s\n' \
    "Usage: $0 [--output FILE]" \
    "" \
    "Collect the minimum OS, CPU/NUMA, memory, compiler, RDMA, network," \
    "and library information needed to start the CoTra ARM port." \
    "" \
    "Run as the same non-root user that will run CoTra so the reported" \
    "memlock limit is accurate."
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      if [ "$#" -lt 2 ]; then
        printf 'Missing value for --output\n' >&2
        exit 2
      fi
      OUTPUT_FILE=$2
      shift 2
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

if ! : > "${OUTPUT_FILE}" 2>/dev/null; then
  printf 'Cannot write report file: %s\n' "${OUTPUT_FILE}" >&2
  exit 1
fi

have() {
  command -v "$1" >/dev/null 2>&1
}

missing() {
  printf '[command not installed: %s]\n' "$1"
}

{
  printf '%s\n' \
    "CoTra minimal ARM/RDMA environment report" \
    "Generated: $(date 2>/dev/null)" \
    "Host: ${REPORT_HOST}" \
    "Output: ${OUTPUT_FILE}" \
    "Effective user: $(id 2>/dev/null)"

  printf '\n=== OS ===\n'
  uname -a
  if [ -r /etc/os-release ]; then
    sed -n '1,120p' /etc/os-release
  else
    printf '[not readable: /etc/os-release]\n'
  fi

  printf '\n=== CPU / NUMA / MEMORY ===\n'
  if have lscpu; then lscpu; else missing lscpu; fi
  if have numactl; then numactl --hardware; else missing numactl; fi
  if have free; then free -h; else missing free; fi
  if [ -r /proc/meminfo ]; then
    grep -iE 'HugePages|Hugepagesize' /proc/meminfo || true
  else
    printf '[not readable: /proc/meminfo]\n'
  fi
  if [ -r /proc/self/limits ]; then
    grep '^Max locked memory' /proc/self/limits || true
  else
    printf '[not readable: /proc/self/limits]\n'
  fi

  printf '\n=== TOOLCHAIN ===\n'
  if have g++; then g++ --version | sed -n '1p'; else missing g++; fi
  if have cmake; then cmake --version | sed -n '1p'; else missing cmake; fi

  printf '\n=== RDMA ===\n'
  if have ibv_devices; then ibv_devices; else missing ibv_devices; fi
  if have ibv_devinfo; then
    ibv_devinfo 2>&1 | grep -E \
      'hca_id|transport|fw_ver|state:|active_mtu|gid_tbl_len|link_layer' || true
  else
    missing ibv_devinfo
  fi
  if have rdma; then rdma link show; else missing rdma; fi

  printf '\n=== NETWORK ===\n'
  if have ip; then
    ip -brief link
    ip -brief address
    ip route
  else
    missing ip
  fi

  printf '\n=== LIBRARIES ===\n'
  if have pkg-config; then
    printf '%s\n' '-- libibverbs --'
    pkg-config --modversion libibverbs 2>&1 || true
    printf '%s\n' '-- librdmacm --'
    pkg-config --modversion librdmacm 2>&1 || true
  else
    missing pkg-config
  fi
  if have ldconfig; then
    ldconfig -p 2>/dev/null | grep -E \
      'libibverbs|librdmacm|libnuma|libmemcached|libopenblas|liblapacke' || true
  else
    missing ldconfig
  fi

  printf '\n=== SUMMARY ===\n'
  printf 'Report complete: %s\n' "${OUTPUT_FILE}"
  printf '%s\n' \
    'Run this script as the non-root CoTra user; do not use sudo unless' \
    'CoTra itself will run as root.'
} 2>&1 | tee "${OUTPUT_FILE}"
