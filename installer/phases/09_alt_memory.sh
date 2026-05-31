#!/usr/bin/env bash
# Phase 09 — alternative memory plugins (installed-disabled).
#
# remnic-hermes is a Python LIBRARY (no executable entry points) — `uv tool
# install` fails with "No executables are provided". We pip-install it into
# a dedicated venv at $AI_STACK/alt-memory/.venv so it's importable when a
# downstream tool wants it.
#
# byterover-cli is a Node CLI (`brv`) published unscoped at
# campfirein/byterover-cli — the old guide's `@byterover/cli` 404s.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

PHASE=09
ALT_DIR="$AI_STACK/alt-memory"
ALT_VENV="$ALT_DIR/.venv"

precheck() {
  # Pass if the venv exists AND remnic-hermes is importable AND brv is on PATH.
  [[ -d "$ALT_VENV" ]] || return 1
  "$ALT_VENV/bin/python" -c 'import remnic_hermes' 2>/dev/null || return 1
  command -v brv >/dev/null 2>&1 || command -v byterover >/dev/null 2>&1 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (alt-memory)"
  exit 0
fi

hdr "Phase 09 — alternative memory plugins"

mkdir -p "$ALT_DIR"

if command -v uv >/dev/null; then
  # remnic-hermes is a library, not a CLI tool. Use a dedicated venv.
  if [[ ! -d "$ALT_VENV" ]]; then
    log "Creating venv at $ALT_VENV..."
    uv venv "$ALT_VENV" 2>&1 | tail -3 || warn "uv venv failed"
  fi
  log "uv pip install remnic-hermes (library; PyPI: joshuaswarren/remnic)..."
  uv pip install --python "$ALT_VENV/bin/python" remnic-hermes 2>&1 | tail -3 \
    || warn "remnic-hermes install failed — see https://github.com/joshuaswarren/remnic"
else
  warn "uv missing; skipping remnic-hermes"
fi

if command -v npm >/dev/null; then
  # Original install guide said @byterover/cli (404); the published package
  # is unscoped 'byterover-cli' at github.com/campfirein/byterover-cli —
  # the CLI binary is `brv` (formerly Cipher).
  log "npm install -g byterover-cli (CLI exposes 'brv'; was @byterover/cli per old guide)..."
  npm install -g byterover-cli 2>&1 | tail -3 \
    || warn "byterover-cli install failed — see https://github.com/campfirein/byterover-cli"
fi

stamp_mark "$PHASE"
record "phase 09 complete: alt-memory pkgs installed (disabled-by-default; remnic-hermes in $ALT_VENV, brv on PATH)"
ok "Phase 09 — alt-memory — complete"
note "remnic-hermes venv: $ALT_VENV"
note "byterover CLI:      brv --help"
