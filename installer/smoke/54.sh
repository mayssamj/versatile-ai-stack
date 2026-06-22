#!/usr/bin/env bash
# Smoke for the openshell-gateway doctor check (installer/doctor/checks/54_openshell_gateway.sh).
# Named 54.sh so `vz-ai-stack.sh test 54` resolves it (cmd_test strips after '_').
#
# WHY: install warns "openshell is not registered as a brew service" but doctor
# never detected it. This check asserts the gateway is UP on :17670 and MANAGEABLE
# via brew services. This smoke pins every branch:
#   - not installed                 -> pass + [skip]   (OpenShell not in use)
#   - up + brew-manageable          -> pass (green, reports port + state)
#   - up + untrusted tap            -> FAIL + "brew trust" guidance  (the reported bug)
#   - up + brew present, no service -> FAIL + "no brew service" note
#   - down + untrusted tap          -> FAIL + start guidance
#   - down + brew-manageable        -> FAIL (gateway dead)
#   - up + brew ABSENT (uv/pipx)    -> FAIL + uv/pipx note
#   - up + brew state "stopped"     -> pass (green; manual-start branch)
#
# HERMETIC: stubs port_listening + brew + the installed/has-brew probes (defined AFTER
# the source so they win), so it needs no live openshell/brew/docker and is safe from
# any worktree path. Driven by STUB_* env vars.
# Run: bash installer/smoke/54.sh   (or: vz-ai-stack.sh test 54)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; export AI_STACK
source "$AI_STACK/installer/lib/common.sh"

hdr "Smoke 54 — openshell gateway liveness + manageability"

# Load the check exactly as doctor.sh does.
declare -a CHECKS=(); declare -A CHECK_TITLE=()
source "$AI_STACK/installer/doctor/checks/54_openshell_gateway.sh"

# --- stubs (defined AFTER the source so they win); driven by STUB_* env vars ---
port_listening() { [[ "${STUB_UP:-no}" == yes ]]; }
_osg_installed() { [[ "${STUB_INSTALLED:-yes}" == yes ]]; }
_osg_has_brew()  { [[ "${STUB_HAS_BREW:-yes}" == yes ]]; }
brew() {
  if [[ "${1:-}" == services && "${2:-}" == list ]]; then
    # Emit an openshell row only when STUB_SVC is set (== brew can see it). 4-column
    # format like real `brew services list`; awk is field-count-independent.
    [[ -n "${STUB_SVC:-}" ]] && printf 'Name       Status   User  File\nopenshell  %s   me\n' "$STUB_SVC"
    return 0
  fi
  if [[ "${1:-}" == services && "${2:-}" == info ]]; then
    # The check reads `$(brew services info ... 2>&1 || true)` and greps the TEXT — the
    # return code is absorbed by `|| true`, so only this stderr output drives detection.
    if [[ "${STUB_UNTRUSTED:-no}" == yes ]]; then
      echo "Error: Refusing to load formula nvidia/openshell/openshell from untrusted tap nvidia/openshell." >&2
      return 1
    fi
    return 0
  fi
  [[ "${1:-}" == --prefix ]] && { echo /opt/homebrew; return 0; }
  return 0
}

run() { set +e; OUT="$(openshell_gateway_diagnose 2>&1)"; RC=$?; set -e; }
flags() { grep -qi "$1" <<<"$OUT"; }
pass=0; fail=0
yes_() { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
no_()  { fail=$((fail+1)); printf '  ✗ %s\n    --- diagnose output ---\n%s\n' "$1" "$OUT"; }

# 1. not installed -> pass + skip
STUB_INSTALLED=no run
{ [[ $RC -eq 0 ]] && flags "skip"; } && yes_ "not installed -> pass + [skip]" \
  || no_ "not-installed should pass with [skip]"

# 2. up + brew-manageable -> green (assert message + port, not just RC)
STUB_INSTALLED=yes STUB_HAS_BREW=yes STUB_UP=yes STUB_SVC=started STUB_UNTRUSTED=no run
{ [[ $RC -eq 0 ]] && flags "gateway up on" && flags "17670"; } \
  && yes_ "up + brew-manageable -> green (reports :17670 + state)" \
  || no_ "up + manageable should be green and report :17670 (false RED or missing detail)"

# 3. up + UNTRUSTED TAP -> red + brew-trust guidance (the reported bug)
STUB_INSTALLED=yes STUB_HAS_BREW=yes STUB_UP=yes STUB_SVC= STUB_UNTRUSTED=yes run
{ [[ $RC -ne 0 ]] && flags "untrusted tap" && flags "brew trust"; } \
  && yes_ "up + untrusted tap -> red + brew-trust guidance" \
  || no_ "up + untrusted tap not flagged with brew-trust guidance"

# 4. up + brew present but NO service (not untrusted) -> red + "no brew service"
STUB_INSTALLED=yes STUB_HAS_BREW=yes STUB_UP=yes STUB_SVC= STUB_UNTRUSTED=no run
{ [[ $RC -ne 0 ]] && flags "no brew service"; } && yes_ "up + no-service -> red + no-brew-service note" \
  || no_ "up + no-service not flagged correctly"

# 5. down + untrusted tap -> red + start guidance
STUB_INSTALLED=yes STUB_HAS_BREW=yes STUB_UP=no STUB_SVC= STUB_UNTRUSTED=yes run
{ [[ $RC -ne 0 ]] && flags "DOWN" && flags "brew trust"; } \
  && yes_ "down + untrusted -> red + start guidance" \
  || no_ "down + untrusted not flagged correctly"

# 6. down + brew-manageable -> red (gateway dead)
STUB_INSTALLED=yes STUB_HAS_BREW=yes STUB_UP=no STUB_SVC=started STUB_UNTRUSTED=no run
{ [[ $RC -ne 0 ]] && flags "DOWN"; } && yes_ "down + manageable -> red (gateway dead)" \
  || no_ "down should be red"

# 7. up + brew ABSENT (uv/pipx-only) -> red + uv/pipx note
STUB_INSTALLED=yes STUB_HAS_BREW=no STUB_UP=yes STUB_SVC= STUB_UNTRUSTED=no run
{ [[ $RC -ne 0 ]] && flags "uv/pipx"; } && yes_ "up + brew-absent -> red + uv/pipx note" \
  || no_ "up + brew-absent not flagged with uv/pipx note"

# 8. up + brew state "stopped" (manageable, manually started) -> green
STUB_INSTALLED=yes STUB_HAS_BREW=yes STUB_UP=yes STUB_SVC=stopped STUB_UNTRUSTED=no run
{ [[ $RC -eq 0 ]] && flags "stopped"; } && yes_ "up + brew 'stopped' but port up -> green (manual-start branch)" \
  || no_ "up + 'stopped' with port up should be green"

echo
if (( fail == 0 )); then printf '✓ 54 openshell_gateway: %d checks passed\n' "$pass"; exit 0
else printf '✗ 54 openshell_gateway: %d passed, %d FAILED\n' "$pass" "$fail"; exit 1; fi
