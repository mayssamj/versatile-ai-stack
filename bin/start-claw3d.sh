#!/usr/bin/env bash
# start-claw3d.sh — health-gated composite: bridge → UI.
#
# Starts the claw3d stack in two steps:
#   1. Start the claw3d↔agents bridge (bin/start-claw3d-bridge.sh, :7780).
#      Independently confirm /health is reachable before proceeding.
#      Abort with a clear error if the bridge does not become healthy in time —
#      avoids a "UI up, bridge dead, broken Connect" state.
#   2. Start the claw3d 3D agent-office UI (Next.js, :4310).
#
# claw3d (vendored at ~/ai-stack/claw3d) is a Next.js app started via
# `node server/index.js`. We run it in dev mode (no separate build step) bound
# to 127.0.0.1:<PORT>, pointed at the stack-agents bridge (custom HTTP runtime)
# via claw3d/.env. Open it at http://localhost:<PORT>. PID + log under
# installer/state. Config (.env / settings.json) is written by Phase 19.
set -Eeuo pipefail
if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
  echo "needs bash 5+" >&2; exit 2
fi
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/validate.sh"

CLAW_DIR="$AI_STACK/claw3d"
PID_FILE="$STATE_DIR/claw3d.pid"
LOG_FILE="$STATE_DIR/claw3d.log"
# Bind 127.0.0.1 (localhost-only). claw3d REFUSES to bind a public host like
# 0.0.0.0 without STUDIO_ACCESS_TOKEN (its own security stance), and the bridge is
# loopback-only by design too — so neither host service gets an /etc/hosts alias;
# they are intentionally local-only. Open the UI at http://localhost:4310.
BIND_HOST="${CLAW3D_HOST:-127.0.0.1}"
CHECK_HOST=127.0.0.1
PORT="${CLAW3D_PORT:-4310}"
BRIDGE_PORT="${CLAW3D_BRIDGE_PORT:-7780}"
# Timeout (seconds) for the composite health-gate on the bridge before aborting.
BRIDGE_HEALTH_TIMEOUT=30

[[ -d "$CLAW_DIR" && -f "$CLAW_DIR/server/index.js" ]] || { err "claw3d not installed at $CLAW_DIR — run 'vz-ai-stack.sh install 19'"; exit 1; }
[[ -d "$CLAW_DIR/node_modules" ]] || { err "claw3d node_modules missing — run 'vz-ai-stack.sh install 19' (npm install)"; exit 1; }
command -v node >/dev/null || { err "node not on PATH — run phase 00"; exit 1; }

pid_is_ours() {
  local pid="$1"; [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o args= 2>/dev/null | grep -qF "$CLAW_DIR/server/index.js" \
    || ps -p "$pid" -o args= 2>/dev/null | grep -qF "$CLAW_DIR"
}
# http_ok <url> — true ONLY on a 2xx/3xx response (the UI redirects 307, so accept
# 3xx). The old `!= "000"` form was broken: on connection-refused curl prints "000"
# AND exits non-zero, so `|| echo 000` appended a second "000" → "000000" != "000"
# → it reported a DOWN service as healthy, silently defeating the composite gate.
http_ok() { local code; code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1" 2>/dev/null)" || code="000"; [[ "$code" =~ ^[23] ]]; }

# --- --recreate / restart: stop the pidfile-owned UI FIRST, then fall through
# to the normal composite start (bridge health-gate included). Council R2a: a
# post-upgrade "restart" must actually recycle the daemon — this script used to
# ignore all arguments and no-op exit 0 when healthy, so an upgraded clone kept
# serving stale code while the summary said 'upgraded'. (2026-07-15)
if [[ "${1:-}" == "--recreate" || "${1:-}" == "restart" ]]; then
  if [[ -f "$PID_FILE" ]]; then
    _rpid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
    if pid_is_ours "$_rpid"; then
      log "recreate: stopping claw3d UI (pid $_rpid)"
      kill "$_rpid" 2>/dev/null || true
      _i=0
      while (( _i < 10 )) && kill -0 "$_rpid" 2>/dev/null; do sleep 1; _i=$((_i+1)); done
      if kill -0 "$_rpid" 2>/dev/null; then kill -9 "$_rpid" 2>/dev/null || true; sleep 1; fi
    fi
    rm -f "$PID_FILE"
  fi
fi

# --- Idempotency: if the UI is already running, confirm the bridge is healthy too
# (the composite invariant: never leave UI-up / bridge-dead → broken Connect).
# UI up + bridge healthy → done. UI up + bridge dead → (re)start ONLY the bridge,
# leaving the UI intact. UI down → fall through to the full composite start. ---
if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
  if pid_is_ours "$pid" && http_ok "http://$CHECK_HOST:$PORT/"; then
    if http_ok "http://127.0.0.1:${BRIDGE_PORT}/health"; then
      ok "claw3d already running (pid $pid, http://localhost:$PORT)"; exit 0
    fi
    warn "claw3d UI up (pid $pid) but bridge :$BRIDGE_PORT is unhealthy — (re)starting the bridge..."
    CLAW3D_BRIDGE_PORT="$BRIDGE_PORT" bash "$AI_STACK/bin/start-claw3d-bridge.sh" \
      || { err "bridge restart failed; UI left running but Connect will be broken."; exit 1; }
    if http_ok "http://127.0.0.1:${BRIDGE_PORT}/health"; then
      ok "claw3d already running (pid $pid); bridge restored on :$BRIDGE_PORT"; exit 0
    fi
    err "bridge still unhealthy on :$BRIDGE_PORT after restart — check $STATE_DIR/claw3d-bridge.log"; exit 1
  fi
  pid_is_ours "$pid" && { kill "$pid" 2>/dev/null || true; sleep 2; }
  rm -f "$PID_FILE"
fi

# --- Step 1: Start the bridge (idempotent — safe to call when already up) ---
log "Starting claw3d-bridge (health-gated, :$BRIDGE_PORT)..."
CLAW3D_BRIDGE_PORT="$BRIDGE_PORT" bash "$AI_STACK/bin/start-claw3d-bridge.sh" \
  || { err "claw3d-bridge start script returned non-zero; aborting composite start."; exit 1; }

# --- Step 1b: Composite health-gate — confirm bridge /health independently ---
# The bridge script already self-checks, but the composite must verify before
# proceeding so we never reach the UI launch with a dead bridge.
log "Confirming bridge /health on :$BRIDGE_PORT (timeout ${BRIDGE_HEALTH_TIMEOUT}s)..."
_bridge_i=0
while (( _bridge_i < BRIDGE_HEALTH_TIMEOUT )); do
  if http_ok "http://127.0.0.1:${BRIDGE_PORT}/health"; then
    ok "claw3d-bridge healthy on :$BRIDGE_PORT"
    break
  fi
  sleep 1; _bridge_i=$(( _bridge_i + 1 ))
done
if ! http_ok "http://127.0.0.1:${BRIDGE_PORT}/health"; then
  err "claw3d bridge failed to come up on :${BRIDGE_PORT}/health — not starting the UI to avoid a broken Connect"
  err "Check bridge log: $STATE_DIR/claw3d-bridge.log"
  exit 1
fi

# --- Step 2: Start the UI (:4310) ---
if port_listening "$PORT"; then err "Port :$PORT bound by another process (lsof -nP -iTCP:$PORT)"; exit 1; fi

install -m 600 /dev/null "$LOG_FILE"
log "Starting claw3d (dev), binding $BIND_HOST:$PORT (open http://localhost:$PORT; first boot compiles, 30-90s)..."
( cd "$CLAW_DIR"
  # Launch with the ABSOLUTE script path (not the relative `server/index.js`) so
  # `ps -o args` records the full path — this is what pid_is_ours greps for on the
  # idempotency re-check. With a relative launch, `ps args` shows only
  # `node server/index.js`, pid_is_ours never matches, and a 2nd `start claw3d`
  # deletes the pidfile + errors on the bound port (orphaning the live UI).
  PORT="$PORT" HOST="$BIND_HOST" nohup node "$CLAW_DIR/server/index.js" --dev >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
) </dev/null
sleep 2
pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
[[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null || { err "claw3d failed to start. Last log:"; tail -n 20 "$LOG_FILE" >&2 || true; exit 1; }
i=0; while (( i < 180 )); do
  port_listening "$PORT" && http_ok "http://$CHECK_HOST:$PORT/" && { ok "claw3d running (pid $pid) → open http://localhost:$PORT"; exit 0; }
  sleep 1; i=$((i+1))
done
err "claw3d pid $pid alive but :$PORT didn't serve in 180s. Last log:"; tail -n 30 "$LOG_FILE" >&2 || true; exit 1
