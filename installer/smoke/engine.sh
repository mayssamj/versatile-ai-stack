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

# --- inherit_errexit safety lint: NO bare `=$(engine_…)` / `=$(get_env …)` assignments ---
# (Under set -Eeuo pipefail + inherit_errexit a bare assignment from a function that
#  returns non-zero ABORTS the whole script — every call MUST be guarded `|| {…}`/`|| true`.)
# This is the guard that would have caught the §24 review's bare `sel=$(get_env …)` in the
# doctor checks. Scans the engine module + its callers + ALL engine-aware doctor checks +
# the OpenShell durability bin scripts; the regex flags a bare `var="$(engine_…`/`var="$(get_env …`
# assignment NOT followed by `|| ` and NOT on an `if`/`for`/`while`/`||`/`&&` line.
log "lint: no bare =\$(engine_…)/=\$(get_env …) command-substitution assignments"
if grep -rnE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\"?\$\((engine_|get_env)' \
     "$AI_STACK/installer/lib/docker-engine.sh" "$AI_STACK/installer/lib/deps.sh" \
     "$AI_STACK/installer/lib/docker.sh" "$AI_STACK/installer/phases/04_openshell.sh" \
     "$AI_STACK/vz-ai-stack.sh" \
     "$AI_STACK/installer/doctor/checks/01_orbstack_running.sh" \
     "$AI_STACK/installer/doctor/checks/02_host_docker_internal.sh" \
     "$AI_STACK/installer/doctor/checks/47_docker_engine_consistency.sh" \
     "$AI_STACK/installer/doctor/checks/48_docker_engine_selection.sh" \
     "$AI_STACK/bin/openshell-checkpoint.sh" "$AI_STACK/bin/openshell-state-restore.sh" \
     "$AI_STACK/bin/openshell-watchdog.sh" "$AI_STACK/bin/openshell-token-refresh.sh" \
     2>/dev/null | grep -vE '\|\||;[[:space:]]*\}|\bif\b|\bfor\b|\bwhile\b|&&'; then
  err "found a bare =\$(engine_…)/=\$(get_env …) assignment (must be guarded under inherit_errexit)"; exit 1
fi
ok "no unguarded engine_*/get_env command substitutions (lib + doctor checks + bin scripts)"

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

log "8c: phase 00 preflight selects + pins the engine when unset"
grep -qE 'engine_select|ensure_docker_engine' "$AI_STACK/installer/phases/00_host.sh" \
  || { err "00_host.sh does not run engine selection in preflight"; exit 1; }
ok "8c: phase 00 wires selection-before-use"

# ===========================================================================
# Task 9 — deps.sh: ensure_orbstack=thin alias + deps_report engine status block
# ===========================================================================
# SAFETY: this test MUST stay READ-ONLY. We call `deps_report --check` (NOT bare
# `deps_report`, which would call bootstrap_host_deps/ensure_*/engine_pin and
# INSTALL brew/orbstack/ollama + WRITE the real ~/.config/openshell/gateway.env).
# Defense-in-depth: NO_PROMPT=1 + a throwaway ENGINE_GATEWAY_ENV_FILE + throwaway
# ENV_FILE, all inside a subshell, so nothing reaches real host state.
log "deps wiring: ensure_orbstack is an alias + deps_report --check shows engine (READ-ONLY)"
source "$AI_STACK/installer/lib/deps.sh"
declare -F ensure_orbstack >/dev/null || { err "ensure_orbstack name removed (callers depend on it)"; exit 1; }
declare -F ensure_docker_engine >/dev/null || { err "ensure_docker_engine undefined"; exit 1; }
# Non-tautological: assert the UNIQUE sentinel the NEW block emits, NOT a broad
# 'engine|socket' grep that the existing deps_report already satisfies. The block
# prints `note "Docker engine: <id> ..."` and a `gateway.env socket == selected`
# / `... != selected ...` comparison — match those exact labels.
_t9_gw="$(mktemp -t aistack-t9-gw.XXXXXX)"; rm -f "$_t9_gw"   # path only; block must NOT write it
_t9_env="$(mktemp -t aistack-t9-env.XXXXXX)"
rep="$(AI_STACK_DOCKER_ENGINE=orbstack NO_PROMPT=1 \
       ENGINE_GATEWAY_ENV_FILE="$_t9_gw" ENV_FILE="$_t9_env" bash -c '
  set -Eeuo pipefail; AI_STACK="'"$AI_STACK"'"
  source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
  source "$AI_STACK/installer/lib/docker-engine.sh"; source "$AI_STACK/installer/lib/deps.sh"
  set_env AI_STACK_DOCKER_ENGINE orbstack
  deps_report --check 2>&1 || true
')"
rm -f "$_t9_env" "$_t9_gw"
grep -q "Docker engine: orbstack" <<<"$rep" \
  || { err "deps_report --check missing the 'Docker engine: orbstack' sentinel line"; exit 1; }
grep -qE 'gateway\.env socket (==|!=) selected' <<<"$rep" \
  || { err "deps_report --check missing the gateway.env socket comparison line"; exit 1; }
ok "deps wiring present (unique sentinels, read-only --check path)"

# ===========================================================================
# Task 10 — docker.sh: engine-conditional add-host in docker_run_managed
# ===========================================================================
# `docker` is fully stubbed (a shell function inside each subshell) so nothing
# reaches a real daemon; ENV_FILE is a throwaway.
log "docker_run_managed appends engine_addhost_args for the selected engine"
# colima → MUST include host.docker.internal add-host
_t10_env="$(mktemp -t aistack-t10c.XXXXXX)"
out="$(AI_STACK_DOCKER_ENGINE=colima ENV_FILE="$_t10_env" bash -c '
  set -Eeuo pipefail; AI_STACK="'"$AI_STACK"'"
  source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
  source "$AI_STACK/installer/lib/docker-engine.sh"; source "$AI_STACK/installer/lib/docker.sh"
  docker() { printf "%s\n" "$*"; }
  set_env AI_STACK_DOCKER_ENGINE colima
  docker_run_managed t 99 alpine -- true
')"
rm -f "$_t10_env"
grep -q -- '--add-host=host.docker.internal:host-gateway' <<<"$out" \
  || { err "colima docker_run_managed missing host.docker.internal add-host: $out"; exit 1; }
# orbstack → MUST NOT include it
out="$(AI_STACK_DOCKER_ENGINE=orbstack bash -c '
  set -Eeuo pipefail; AI_STACK="'"$AI_STACK"'"
  e="$(mktemp)"; export ENV_FILE="$e"
  source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
  source "$AI_STACK/installer/lib/docker-engine.sh"; source "$AI_STACK/installer/lib/docker.sh"
  docker() { printf "%s\n" "$*"; }
  set_env AI_STACK_DOCKER_ENGINE orbstack
  docker_run_managed t 99 alpine -- true; rm -f "$e"
')"
grep -q -- '--add-host=host.docker.internal' <<<"$out" \
  && { err "orbstack docker_run_managed should NOT add host.docker.internal: $out"; exit 1; } || true
ok "docker_run_managed add-host is engine-conditional"

# --- 10b: bin/start-litellm.sh add-host must be engine-DERIVED, not hardcoded ----
# SAFETY: start-litellm.sh exits early on its network/Postgres preconditions in a
# clean env, so a test that depends on its full `docker run` output is flaky. The
# LOAD-BEARING checks are (a) STATIC: the script sources docker-engine.sh AND builds
# its add-host via engine_addhost_args/get_env (not a hardcoded literal); and (b)
# ISOLATED: drive engine_addhost_args directly to prove colima→flag, orbstack→empty.
# A run-the-script grep is kept ONLY as a soft signal (an early precondition-exit
# does NOT fail the test). `docker` is stubbed via a temp-PATH dir; ENV_FILE throwaway.
log "10b: start-litellm.sh add-host is engine-derived (static + isolated)"
_sl="$AI_STACK/bin/start-litellm.sh"
# (a) STATIC: sources the registry + constructs add-host from engine_addhost_args.
grep -qE 'source[[:space:]].*docker-engine\.sh' "$_sl" \
  || { err "10b: start-litellm.sh does not source docker-engine.sh"; exit 1; }
grep -q 'engine_addhost_args' "$_sl" \
  || { err "10b: start-litellm.sh does not derive add-host via engine_addhost_args"; exit 1; }
grep -q -- '--add-host=host.docker.internal:host-gateway' "$_sl" \
  && { err "10b: start-litellm.sh still HARDCODES the host.docker.internal add-host literal"; exit 1; } || true
# (b) ISOLATED: the registry function the script now uses yields the right token.
( set -Eeuo pipefail; AI_STACK="$AI_STACK"
  source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/docker-engine.sh"
  [[ "$(engine_addhost_args colima)" == "--add-host=host.docker.internal:host-gateway" ]] \
    || { echo "isolated: colima must yield the add-host flag"; exit 1; }
  [[ -z "$(engine_addhost_args orbstack)" ]] || { echo "isolated: orbstack must yield empty"; exit 1; }
) || { err "10b: isolated engine_addhost_args check failed"; exit 1; }
# (c) SOFT run-the-script signal — wrapped so an early precondition-exit cannot fail us.
_d=$(mktemp -d); printf '#!/usr/bin/env bash\necho "$@"\nexit 0\n' >"$_d/docker"; chmod +x "$_d/docker"
_slenv="$(mktemp)"; printf 'AI_STACK_DOCKER_ENGINE=colima\n' > "$_slenv"
run_out="$(PATH="$_d:$PATH" ENV_FILE="$_slenv" bash "$_sl" 2>&1 || true)"
rm -f "$_slenv"; rm -rf "$_d"
if grep -q 'docker run' <<<"$run_out" || grep -q -- '--add-host' <<<"$run_out"; then
  grep -q -- '--add-host=host.docker.internal:host-gateway' <<<"$run_out" \
    || { err "10b: start-litellm.sh reached docker run but lacked the colima add-host: $run_out"; exit 1; }
  ok "10b: start-litellm.sh emitted the colima add-host (full run path)"
else
  ok "10b: start-litellm.sh exited on a precondition (run-grep skipped; static+isolated checks carry it)"
fi

# ===========================================================================
# Task 11a — global --engine <id> argv → AI_STACK_ENGINE_FLAG → engine_select
# ===========================================================================
log "11a: global --engine <id> argv → AI_STACK_ENGINE_FLAG → engine_select"
tmpenv="$(mktemp)"; printf 'AI_STACK_DOCKER_ENGINE=\n' > "$tmpenv"
got="$(env -u DOCKER_HOST ENV_FILE="$tmpenv" bash "$AI_STACK/vz-ai-stack.sh" --engine orbstack __print-docker-host 2>/dev/null || true)"
rm -f "$tmpenv"
grep -q "DOCKER_HOST=unix://$HOME/.orbstack/run/docker.sock" <<<"$got" \
  || { err "global --engine flag not plumbed to AI_STACK_ENGINE_FLAG/engine_select: $got"; exit 1; }
ok "11a: global --engine argv plumbed"

log "11a-regression: --engine with no value errors clearly (exit 2, not silent)"
# Was a silent exit 1 (the pre-scan consumed the last token, then the trailing
# shift on an empty $@ tripped set -e before the ERR trap was installed). Now an
# explicit arity check must error clearly AND exit 2 (never a silent exit 1).
out="$(ENV_FILE="$(mktemp)" bash "$AI_STACK/vz-ai-stack.sh" --engine 2>&1; echo "rc=$?")"
grep -q 'requires an <id>' <<<"$out" || { err "--engine missing-value did not error clearly: $out"; exit 1; }
grep -q 'rc=2' <<<"$out" || { err "--engine missing-value should exit 2: $out"; exit 1; }
ok "11a-regression: --engine missing-value handled"

# ===========================================================================
# Task 11 — docker-engine [status|select|set <id>] subcommand + help routing
# ===========================================================================
log "11: docker-engine select accepts --engine colima AND --engine=colima (no daemon: assert parse, not pin)"
# SAFETY: parse-only. We feed an UNINSTALLED engine (colima) so engine_ensure
# fails fast at the NO_PROMPT brew-remedy BEFORE any engine_pin — it NEVER writes
# the real .env / gateway.env. Guard: skip if colima is somehow installed on this
# box (pinning it would be a real mutation), and run with a throwaway ENV_FILE +
# ENGINE_GATEWAY_ENV_FILE as defense-in-depth.
engine_installed colima && { err "11: test assumes colima NOT installed (else select would pin it for real)"; exit 1; } || true
_t11_env="$(mktemp)"; _t11_gw="$(mktemp)"; rm -f "$_t11_gw"
for form in "--engine colima" "--engine=colima"; do
  out="$(NO_PROMPT=1 ENV_FILE="$_t11_env" ENGINE_GATEWAY_ENV_FILE="$_t11_gw" \
        bash "$AI_STACK/installer/lib/docker-engine.sh" select $form 2>&1 || true)"
  # The flag MUST have been parsed: NOT a 'needs an <id>' misparse, AND the
  # engine_ensure failure names colima/brew (proves engine_select got the flag).
  grep -q 'needs an <id>' <<<"$out" && { err "11: select misparsed '$form' (treated --engine as no-op): $out"; exit 1; }
  grep -qiE 'colima|brew install colima' <<<"$out" \
    || { err "11: select '$form' did not reach engine_ensure for colima (flag not plumbed): $out"; exit 1; }
done
# Defense-in-depth: the throwaway files must NOT have been pinned (ensure failed first).
[[ ! -s "$_t11_gw" ]] || { err "11: select PINNED gateway.env on an uninstalled engine (should fail at ensure)"; rm -f "$_t11_env" "$_t11_gw"; exit 1; }
grep -q '^AI_STACK_DOCKER_ENGINE=colima' "$_t11_env" 2>/dev/null && { err "11: select PINNED .env on an uninstalled engine"; rm -f "$_t11_env" "$_t11_gw"; exit 1; } || true
rm -f "$_t11_env" "$_t11_gw"
ok "11: both --engine forms parse (parse-only; no pin)"

log "11: help docker-engine routes to usage (not services.yml service-help)"
out="$(bash "$AI_STACK/vz-ai-stack.sh" help docker-engine 2>&1 || true)"
grep -q 'docker-engine select' <<<"$out" \
  || { err "help docker-engine did not route to docker-engine usage: $out"; exit 1; }
ok "11: help docker-engine routes correctly"

log "11: sourcing docker-engine.sh does NOT trigger the CLI dispatch (BASH_SOURCE guard)"
# Pass a BOGUS subcommand at source time: if the guard were broken the dispatch would
# run `_de_main bogus-…` → `exit 2` and abort the subshell (caught by `||` below). When
# the guard holds, sourcing is a NO-OP dispatch and the LIBRARY functions are present.
( set -Eeuo pipefail; AI_STACK="$AI_STACK"
  source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
  source "$AI_STACK/installer/lib/docker-engine.sh" bogus-should-not-dispatch
  declare -F engine_select >/dev/null || { echo "library funcs not loaded on source"; exit 1; }
  # The CLI body (_de_main) is defined INSIDE the guard, so it MUST be absent on source.
  declare -F _de_main >/dev/null && { echo "_de_main leaked outside the BASH_SOURCE guard"; exit 1; } || true
) || { err "sourcing docker-engine.sh dispatched the CLI (BASH_SOURCE==\$0 guard broken)"; exit 1; }
ok "11: docker-engine.sh CLI guarded (source-safe)"

# ===========================================================================
# Task 12 — Phase 04: OrbStack hardcode → read-only-select + single writer +
#           canonical Ready guard + checkpoint-before-restart
# ===========================================================================
# SAFETY: STATIC-grep + BEHAVIORAL-against-a-throwaway only. This test NEVER
# executes Phase 04 and NEVER triggers the restart/checkpoint path — it feeds a
# static colorized fixture to the canonical guard and writes the gateway env via
# engine_write_gateway_env to a THROWAWAY file (ENGINE_GATEWAY_ENV_FILE).
log "phase 04: hardcode gone, engine registry + single gateway writer used"
grep -q 'engine_write_gateway_env\|engine_socket' "$AI_STACK/installer/phases/04_openshell.sh" \
  || { err "04_openshell.sh does not call engine_socket/engine_write_gateway_env"; exit 1; }
grep -q 'ORB_SOCK="\$HOME/.orbstack/run/docker.sock"' "$AI_STACK/installer/phases/04_openshell.sh" \
  && { err "04_openshell.sh still hardcodes ORB_SOCK"; exit 1; } || true
# Read-only selection: phase must NOT perform a hidden global pin; it errors if unset.
grep -qE 'docker-engine select first|run .*docker-engine select' "$AI_STACK/installer/phases/04_openshell.sh" \
  || { err "04_openshell.sh should ERROR (not hidden-pin) when engine unset"; exit 1; }
ok "phase 04 uses engine registry + read-only selection"

log "phase 04 BEHAVIORAL: engine_write_gateway_env writes selected socket to throwaway gateway.env"
GW2="$(mktemp -t aistack-gw04.XXXXXX)"; trap 'rm -f "$ENV_FILE" "$GW" "$GW2"' EXIT
# The phase's writer is the shared helper — prove the contract directly + against a throwaway file.
ENGINE_GATEWAY_ENV_FILE="$GW2" engine_write_gateway_env orbstack || true
grep -qx "DOCKER_HOST=unix://$HOME/.orbstack/run/docker.sock" "$GW2" \
  || { err "phase-04 gateway writer did not write selected socket: $(cat "$GW2")"; exit 1; }
ok "phase 04 gateway.env derivation behavioral-verified (throwaway file)"

log "phase 04 guard: colorized Ready sandbox → restart REFUSED (not the destroy-both bug)"
# Feed a colorized fixture to the canonical guard and assert it DETECTS Ready.
source "$AI_STACK/installer/lib/openshell.sh"
fixture=$'NAME   PHASE\nsbx-1  \x1b[32mReady\x1b[0m\n'
det="$(printf '%s' "$fixture" | _osh_strip_ansi | awk 'NR>1 && $NF=="Ready"{print $1}')"
[[ "$det" == "sbx-1" ]] || { err "canonical guard failed to detect colorized Ready (det='$det')"; exit 1; }
ok "phase 04 guard detects colorized Ready sandbox"

# ===========================================================================
# Task 12b — OpenShell durability bin scripts are engine-aware
# ===========================================================================
# SAFETY: STATIC-grep only. These scripts operate on real sandboxes / launchd —
# this test NEVER runs them; it only proves each derives DOCKER_HOST from the
# selected engine (gateway.env first, registry fallback) before invoking docker.
log "12b: openshell-* bin scripts are engine-aware (export DOCKER_HOST from selection/gateway.env)"
for s in openshell-checkpoint openshell-state-restore openshell-watchdog openshell-token-refresh; do
  grep -qE 'AI_STACK_DOCKER_ENGINE|engine_socket|gateway\.env.*DOCKER_HOST|DOCKER_HOST=.*gateway' \
    "$AI_STACK/bin/$s.sh" \
    || { err "$s.sh is NOT engine-aware (still assumes OrbStack socket/binary)"; exit 1; }
done
ok "12b: openshell durability scripts derive DOCKER_HOST from the selected engine"

# ===========================================================================
# Task 13 — Doctor check 01 (selected engine reachable) + 02 (engine-aware host.docker.internal)
# ===========================================================================
# SAFETY: each subshell uses a THROWAWAY ENV_FILE + function stubs (engine_running,
# docker) so nothing reaches a real daemon or the real .env / gateway.env.
log "13: doctor check 01 — pinned-but-unreachable engine → non-zero + message"
( set -Eeuo pipefail; AI_STACK="$AI_STACK"; ENV_FILE="$(mktemp)"
  source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
  source "$AI_STACK/installer/lib/docker.sh"
  declare -a CHECKS; declare -A CHECK_TITLE
  source "$AI_STACK/installer/doctor/checks/01_orbstack_running.sh"
  # Pin a valid engine and stub engine_running to fail → diagnose must return non-zero.
  set_env AI_STACK_DOCKER_ENGINE orbstack
  engine_running() { return 1; }
  out="$(orbstack_running_diagnose 2>&1)"; rc=$?
  [[ $rc -ne 0 ]] || { echo "01 diagnose should fail when selected engine unreachable" >&2; exit 1; }
  grep -qi 'not reachable\|selected engine' <<<"$out" || { echo "01 message missing: $out" >&2; exit 1; }
  rm -f "$ENV_FILE"
) || { err "doctor 01 pinned-unreachable path failed"; exit 1; }
ok "13: doctor 01 pinned-unreachable path correct"

log "13: doctor check 01 — no engine pinned → legacy ambient fallback returns 0 when docker info works"
( set -Eeuo pipefail; AI_STACK="$AI_STACK"; ENV_FILE="$(mktemp)"
  source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"; source "$AI_STACK/installer/lib/docker.sh"
  declare -a CHECKS; declare -A CHECK_TITLE
  source "$AI_STACK/installer/doctor/checks/01_orbstack_running.sh"
  set_env AI_STACK_DOCKER_ENGINE ""
  docker() { [[ "$1" == info ]] && return 0; command docker "$@"; }
  orbstack_running_diagnose >/dev/null 2>&1 || { echo "01 legacy fallback should be green when docker info works" >&2; exit 1; }
  rm -f "$ENV_FILE"
) || { err "doctor 01 no-engine legacy fallback failed"; exit 1; }
ok "13: doctor 01 legacy fallback correct"

log "13: doctor check 02 — colima diagnose builds the --add-host arg (capture via docker stub)"
( set -Eeuo pipefail; AI_STACK="$AI_STACK"; ENV_FILE="$(mktemp)"
  source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"; source "$AI_STACK/installer/lib/docker.sh"
  declare -a CHECKS; declare -A CHECK_TITLE
  source "$AI_STACK/installer/doctor/checks/02_host_docker_internal.sh"
  set_env AI_STACK_DOCKER_ENGINE colima
  captured=""; docker() { captured="$*"; echo "$captured" >"$ENV_FILE.args"; return 0; }
  host_docker_internal_diagnose >/dev/null 2>&1 || true
  grep -q -- '--add-host=host.docker.internal:host-gateway' "$ENV_FILE.args" \
    || { echo "02 colima diagnose did not pass the add-host flag to docker" >&2; exit 1; }
  rm -f "$ENV_FILE" "$ENV_FILE.args"
) || { err "doctor 02 colima add-host path failed"; exit 1; }
ok "13: doctor 02 engine-aware add-host path correct"

# ===========================================================================
# Task 14 — New doctor checks 47 (consistency / split-brain) + 48 (selection present)
# ===========================================================================
# NB: on the post-fleet-parity main, the doctor baseline is 46 — fleet-parity's
# 46_agent_fleet_parity.sh merged FIRST. So this feature's two checks were renumbered
# to 47 (consistency) + 48 (selection), final count 48. The pre-existing
# 46_agent_fleet_parity.sh MUST remain present + intact (no collision with our files).
log "doctor: 46_agent_fleet_parity intact, 47 + 48 present, count == 48, single 47_/48_ ordinals"
[[ -f "$AI_STACK/installer/doctor/checks/46_agent_fleet_parity.sh" ]] || { err "46_agent_fleet_parity missing (fleet-parity check clobbered)"; exit 1; }
grep -q 'CHECKS+=(agent_fleet_parity)' "$AI_STACK/installer/doctor/checks/46_agent_fleet_parity.sh" || { err "46_agent_fleet_parity not registered (intact check)"; exit 1; }
[[ -f "$AI_STACK/installer/doctor/checks/47_docker_engine_consistency.sh" ]] || { err "47 missing"; exit 1; }
[[ -f "$AI_STACK/installer/doctor/checks/48_docker_engine_selection.sh" ]] || { err "48 missing"; exit 1; }
# Exactly ONE 47_ and ONE 48_ ordinal — proves no filename collision after the renumber.
[[ "$(ls "$AI_STACK"/installer/doctor/checks/47_*.sh | wc -l | tr -d ' ')" == 1 ]] \
  || { err "duplicate 47_ ordinal — collision"; exit 1; }
[[ "$(ls "$AI_STACK"/installer/doctor/checks/48_*.sh | wc -l | tr -d ' ')" == 1 ]] \
  || { err "duplicate 48_ ordinal — collision"; exit 1; }
n="$(ls "$AI_STACK"/installer/doctor/checks/*.sh | wc -l | tr -d ' ')"
[[ "$n" == 48 ]] || { err "expected 48 check files, found $n"; exit 1; }
# Both new check NAMES register.
grep -q 'CHECKS+=(docker_engine_consistency)' "$AI_STACK/installer/doctor/checks/47_docker_engine_consistency.sh" || { err "47 check not registered"; exit 1; }
grep -q 'CHECKS+=(docker_engine_selection)'  "$AI_STACK/installer/doctor/checks/48_docker_engine_selection.sh"  || { err "48 check not registered"; exit 1; }
ok "doctor 46_agent_fleet_parity intact + 47/48 present, 48 checks total, single 47_/48_ ordinals"

# Behavioral guard for check 48's GREEN path: diagnose MUST return 0 when a valid,
# installed engine is pinned. The original Task-14 test was STATIC (presence /
# registration only) and never DROVE diagnose — this fills that gap.
# NB on the reviewer's "missing return 0 → always RED" claim: it does NOT hold. The
# pre-fix body ended in `if ! engine_installed "$sel"; then …; return 1; fi` — and a
# trailing `if COND; …; fi` exits 0 when COND is false (engine installed), even under
# the runner's `set -Eeuo pipefail`+inherit_errexit (errexit is suspended for a fn run
# as an `if` condition). So the green path already returned 0; the added explicit
# `return 0` is defensive clarity (robust if a later edit appends a statement), not a
# bugfix — and this assertion correctly passes both before and after it.
log "14-regression: check 48 diagnose GREEN when valid installed engine pinned (return 0)"
( set -Eeuo pipefail; AI_STACK="$AI_STACK"; ENV_FILE="$(mktemp)"
  source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"; source "$AI_STACK/installer/lib/docker.sh"
  declare -a CHECKS; declare -A CHECK_TITLE
  source "$AI_STACK/installer/doctor/checks/48_docker_engine_selection.sh"
  set_env AI_STACK_DOCKER_ENGINE orbstack
  engine_installed() { return 0; }   # stub: pretend selected engine is installed
  docker_engine_selection_diagnose >/dev/null 2>&1 || { echo "48 diagnose RED on a valid installed pin (missing return 0?)" >&2; exit 1; }
  rm -f "$ENV_FILE"
) || { err "check 48 green-path regression failed"; exit 1; }
ok "14-regression: check 48 diagnose green-path correct"

# ===========================================================================
# Task 17 — NO_PROMPT + ZERO engines installed → clean brew-remedy hard-fail
# ===========================================================================
# END-TO-END coverage gap (QA/INFRA): prove the hands-off path with NOTHING
# installed exits cleanly with the brew remedy and NEVER proceeds to a docker
# call. Simulate "zero engines" by stubbing detection in a subshell; `engine_select`
# then falls to the NO_PROMPT priority-head, and `engine_ensure` hard-fails at the
# static brew remedy (engine_install is offline under NO_PROMPT). Throwaway ENV_FILE.
log "17: NO_PROMPT + zero engines installed → clean hard-fail with brew remedy (no docker calls)"
out="$(
  set +e
  AI_STACK="$AI_STACK"; ENV_FILE="$(mktemp -t aistack-t17-env.XXXXXX)"
  NO_PROMPT=1 bash -c '
    set -Eeuo pipefail; AI_STACK="'"$AI_STACK"'"
    source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
    source "$AI_STACK/installer/lib/docker-engine.sh"
    engine_installed() { return 1; }            # pretend nothing is installed
    engine_detect_installed() { :; }            # empty
    # FAIL LOUDLY if any docker call escapes onto this path.
    docker() { echo "FATAL: docker invoked on the zero-engine NO_PROMPT path: $*" >&2; return 99; }
    sel="$(NO_PROMPT=1 engine_select 2>/dev/null)" || true
    engine_ensure "$sel" 2>&1                    # must hard-fail with brew remedy
  '
  rm -f "$ENV_FILE"
)"
grep -q 'FATAL: docker invoked' <<<"$out" && { err "17: zero-engine NO_PROMPT path made a docker call: $out"; exit 1; }
grep -q 'brew install' <<<"$out" || { err "17: NO_PROMPT zero-engine path did not print brew remedy: $out"; exit 1; }
ok "17: NO_PROMPT zero-engine path hard-fails with remedy"
