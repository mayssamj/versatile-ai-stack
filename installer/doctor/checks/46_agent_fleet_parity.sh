# Agent fleet parity — the content that is SUPPOSED to be identical across the 3 frameworks
# (hermes / pi / claude-code) actually is. Wraps installer/lib/check_fleet_parity.sh so a LIVE
# install (not just a pre-commit lint) catches fleet drift. Asserts:
#   - the 6 shared skills are byte-identical ×3
#   - the shared Ethos couplet is present in all 27 souls
#   - the Tier-1 universal discipline block (10 bullets) is byte-exact in all 27 souls
#   - each role's persona body is identical across its 3 framework copies
# Drift is NOT auto-fixed (which copy is canonical is a human call): re-sync by editing the
# hermes copy, then cp to pi + claude-code.
CHECKS+=(agent_fleet_parity)
CHECK_TITLE[agent_fleet_parity]="Agent fleet parity — skills + Tier-1 principles + role bodies identical across the 3 frameworks"

agent_fleet_parity_diagnose() {
  local lint="$AI_STACK/installer/lib/check_fleet_parity.sh"
  [[ -f "$lint" ]] || { echo "installer/lib/check_fleet_parity.sh missing"; return 1; }
  local out
  if out="$(bash "$lint" 2>&1)"; then
    printf '%s\n' "$out" | tail -1 | sed 's/^/  /'
    return 0
  fi
  printf '%s\n' "$out" | grep -E '✗|DRIFT' | sed 's/^/  /'
  echo "  Fix: edit the hermes copy, then cp to pi + claude-code (skills + soul bodies are byte-identical ×3)."
  return 1
}
