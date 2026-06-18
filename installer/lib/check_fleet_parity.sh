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

SKILLS=(team-protocol verification-gates hypothesis-debugging reversible-changes tdd brainstorming memory-management)
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
souls=( agent-profiles/hermes/profiles/*/SOUL.md agent-profiles/pi/agents/*/SYSTEM.md agent-profiles/claude-code/.claude/agents/*.md fleet/manager.md )
have=0; total=0
for f in "${souls[@]}"; do
  total=$((total+1))
  if grep -qF "$COUPLET_MARKER" "$f"; then have=$((have+1)); else echo "  ✗ couplet missing: $f"; fail=1; fi
done
echo "  couplet present in $have/$total souls"

echo "== Tier-1 universal discipline block — all 10 bullets byte-exact in every soul =="
# Canonical Tier-1 = the universal bullets in the manager soul; every role must carry them verbatim.
t1="$(awk '/Universal discipline \(every role carries these\)/{p=1;next} /Operator-specific/{p=0} p&&/^- /{print}' \
  agent-profiles/hermes/profiles/manager/SOUL.md)"
tn="$(printf '%s\n' "$t1" | grep -c '^- ' || true)"
if (( tn < 10 )); then echo "  ✗ could not extract Tier-1 from manager ($tn bullets)"; fail=1; fi
while IFS= read -r bl; do
  [[ -n "$bl" ]] || continue
  for f in "${souls[@]}"; do grep -Fxq -- "$bl" "$f" || { echo "  ✗ Tier-1 bullet missing/changed in $f: ${bl:0:50}…"; fail=1; }; done
done <<< "$t1"
echo "  Tier-1: $tn bullets checked × ${#souls[@]} souls"

echo "== Each role's persona body identical across its 3 framework copies =="
# The 8 specialists are uniform (agent-profiles/<platform>/.../<role>). The MANAGER is the MAIN
# agent — a CLAUDE.md @-import, NOT a subagent — so its claude-code body lives at top-level
# fleet/manager.md (D2), not under .claude/agents/; it's checked by name in check_manager_body below.
ROLES8=(techlead frontend-engineer backend-engineer ml-engineer qa-test-engineer reviewing-engineer sre-engineer incident-manager)
extract_body() {  # strip cc frontmatter + framework tail; print the role H1..(before tail), trailing ---/blank trimmed
  awk '
    NR==1 && /^---$/ {fm=1; next}
    fm && /^---$/ {fm=0; next}
    fm {next}
    /^## (Profile bootstrap|Setup \(Pi\)|Platform note)/ {exit}
    !started && /^# / && index($0,".md")==0 {started=1}
    started {print}
  ' "$1" | awk '{a[NR]=$0} END{last=NR; while(last>0 && (a[last]=="" || a[last]=="---")) last--; for(i=1;i<=last;i++) print a[i]}'
}
check_manager_body() {  # manager = MAIN agent; its claude-code body is fleet/manager.md, not .claude/agents/manager.md
  local h="agent-profiles/hermes/profiles/manager/SOUL.md"
  local p="agent-profiles/pi/agents/manager/SYSTEM.md"
  local c="fleet/manager.md" f
  for f in "$h" "$p" "$c"; do [[ -f "$f" ]] || { echo "  ✗ manager: missing $f"; fail=1; return; }; done
  if diff -q <(extract_body "$h") <(extract_body "$p") >/dev/null && diff -q <(extract_body "$h") <(extract_body "$c") >/dev/null; then
    echo "  ✓ manager body identical ×3 (hermes == pi == fleet/manager.md)"
  else
    echo "  ✗ manager body DRIFT: hermes-vs-pi $(diff -q <(extract_body "$h") <(extract_body "$p") >/dev/null && echo ok || echo DIFF); hermes-vs-fleet $(diff -q <(extract_body "$h") <(extract_body "$c") >/dev/null && echo ok || echo DIFF)"; fail=1
  fi
}
for r in "${ROLES8[@]}"; do
  h="agent-profiles/hermes/profiles/$r/SOUL.md"; p="agent-profiles/pi/agents/$r/SYSTEM.md"; c="agent-profiles/claude-code/.claude/agents/$r.md"
  if diff -q <(extract_body "$h") <(extract_body "$p") >/dev/null && diff -q <(extract_body "$h") <(extract_body "$c") >/dev/null; then
    echo "  ✓ $r body identical ×3"
  else
    echo "  ✗ $r body DRIFT: hermes-vs-pi $(diff -q <(extract_body "$h") <(extract_body "$p") >/dev/null && echo ok || echo DIFF); hermes-vs-claude $(diff -q <(extract_body "$h") <(extract_body "$c") >/dev/null && echo ok || echo DIFF)"; fail=1
  fi
done
check_manager_body

if (( fail )); then
  echo "FLEET PARITY: ✗ DRIFT DETECTED — re-sync the divergent copies (edit hermes, then cp to pi + claude-code; the claude-code manager copy is fleet/manager.md)." >&2
  exit 1
fi
echo "FLEET PARITY: ✓ all skills identical ×3 and all souls carry the Ethos couplet."
