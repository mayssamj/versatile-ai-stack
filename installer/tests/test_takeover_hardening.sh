#!/usr/bin/env bash
# test_takeover_hardening.sh — regression tests for the 2026-07-05 codebase-takeover
# hardening pass. Each test corresponds to a CONFIRMED defect fixed in that pass and is
# HERMETIC + CI-SAFE: temp sandboxes, stubbed binaries on PATH, NO real docker/network,
# NO live-stack mutation. Run: bash installer/tests/test_takeover_hardening.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Resolve a bash 5+ interpreter for the strict-shell sub-invocations, portably
# (not a hardcoded Homebrew path). Prefer the running interpreter, then the usual
# Homebrew locations, then PATH.
BASH5="${BASH:-}"
if [[ -z "$BASH5" || "${BASH_VERSINFO[0]:-0}" -lt 5 ]]; then
  for _b in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null)"; do
    [[ -x "$_b" ]] && { BASH5="$_b"; break; }
  done
fi
PASS=0; FAIL=0
# NOTE: named t_ok/t_bad (not ok/bad) — sourcing common.sh into the test shell
# defines its own ok()/warn()/err(), which would clobber plain ok()/bad().
t_ok(){  PASS=$((PASS+1)); echo "  ok   $1"; }
t_bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
section(){ echo; echo "== $1 =="; }

# fresh_stack — make a throwaway $AI_STACK/.env sandbox and (re)source common+env there.
fresh_stack() {
  AI_STACK="$(mktemp -d)"; export AI_STACK
  ENV_FILE="$AI_STACK/.env"; export ENV_FILE
  export RUN_ID="test-hardening"
  # shellcheck disable=SC1090
  source "$ROOT/installer/lib/common.sh" >/dev/null 2>&1
  source "$ROOT/installer/lib/env.sh"    >/dev/null 2>&1
}

# ---------------------------------------------------------------------------
# FIX-1 (#0): set_env must NOT C-escape-expand values (awk -v bug). A value with a
# literal backslash-escape (e.g. a token containing `\n`) must be stored verbatim as
# ONE .env line, and read back byte-identical — never split into two lines.
# ---------------------------------------------------------------------------
section "FIX-1 set_env preserves backslash-escape values (env.sh)"
fresh_stack
secret='abc\nxyz'                     # literal backslash + n (a plausible pasted token)
set_env TOKEN "$secret" >/dev/null 2>&1 || t_bad "set_env returned non-zero"
if grep -qx 'xyz' "$ENV_FILE"; then t_bad "orphan 'xyz' line present — value was split"; else t_ok "no orphan line from split value"; fi
got="$(get_env TOKEN)"
[[ "$got" == "$secret" ]] && t_ok "get_env returns verbatim backslash-n" || t_bad "get_env returned '$got' != '$secret'"
set_env TOK2 'a\tb' >/dev/null 2>&1
got2="$(get_env TOK2)"
[[ "$got2" == 'a\tb' ]] && t_ok "tab-escape round-trips" || t_bad "tab-escape corrupted: '$got2'"
# A double-backslash must also survive.
set_env TOK3 'x\\y' >/dev/null 2>&1
got3="$(get_env TOK3)"
[[ "$got3" == 'x\\y' ]] && t_ok "double-backslash round-trips" || t_bad "double-backslash corrupted: '$got3'"
rm -rf "$AI_STACK"

# ---------------------------------------------------------------------------
# FIX-2 (#1/#6): `gc` must NOT offer to remove healthy RUNNING containers. The
# ai-stack.partial=true label can never be cleared (immutable), so gc must exclude
# running (and mark_ready'd) containers. Also: mark_ready must actually record
# readiness (the old docker update --label-add was a silent no-op).
# ---------------------------------------------------------------------------
section "FIX-2 gc excludes running containers; mark_ready records readiness"

# --- 2a: mark_ready writes a durable marker (no longer a no-op) ---
fresh_stack
source "$ROOT/installer/lib/docker.sh" >/dev/null 2>&1
mark_ready "litellm"
if [[ -f "$AI_STACK/installer/state/ready/litellm" ]]; then t_ok "mark_ready records a readiness marker"; else t_bad "mark_ready did not write a marker (still a no-op?)"; fi
container_ready_marked "litellm" && t_ok "container_ready_marked true after mark_ready" || t_bad "container_ready_marked false after mark_ready"
container_ready_marked "phoenix" && t_bad "container_ready_marked true for un-marked container" || t_ok "container_ready_marked false for un-marked container"
rm -rf "$AI_STACK"

# --- 2b: gc.sh excludes a RUNNING partial container, lists only the dead one ---
STUBDIR="$(mktemp -d)"
cat > "$STUBDIR/docker" <<'STUB'
#!/usr/bin/env bash
# Fake docker: `ps -a --filter label=ai-stack.partial=true` -> two partial containers
# (one running "litellm", one exited "halfdead"); `ps` (running) -> only "litellm".
if [[ "$1" == "ps" ]]; then
  shift
  if [[ "$*" == *"-a"* ]]; then printf '%s\n' litellm halfdead; else printf '%s\n' litellm; fi
  exit 0
fi
exit 0
STUB
chmod +x "$STUBDIR/docker"
gc_out="$(PATH="$STUBDIR:$PATH" NO_PROMPT=1 $BASH5 "$ROOT/installer/lib/gc.sh" 2>&1 || true)"
if grep -q 'halfdead' <<<"$gc_out"; then t_ok "gc lists the genuinely-dead partial container (halfdead)"; else t_bad "gc did not list the dead orphan"; fi
if grep -qE '^\s*-\s*litellm' <<<"$gc_out"; then t_bad "gc listed the RUNNING container litellm for removal (mass-delete danger)"; else t_ok "gc excluded the running container litellm from removal"; fi
grep -qi 'Excluded' <<<"$gc_out" && t_ok "gc reports it excluded healthy containers" || t_bad "gc did not report exclusions"
rm -rf "$STUBDIR"

# ---------------------------------------------------------------------------
# FIX-3 (#10): http_ok must report a DEAD server as unhealthy. The `|| echo 000`
# inside the substitution doubled curl's 000 to "000000" != "000" → false-healthy.
# We extract the SHIPPED http_ok from each start script and exercise it.
# ---------------------------------------------------------------------------
section "FIX-3 http_ok reports a dead server as unhealthy (start-paperclip/unsloth)"
DEAD_URL="http://127.0.0.1:59999/health"   # nothing listens here
for f in bin/start-paperclip.sh bin/start-unsloth.sh; do
  fn="$(sed -n '/^http_ok() {/,/^}/p' "$ROOT/$f")"
  [[ -n "$fn" ]] || { t_bad "$f: could not extract http_ok"; continue; }
  # Run in a strict subshell (set -e) so we also prove it does not abort on curl failure.
  if ( set -Eeuo pipefail; eval "$fn"; http_ok "$DEAD_URL" ) 2>/dev/null; then
    t_bad "$f: http_ok returned HEALTHY for a dead server"
  else
    t_ok "$f: http_ok returns unhealthy for a dead server (no set -e abort)"
  fi
done

# ---------------------------------------------------------------------------
# FIX-4 (#2): the hermes post-upgrade version read must not abort `upgrade all`.
# The bare `_postv="$(_openshell_exec_retry ... | sed | head)"` had no `|| true`, so
# a persistent relay failure (non-zero rc) tripped errexit and killed the whole run.
# ---------------------------------------------------------------------------
section "FIX-4 upgrade hermes post-version read is guarded (upgrade.sh)"
# Static: the real _postv= line carries a || true / rc guard.
postv_line="$(grep -n '_postv="\$(_openshell_exec_retry' "$ROOT/installer/lib/upgrade.sh" | head -1)"
if grep -q '_postv="\$(_openshell_exec_retry.*)" *|| *\(true\|_[a-z]*=\$?\)' "$ROOT/installer/lib/upgrade.sh"; then
  t_ok "upgrade.sh _postv read is guarded (|| true)"
else
  t_bad "upgrade.sh _postv read is NOT guarded — errexit will abort upgrade all"
fi
# Behavioral: prove the shell semantics the guard relies on, in FRESH strict shells
# (errexit must be active from the top — a subshell that sets -e from inside a
# command-substitution/condition context has -e ignored, so we use bash -c).
guarded_out="$($BASH5 -c 'set -Eeuo pipefail; shopt -s inherit_errexit
  _fail(){ return 1; }
  v="$(_fail | sed -n "s/x/y/p" | head -1)" || true
  echo REACHED' 2>/dev/null || true)"
unguarded_out="$($BASH5 -c 'set -Eeuo pipefail; shopt -s inherit_errexit
  _fail(){ return 1; }
  v="$(_fail | sed -n "s/x/y/p" | head -1)"
  echo REACHED' 2>/dev/null || true)"
[[ "$guarded_out" == *REACHED* ]] && t_ok "guarded form continues the run" || t_bad "guarded form did not continue"
[[ "$unguarded_out" == *REACHED* ]] && t_bad "unguarded form did NOT abort (semantics assumption wrong)" || t_ok "unguarded form aborts (confirms the bug class)"

# ---------------------------------------------------------------------------
# FIX-5 (#3): adopt falkordb smoke must probe the real bind (127.0.10.7:6379), not
# 127.0.0.1 (nothing listens there → guaranteed false "smoke fail" after recreate).
# ---------------------------------------------------------------------------
section "FIX-5 adopt falkordb smoke targets the correct bind IP (adopt.sh)"
fk_block="$(sed -n '/falkordb)/,/;;/p' "$ROOT/installer/lib/adopt.sh")"
grep -q '127.0.10.7/6379' <<<"$fk_block" && t_ok "adopt falkordb smoke probes 127.0.10.7:6379 (the alias bind)" || t_bad "adopt falkordb smoke does not probe 127.0.10.7"
grep -q 'dev/tcp/127.0.0.1/6379' <<<"$fk_block" && t_bad "adopt falkordb smoke still probes 127.0.0.1 (always fails)" || t_ok "adopt falkordb smoke no longer probes 127.0.0.1"
# Behavioral: the /dev/tcp retry mechanism connects to a live listener and fails on a dead port.
probe_tcp() {  # host port -> 0 if connectable within ~3s
  local h="$1" p="$2" i
  for i in 1 2 3; do (exec 3<>/dev/tcp/"$h"/"$p") 2>/dev/null && { exec 3>&- 3<&- 2>/dev/null; return 0; }; sleep 1; done
  return 1
}
PORTF="$(mktemp)"
python3 -c '
import socket,time,sys
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(("127.0.0.1",0)); s.listen(5)
open(sys.argv[1],"w").write(str(s.getsockname()[1]))
end=time.time()+5
while time.time()<end:
    s.settimeout(1)
    try: c,_=s.accept(); c.close()
    except Exception: pass
' "$PORTF" &
LPID=$!
sleep 0.6
LPORT="$(cat "$PORTF" 2>/dev/null || echo 0)"
if [[ "$LPORT" =~ ^[0-9]+$ && "$LPORT" != 0 ]]; then
  probe_tcp 127.0.0.1 "$LPORT" && t_ok "tcp retry probe connects to a live listener" || t_bad "tcp probe failed against a live listener"
else
  t_bad "could not start test listener"
fi
probe_tcp 127.0.0.1 59998 && t_bad "tcp probe wrongly succeeded on a dead port" || t_ok "tcp retry probe fails on a dead port"
kill "$LPID" 2>/dev/null || true; rm -f "$PORTF"

# ---------------------------------------------------------------------------
# FIX-6 (#8/#47): `doctor --all` must run every check (and enable DOCTOR_ALL deep
# probes), not be treated as a name filter matching nothing (silent 0-check exit 0).
# A MISTYPED filter matching zero checks must exit non-zero, not silently green.
# ---------------------------------------------------------------------------
section "FIX-6 doctor --all runs checks; mistyped filter fails loud (doctor.sh)"
# Static: --all maps to DOCTOR_ALL + empty filter.
if grep -qE 'FILTER == "--all"|"\$FILTER" == "--all"' "$ROOT/installer/doctor/doctor.sh" \
   && grep -q 'DOCTOR_ALL=1' "$ROOT/installer/doctor/doctor.sh"; then
  t_ok "doctor.sh maps --all to DOCTOR_ALL=1 (not a name filter)"
else
  t_bad "doctor.sh does not special-case --all"
fi
# Behavioral: a filter matching NO checks now exits non-zero (skips every check, so no
# docker/diagnose runs — safe against the live daemon).
rc=0; NO_PROMPT=1 $BASH5 "$ROOT/installer/doctor/doctor.sh" __nomatch_zzz__ >/dev/null 2>&1 || rc=$?
[[ "$rc" == "2" ]] && t_ok "mistyped filter exits 2 (was silent exit 0)" || t_bad "mistyped filter exit=$rc (expected 2)"
# Behavioral: a valid filter still runs (a host-local, docker-free check) → exit != 2.
rc=0; NO_PROMPT=1 $BASH5 "$ROOT/installer/doctor/doctor.sh" lo0_aliases >/dev/null 2>&1 || rc=$?
[[ "$rc" != "2" ]] && t_ok "valid filter runs at least one check (exit $rc != 2)" || t_bad "valid filter wrongly hit the no-match guard"

# ---------------------------------------------------------------------------
# FIX-7 (#17): reset's managed-container sweep must be EXHAUSTIVE — one failed
# `docker rm -f` must not abort the reset under set -e. The sweep is now the shared
# function _remove_managed_containers, called by BOTH the hard and nuke branches.
# We EXTRACT the real function and RUN it (not a simulation) with a stubbed docker —
# this catches the `local`-outside-a-function class the §24 review flagged, which a
# grep/simulate test misses. (Reviewer-hardened after batch 2.)
# ---------------------------------------------------------------------------
section "FIX-7 reset sweep continues past a single rm failure (reset.sh, real fn)"
# Both branches must call the shared function (fixes the hard-branch gap + de-dups).
call_sites="$(grep -c '^ *_remove_managed_containers$' "$ROOT/installer/lib/reset.sh" || echo 0)"
[[ "$call_sites" -ge 2 ]] && t_ok "both hard+nuke branches call _remove_managed_containers ($call_sites sites)" || t_bad "expected >=2 call sites, found $call_sites"
grep -q '^_remove_managed_containers() {' "$ROOT/installer/lib/reset.sh" && t_ok "the sweep is a real function (local is valid inside it)" || t_bad "_remove_managed_containers is not defined as a function"
# Extract + RUN the real function under set -e with a stubbed docker where 'halfdead'
# fails to remove. Assert: it completes (no abort), removes the good ones, and warns
# about the failure. A `local`-outside-function bug would make this ERROR out.
fn_body="$(sed -n '/^_remove_managed_containers() {/,/^}/p' "$ROOT/installer/lib/reset.sh")"
[[ -n "$fn_body" ]] || t_bad "could not extract _remove_managed_containers"
sweep_out="$($BASH5 -c '
  set -Eeuo pipefail; shopt -s inherit_errexit
  ok(){ echo "OK $*"; }; warn(){ echo "WARN $*"; }
  docker(){ if [[ "$1" == ps ]]; then printf "%s\n" litellm halfdead qdrant; return 0; fi
            if [[ "$1" == rm ]]; then [[ "$3" == halfdead ]] && return 1 || return 0; fi; return 0; }
  '"$fn_body"'
  _remove_managed_containers
  echo "SWEEP_COMPLETED"' 2>&1 || true)"
[[ "$sweep_out" == *SWEEP_COMPLETED* ]] && t_ok "real sweep function runs to completion under set -e (no local-scope abort)" || t_bad "sweep aborted before completion: $sweep_out"
grep -q 'OK removed litellm' <<<"$sweep_out" && grep -q 'OK removed qdrant' <<<"$sweep_out" && t_ok "sweep removed the healthy containers past the failing one" || t_bad "sweep did not remove all healthy containers: $sweep_out"
grep -q 'WARN.*halfdead' <<<"$sweep_out" && t_ok "sweep warns about the container it could not remove" || t_bad "sweep did not warn about the failed removal: $sweep_out"

# ---------------------------------------------------------------------------
# FIX-8 (#59): aitown --nuke must NOT wipe the world when the pre-delete backup
# failed (fail-closed, unless AI_STACK_FORCE_WIPE=1). The old code warned + wiped.
# ---------------------------------------------------------------------------
section "FIX-8 aitown --nuke fails closed when backup fails (start-aitown.sh)"
nuke_block="$(sed -n '/backup-before-delete/,/rm -rf "\$AT_DATA"/p' "$ROOT/bin/start-aitown.sh")"
grep -q 'ABORTING aitown --nuke' <<<"$nuke_block" && t_ok "aitown --nuke aborts on backup failure" || t_bad "aitown --nuke does not abort on backup failure"
grep -q 'AI_STACK_FORCE_WIPE' <<<"$nuke_block" && t_ok "aitown --nuke honors AI_STACK_FORCE_WIPE override" || t_bad "aitown --nuke lacks the force-wipe override"
# The rm -rf must be REACHED only after a verified backup or the force flag — assert the
# abort (exit 1) sits BETWEEN the backup attempt and the rm.
if awk '/cp -a "\$AT_DATA"/{seen=1} seen&&/ABORTING aitown --nuke/{ab=1} seen&&/rm -rf "\$AT_DATA"/{print (ab?"GUARDED":"UNGUARDED"); exit}' "$ROOT/bin/start-aitown.sh" | grep -q GUARDED; then
  t_ok "abort guard precedes the rm -rf"
else
  t_bad "rm -rf is not guarded by the abort"
fi

echo
echo "TOTAL: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
