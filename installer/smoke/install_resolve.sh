#!/usr/bin/env bash
# Smoke for resolve_phase_script's strategy #4 (mayssam-ai-stack.sh): a name shown in
# `status` (services.yml) that is a sub-component installed BY a differently-named
# phase (docs_ingestor -> 06_documents, litellm_guardrails_* -> 04g_security,
# claw3d_bridge -> 19_claw3d …) must be DIRECTLY installable — while a name that is
# itself a phase (claw3d, openshell, mempalace) keeps resolving via the phase-script
# strategy, and a genuine typo still bails. Each case also pins the RESOLUTION
# MECHANISM (the strategy-4 "resolving there" stderr note) so a future reordering of
# the strategies can't silently regress. All via `install <x> --plan` (READ-ONLY —
# installs/changes nothing). Note: opt-in extras 21–27 (portless, cmux, sourcegraph …)
# each have a same-named phase script, so they resolve via the phase strategy, not #4.
# Run:  bash installer/smoke/install_resolve.sh
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
STACK="$AI_STACK/mayssam-ai-stack.sh"
NOTE="resolving there"   # the strategy-4 (service -> phase) stderr marker

hdr "Smoke install-resolve — service-name -> owning-phase (read-only --plan)"

# _plan <selector> -> echo combined --plan output; abort the suite on a non-zero exit.
_plan() {
  local sel="$1" out rc=0
  out="$(bash "$STACK" install "$sel" --plan 2>&1)" || rc=$?
  [[ $rc -eq 0 ]] || { err "install $sel --plan FAILED (rc=$rc)"; echo "$out" | tail -3; exit 1; }
  printf '%s' "$out"
}
# phase id appears as a standalone token (matches both the note "phase 06 (…)" and the
# plan line "✓ 06 documents"); the [^0-9a-z] boundaries stop "04" matching "04f".
_mentions_phase() { grep -qE "(^|[^0-9a-z])$2([^0-9a-z]|$)" <<<"$1"; }

# via_service <sel> <want>: must resolve to <want> AND fire the #4 note (proves the
# SERVICE->phase path, not a coincidental phase-name match).
via_service() {
  local sel="$1" want="$2" out; out="$(_plan "$sel")"
  _mentions_phase "$out" "$want" || { err "$sel did not resolve to phase $want"; echo "$out" | tail -4; exit 1; }
  grep -q "$NOTE" <<<"$out"       || { err "$sel resolved but NOT via strategy #4 (no service->phase note — resolver order changed?)"; exit 1; }
  ok "$sel -> phase $want (via service lookup)"
}
# phase_wins <sel> <want>: a name that is BOTH a service AND a phase — the phase-script
# strategy must win and the #4 note must NOT fire.
phase_wins() {
  local sel="$1" want="$2" out; out="$(_plan "$sel")"
  _mentions_phase "$out" "$want" || { err "$sel did not resolve to phase $want"; echo "$out" | tail -4; exit 1; }
  grep -q "$NOTE" <<<"$out"       && { err "$sel hit strategy #4 but a phase script should win (ordering regression!)"; exit 1; }
  ok "$sel -> phase $want (phase strategy wins; #4 not reached)"
}

# --- 1. sub-component service names resolve via strategy #4 -------------------
log "service sub-component names resolve to the phase that installs them (strategy #4)"
via_service docs_ingestor              06
via_service litellm_guardrails_builtin 04g
via_service pi_gateway_litellm         15
via_service claw3d_bridge              19    # phase name 'claw3d' has a digit — edge case
via_service byterover_cli              09

# --- 2. REGRESSION: id / name / alias / same-named service resolve WITHOUT #4 -
log "phase ids, names, aliases, and same-named services resolve without strategy #4"
phase_wins 06           06     # numeric id
phase_wins documents    06     # phase name
phase_wins hermes_fleet 04f    # phase name
phase_wins docs         06     # friendly alias
phase_wins claw3d       19     # SERVICE whose name == phase name: phase MUST win
phase_wins openshell    04     # ditto
phase_wins mempalace    26     # ditto

# --- 3. a genuine typo still bails (no silent mis-resolution) -----------------
log "an unknown selector still bails instead of mis-resolving"
rc=0
bash "$STACK" install no_such_service_xyz --plan >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] || { err "typo 'no_such_service_xyz' should have bailed, but exited 0"; exit 1; }
ok "unknown selector bails (exit $rc)"

ok "install-resolve smoke: all tests passed"
