#!/usr/bin/env bash
# start-unsloth.sh — daemonize Unsloth Studio (local fine-tuning + training UI).
#
# Unsloth Studio is a Python+web-UI tool from unslothai/unsloth. The
# official installer (curl|sh) drops a CLI shim at ~/.local/bin/unsloth.
# `unsloth studio -p 8898 -H 0.0.0.0` brings up the web UI on port 8898
# bound to all interfaces — so both http://localhost:8898 and the
# alias http://unsloth:8898 (resolves to 127.0.10.16) reach it.
#
# macOS firewall blocks LAN ingress by default; same security profile
# as docs_mcp and paperclip.
#
# Idempotency: refuses to start a second copy. PID-recycle-safe via
# argv check (looks for "unsloth" + "studio" in the process command line).
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "bin/start-unsloth.sh: needs bash 5+" >&2; exit 2
fi

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/validate.sh"

PID_FILE="$STATE_DIR/unsloth.pid"
LOG_FILE="$STATE_DIR/unsloth.log"
PORT=8898

# Resolve the unsloth CLI. Official installer drops it at ~/.local/bin/unsloth.
resolve_unsloth() {
  if command -v unsloth >/dev/null 2>&1; then
    command -v unsloth
  elif [[ -x "$HOME/.local/bin/unsloth" ]]; then
    echo "$HOME/.local/bin/unsloth"
  else
    echo ""
  fi
}

UNSLOTH_BIN="$(resolve_unsloth)"
[[ -n "$UNSLOTH_BIN" ]] || { err "unsloth CLI not found — run phase 14 first."; exit 1; }

# --- Process identity check ---
pid_is_ours() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # Match any process whose command line contains 'unsloth' AND 'studio'
  # (avoids false-matching unrelated python processes).
  local args; args=$(ps -p "$pid" -o args= 2>/dev/null || echo "")
  [[ "$args" == *unsloth*studio* ]] || [[ "$args" == *unsloth*serve* ]] || return 1
  return 0
}

http_ok() {
  # curl -w '%{http_code}' already emits 000 on failure AND exits non-zero; the old
  # `... || echo 000` inside the substitution doubled it to "000000" != "000" → a dead
  # server read as HEALTHY. Fallback goes in a separate assignment. (2026-07-05 takeover.)
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1" 2>/dev/null) || code=000
  [[ "$code" =~ ^[0-9]{3}$ && "$code" != "000" ]]
}

# --- Already running + serving? Then no-op.
if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
  if pid_is_ours "$pid"; then
    if port_listening "$PORT" && http_ok "http://127.0.0.1:$PORT/"; then
      ok "unsloth studio already running (pid $pid, http://unsloth:$PORT)"
      exit 0
    fi
    warn "stale unsloth pid $pid alive but not serving — killing + restarting"
    kill "$pid" 2>/dev/null || true
    sleep 2
  else
    rm -f "$PID_FILE"
  fi
fi

# --- Refuse if port is held by something else.
if port_listening "$PORT"; then
  err "Port :$PORT is bound by another process."
  err "Inspect: lsof -nP -iTCP:$PORT -sTCP:LISTEN"
  exit 1
fi

install -m 600 /dev/null "$LOG_FILE"

log "Starting unsloth studio on 0.0.0.0:$PORT (background, logs → $LOG_FILE)..."
nohup "$UNSLOTH_BIN" studio -p "$PORT" -H 0.0.0.0 >> "$LOG_FILE" 2>&1 &
echo $! > "$PID_FILE"

sleep 2
pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
  err "unsloth studio failed to start. Last 20 log lines:"
  tail -n 20 "$LOG_FILE" >&2 || true
  exit 1
fi

# First launch downloads dependencies + does workspace setup; can be slow.
log "Waiting for unsloth studio to bind :$PORT (first launch can take 2-5 min)..."
i=0
while (( i < 300 )); do
  if port_listening "$PORT" && http_ok "http://127.0.0.1:$PORT/"; then
    ok "unsloth studio running (pid $pid, http://unsloth:$PORT/)"
    exit 0
  fi
  sleep 1
  i=$((i+1))
done

err "unsloth studio pid $pid alive but :$PORT didn't come up in 300s. Last log lines:"
tail -n 30 "$LOG_FILE" >&2 || true
exit 1
