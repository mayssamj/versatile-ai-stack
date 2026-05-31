#!/usr/bin/env bash
# start-docs_mcp.sh — daemonize the MCP server that serves search_documents
# over HTTP on :8765 (alias docs-mcp / 127.0.10.4).
#
# Not a docker container — it's a host-side Python venv process. We use the
# venv at $AI_STACK/ingestor/.venv that Phase 06 built. The process binds
# 0.0.0.0:8765; the alias is reached via lo0 + /etc/hosts.
#
# Idempotency: refuses to start a second copy. Reads PID from
# installer/state/docs_mcp.pid; if that PID is alive AND the port is bound,
# no-op. Otherwise starts fresh.
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "bin/start-docs_mcp.sh: needs bash 5+" >&2; exit 2
fi

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/validate.sh"

INGESTOR="$AI_STACK/ingestor"
VENV="$INGESTOR/.venv"
MCP_SCRIPT="$INGESTOR/mcp_server.py"
PID_FILE="$STATE_DIR/docs_mcp.pid"
LOG_FILE="$STATE_DIR/docs_mcp.log"
PORT=8765

[[ -d "$VENV" ]]       || { err "venv missing at $VENV — run phase 06 first."; exit 1; }
[[ -f "$MCP_SCRIPT" ]] || { err "mcp_server.py missing at $MCP_SCRIPT — run phase 06 first."; exit 1; }
[[ -f "$AI_STACK/.env" ]] || { err ".env missing"; exit 1; }

# --- Already running? -------------------------------------------------------
# After reboot, PIDs are recycled — kill -0 alone could match an unrelated
# process. We confirm by checking the process command line includes
# mcp_server.py (the actual daemon entrypoint).
pid_is_ours() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  ps -p "$pid" -o command= 2>/dev/null | grep -qF "mcp_server.py" || return 1
  return 0
}

if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
  if pid_is_ours "$pid"; then
    if port_listening "$PORT"; then
      ok "docs_mcp already running (pid $pid, listening :$PORT)"
      exit 0
    fi
    warn "stale docs_mcp pid $pid alive but not bound to :$PORT — killing and restarting"
    kill "$pid" 2>/dev/null || true
    sleep 1
  else
    # PID stale or recycled to a different process — clear and continue.
    rm -f "$PID_FILE"
  fi
fi

# --- Refuse if something else owns :8765 -----------------------------------
if port_listening "$PORT"; then
  err "Port :$PORT is in use by another process (not the previous docs_mcp); refusing to start."
  err "Inspect: lsof -nP -iTCP:$PORT -sTCP:LISTEN"
  exit 1
fi

# --- Load .env into the child's environment ---------------------------------
# load_env_strict only VALIDATES (it doesn't export). We use get_env to
# explicitly read the values we need, then export each one.
load_env_strict || { err ".env has malformed lines — fix before starting docs_mcp"; exit 1; }
export LITELLM_BASE_URL="$(get_env LITELLM_BASE_URL http://litellm:4000)"
export QDRANT_URL="$(get_env QDRANT_URL http://qdrant:6333)"
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY)"
[[ -n "$LITELLM_MASTER_KEY" ]] || { err "LITELLM_MASTER_KEY missing in .env"; exit 1; }
export LITELLM_MASTER_KEY

log "Starting docs_mcp (FastMCP on 0.0.0.0:$PORT)..."
# Log file may contain Python tracebacks from the OpenAI SDK that print
# request headers including the Bearer token. Force 0600 from creation.
install -m 600 /dev/null "$LOG_FILE"

# Run in background; disown so it survives shell exit.
(
  cd "$INGESTOR"
  nohup "$VENV/bin/python" "$MCP_SCRIPT" >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
) </dev/null

sleep 2
pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
  err "docs_mcp failed to start. Last 20 log lines:"
  tail -n 20 "$LOG_FILE" >&2 || true
  exit 1
fi

# Wait up to 15s for the port to come up.
i=0
while (( i < 15 )); do
  if port_listening "$PORT"; then
    ok "docs_mcp running (pid $pid, http://docs-mcp:$PORT/)"
    exit 0
  fi
  sleep 1
  i=$((i+1))
done

err "docs_mcp pid $pid is alive but :$PORT didn't come up in 15s. Last log lines:"
tail -n 20 "$LOG_FILE" >&2 || true
exit 1
