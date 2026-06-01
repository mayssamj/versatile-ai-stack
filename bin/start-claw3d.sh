#!/usr/bin/env bash
# start-claw3d.sh — daemonize the claw3d 3D agent-office UI (host Node service).
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

[[ -d "$CLAW_DIR" && -f "$CLAW_DIR/server/index.js" ]] || { err "claw3d not installed at $CLAW_DIR — run 'install.sh install 19'"; exit 1; }
[[ -d "$CLAW_DIR/node_modules" ]] || { err "claw3d node_modules missing — run 'install.sh install 19' (npm install)"; exit 1; }
command -v node >/dev/null || { err "node not on PATH — run phase 00"; exit 1; }

pid_is_ours() {
  local pid="$1"; [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o args= 2>/dev/null | grep -qF "$CLAW_DIR/server/index.js" \
    || ps -p "$pid" -o args= 2>/dev/null | grep -qF "$CLAW_DIR"
}
http_ok() { [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1" 2>/dev/null || echo 000)" != "000" ]]; }

if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
  if pid_is_ours "$pid" && http_ok "http://$CHECK_HOST:$PORT/"; then
    ok "claw3d already running (pid $pid, http://localhost:$PORT)"; exit 0
  fi
  pid_is_ours "$pid" && { kill "$pid" 2>/dev/null || true; sleep 2; }
  rm -f "$PID_FILE"
fi
if port_listening "$PORT"; then err "Port :$PORT bound by another process (lsof -nP -iTCP:$PORT)"; exit 1; fi

install -m 600 /dev/null "$LOG_FILE"
log "Starting claw3d (dev), binding $BIND_HOST:$PORT (open http://localhost:$PORT; first boot compiles, 30-90s)..."
( cd "$CLAW_DIR"
  PORT="$PORT" HOST="$BIND_HOST" nohup node server/index.js --dev >> "$LOG_FILE" 2>&1 &
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
