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

# Regression: a PRE-exported ENV_FILE must survive sourcing common.sh+env.sh.
( set -Eeuo pipefail
  tmp="$(mktemp -t aistack-presrc.XXXXXX)"; trap 'rm -f "$tmp"' EXIT
  AI_STACK_X="$AI_STACK" ENV_FILE="$tmp" bash -c '
    set -Eeuo pipefail
    AI_STACK="$AI_STACK_X"
    source "$AI_STACK/installer/lib/common.sh"
    source "$AI_STACK/installer/lib/env.sh"
    [[ "$ENV_FILE" == "'"$tmp"'" ]] || { echo "ENV_FILE clobbered to $ENV_FILE" >&2; exit 1; }
  ' ) || { err "pre-exported ENV_FILE was clobbered by common.sh:58"; exit 1; }
ok "pre-exported ENV_FILE honored"

log "no lib re-hardcodes ENV_FILE unconditionally (only the :- idiom allowed)"
bad="$(grep -rnE '^[[:space:]]*ENV_FILE=' "$AI_STACK"/installer/lib/*.sh | grep -vE 'ENV_FILE=\"?\$\{ENV_FILE:-' || true)"
[[ -z "$bad" ]] || { err "unconditional ENV_FILE= assignment(s) found:\n$bad"; exit 1; }
ok "all ENV_FILE= assignments honor the override"

# Full source-chain survival: a pre-exported throwaway ENV_FILE must survive
# common→env→docker→litellm→deps→setup (NOT just common+env).
( set -Eeuo pipefail
  tmp="$(mktemp -t aistack-chain.XXXXXX)"; trap 'rm -f "$tmp"' EXIT
  AI_STACK_X="$AI_STACK" ENV_FILE="$tmp" bash -c '
    set -Eeuo pipefail; AI_STACK="$AI_STACK_X"; L="$AI_STACK/installer/lib"
    for f in common env docker litellm deps setup; do
      [[ -f "$L/$f.sh" ]] && source "$L/$f.sh"
    done
    [[ "$ENV_FILE" == "'"$tmp"'" ]] || { echo "ENV_FILE clobbered to $ENV_FILE by the source chain" >&2; exit 1; }
  ' ) || { err "throwaway ENV_FILE did not survive the full source chain"; exit 1; }
ok "throwaway ENV_FILE survives full source chain"

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

log "engine_socket format contract"
# orbstack: literal, stable path on this host.
orb="$(engine_socket orbstack)" || true
[[ "$orb" == "unix://$HOME/.orbstack/run/docker.sock" ]] \
  || { err "orbstack socket wrong: '$orb'"; exit 1; }
# all resolvable sockets are unix:// (or tcp://); unknown id returns non-zero + empty.
engine_socket bogus >/dev/null 2>&1 && { err "engine_socket accepted bogus"; exit 1; }
# docker-desktop / colima / podman: either resolve to a unix:// string OR fail cleanly (1),
# NEVER hang and NEVER print a non-uri. (They are not installed on this box.)
for e in docker-desktop colima podman; do
  if s="$(engine_socket "$e" 2>/dev/null)"; then
    [[ "$s" == unix://* || "$s" == tcp://* ]] || { err "$e socket not a uri: '$s'"; exit 1; }
  fi
done
ok "engine_socket format contract holds"

ok "Task 1 registry-pure tests passed"
