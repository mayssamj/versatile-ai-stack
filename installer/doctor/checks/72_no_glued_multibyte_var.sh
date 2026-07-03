# 72_no_glued_multibyte_var.sh — no bare $var glued to a multibyte glyph in shell code.
#
# Guards the "$var<multibyte>" crash class: a bare $name written directly before a
# multibyte UTF-8 glyph (→ … · ✓ …) makes bash, in a UTF-8 locale under `set -u`,
# absorb the glyph's lead byte into the variable name and abort with
# "name<byte>: unbound variable". It shipped once in `upgrade` (verdisp=
# "$VER_BEFORE→$VER_AFTER") and detonated only on a real version move in a UTF-8
# locale, escaping every offline test. Running the scan here means every `doctor`
# invocation re-asserts the invariant — not just a manual test run. Fix any hit by
# brace-delimiting the variable: "${name}→...".
CHECKS+=(no_glued_multibyte_var)
CHECK_TITLE[no_glued_multibyte_var]="No bare \$var glued to a multibyte char in shell code (\${var} required)"

no_glued_multibyte_var_diagnose() {
  # shellcheck source=../../lib/lint_glued_var.sh
  source "$AI_STACK/installer/lib/lint_glued_var.sh"
  local out
  if out="$(scan_glued_multibyte_var "$AI_STACK")"; then
    return 0
  fi
  echo "bare \$var glued to a multibyte glyph — brace-delimit as \${var} (UTF-8 + set -u crash):"
  printf '%s\n' "$out"
  return 1
}
