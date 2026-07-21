#!/usr/bin/env bash
# test_install_doctor_determinism.sh — clean-install→doctor determinism (§24 2026-07-21), OFFLINE.
# Covers the three root causes of "fresh install, doctor red":
#   1. pipefail-EPIPE `| grep -q` races (litellm_has_callback flaked check 06 ~40%)
#      — pins every converted site + drives the REAL litellm_has_callback 50×
#      under pipefail with real yq, + drives the new check-83 static guard.
#   2. paperclip: dir-existence dep gate + stamp-on-failure + group-SIGTERM kill
#      — pins the integrity gate, verify-then-stamp, precheck cwd fallback,
#      start-script self-heal and `set -m` process-group detach.
#   3. hermes slack role router had NO supervision — pins the watchdog W2b block
#      (stale-pid sentinel, launcher relaunch, operator-intent guard).
set -uo pipefail
(( BASH_VERSINFO[0] >= 4 )) || { echo "FAIL: this suite needs bash >= 4 (got $BASH_VERSION)"; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LL="$HERE/../lib/litellm.sh"; DEPS="$HERE/../lib/deps.sh"; ST="$HERE/../lib/status.sh"
VF="$HERE/../lib/verify.sh"; LMS="$HERE/../lib/lmstudio.sh"; FL="$HERE/../lib/fleet.sh"
P01="$HERE/../phases/01_inference.sh"; P08="$HERE/../phases/08_paperclip.sh"
P16="$HERE/../phases/16_lumen.sh"; P25="$HERE/../phases/25_lmstudio.sh"
C06="$HERE/../doctor/checks/06_arize_phoenix_callback.sh"
C09="$HERE/../doctor/checks/09_phoenix_project.sh"
C13="$HERE/../doctor/checks/13_phoenix_api_key.sh"
C17="$HERE/../doctor/checks/17_alias_resolution.sh"
C83="$HERE/../doctor/checks/83_pipefail_grep_epipe_guard.sh"
SP="$HERE/../../bin/start-paperclip.sh"; WD="$HERE/../../bin/openshell-watchdog.sh"
PI="$HERE/../../bin/pi"; PIAS="$HERE/../../bin/pi-as"
PASS=0; FAIL=0; t_ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }; t_bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "== static: every EPIPE conversion holds (no raw racy pipelines) =="
grep -q 'cbs="\$(yq -r' "$LL" && grep -q '<<<"\$cbs"' "$LL" \
  && t_ok "litellm_has_callback is capture-then-grep" || t_bad "litellm_has_callback regressed"
! grep -qE '\|[[:space:]]*grep -qxF "\$mod"' "$LL" \
  && t_ok "litellm.sh: no piped grep -qxF on \$mod" || t_bad "litellm.sh raw pipe returned"
grep -c '<<<"\$resp"' "$LL" | grep -qx '2' \
  && t_ok "wait_ready + smoke_ok both capture the curl body" || t_bad "curl-body capture sites drifted"
grep -q 'grep -ciE' "$C06" && ! grep -qE 'docker logs [^|]*\| *grep -qiE' "$C06" \
  && t_ok "check 06 OTLP-error scan counts (grep -c)" || t_bad "check 06 scan regressed to -q"
grep -q 'grep -ciE' "$C09" && grep -q 'grep -cF' "$C13" \
  && t_ok "checks 09/13 docker-logs scans count (grep -c)" || t_bad "checks 09/13 regressed"
! grep -qF '|| echo "000")"' "$C17" && grep -qE '\^\[0-9\]\{3\}' "$C17" \
  && t_ok "check 17: no 000000 concat; 3-digit normalization present" || t_bad "check 17 000000 bug back"
for f in "$DEPS" "$ST" "$P01"; do
  grep -q 'END{exit (s=="started")?0:1}' "$f" \
    && t_ok "$(basename "$f"): brew-services match folded into awk END" \
    || t_bad "$(basename "$f"): awk-mid-pipe regressed"
done
[[ "$(grep -c 'END{exit f?0:1}' "$P16")" -ge 2 ]] \
  && t_ok "16_lumen: both ollama-list matches folded into awk END" || t_bad "16_lumen regressed"
grep -q '_vals="\$(yq -r' "$P25" && grep -q '_avals="\$(yq -r' "$P25" \
  && t_ok "25_lmstudio: BOTH yq membership tests capture-then-grep (precheck + main body)" \
  || t_bad "25_lmstudio regressed (council caught the main-body site once already)"
grep -q '_ids="\$(lms_served_ids)"' "$LMS" && t_ok "lms_is_served captures" || t_bad "lms_is_served regressed"
grep -q '_mresp="\$(litellm_scoped_curl' "$FL" && t_ok "fleet.sh /v1/models capture" || t_bad "fleet.sh regressed"
grep -q 'END{exit f?0:1}' "$VF" && t_ok "verify.sh lo0 match folded into awk END" || t_bad "verify.sh regressed"
grep -q 'END{exit ok?0:1}' "$PI" && grep -q 'END{exit ok?0:1}' "$PIAS" \
  && t_ok "bin/pi + pi-as Ready checks consume-all awk" || t_bad "bin/pi Ready check regressed"

echo "== static: paperclip determinism (phase 08 + start script) =="
grep -q 'server/node_modules/.bin/tsx' "$P08" \
  && t_ok "phase 08 dep gate anchors on the tsx entrypoint" || t_bad "phase 08 back to dir-existence gate"
n_guard="$(grep -n 'if ! precheck' "$P08" | head -1 | cut -d: -f1)"
n_stamp="$(grep -n '^stamp_mark "\$PHASE"' "$P08" | head -1 | cut -d: -f1)"
[[ -n "$n_guard" && -n "$n_stamp" && "$n_guard" -lt "$n_stamp" ]] \
  && t_ok "phase 08 verify-then-stamp: precheck gate precedes stamp_mark" \
  || t_bad "phase 08 stamp no longer gated on a healthy daemon"
grep -q 'NOT stamping Phase 08' "$P08" && t_ok "phase 08 not-up path is loud + unstamped" || t_bad "unstamped-failure warn missing"
grep -q 'lsof -a -d cwd' "$P08" && t_ok "phase 08 precheck has the cwd identity fallback" || t_bad "precheck cwd fallback missing (healthy daemon would never re-stamp)"
grep -q 'server/node_modules/.bin/tsx' "$SP" && t_ok "start-paperclip self-heals a gutted tree (tsx gate)" || t_bad "start-paperclip self-heal missing"
[[ "$(grep -c '^  set -m$' "$SP")" -ge 2 ]] \
  && t_ok "start-paperclip: app + relay launch in their OWN process groups (set -m)" \
  || t_bad "set -m group detach missing (group-SIGTERM reaps the daemon again)"

echo "== static: watchdog W2b slack-router supervision =="
grep -q 'W2b' "$WD" && t_ok "W2b block present" || t_bad "W2b block missing"
grep -q 'hermes-slack-role-router.pid ] || exit 3' "$WD" \
  && t_ok "W2b stale-pid sentinel: absent pid file = operator intent (no relaunch)" || t_bad "W2b operator-intent guard drifted"
grep -q 'hermes_slack_role_router "/proc/\$pid/cmdline"' "$WD" \
  && t_ok "W2b alive-check confirms process IDENTITY (recycled-PID mask guard)" || t_bad "W2b identity leg missing (bare kill -0)"
grep -q 'fleet-boot/hermes_slack_role_router_start.sh" >>"\$LOG"' "$WD" \
  && t_ok "W2b relaunches via the persisted phase-38 launcher" || t_bad "W2b launcher relaunch drifted"
grep -qE 'W2b.*HOME=/sandbox|export HOME=/sandbox; cd /sandbox; bash /sandbox/fleet-boot' "$WD" \
  && t_ok "W2b launcher runs with HOME=/sandbox (env contract)" || t_bad "W2b env contract drifted"
grep -q 'hermes slack role router relaunch FAILED' "$WD" \
  && t_ok "W2b failure is operator-visible (notify)" || t_bad "W2b silent-failure path"

echo "== static: check 83 registered, advisory, print-only fix =="
grep -q 'CHECKS+=(pipefail_grep_epipe_guard)' "$C83" && t_ok "check 83 registered" || t_bad "check 83 not registered"
! grep -q 'FIX_CAPABLE\[pipefail_grep_epipe_guard\]' "$C83" \
  && t_ok "check 83 UNMARKED (advisory)" || t_bad "check 83 marked FIX_CAPABLE"
fixbody="$(sed -n '/^pipefail_grep_epipe_guard_fix/,/^}/p' "$C83")"
[[ -n "$fixbody" ]] && ! grep -qE 'yq -i|sed -i|docker rm|rm -rf' <<<"$fixbody" \
  && t_ok "check 83 fix body is print-only" || t_bad "check 83 fix body mutates"

echo "== behavioral: check-83 guard drives clean/violation/comment/inner-shell =="
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/installer/lib" "$TMP/installer/phases" "$TMP/installer/doctor/checks" "$TMP/bin"
eval "$(sed -n '/^pipefail_grep_epipe_guard_diagnose/,/^}/p' "$C83")"
[[ -n "$(declare -f pipefail_grep_epipe_guard_diagnose)" ]] || { t_bad "check-83 extraction EMPTY (vacuity)"; exit 1; }
AI_STACK="$TMP" pipefail_grep_epipe_guard_diagnose >/dev/null 2>&1 \
  && t_ok "empty tree passes" || t_bad "empty tree flagged"
echo 'yq -r .x f.yml | grep -q foo' > "$TMP/installer/lib/a.sh"
AI_STACK="$TMP" pipefail_grep_epipe_guard_diagnose >/dev/null 2>&1 \
  && t_bad "yq|grep -q violation NOT flagged" || t_ok "yq|grep -q violation flagged"
# PIPED yq filter (council blind spot: `[^|]*` stopped at the filter's own pipe
# and let 25_lmstudio.sh:159 through — the guard must see multi-stage filters).
echo 'yq -r ".a | to_entries | .[].value" f.yml 2>/dev/null | grep -qxF "$x" || continue' > "$TMP/installer/lib/a.sh"
AI_STACK="$TMP" pipefail_grep_epipe_guard_diagnose >/dev/null 2>&1 \
  && t_bad "PIPED-filter yq violation NOT flagged (guard blind spot back)" || t_ok "piped-filter yq violation flagged"
echo '# yq -r .x f.yml | grep -q foo (comment)' > "$TMP/installer/lib/a.sh"
AI_STACK="$TMP" pipefail_grep_epipe_guard_diagnose >/dev/null 2>&1 \
  && t_ok "comment line NOT flagged" || t_bad "comment line false-positive"
echo 'docker exec c sh -c "ps | awk 1 | grep -q x"' > "$TMP/installer/lib/a.sh"
AI_STACK="$TMP" pipefail_grep_epipe_guard_diagnose >/dev/null 2>&1 \
  && t_ok "inner sh -c NOT flagged (no pipefail there)" || t_bad "inner-shell false-positive"
echo 'foo | awk "{print}" | grep -q bar' > "$TMP/bin/b"
AI_STACK="$TMP" pipefail_grep_epipe_guard_diagnose >/dev/null 2>&1 \
  && t_bad "awk-mid-pipe violation NOT flagged" || t_ok "awk-mid-pipe violation flagged"
rm -f "$TMP/installer/lib/a.sh" "$TMP/bin/b"

echo "== behavioral: REAL litellm_has_callback, 50x under pipefail (flake regression) =="
if command -v yq >/dev/null 2>&1; then
  cat > "$TMP/config.yaml" <<'YML'
litellm_settings:
  callbacks: ["trace_to_file.handler", "arize_phoenix", "guardrails.handler"]
YML
  eval "$(sed -n '/^litellm_has_callback() {/,/^}/p' "$LL")"
  [[ -n "$(declare -f litellm_has_callback)" ]] || { t_bad "has_callback extraction EMPTY (vacuity)"; exit 1; }
  LITELLM_CONFIG="$TMP/config.yaml"
  hits=0
  for _ in $(seq 1 50); do
    # MIDDLE list element = the exact position that raced (grep -q exited before
    # yq finished writing). Old code: ~60% hit rate here; fixed code: 50/50.
    if litellm_has_callback arize_phoenix; then hits=$((hits+1)); fi
  done
  [[ "$hits" -eq 50 ]] && t_ok "50/50 TRUE for a mid-list callback under pipefail" \
                       || t_bad "flake persists: only $hits/50 TRUE"
  litellm_has_callback not_a_callback && t_bad "absent module read TRUE" || t_ok "absent module FALSE"
  LITELLM_CONFIG="$TMP/nope.yaml" litellm_has_callback arize_phoenix \
    && t_bad "missing config read TRUE" || t_ok "missing config FALSE"
else
  echo "  skip yq not installed — has_callback behavioral leg skipped"
fi

echo
echo "RESULT: PASS=$PASS FAIL=$FAIL"
(( FAIL == 0 )) || exit 1
exit 0
