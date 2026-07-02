#!/usr/bin/env bash
# test_sim_smoke_upgrade_gate.sh — `upgrade all` must NOT fire a sim's live model
# smoke (billable/metered inference) when re-asserting an installed-but-drifted
# opt-in sim (mechanism-audit w6wxiev01 #2 + operator no-unsolicited-inference).
# up_phase_rerun runs the phase with AI_STACK_UPGRADE=1; each sim phase must gate
# its scoped-key ping + smoke_sim.py behind that flag and still reach stamp_mark.
#
# INVARIANT, not an allowlist (review w0osuue6z): DISCOVER every phase that runs a
# live `smoke_sim.py` and assert each one is gated — so a future sim phase cannot
# silently reintroduce ungated inference on `upgrade all`.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
UPG="$ROOT/installer/lib/upgrade.sh"
GUARD_RE='if \[\[ "\$\{AI_STACK_UPGRADE:-0\}" == 1 \]\]; then'
PASS=0; FAIL=0
ok(){  PASS=$((PASS+1)); echo "  ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }

echo "== up_phase_rerun exports the flag the gate keys on =="
grep -qE 'AI_STACK_UPGRADE=1 bash "\$script"' "$UPG" && ok "up_phase_rerun runs the phase with AI_STACK_UPGRADE=1" || bad "up_phase_rerun does not set AI_STACK_UPGRADE=1"

echo "== INVARIANT: EVERY phase that runs a live smoke_sim.py gates it on AI_STACK_UPGRADE before stamp_mark =="
mapfile -t SIM_PHASES < <(grep -lE '_simout=.*smoke_sim\.py' "$ROOT"/installer/phases/*.sh 2>/dev/null | sort)
(( ${#SIM_PHASES[@]} >= 3 )) && ok "discovered ${#SIM_PHASES[@]} live-smoke phases: $(printf '%s ' "${SIM_PHASES[@]##*/}")" || bad "expected >=3 live-smoke phases, found ${#SIM_PHASES[@]}"
for P in "${SIM_PHASES[@]}"; do
  b="${P##*/}"
  bash -n "$P" || { bad "$b: SYNTAX ERROR"; continue; }
  L_smoke="$(grep -nE '_simout=.*smoke_sim\.py' "$P" | head -1 | cut -d: -f1)"
  L_stamp="$(grep -n 'stamp_mark "\$PHASE"' "$P" | head -1 | cut -d: -f1)"
  [[ -n "$L_smoke" && -n "$L_stamp" ]] || { bad "$b: missing smoke/stamp (smoke=$L_smoke stamp=$L_stamp)"; continue; }
  # the nearest AI_STACK_UPGRADE if-guard ABOVE the smoke run
  L_guard="$(awk -v s="$L_smoke" 'NR<s && $0 ~ /if \[\[ "\$\{AI_STACK_UPGRADE:-0\}" == 1 \]\]; then/{l=NR} END{print l}' "$P")"
  if [[ -n "$L_guard" ]] && (( L_guard < L_smoke && L_smoke < L_stamp )); then ok "$b: smoke_sim (L$L_smoke) gated by AI_STACK_UPGRADE (L$L_guard) before stamp_mark (L$L_stamp)"
  else bad "$b: smoke_sim NOT gated by AI_STACK_UPGRADE before stamp (guard=$L_guard smoke=$L_smoke stamp=$L_stamp)"; fi
  # guard closes with `fi` before stamp_mark → stamp still reached on upgrade
  awk "NR>$L_smoke && NR<$L_stamp && /^[[:space:]]*fi([[:space:]]|\$)/{f=1} END{exit !f}" "$P" \
    && ok "$b: guard closes (fi) before stamp_mark → stamp still reached on upgrade" \
    || bad "$b: no 'fi' between the smoke and stamp_mark"
  # the operator-facing skip note (anchored on the real string, not a comment)
  grep -q 'note "upgrade re-assert:' "$P" && ok "$b: prints the operator skip-note" || bad "$b: missing 'upgrade re-assert:' skip note"
  # RUN-LOG honesty: the durable record must NOT claim '-verified smoke sim' on the skipped path
  grep -q 'live smoke SKIPPED' "$P" && ok "$b: durable record is honest on the skipped-smoke path" || bad "$b: record may over-claim verification on upgrade (no 'live smoke SKIPPED' record)"
done

echo "== Concordia embedder pre-fetch (local model load) is ALSO gated on AI_STACK_UPGRADE =="
CC="$ROOT/installer/phases/37_concordia.sh"
if [[ -f "$CC" ]]; then
  L_emb="$(grep -n 'SentenceTransformer(sys.argv' "$CC" | head -1 | cut -d: -f1)"
  L_eguard="$(awk -v s="$L_emb" 'NR<s && $0 ~ /if \[\[ "\$\{AI_STACK_UPGRADE:-0\}" == 1 \]\]; then/{l=NR} END{print l}' "$CC")"
  L_efi="$(awk -v s="$L_emb" 'NR>s && /^[[:space:]]*fi([[:space:]]|$)/{print NR; exit}' "$CC")"
  if [[ -n "$L_eguard" && -n "$L_efi" ]] && (( L_eguard < L_emb && L_emb < L_efi )); then ok "embedder pre-fetch (L$L_emb) gated by AI_STACK_UPGRADE (L$L_eguard, fi L$L_efi)"
  else bad "embedder pre-fetch NOT gated (guard=$L_eguard emb=$L_emb fi=$L_efi)"; fi
fi

echo "== metagpt (32) is intentionally NOT gated (smoke = 'bin/metagpt --help', no inference) =="
MG="$ROOT/installer/phases/32_metagpt.sh"
grep -q 'smoke_sim.py' "$MG" 2>/dev/null && bad "32_metagpt unexpectedly has a smoke_sim.py (would need gating)" || ok "32_metagpt has no live sim smoke — correctly excluded"

echo "== behavioral: the guard SEMANTICS (skip on upgrade, run on install) =="
gate_demo(){ local r="run"; [[ "${AI_STACK_UPGRADE:-0}" == 1 ]] && r="skipped"; printf '%s' "$r"; }
[[ "$(AI_STACK_UPGRADE=1 gate_demo)" == "skipped" ]] && ok "AI_STACK_UPGRADE=1 → smoke skipped" || bad "AI_STACK_UPGRADE=1 did not skip"
[[ "$(gate_demo)" == "run" ]] && ok "unset (install path) → smoke runs (unchanged)" || bad "install path did not run the smoke"
[[ "$(AI_STACK_UPGRADE=0 gate_demo)" == "run" ]] && ok "AI_STACK_UPGRADE=0 → smoke runs" || bad "AI_STACK_UPGRADE=0 wrongly skipped"

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
