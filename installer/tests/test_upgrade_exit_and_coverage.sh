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
  note(){ :; }; err(){ :; }; warn(){ :; }; restart_and_verify(){ return 0; }
  _svc_npm_bin(){ echo npm; }
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
have 'with a real artifact but no version oracle yet' && ok "footer names the un-checked (manual) plane" || bad "no un-checked-plane footer text"
have 'currency NOT confirmed' && ok "separate warning for registry/proxy-unreachable or local-built" || bad "no unconfirmed-currency disclosure"
grep -qF -- "or 'upgrade all', which also covers the host globals" "$UPG" && ok "footer routes to 'upgrade hermes'/'upgrade all' (the honest motions)" || bad "footer does not route to the exhaustive motions"
# the disclosure must NOT be gated on targets==0 (the old bug): the manual footer
# appears BEFORE the targets==0 early-return.
_foot_ln="$(grep -n 'with a real artifact but no version oracle yet' "$UPG" | head -1 | cut -d: -f1)"
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
have 'applies only updates we can VERIFY you are behind on' && ok "usage: --outdated = verified-behind only" || bad "usage lost the verified-behind story"
have 'exhaustive: also the fleet pip + host globals' && ok "usage: 'upgrade all' named as the exhaustive motion" || bad "usage does not steer to 'upgrade all'"
have 'pins are never swept' && ok "usage: pins-never-swept stated" || bad "usage does not state the pin policy"

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

########################################################################
# v2 — --outdated coverage broadening (2026-07-15): pins, dispatch, git
# chain, verified restart, uv-tool, sandbox-pip, buckets, parity.
# House style: sed-extract the REAL function and drive it under the actual
# run condition (set -Eeuo pipefail + inherit_errexit) with stubbed leaves.
########################################################################
VERS="$ROOT/installer/lib/versions.sh"

echo "== v2/B-pin (behavioral): pin_hold_check holds version-mutating methods on EVERY path =="
_pf="$(mktemp)"; sed -n '/^pin_hold_check() {/,/^}/p' "$UPG" > "$_pf"
_pin_run(){ # <pin> <method> → prints held/proceed
  bash -c 'set -Eeuo pipefail; shopt -s inherit_errexit; source "$1"
    PIN="$2"; METHOD="$3"
    svc_upgrade(){ [[ "$2" == pin ]] && echo "$PIN" || echo "-"; }
    note(){ :; }; STRATEGY=""; RESULT=""
    if pin_hold_check svcx "$METHOD"; then echo "held|$RESULT"; else echo "proceed"; fi' _ "$_pf" "$1" "$2" 2>/dev/null
}
r="$(_pin_run 1.2.3 npm-global)"; [[ "$r" == "held|pinned (held at 1.2.3)" ]] && ok "pin + npm-global → held ('$r')" || bad "pin + npm-global not held: '$r'"
r="$(_pin_run 1.2.3 git-pull)";   [[ "$r" == held\|* ]] && ok "pin + git-pull → held" || bad "pin + git-pull not held: '$r'"
r="$(_pin_run 1.2.3 uv-tool)";    [[ "$r" == held\|* ]] && ok "pin + uv-tool → held" || bad "pin + uv-tool not held: '$r'"
r="$(_pin_run 1.2.3 none)";       [[ "$r" == "proceed" ]] && ok "pin + method:none → proceeds (pin-preserving re-assert allowed)" || bad "pin + none wrongly held: '$r'"
r="$(_pin_run 1.2.3 phase-rerun)"; [[ "$r" == "proceed" ]] && ok "pin + phase-rerun → proceeds" || bad "pin + phase-rerun wrongly held: '$r'"
r="$(_pin_run - npm-global)";     [[ "$r" == "proceed" ]] && ok "no pin → proceeds" || bad "no pin wrongly held: '$r'"
rm -f "$_pf"
# The gate must run in upgrade_one BEFORE dispatch, and a held row must skip reverify
# (early record_row+return); belt: pinned* in the no-reverify case.
have 'if pin_hold_check "$svc" "$_method"; then' && ok "upgrade_one gates dispatch behind pin_hold_check" || bad "upgrade_one does not consult pin_hold_check"
haveE 'FAILED\*\|skipped\*\|manual\|planned\|pinned\*' && ok "pinned* in the no-reverify RESULT case (A2)" || bad "pinned rows could still trigger a reverify probe"

echo "== v2/B-dispatch (behavioral): method-aware dispatch (no metadata-block hijack; typo warns) =="
_df="$(mktemp)"; sed -n '/^dispatch_upgrade() {/,/^}/p' "$UPG" > "$_df"
_disp(){ # <method> → prints route[,warned]
  bash -c 'set -Eeuo pipefail; shopt -s inherit_errexit; source "$1"
    W=""; warn(){ W=warned; }
    up_by_method(){ echo -n "method${W:+,$W}"; }
    up_by_type(){ echo -n "type${W:+,$W}"; }
    dispatch_upgrade svcx sometype "$2"' _ "$_df" "$1" 2>/dev/null
}
r="$(_disp sandbox-pip)"; [[ "$r" == "method" ]] && ok "sandbox-pip → up_by_method" || bad "sandbox-pip route: '$r'"
r="$(_disp none)";        [[ "$r" == "method" ]] && ok "none → up_by_method (silent config arm)" || bad "none route: '$r'"
r="$(_disp -)";           [[ "$r" == "type" ]] && ok "metadata-only block ('-') → TYPE handler (no hijack)" || bad "'-' route: '$r'"
r="$(_disp '')";          [[ "$r" == "type" ]] && ok "no method ('') → TYPE handler" || bad "'' route: '$r'"
r="$(_disp uv-vnev)";     [[ "$r" == "type,warned" ]] && ok "typo'd method → WARN + safe type fallback" || bad "typo route: '$r' (want type,warned)"
rm -f "$_df"

echo "== v2/B-git (behavioral): up_git_pull guard→pull→build→verified-restart state machine =="
_gf="$(mktemp)"; sed -n '/^up_git_pull() {/,/^}/p' "$UPG" > "$_gf"
# scenario driver: env toggles select fake-git behavior; prints "rc|RESULT|calls"
_git_run(){ # DIRTY PULL_RC HEAD_MOVES BUILD_CMD RESTART_OK
  bash -c '
    set -Eeuo pipefail; shopt -s inherit_errexit; source "$1"
    DIRTY="$2"; PULL_RC="$3"; HEAD_MOVES="$4"; BUILD_CMD="$5"; RESTART_OK="$6"
    CLONE="$(mktemp -d)"; mkdir -p "$CLONE/.git"; AI_STACK="$(dirname "$CLONE")"
    DIRNAME="$(basename "$CLONE")"
    # Marker FILES, not variables: the pull runs in a pipeline (`git … | tail -3`)
    # whose components are SUBSHELLS — variable writes inside the stub would vanish.
    MARK="$(mktemp -d)"
    svc_upgrade(){ case "$2" in dir) echo "$DIRNAME";; build) echo "$BUILD_CMD";;
      restart) echo daemonx;; build_timeout) echo 5;; *) echo "-";; esac; }
    note(){ :; }; warn(){ :; }; err(){ :; }
    _vz_bounded(){ shift; "$@"; }
    git(){ shift 2  # git -C <abs> <verb> …
      case "$1" in
        status)    if [[ "$DIRTY" == 1 ]]; then echo " M f"; fi ;;
        rev-parse) if [[ -f "$MARK/pulled" && "$HEAD_MOVES" == 1 ]]; then echo bbbbbbb; else echo aaaaaaa; fi ;;
        pull)      printf "pull;" >> "$MARK/calls"; : > "$MARK/pulled"; return "$PULL_RC" ;;
        reset)     printf "reset;" >> "$MARK/calls" ;;
      esac; return 0; }
    restart_and_verify(){ printf "restart;" >> "$MARK/calls"; [[ "$RESTART_OK" == 1 ]]; }
    DRY=0; STRATEGY=""; RESULT=""
    up_git_pull svcx; rc=$?
    CALLS="$(cat "$MARK/calls" 2>/dev/null || true)"
    rm -rf "$CLONE" "$MARK"
    echo "$rc|$RESULT|$CALLS"' _ "$_gf" "$1" "$2" "$3" "$4" "$5" 2>/dev/null
}
r="$(_git_run 1 0 1 true 1)"; [[ "$r" == "0|skipped (dirty tree)|" ]] && ok "dirty tree → skipped, ZERO mutation ('$r')" || bad "dirty tree wrong: '$r'"
r="$(_git_run 0 1 0 true 1)"; [[ "$r" == "0|FAILED|pull;" ]] && ok "pull fails → FAILED, rc 0" || bad "pull-fail wrong: '$r'"
r="$(_git_run 0 0 0 true 1)"; [[ "$r" == "0|up-to-date|pull;" ]] && ok "HEAD unchanged → up-to-date, NO build/restart" || bad "no-op wrong: '$r'"
r="$(_git_run 0 0 1 false 1)"; [[ "$r" == "0|FAILED|pull;reset;" ]] && ok "build fails → rollback (reset) + FAILED, BEFORE any restart" || bad "build-fail wrong: '$r'"
r="$(_git_run 0 0 1 true 0)"; [[ "$r" == "0|FAILED|pull;restart;" ]] && ok "restart unverified → FAILED (no stale-daemon 'upgraded')" || bad "restart-fail wrong: '$r'"
r="$(_git_run 0 0 1 true 1)"; [[ "$r" == "0|upgraded|pull;restart;" ]] && ok "pull+build+verified restart → upgraded" || bad "happy path wrong: '$r'"
rm -f "$_gf"

echo "== v2/B-restart (behavioral): restart_and_verify pidfile semantics + exit-2 fallback =="
_rf2="$(mktemp)"; sed -n '/^recreate_via_start_script() {/,/^}/p' "$UPG" > "$_rf2"
sed -n '/^restart_and_verify() {/,/^}/p' "$UPG" >> "$_rf2"
_restart_run(){ # <script-body> <pid_before> <pid_after> → prints rc  (empty pid = no pidfile)
  bash -c '
    set -Eeuo pipefail; shopt -s inherit_errexit; source "$1"
    AI_STACK="$(mktemp -d)"; mkdir -p "$AI_STACK/bin" "$AI_STACK/installer/state"
    printf "%s\n" "#!/usr/bin/env bash" "$2" > "$AI_STACK/bin/start-svcx.sh"; chmod +x "$AI_STACK/bin/start-svcx.sh"
    [[ -n "$3" ]] && echo "$3" > "$AI_STACK/installer/state/svcx.pid"
    BASH="$(command -v bash)"; err(){ :; }
    export PID_AFTER="$4"
    if restart_and_verify svcx; then echo 0; else echo 1; fi
    rm -rf "$AI_STACK"' _ "$_rf2" "$1" "$2" "$3" 2>/dev/null
}
# script that rewrites the pidfile to $PID_AFTER (simulates a real recycle or a no-op)
_body='echo "$PID_AFTER" > "$(dirname "$0")/../installer/state/svcx.pid"; exit 0'
r="$(_restart_run "$_body" 111 111)"; [[ "$r" == 1 ]] && ok "exit-0 no-op (PID unchanged) → NOT a verified restart" || bad "PID-unchanged no-op passed as restart: '$r'"
r="$(_restart_run "$_body" 111 222)"; [[ "$r" == 0 ]] && ok "PID changed → verified restart" || bad "PID-changed restart failed: '$r'"
r="$(_restart_run 'exit 0' '' '')";   [[ "$r" == 0 ]] && ok "no pidfile (launchd-style) → exit code is the criterion" || bad "no-pidfile exit-0 wrong: '$r'"
r="$(_restart_run 'exit 1' 111 111)"; [[ "$r" == 1 ]] && ok "script exit 1 → failed" || bad "script-fail wrong: '$r'"
# exit-2 fallback: --recreate rejected → retried with `restart`
_fbody='if [[ "${1:-}" == "--recreate" ]]; then exit 2; fi; [[ "${1:-}" == restart ]] && exit 0; exit 9'
r="$(_restart_run "$_fbody" '' '')"; [[ "$r" == 0 ]] && ok "exit-2 on --recreate → falls back to 'restart' (openwork-style)" || bad "exit-2 fallback broken: '$r'"
# a daemon that HAD a pidfile must present a NEW one — rm-pidfile-and-exit-0 is not a restart
_vbody='rm -f "$(dirname "$0")/../installer/state/svcx.pid"; exit 0'
r="$(_restart_run "$_vbody" 111 '')"; [[ "$r" == 1 ]] && ok "pidfile vanished after restart → NOT verified (latent-hole fix)" || bad "vanished pidfile blessed as a restart: '$r'"
rm -f "$_rf2"

echo "== v2/B-bucket (behavioral): the --outdated selection semantics (pinned NEVER swept) =="
_bf="$(mktemp)"; sed -n '/^outdated_bucket() {/,/^}/p' "$UPG" > "$_bf"
_bk(){ bash -c 'set -Eeuo pipefail; source "$1"; outdated_bucket "$2"' _ "$_bf" "$1" 2>/dev/null; }
[[ "$(_bk update-available)" == sweep ]]       && ok "update-available → sweep" || bad "update-available bucket wrong"
[[ "$(_bk manual)" == manual ]]                && ok "manual → disclosed, not swept" || bad "manual bucket wrong"
[[ "$(_bk unknown)" == unconfirmed && "$(_bk rebuild)" == unconfirmed ]] && ok "unknown/rebuild → unconfirmed" || bad "unconfirmed bucket wrong"
[[ "$(_bk pinned)" == pinned ]]                && ok "pinned → held bucket (never swept)" || bad "PINNED WOULD BE SWEPT — bucket wrong"
[[ "$(_bk config)" == config ]]                && ok "config → config bucket" || bad "config bucket wrong"
[[ "$(_bk up-to-date)" == ignore ]]            && ok "up-to-date → ignore" || bad "up-to-date bucket wrong"
rm -f "$_bf"
have 'pinned service(s) held at their declared versions' && ok "--outdated prints the pinned disclosure" || bad "no pinned disclosure in --outdated"
have 'config-only service(s)' && ok "--outdated prints the config disclosure" || bad "no config disclosure in --outdated"

echo "== v2/B-oracle (behavioral): versions.sh new oracles (sourced directly — side-effect-free) =="
# uv-tool: v-prefix stripped, exact-name anchored (idempotency: must converge with PyPI)
r="$(bash -c 'set -Eeuo pipefail; shopt -s inherit_errexit
  __SVC_ACCESSORS_SOURCED=1; AI_STACK=/tmp; SERVICES_YML=/dev/null
  source "$1"
  svc_upgrade(){ [[ "$2" == pkg ]] && echo halo-engine || echo "-"; }
  svc_type(){ echo cli-only; }; svc_path(){ echo "-"; }; svc_image(){ echo "-"; }
  uv(){ printf "halo-engine-extra v9.9.9\nhalo-engine v0.1.17\n- halo\n"; }
  _iv_uvtool svcx' _ "$VERS" 2>/dev/null)"
[[ "$r" == "0.1.17" ]] && ok "_iv_uvtool: exact-name match + v-prefix stripped ('$r')" || bad "_iv_uvtool parse wrong: '$r'"
# sandbox-pip: DOCKER_OK UNSET under set -u must not crash (A5); running container reads version
r="$(bash -c 'set -u
  __SVC_ACCESSORS_SOURCED=1; AI_STACK=/tmp; SERVICES_YML=/dev/null
  source "$1"
  svc_upgrade(){ case "$2" in pkg) echo hermes-agent;; container) echo openshell-hf;; *) echo "-";; esac; }
  docker(){ case "$1" in ps) echo openshell-hf-123;; exec) printf "Name: hermes-agent\nVersion: 0.18.2\n";; esac; }
  _vz_bounded(){ shift; "$@"; }
  _iv_sandbox_pip svcx' _ "$VERS" 2>/dev/null)"
[[ "$r" == "0.18.2" ]] && ok "_iv_sandbox_pip: running sandbox → version, DOCKER_OK unset is safe ('$r')" || bad "_iv_sandbox_pip wrong (or set -u crash): '$r'"
r="$(bash -c 'set -u
  __SVC_ACCESSORS_SOURCED=1; AI_STACK=/tmp; SERVICES_YML=/dev/null
  source "$1"
  svc_upgrade(){ case "$2" in pkg) echo hermes-agent;; container) echo openshell-hf;; *) echo "-";; esac; }
  docker(){ case "$1" in ps) printf "";; *) return 1;; esac; }
  _vz_bounded(){ shift; "$@"; }
  _iv_sandbox_pip svcx' _ "$VERS" 2>/dev/null)"
[[ "$r" == "-" ]] && ok "_iv_sandbox_pip: no running container → '-' (honest unknown, no hang)" || bad "_iv_sandbox_pip stopped-container wrong: '$r'"

echo "== v2/B-parity: version_status agrees with check_one on pinned/config (shared classifier) =="
r="$(bash -c 'set -Eeuo pipefail
  __SVC_ACCESSORS_SOURCED=1; AI_STACK=/tmp; SERVICES_YML=/dev/null
  source "$1"
  svc_type(){ echo cli-only; }
  svc_upgrade(){ [[ "$2" == pin ]] && echo 1.0.0 || echo "-"; }
  version_status svcx' _ "$VERS" 2>/dev/null)"
[[ "$r" == "pinned" ]] && ok "version_status: declared pin → pinned (status --versions parity)" || bad "version_status pin parity broken: '$r'"
r="$(bash -c 'set -Eeuo pipefail
  __SVC_ACCESSORS_SOURCED=1; AI_STACK=/tmp; SERVICES_YML=/dev/null
  source "$1"
  svc_type(){ echo litellm-feature; }
  svc_upgrade(){ echo "-"; }
  version_status svcx' _ "$VERS" 2>/dev/null)"
[[ "$r" == "config" ]] && ok "version_status: config-only type → config" || bad "version_status config parity broken: '$r'"
_ck="$(mktemp)"; sed -n '/^check_one() {/,/^}/p' "$UPG" > "$_ck"
r="$(bash -c 'set -Eeuo pipefail; shopt -s inherit_errexit; source "$1"
  svc_type(){ echo cli-only; }
  svc_upgrade_pin(){ echo 1.0.0; }; svc_config_only(){ return 1; }
  svc_installed_version(){ echo "-"; }; svc_available_version(){ echo "-"; }
  warn(){ :; }; DOCKER_OK=1
  check_one svcx; echo "$CHECK_STATUS|$CHECK_CUR"' _ "$_ck" 2>/dev/null)"
[[ "$r" == "pinned|pin:1.0.0" ]] && ok "check_one: unmeasured pin → status pinned, CUR='pin:<val>' marker (R7)" || bad "check_one pin display wrong: '$r'"
r="$(bash -c 'set -Eeuo pipefail; shopt -s inherit_errexit; source "$1"
  svc_type(){ echo node-bg; }
  svc_upgrade_pin(){ echo "-"; }; svc_config_only(){ return 0; }
  warn(){ :; }; DOCKER_OK=1
  check_one svcx; echo "$CHECK_STATUS"' _ "$_ck" 2>/dev/null)"
[[ "$r" == "config" ]] && ok "check_one: config-only → status config" || bad "check_one config wrong: '$r'"
rm -f "$_ck"

echo "== v2/static: remaining consensus mechanics wired =="
haveE 'brew\|npm-global\|uv-venv\|uv-tool\|git-pull\|compose\)' && ok "uv-tool in the reconcile STRATEGY list (A6 — no-op can't read 'upgraded')" || bad "uv-tool missing from reconcile — a current tool would claim 'upgraded'"
grep -qF -- '--recreate" || "${1:-}" == "restart"' "$ROOT/bin/start-paperclip.sh" && ok "start-paperclip.sh has the --recreate/restart arm" || bad "start-paperclip.sh missing the recreate arm"
grep -qF -- '--recreate" || "${1:-}" == "restart"' "$ROOT/bin/start-claw3d.sh" && ok "start-claw3d.sh has the --recreate/restart arm" || bad "start-claw3d.sh missing the recreate arm"
grep -qF 'if (( rc == 2 )); then' "$UPG" && ok "recreate_via_start_script: exit-2 → 'restart' fallback" || bad "no exit-2 fallback"
grep -qF '${DOCKER_OK:-1}' "$VERS" && ok "_iv_sandbox_pip uses \${DOCKER_OK:-1} (set -u safe in status context)" || bad "bare DOCKER_OK in versions.sh — set -u crash under status --versions"
bash -n "$VERS" 2>/dev/null && ok "versions.sh syntax valid" || bad "versions.sh syntax error"
bash -n "$ROOT/bin/start-paperclip.sh" 2>/dev/null && ok "start-paperclip.sh syntax valid" || bad "start-paperclip.sh syntax error"
bash -n "$ROOT/bin/start-claw3d.sh" 2>/dev/null && ok "start-claw3d.sh syntax valid" || bad "start-claw3d.sh syntax error"
# services.yml ground truth: pinned blocks carry BOTH a real oracle method or none AND a pin
_pin_ct="$(yq -r '.services | to_entries | map(select(.value.upgrade.pin != null)) | length' "$ROOT/services.yml" 2>/dev/null || echo 0)"
[[ "$_pin_ct" == 7 ]] && ok "services.yml declares exactly 7 pins" || bad "expected 7 upgrade.pin blocks, found $_pin_ct"
_none_ct="$(yq -r '.services | to_entries | map(select(.value.upgrade.method == "none")) | length' "$ROOT/services.yml" 2>/dev/null || echo 0)"
[[ "$_none_ct" == 6 ]] && ok "services.yml: 6 method:none markers (lumen/aionui pin-only + 4 shims; pi is pin-ONLY so its up_openshell arm keeps routing)" || bad "expected 6 method:none blocks, found $_none_ct"
[[ "$(yq -r '.services.pi.upgrade.method // "ABSENT"' "$ROOT/services.yml" 2>/dev/null)" == "ABSENT" ]] && ok "pi block is pin-only (no method) → type routes to up_openshell's pi arm" || bad "pi carries a method — it would be rerouted off up_openshell"
# Every pin ships its bump recipe as DATA (printable by pin_hold_check — no dead pointers).
_bump_ct="$(yq -r '.services | to_entries | map(select(.value.upgrade.pin != null and .value.upgrade.bump != null)) | length' "$ROOT/services.yml" 2>/dev/null || echo 0)"
[[ "$_bump_ct" == 7 ]] && ok "all 7 pins carry an upgrade.bump recipe (data, not comments)" || bad "pins without bump recipes: $((7 - _bump_ct))"
grep -qF 'Bump: ${bump}' "$UPG" && ok "pin_hold_check prints the actual bump recipe" || bad "pin_hold_check does not print upgrade.bump"
grep -qF 'npm_bin-missing' "$VERS" && grep -qF 'skipped (npm_bin missing)' "$UPG" && ok "declared-but-missing npm_bin fails CLOSED (oracle '-', handler skips)" || bad "npm_bin missing does not fail closed"
grep -qE '\^\[A-Za-z_\]\[A-Za-z0-9_\]\*=' "$VERS" && ok "_compose_images shape-validates check_env entries (no env-argv command injection)" || bad "check_env entries reach env unvalidated"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
