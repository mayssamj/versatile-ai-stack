#!/usr/bin/env bash
# Phase 00 — host preparation.
# Installs brew packages, creates the directory tree, writes a starter .env,
# verifies tooling, locks .env permissions, probes host.docker.internal.
#
# Idempotent: re-running on a fully-prepared host is a no-op + ✓ message.
set -Eeuo pipefail

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker-engine.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/validate.sh"
source "$AI_STACK/installer/lib/deps.sh"

PHASE=00
precheck() {
  # What "done" looks like for phase 00:
  # - brew + all required formulae installed (bash 5+, yq, jq, node, pnpm, uv, git, tesseract, openssl, orbstack)
  # - directory tree exists
  # - .env exists, mode 0600, all required keys present (may be empty)
  # - host.docker.internal resolves from inside a container
  local missing=()
  for tool in bash yq jq node pnpm uv git tesseract openssl; do
    command -v "$tool" >/dev/null || missing+=("$tool")
  done
  [[ ${#missing[@]} -eq 0 ]] || return 1

  (( BASH_VERSINFO[0] >= 5 )) || return 1

  for d in bin litellm data data/phoenix data/falkor data/qdrant data/honcho data/openwebui \
           traces ingestor/inbox ingestor/processed guardrails openshell/policies tools \
           hermes-workspace ingestor autofyn deer-flow halo \
           installer/state; do
    [[ -d "$AI_STACK/$d" ]] || return 1
  done

  [[ -f "$AI_STACK/.env" ]] || return 1
  local perm; perm="$(stat -f '%Sp' "$AI_STACK/.env")"
  [[ "$perm" == "-rw-------" ]] || return 1

  load_env_strict >/dev/null 2>&1 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (host prep)"
  exit 0
fi

hdr "Phase 00 — host preparation"

# Selection-before-use: pin the Docker engine before any docker call or Phase 04.
# Idempotent — if .env already pins an installed engine, engine_select returns it
# with no prompt. Honors a global --engine via AI_STACK_ENGINE_FLAG (Task 11a).
if declare -F engine_select >/dev/null 2>&1; then
  _pf_sel="$(engine_select)" || { err "Phase 00: could not select a Docker engine"; exit 1; }
  engine_pin "$_pf_sel" || { err "Phase 00: could not pin engine '$_pf_sel'"; exit 1; }
  unset _pf_sel
fi

# --- host dependencies: core CLI tools + OrbStack/Docker (verified actions) ---
# Centralized in installer/lib/deps.sh so the SAME check->install->verify logic
# backs preflight, this phase, and `vz-ai-stack.sh deps`. Each ensures only what
# is missing, then re-verifies — no assumptions. Ollama (install + cross-container
# env-patch + start + model pulls) is ensured in Phase 01 so that step stays one
# coherent unit. See doc/PREREQUISITES.md for the full map.
ensure_core_tools || { err "core CLI tools could not be ensured (see above)"; exit 1; }
ensure_orbstack   || { err "OrbStack/Docker could not be ensured (see above)"; exit 1; }

# (Ollama install + cross-container env-patch + start moved to Phase 01 via
# ensure_ollama in installer/lib/deps.sh — it must run AFTER ollama is installed,
# and Phase 01 is where ollama is installed + models are pulled.)

# --- directory tree ---
log "Ensuring directory tree..."
mkdir -p "$AI_STACK"/{bin,litellm,data/phoenix,data/falkor,data/qdrant,data/honcho,data/openwebui,traces,ingestor/inbox,ingestor/processed,guardrails,openshell/policies,tools,hermes-workspace,ingestor,autofyn,deer-flow,halo,installer/state,CHANGELOG.d}

# --- .env baseline ---
# Single source of truth lives in installer/lib/env.sh::env_ensure_baseline
# (shared with `vz-ai-stack.sh setup`): ensures the file @ 0600, sets non-secret
# service-URL defaults, migrates stale host.docker.internal values (queues a
# litellm restart via queue_restart, loaded in this phase), and auto-generates
# LITELLM_MASTER_KEY + PHOENIX_SECRET. Cloud API keys are intentionally left
# empty here and offered interactively by `setup`.
env_ensure_baseline

# --- host.docker.internal probe ---
log "Probing host.docker.internal from inside a container..."
if probe_host_docker_internal; then
  ok "host.docker.internal resolves"
else
  err "host.docker.internal probe FAILED — fix before continuing."
  exit 1
fi

# --- env strict validation ---
load_env_strict || { err ".env has malformed lines"; exit 1; }

stamp_mark "$PHASE"
record "phase 00 complete: brew formulae installed, dir tree present, .env initialized"
ok "Phase 00 — host preparation — complete"
