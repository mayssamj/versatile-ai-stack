#!/usr/bin/env bash
# test_version_visibility.sh — Tier 1: the operator can SEE installed vs available
# versions in both `status` and `upgrade`, and the green all-clear no longer
# over-claims currency. Static wiring guards (the version LOGIC itself is unit-
# tested in test_versions.sh); mirrors the repo's static-test convention.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPG="$ROOT/installer/lib/upgrade.sh"; STAT="$ROOT/installer/lib/status.sh"; VER="$ROOT/installer/lib/versions.sh"
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); echo "  ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "== shared oracle owns the docker currency logic (status can reuse it) =="
grep -q 'check_image()' "$VER"      && ok "check_image lives in versions.sh" || bad "check_image not in versions.sh"
grep -q 'version_status()' "$VER"   && ok "version_status lives in versions.sh" || bad "version_status missing"
# upgrade.sh must NOT re-define the moved helpers (only reference them)
if grep -qE '^check_image\(\)' "$UPG"; then bad "upgrade.sh still DEFINES check_image (dup)"; else ok "upgrade.sh does not re-define check_image"; fi

echo "== status --versions surfaces installed + available =="
grep -q 'versions|-V' "$STAT"          && ok "status has a --versions/-V flag" || bad "status --versions flag missing"
grep -q 'print_versions_view' "$STAT"  && ok "status has print_versions_view" || bad "print_versions_view missing"
grep -q 'source "\$AI_STACK/installer/lib/versions.sh"' "$STAT" && ok "status sources the shared oracle" || bad "status does not source versions.sh"
grep -q -- '--local' "$STAT"           && ok "status --versions has a --local fast path" || bad "no --local"

echo "== upgrade --check no longer blanket-'manual's npm/pip/git =="
if grep -q 'consult the shared oracle' "$UPG" && grep -A45 'consult the shared oracle' "$UPG" | grep -q 'version_classify'; then ok "check_one catch-all consults the oracle (installed+available, not blanket-manual)"; else bad "check_one still blanket-manual (or the pin/config block displaced version_classify)"; fi

echo "== upgrade prints a pre-upgrade version report =="
grep -q 'PREFLIGHT=1; print_check_report' "$UPG" && ok "pre-upgrade report wired into the mutate path" || bad "no pre-upgrade report"
grep -q -- '--no-check' "$UPG" && ok "--no-check escape hatch exists" || bad "no --no-check flag"

echo "== the green all-clear no longer over-claims currency =="
grep -q 'Currency is NOT confirmed' "$UPG" && ok "unverified rows suppress the false all-clear" || bad "all-clear still unconditional"
grep -q 'unconfirmed' "$UPG" && ok "check report counts unverifiable rows" || bad "no unconfirmed count"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
