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

# config_validate — fail-fast guardrail (2026-06-21 resilience hardening). Validate
# that the declarative configs PARSE cleanly BEFORE any phase runs, so a YAML typo
# (a stray quote / missing colon in services.yml or models.yml) aborts with a clear,
# actionable error instead of hard-aborting mid-phase under `set -e` — the class that
# hung `install all` at phase 26 on a one-character models.yml typo. Read-only +
# idempotent. Skips gracefully if yq isn't on PATH yet (preflight ensures it).
config_validate() {
  command -v yq >/dev/null 2>&1 || { warn "config_validate: yq not on PATH yet — skipping"; return 0; }
  local rc=0 f msg
  for f in "$AI_STACK/services.yml" "$AI_STACK/installer/models.yml"; do
    [[ -f "$f" ]] || continue
    if ! yq -e '.' "$f" >/dev/null 2>&1; then
      msg="$(yq -e '.' "$f" 2>&1 | head -1)"
      err "Config does not parse as YAML: ${f#"$AI_STACK"/}"
      err "  ↳ ${msg:-invalid YAML}"
      err "  Fix it (often a stray quote or a missing ':'), then re-run."
      rc=1
    fi
  done
  # Structural sanity (only if the files parsed): the top-level maps the installer relies on.
  if (( rc == 0 )) && [[ -f "$AI_STACK/services.yml" ]]; then
    yq -e '.services | type == "!!map"' "$AI_STACK/services.yml" >/dev/null 2>&1 \
      || { err "services.yml: top-level '.services:' is missing or not a map."; rc=1; }
  fi
  if (( rc == 0 )) && [[ -f "$AI_STACK/installer/models.yml" ]]; then
    yq -e '.models | type == "!!map"' "$AI_STACK/installer/models.yml" >/dev/null 2>&1 \
      || { err "models.yml: top-level '.models:' is missing or not a map."; rc=1; }
  fi
  return $rc
}
