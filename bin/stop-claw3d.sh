#!/usr/bin/env bash
# stop-claw3d.sh — composite teardown: UI + bridge.
# `start claw3d` brings up BOTH the UI (claw3d.pid) and the bridge
# (claw3d-bridge.pid); the generic cmd_stop pidfile fallback would only stop the
# UI, orphaning the bridge. This script (cmd_stop prefers bin/stop-<svc>.sh) tears
# down both, so the advertised `Stop: mayssam-ai-stack.sh stop claw3d` is truthful.
# Idempotent: missing/dead pidfiles are a clean no-op.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

# stop_pidfile <label> <pidfile> — graceful TERM→wait→KILL with an ownership
# guard (kill -0 proves alive, not ours; a recycled pid must not be killed).
stop_pidfile() {
  local label="$1" pidfile="$2"
  [[ -f "$pidfile" ]] || { ok "$label not running."; return 0; }
  local pid; pid="$(cat "$pidfile" 2>/dev/null || echo "")"
  if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pidfile"; note "$label not running (stale pidfile cleaned)."; return 0
  fi
  local pargs; pargs="$(ps -p "$pid" -o args= 2>/dev/null || echo "")"
  if [[ "$pargs" != *"claw3d"* && "$pargs" != *"$AI_STACK"* ]]; then
    warn "$label pid $pid doesn't look like ours (args: ${pargs:-<none>}) — NOT killing; cleaning pidfile."
    rm -f "$pidfile"; return 0
  fi
  log "Stopping $label (pid $pid)..."
  kill "$pid" 2>/dev/null || true
  local w=0; while (( w < 10 )) && kill -0 "$pid" 2>/dev/null; do sleep 0.5; w=$(( w + 1 )); done
  kill -0 "$pid" 2>/dev/null && { warn "$label pid $pid alive after TERM — KILL"; kill -9 "$pid" 2>/dev/null || true; }
  rm -f "$pidfile"; ok "Stopped $label (pid $pid)."
}

# UI first, then the bridge it depended on.
stop_pidfile "claw3d UI"     "$STATE_DIR/claw3d.pid"
stop_pidfile "claw3d-bridge" "$STATE_DIR/claw3d-bridge.pid"
ok "claw3d stopped (UI + bridge)."
