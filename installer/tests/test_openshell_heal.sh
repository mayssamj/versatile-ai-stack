#!/usr/bin/env bash
# test_openshell_heal.sh — offline tests for the openshell.sh heal WRAPPERS that
# historically drifted / were inspection-only: the storm-wrapper UNKNOWN mapping (G9),
# the G5 UUID token-path glob (incl. the >1-match fail-explicit), and the G4 gateway-
# relaunch name-scoping. Fake `docker` on PATH + temp $HOME; no live stack, no model.
# Run: bash installer/tests/test_openshell_heal.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export AI_STACK="$(cd "$HERE/../.." && pwd)"
# shellcheck disable=SC1090
source "$AI_STACK/installer/lib/openshell.sh" 2>/dev/null   # also sources storm-detect.sh

# NOTE: openshell.sh's functions use common.sh's ok/err/warn/log, so the test counters
# MUST NOT shadow those names — use t_ok/t_bad.
P=0; F=0
t_ok(){ P=$((P+1)); printf '  ok   %s\n' "$1"; }
t_bad(){ F=$((F+1)); printf '  FAIL %s\n' "$1"; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
CALLS="$TMP/calls"; : > "$CALLS"
cat > "$TMP/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$CALLS_FILE"
case "$1 ${2:-}" in
  "ps -q"|"ps -aq") echo fakecid ;;
esac
case "${1:-}" in
  inspect)
    case "$*" in
      *State.StartedAt*) echo "2026-06-30T13:32:28.5Z" ;;
      *.Name*)           echo "/openshell-${FAKE_SBX:-hermes-fleet-v1}-${FAKE_UUID:-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee}" ;;
      *State.Status*)    echo running ;;
    esac ;;
  logs)    echo "${FAKE_LOGS:-ok: serving}" ;;
  version) echo ok ;;
esac
EOF
chmod +x "$TMP/docker"
export CALLS_FILE="$CALLS" PATH="$TMP:$PATH" HOME="$TMP"

echo "== openshell_token_storm wrapper maps storm_detect rc {0,1,2} correctly (G9 UNKNOWN) =="
storm_detect(){ return 2; }; openshell_token_storm hermes-fleet-v1; rc=$?
(( rc == 1 )) && t_ok "UNKNOWN(rc2) -> not-storming(rc1)" || t_bad "UNKNOWN mapping rc=$rc (want 1)"
storm_detect(){ return 0; }; openshell_token_storm hermes-fleet-v1; (( $? == 0 )) && t_ok "storm(rc0) -> rc0" || t_bad "storm mapping wrong"
storm_detect(){ return 1; }; openshell_token_storm hermes-fleet-v1; (( $? == 1 )) && t_ok "healthy(rc1) -> rc1" || t_bad "healthy mapping wrong"

echo "== _osh_token_path G5: glob by UUID, NOT the /default/ slug =="
export FAKE_UUID="11111111-2222-3333-4444-555555555555"
D="$HOME/.local/state/openshell/docker-sandbox-tokens"
mkdir -p "$D/somegw/$FAKE_UUID"; echo jwt > "$D/somegw/$FAKE_UUID/sandbox.jwt"
got="$(_osh_token_path hermes-fleet-v1)"; rc=$?
{ (( rc == 0 )) && [[ "$got" == *"/somegw/$FAKE_UUID/sandbox.jwt" ]]; } && t_ok "resolves under NON-default gateway slug" || t_bad "got='$got' rc=$rc"
mkdir -p "$D/othergw/$FAKE_UUID"; echo jwt > "$D/othergw/$FAKE_UUID/sandbox.jwt"
_osh_token_path hermes-fleet-v1 >/dev/null 2>&1; (( $? == 1 )) && t_ok ">1 match -> fail-explicit (rc1)" || t_bad ">1 match not rejected"
rm -rf "$D/somegw" "$D/othergw"
_osh_token_path hermes-fleet-v1 >/dev/null 2>&1; (( $? == 1 )) && t_ok "no match -> rc1" || t_bad "no-match not rc1"

echo "== _osh_relaunch_gateway G4: name-scoped to hermes-fleet-v1 only =="
: > "$CALLS"; _osh_relaunch_gateway pi-v1 fakecid >/dev/null 2>&1
grep -q exec "$CALLS" && t_bad "pi-v1 should NOT exec a gateway" || t_ok "pi-v1: no gateway exec (has no gateway)"
: > "$CALLS"; _osh_relaunch_gateway hermes-fleet-v1 fakecid >/dev/null 2>&1
{ grep -q 'exec -d' "$CALLS" && grep -q -- '--replace' "$CALLS"; } && t_ok "hermes-fleet-v1: exec -d … --replace invoked" || t_bad "hermes relaunch not invoked (calls: $(cat "$CALLS"))"

echo
echo "RESULT: $P passed, $F failed"
(( F == 0 ))
