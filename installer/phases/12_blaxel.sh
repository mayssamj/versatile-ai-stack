#!/usr/bin/env bash
# Phase 12 — Blaxel (cloud-only). CLI install only; deploys are on demand.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

PHASE=12

precheck() {
  command -v bl >/dev/null 2>&1 || command -v blaxel >/dev/null 2>&1 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (blaxel CLI)"
  exit 0
fi

hdr "Phase 12 — Blaxel (cloud)"

# Blaxel ships a Go-based CLI ('bl') via Homebrew tap. The original install
# guide said npm '@blaxel/cli' which does not exist. The real CLI lives at
# github.com/blaxel-ai/toolkit and the macOS install path is:
#   brew tap blaxel-ai/blaxel && brew install blaxel
if ! command -v bl >/dev/null 2>&1 && ! command -v blaxel >/dev/null 2>&1; then
  if command -v brew >/dev/null; then
    log "Installing Blaxel toolkit via Homebrew tap (blaxel-ai/blaxel)..."
    # Trust the tap we are about to install FROM (idempotent; consent = this very
    # install). Without it, modern Homebrew REFUSES `brew upgrade/outdated blaxel`
    # ('untrusted tap'), so the upgrade funnel's brew method could neither
    # version-check nor upgrade it. Older brews without `brew trust` fall through.
    brew trust blaxel-ai/blaxel 2>/dev/null | tail -1 || true
    if brew tap blaxel-ai/blaxel 2>&1 | tail -3 && brew install blaxel 2>&1 | tail -5; then
      ok "blaxel CLI installed via brew"
    else
      warn "brew install blaxel failed — fallback: curl -fsSL https://raw.githubusercontent.com/blaxel-ai/toolkit/main/install.sh | sh"
    fi
  else
    warn "brew not on PATH; install blaxel CLI manually:"
    warn "  curl -fsSL https://raw.githubusercontent.com/blaxel-ai/toolkit/main/install.sh | sh"
  fi
fi

# Sanity-check keys
for k in BLAXEL_API_KEY BLAXEL_WORKSPACE; do
  v="$(get_env "$k" "")"
  if [[ -z "$v" ]]; then
    warn "$k is empty in .env — Blaxel commands will fail until set."
  fi
done

stamp_mark "$PHASE"
record "phase 12 complete: blaxel CLI installed (best-effort)"
ok "Phase 12 — Blaxel — complete"
note "Blaxel is cloud-only; no local services run. Use 'bl' / 'blaxel' on demand."
