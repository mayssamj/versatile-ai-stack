#!/usr/bin/env bash
# test_upgrade_exit_and_coverage.sh — §24 audit fixes for `vz-ai-stack.sh upgrade`
# (2026-07-14). Static mirror of upgrade.sh (it self-runs upgrade_main on load and
# cannot be sourced in isolation — same reason as test_upgrade_honesty.sh) PLUS
# behavioral logic tables for the parts that are decidable without a live run.
#
#   F1 — an unhealthy reverify ('warn') must make RESULT a FAILED* value so the
#        exit gate (which reads RESULT, field 3) returns non-zero. Previously the
#        warn landed only in the REVERIFY column and the run still exited 0.
#   F3 — `--outdated` must ALWAYS disclose the sandbox/CLI/pip/fleet plane it cannot
#        reach (not only when 0 are outdated — which, with rolling upstreams, is
#        almost never, so the disclosure effectively never printed).
#   F4 — `--all` combined with `--outdated` is inert → must warn.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPG="$ROOT/installer/lib/upgrade.sh"
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); echo "  ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
# `--` ends grep options so a needle that STARTS with '--' (e.g. a '--all …' usage
# string) is treated as a pattern, not a flag.
have(){ grep -qF -- "$1" "$UPG"; }
haveE(){ grep -qE -- "$1" "$UPG"; }

[[ -f "$UPG" ]] || { bad "installer/lib/upgrade.sh not found"; echo; echo "RESULT: $PASS passed, $FAIL failed"; exit 1; }

echo "== upgrade.sh parses (bash -n) =="
bash -n "$UPG" 2>/dev/null && ok "upgrade.sh syntax valid" || bad "upgrade.sh has a syntax error"

echo "== F1: reverify 'warn' downgrades RESULT so the exit gate trips =="
# the guard must exist inside the reverify arm of upgrade_one
have 'RESULT="FAILED (unhealthy: ${RESULT})"' \
  && ok "upgrade_one downgrades RESULT to a FAILED* value on rev==warn" \
  || bad "upgrade_one does NOT downgrade RESULT on a failed reverify (exit-0-on-unhealthy bug)"
# it must be gated on exactly 'warn' (ok / n/a must NOT be treated as failure)
if grep -qE 'if \[\[ "\$rev" == "warn" \]\]; then RESULT="FAILED' "$UPG"; then
  ok "downgrade is gated on rev=='warn' only (ok/n/a left untouched)"
else
  bad "downgrade not gated precisely on 'warn' (risk: n/a/ok mis-flagged as failure)"
fi
# BOTH exit gates must use the FAILED* glob (host-global path + general/--outdated/all
# path). A regression in only one is a false-green if we merely assert "exists somewhere"
# (QA proved this). upgrade.sh has exactly two exit gates; require both to match.
_gate_ct="$(grep -cE '\[\[ "\$res" == FAILED\* \]\]' "$UPG")"
(( _gate_ct == 2 )) && ok "BOTH exit gates use the FAILED* glob (count=$_gate_ct)" || bad "expected 2 FAILED* exit gates, found $_gate_ct — a gate regression would be an invisible false-green"

echo "== F1: reverify has a bounded readiness grace (no false-FAIL on cold start) =="
grep -qE 'tries=[0-9]+ gap=[0-9]+' "$UPG" && ok "reverify defines a bounded retry (tries/gap)" || bad "reverify has no bounded retry — a cold-starting litellm would false-FAIL"
grep -qE 'for \(\( attempt=1; attempt<=tries' "$UPG" && ok "reverify retries a failing probe over the grace window" || bad "reverify does not loop-retry a failing probe"
# the healthy path must short-circuit on the FIRST success (no /health model-ping amplification)
grep -qF 'curl -fsS --max-time 10 "$h" >/dev/null 2>&1 && { echo ok; return 0; }' "$UPG" && ok "reverify returns 'ok' on first success (retries only while failing)" || bad "reverify does not short-circuit on first success"

echo "== F1 (behavioral): the decision table + glob semantics =="
# Reproduce the exact arm decision for the (rev, RESULT) matrix and assert the
# resulting RESULT and whether it trips the FAILED* exit gate.
decide(){ local rev="$1" R="$2"; if [[ "$rev" == "warn" ]]; then R="FAILED (unhealthy: ${R})"; fi; printf '%s' "$R"; }
trips(){ [[ "$1" == FAILED* ]] && echo yes || echo no; }
r="$(decide warn upgraded)";    [[ "$r" == "FAILED (unhealthy: upgraded)" && "$(trips "$r")" == yes ]] && ok "warn+upgraded → '$r' → trips exit gate" || bad "warn+upgraded wrong: '$r'"
r="$(decide warn up-to-date)";  [[ "$(trips "$r")" == yes ]] && ok "warn+up-to-date → trips exit gate" || bad "warn+up-to-date did not trip: '$r'"
r="$(decide ok upgraded)";      [[ "$r" == "upgraded"  && "$(trips "$r")" == no  ]] && ok "ok+upgraded → unchanged, does not trip" || bad "ok+upgraded wrongly changed: '$r'"
r="$(decide n/a re-asserted)";  [[ "$r" == "re-asserted" && "$(trips "$r")" == no ]] && ok "n/a+re-asserted → unchanged, does not trip (n/a is NOT a failure)" || bad "n/a mis-handled: '$r'"

echo "== F3: --outdated ALWAYS discloses BOTH un-reachable buckets (manual + unconfirmed) =="
have 'skipped_manual+=("$svc")' && ok "--outdated collects the 'manual' (fleet/pip/CLI) services" || bad "--outdated does not collect skipped 'manual' services"
have 'unconfirmed+=("$svc")' && ok "--outdated also collects 'unknown'/'rebuild' (currency-not-confirmed) services" || bad "--outdated silently drops unknown/rebuild (proxy-blocked/local-built) — false-coverage gap"
have 'NOT version-checkable by --outdated' && ok "footer names the un-checked (manual) plane" || bad "no un-checked-plane footer text"
have 'currency NOT confirmed' && ok "separate warning for registry/proxy-unreachable or local-built" || bad "no unconfirmed-currency disclosure"
grep -q "run 'vz-ai-stack.sh upgrade all'" "$UPG" && ok "footer points at 'upgrade all' (the exhaustive motion)" || bad "footer does not route to 'upgrade all'"
# the disclosure must NOT be gated on targets==0 (the old bug): the manual footer
# appears BEFORE the targets==0 early-return.
_foot_ln="$(grep -n 'NOT version-checkable by --outdated' "$UPG" | head -1 | cut -d: -f1)"
_zero_ln="$(grep -n 'Nothing auto-checkable is outdated' "$UPG" | head -1 | cut -d: -f1)"
if [[ -n "$_foot_ln" && -n "$_zero_ln" ]] && (( _foot_ln < _zero_ln )); then
  ok "disclosure prints BEFORE the 'nothing outdated' early-return (always, not just on empty)"
else
  bad "disclosure is gated behind the targets==0 branch (footer=$_foot_ln zero=$_zero_ln) — regresses to the old never-prints bug"
fi

echo "== F4: --all + --outdated warns (inert combo) =="
have 'ALL_ROWS && OUTDATED' && ok "arg logic detects --all + --outdated" || bad "no --all+--outdated detection"
have '--all has no effect with --outdated' && ok "warns that --all is inert with --outdated" || bad "no inert-flag warning"
# it must be a WARN, not a hard exit (the command is still valid)
if grep -A2 'ALL_ROWS && OUTDATED' "$UPG" | grep -q 'warn '; then ok "uses warn (non-fatal), not exit/err" || true; else bad "--all+--outdated is not a non-fatal warn"; fi

echo "== usage text reflects the new semantics =="
have 'NOT the fleet/pip plane' && ok "usage: --outdated scoped to docker/compose/brew currency" || bad "usage still implies --outdated covers everything"
have 'exhaustive: also the fleet pip + host globals' && ok "usage: 'upgrade all' named as the exhaustive motion" || bad "usage does not steer to 'upgrade all'"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
