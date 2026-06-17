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

log "engine_installed / engine_detect_installed (self-consistent, host-agnostic)"
# engine_installed and engine_detect_installed must AGREE for every id (no fixed inventory).
inst="$(engine_detect_installed)"
for e in $ENGINE_IDS; do
  if engine_installed "$e"; then
    grep -qx "$e" <<<"$inst" || { err "detect_installed missing $e though engine_installed $e is true"; exit 1; }
  else
    grep -qx "$e" <<<"$inst" && { err "detect_installed wrongly listed $e"; exit 1; } || true
  fi
done
# At least one engine must be installed on a real dev box (sanity, not inventory).
[[ -n "$inst" ]] || { err "no docker engine installed at all"; exit 1; }
ok "install detection self-consistent for all ids"

log "engine_running is timeout-bounded (must not hang) — assert against a NOT-running engine"
# Find an installed-but-not-running engine to time; if none, use a known-absent path:
bounded_target=""
for e in $ENGINE_IDS; do engine_installed "$e" && ! engine_running "$e" && { bounded_target="$e"; break; }; done
[[ -n "$bounded_target" ]] || bounded_target=podman   # podman path is safe to time even if absent
start=$(date +%s)
engine_running "$bounded_target" && true   # don't care about result, only the wall-clock
end=$(date +%s)
(( end - start <= 8 )) || { err "engine_running not timeout-bounded ($((end-start))s for $bounded_target)"; exit 1; }
ok "engine_running bounded (<=8s, target=$bounded_target)"

log "engine_select precedence (failure paths first)"
# 1) Unknown --engine flag must be rejected hard.
( AI_STACK_ENGINE_FLAG=bogus NO_PROMPT=1 engine_select ) >/dev/null 2>&1 \
  && { err "engine_select accepted bogus flag"; exit 1; } || true
# 2) Flag beats everything (even a different .env value).
set_env AI_STACK_DOCKER_ENGINE colima
sel="$(AI_STACK_ENGINE_FLAG=podman NO_PROMPT=1 engine_select 2>/dev/null)"
[[ "$sel" == podman ]] || { err "flag did not win: '$sel'"; exit 1; }
# 3) .env beats running-singleton + priority when no flag.
sel="$(NO_PROMPT=1 engine_select 2>/dev/null)"
[[ "$sel" == colima ]] || { err ".env did not win: '$sel'"; exit 1; }
# 4) RUNNING-SINGLETON rung (the subtlest one — MUST be unambiguous, so STUB
#    engine_detect_running to return exactly ONE id that DIFFERS from the
#    priority-fallback winner, with empty .env and NO flag. This proves
#    "single running engine" beats the orbstack priority fallback. Without the
#    stub this rung is physically untestable on a single-engine box.
set_env AI_STACK_DOCKER_ENGINE ""
sel="$(
  set -Eeuo pipefail
  AI_STACK="$AI_STACK"; ENV_FILE="$ENV_FILE"
  source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
  source "$AI_STACK/installer/lib/docker-engine.sh"
  engine_detect_running() { printf 'colima\n'; }   # exactly one, != orbstack priority winner
  NO_PROMPT=1 engine_select 2>/dev/null
)"
[[ "$sel" == colima ]] || { err "running-singleton rung failed (want colima, got '$sel')"; exit 1; }
ok "running-singleton beats priority fallback"
# 5) No flag, empty .env, NO_PROMPT, ZERO/MULTIPLE running → fixed priority (first INSTALLED, else first id).
sel="$(NO_PROMPT=1 engine_select 2>/dev/null)"
# orbstack is installed on this box → must win the priority fallback.
[[ "$sel" == orbstack ]] || { err "NO_PROMPT priority did not pick orbstack: '$sel'"; exit 1; }
ok "engine_select precedence correct (incl running-singleton)"

log "engine_ensure failure path: not installed + NO_PROMPT → hard fail with brew remedy"
# Pick an engine that is NOT installed on this box (docker-desktop).
engine_installed docker-desktop && { err "test assumes docker-desktop NOT installed"; exit 1; } || true
out="$(NO_PROMPT=1 engine_ensure docker-desktop 2>&1)" && { err "engine_ensure should fail (not installed, NO_PROMPT)"; exit 1; } || true
grep -q 'brew install' <<<"$out" || { err "engine_ensure must print 'brew install' remedy; got: $out"; exit 1; }
ok "engine_ensure NO_PROMPT-not-installed hard-fails with brew remedy"

log "engine_install_cmd exact brew strings for ALL 4 ids (pure, no brew needed)"
[[ "$(engine_install_cmd orbstack)"       == "brew install --cask orbstack" ]]       || { err "install_cmd orbstack";       exit 1; }
[[ "$(engine_install_cmd docker-desktop)" == "brew install --cask docker-desktop" ]] || { err "install_cmd docker-desktop"; exit 1; }
[[ "$(engine_install_cmd colima)"         == "brew install colima docker" ]]         || { err "install_cmd colima";         exit 1; }
[[ "$(engine_install_cmd podman)"         == "brew install podman docker" ]]         || { err "install_cmd podman";         exit 1; }
engine_install_cmd bogus >/dev/null 2>&1 && { err "install_cmd accepted bogus"; exit 1; } || true
ok "engine_install_cmd strings correct for all 4 ids"

log "engine_install / engine_start are defined (no-op assert)"
declare -F engine_install >/dev/null || { err "engine_install undefined"; exit 1; }
declare -F engine_start   >/dev/null || { err "engine_start undefined"; exit 1; }
ok "engine_install/engine_start defined"

ok "Task 1 registry-pure tests passed"
