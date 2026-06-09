#!/usr/bin/env bash
# check_fleet_parity.sh — lint (NOT a doctor check) asserting the agent-profiles/
# fleet content that is SUPPOSED to be identical across the 3 platforms actually is:
#   1. the 6 shared skills are byte-identical across hermes / pi / claude-code
#   2. all 9 roles × 3 fleets carry the shared Ethos couplet
# The 6 skills are physically triplicated with no generator; this guard makes that
# invariant enforceable (run in CI / before committing skill or soul edits).
#
# Usage:  bash installer/lib/check_fleet_parity.sh    (exit 0 = parity holds, 1 = drift)
set -Eeuo pipefail
if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
  echo "check_fleet_parity: needs bash 5+" >&2; exit 2
fi
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$AI_STACK"

SKILLS=(team-protocol verification-gates hypothesis-debugging reversible-changes tdd brainstorming)
HERMES_SKILLS="agent-profiles/hermes/skills"
PI_SKILLS="agent-profiles/pi/skills"
CLAUDE_SKILLS="agent-profiles/claude-code/.claude/skills"
COUPLET_MARKER="earn every pushback with evidence"

fail=0

echo "== Skill byte-identity (hermes == pi == claude-code) =="
for s in "${SKILLS[@]}"; do
  h="$HERMES_SKILLS/$s/SKILL.md"; p="$PI_SKILLS/$s/SKILL.md"; c="$CLAUDE_SKILLS/$s/SKILL.md"
  miss=0
  for f in "$h" "$p" "$c"; do [[ -f "$f" ]] || { echo "  ✗ $s: missing $f"; miss=1; fail=1; }; done
  (( miss )) && continue
  if cmp -s "$h" "$p" && cmp -s "$h" "$c"; then
    echo "  ✓ $s identical ×3"
  else
    echo "  ✗ $s DRIFT: hermes vs pi $(cmp -s "$h" "$p" && echo ok || echo DIFF); hermes vs claude $(cmp -s "$h" "$c" && echo ok || echo DIFF)"
    fail=1
  fi
done

echo "== Shared Ethos couplet present in all 27 souls =="
souls=( agent-profiles/hermes/profiles/*/SOUL.md agent-profiles/pi/agents/*/SYSTEM.md agent-profiles/claude-code/.claude/agents/*.md )
have=0; total=0
for f in "${souls[@]}"; do
  total=$((total+1))
  if grep -qF "$COUPLET_MARKER" "$f"; then have=$((have+1)); else echo "  ✗ couplet missing: $f"; fail=1; fi
done
echo "  couplet present in $have/$total souls"

if (( fail )); then
  echo "FLEET PARITY: ✗ DRIFT DETECTED — re-sync the divergent copies (edit hermes, then cp to pi + claude-code)." >&2
  exit 1
fi
echo "FLEET PARITY: ✓ all skills identical ×3 and all souls carry the Ethos couplet."
