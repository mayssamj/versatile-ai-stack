#!/usr/bin/env bash
# test_no_glued_multibyte_var.sh — regression test for the "$var<multibyte>"
# unbound-variable crash class (root cause + fix documented in
# installer/lib/lint_glued_var.sh, the shared scanner this test and doctor check 72
# both use). A bare $name glued to a multibyte glyph (e.g. $VER_BEFORE→) crashes
# bash under `set -u` in a UTF-8 locale; brace-delimit (${name}) to fix.
#
# This test also self-checks the detector against a synthetic bad file, so a
# silently-broken scan (macOS `grep -P` no-ops on byte ranges — that's WHY the
# scanner is perl) can never masquerade as a clean repo.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT/installer/lib/lint_glued_var.sh"
cd "$ROOT"
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); echo "  ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "== detector self-check (a broken scan must FAIL, not pass vacuously) =="
# Feed a known-bad line in a real temp file through the true discover→read→match
# path (_glued_var_detect reads a NUL-delimited path list on stdin).
tmpd="$(mktemp -d)"; trap 'rm -rf "$tmpd"' EXIT
printf 'x="$FOO\xe2\x86\x92$BAR"\n' > "$tmpd/synthetic_bad.sh"   # $FOO glued to → (U+2192)
probe="$(printf '%s\0' "$tmpd/synthetic_bad.sh" | _glued_var_detect)"
if [[ -n "$probe" ]]; then ok "detector catches a synthetic \$FOO→\$BAR line"
else bad "detector self-check FAILED — the byte scan is broken; results below are meaningless"; fi

echo "== no bare \$var glued to a multibyte char in tracked shell code =="
if hits="$(scan_glued_multibyte_var "$ROOT")"; then
  ok "no glued \$var→<multibyte> occurrences (use \${var} to delimit)"
else
  bad "glued \$var→<multibyte> found — brace-delimit the variable (\${var}):"
  printf '%s\n' "$hits" | sed 's/^/       /'
fi

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
