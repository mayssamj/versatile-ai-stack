#!/usr/bin/env bash
# Smoke for the codex-bridge doctor check (installer/doctor/checks/55_codex_bridge.sh).
# Named 55.sh so `mayssam-ai-stack.sh test 55` resolves it (cmd_test strips after '_').
#
# Pins every branch of codex_bridge_diagnose:
#   - not installed (no plist, not healthy)   -> pass + opt-in message
#   - installed but daemon not enabled        -> pass + "not enabled"
#   - loaded but endpoint unhealthy           -> FAIL + re-login guidance
#   - healthy but not wired into config.yaml  -> FAIL + "NOT wired"
#   - healthy + wired + LiteLLM uncheckable    -> pass + "uncheckable"
#   - healthy + wired + LiteLLM serves 0      -> FAIL + recreate guidance
#   - healthy + wired + LiteLLM serves 2      -> pass + "serves 2"
#
# HERMETIC: stubs _cb_installed/_cb_loaded/_cb_healthy/_cb_wired/_cb_served_count
# (defined AFTER the source so they win); needs no live daemon/litellm/launchctl.
# Driven by STUB_* env vars. Run: bash installer/smoke/55.sh  (or: stack test 55)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; export AI_STACK
source "$AI_STACK/installer/lib/common.sh"

hdr "Smoke 55 — codex bridge (ChatGPT subscription) doctor check"

declare -a CHECKS=(); declare -A CHECK_TITLE=()
source "$AI_STACK/installer/doctor/checks/55_codex_bridge.sh"

# --- stubs (defined AFTER the source so they win); driven by STUB_* env vars ---
_cb_installed()    { [[ "${STUB_INSTALLED:-no}" == yes ]]; }
_cb_loaded()       { [[ "${STUB_LOADED:-no}" == yes ]]; }
_cb_healthy()      { [[ "${STUB_HEALTHY:-no}" == yes ]]; }
_cb_wired()        { [[ "${STUB_WIRED:-yes}" == yes ]]; }
_cb_served_count() { echo "${STUB_SERVED:-0}"; }
# Point auth at an absent file so the loaded-unhealthy branch takes the
# "auth missing" message (deterministic, no dependence on a real ~/.codex).
CODEX_AUTH_FILE="${TMPDIR:-/tmp}/cb_smoke_auth_absent.json"; rm -f "$CODEX_AUTH_FILE"

run() { set +e; OUT="$(codex_bridge_diagnose 2>&1)"; RC=$?; set -e; }
flags() { grep -qi "$1" <<<"$OUT"; }
pass=0; fail=0
yes_() { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
no_()  { fail=$((fail+1)); printf '  ✗ %s\n    --- diagnose output ---\n%s\n' "$1" "$OUT"; }

# 1. not installed -> green + opt-in
STUB_INSTALLED=no STUB_HEALTHY=no run
{ [[ $RC -eq 0 ]] && flags "not installed"; } && yes_ "not installed -> green (opt-in)" \
  || no_ "not-installed should be green + opt-in message"

# 2. installed but daemon not enabled -> green
STUB_INSTALLED=yes STUB_LOADED=no STUB_HEALTHY=no run
{ [[ $RC -eq 0 ]] && flags "not enabled"; } && yes_ "installed, not enabled -> green" \
  || no_ "installed-not-enabled should be green"

# 3. loaded but unhealthy -> red + re-login guidance
STUB_INSTALLED=yes STUB_LOADED=yes STUB_HEALTHY=no run
{ [[ $RC -ne 0 ]] && flags "not healthy" && flags "codex login"; } \
  && yes_ "loaded + unhealthy -> red + codex-login guidance" \
  || no_ "loaded+unhealthy should be red with re-login guidance"

# 4. healthy but NOT wired into config -> red
STUB_INSTALLED=yes STUB_LOADED=yes STUB_HEALTHY=yes STUB_WIRED=no run
{ [[ $RC -ne 0 ]] && flags "not wired"; } && yes_ "healthy + not wired -> red" \
  || no_ "healthy+not-wired should be red"

# 5. healthy + wired + LiteLLM uncheckable -> green
STUB_INSTALLED=yes STUB_LOADED=yes STUB_HEALTHY=yes STUB_WIRED=yes STUB_SERVED=down run
{ [[ $RC -eq 0 ]] && flags "uncheckable"; } && yes_ "healthy + LiteLLM down -> green (uncheckable)" \
  || no_ "healthy+litellm-down should be green"

# 6. healthy + wired + serves 0 -> red + recreate guidance
STUB_INSTALLED=yes STUB_LOADED=yes STUB_HEALTHY=yes STUB_WIRED=yes STUB_SERVED=0 run
{ [[ $RC -ne 0 ]] && flags "not serving" && flags "recreate"; } \
  && yes_ "healthy + serves 0 -> red + recreate guidance" \
  || no_ "healthy+serves-0 should be red"

# 7. healthy + wired + serves 2 -> green
STUB_INSTALLED=yes STUB_LOADED=yes STUB_HEALTHY=yes STUB_WIRED=yes STUB_SERVED=2 run
{ [[ $RC -eq 0 ]] && flags "serves 2"; } && yes_ "healthy + serves 2 -> green" \
  || no_ "healthy+serves-2 should be green"

echo
if (( fail == 0 )); then printf '✓ 55 codex_bridge: %d checks passed\n' "$pass"; exit 0
else printf '✗ 55 codex_bridge: %d passed, %d FAILED\n' "$pass" "$fail"; exit 1; fi
