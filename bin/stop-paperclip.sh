#!/usr/bin/env bash
# stop-paperclip.sh — composite teardown: paperclip daemon + alias relay.
# `start paperclip` brings up BOTH the node daemon (paperclip.pid) and the alias
# relay (paperclip-relay.pid); the generic cmd_stop pidfile fallback would only
# stop the daemon, orphaning the relay. This script tears down both so the
# advertised `Stop: mayssam-ai-stack.sh stop paperclip` is truthful. Idempotent.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

stop_pidfile() {
  local label="$1" pidfile="$2"
  [[ -f "$pidfile" ]] || { ok "$label not running."; return 0; }
  local pid; pid="$(cat "$pidfile" 2>/dev/null || echo "")"
  if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
    rm -f "$pidfile"; note "$label not running (stale pidfile cleaned)."; return 0
  fi
  local pargs; pargs="$(ps -p "$pid" -o args= 2>/dev/null || echo "")"
  if [[ "$pargs" != *"paperclip"* && "$pargs" != *"$AI_STACK"* ]]; then
    warn "$label pid $pid doesn't look like ours (args: ${pargs:-<none>}) — NOT killing; cleaning pidfile."
    rm -f "$pidfile"; return 0
  fi
  log "Stopping $label (pid $pid)..."
  kill "$pid" 2>/dev/null || true
  local w=0; while (( w < 10 )) && kill -0 "$pid" 2>/dev/null; do sleep 0.5; w=$(( w + 1 )); done
  kill -0 "$pid" 2>/dev/null && { warn "$label pid $pid alive after TERM — KILL"; kill -9 "$pid" 2>/dev/null || true; }
  rm -f "$pidfile"; ok "Stopped $label (pid $pid)."
}

stop_pidfile "paperclip relay"  "$STATE_DIR/paperclip-relay.pid"
stop_pidfile "paperclip daemon" "$STATE_DIR/paperclip.pid"
ok "paperclip stopped (daemon + relay)."
