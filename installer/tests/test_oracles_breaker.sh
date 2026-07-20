#!/usr/bin/env bash
# test_oracles_breaker.sh — in-sandbox oracles (pi sandbox-npm, owner display)
# + the probe circuit-breaker (2026-07-20 round). House style: source the REAL
# versions.sh / sed-extract the REAL upgrade.sh functions and drive them under
# set -Eeuo pipefail with stubbed leaves. versions.sh is common.sh-independent —
# this suite never sources common.sh.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPG="$ROOT/installer/lib/upgrade.sh"
VERS="$ROOT/installer/lib/versions.sh"
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); echo "  ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }

bash -n "$UPG" && bash -n "$VERS" && bash -n "$ROOT/installer/lib/status.sh" \
  && ok "upgrade.sh + versions.sh + status.sh parse" || bad "syntax error in edited libs"

echo "== sandbox-npm oracle: live read, anchored prefix, staged fallback, fail-closed =="
_npm_run(){ # PS_OUT EXEC_JSON DOCKER_OK_VAL VFILE_JSON → output
  bash -c '
    set -Eeuo pipefail; shopt -s inherit_errexit
    __SVC_ACCESSORS_SOURCED=1; SERVICES_YML=/dev/null
    M="$(mktemp -d)"; AI_STACK="$M"; mkdir -p "$M/installer/state"
    source "$1"
    PS_OUT="$2"; EXEC_JSON="$3"; DOK="$4"; VFILE_JSON="$5"
    [[ -n "$VFILE_JSON" ]] && printf "%s" "$VFILE_JSON" > "$M/pi_pkg.json"
    svc_upgrade(){ case "$2" in pkg) echo "@earendil-works/pi-coding-agent";;
      container) echo openshell-pi-v1;; version_file) [[ -n "$VFILE_JSON" ]] && echo pi_pkg.json || echo "-";; *) echo "-";; esac; }
    docker(){ case "$1" in ps) printf "%b" "$PS_OUT";; exec) printf "%s" "$EXEC_JSON";; esac; return 0; }
    _vz_bounded(){ shift; "$@"; }
    [[ "$DOK" == unset ]] || DOCKER_OK="$DOK"
    _iv_sandbox_npm svcx; rm -rf "$M"' _ "$VERS" "$1" "$2" "$3" "$4" 2>/dev/null
}
r="$(_npm_run 'openshell-pi-v1-abc\n' '{"version":"0.77.0"}' unset '')"
[[ "$r" == "0.77.0" ]] && ok "running sandbox → LIVE version (DOCKER_OK unset is set-u safe)" || bad "live read wrong: '$r'"
r="$(_npm_run 'openshell-pi-v10-zzz\nopenshell-pi-v1-abc\n' '{"version":"0.77.0"}' unset '')"
[[ "$r" == "0.77.0" ]] && ok "anchored prefix: pi-v10 sibling NOT matched, pi-v1 found" || bad "prefix anchor wrong: '$r'"
r="$(_npm_run '' '' unset '{"dependencies":{"@earendil-works/pi-coding-agent":"0.77.0"}}')"
[[ "$r" == "staged:0.77.0" ]] && ok "sandbox Exited → 'staged:<v>' from version_file (visibly a declaration)" || bad "staged fallback wrong: '$r'"
r="$(_npm_run 'openshell-pi-v1-abc\n' '{"version":"0.77.0"}' 0 '{"dependencies":{"@earendil-works/pi-coding-agent":"0.77.0"}}')"
[[ "$r" == "staged:0.77.0" ]] && ok "docker DOWN (DOCKER_OK=0) → staged fallback still reached (council A7)" || bad "docker-down fallback wrong: '$r'"
r="$(_npm_run '' '' unset '')"
[[ "$r" == "-" ]] && ok "no container + no version_file → '-' (fail-closed)" || bad "both-miss wrong: '$r'"

echo "== check_one pin branch: staged values compare stripped, drift warn names its source =="
_ck="$(mktemp)"; sed -n '/^check_one() {/,/^}/p' "$UPG" > "$_ck"
_pin_run(){ # INST PIN → "CUR|warns"
  bash -c 'set -Eeuo pipefail; shopt -s inherit_errexit; source "$1"
    INST="$2"; PIN="$3"; W=""
    svc_type(){ echo openshell; }
    svc_upgrade_pin(){ echo "$PIN"; }; svc_config_only(){ return 1; }
    svc_installed_version(){ echo "$INST"; }
    svc_available_version(){ echo "-"; }
    svc_upgrade(){ echo "-"; }
    warn(){ W="$*"; }
    DOCKER_OK=1
    check_one pi
    echo "$CHECK_CUR|${W:-none}"' _ "$_ck" "$1" "$2" 2>/dev/null
}
r="$(_pin_run staged:0.77.0 0.77.0)"
[[ "$r" == "staged:0.77.0|none" ]] && ok "staged == pin (stripped compare) → NO false drift warn, CUR shows staged marker" || bad "staged-match wrong: '$r'"
r="$(_pin_run staged:0.78.0 0.77.0)"
[[ "$r" == staged:0.78.0\|*host-staged* ]] && ok "staged ≠ pin → drift warn names 'host-staged' as the comparand" || bad "staged-drift wrong: '$r'"
r="$(_pin_run 0.77.0 0.77.0)"
[[ "$r" == "0.77.0|none" ]] && ok "live measured == pin → clean" || bad "live-match wrong: '$r'"

echo "== owner display: config rows show the OWNER's measured version =="
_own_run(){ # OWNER OWNERVER → CUR
  bash -c 'set -Eeuo pipefail; shopt -s inherit_errexit; source "$1"
    OWNER="$2"; OWNERVER="$3"
    svc_type(){ [[ "$1" == hermes_fleet ]] && echo hermes-profiles || echo sandbox-daemon; }
    svc_upgrade_pin(){ echo "-"; }; svc_config_only(){ return 0; }
    svc_upgrade(){ [[ "$2" == owner ]] && echo "$OWNER" || echo "-"; }
    svc_installed_version(){ [[ "$1" == hermes_fleet ]] && echo "$OWNERVER" || echo "-"; }
    warn(){ :; }; DOCKER_OK=1
    check_one hermes_telegram
    echo "$CHECK_STATUS|$CHECK_CUR"' _ "$_ck" "$1" "$2" 2>/dev/null
}
r="$(_own_run hermes_fleet 0.18.2)"; [[ "$r" == "config|0.18.2" ]] && ok "owner set → CUR = owner's measured version, status stays config" || bad "owner display wrong: '$r'"
r="$(_own_run - -)";                 [[ "$r" == "config|-" ]] && ok "no owner → today's behavior" || bad "no-owner wrong: '$r'"
r="$(_own_run hermes_fleet -)";      [[ "$r" == "config|-" ]] && ok "owner's sandbox down ('-') → honest '-'" || bad "owner-down wrong: '$r'"
rm -f "$_ck"

echo "== circuit-breaker: trips, open, short-circuit, reset, transports, kill-switch =="
_brk(){ # SCRIPT-BODY (runs with sourced VERS + fixture AI_STACK + file clock)
  bash -c '
    set -Eeuo pipefail; shopt -s inherit_errexit
    __SVC_ACCESSORS_SOURCED=1; SERVICES_YML=/dev/null
    T="$(mktemp -d)"; AI_STACK="$T"; mkdir -p "$T/installer/state"; echo 0 > "$T/clock"
    source "$1"
    _vz_now(){ cat "$T/clock" 2>/dev/null || echo 0; }
    tick(){ echo $(( $(cat "$T/clock") + ${1:-10} )) > "$T/clock"; }
    svc_type(){ echo docker; }
    svc_upgrade(){ echo "-"; }
    slow_empty(){ tick 10; printf ""; }
    fast_empty(){ tick 1; printf ""; }
    slow_ok(){ tick 10; printf "sha256:aaa"; }
    touch_probe(){ echo hit >> "$T/dispatched"; printf ""; }
    eval "$2"
    rm -rf "$T"' _ "$VERS" "$1" 2>/dev/null
}
r="$(_brk '
  _av_docker(){ slow_empty; }
  svc_available_version s1 >/dev/null; svc_available_version s2 >/dev/null; svc_available_version s3 >/dev/null
  st="$(_vz_breaker_open registry && echo OPEN || echo CLOSED)"
  _av_docker(){ touch_probe; }
  out="$(svc_available_version s4)"
  echo "$st|$out|$([[ -f "$T/dispatched" ]] && echo dispatched || echo short-circuited)"')"
[[ "$r" == "OPEN|-|short-circuited" ]] && ok "3 slow-empty trips → OPEN; 4th probe short-circuits without dispatch" || bad "breaker open/short-circuit wrong: '$r'"
r="$(_brk '
  _av_docker(){ fast_empty; }
  for i in 1 2 3 4 5; do svc_available_version s$i >/dev/null; done
  _vz_breaker_open registry && echo OPEN || echo CLOSED')"
[[ "$r" == "CLOSED" ]] && ok "fast-empty misses (404/refusal class) never trip" || bad "fast-empty tripped: '$r'"
r="$(_brk '
  _av_docker(){ slow_empty; }
  svc_available_version a >/dev/null; svc_available_version b >/dev/null
  _av_docker(){ slow_ok; }
  svc_available_version c >/dev/null
  _av_docker(){ slow_empty; }
  svc_available_version d >/dev/null; svc_available_version e >/dev/null
  _vz_breaker_open registry && echo OPEN || echo CLOSED')"
[[ "$r" == "CLOSED" ]] && ok "a success RESETS the consecutive counter (2+success+2 ≠ open)" || bad "reset semantics wrong: '$r'"
r="$(_brk '
  AI_STACK_BREAKER_TRIPS=0
  _av_docker(){ slow_empty; }
  for i in 1 2 3 4 5 6; do svc_available_version s$i >/dev/null; done
  _vz_breaker_open registry && echo OPEN || echo CLOSED')"
[[ "$r" == "CLOSED" ]] && ok "AI_STACK_BREAKER_TRIPS=0 disables (kill-switch)" || bad "kill-switch wrong: '$r'"
r="$(_brk '
  _av_docker(){ slow_empty; }
  for i in 1 2 3; do svc_available_version s$i >/dev/null; done
  svc_type(){ echo npm-global; }
  _av_npm(){ touch_probe; printf "1.0"; }
  out="$(svc_available_version other)"
  echo "$out|$([[ -f "$T/dispatched" ]] && echo dispatched || echo blocked)"')"
[[ "$r" == "1.0|dispatched" ]] && ok "transports independent: OPEN registry does not blind npm" || bad "transport isolation wrong: '$r'"
r="$(_brk '
  echo "OPEN registry" > "$(_vz_breaker_file)"
  command(){ return 1; }   # no docker
  image_is_local_built(){ return 1; }; image_is_pinned(){ return 1; }
  img_local_digest(){ printf ""; }
  check_image foo/bar:latest')"
[[ "$r" == "unknown" ]] && ok "OPEN + no local digest → 'unknown', never a silent 'build' (council A3)" || bad "check_image open-classification wrong: '$r'"
r="$(_brk '
  rm -rf "$T/installer"    # absent state dir → breaker must be INERT, no crash
  _av_docker(){ slow_empty; }
  for i in 1 2 3 4; do svc_available_version s$i >/dev/null; done
  _av_docker(){ printf "sha256:bbb"; }
  svc_available_version s5')"
[[ "$r" == "sha256:bbb" ]] && ok "absent state dir → breaker inert, probes keep flowing, no set -Eeuo crash" || bad "absent-dir hardening wrong: '$r'"

r="$(_brk '
  AI_STACK_BREAKER_TRIPS=off AI_STACK_BREAKER_SLOW_S=fast   # garbage knobs (typo class)
  _av_docker(){ slow_empty; }
  for i in 1 2 3; do svc_available_version s$i >/dev/null; done
  st="$(_vz_breaker_open registry && echo OPEN || echo CLOSED)"
  echo "alive|$st"')"
[[ "$r" == "alive|OPEN" ]] && ok "garbage knob values → validated to defaults, NO set-u crash (impl-council blocking)" || bad "garbage knobs crash or misbehave: '$r'"
r="$(_brk '
  _av_docker(){ slow_empty; }
  for i in 1 2 3; do svc_available_version s$i >/dev/null; done
  svc_type(){ echo brew-service; }
  _av_brew(){ tick 10; printf ""; }
  for i in 4 5 6; do svc_available_version s$i >/dev/null; done
  _vz_breaker_opened_list')"
[[ "$r" == "brew registry" || "$r" == "registry brew" ]] && ok "opened_list names BOTH open transports ('$r')" || bad "multi-transport list wrong: '$r'"

echo "== statics: wiring, guards, lifecycle =="
grep -qF 'svc_upgrade "$name" owner' "$ROOT/installer/lib/status.sh" && ok "status.sh carries the owner-display read" || bad "status.sh owner read missing"
grep -qF 'probe circuit-breaker OPEN (' "$UPG" && grep -qF 'probe circuit-breaker OPEN (' "$ROOT/installer/lib/status.sh" \
  && grep -qF 'AI_STACK_BREAKER_TRIPS=0 disables' "$UPG" && grep -qF 'AI_STACK_BREAKER_TRIPS=0 disables' "$ROOT/installer/lib/status.sh" \
  && ok "disclosure anchor phrases present in BOTH consumers (drift guard)" || bad "disclosure wording drifted between upgrade.sh and status.sh"
grep -qE 'npm-global\|uv-venv\|git-pull\|uv-tool\|uv-reqs\|sandbox-pip\|brew\|rebuild\|phase-rerun\|none\)' "$UPG" && ok "dispatch whitelist UNCHANGED (oracle axis adds no methods)" || bad "dispatch whitelist changed"
c="$(grep -c '_vz_breaker_reset' "$UPG")"; [[ "$c" -ge 3 ]] && ok "breaker reset at the 3 upgrade.sh scan entries ($c)" || bad "breaker resets missing in upgrade.sh ($c)"
grep -q '_vz_breaker_reset' "$ROOT/installer/lib/status.sh" && ok "breaker reset in status --versions" || bad "status.sh missing breaker reset"
c="$(grep -c '_breaker_disclose' "$UPG")"; [[ "$c" -ge 4 ]] && ok "disclosure+cleanup after all three upgrade.sh loops ($c incl. def)" || bad "breaker disclosure sites missing ($c)"
grep -q '_vz_breaker_opened_list' "$ROOT/installer/lib/status.sh" && ok "status.sh prints the disclosure" || bad "status.sh missing disclosure"
grep -qF '"$m" == "none"' "$VERS" && ok "oracle axis guarded: read only when method absent/none (typo'd methods keep '-')" || bad "oracle guard missing"
c="$(grep -c '_vz_running_container' "$VERS")"; [[ "$c" -ge 3 ]] && ok "anchored container match used by BOTH sandbox oracles ($c)" || bad "anchored matcher not shared ($c)"
grep -q 'oracle: sandbox-npm' "$ROOT/services.yml" && grep -qc 'owner: hermes_fleet' "$ROOT/services.yml" >/dev/null && ok "services.yml carries pi oracle + telegram/slack owner keys" || bad "services.yml keys missing"
[[ "$(yq -r '.services.pi.upgrade.method // "ABSENT"' "$ROOT/services.yml")" == "ABSENT" ]] && ok "pi still method-less (up_openshell arm preserved)" || bad "pi gained a method"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
