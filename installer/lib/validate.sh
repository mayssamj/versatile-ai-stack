# validate.sh — health checks, port probes, curl-with-retry, smoke-test helpers.
# Sourced after common.sh.

[[ -z "${AI_STACK:-}" ]] && { echo "validate.sh: AI_STACK unset" >&2; exit 2; }

# wait_http URL [timeout_sec] [expected_status]
# Returns 0 when URL returns expected_status (default 200) within timeout.
wait_http() {
  local url="$1" timeout="${2:-30}" want="${3:-200}"
  local i=0
  while (( i < timeout )); do
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$url" 2>/dev/null || true)"
    if [[ "$code" == "$want" ]]; then
      return 0
    fi
    sleep 1
    i=$((i+1))
  done
  err "wait_http: $url did not return $want within ${timeout}s (last: ${code:-no-response})"
  return 1
}

# port_listening PORT
port_listening() {
  lsof -nP -iTCP:"$1" -sTCP:LISTEN 2>/dev/null | grep -q LISTEN
}

# wait_port PORT [timeout_sec]
wait_port() {
  local port="$1" timeout="${2:-30}" i=0
  while (( i < timeout )); do
    port_listening "$port" && return 0
    sleep 1
    i=$((i+1))
  done
  err "wait_port: nothing on :$port after ${timeout}s"
  return 1
}

# require_disk_free GB [path]
require_disk_free() {
  local need_gb="$1" path="${2:-$HOME}"
  local avail_gb
  # macOS df: -k = KB; pick the "Avail" column for the partition we land on.
  avail_gb="$(df -k "$path" | awk 'NR==2 { printf("%d", $4/1024/1024) }')"
  if (( avail_gb < need_gb )); then
    err "Need ${need_gb}GB free on $path; only ${avail_gb}GB available."
    return 1
  fi
  return 0
}

# require_port_free PORT [svc]
# Refuse to proceed if some other process is already on the port.
require_port_free() {
  local port="$1" svc="${2:-the service}"
  if port_listening "$port"; then
    # Is it US? (a managed container we already control)
    local owner
    owner="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1}')"
    if [[ "$owner" == "OrbStack" || "$owner" == "com.docker.backend" ]]; then
      # OrbStack process owns it — most likely an existing managed container.
      return 0
    fi
    err "Port $port is in use by $owner (not docker); cannot start $svc."
    err "Either free the port or override via env var (consult start script for which)."
    return 1
  fi
  return 0
}
