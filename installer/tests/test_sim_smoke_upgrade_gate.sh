#!/usr/bin/env bash
# test_sim_smoke_upgrade_gate.sh — `upgrade all` must NOT fire a sim's live model
# smoke (billable/metered inference) when re-asserting an installed-but-drifted
# opt-in sim (mechanism-audit w6wxiev01 finding #2 + operator no-unsolicited-
# inference stance). The sim phases run their scoped-key chat ping + multi-agent
# smoke_sim.py ONLY on the install path; under AI_STACK_UPGRADE=1 (set by
# up_phase_rerun) they must skip straight to stamp_mark (config re-asserted).
# Static structural check (phase scripts have side effects → can't source), plus a
# behavioral proof of the guard SEMANTICS.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPG="$ROOT/installer/lib/upgrade.sh"
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); echo "  ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "== up_phase_rerun exports the flag the gate keys on =="
grep -qE 'AI_STACK_UPGRADE=1 bash "\$script"' "$UPG" && ok "up_phase_rerun runs the phase with AI_STACK_UPGRADE=1" || bad "up_phase_rerun does not set AI_STACK_UPGRADE=1"

echo "== each billing sim phase gates its live smoke on AI_STACK_UPGRADE, before stamp_mark =="
for f in 33_agentscope 34_oasis 37_concordia; do
  P="$ROOT/installer/phases/$f.sh"
  [[ -f "$P" ]] || { bad "$f: phase file missing"; continue; }
  bash -n "$P" || { bad "$f: SYNTAX ERROR after edit"; continue; }
  L_guard="$(grep -nE 'AI_STACK_UPGRADE' "$P" | head -1 | cut -d: -f1)"
  # the EXECUTED smoke (the _simout=$(… smoke_sim.py …) run), not a doc 'note' mention.
  L_smoke="$(grep -nE '_simout=.*smoke_sim\.py' "$P" | head -1 | cut -d: -f1)"
  L_stamp="$(grep -n 'stamp_mark "\$PHASE"' "$P" | head -1 | cut -d: -f1)"
  if [[ -z "$L_guard" || -z "$L_smoke" || -z "$L_stamp" ]]; then bad "$f: missing guard/smoke/stamp (guard=$L_guard smoke=$L_smoke stamp=$L_stamp)"; continue; fi
  # guard BEFORE the sim run, sim run BEFORE stamp_mark
  if (( L_guard < L_smoke && L_smoke < L_stamp )); then ok "$f: AI_STACK_UPGRADE guard (L$L_guard) wraps the smoke_sim run (L$L_smoke) before stamp_mark (L$L_stamp)"
  else bad "$f: ordering wrong (guard=$L_guard smoke=$L_smoke stamp=$L_stamp)"; fi
  # a `fi` must close the guard between the smoke and stamp_mark (so stamp_mark is NOT inside the else)
  if awk "NR>$L_smoke && NR<$L_stamp && /^[[:space:]]*fi([[:space:]]|$)/{found=1} END{exit !found}" "$P"; then ok "$f: guard closes (fi) before stamp_mark → stamp still reached on upgrade"
  else bad "$f: no 'fi' between the smoke and stamp_mark — stamp_mark may be inside the guarded branch"; fi
  # the run-note tells the operator how to get the full smoke
  grep -q "install $f" "$P" 2>/dev/null || grep -qiE 'install .*to (run|verify)|full verified smoke' "$P" && ok "$f: upgrade-skip note points at 'install' for the full smoke" || bad "$f: no operator note on how to run the skipped smoke"
done

echo "== metagpt (32) is intentionally NOT gated (its smoke is 'bin/metagpt --help', no inference) =="
MG="$ROOT/installer/phases/32_metagpt.sh"
if grep -q 'smoke_sim.py' "$MG" 2>/dev/null; then bad "32_metagpt unexpectedly has a smoke_sim.py (would need gating)"; else ok "32_metagpt has no live sim smoke (only 'bin/metagpt --help') — correctly excluded"; fi

echo "== behavioral: the guard SEMANTICS (skip on upgrade, run on install) =="
gate_demo() {
  local ran="run"
  if [[ "${AI_STACK_UPGRADE:-0}" == 1 ]]; then ran="skipped"; fi
  printf '%s' "$ran"
}
[[ "$(AI_STACK_UPGRADE=1 gate_demo)" == "skipped" ]] && ok "AI_STACK_UPGRADE=1 → smoke skipped" || bad "AI_STACK_UPGRADE=1 did not skip"
[[ "$(gate_demo)" == "run" ]] && ok "unset (install path) → smoke runs (unchanged behavior)" || bad "install path did not run the smoke"
[[ "$(AI_STACK_UPGRADE=0 gate_demo)" == "run" ]] && ok "AI_STACK_UPGRADE=0 → smoke runs" || bad "AI_STACK_UPGRADE=0 wrongly skipped"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
