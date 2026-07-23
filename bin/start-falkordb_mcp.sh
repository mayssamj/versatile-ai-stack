#!/usr/bin/env bash
# start-falkordb_mcp.sh — managed launcher for the falkordb-mcp HTTP daemon.
#
# Host-loopback MCP server the HERMES FLEET dials (host.docker.internal:7083) to consume
# FalkorDB graph memory (Cypher via GRAPH.QUERY). Local clients (host Claude Code, Pi) use the
# stdio entrypoint (registered via `claude mcp add`), so they do NOT need this daemon. Raw
# falkordb:6379 stays denied to sandboxes — this token-gated shim is their only path.
#
# node-bg service: pid at $STATE_DIR/falkordb_mcp.pid so `mayssam-ai-stack.sh stop falkordb_mcp`
# tears it down. `start falkordb_mcp` is idempotent (already-healthy → report + exit 0).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

PORT="$(get_env FALKORDB_MCP_PORT '7083')"
TOKEN="$(get_env FALKORDB_MCP_TOKEN '')"
HOSTB="127.0.0.1"
PIDFILE="$STATE_DIR/falkordb_mcp.pid"
LOGFILE="$STATE_DIR/falkordb-mcp.log"
SHIM="$AI_STACK/falkordb-mcp/bin.mjs"

# Env the shim reads (per-key from .env; passed inline to the nohup below).
FALKORDB_URL="$(get_env FALKORDB_URL 'redis://falkordb:6379')"
FALKORDB_GRAPH="$(get_env FALKORDB_GRAPH 'fleet-memory')"
# Append-only audit of every graph_write (the destructive tool) → durable, operator-known path.
AUDIT_LOG="$(get_env FALKORDB_MCP_AUDIT_LOG "$STATE_DIR/falkordb-writes.jsonl")"

_alive() {
  local p
  [[ -f "$PIDFILE" ]] || return 1
  p="$(cat "$PIDFILE" 2>/dev/null)"; [[ -n "$p" ]] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  # PID-recycle guard: confirm it's actually our shim before treating it as the daemon.
  ps -p "$p" -o command= 2>/dev/null | grep -qF "$SHIM"
}
_health() { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://$HOSTB:$PORT/healthz" 2>/dev/null | grep -q '^200$'; }

if [[ ! -f "$SHIM" ]]; then
  err "falkordb-mcp shim missing ($SHIM) — run 'mayssam-ai-stack.sh install falkordb_mcp'."
  exit 1
fi
if [[ ! -d "$AI_STACK/falkordb-mcp/node_modules/@modelcontextprotocol/sdk" ]]; then
  err "falkordb-mcp deps missing — run 'mayssam-ai-stack.sh install falkordb_mcp' (npm install)."
  exit 1
fi
command -v node >/dev/null 2>&1 || { err "node not found on PATH"; exit 1; }

if _alive && _health; then
  ok "falkordb-mcp already running (pid $(cat "$PIDFILE")) on http://$HOSTB:$PORT/mcp"
  note "Stop: mayssam-ai-stack.sh stop falkordb_mcp"
  exit 0
fi
if _alive; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; sleep 1; fi
rm -f "$PIDFILE"

# Fail closed: the fleet reaches this over host.docker.internal, so an unauthenticated server
# is a real exposure. The shim refuses --http without a token; surface it here.
[[ -n "$TOKEN" ]] || { err "FALKORDB_MCP_TOKEN not set in .env — refusing to start (re-run 'mayssam-ai-stack.sh install falkordb_mcp' to mint one)."; exit 1; }

log "Starting falkordb-mcp (http) on $HOSTB:$PORT → graph '$FALKORDB_GRAPH' @ $FALKORDB_URL …"
FALKORDB_MCP_TOKEN="$TOKEN" \
FALKORDB_MCP_PORT="$PORT" \
FALKORDB_MCP_HOST="$HOSTB" \
FALKORDB_URL="$FALKORDB_URL" \
FALKORDB_GRAPH="$FALKORDB_GRAPH" \
FALKORDB_MCP_AUDIT_LOG="$AUDIT_LOG" \
nohup node "$SHIM" --http --port "$PORT" --host "$HOSTB" >>"$LOGFILE" 2>&1 &
echo $! > "$PIDFILE"

for _ in $(seq 1 25); do _health && break; sleep 0.2; done
if _health; then
  ok "falkordb-mcp up: http://$HOSTB:$PORT/mcp"
  note "Fleet reaches it at http://host.docker.internal:$PORT/mcp (wired per-profile by Phase 41)."
  note "Stop: mayssam-ai-stack.sh stop falkordb_mcp    Logs: $LOGFILE"
else
  err "falkordb-mcp did not become healthy on :$PORT — see $LOGFILE"
  tail -5 "$LOGFILE" 2>/dev/null || true
  exit 1
fi
