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

echo "== F1: a mutation this run left unhealthy downgrades RESULT so the exit gate trips =="
have 'RESULT="FAILED (unhealthy: ${RESULT})"' \
  && ok "upgrade_one downgrades RESULT to a FAILED* value when a mutation is unhealthy" \
  || bad "upgrade_one does NOT downgrade RESULT on a failed post-mutation reverify"
# Gated on warn AND (RESULT==upgraded OR done (unverified)) — must NOT fire on up-to-date/
# re-asserted no-ops (2026-07-14: firing on any non-skip result false-FAILED up-to-date litellm).
if grep -qF 'if [[ "$rev" == "warn" && ( "$RESULT" == "upgraded" || "$RESULT" == "done (unverified)" ) ]]; then' "$UPG"; then
  ok "downgrade gated on warn AND a real-mutation RESULT (upgraded / done (unverified))"
else
  bad "downgrade gate not scoped to real mutations — will false-FAIL up-to-date/re-asserted no-ops"
fi
# BOTH exit gates must use the FAILED* glob (host-global path + general/--outdated/all path).
_gate_ct="$(grep -cE '\[\[ "\$res" == FAILED\* \]\]' "$UPG")"
(( _gate_ct == 2 )) && ok "BOTH exit gates use the FAILED* glob (count=$_gate_ct)" || bad "expected 2 FAILED* exit gates, found $_gate_ct — a gate regression would be an invisible false-green"

echo "== F1: reverify has a bounded readiness grace (no false-FAIL on cold start) =="
grep -qE 'tries=[0-9]+ gap=[0-9]+' "$UPG" && ok "reverify defines a bounded retry (tries/gap)" || bad "reverify has no bounded retry — a cold-starting litellm would false-FAIL"
grep -qF 'curl -fsS --max-time 10 "$h" >/dev/null 2>&1 && { echo ok; return 0; }' "$UPG" && ok "reverify returns 'ok' on first success (retries only while failing)" || bad "reverify does not short-circuit on first success"

echo "== F1 (behavioral): drive the REAL decision line extracted from upgrade.sh =="
# QA finding: a hand-copied decide() mirror can never fail. Extract the ACTUAL if…fi that
# gates the downgrade and eval it with controlled rev/RESULT, so a regression on the real
# line is caught here (not only by the static grep above).
_f1="$(sed -n '/if \[\[ "\$rev" == "warn" && (/,/^ *fi$/p' "$UPG")"
[[ -n "$_f1" ]] && ok "extracted the real F1 decision block from upgrade.sh" || bad "could not extract F1 decision block (structure changed?)"
f1decide(){ local rev="$1" RESULT="$2"; eval "$_f1"; printf '%s' "$RESULT"; }
trips(){ [[ "$1" == FAILED* ]] && echo yes || echo no; }
r="$(f1decide warn upgraded)";              [[ "$r" == "FAILED (unhealthy: upgraded)"           && "$(trips "$r")" == yes ]] && ok "warn+upgraded → '$r' → fails"           || bad "warn+upgraded wrong: '$r'"
r="$(f1decide warn 'done (unverified)')";   [[ "$r" == "FAILED (unhealthy: done (unverified))"  && "$(trips "$r")" == yes ]] && ok "warn+done(unverified) → fails (real mutation ran)" || bad "warn+done(unverified) wrong: '$r'"
r="$(f1decide warn up-to-date)";            [[ "$r" == "up-to-date"   && "$(trips "$r")" == no ]] && ok "warn+up-to-date → NOT failed (B2 regression guard)" || bad "warn+up-to-date wrongly failed: '$r'"
r="$(f1decide warn re-asserted)";           [[ "$r" == "re-asserted"  && "$(trips "$r")" == no ]] && ok "warn+re-asserted → NOT failed (phase re-run may short-circuit)" || bad "warn+re-asserted wrongly failed: '$r'"
r="$(f1decide ok upgraded)";                [[ "$r" == "upgraded"     && "$(trips "$r")" == no ]] && ok "ok+upgraded → unchanged" || bad "ok+upgraded wrongly changed: '$r'"

echo "== B1b/B1c (behavioral): the two adversarial-found crash-class fixes =="
# resolve_phase_script_inline: a no-match phase id must NOT unbound-abort (config drift).
_rf="$(mktemp)"; sed -n '/^resolve_phase_script_inline() {/,/^}/p' "$UPG" > "$_rf"
if bash -c 'set -Eeuo pipefail; shopt -s inherit_errexit nullglob; source "$1"
  AI_STACK="/tmp/nonexistent_ai_stack_$$"; s="$(resolve_phase_script_inline bogus_phase_id)"; [[ -z "$s" ]]' _ "$_rf" >/dev/null 2>&1; then
  ok "resolve_phase_script_inline: no-match → empty, returns 0 (no unbound m[0] abort)"
else
  bad "resolve_phase_script_inline aborts on a no-match phase id (config-drift crash)"
fi
rm -f "$_rf"
# check_one docker: an empty 2nd (redundant) remote-digest fetch must NOT abort (Zscaler flake).
_cf2="$(mktemp)"; sed -n '/^check_one() {/,/^}/p' "$UPG" > "$_cf2"
if bash -c 'set -Eeuo pipefail; shopt -s inherit_errexit nullglob; source "$1"
  svc_type(){ echo docker; }; svc_image(){ echo foo/bar:latest; }
  check_image(){ echo update-available; }; img_local_digest(){ echo sha256:aaaabbbbccccdddd1111; }
  img_remote_digest(){ printf ""; }; DOCKER_OK=1
  check_one litellm' _ "$_cf2" >/dev/null 2>&1; then
  ok "check_one docker: empty 2nd remote digest → returns 0 (no --check/preflight abort)"
else
  bad "check_one aborts when the redundant 2nd registry fetch flakes empty (Zscaler-reachable crash)"
fi
rm -f "$_cf2"

echo "== B1 (behavioral): up_npm_global with no restart returns 0 (no upgrade-all abort) =="
# Drive the REAL extracted function under set -Eeuo pipefail (the actual run condition).
# byterover_cli has restart='-': the old trailing '[[ ]] && {…}' returned 1 as the function's
# last statement → aborted the whole 'upgrade all'. The fix (if/fi) returns 0.
_b1f="$(mktemp)"; sed -n '/^up_npm_global() {/,/^}/p' "$UPG" > "$_b1f"
if bash -c 'set -Eeuo pipefail; source "$1"
  svc_upgrade(){ [[ "$2" == target ]] && echo testpkg || echo "-"; }
  note(){ :; }; err(){ :; }; warn(){ :; }; recreate_via_start_script(){ return 0; }
  npm(){ return 0; }; DRY=0; STRATEGY=""; RESULT=""
  up_npm_global byterover_cli' _ "$_b1f" >/dev/null 2>&1; then
  ok "up_npm_global returns 0 with restart='-' (byterover_cli no longer aborts 'upgrade all')"
else
  bad "up_npm_global returns non-zero with restart='-' → aborts 'upgrade all' under set -Eeuo pipefail"
fi
rm -f "$_b1f"

echo "== B3: litellm health probe is readiness (no model-ping / no local-model load) =="
grep -qE 'health:[[:space:]]*http://127\.0\.0\.1:4000/health/(readiness|liveness)' "$ROOT/services.yml" \
  && ok "litellm health = /health/readiness|liveness (static, no model call)" \
  || bad "litellm health is bare /health — pings+loads models (never-load-models violation)"
# It must NOT be the bare model-pinging /health (regression guard).
grep -qE 'health:[[:space:]]*http://127\.0\.0\.1:4000/health[[:space:]]*$' "$ROOT/services.yml" \
  && bad "litellm health reverted to bare /health (model-loading endpoint)" \
  || ok "litellm health is not the bare model-pinging /health"

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

echo "== B-collect (behavioral): collect_targets returns 0 when the LAST service is disabled =="
# Sibling of the up_npm_global crash: the while body was `[[ enabled ]] && _out+=`, so a
# disabled LAST-iterated service made the while (hence the function) return 1 → aborted the
# bare `collect_targets …` call under set -Eeuo pipefail. Drive the REAL function.
_cf="$(mktemp)"; sed -n '/^collect_targets() {/,/^}/p' "$UPG" > "$_cf"
if out="$(bash -c 'set -Eeuo pipefail; source "$1"
  SERVICES_YML=dummy
  yq(){ printf "a\nb\nlast\n"; }                       # 3 keys, "last" iterated last
  svc_enabled(){ [[ "$1" == last ]] && echo false || echo true; }  # last is DISABLED
  declare -a T; collect_targets T all; printf "%s" "${T[*]}"' _ "$_cf" 2>/dev/null)"; then
  [[ "$out" == "a b" ]] && ok "collect_targets returns 0 + filters correctly ('$out'), no abort" || bad "collect_targets returned 0 but wrong set: '$out'"
else
  bad "collect_targets aborts under set -Eeuo pipefail when the last service is disabled (latent crash)"
fi
rm -f "$_cf"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
