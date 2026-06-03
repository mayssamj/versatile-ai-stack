#!/usr/bin/env bash
# Phase 14 — Unsloth Studio.
#
# Unsloth Studio is a local fine-tuning + training web UI from
# unslothai/unsloth. Supports MLX + GGUF inference and training on Apple
# Silicon. The official installer (curl|sh) drops a CLI shim at
# ~/.local/bin/unsloth that knows how to launch the web UI.
#
# This phase:
#   1. Detects existing install via `command -v unsloth` (or ~/.local/bin)
#   2. Runs the official install script if missing
#      (https://unsloth.ai/install.sh — 2400-line shell script that
#      uv/pip-installs the unsloth package; uses sudo only for apt on
#      Linux, never on macOS)
#   3. Daemonizes the studio via bin/start-unsloth.sh (idempotent)
#
# Standalone install: `bash vz-ai-stack.sh install 14`
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/validate.sh"

PHASE=14
PID_FILE="$STATE_DIR/unsloth.pid"

resolve_unsloth() {
  if command -v unsloth >/dev/null 2>&1; then command -v unsloth
  elif [[ -x "$HOME/.local/bin/unsloth" ]]; then echo "$HOME/.local/bin/unsloth"
  else echo ""
  fi
}

precheck() {
  # CLI installed?
  [[ -n "$(resolve_unsloth)" ]] || return 1
  # Daemon up + serving?
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  port_listening 8898 || return 1
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 http://127.0.0.1:8898/ 2>/dev/null || echo 000)
  [[ "$code" != "000" ]] || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (unsloth studio up on :8898)"
  exit 0
fi

hdr "Phase 14 — Unsloth Studio"

# --- Install the CLI if missing ---
UNSLOTH_BIN="$(resolve_unsloth)"
if [[ -z "$UNSLOTH_BIN" ]]; then
  log "Installing Unsloth Studio via the official curl|sh installer..."
  # The official script (https://unsloth.ai/install.sh) installs to
  # $UNSLOTH_STUDIO_HOME (default $HOME/.unsloth/studio) and adds the CLI
  # shim to $HOME/.local/bin. Total install can be ~1-3 GB (PyTorch + deps).
  # We trust the curl|sh because the user has explicitly opted in by
  # running this phase.
  if curl -fsSL https://unsloth.ai/install.sh 2>/dev/null | sh 2>&1 | tail -30; then
    ok "unsloth installer finished"
  else
    err "official installer failed — see https://github.com/unslothai/unsloth#install"
    exit 1
  fi
  # Re-resolve after install (the installer adds ~/.local/bin to PATH in a
  # rc file, but the current shell hasn't sourced it — look there directly).
  UNSLOTH_BIN="$(resolve_unsloth)"
  if [[ -z "$UNSLOTH_BIN" ]]; then
    err "installer ran but 'unsloth' is still not on PATH. Try:"
    err "  exec \$SHELL -l   # reload PATH"
    err "  or:  ls ~/.local/bin/unsloth"
    exit 1
  fi
fi

OS_VER="$("$UNSLOTH_BIN" --version 2>&1 | head -1 || echo "?")"
ok "unsloth CLI on PATH: $UNSLOTH_BIN ($OS_VER)"

# --- Daemonize the studio ---
if [[ -x "$AI_STACK/bin/start-unsloth.sh" ]]; then
  bash "$AI_STACK/bin/start-unsloth.sh" \
    || warn "unsloth daemon start failed — see $STATE_DIR/unsloth.log"
else
  warn "$AI_STACK/bin/start-unsloth.sh missing — unsloth not auto-started"
fi

stamp_mark "$PHASE"
record "phase 14 complete: unsloth studio installed + daemon $(precheck 2>/dev/null && echo up || echo not-up)"
ok "Phase 14 — Unsloth Studio — complete"
note "UI:    http://unsloth:8898  (or http://localhost:8898)"
note "Stop:  kill \$(cat $PID_FILE)"
note "Logs:  tail -f $STATE_DIR/unsloth.log"
note "Models land in: ~/.cache/huggingface/hub/  (clean with 'unsloth studio clean')"
