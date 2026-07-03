#!/usr/bin/env bash
# test_hermes_workspace_track_latest.sh — the Hermes Workspace agent image TRACKS LATEST on
# `upgrade` (AI_STACK_UPGRADE=1) but pins a digest for reproducibility; the resolver FALLS BACK
# (loudly) to the known-good default when the registry/proxy is blocked; a compat drift FAILS
# the phase (not a silent green); and `upgrade hermes` fans out to the group. Pure-offline:
# extracts the phase-05 functions + collect_targets and stubs the network; no live calls.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P05="$ROOT/installer/phases/05_uis.sh"
UPG="$ROOT/installer/lib/upgrade.sh"
SVC="$ROOT/services.yml"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }
command -v yq >/dev/null 2>&1 || { echo "yq not on PATH — skipping (not a failure)"; exit 0; }

DEF="$(sed -n 's/^HERMES_AGENT_DEFAULT="\(.*\)".*/\1/p' "$P05" | head -1)"

# 1. Default is a valid multi-arch INDEX-digest pin (NOT :latest, NOT a bare tag).
[[ "$DEF" =~ ^nousresearch/hermes-agent:v[0-9][0-9.]*@sha256:[0-9a-f]{64}$ ]] \
  && ok "HERMES_AGENT_DEFAULT is a pinned index digest (${DEF#nousresearch/hermes-agent:})" \
  || bad "HERMES_AGENT_DEFAULT is not a valid pinned index digest: $DEF"

# 2. On upgrade the stamp gate is BYPASSED — else AI_STACK_UPGRADE=1 would early-exit (no-op).
grep -q 'AI_STACK_UPGRADE:-}" != "1" ]] && precheck' "$P05" \
  && ok "phase 05 bypasses the stamp gate on AI_STACK_UPGRADE=1 (upgrade actually runs)" \
  || bad "phase 05 would early-exit on upgrade → no-op"

# 3a. Resolver falls back when the GitHub API is blocked (empty tag → first guard).
out3a="$(
  HERMES_AGENT_DEFAULT="$DEF"; warn(){ :; }; curl(){ return 7; }; img_remote_digest(){ printf ''; }
  source <(sed -n '/^_hermes_agent_latest_ref()/,/^}/p' "$P05"); _hermes_agent_latest_ref
)"
[[ "$out3a" == "$DEF" ]] \
  && ok "resolver falls back to default when the GitHub API is blocked (empty tag)" \
  || bad "resolver did NOT fall back on GitHub failure (got: '$out3a')"

# 3b. Resolver falls back when the TAG resolves but the registry DIGEST is blocked (2nd guard —
#     the corporate-network failure mode QA proved the old test never reached).
out3b="$(
  HERMES_AGENT_DEFAULT="$DEF"; warn(){ :; }
  curl(){ printf '{"tag_name":"v2026.7.1"}'; }      # tag resolves…
  img_remote_digest(){ printf ''; }                  # …but the digest fetch is blocked
  source <(sed -n '/^_hermes_agent_latest_ref()/,/^}/p' "$P05"); _hermes_agent_latest_ref
)"
[[ "$out3b" == "$DEF" ]] \
  && ok "resolver falls back to default when the registry digest is blocked (tag OK, digest empty)" \
  || bad "resolver returned a MALFORMED ref on a blocked digest (got: '$out3b')"

# 4. Compat-fail HONESTY WIRING (not a string grep): the drift branch sets _ws_compat_fail=1,
#    it is durably record()'d, AND the phase exits 1 on that flag so the summary shows FAILED.
grep -q '_ws_compat_fail=1' "$P05" \
  && ok "compat drift sets _ws_compat_fail=1" || bad "compat drift does not set a fail flag"
grep -q 'record "phase 05 UPGRADE COMPAT FAIL' "$P05" \
  && ok "compat drift is durably record()'d (run-log, not warn-only)" || bad "compat drift not record()'d"
grep -Eq '\[\[ "\$\{_ws_compat_fail:-0\}" == "1" \]\]; then' "$P05" && grep -A2 '_ws_compat_fail:-0' "$P05" | grep -q 'exit 1' \
  && ok "phase exits 1 on compat-fail → up_phase_rerun records RESULT=FAILED (no silent green)" \
  || bad "compat-fail does not exit 1 → summary would show a false 'success'"

# 5. Reproducibility: a plain (re-)install keeps the EXISTING override pin (no re-resolve/network).
tmp="$(mktemp -d)"; mkdir -p "$tmp/ws"
printf 'services:\n  hermes-agent:\n    image: nousresearch/hermes-agent:v0.0.9@sha256:%064d\n' 0 > "$tmp/ws/docker-compose.override.yml"
pin="$(
  WS_DIR="$tmp/ws"
  source <(sed -n '/^_hermes_agent_current_pin()/,/^}/p' "$P05"); _hermes_agent_current_pin
)"
rm -rf "$tmp"
[[ "$pin" == nousresearch/hermes-agent:v0.0.9@sha256:* ]] \
  && ok "_hermes_agent_current_pin returns the existing override pin (re-install stays put, no network)" \
  || bad "_hermes_agent_current_pin did not return the existing pin (got: '$pin')"

# 6. Functional: `upgrade hermes` fans out to every group:hermes service (incl. hermes_workspace).
grp="$(
  AI_STACK="$ROOT"; SERVICES_YML="$SVC"
  source "$ROOT/installer/lib/services_accessors.sh"
  source <(sed -n '/^collect_targets()/,/^}/p' "$UPG")
  declare -a t; collect_targets t hermes; printf '%s ' "${t[@]}"
)"
[[ " $grp " == *" hermes_fleet "* && " $grp " == *" hermes_workspace "* && " $grp " == *" hermes_telegram "* && " $grp " == *" hermes_slack "* ]] \
  && ok "collect_targets(hermes) → $grp" \
  || bad "collect_targets(hermes) missing a surface (got: '$grp')"

# 7. FRESH install (no override, not upgrade) → the committed DEFAULT, and the network resolver is
#    NOT called (reproducibility: two installs of one commit stay identical; QA-named gap).
flag="${TMPDIR:-/tmp}/net_called_$$"; rm -f "$flag"
out7="$(
  HERMES_AGENT_DEFAULT="$DEF"; unset AI_STACK_UPGRADE 2>/dev/null; log(){ :; }
  _hermes_agent_current_pin(){ printf ''; }                                   # no override yet (fresh)
  _hermes_agent_latest_ref(){ : > "$flag"; printf 'nousresearch/hermes-agent:vNET@sha256:0'; }  # must NOT run
  source <(sed -n '/^_hermes_agent_choose_image()/,/^}/p' "$P05"); _hermes_agent_choose_image
)"
[[ "$out7" == "$DEF" && ! -f "$flag" ]] \
  && ok "fresh install → committed DEFAULT, network resolver NOT called (reproducible + gated)" \
  || bad "fresh install wrong (got: '$out7', network_called=$([[ -f "$flag" ]] && echo yes || echo no))"
rm -f "$flag"

# 8. LOG-LEAK GUARD (live-caught bug): _hermes_agent_choose_image's STDOUT is captured as the
#    image ref, so any diagnostic MUST go to stderr. Stub `log` to write to STDOUT exactly like
#    the REAL log() does (common.sh has no >&2 on log) — the captured ref must be ONLY the
#    resolved image, never the log line glued on. (The other cases stub log(){ :; }, which is
#    precisely why 153 offline assertions missed this; here we reproduce the real stream.)
out8="$(
  HERMES_AGENT_DEFAULT="$DEF"; export AI_STACK_UPGRADE=1
  log(){ printf '[ts] %s\n' "$*"; }                                  # REAL log → stdout (the trigger)
  _hermes_agent_latest_ref(){ printf 'nousresearch/hermes-agent:v9.9.9@sha256:beef'; }
  source <(sed -n '/^_hermes_agent_choose_image()/,/^}/p' "$P05"); _hermes_agent_choose_image
)"
[[ "$out8" == "nousresearch/hermes-agent:v9.9.9@sha256:beef" ]] \
  && ok "choose_image on upgrade returns ONLY the ref (log → stderr, no capture leak)" \
  || bad "choose_image LEAKED a stdout log line into the image ref (got: '$out8')"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
