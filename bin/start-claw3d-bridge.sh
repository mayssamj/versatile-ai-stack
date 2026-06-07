#!/usr/bin/env bash
# start-claw3d-bridge.sh — daemonize the claw3d↔agents bridge (host service).
#
# The bridge (claw3d-bridge/bridge.py, stdlib-only) implements claw3d's custom
# HTTP runtime contract and routes chat to the real sandboxed agents (Hermes
# profiles, Pi) + DeerFlow. Consumed by the claw3d UI server-side over
# 127.0.0.1, so it needs no /etc/hosts alias. PID + log under installer/state.
set -Eeuo pipefail
if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
  echo "needs bash 5+" >&2; exit 2
fi
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/validate.sh"

BRIDGE="$AI_STACK/claw3d-bridge/bridge.py"
PID_FILE="$STATE_DIR/claw3d-bridge.pid"
LOG_FILE="$STATE_DIR/claw3d-bridge.log"
HOST=127.0.0.1
PORT="${CLAW3D_BRIDGE_PORT:-7780}"

[[ -f "$BRIDGE" ]] || { err "bridge missing at $BRIDGE"; exit 1; }
command -v python3 >/dev/null || { err "python3 not on PATH"; exit 1; }

pid_is_ours() {
  local pid="$1"; [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o args= 2>/dev/null | grep -qF "claw3d-bridge/bridge.py"
}
# http_ok <url> — true ONLY on a 2xx/3xx response. The old `!= "000"` form reported
# a DOWN service as healthy: on connection-refused, curl prints "000" AND exits
# non-zero, so `|| echo 000` appended a second "000" → "000000" != "000" → true.
# That made the bridge's own self-health-check pass even when it never came up.
http_ok() { local code; code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1" 2>/dev/null)" || code="000"; [[ "$code" =~ ^[23] ]]; }

# Idempotent re-entry.
if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
  if pid_is_ours "$pid" && http_ok "http://$HOST:$PORT/health"; then
    ok "claw3d-bridge already running (pid $pid, http://$HOST:$PORT)"; exit 0
  fi
  pid_is_ours "$pid" && { kill "$pid" 2>/dev/null || true; sleep 1; }
  rm -f "$PID_FILE"
fi
if port_listening "$PORT"; then err "Port :$PORT bound by another process (lsof -nP -iTCP:$PORT)"; exit 1; fi

install -m 600 /dev/null "$LOG_FILE"
# DeerFlow internal-auth token (optional) passed through if present in .env.
DF_AUTH="$(grep -E '^DEER_FLOW_INTERNAL_AUTH_TOKEN=' "$AI_STACK/.env" 2>/dev/null | cut -d= -f2- || true)"
log "Starting claw3d-bridge on http://$HOST:$PORT ..."
( cd "$AI_STACK"
  CLAW3D_BRIDGE_HOST="$HOST" CLAW3D_BRIDGE_PORT="$PORT" DEER_FLOW_INTERNAL_AUTH_TOKEN="$DF_AUTH" \
    nohup python3 "$BRIDGE" >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
) </dev/null
sleep 1.5
pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
i=0; while (( i < 15 )); do
  http_ok "http://$HOST:$PORT/health" && { ok "claw3d-bridge running (pid $pid, http://$HOST:$PORT)"; exit 0; }
  sleep 1; i=$((i+1))
done
err "claw3d-bridge failed to serve on :$PORT. Last log:"; tail -n 15 "$LOG_FILE" >&2 || true; exit 1
