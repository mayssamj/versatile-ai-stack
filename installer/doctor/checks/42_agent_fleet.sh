# Agent fleet (Phase 04h) — the 9-role software-engineering team installed across
# claude-code (~/.claude, USER-GLOBAL) and pi (pi-v1:/sandbox/agents/<role>/SYSTEM.md).
# (Hermes's side of the fleet is covered by check 30 hermes_routing.)
#
# OPT-IN: 04h is not part of a minimal install, so this check GREEN-SKIPS when no
# install marker is present on either surface. When 04h HAS run, it asserts the
# full roster of agents + skills landed and flags un-applied updates (*.ai-stack-new
# sidecars 04h writes instead of clobbering a user-edited file).
CHECKS+=(agent_fleet)
CHECK_TITLE[agent_fleet]="Agent fleet present (claude-code ~/.claude + pi-v1 personas, Phase 04h)"

_agent_fleet_osh() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""; fi
}

agent_fleet_diagnose() {
  local src="$AI_STACK/agent-profiles/claude-code/.claude"
  [[ -d "$src/agents" ]] || { echo "(agent-profiles source absent) [skip]"; return 0; }
  local roles skills r sk problems=0 ran=0
  roles="$(cd "$src/agents" && ls -1 ./*.md 2>/dev/null | sed 's#.*/##; s#\.md$##')"
  skills="$(cd "$src/skills" 2>/dev/null && ls -1d ./*/ 2>/dev/null | sed 's#./##; s#/##')"

  # --- claude-code surface (~/.claude, global). Marker: manager.md present. ---
  if [[ -f "$HOME/.claude/agents/manager.md" ]]; then
    ran=1
    while IFS= read -r r; do
      [[ -z "$r" ]] && continue
      [[ -f "$HOME/.claude/agents/$r.md" ]] || { echo "missing ~/.claude/agents/$r.md"; problems=1; }
    done <<<"$roles"
    while IFS= read -r sk; do
      [[ -z "$sk" ]] && continue
      [[ -f "$HOME/.claude/skills/$sk/SKILL.md" ]] || { echo "missing ~/.claude/skills/$sk/SKILL.md"; problems=1; }
    done <<<"$skills"
    # Nullglob-safe existence test (a bare `ls <unmatched-glob>` under nullglob
    # lists the cwd and returns 0 — a false positive). Iterate + test each path.
    local s
    for s in "$HOME"/.claude/agents/*.ai-stack-new "$HOME"/.claude/skills/*/*.ai-stack-new; do
      if [[ -e "$s" ]]; then
        echo "un-applied agent updates present (*.ai-stack-new under ~/.claude — review/merge then delete)"; problems=1; break
      fi
    done
  fi

  # --- pi surface (pi-v1 sandbox). Marker: /sandbox/agents/manager/SYSTEM.md. ---
  local osh; osh="$(_agent_fleet_osh)"
  if [[ -n "$osh" ]] && "$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
       | awk 'NR>1 && $1=="pi-v1" && $NF=="Ready"{ok=1} END{exit !ok}'; then
    if "$osh" sandbox exec -n pi-v1 --no-tty -- /bin/sh -c 'test -f /sandbox/agents/manager/SYSTEM.md' >/dev/null 2>&1; then
      ran=1
      local got
      got="$("$osh" sandbox exec -n pi-v1 --no-tty -- /bin/sh -c 'ls -1 /sandbox/agents 2>/dev/null' 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g')"
      while IFS= read -r r; do
        [[ -z "$r" ]] && continue
        grep -qxF "$r" <<<"$got" || { echo "missing pi persona /sandbox/agents/$r/SYSTEM.md"; problems=1; }
      done <<<"$roles"
    fi
  fi

  if (( ran == 0 )); then
    echo "(Phase 04h 'agent_fleet' not run — opt-in) [skip]"
    return 0
  fi
  if (( problems )); then return 1; fi
  echo "fleet present: $(grep -c . <<<"$roles") agents + $(grep -c . <<<"$skills") skills (claude-code/pi surfaces that ran)"
  return 0
}

agent_fleet_fix() {
  warn "Re-install the agent fleet across platforms (idempotent, non-clobbering):"
  warn "    bash $AI_STACK/install.sh install agent_fleet"
  return 1
}
