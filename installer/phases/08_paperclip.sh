#!/usr/bin/env bash
# Phase 08 — Paperclip (personal task agent) + honcho plugin.
# Paperclip is a Node monorepo; we clone, pnpm install, and daemonize
# `pnpm dev` via bin/start-paperclip.sh so the API+UI on :3100 comes up
# automatically and the doctor's alias check passes.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/validate.sh"

PHASE=08
PC_DIR="$AI_STACK/tools/paperclip"
PID_FILE="$STATE_DIR/paperclip.pid"

# Precheck = everything Phase 08 is responsible for is already true:
#   1. repo cloned + deps installed
#   2. daemon running with a tracked PID + bound :3100 + serving HTTP
precheck() {
  [[ -d "$PC_DIR/.git" ]] || return 1
  [[ -d "$PC_DIR/node_modules" ]] || return 1
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # PID-recycle guard: confirm the live PID is actually our paperclip.
  ps -p "$pid" -o args= 2>/dev/null | grep -qF "$PC_DIR" || return 1
  port_listening 3100 || return 1
  # Use /api/health (paperclip's documented health endpoint); accept any
  # non-000 response as "alive" — startup may transiently return non-200.
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:3100/api/health 2>/dev/null || true)
  [[ "$code" != "000" ]] || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (paperclip up on :3100)"
  exit 0
fi

hdr "Phase 08 — Paperclip"

mkdir -p "$AI_STACK/tools"
if [[ ! -d "$PC_DIR/.git" ]]; then
  log "Cloning Paperclip (best effort)..."
  rm -rf "${PC_DIR}.partial"
  if git clone https://github.com/paperclipai/paperclip "${PC_DIR}.partial" 2>&1 | tail -5; then
    mv "${PC_DIR}.partial" "$PC_DIR"
    ok "cloned to $PC_DIR"
  else
    rm -rf "${PC_DIR}.partial"
    warn "Paperclip clone failed (upstream URL may differ). Place source at $PC_DIR and re-run."
    stamp_mark "$PHASE"
    ok "Phase 08 — Paperclip — stub complete (upstream-unreachable)"
    exit 0
  fi
fi

if command -v pnpm >/dev/null && [[ ! -d "$PC_DIR/node_modules" ]]; then
  log "pnpm install in $PC_DIR (first run; subsequent re-runs skip this)..."
  (cd "$PC_DIR" && pnpm install 2>&1 | tail -10) || warn "pnpm install exited non-zero"
fi

# Auto-start the daemon. start-paperclip.sh is itself idempotent — no-op
# when the PID file points at a live, healthy paperclip.
if [[ -x "$AI_STACK/bin/start-paperclip.sh" ]]; then
  bash "$AI_STACK/bin/start-paperclip.sh" \
    || warn "paperclip daemon start failed — see $STATE_DIR/paperclip.log"
else
  warn "$AI_STACK/bin/start-paperclip.sh missing — paperclip not auto-started"
fi

stamp_mark "$PHASE"
record "phase 08 complete: paperclip cloned + deps installed + daemon $(precheck 2>/dev/null && echo up || echo not-up)"
ok "Phase 08 — Paperclip — complete"
note "UI + API:  http://paperclip:3100  (or http://localhost:3100)"
note "Stop:      kill \$(cat $PID_FILE)"
note "Logs:      tail -f $STATE_DIR/paperclip.log"
