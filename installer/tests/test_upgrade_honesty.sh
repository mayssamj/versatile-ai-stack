#!/usr/bin/env bash
# test_upgrade_honesty.sh — the upgrade engine must NEVER report success it did
# not verify (SOUL §4/§18/§19; council finding #1-#4). Static mirror of
# upgrade.sh (the engine self-runs upgrade_main at load, so it can't be sourced
# in isolation — same reason test_upgrade_exhaustive.sh is static). Asserts:
#   - the shared version oracle is wired in
#   - the driver captures installed version BEFORE and AFTER the mutation
#   - RESULT is reconciled to the observed delta (no 'upgraded' on a no-op)
#   - the two known swallow sites (up_brew, up_openshell pip) no longer discard
#     the mutation's exit code, and a failed ollama bind re-assert is FAILED
#   - the summary carries a VERSION column so drift is visible even if reverify ok
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPG="$ROOT/installer/lib/upgrade.sh"
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); echo "  ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
have(){ grep -qF "$1" "$UPG"; }
haveE(){ grep -qE "$1" "$UPG"; }

echo "== shared oracle wired in =="
have 'source "$LIB/versions.sh"' && ok "upgrade.sh sources versions.sh" || bad "upgrade.sh does not source versions.sh"

echo "== driver captures a before/after version delta =="
have 'svc_installed_version' && ok "driver reads svc_installed_version" || bad "svc_installed_version never called"
have 'reconcile_result'      && ok "driver reconciles RESULT to the delta" || bad "reconcile_result not called"
haveE 'VER_BEFORE'           && ok "VER_BEFORE captured" || bad "no VER_BEFORE capture"
haveE 'VER_AFTER'            && ok "VER_AFTER captured" || bad "no VER_AFTER capture"

echo "== up_brew no longer swallows the upgrade =="
if have 'brew upgrade "$svc" || true'; then bad "up_brew STILL swallows: brew upgrade \"\$svc\" || true"; else ok "up_brew does not '|| true' the brew upgrade"; fi
have '_brew_rc' && ok "up_brew captures brew exit code" || bad "up_brew does not capture brew rc"
# a failed OLLAMA_HOST re-assert must surface, not just warn
if grep -A3 '_dep_ollama_patch_env' "$UPG" | grep -q 'RESULT=FAILED'; then ok "failed OLLAMA_HOST re-assert -> FAILED"; else bad "OLLAMA_HOST re-assert failure not promoted to FAILED"; fi

echo "== up_openshell (hermes_fleet) no longer swallows the pip upgrade =="
if have "pip install --upgrade hermes-agent' || true"; then bad "hermes_fleet STILL swallows the pip result with || true"; else ok "hermes_fleet pip result is not '|| true'-swallowed"; fi
if grep -qE '_pip_rc|Successfully installed|already satisfied' "$UPG"; then ok "hermes_fleet derives RESULT from the real pip outcome"; else bad "hermes_fleet does not inspect the pip outcome"; fi

echo "== summary surfaces the version so a no-op is visible =="
grep -q 'VERSION' "$UPG" && ok "print_summary has a VERSION column" || bad "no VERSION column in the summary"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
