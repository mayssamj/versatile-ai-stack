# Verify-then-stamp SHAPE still present in phases 39/40/41 (source drift guard).
#
# CHANGE 2 of the 2026-07-16 incident made phases 39 (fleet_memory) / 40 (honcho_mcp) /
# 41 (falkordb_mcp) gate their `stamp_mark` on the doctor's OWN post-condition assertion
# (_mem_hermes_{docs,honcho,falkordb}_wired) instead of stamping on optimism. The §24
# council upheld the fix but flagged a residual risk: "nothing pins the no-sandbox-still-
# stamps invariant; a future tidy-up would silently destroy it." That invariant — a genuine
# no-sandbox / not-Ready fleet MUST STILL stamp (the opt-in RECORD that arms
# 04f_hermes_fleet.sh's `stamp_check 39/40/41` so a fleet built LATER still gets wired) —
# lives in the phases' else-branch and is not otherwise pinned.
#
# This is a STATIC/source check (cf. check 62 audit_drift): it asserts the verify-then-stamp
# SHAPE tokens are still present in each phase, WITHOUT running the stack or cold-starting
# anything. It intentionally checks SHAPE, not byte-identity — the three phases legitimately
# differ — so it survives benign edits while red-barring a tidy-up that removes the gate or
# the stamping else-branch. Per phase it requires:
#   1. a `if sandbox_ready …` wiring-branch gate (wire only a Ready fleet);
#   2. a `if _mem_hermes_<key>_wired …` POST-CONDITION gate (verify before stamp);
#   3. a `NOT stamping Phase` failure path (a wiring that did not land must not stamp);
#   4. a `not present or not Ready` genuine-skip else-branch (the opt-in record);
#   5. a TOP-LEVEL `stamp_mark "$PHASE"` fall-through both the verified AND the skip path reach;
#   6. ORDER: the skip-note precedes that stamp AND no `exit` short-circuits the skip path
#      before it — i.e. a genuine no-sandbox run still reaches the stamp.
#
# Companion runtime test: installer/smoke/verify-then-stamp.sh pins the CONTRACT (the real
# helpers + real stamp produce the right outcome); THIS check pins that the phases still
# IMPLEMENT it. GRACEFUL: a phase file absent → skip-clean (never red-bar). Pure file reads;
# no external calls. _fix is print-only advice → NOT FIX_CAPABLE.
CHECKS+=(verify_then_stamp_guard)
CHECK_TITLE[verify_then_stamp_guard]="Verify-then-stamp shape intact in phases 39/40/41 (no-sandbox-still-stamps drift guard)"

verify_then_stamp_guard_diagnose() {
  local pdir="$AI_STACK/installer/phases"
  # phase-file : post-condition key (39→docs, 40→honcho, 41→falkordb)
  local specs=("39_fleet_memory.sh:docs" "40_honcho_mcp.sh:honcho" "41_falkordb_mcp.sh:falkordb")
  local fails=() checked=0 spec f key file nskip nstamp nfail

  for spec in "${specs[@]}"; do
    f="${spec%%:*}"; key="${spec#*:}"; file="$pdir/$f"
    if [[ ! -f "$file" ]]; then
      echo "  ($f absent — cannot check; skip)"
      continue
    fi
    checked=$((checked + 1))

    grep -q 'if sandbox_ready ' "$file" \
      || fails+=("  $f: missing the 'if sandbox_ready …' wiring-branch gate (only a Ready fleet is wired)")
    grep -q "if _mem_hermes_${key}_wired " "$file" \
      || fails+=("  $f: missing the 'if _mem_hermes_${key}_wired …' POST-CONDITION gate — the stamp would no longer verify before recording")
    grep -q 'NOT stamping Phase' "$file" \
      || fails+=("  $f: missing the 'NOT stamping Phase' failure path — a wiring that did not land must NOT stamp")
    grep -q 'not present or not Ready' "$file" \
      || fails+=("  $f: missing the genuine-skip else-branch ('not present or not Ready') — the no-sandbox opt-in record is at risk")
    grep -qE '^stamp_mark "\$PHASE"' "$file" \
      || fails+=("  $f: missing a TOP-LEVEL 'stamp_mark \"\$PHASE\"' — the fall-through stamp both the verified AND the skip path reach")

    # ORDER + no-short-circuit: the skip-note must come before the fall-through stamp, and no
    # `exit` statement may sit between them (that would stop a genuine no-sandbox run from
    # stamping — the exact "tidy-up" the council warned about). Only run when both anchors exist.
    nskip="$(grep -nE 'not present or not Ready' "$file" | head -1 | cut -d: -f1)"
    nstamp="$(grep -nE '^stamp_mark "\$PHASE"' "$file" | head -1 | cut -d: -f1)"
    if [[ -n "$nskip" && -n "$nstamp" ]]; then
      if (( nskip >= nstamp )); then
        fails+=("  $f: the genuine-skip note (line $nskip) is not before the fall-through stamp (line $nstamp) — skip path may no longer stamp")
      elif awk -v a="$nskip" -v b="$nstamp" \
             'NR>a && NR<b && ($0 ~ /^[[:space:]]*exit([[:space:]]|$)/ || $0 ~ /;[[:space:]]*exit([[:space:]]|$)/){found=1} END{exit !found}' \
             "$file"; then
        fails+=("  $f: an 'exit' short-circuits the genuine-skip path before the stamp (between lines $nskip and $nstamp) — a no-sandbox run would no longer stamp (opt-in-survives-rebuild broken)")
      fi
    fi

    # (MUSTFIX-1, §24 council) The COMPLEMENT of the skip-path assertion above: the failure
    # path MUST short-circuit. The `NOT stamping Phase` branch must be FOLLOWED by an `exit`
    # BEFORE the genuine-skip note — otherwise a wiring that did not land falls through to the
    # top-level stamp_mark and stamps an UNWIRED fleet (the EXACT 2026-07-16 incident). The
    # string alone (asserted above) does not guarantee the exit; this pins it.
    nfail="$(grep -nE 'NOT stamping Phase' "$file" | head -1 | cut -d: -f1)"
    if [[ -n "$nfail" && -n "$nskip" ]]; then
      if (( nfail >= nskip )); then
        fails+=("  $f: the 'NOT stamping Phase' failure branch (line $nfail) is not before the genuine-skip note (line $nskip) — the verify-then-stamp shape is inverted")
      elif ! awk -v a="$nfail" -v b="$nskip" \
             'NR>a && NR<b && ($0 ~ /^[[:space:]]*exit([[:space:]]|$)/ || $0 ~ /;[[:space:]]*exit([[:space:]]|$)/){found=1} END{exit !found}' \
             "$file"; then
        fails+=("  $f: the 'NOT stamping Phase' branch (line $nfail) has no 'exit' before the skip note (line $nskip) — a wiring that did not land would fall through and STILL stamp (the exact 2026-07-16 incident)")
      fi
    fi
  done

  if (( checked == 0 )); then
    echo "  (none of phases 39/40/41 present — nothing to guard; skip)"
    return 0
  fi
  if (( ${#fails[@]} > 0 )); then
    echo "verify-then-stamp SHAPE DRIFTED in a fleet-memory phase — the stamp gate or the no-sandbox-still-stamps invariant is at risk:"
    printf '%s\n' "${fails[@]}"
    return 1
  fi
  echo "  (verify-then-stamp shape intact in all $checked fleet-memory phase(s): Ready-gate + post-condition gate + no-stamp-on-fail + genuine-skip stamp)"
  return 0
}

verify_then_stamp_guard_fix() {
  warn "A fleet-memory phase (39/40/41) lost its verify-then-stamp shape. Restore it so the phase:"
  warn "  • gates the stamp on the doctor's post-condition (if _mem_hermes_<key>_wired … ; else err+exit 1);"
  warn "  • KEEPS the 'not present or not Ready' else-branch that falls through to a TOP-LEVEL stamp_mark \"\$PHASE\""
  warn "    — that stamp is the OPT-IN RECORD 04f_hermes_fleet.sh reads (stamp_check 39/40/41) to wire a fleet built later."
  warn "  Reference the sibling phase that still has the shape, and re-run: vz-ai-stack.sh test verify-then-stamp"
  return 1
}
