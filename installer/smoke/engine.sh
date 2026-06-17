#!/usr/bin/env bash
# Unit tests for installer/lib/docker-engine.sh — engine registry.
# Runs entirely offline (no daemon). .env writes go to a THROWAWAY file.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
# MUST reassign AFTER sourcing common.sh+env.sh (common.sh:58 hardcodes it until Task 2;
# after Task 2 the pre-export also works, but reassign is the belt-and-suspenders rule).
ENV_FILE="$(mktemp -t aistack-test-env.XXXXXX)"
trap 'rm -f "$ENV_FILE"' EXIT
source "$AI_STACK/installer/lib/docker-engine.sh"

hdr "Smoke engine — registry (pure)"

# --- ids + display ---
log "ENGINE_IDS in priority order"
[[ "$ENGINE_IDS" == "orbstack docker-desktop colima podman" ]] \
  || { err "ENGINE_IDS wrong: '$ENGINE_IDS'"; exit 1; }
[[ "$(engine_display orbstack)" == "OrbStack" ]] || { err "display orbstack"; exit 1; }
[[ "$(engine_display docker-desktop)" == "Docker Desktop" ]] || { err "display dd"; exit 1; }
[[ "$(engine_display colima)" == "Colima" ]] || { err "display colima"; exit 1; }
[[ "$(engine_display podman)" == "Podman" ]] || { err "display podman"; exit 1; }
ok "display names correct"

# --- addhost gating (the per-engine variance) ---
log "engine_addhost_args gating"
[[ -z "$(engine_addhost_args orbstack)" ]] || { err "orbstack should NOT add-host"; exit 1; }
[[ -z "$(engine_addhost_args docker-desktop)" ]] || { err "dd should NOT add-host"; exit 1; }
[[ "$(engine_addhost_args colima)" == "--add-host=host.docker.internal:host-gateway" ]] \
  || { err "colima MUST add-host"; exit 1; }
[[ "$(engine_addhost_args podman)" == "--add-host=host.docker.internal:host-gateway" ]] \
  || { err "podman MUST add-host"; exit 1; }
ok "add-host gating correct"

# --- unknown id rejected everywhere ---
log "unknown id rejection"
engine_display bogus >/dev/null 2>&1 && { err "engine_display accepted bogus"; exit 1; }
engine_addhost_args bogus >/dev/null 2>&1 && { err "engine_addhost_args accepted bogus"; exit 1; }
ok "unknown id rejected"

# --- inherit_errexit safety lint: NO bare `=$(engine_…)` assignments anywhere ---
# (Under set -Eeuo pipefail + inherit_errexit a bare assignment from a function that
#  returns non-zero ABORTS the whole script — every call MUST be guarded `|| {…}`.)
log "lint: no bare =\$(engine_…) command-substitution assignments"
if grep -rnE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\"?\$\(engine_' \
     "$AI_STACK/installer/lib/docker-engine.sh" "$AI_STACK/installer/lib/deps.sh" \
     "$AI_STACK/installer/lib/docker.sh" "$AI_STACK/installer/phases/04_openshell.sh" \
     "$AI_STACK/vz-ai-stack.sh" 2>/dev/null | grep -vE '\|\||;[[:space:]]*\}|\bif\b|\bfor\b'; then
  err "found a bare =\$(engine_…) assignment (must be guarded under inherit_errexit)"; exit 1
fi
ok "no unguarded engine_* command substitutions"

ok "Task 1 registry-pure tests passed"
