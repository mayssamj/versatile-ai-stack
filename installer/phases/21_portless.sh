#!/usr/bin/env bash
# Phase 21 — portless (agent-aware local dev proxy). OPT-IN extra.
#
# portless (https://github.com/vercel-labs/portless, Apache-2.0) maps stable
# named HTTPS URLs (name.localhost) to local dev servers and ships a Claude Code
# skill (portless get/list) so an agent discovers the right URL instead of
# guessing ephemeral ports. Installed as a global npm CLI on the HOST.
#
# Node: upstream DECLARES engines node>=24, but npm's `engines` field is advisory
# (not enforced unless engine-strict=true) and portless runs fine under Node 22
# (verified on this host). So we install regardless and only print an ADVISORY
# when Node < 24. We do NOT upgrade Node here — the stack pins it elsewhere.
#
# Idempotency: precheck() passes once `portless` is on PATH and runnable.
# Standalone:  bash install.sh install 21   (or:  install.sh install portless)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

PHASE=21
PORTLESS_REC_NODE_MAJOR=24

# Running Node major (e.g. 22), or empty if absent/unparseable. Never fails.
_node_major() {
  command -v node >/dev/null 2>&1 || { printf ''; return 0; }
  local v; v="$(node -v 2>/dev/null)"; v="${v#v}"; v="${v%%.*}"
  [[ "$v" =~ ^[0-9]+$ ]] && printf '%s' "$v" || printf ''
}

# Done == the CLI is present AND actually runs. (Node version is an advisory,
# NOT a gate — so the phase converges on this Node-22 host instead of looping.)
precheck() {
  command -v portless >/dev/null 2>&1 || return 1
  portless --version >/dev/null 2>&1 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (portless on PATH)"
  exit 0
fi

hdr "Phase 21 — portless (agent-aware local dev proxy)"

# npm prerequisite — soft-fail (exit 0, no stamp) so a later re-run completes.
if ! command -v npm >/dev/null 2>&1; then
  warn "npm not on PATH — portless installs via 'npm install -g portless'."
  warn "Install Node.js (24+ recommended), then re-run: bash install.sh install portless"
  ok   "Phase 21 — skipped (npm unavailable); not stamped — re-run later."
  exit 0
fi

# Node advisory (NOT a gate).
NODE_MAJOR="$(_node_major)"
if [[ -n "$NODE_MAJOR" ]] && (( NODE_MAJOR < PORTLESS_REC_NODE_MAJOR )); then
  warn "portless recommends Node ${PORTLESS_REC_NODE_MAJOR}+; this host runs Node v${NODE_MAJOR}."
  warn "Installing anyway (npm 'engines' is advisory; portless runs under Node 22). If you"
  warn "hit runtime issues, select Node ${PORTLESS_REC_NODE_MAJOR}+ via a per-shell manager (nvm/fnm) —"
  warn "do NOT change the stack's pinned Node globally."
fi

# Install the global CLI (idempotent).
if command -v portless >/dev/null 2>&1; then
  ok "portless already on PATH — skipping npm install"
else
  log "Installing portless globally (npm install -g portless)..."
  if ! npm install -g portless; then
    err "npm install -g portless failed (check 'npm config get prefix' perms + network)."
    err "Not stamped — re-run: bash install.sh install portless"
    exit 0   # soft-fail: leave host clean for a retry
  fi
fi

# Verify the binary runs.
if ! command -v portless >/dev/null 2>&1; then
  warn "portless not on PATH after install — your npm global bin dir may not be in PATH."
  warn "Add \"\$(npm config get prefix)/bin\" to PATH, open a new shell, then re-run 'install.sh install portless'."
  ok   "Phase 21 — install ran but portless not visible; not stamped."
  exit 0
fi
PORTLESS_VERSION="$(portless --version 2>/dev/null | head -1 | tr -d '[:space:]')"
[[ -n "$PORTLESS_VERSION" ]] || PORTLESS_VERSION="unknown"
ok "portless installed (version: ${PORTLESS_VERSION})"

stamp_mark "$PHASE"
record "phase 21 complete: portless ${PORTLESS_VERSION} (global npm CLI; Node v${NODE_MAJOR:-?})"
ok "Phase 21 — portless — complete"
note "Behind a stable URL:  portless myapp 'npm run dev'   → https://myapp.localhost"
note "List routes: portless list    Trust the local CA (once): portless trust"
note "Ships a Claude Code skill (portless get/list) so agents resolve the right URL."
