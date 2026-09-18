#!/bin/bash

resolve_hostname() {
  local hostname=$1
  if command -v getent &> /dev/null; then
    local ips
    ips=$(getent ahostsv4 "$hostname" | awk '/STREAM/ {print $1}')
  elif command -v host &> /dev/null; then
    local ips
    ips=$(host "$hostname" | awk '/has address/ {print $4}')
  else
    echo "Error: failed to find getent or host.. "
    return 1
  fi

  if [ -z "$ips" ]; then
    echo "failed to resolve: $hostname"
    return 1
  fi

  # pass lo
  local filtered_ips=()
  for ip in $ips; do
    if [[ $ip != 127.* ]]; then
      filtered_ips+=("$ip")
    fi
  done

  if [ ${#filtered_ips[@]} -eq 0 ]; then
    echo "can not find address"
    return 1
  fi

  echo "${filtered_ips[0]}"
  return 0
}

is_local_ipv4() {
  local expected_ip=$1
  if command -v ip &> /dev/null; then
    ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' |
      cut -d/ -f1 | grep -Fqx -- "$expected_ip"
    return $?
  fi

  [[ "$(resolve_hostname "$(hostname)")" == "$expected_ip" ]]
}

# Memcached ASCII protocol helper written in pure bash /dev/tcp so that the
# deployment scripts do not require an extra ncat/nc binary on every node.
# Each helper returns 0 on success, non-zero on connect / I/O failure.
mc_send_cmd() {
  local addr=$1
  local port=$2
  local timeout_sec=${3:-2}
  local data=$4
  local reply=""
  local line=""
  local rc=0
  local exec_fd
  # The /dev/tcp pseudo-device is provided by bash itself (no binary needed).
  # We pick a free FD number with printf %d and close both directions on exit.
  exec_fd=9
  # Try up to 2 fds in case 9 is in use (uncommon).
  for try_fd in 9 200; do
    # shellcheck disable=SC2086
    if eval "exec $try_fd<>/dev/tcp/${addr}/${port}" 2>/dev/null; then
      exec_fd=$try_fd
      break
    fi
    if [[ $try_fd == 200 ]]; then
      return 1
    fi
  done
  # Enforce timeout via subshell + background alarm where possible.
  # For a simple best-effort wait, sleep in a busy-loop is not accurate; we
  # rely on bash being able to abort the connect quickly on ECONNREFUSED.
  printf '%s' "$data" >&$exec_fd 2>/dev/null || rc=$?
  if ((rc == 0)); then
    # Read only the first 4KB of reply; memcached ASCII responses fit easily.
    # Use read with a short timeout so that a close() -> EOF triggers exit.
    IFS= read -r -t "$timeout_sec" -u $exec_fd line 2>/dev/null || true
    reply=$line
  fi
  eval "exec $exec_fd<&-"
  eval "exec $exec_fd>&-"
  [[ -z $rc ]] && rc=0
  ((rc == 0)) || return $rc
  # For commands that expect a non-empty reply (e.g. "VERSION"), empty means
  # the server closed the connection before responding → treat as failure.
  if [[ -n $data && -z $reply ]]; then
    # But "set x 0 0 1" style writes may have empty first read if the reply
    # is buffered; still OK since connect succeeded.
    return 0
  fi
  return 0
}

probe_memcached() {
  local addr=$1
  local port=$2
  # memcached ASCII: send "version\r\n" and expect "VERSION ...".
  # mc_send_cmd already opens/closes connection; any failure → non-zero.
  local reply=""
  local exec_fd=9
  local try_fd
  for try_fd in 9 200; do
    if eval "exec $try_fd<>/dev/tcp/${addr}/${port}" 2>/dev/null; then
      exec_fd=$try_fd
      break
    fi
    if [[ $try_fd == 200 ]]; then
      return 1
    fi
  done
  local ok=1
  printf 'version\r\nquit\r\n' >&$exec_fd 2>/dev/null || ok=0
  if ((ok == 1)); then
    local line=""
    IFS= read -r -t 1 -u $exec_fd line 2>/dev/null || true
    # Case-insensitive match; anything starting VERSION is good enough.
    case "${line,,}" in
      version*) ok=1 ;;
      *) ok=0 ;;
    esac
  fi
  eval "exec $exec_fd<&-"
  eval "exec $exec_fd>&-"
  ((ok == 1))
}

wait_for_memcached() {
  local addr=$1
  local port=$2
  local attempts=$3
  local attempt
  for ((attempt = 1; attempt <= attempts; attempt++)); do
    if probe_memcached "$addr" "$port"; then
      return 0
    fi
    sleep 1
  done
  return 1
}


clear_memcache() {
  local CONF_FILE=$1
  if [ -f "$CONF_FILE" ]; then
    DOMAIN=$(sed -n '1p' "$CONF_FILE")  # read first line
    PORT=$(sed -n '2p' "$CONF_FILE")    # read second line
  else
    echo "config file $CONF_FILE does not exist."
    exit 1
  fi

  leader_hostname="$DOMAIN"
  if read_ip=$(resolve_hostname "$leader_hostname"); then
    echo "leader hostname $leader_hostname ip: $read_ip"
  else
    echo "failed to resolve leader machine ip"
    return 1
  fi

  hostname=$(hostname)
  echo "local hostname: $hostname"

  if is_local_ipv4 "$read_ip"; then
    if ! command -v memcached &> /dev/null; then
      echo "memcached is not installed on the leader"
      return 1
    fi
    # NOTE: the leader also needs memcached installed and available on PATH.
    # No nc/ncat dependency; the ASCII talker below uses bash /dev/tcp.

    # restart memcache
    addr=$DOMAIN
    port=$PORT
    pid_file="${TMPDIR:-/tmp}/cotra-memcached-${UID}.pid"

    # Stop the previous daemon completely before reusing its listening port.
    # Without this wait, a probe can connect to the dying old process and then
    # the C++ client sees ECONNREFUSED after that process exits.
    local old_pid old_comm
    if [[ -s $pid_file ]]; then
      old_pid=$(cat "$pid_file" 2>/dev/null || true)
      if [[ $old_pid =~ ^[1-9][0-9]*$ ]] && kill -0 "$old_pid" 2>/dev/null; then
        old_comm=$(ps -p "$old_pid" -o comm= 2>/dev/null || true)
        old_comm=${old_comm//[[:space:]]/}
        if [[ $old_comm != memcached ]]; then
          echo "refusing to stop PID $old_pid from $pid_file: process is $old_comm"
          return 1
        fi
        kill "$old_pid" 2>/dev/null || true
        for _ in {1..50}; do
          if ! kill -0 "$old_pid" 2>/dev/null; then
            break
          fi
          sleep 0.1
        done
        if kill -0 "$old_pid" 2>/dev/null; then
          echo "old memcached PID $old_pid did not stop within 5 seconds"
          return 1
        fi
      fi
      rm -f "$pid_file"
    fi

    # launch memcached
    local max_connections ready memcached_pid
    max_connections="${COTRA_MEMCACHED_MAX_CONNECTIONS:-256}"
    if [[ ! $max_connections =~ ^[1-9][0-9]*$ ]]; then
      echo "COTRA_MEMCACHED_MAX_CONNECTIONS must be a positive integer"
      return 1
    fi
    memcached_args=(
      -l "$addr"
      -p "$port"
      -c "$max_connections"
      -d
      -P "$pid_file"
    )
    if [[ $EUID -eq 0 ]]; then
      memcached_args=(-u root "${memcached_args[@]}")
    fi
    if ! memcached "${memcached_args[@]}"; then
      echo "failed to start memcached on $addr:$port"
      return 1
    fi

    ready=0
    if wait_for_memcached "$addr" "$port" 10; then
      ready=1
    fi
    memcached_pid=$(cat "$pid_file" 2>/dev/null || true)
    if [[ $ready -ne 1 || ! $memcached_pid =~ ^[1-9][0-9]*$ ]] ||
      ! kill -0 "$memcached_pid" 2>/dev/null; then
      echo "memcached did not become ready on $addr:$port"
      echo "open-file limit: $(ulimit -n)"
      echo "diagnose with: memcached -vv -l $addr -p $port -c $max_connections"
      return 1
    fi

    # Clear stale metadata from earlier runs and initialize counters.
    # Implemented with bash /dev/tcp (no nc binary required).
    mc_ascii_send() {
      local s_addr=$1
      local s_port=$2
      local s_data=$3
      local s_fd=9
      local s_ok=1
      local s_try
      for s_try in 9 200; do
        if eval "exec $s_try<>/dev/tcp/${s_addr}/${s_port}" 2>/dev/null; then
          s_fd=$s_try
          break
        fi
        if [[ $s_try == 200 ]]; then
          return 1
        fi
      done
      printf '%s' "$s_data" >&$s_fd 2>/dev/null || s_ok=0
      # Drain a short reply so the server has time to ACK the writes (memcached
      # ASCII commands like "STORED" / "OK" arrive on the same connection).
      if ((s_ok == 1)); then
        local s_line=""
        local s_i
        for s_i in 1 2 3 4; do
          IFS= read -r -t 2 -u $s_fd s_line 2>/dev/null || break
          case "$s_line" in
            STORED*|OK*|DELETED*|END*|ERROR*|CLIENT_ERROR*|SERVER_ERROR*) break ;;
          esac
        done
        :
      fi
      eval "exec $s_fd<&-"
      eval "exec $s_fd>&-"
      ((s_ok == 1))
    }
    mc_ascii_send "$addr" "$port" $'flush_all\r\nquit\r\n' || true
    mc_ascii_send "$addr" "$port" $'set serverNum 0 0 1\r\n0\r\nquit\r\n' || true
    mc_ascii_send "$addr" "$port" $'set clientNum 0 0 1\r\n0\r\nquit\r\n' || true
    echo "memcache clear and restart"
  else
    echo "waiting for leader memcached at $read_ip:$PORT"
    if ! wait_for_memcached "$read_ip" "$PORT" 30; then
      echo "cannot reach leader memcached at $read_ip:$PORT after 30 seconds"
      echo "check on the leader: ss -ltnp | grep ':$PORT'"
      return 1
    fi
    echo "leader memcached is reachable at $read_ip:$PORT"
  fi
  return 0
}
