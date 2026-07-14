#!/usr/bin/env bash
# start-honcho_mcp.sh — managed launcher for the honcho-mcp HTTP daemon.
#
# This is the host-loopback MCP server the HERMES FLEET dials (host.docker.internal
# :7082) to consume Honcho memory. Local clients (host Claude Code, Pi) use the stdio
# entrypoint instead (registered via `claude mcp add`), so they do NOT need this daemon.
#
# Bound to 127.0.0.1 only; the fleet reaches it via the engine's host.docker.internal
# mapping, gated by HONCHO_MCP_TOKEN in .env. Once Phase 40 retires the raw honcho:8000
# sandbox egress, THIS shim is the only in-sandbox path to Honcho.
#
# node-bg service: pid at $STATE_DIR/honcho_mcp.pid so `vz-ai-stack.sh stop honcho_mcp`
# (cmd_stop's pidfile fallback) tears it down. `start honcho_mcp` is idempotent
# (already-healthy → report + exit 0).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

PORT="$(get_env HONCHO_MCP_PORT '7082')"
TOKEN="$(get_env HONCHO_MCP_TOKEN '')"
HOSTB="127.0.0.1"
PIDFILE="$STATE_DIR/honcho_mcp.pid"
LOGFILE="$STATE_DIR/honcho-mcp.log"
SHIM="$AI_STACK/honcho-mcp/bin.mjs"

# Env the shim reads (per-key from .env; passed inline to the nohup below).
HONCHO_BASE_URL="$(get_env HONCHO_BASE_URL 'http://honcho:8000')"
HONCHO_WORKSPACE_ID="$(get_env HONCHO_WORKSPACE_ID 'default')"
HONCHO_API_KEY="$(get_env HONCHO_API_KEY '')"

_alive() {
  local p
  [[ -f "$PIDFILE" ]] || return 1
  p="$(cat "$PIDFILE" 2>/dev/null)"; [[ -n "$p" ]] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  # PID-recycle guard (mirrors start-understand.sh): confirm it's actually our shim
  # before treating it as the daemon — and before the kill below SIGTERMs it.
  ps -p "$p" -o command= 2>/dev/null | grep -qF "$SHIM"
}
_health() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$HOSTB:$PORT/healthz" 2>/dev/null | grep -q '^200$'; }

if [[ ! -f "$SHIM" ]]; then
  err "honcho-mcp shim missing ($SHIM) — run 'vz-ai-stack.sh install honcho_mcp'."
  exit 1
fi
if [[ ! -d "$AI_STACK/honcho-mcp/node_modules/@modelcontextprotocol/sdk" ]]; then
  err "honcho-mcp deps missing — run 'vz-ai-stack.sh install honcho_mcp' (npm install)."
  exit 1
fi
command -v node >/dev/null 2>&1 || { err "node not found on PATH"; exit 1; }

if _alive && _health; then
  ok "honcho-mcp already running (pid $(cat "$PIDFILE")) on http://$HOSTB:$PORT/mcp"
  note "Stop: vz-ai-stack.sh stop honcho_mcp"
  exit 0
fi
if _alive; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; sleep 1; fi
rm -f "$PIDFILE"

# Fail closed: the fleet reaches this over host.docker.internal, so an unauthenticated
# server is a real exposure. The shim refuses --http without a token; surface it here.
[[ -n "$TOKEN" ]] || { err "HONCHO_MCP_TOKEN not set in .env — refusing to start (re-run 'vz-ai-stack.sh install honcho_mcp' to mint one)."; exit 1; }

log "Starting honcho-mcp (http) on $HOSTB:$PORT → $HONCHO_BASE_URL (workspace $HONCHO_WORKSPACE_ID) …"
HONCHO_MCP_TOKEN="$TOKEN" \
HONCHO_MCP_PORT="$PORT" \
HONCHO_MCP_HOST="$HOSTB" \
HONCHO_BASE_URL="$HONCHO_BASE_URL" \
HONCHO_WORKSPACE_ID="$HONCHO_WORKSPACE_ID" \
HONCHO_API_KEY="$HONCHO_API_KEY" \
nohup node "$SHIM" --http --port "$PORT" --host "$HOSTB" >>"$LOGFILE" 2>&1 &
echo $! > "$PIDFILE"

for _ in $(seq 1 25); do _health && break; sleep 0.2; done
if _health; then
  ok "honcho-mcp up: http://$HOSTB:$PORT/mcp"
  note "Fleet reaches it at http://host.docker.internal:$PORT/mcp (wired per-profile by Phase 40)."
  note "Stop: vz-ai-stack.sh stop honcho_mcp    Logs: $LOGFILE"
else
  err "honcho-mcp did not become healthy on :$PORT — see $LOGFILE"
  tail -5 "$LOGFILE" 2>/dev/null || true
  exit 1
fi
