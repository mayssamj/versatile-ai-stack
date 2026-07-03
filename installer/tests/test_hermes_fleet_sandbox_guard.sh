#!/usr/bin/env bash
# test_hermes_fleet_sandbox_guard.sh — BEHAVIORAL companion to
# test_upgrade_exhaustive.sh's static services.yml assertion (ccf9395, the
# hermes_fleet 0.16->0.18 "sandbox not found" bug). That test only proves
# services.yml DECLARES a non-empty `sandbox:` field; it can't prove
# up_openshell's runtime guard actually fires if the field were ever missing
# again (e.g. a future refactor of svc_sandbox(), or a NEW sandbox-based
# service added without the field before the static assertion is regenerated).
# This sources the REAL up_openshell() function body out of upgrade.sh — same
# sed-range idiom as test_upgrade_resilience.sh's harness, since upgrade.sh
# self-runs upgrade_main at load and can't be sourced whole — and drives it
# with svc_sandbox/openshell stubbed, to prove:
#   (A) svc_sandbox()=="-"  -> RESULT=FAILED, the actionable message is
#       printed, and the in-sandbox `openshell sandbox exec` is NEVER invoked
#       (a naive check of RESULT=FAILED alone is NOT enough — a DIFFERENT
#       downstream failure, e.g. an unresolved phase script, produces the
#       same RESULT; this is why (A) also asserts the exact message AND that
#       openshell was never called — verified to have teeth by re-running
#       this file against a copy of upgrade.sh with the guard deleted: only
#       the RESULT=FAILED assertion stayed green, the message + non-exec
#       assertions correctly went red).
#   (B) svc_sandbox()==""   -> same guard (the other half of the `-z` check).
#   (C) a valid sandbox     -> the guard does NOT false-trip; the real pip
#       path still runs through to a genuine RESULT.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPG="$ROOT/installer/lib/upgrade.sh"
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); echo "  ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

_preamble() {
  cat <<PRE
set -uo pipefail
DRY=0; VER_OVERRIDE=""
err(){  printf 'ERR: %s\n' "\$*" >&2; }
warn(){ printf 'WARN: %s\n' "\$*" >&2; }
note(){ :; }
source <(sed -n '/^up_openshell()/,/^}/p' "$UPG")
PRE
}

echo "== (A) missing 'sandbox:' (svc_sandbox returns '-') -> RESULT=FAILED + clear message, NEVER execs into the sandbox =="
{ _preamble; cat <<'H'
svc_sandbox(){ echo "-"; }
svc_phase(){ echo "04f"; }
openshell(){ echo "SHOULD_NOT_BE_CALLED: openshell $*" >&2; return 1; }
up_openshell hermes_fleet
echo "RESULT=$RESULT"
H
} > "$TMP/hA.sh"
oA="$("$BASH" "$TMP/hA.sh" 2>&1)"
echo "$oA" | grep -q '^RESULT=FAILED$'                        && ok "RESULT=FAILED on empty sandbox" || bad "RESULT not FAILED: $oA"
echo "$oA" | grep -q "no 'sandbox:' declared in services.yml" && ok "actionable error message printed" || bad "message missing: $oA"
echo "$oA" | grep -q 'SHOULD_NOT_BE_CALLED'                   && bad "guard did NOT prevent the sandbox exec (ran anyway!)" || ok "never execs into the sandbox (fails before the openshell call)"

echo "== (B) empty-string sandbox ('') also trips the guard =="
{ _preamble; cat <<'H'
svc_sandbox(){ echo ""; }
svc_phase(){ echo "04f"; }
openshell(){ echo "SHOULD_NOT_BE_CALLED" >&2; return 1; }
up_openshell hermes_fleet
echo "RESULT=$RESULT"
H
} > "$TMP/hB.sh"
oB="$("$BASH" "$TMP/hB.sh" 2>&1)"
echo "$oB" | grep -q '^RESULT=FAILED$' && ok "RESULT=FAILED on '' sandbox" || bad "RESULT not FAILED: $oB"

echo "== (C) valid sandbox -> guard does NOT false-trip; the real pip path still runs =="
{ _preamble; cat <<'H'
svc_sandbox(){ echo "hermes-fleet-v1"; }
svc_phase(){ echo "04f"; }
openshell(){ echo "Successfully installed hermes-agent-0.18.0"; }
resolve_phase_script_inline(){ echo "$TMP_SCRIPT"; }
up_openshell hermes_fleet
echo "RESULT=$RESULT"
H
} > "$TMP/hC.sh"
echo 'exit 0' > "$TMP/dummy_phase.sh"; chmod +x "$TMP/dummy_phase.sh"
oC="$(TMP_SCRIPT="$TMP/dummy_phase.sh" "$BASH" "$TMP/hC.sh" 2>&1)"
echo "$oC" | grep -q '^RESULT=upgraded$' && ok "guard does not false-trip on a valid sandbox (RESULT=upgraded)" || bad "unexpected RESULT: $oC"

echo
echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
