#!/usr/bin/env bash
# Phase 22 — cmux (native macOS terminal for parallel AI-agent sessions).
#
# cmux (https://github.com/manaflow-ai/cmux, GPL-3.0) is a native macOS app
# (Swift/AppKit, Ghostty-based terminal) for running many parallel AI-agent
# sessions in tabs, each with its own git/PR/port sidebar. It ships a `cmux
# notify` CLI you can wire into agent hooks (Claude Code, OpenCode, etc.).
#
# SHAPE — this is a HOST GUI app, NOT a container or daemon:
#   - There is NO service to start: the user launches cmux.app themselves.
#   - Installed via Homebrew Cask from the upstream tap. Confirmed from the
#     README (2026-05): `brew tap manaflow-ai/cmux` then
#     `brew install --cask cmux`. The cask is NOT in homebrew/cask core, so the
#     tap is required. Updates self-apply via Sparkle (or `brew upgrade --cask
#     cmux`).
#
# OPT-IN: not wired into the default `vz-ai-stack.sh install` run. Add it on demand
# with `bash vz-ai-stack.sh install 22`.
#
# IDEMPOTENT + RESILIENT: re-runnable. If a hard prerequisite is unmet (not
# macOS, no Homebrew, tap/cask unavailable, no network) it prints an actionable
# warning and exits 0 WITHOUT stamping, so a later re-run completes once the
# prerequisite is satisfied — it never leaves the system half-installed and
# never hard-fails on a soft/prereq problem.
#
# Standalone install: `bash vz-ai-stack.sh install 22`.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

PHASE=22
CMUX_TAP="manaflow-ai/cmux"
CMUX_CASK="cmux"
CMUX_APP="/Applications/cmux.app"

# True when cmux is already on the machine — either Homebrew knows the cask, or
# the app bundle is present (covers a manual / Sparkle-updated install too).
_cmux_installed() {
  if command -v brew >/dev/null 2>&1; then
    brew list --cask "$CMUX_CASK" >/dev/null 2>&1 && return 0
  fi
  [[ -d "$CMUX_APP" ]] && return 0
  return 1
}

precheck() {
  _cmux_installed
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 22 — cmux — already installed (cmux.app present)"
  exit 0
fi

hdr "Phase 22 — cmux (parallel AI-agent terminal, macOS)"

# --- 0. Hard prerequisites (soft-fail, non-stamping) ----------------------
# macOS only: cmux is a native AppKit app.
if [[ "$(uname -s)" != "Darwin" ]]; then
  warn "cmux is a native macOS app — this host is not macOS ($(uname -s))."
  warn "Skipping (non-fatal). Nothing was installed."
  exit 0
fi

# Already there? Stamp and finish (covers a manual install with no stamp yet).
if _cmux_installed; then
  ok "cmux already present (cmux.app / brew cask) — recording state."
  stamp_mark "$PHASE"
  record "phase 22: cmux already installed (no-op converge)"
  ok "Phase 22 — cmux — complete"
  note "Launch: open -a cmux   (or Spotlight → cmux)"
  note "Update: brew upgrade --cask $CMUX_CASK"
  exit 0
fi

# Homebrew required to install the cask.
if ! command -v brew >/dev/null 2>&1; then
  warn "Homebrew not found — needed to install the cmux cask."
  warn "Install it from https://brew.sh then re-run: bash vz-ai-stack.sh install $PHASE"
  exit 0
fi

# --- 1. Tap the upstream cask source --------------------------------------
# cmux lives in the manaflow-ai tap, not homebrew/cask core. Tapping is
# idempotent; a failure here is almost always no-network or a renamed tap, so
# warn + exit 0 (don't stamp) so a re-run picks it up later.
if ! brew tap 2>/dev/null | grep -qxi "$CMUX_TAP"; then
  log "Tapping $CMUX_TAP..."
  if ! brew tap "$CMUX_TAP" 2>&1 | tail -5; then
    warn "Failed to tap $CMUX_TAP (no network, or the tap was renamed/removed upstream)."
    warn "Check https://github.com/manaflow-ai/cmux for the current install steps,"
    warn "then re-run: bash vz-ai-stack.sh install $PHASE"
    exit 0
  fi
fi
ok "tap present: $CMUX_TAP"

# --- 2. Install the cask --------------------------------------------------
log "Installing cmux (cask) — this downloads the .app and may take a minute..."
if ! brew install --cask "$CMUX_CASK" 2>&1 | tail -8; then
  warn "brew install --cask $CMUX_CASK did not complete cleanly."
  warn "If it was a symlink/quarantine prompt, finish it manually, or try:"
  warn "    brew install --cask --force $CMUX_CASK"
  warn "Then re-run: bash vz-ai-stack.sh install $PHASE   (it will converge if cmux.app exists)."
  # Some cask failures still leave a working app; verify before giving up.
  if ! _cmux_installed; then
    exit 0
  fi
fi

# --- 3. Verify the install landed -----------------------------------------
if ! _cmux_installed; then
  warn "cmux does not appear installed after brew install (no cask record, no cmux.app)."
  warn "Re-run after resolving the brew output above: bash vz-ai-stack.sh install $PHASE"
  exit 0
fi
ok "cmux installed (cmux.app present)"

stamp_mark "$PHASE"
record "phase 22 complete: cmux cask installed from $CMUX_TAP (GUI app, no daemon)"
ok "Phase 22 — cmux — complete"
note "Launch:  open -a cmux   (or Spotlight → cmux)"
note "Update:  brew upgrade --cask $CMUX_CASK   (also self-updates via Sparkle)"
note "Hooks:   wire 'cmux notify' into your agent (Claude Code / OpenCode) hooks"
note "         to get a desktop ping when a session needs you."
