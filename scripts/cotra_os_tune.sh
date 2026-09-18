#!/usr/bin/env bash
# =============================================================================
# cotra_os_tune.sh — OS / firmware tuning to kill run-to-run QPS variance
#                     (straggler amplification by the global search barrier).
#
# WHY THIS EXISTS
#   exec_query.h:731  while(load_cnt.load() < query_load)  is a global barrier:
#   every measured run's wall time == the SLOWEST thread that run.  At 72t
#   across 3 NUMA nodes, random stragglers (frequency downclock, deep C-state
#   exit, TLB miss storm on 4KB pages, NIC IRQ preempting a compute core) get
#   amplified into 2-3x run-to-run spread.  This script removes those sources.
#
# WHAT THE PROGRAM ALREADY DOES (do NOT duplicate)
#   - CPU pinning:        hwtopo.cpp bindThreadSelf() -> sched_setaffinity,
#                         threads bound tid-sequential by (smt,physid,coreid).
#                         => do NOT wrap the binary in taskset/numactl
#                            --cpunodebind; it is redundant and can conflict.
#   - NUMA-interleaved memory: numa_mem.cpp largeMallocInterleaved() +
#                         first-touch pageIn() round-robin across bound threads.
#                         => do NOT numactl --membind either.
#
# WHAT THE PROGRAM NEEDS FROM THE OS (this script)
#   1. 2 MiB hugepages available  (hugepage.cpp mmap MAP_HUGETLB; silent 4KB
#      fallback if the pool is empty OR if Hugepagesize != 2048 kB).
#   2. CPU governor = performance (no random downclock).
#   3. Deep C-states disabled (no slow exit latency).
#   4. NIC IRQs pinned OFF compute cores (no preempt of a bound thread).
#   5. NIC RX coalescing tamed (deterministic latency).
#
# USAGE  (run on EVERY node, all 8)
#   bash cotra_os_tune.sh discover             # read-only: show current state
#   sudo bash cotra_os_tune.sh apply           # apply runtime settings
#   sudo bash cotra_os_tune.sh irq [PID]       # pin mlx5 IRQs off compute cores
#                                              #   PID = running scala_anns pid
#                                              #   (omitted -> use high cores)
#   bash cotra_os_tune.sh verify [PID]         # check hugepages actually used
#
# All "apply" changes are runtime (no reboot).  Persistent variants are printed
# at the end so you can put them in sysctl.d / GRUB for boot-time durability.
# =============================================================================
set -u

NIC="${NIC:-mlx5_0}"
HP_SIZE_KB=2048            # hugepage.cpp hardcodes 2 MiB; do not change.

note()  { printf '\033[1;34m[tune]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[tune WARN]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[tune ERR]\033[0m %s\n' "$*" >&2; exit 1; }

have()  { command -v "$1" >/dev/null 2>&1; }

# -----------------------------------------------------------------------------
# discover  — read-only snapshot of every knob this script can touch.
# -----------------------------------------------------------------------------
do_discover() {
  note "=== CPU / NUMA ==="
  have lscpu      && lscpu | grep -E '^(Architecture|CPU\(s\)|On-line|NUMA|Model name)' || true
  have numactl    && numactl -H 2>/dev/null | grep -E '^(node [0-9]+ (cpus|size)|available)' || true
  printf 'total cores: %s\n' "$(nproc)"

  note "=== Memory ==="
  free -g 2>/dev/null || true
  grep -E '^(MemTotal|HugePages_Total|HugePages_Free|HugePages_Rsvd|Hugepagesize|HugePages_Surp)' /proc/meminfo

  note "=== Hugepage compatibility (CRITICAL) ==="
  local hps
  hps=$(awk '/^Hugepagesize:/{print $2}' /proc/meminfo)
  if [[ -z ${hps:-} ]]; then
    warn "no Hugepagesize line; hugepages likely unsupported on this kernel."
  elif (( hps == HP_SIZE_KB )); then
    note "Hugepagesize=${hps} kB == program's 2 MiB  =>  hugepages USABLE"
  else
    warn "Hugepagesize=${hps} kB != 2048 kB.  hugepage.cpp hardcodes 2 MiB,"
    warn "so the program can NEVER use hugepages on this kernel config and"
    warn "will silently fall back to 4 KiB pages.  Fix: boot with"
    warn "  default_hugepagesz=2M hugepagesz=2M hugepages=N"
    warn "on the kernel command line (GRUB).  This is likely your #1 variance"
    warn "source if you see the 'Compatible 2 MiB huge pages are unavailable'"
    warn "line in the search log."
  fi

  note "=== CPU governor ==="
  local g first=1
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    g=$(cat "$f" 2>/dev/null)
    if (( first )); then printf '  sample (cpu0): %s\n' "$g"; first=0; fi
  done
  have cpupower && { note '  available governors:'; cpupower frequency-info -g 2>/dev/null | tail -n +2 || true; }

  note "=== C-states (cpuidle) ==="
  local drv
  drv=$(cat /sys/devices/system/cpu/cpuidle/current_driver 2>/dev/null)
  printf '  cpuidle driver: %s\n' "${drv:-<none / disabled>}"
  local s name
  for s in /sys/devices/system/cpu/cpu0/cpuidle/state*/; do
    [[ -e ${s}name ]] || continue
    name=$(cat "${s}name" 2>/dev/null)
    printf '  state %s: %-14s disable=%s\n' \
      "$(basename "$s")" "$name" "$(cat "${s}disable" 2>/dev/null)"
  done

  note "=== NIC: ${NIC} ==="
  have ethtool && {
    ethtool -i "$NIC" 2>/dev/null | grep -E '^(driver|bus-info|version)' || true
    note "  coalescing (-C):"; ethtool -c "$NIC" 2>/dev/null | grep -E '^(rx-usecs|rx-frames|adaptive-rx)' || true
  } || warn "ethtool not installed; cannot inspect/tune NIC."
  printf '  cqe_compression (module): %s\n' \
    "$(cat /sys/module/mlx5_core/parameters/cqe_compression 2>/dev/null || echo '<n/a>')"

  note "=== NIC IRQs ==="
  grep -E "${NIC}|mlx5" /proc/interrupts 2>/dev/null | head -n 20 || warn "no ${NIC} interrupts found"
  note "  irqbalance:"
  systemctl is-active irqbalance 2>/dev/null || echo '<not a systemd service>'

  note "=== done (discover). No changes were made. ==="
}

# -----------------------------------------------------------------------------
# apply — runtime settings (needs root, no reboot)
# -----------------------------------------------------------------------------
do_apply() {
  [[ $(id -u) -eq 0 ]] || die "apply needs root (run with sudo)."

  # ---- 1. hugepages -------------------------------------------------------
  # Target ~75% of currently FREE RAM.  Reservation can partially fail if
  # memory is fragmented; drop_caches first for a better success rate.
  local free_kb hp_target
  free_kb=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo)
  hp_target=$(( free_kb * 75 / 100 / HP_SIZE_KB ))
  note "reserving ${hp_target} x 2MiB hugepages (~$(( hp_target * 2 / 1024 )) GiB of ${free_kb%% *} free kB)"
  # Best-effort defrag so the kernel can actually grant the request.
  echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || warn "could not drop caches (continuing)"
  echo "$hp_target" > /proc/sys/vm/nr_hugepages
  local got
  got=$(awk '/^HugePages_Total:/{print $2}' /proc/meminfo)
  if (( got < hp_target * 9 / 10 )); then
    warn "only got ${got}/${hp_target} hugepages (memory fragmented). Reboot with"
    warn "  hugepages=${hp_target}  on the kernel cmdline for a clean reservation."
  else
    note "hugepages reserved: ${got} (target ${hp_target})"
  fi

  # Sanity: is the size even usable by the program?
  local hps
  hps=$(awk '/^Hugepagesize:/{print $2}' /proc/meminfo)
  if [[ -n ${hps:-} ]] && (( hps != HP_SIZE_KB )); then
    warn "Hugepagesize=${hps} kB != 2048 kB => program still cannot use these!"
    warn "Add to GRUB: default_hugepagesz=2M hugepagesz=2M hugepages=${hp_target} ; reboot."
  fi

  # ---- 2. CPU governor = performance -------------------------------------
  local n=0
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
    [[ -w $f ]] || continue
    echo performance > "$f" 2>/dev/null && n=$((n+1))
  done
  note "set governor=performance on ${n} cpus"
  # Some ARM platforms expose EPP/energy prefs instead; best-effort.
  for f in /sys/devices/system/cpu/cpu*/cpufreq/energy_performance_preference; do
    [[ -w $f ]] || continue
    echo performance > "$f" 2>/dev/null || true
  done

  # ---- 3. disable deep C-states (keep state0 = WFI) -----------------------
  local s name disabled=0
  for s in /sys/devices/system/cpu/cpu*/cpuidle/state*/; do
    [[ -e ${s}disable ]] || continue
    case "$(basename "$s")" in state0) continue;; esac   # keep shallowest
    echo 1 > "${s}disable" 2>/dev/null && disabled=$((disabled+1))
  done
  note "disabled deeper C-states on ${disabled} cpu-state entries"

  # ---- 4. stop irqbalance (we pin IRQs ourselves in `irq`) ----------------
  if systemctl is-active irqbalance >/dev/null 2>&1; then
    systemctl stop irqbalance && note "stopped irqbalance"
  else
    note "irqbalance not running (good)"
  fi

  # ---- 5. NIC RX coalescing: minimal, deterministic -----------------------
  if have ethtool; then
    ethtool -C "$NIC" adaptive-rx off rx-usecs 0 rx-frames 0 2>/dev/null \
      && note "NIC ${NIC}: adaptive-rx off, rx-usecs=0 rx-frames=0" \
      || warn "ethtool -C failed for ${NIC} (driver may not allow it; non-fatal)"
  fi

  do_persistent_advice "$hp_target"
  note "=== apply done. Run 'discover' again to confirm, then 'irq' while scala_anns runs. ==="
}

# -----------------------------------------------------------------------------
# irq — pin mlx5 NIC IRQs onto cores NOT used by compute threads.
# -----------------------------------------------------------------------------
do_irq() {
  [[ $(id -u) -eq 0 ]] || die "irq needs root (run with sudo)."
  local pid="${1:-}"

  # Determine the compute core set.
  local compute_csv=""
  if [[ -n $pid ]]; then
    note "reading compute cores from scala_anns pid ${pid}"
    for t in /proc/${pid}/task/*/status; do
      [[ -r $t ]] || continue
      local l
      l=$(awk '/^Cpus_allowed_list:/{print $2}' "$t" 2>/dev/null)
      [[ -n $l ]] && compute_csv="${compute_csv:+${compute_csv},}${l}"
    done
  fi

  local total
  total=$(nproc)
  local irq_csv
  if [[ -n $compute_csv ]]; then
    irq_csv=$(complement_cpu_list "$compute_csv" "$total")
    note "compute cores: ${compute_csv}"
    note "free   cores: ${irq_csv:-<none>}"
  else
    # No pid: assume program binds the low cores (tid-sequential); use the
    # top 4 cores as IRQ targets (e.g. 96-core box, 72t -> cores 92-95 = node3).
    irq_csv="$(( total - 4 ))-$(( total - 1 ))"
    note "no pid given; defaulting IRQ cores to ${irq_csv} (top 4)."
    warn "verify with 'irq <scala_anns_pid>' for an exact non-compute set."
  fi

  [[ -n $irq_csv ]] || die "no free cores for IRQs (compute uses all ${total})."

  # Expand the chosen IRQ core list to a single first core for affinity_list,
  # but round-robin so multiple queues spread out.
  local -a irqcores
  read -ra irqcores <<< "$(expand_range "$irq_csv")"
  local nq=${#irqcores[@]}
  (( nq > 0 )) || die "expanded IRQ core list is empty."

  local i=0 cnt=0
  while read -r irq _ rest; do
    # match mlx5 interrupt lines (names vary: mlx5_0-0, mlx5-0@..., mlx5_comp21)
    case "$rest" in *mlx5*) ;; *) continue;; esac
    local target=${irqcores[$(( i % nq ))]}
    local af="/proc/irq/${irq}/smp_affinity_list"
    if [[ -w $af ]]; then
      echo "$target" > "$af" 2>/dev/null && cnt=$((cnt+1)) || warn "failed to set $af"
    else
      warn "$af not writable; try the hex smp_affinity manually for irq ${irq}"
    fi
    i=$((i+1))
  done < <(grep -E "mlx5" /proc/interrupts 2>/dev/null)
  note "pinned ${cnt} mlx5 IRQ(s) to cores {${irq_csv}} (round-robin)"
}

# -----------------------------------------------------------------------------
# verify — confirm the program actually consumes hugepages during a run.
# -----------------------------------------------------------------------------
do_verify() {
  local pid="${1:-}"
  note "hugepages now:"
  grep -E '^(HugePages_Total|HugePages_Free|HugePages_Rsvd)' /proc/meminfo
  if [[ -n $pid ]] && [[ -d /proc/$pid ]]; then
    local h
    h=$(awk '/^VmHWM:/{print $2}' /proc/${pid}/status 2>/dev/null)
    note "scala_anns pid ${pid} VmHWM=${h} kB"
    note "if HugePages_Free dropped during the run vs. discover-time, MAP_HUGETLB is working."
  fi
  note "also grep the search log for: 'Compatible 2 MiB huge pages are unavailable'"
  note "  (that one-time WARN means 4KB fallback is active -> fix hugepages first)."
}

# -----------------------------------------------------------------------------
# helpers
# -----------------------------------------------------------------------------
# expand "0-3,5,7-8" -> "0 1 2 3 5 7 8"
expand_range() {
  local in=$1 out=""
  IFS=',' read -ra parts <<< "$in"
  for p in "${parts[@]}"; do
    if [[ $p == *-* ]]; then
      local b e
      b=${p%-*}; e=${p#*-}
      while (( b <= e )); do out="${out:+$out }$b"; b=$((b+1)); done
    else
      out="${out:+$out }$p"
    fi
  done
  printf '%s' "$out"
}

# all cores 0..total-1 minus the given csv -> csv
complement_cpu_list() {
  local used=$1 total=$2
  declare -A usedmap=()
  local x
  for x in $(expand_range "$used"); do usedmap[$x]=1; done
  local out="" i=0
  while (( i < total )); do
    [[ -z ${usedmap[$i]:-} ]] && out="${out:+$out,}$i"
    i=$((i+1))
  done
  printf '%s' "$out"
}

do_persistent_advice() {
  local hp=$1
  cat <<EOF

[tune] ---- Persistent (boot-time) equivalents ----
Hugepages (recommended, survives reboot + avoids fragmentation failure):
  # /etc/default/grub  ->  GRUB_CMDLINE_LINUX_APPEND="... default_hugepagesz=2M hugepagesz=2M hugepages=${hp}"
  # then: update-grub && reboot
  # (on aarch64 if default hugepage size is not 2M, the explicit
  #  hugepagesz=2M is REQUIRED or the program can never use them)

Governor (persistent):
  # /etc/sysctl.d/ ?  -> no, governor is sysfs; use a systemd unit or cpupower:
  cpupower frequency-set -g performance
  # or /etc/systemd/system/cotra-gov.service running at boot:
  #   ExecStart=/bin/sh -c 'for c in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > \$c; done'

Disable deep C-states persistently (kernel cmdline, reboot):
  processor.max_cstate=1  (and idle=poll for max determinism, costs power)

NIC module (CQE compression off, needs NIC reload / reboot):
  echo "options mlx5_core cqe_compression=0" > /etc/modprobe.d/mlx5.conf
  # reload: rmmod mlx5_core; modprobe mlx5_core  (only when NIC not in use)

Keep irqbalance off persistently:
  systemctl disable irqbalance
EOF
}

# -----------------------------------------------------------------------------
case "${1:-discover}" in
  discover) do_discover ;;
  apply)    do_apply ;;
  irq)      shift; do_irq "$@" ;;
  verify)   shift; do_verify "$@" ;;
  -h|--help|help) sed -n '1,60p' "$0" ;;
  *) die "unknown command '$1'. Try: discover | apply | irq [PID] | verify [PID]" ;;
esac
