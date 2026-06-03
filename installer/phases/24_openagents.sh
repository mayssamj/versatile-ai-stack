#!/usr/bin/env bash
# Phase 24 — OpenAgents Launcher (OPT-IN; host tool, not a container).
#
# OpenAgents (openagents.org/launcher; repo openagents-org/openagents, Apache-2.0)
# bills itself as "Ollama for AI agents": a launcher/dashboard with a CLI (`agn`)
# that installs and manages coding agents from one place.
#
# WHY OPT-IN + WHY IT OVERLAPS THIS STACK:
#   OpenAgents is a COMPETING orchestration layer. It ships:
#     - its own installer (curl|bash → portable Node under ~/.openagents),
#     - its own agent-management / launcher CLI (`agn`), and
#     - its own Workspace UI.
#   That duplicates what this stack already does (Phase 04 OpenShell isolation,
#   the Hermes fleet, AutoFyn, the Open WebUI / claw3d front-ends). We install
#   it ONLY when explicitly requested (`vz-ai-stack.sh install 24`) and we do NOT
#   wire it into LiteLLM, the sandboxes, or any front-end. It lives entirely in
#   its own ~/.openagents prefix and is yours to drive by hand. Treat it as an
#   evaluation sandbox, not a load-bearing piece of the stack.
#
# WHAT THIS PHASE DOES (idempotent):
#   1. Verifies platform (macOS arm64 is the supported target here; anything
#      else → clear warning + non-fatal exit 0, NO stamp, so a later re-run on
#      the right host completes).
#   2. Downloads the official installer to a temp file (mktemp) and runs THAT
#      file — never a blind `curl | bash`. See the supply-chain note below.
#   3. Verifies `agn` is resolvable afterward (the installer drops it under
#      ~/.openagents/nodejs/node_modules/.bin and appends a PATH line to your
#      shell rc — so it may not be on *this* shell's PATH yet; we look it up
#      directly and tell you how to load it).
#
# SUPPLY-CHAIN CAVEAT: piping a remote script straight into a shell
# (`curl … | bash`) executes whatever the server returns, sight-unseen, with no
# on-disk artifact to inspect or pin. We at least MATERIALIZE the script to a
# temp file first so it's a real, reviewable file before it runs. This is NOT a
# substitute for pinning a checksum — upstream serves the script from a redirect
# to GitHub `develop` and does not publish a checksum, so the bytes can change
# between runs. On any abnormal exit (bad content / installer failure) the phase
# PRESERVES the downloaded file (clears the cleanup trap) so you can inspect what
# was served; on success it's removed. Not a substitute for a pinned checksum —
# vendor a pinned copy if you care. This is exactly why the phase is opt-in.
#
# We do NOT install or wire any LLM stage here: OpenAgents manages its own
# agents and we keep it OFFLINE from our LiteLLM/Phoenix plane on purpose.
#
# Standalone install: `bash vz-ai-stack.sh install 24`.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

PHASE=24
OPENAGENTS_INSTALL_URL="https://openagents.org/install.sh"
OPENAGENTS_PREFIX="$HOME/.openagents"
OPENAGENTS_BIN_DIR="$OPENAGENTS_PREFIX/nodejs/node_modules/.bin"

# Resolve the `agn` binary whether or not it's on the current shell's PATH.
# The installer appends a PATH line to your rc file, which a non-login installer
# shell won't have sourced — so check the known prefix too.
resolve_agn() {
  if command -v agn >/dev/null 2>&1; then command -v agn; return 0; fi
  if [[ -x "$OPENAGENTS_BIN_DIR/agn" ]]; then echo "$OPENAGENTS_BIN_DIR/agn"; return 0; fi
  return 1
}

precheck() {
  resolve_agn >/dev/null 2>&1
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 24 — OpenAgents Launcher — already installed ($(resolve_agn))"
  exit 0
fi

hdr "Phase 24 — OpenAgents Launcher (opt-in; overlaps this stack)"

# --- 0. Prereq: platform check (macOS arm64) ------------------------------
# Upstream macOS arm64 support was UNVERIFIED at authoring time. The installer
# DOES branch on `uname -m` and pull a darwin-arm64 portable Node, so arm64 is
# the supported target here. On anything else we bail NON-FATALLY without
# stamping, so re-running on a supported host completes cleanly.
OS="$(uname -s)"
ARCH="$(uname -m)"
if [[ "$OS" != "Darwin" || "$ARCH" != "arm64" ]]; then
  warn "OpenAgents phase targets macOS arm64; this host is ${OS}/${ARCH}."
  warn "Skipping (non-fatal). Re-run 'vz-ai-stack.sh install 24' on a supported host."
  exit 0
fi

# --- 0b. Prereq: network reachable + curl present -------------------------
if ! command -v curl >/dev/null 2>&1; then
  warn "curl not on PATH — cannot fetch the OpenAgents installer. Skipping (non-fatal)."
  exit 0
fi

# --- 1. Materialize the installer to a temp file, then run THAT file ------
# (Deliberately NOT `curl … | bash` — see the supply-chain caveat in the header.)
INSTALLER_TMP="$(mktemp "${TMPDIR:-/tmp}/openagents-install.XXXXXX.sh")" || {
  warn "could not create a temp file for the installer. Skipping (non-fatal)."
  exit 0
}
# Best-effort cleanup; keep it on a hard failure path too.
trap 'rm -f "$INSTALLER_TMP"' EXIT

log "Downloading the OpenAgents installer to a temp file (materialized, not piped)..."
if ! curl -fsSL -o "$INSTALLER_TMP" "$OPENAGENTS_INSTALL_URL"; then
  warn "failed to download $OPENAGENTS_INSTALL_URL (network down or URL moved)."
  warn "Skipping (non-fatal) — nothing was installed. Re-run 'vz-ai-stack.sh install 24' later."
  exit 0
fi
# Sanity: must START with a shell shebang AND must not be HTML. (The looser
# "contains the word install" sniff false-passed on product/error HTML pages.)
if [[ ! -s "$INSTALLER_TMP" ]] \
   || ! head -c 64 "$INSTALLER_TMP" | grep -qE '^#!.*sh' \
   || head -c 512 "$INSTALLER_TMP" | grep -qiE '<!doctype|<html|<head|<body'; then
  warn "downloaded installer doesn't look like a shell script (HTML / error page?)."
  trap - EXIT   # preserve the artifact so you can inspect what was served
  warn "Skipping (non-fatal). Inspect the downloaded file: $INSTALLER_TMP"
  exit 0
fi
ok "installer materialized at $INSTALLER_TMP (review it there before/while it runs)"

log "Running the OpenAgents installer (drops a portable Node + 'agn' under ~/.openagents)..."
# Do NOT abort the whole phase if the upstream installer fails — it may need
# interaction, fail on an unsupported variant, or change shape. On failure we
# warn and exit 0 WITHOUT stamping, so the system is never left half-broken and
# a later re-run can complete.
if ! bash "$INSTALLER_TMP"; then
  warn "the OpenAgents installer exited non-zero — it may be unsupported on this host"
  warn "or need interactive input. Nothing was stamped. Skipping (non-fatal)."
  trap - EXIT   # preserve the installer for inspection
  warn "Inspect the installer at: $INSTALLER_TMP   (or see $OPENAGENTS_INSTALL_URL)"
  exit 0
fi

# --- 2. Verify `agn` is present -------------------------------------------
AGN="$(resolve_agn 2>/dev/null || true)"
if [[ -z "$AGN" ]]; then
  warn "OpenAgents installer finished but 'agn' was not found on PATH or under"
  warn "  $OPENAGENTS_BIN_DIR"
  warn "Not stamping. Open a new shell (the installer edits your rc) and re-run"
  warn "  'vz-ai-stack.sh install 24' to verify."
  exit 0
fi

stamp_mark "$PHASE"
record "phase 24 complete: OpenAgents Launcher installed (agn at $AGN); opt-in, NOT wired into LiteLLM/sandboxes/UIs"
ok "Phase 24 — OpenAgents Launcher — complete (agn: $AGN)"
note "Open a NEW shell (the installer appended a PATH line to your rc), then:"
note "    agn            # launch the OpenAgents dashboard"
note "Or run it directly without reloading your shell:"
note "    $AGN"
warn "Heads-up: OpenAgents is its own agent orchestrator + Workspace UI and"
warn "OVERLAPS this stack (OpenShell/Hermes/AutoFyn/Open WebUI). It is NOT wired"
warn "into LiteLLM, the sandboxes, or any front-end here — it lives in ~/.openagents."
