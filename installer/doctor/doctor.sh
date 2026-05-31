#!/usr/bin/env bash
# doctor.sh — diagnose & offer fixes.
#
# Discovers every checks/*.sh, sources them all, runs each <name>_diagnose,
# offers <name>_fix on failure if interactive. Reports a summary.
#
# Each check file must:
#   - Define <name>_diagnose : exits 0 on PASS, non-zero on FAIL.
#   - Define <name>_fix      : applies the fix (may prompt). Returns 0 on success.
#   - Append its name to the CHECKS array.
#   - Set CHECK_TITLE[<name>] to a short description.
set -Eeuo pipefail
shopt -s inherit_errexit nullglob

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/validate.sh"
source "$AI_STACK/installer/lib/prompt.sh"
source "$AI_STACK/installer/lib/litellm.sh"

declare -ag CHECKS=()
declare -Ag CHECK_TITLE=()

# Source every check file. Each must append to CHECKS + set CHECK_TITLE.
for f in "$AI_STACK"/installer/doctor/checks/*.sh; do
  # shellcheck source=/dev/null
  source "$f"
done

if (( ${#CHECKS[@]} == 0 )); then
  warn "no doctor checks found in installer/doctor/checks/"
  exit 0
fi

FILTER="${1:-}"
hdr "Running doctor checks${FILTER:+ (filter: $FILTER)}"

# Use a deliberately uncommon loop variable so check functions can't shadow it.
# (A function that does `for name in ...` without declaring `local name` would
# otherwise clobber the outer iteration.)
passed=0; failed=0; fixed=0; skipped=0
for __check in "${CHECKS[@]}"; do
  __title="${CHECK_TITLE[$__check]:-$__check}"
  if [[ -n "$FILTER" && "$__check" != *"$FILTER"* ]]; then
    skipped=$((skipped+1))
    continue
  fi
  printf '  %-60s ' "$__title"
  if "${__check}_diagnose" >/dev/null 2>&1; then
    printf '%s\n' "${C_GREEN}✓${C_RESET}"
    passed=$((passed+1))
  else
    printf '%s\n' "${C_RED}✗${C_RESET}"
    failed=$((failed+1))
    # Re-run to show the user the actual failure detail.
    "${__check}_diagnose" 2>&1 | sed 's/^/      /' || true
    if declare -F "${__check}_fix" >/dev/null; then
      if [[ "${NO_PROMPT:-0}" == "1" ]]; then
        note "    (auto-fix available; NO_PROMPT=1 so skipping)"
      elif confirm "    Auto-fix available. Apply?" Y; then
        if "${__check}_fix"; then
          ok   "    fixed."
          fixed=$((fixed+1))
        else
          err "    fix attempt failed."
        fi
      fi
    fi
  fi
done

printf '\nDoctor done: %d checks, %d passed, %d fixed, %d remaining failed, %d skipped.\n' \
  "$((passed+failed))" "$passed" "$fixed" "$((failed-fixed))" "$skipped"

(( failed - fixed > 0 )) && exit 1 || exit 0
