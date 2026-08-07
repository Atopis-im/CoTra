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
    if ! command -v nc &> /dev/null; then
      echo "nc is required to initialize CoTra metadata"
      return 1
    fi

    # restart memcache
    addr=$DOMAIN
    port=$PORT
    pid_file="${TMPDIR:-/tmp}/cotra-memcached-${UID}.pid"

    # kill old me
    if [[ -f "$pid_file" ]]; then
        kill "$(cat "$pid_file")" 2>/dev/null
        rm -f "$pid_file"
    fi

    # launch memcached
    memcached_args=(-l "$addr" -p "$port" -c 10000 -d -P "$pid_file")
    if [[ $EUID -eq 0 ]]; then
      memcached_args=(-u root "${memcached_args[@]}")
    fi
    if ! memcached "${memcached_args[@]}"; then
      echo "failed to start memcached on $addr:$port"
      return 1
    fi
    sleep 1

    # Clear stale metadata from earlier runs and initialize counters.
    printf 'flush_all\r\nquit\r\n' | nc "$addr" "$port"
    printf 'set serverNum 0 0 1\r\n0\r\nquit\r\n' | nc "$addr" "$port"
    printf 'set clientNum 0 0 1\r\n0\r\nquit\r\n' | nc "$addr" "$port"
    echo "memcache clear and restart"
  fi
  return 0
}


