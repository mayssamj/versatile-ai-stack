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
# Host-adaptive: derive the EXPECTED winner = first ENGINE_IDS that is actually
# installed (via engine_detect_installed, which is priority-ordered), so the suite
# passes on any host. Falls back to the priority head if nothing is installed.
sel="$(NO_PROMPT=1 engine_select 2>/dev/null)"
# NB: capture-then-slice (no `| head`) — a SIGPIPE from head would trip pipefail+errexit.
_inst_all="$(engine_detect_installed)"
want_first_installed="${_inst_all%%$'\n'*}"
[[ -n "$want_first_installed" ]] || want_first_installed="${ENGINE_IDS%% *}"
[[ "$sel" == "$want_first_installed" ]] \
  || { err "NO_PROMPT priority did not pick first-installed ('$want_first_installed'): got '$sel'"; exit 1; }
ok "engine_select precedence correct (incl running-singleton; NO_PROMPT→$sel)"

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

log "engine_install NO_PROMPT path is OFFLINE — hard-fails fast with static remedy, no 'brew info'"
# Structural guarantee (Fix 3): the NO_PROMPT hard-fail MUST be reached BEFORE any
# `brew info` cask probe, so the hands-off path never makes a network call. We assert
# both behaviorally (fast + correct remedy, no brew) AND structurally (body shape).
body="$(declare -f engine_install)"
# The NO_PROMPT branch must appear BEFORE the first `brew info` in the function body.
# `grep -m1` stops at the first hit (no SIGPIPE into a closed `head`); `cut` consumes it all.
np_line="$(grep -m1 -n 'NO_PROMPT' <<<"$body" | cut -d: -f1 || true)"
bi_line="$(grep -m1 -n 'brew info' <<<"$body" | cut -d: -f1 || true)"
[[ -n "$np_line" ]] || { err "engine_install body lost its NO_PROMPT guard"; exit 1; }
if [[ -n "$bi_line" ]]; then
  (( np_line < bi_line )) || { err "engine_install: 'brew info' is reachable on the NO_PROMPT path (lazy-cask regression)"; exit 1; }
fi
# Behavioral: stub `brew` to FAIL LOUDLY if called — proves the NO_PROMPT path never shells out.
out="$(
  set -Eeuo pipefail
  brew() { echo "FATAL: brew invoked on NO_PROMPT path: $*" >&2; return 99; }
  start=$(date +%s)
  NO_PROMPT=1 engine_install docker-desktop 2>&1
  echo "RC=$?"
  echo "ELAPSED=$(( $(date +%s) - start ))"
)" || true
grep -q 'FATAL: brew invoked' <<<"$out" && { err "engine_install NO_PROMPT path called brew: $out"; exit 1; }
grep -q 'RC=1' <<<"$out" || { err "engine_install NO_PROMPT must return 1; got: $out"; exit 1; }
# Must print the STATIC engine_install_cmd remedy (the cask-churned 'docker-desktop' string).
grep -q "$(engine_install_cmd docker-desktop)" <<<"$out" \
  || { err "engine_install NO_PROMPT must print static remedy '$(engine_install_cmd docker-desktop)'; got: $out"; exit 1; }
elapsed="$(grep -oE 'ELAPSED=[0-9]+' <<<"$out" | cut -d= -f2)"
(( ${elapsed:-99} <= 1 )) || { err "engine_install NO_PROMPT not fast (${elapsed}s) — likely hit network"; exit 1; }
ok "engine_install NO_PROMPT offline + fast (${elapsed}s) + static remedy, no brew call"

log "engine_install preserves the install rc (pipe-to-tail must NOT swallow a failed brew)"
# Fix 1: the install pipeline runs under `set -o pipefail` so a failing brew → non-zero.
# Drive the INTERACTIVE path offline: stub brew to fail, auto-confirm via stdin 'Y'.
rc=0
out="$(
  set -Eeuo pipefail
  brew() { echo "simulated brew failure" >&2; return 1; }
  printf 'Y\n' | engine_install orbstack 2>&1
)" || rc=$?
[[ "$rc" -ne 0 ]] || { err "engine_install returned 0 despite a failing brew (rc swallowed by tail); out: $out"; exit 1; }
grep -q 'install failed' <<<"$out" || { err "engine_install must report 'install failed' on a failed brew; got: $out"; exit 1; }
# Structural backstop: the body must use pipefail-protected invocation.
grep -q 'set -o pipefail' <<<"$body" || { err "engine_install body lost 'set -o pipefail' rc-capture (Fix 1 regression)"; exit 1; }
ok "engine_install preserves install rc (set -o pipefail) — failed brew → non-zero + 'install failed'"

log "engine_pin: persists .env, rewrites gateway.env, exports DOCKER_HOST"
GW="$(mktemp -t aistack-gw.XXXXXX)"; trap 'rm -f "$ENV_FILE" "$GW"' EXIT
# engine_pin must honor an injected GATEWAY_ENV_FILE override + skip docker context under NO_PROMPT.
( NO_PROMPT=1 ENGINE_GATEWAY_ENV_FILE="$GW" engine_pin orbstack ) >/dev/null 2>&1 \
  || { err "engine_pin orbstack failed"; exit 1; }
[[ "$(get_env AI_STACK_DOCKER_ENGINE "")" == orbstack ]] || { err ".env not pinned"; exit 1; }
grep -qx "OPENSHELL_DRIVERS=docker" "$GW" || { err "gateway.env missing drivers line"; exit 1; }
grep -qx "DOCKER_HOST=unix://$HOME/.orbstack/run/docker.sock" "$GW" \
  || { err "gateway.env DOCKER_HOST wrong: $(cat "$GW")"; exit 1; }
# Fix 4: written via atomic_write (common.sh) → mode MUST be 600 (no world/group bits).
mode="$(stat -f '%Lp' "$GW" 2>/dev/null || stat -c '%a' "$GW" 2>/dev/null)"
[[ "$mode" == "600" ]] || { err "gateway.env mode is '$mode', want 600 (atomic_write chmod regression)"; exit 1; }
# Structural backstop: the writer must go through atomic_write, not a bare cat>redirect.
gwbody="$(declare -f engine_write_gateway_env)"
grep -q 'atomic_write' <<<"$gwbody" || { err "engine_write_gateway_env no longer uses atomic_write (Fix 4 regression)"; exit 1; }
grep -qE 'cat[[:space:]]*>[^&]' <<<"$gwbody" && { err "engine_write_gateway_env still uses a non-atomic 'cat >' write"; exit 1; } || true
ok "engine_pin persisted + rewrote gateway.env via atomic_write (mode 600)"

log "engine_write_gateway_env is the SINGLE writer + idempotent (no-op on 2nd call)"
declare -F engine_write_gateway_env >/dev/null || { err "engine_write_gateway_env undefined (single-writer not extracted)"; exit 1; }
# First call already happened via engine_pin → file matches → second call must be a NO-OP (return 1=unchanged).
if ENGINE_GATEWAY_ENV_FILE="$GW" engine_write_gateway_env orbstack; then
  err "engine_write_gateway_env reported CHANGED on an already-current gateway.env (not idempotent)"; exit 1
fi
# The no-op MUST NOT disturb the file: content + mode 600 still intact after the idempotent call.
grep -qx "DOCKER_HOST=unix://$HOME/.orbstack/run/docker.sock" "$GW" \
  || { err "idempotent no-op corrupted gateway.env content: $(cat "$GW")"; exit 1; }
mode2="$(stat -f '%Lp' "$GW" 2>/dev/null || stat -c '%a' "$GW" 2>/dev/null)"
[[ "$mode2" == "600" ]] || { err "idempotent no-op changed gateway.env mode to '$mode2'"; exit 1; }
ok "engine_write_gateway_env idempotent (unchanged → return 1; content+mode preserved)"

ok "Task 1 registry-pure tests passed"

log "central export: pinned .env → DOCKER_HOST exported by the REAL vz-ai-stack.sh load path"
tmpenv="$(mktemp -t aistack-export.XXXXXX)"
printf 'AI_STACK_DOCKER_ENGINE=orbstack\n' > "$tmpenv"
got="$(ENV_FILE="$tmpenv" bash "$AI_STACK/vz-ai-stack.sh" __print-docker-host 2>/dev/null || true)"
rm -f "$tmpenv"
grep -q "DOCKER_HOST=unix://$HOME/.orbstack/run/docker.sock" <<<"$got" \
  || { err "central export not wired (real load path did not export DOCKER_HOST): $got"; exit 1; }
# Empty-engine case: unset .env → export is a no-op (DOCKER_HOST stays unset/ambient).
tmpe2="$(mktemp)"; printf 'AI_STACK_DOCKER_ENGINE=\n' > "$tmpe2"
got2="$(env -u DOCKER_HOST ENV_FILE="$tmpe2" bash "$AI_STACK/vz-ai-stack.sh" __print-docker-host 2>/dev/null || true)"
rm -f "$tmpe2"
grep -q 'DOCKER_HOST=<unset>' <<<"$got2" || { err "empty engine should be a no-op export: $got2"; exit 1; }
ok "central DOCKER_HOST export wired (real path; no-op when unset)"

log "8b: standalone docker.sh source chain exports the selected DOCKER_HOST"
tmpenv="$(mktemp -t aistack-8b.XXXXXX)"
printf 'AI_STACK_DOCKER_ENGINE=orbstack\n' > "$tmpenv"
got="$(env -u DOCKER_HOST ENV_FILE="$tmpenv" bash -c '
  set -Eeuo pipefail; AI_STACK="'"$AI_STACK"'"; L="$AI_STACK/installer/lib"
  source "$L/common.sh"; source "$L/env.sh"; source "$L/docker-engine.sh"; source "$L/docker.sh"
  echo "DOCKER_HOST=${DOCKER_HOST:-<unset>}"
' 2>/dev/null || true)"
rm -f "$tmpenv"
grep -q "DOCKER_HOST=unix://$HOME/.orbstack/run/docker.sock" <<<"$got" \
  || { err "docker.sh source-time export not wired: $got"; exit 1; }
ok "8b: standalone docker.sh chain exports DOCKER_HOST"
