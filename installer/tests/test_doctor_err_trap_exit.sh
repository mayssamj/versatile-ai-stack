#!/usr/bin/env bash
# test_doctor_err_trap_exit.sh — offline unit + e2e test for the ERR-trap-on-leaf-dispatch fix in
# mayssam-ai-stack.sh. Commands whose non-zero exit is a normal DIAGNOSTIC/QUERY RESULT (doctor: checks
# failed 1/2; verify: probes failed; test: smoke failed; url/ingress/... : bad input) are dispatched
# through the diag_exit() helper. Under the top-level `set -Eeuo pipefail` + ERR trap, the OLD bare /
# `|| return $?` dispatch made a normal non-zero print a spurious "✗ ERR line N: ... (exit=1)" that
# reads like a crash — the user's "the script failed when I called doctor" report. diag_exit runs the
# command in a `||` context (suppressing errexit + the ERR trap for its WHOLE subtree, which also
# revives cmd_verify's previously-dead failure-path), then `exit`s with the captured code so it is
# PRESERVED for scripting/CI without the false alarm. No network / no model / no live stack.
# Run: bash installer/tests/test_doctor_err_trap_exit.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VZ="$HERE/../../mayssam-ai-stack.sh"
[[ -f "$VZ" ]] || { echo "  [skip] mayssam-ai-stack.sh not found at $VZ"; exit 0; }

# Pull the REAL diag_exit definition (no copy = no drift). It is a one-liner; assert it looks
# balanced (ends in `}`) so a future multi-line refactor fails loudly HERE with a clear message
# instead of via a cryptic truncated-eval error.
DIAG_SRC="$(grep -E '^diag_exit\(\)' "$VZ")"
[[ -n "$DIAG_SRC" && "$DIAG_SRC" == *'}' ]] \
  || { echo "  FAIL: could not extract a balanced diag_exit() one-liner from $VZ"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0

# unit_case <label> <callee-def> <call-args> <want-exit>
# Defines <callee>, then runs it via the REAL diag_exit under the SAME shell posture as
# mayssam-ai-stack.sh (set -Eeuo pipefail + inherit_errexit/nullglob + the ERR trap). Asserts no
# spurious ERR line AND that the exit code is preserved exactly.
unit_case() {
  local label="$1" callee="$2" call="$3" want="$4" out
  out="$(
    set +e
    ( set -Eeuo pipefail
      shopt -s inherit_errexit nullglob
      trap 'echo "SPURIOUS-ERR"' ERR
      eval "$DIAG_SRC"
      eval "$callee"
      eval "diag_exit $call"
    ) 2>&1
    echo "OUTER=$?"
  )"
  if ! grep -q SPURIOUS-ERR <<<"$out" && grep -qx "OUTER=$want" <<<"$out"; then
    PASS=$((PASS+1)); echo "  ok   $label (-> exit=$want, no ERR trap)"
  else
    FAIL=$((FAIL+1)); echo "  FAIL $label (want exit=$want):"; echo "$out" | sed 's/^/      /'
  fi
}

# A callee that returns a code (like a plain cmd_doctor whose subprocess exits N). The exact code
# must survive (2 stays 2) — doctor.sh distinguishes 0 healthy / 1 unhealed / 2 error.
unit_case "exit 0 passthrough" 'f(){ bash -c "exit 0"; }' 'f' 0
unit_case "exit 1 preserved"   'f(){ bash -c "exit 1"; }' 'f' 1
unit_case "exit 2 preserved"   'f(){ bash -c "exit 2"; }' 'f' 2

# The cmd_verify class: a mid-body subprocess fails, then MORE work must still run (the real bug
# was that errexit aborted at the probe, so the failure-path messaging was DEAD code). Under
# diag_exit the whole body must complete AND the code be preserved. Assert the post-fail marker ran.
verify_out="$(
  set +e
  ( set -Eeuo pipefail; shopt -s inherit_errexit nullglob
    trap 'echo "SPURIOUS-ERR"' ERR
    eval "$DIAG_SRC"
    cmd_verify_like(){ bash -c "exit 1"; local rc=$?; echo "FAILPATH-RAN"; return "$rc"; }
    diag_exit cmd_verify_like
  ) 2>&1; echo "OUTER=$?"
)"
if ! grep -q SPURIOUS-ERR <<<"$verify_out" && grep -q FAILPATH-RAN <<<"$verify_out" && grep -qx "OUTER=1" <<<"$verify_out"; then
  PASS=$((PASS+1)); echo "  ok   cmd_verify class: body completes past a failed probe, exit=1 (dead-code revived)"
else
  FAIL=$((FAIL+1)); echo "  FAIL cmd_verify class:"; echo "$verify_out" | sed 's/^/      /'
fi

# Positive control (non-vacuity): WITHOUT diag_exit, the SAME failing callee as a bare, non-conditional
# dispatch MUST trip the ERR trap — proving these assertions can actually detect a regression.
ctrl_out="$(
  set +e
  ( set -Eeuo pipefail; shopt -s inherit_errexit nullglob
    trap 'echo "SPURIOUS-ERR"' ERR
    f(){ bash -c "exit 1"; }
    f
  ) 2>&1; echo "OUTER=$?"
)"
if grep -q SPURIOUS-ERR <<<"$ctrl_out"; then
  PASS=$((PASS+1)); echo "  ok   control: bare dispatch DOES trip the ERR trap (assertions are non-vacuous)"
else
  FAIL=$((FAIL+1)); echo "  FAIL control: bare dispatch did not trip the trap — assertions may be vacuous:"; echo "$ctrl_out" | sed 's/^/      /'
fi

# Wiring guard (static, instant): every diagnostic/query case-branch must dispatch through diag_exit.
# A future edit that drops `diag_exit` from any of these branches reintroduces the reported bug; this
# catches it for ALL 10 commands without a slow live run (the `url` e2e below proves the pattern end-to-end).
wiring_ok=1
for fn in cmd_doctor cmd_verify cmd_test cmd_embedding cmd_status cmd_model cmd_fleet cmd_docker_engine cmd_ingress cmd_url; do
  grep -qF "diag_exit ${fn} " "$VZ" || { echo "  FAIL wiring: '${fn}' is not routed via diag_exit in mayssam-ai-stack.sh"; wiring_ok=0; }
done
if (( wiring_ok )); then PASS=$((PASS+1)); echo "  ok   wiring: all 10 diagnostic/query branches dispatch through diag_exit"
else FAIL=$((FAIL+1)); fi

# E2E through the REAL main() dispatch: `url <unknown-alias>` exits non-zero fast (bin/url) and is
# routed via diag_exit. Guards the actual case-branch wiring (not just the helper): the real command
# must emit NO "ERR line" and preserve a non-zero exit code.
e2e_out="$(bash "$VZ" url __no_such_alias_xyzzy__ 2>&1)"; e2e_rc=$?
if ! grep -q "ERR line" <<<"$e2e_out" && (( e2e_rc != 0 )); then
  PASS=$((PASS+1)); echo "  ok   e2e: real 'url <unknown>' dispatch — no ERR line, exit=$e2e_rc preserved"
else
  FAIL=$((FAIL+1)); echo "  FAIL e2e 'url <unknown>' (rc=$e2e_rc):"; echo "$e2e_out" | sed 's/^/      /'
fi

echo; echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
