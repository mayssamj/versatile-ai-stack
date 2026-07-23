#!/usr/bin/env bash
# test_upgrade_resilience.sh — the three upgrade robustness fixes, BEHAVIORALLY:
#   (1) EXIT-trap: the honesty summary survives a mid-run abort; prints EXACTLY once on
#       the normal path (no double-print); the lock is released even if print_summary
#       itself aborts; and INT/TERM STOP the run (not merely unlock mid-loop).
#   (2) bash-5: NO bare-`bash` sub-dispatch survives in mayssam-ai-stack.sh OR upgrade.sh
#       (all go through "$BASH"), and upgrade.sh self-gates to bash-5.
#   (3) compose pinned-tag: the logic lives in versions.sh (_compose_lone_semver_tag,
#       behaviorally tested in test_versions.sh); here we assert check_one CALLS it.
# The harnesses extract the REAL functions — including lock_release (common.sh) and the
# REAL _arm_upgrade_traps (so a dropped INT/TERM trap fails a BEHAVIORAL test, not just a
# name grep) — since upgrade.sh self-runs upgrade_main and can't be sourced whole.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPG="$ROOT/installer/lib/upgrade.sh"; VZ="$ROOT/mayssam-ai-stack.sh"; CMN="$ROOT/installer/lib/common.sh"
BASH5="${BASH:-/opt/homebrew/bin/bash}"
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); echo "  ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
have(){ grep -qF "$1" "$UPG"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Shared harness preamble ($1 = lock dir): the REAL lock_release + record_row +
# print_summary + upgrade_on_exit + _arm_upgrade_traps, with note/hdr stubbed.
_preamble() {
  cat <<PRE
set -Eeuo pipefail; shopt -s inherit_errexit
note(){ :; }; hdr(){ printf '== %s ==\n' "\$*"; }
SUMMARY=(); _SUMMARY_PRINTED=0; LOCKDIR="\$1"
source <(sed -n '/^lock_release()/,/^}/p' "$CMN")
source <(sed -n '/^record_row()/,/^}/p; /^print_summary()/,/^}/p; /^upgrade_on_exit()/,/^}/p; /^_arm_upgrade_traps()/,/^}/p' "$UPG")
PRE
}

echo "== (1a) abort mid-run: summary survives + lock released + exit preserved =="
L1="$TMP/l1"; mkdir -p "$L1"
{ _preamble; cat <<'H'
record_row svcX compose upgraded n/a "1.0->1.1"
_arm_upgrade_traps
echo "$DELIBERATELY_UNSET_MIDLOOP"
echo SHOULD_NOT_PRINT_AFTER_ABORT
H
} > "$TMP/h1.sh"
o1="$("$BASH5" "$TMP/h1.sh" "$L1" 2>&1)"; r1=$?
echo "$o1" | grep -q 'Upgrade summary'             && ok "summary printed despite abort" || bad "summary lost on abort"
echo "$o1" | grep -q 'svcX'                         && ok "recorded row survived" || bad "row lost"
if echo "$o1" | grep -q SHOULD_NOT_PRINT_AFTER_ABORT; then bad "did not actually abort"; else ok "genuinely aborted"; fi
[[ ! -d "$L1" ]]                                    && ok "lock released via lock_release" || bad "lock NOT released"
(( r1 != 0 ))                                       && ok "abort exit code preserved" || bad "exit swallowed"

echo "== (1b) normal path prints the summary EXACTLY once (no double-print) =="
L2="$TMP/l2"; mkdir -p "$L2"
{ _preamble; cat <<'H'
record_row svcY compose up-to-date n/a "1.0"
_arm_upgrade_traps
print_summary        # explicit (normal-path) call
exit 0               # -> EXIT trap fires -> print_summary again -> MUST no-op
H
} > "$TMP/h2.sh"
o2="$("$BASH5" "$TMP/h2.sh" "$L2" 2>&1)"; r2=$?
n2="$(printf '%s\n' "$o2" | grep -c 'Upgrade summary')"
(( n2 == 1 ))       && ok "summary header appears exactly once (got $n2)" || bad "double-print: header appears $n2 times"
[[ ! -d "$L2" ]]    && ok "normal path released the lock" || bad "normal path leaked the lock"
(( r2 == 0 ))       && ok "normal exit 0 preserved" || bad "normal exit=$r2"

echo "== (1c) print_summary aborting STILL releases the lock (subshell isolation) =="
L3="$TMP/l3"; mkdir -p "$L3"
{ _preamble; cat <<'H'
print_summary(){ echo "== Upgrade summary =="; echo "$UNSET_INSIDE_PRINT"; }   # aborts under set -u
record_row svcZ compose upgraded n/a x
_arm_upgrade_traps
echo "$ABORT_MAIN"
H
} > "$TMP/h3.sh"
"$BASH5" "$TMP/h3.sh" "$L3" >/dev/null 2>&1 || true
[[ ! -d "$L3" ]]    && ok "lock released even though print_summary aborted" || bad "lock LEAKED when print_summary aborted"

echo "== (1d) SIGTERM STOPS the run + releases the lock (via the REAL _arm_upgrade_traps) =="
L4="$TMP/l4"; mkdir -p "$L4"
{ _preamble; cat <<'H'
record_row svcT compose upgraded n/a x
_arm_upgrade_traps
echo READY
sleep 5
echo SHOULD_NOT_REACH
H
} > "$TMP/h4.sh"
"$BASH5" "$TMP/h4.sh" "$L4" > "$TMP/o4" 2>&1 &
hp=$!
for _ in $(seq 1 50); do grep -q READY "$TMP/o4" 2>/dev/null && break; sleep 0.1; done
kill -TERM "$hp" 2>/dev/null; wait "$hp"; r4=$?
if grep -q SHOULD_NOT_REACH "$TMP/o4"; then bad "SIGTERM did NOT stop the run"; else ok "SIGTERM stopped the run (loop halted)"; fi
[[ ! -d "$L4" ]]  && ok "SIGTERM released the lock" || bad "SIGTERM leaked the lock"
(( r4 == 143 ))   && ok "SIGTERM exit code 143" || bad "SIGTERM exit=$r4 (expect 143)"

echo "== (1e) static: BOTH lock_acquire sites arm via _arm_upgrade_traps; it arms EXIT+INT+TERM =="
nla="$(grep -c 'lock_acquire$' "$UPG")"
narm="$(grep -A2 'lock_acquire$' "$UPG" | grep -c '_arm_upgrade_traps')"
(( nla >= 2 && narm == nla )) && ok "all $nla lock_acquire sites call _arm_upgrade_traps" || bad "_arm_upgrade_traps called at $narm of $nla sites"
fn="$(sed -n '/^_arm_upgrade_traps()/,/^}/p' "$UPG")"
printf '%s' "$fn" | grep -q "trap 'upgrade_on_exit' EXIT" && ok "_arm_upgrade_traps arms EXIT" || bad "EXIT not armed"
printf '%s' "$fn" | grep -q "trap 'exit 130' INT"         && ok "_arm_upgrade_traps arms INT (stop)"  || bad "INT not armed"
printf '%s' "$fn" | grep -q "trap 'exit 143' TERM"        && ok "_arm_upgrade_traps arms TERM (stop)" || bad "TERM not armed"
have 'lock_release' && ok "upgrade_on_exit delegates to lock_release (single source of truth)" || bad "no lock_release delegation"
grep -q '(( _SUMMARY_PRINTED )) && return 0' "$UPG" && ok "print_summary idempotency guard present" || bad "no idempotency guard"

echo "== (2) bash-5: NO bare-bash sub-dispatch remains; upgrade.sh self-gates =="
for f in "$VZ" "$UPG"; do
  hits="$(grep -nE '(^|[^"$A-Za-z_])bash +"' "$f" | grep -vE '^[0-9]+: *#' || true)"
  [[ -z "$hits" ]] && ok "$(basename "$f"): no bare-'bash \"…' dispatch" || { bad "$(basename "$f"): bare-bash dispatch remains:"; printf '%s\n' "$hits" | sed 's/^/       /'; }
done
grep -qE 'BASH_VERSINFO\[0\] *< *5' "$UPG" && ok "upgrade.sh self-gates to bash-5" || bad "upgrade.sh has no bash-5 self-gate"

echo "== (3) compose pinned-tag: check_one CALLS the sourceable helper =="
have '_compose_lone_semver_tag' && ok "check_one calls _compose_lone_semver_tag (behaviorally tested in test_versions.sh)" || bad "check_one does not call the tag helper"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
