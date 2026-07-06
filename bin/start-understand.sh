#!/usr/bin/env bash
# start-understand.sh — managed launcher for the understand-mcp HTTP daemon.
#
# This is the host-loopback MCP server the HERMES FLEET dials (host.docker.internal
# :7081) to consume the committed knowledge graph. Local clients (host Claude Code,
# Pi) use the stdio entrypoint instead (registered via `claude mcp add`), so they do
# NOT need this daemon — but it's harmless to run.
#
# Bound to 127.0.0.1 only (loopback ⇒ no auth surface off-box; the fleet reaches it
# via the engine's host.docker.internal mapping, gated by a token in .env). Read-only:
# it only reads the graph + source under $AI_STACK; no writes, no LLM, no egress.
#
# node-bg service: pid recorded at $STATE_DIR/understand.pid so `vz-ai-stack.sh stop
# understand` (cmd_stop's pidfile fallback) tears it down. `start understand` is
# idempotent (already-healthy → report + exit 0).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

PORT="$(get_env UNDERSTAND_MCP_PORT '7081')"
TOKEN="$(get_env UNDERSTAND_MCP_TOKEN '')"
HOSTB="127.0.0.1"
PIDFILE="$STATE_DIR/understand.pid"
LOGFILE="$STATE_DIR/understand-mcp.log"
SHIM="$AI_STACK/understand-mcp/bin.mjs"

# Resolve the plugin root (built by Phase 30; stable symlink preferred).
PLUGIN_ROOT="${UNDERSTAND_PLUGIN_ROOT:-$HOME/.understand-anything-plugin}"

_alive() {
  local p
  [[ -f "$PIDFILE" ]] || return 1
  p="$(cat "$PIDFILE" 2>/dev/null)"; [[ -n "$p" ]] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  # PID-recycle guard (mirrors start-docs_mcp.sh's pid_is_ours): after a reboot a
  # recycled PID can pass kill -0 while being an UNRELATED process. Confirm it is
  # actually our node shim before treating it as the daemon — and, critically, before
  # the `if _alive; then kill …` below SIGTERMs it. (2026-07-05 takeover fix.)
  ps -p "$p" -o command= 2>/dev/null | grep -qF "$SHIM"
}
_health() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$HOSTB:$PORT/healthz" 2>/dev/null | grep -q '^200$'; }

if [[ ! -f "$SHIM" ]]; then
  err "understand-mcp shim missing ($SHIM) — run 'vz-ai-stack.sh install understand'."
  exit 1
fi
if [[ ! -x "$(command -v node)" ]]; then err "node not found on PATH"; exit 1; fi

if _alive && _health; then
  ok "understand-mcp already running (pid $(cat "$PIDFILE")) on http://$HOSTB:$PORT/mcp"
  note "Stop: vz-ai-stack.sh stop understand"
  exit 0
fi
# Clean a stale pidfile / half-up process.
if _alive; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; sleep 1; fi
rm -f "$PIDFILE"

log "Starting understand-mcp (http) on $HOSTB:$PORT …"
# Fail closed: the fleet reaches this over host.docker.internal, so an unauthenticated
# server is a real exposure. The server refuses --http without a token; surface it here.
[[ -n "$TOKEN" ]] || { err "UNDERSTAND_MCP_TOKEN not set in .env — refusing to start (re-run 'vz-ai-stack.sh install understand' to mint one)."; exit 1; }

UNDERSTAND_PLUGIN_ROOT="$PLUGIN_ROOT" \
UNDERSTAND_GRAPH_ROOT="$AI_STACK" \
UNDERSTAND_SOURCE_ROOT="$AI_STACK" \
UNDERSTAND_MCP_TOKEN="$TOKEN" \
nohup node "$SHIM" --http --port "$PORT" --host "$HOSTB" >>"$LOGFILE" 2>&1 &
echo $! > "$PIDFILE"

# Health-gate (server prints readiness to stderr→log; poll /healthz).
for _ in $(seq 1 25); do _health && break; sleep 0.2; done
if _health; then
  ok "understand-mcp up: http://$HOSTB:$PORT/mcp  (graph from $AI_STACK/.understand-anything/)"
  note "Fleet reaches it at http://host.docker.internal:$PORT/mcp (wired per-profile by Phase 30)."
  note "Stop: vz-ai-stack.sh stop understand    Logs: $LOGFILE"
else
  err "understand-mcp did not become healthy on :$PORT — see $LOGFILE"
  tail -5 "$LOGFILE" 2>/dev/null || true
  exit 1
fi
