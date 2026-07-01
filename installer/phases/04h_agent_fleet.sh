#!/usr/bin/env bash
# Phase 04·H — AI software-engineering agent fleet, across THREE platforms.
#
# Source of truth: agent-profiles/{claude-code,pi,hermes}/. This phase wires the
# same 9-role team into each platform's native shape:
#   - Hermes  : rebuilds hermes-fleet-v1 to the 9 roles by running Phase 04f
#               directly (04f reads the roster from installer/models.yml).
#   - Pi      : uploads the 9 SYSTEM.md (+ shared skills) into the pi-v1 sandbox
#               (phase-1: switchable per-project personas; `bin/pi-as <role>`).
#   - Claude  : copies the 9 agents + 6 skills into ~/.claude/{agents,skills}/
#               (USER-GLOBAL — active in every Claude Code session on this Mac).
# Finally widens HERMES_LITELLM_KEY + PI_LITELLM_KEY to the full models.yml model
# set so the subscription (claude-*-sub-*) routes are reachable (mirrors what
# `vz-ai-stack.sh model sync` does, but inline + lock-free — phases run UNDER the
# install lock, and `model sync` would re-acquire it and deadlock).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

PHASE=04h
PI_SANDBOX=pi-v1
PROFILES="$AI_STACK/agent-profiles"
MODELS_YML="$AI_STACK/installer/models.yml"

# Role <-> file map. claude-code/pi use the hyphenated role; hermes uses the
# hermes_<snake> profile (handled inside 04f).
ROLES=(manager techlead frontend-engineer backend-engineer ml-engineer \
       qa-test-engineer reviewing-engineer sre-engineer incident-manager)
# Shipped shared skills (the 6 that actually exist as SKILL.md).
SKILLS=(team-protocol tdd hypothesis-debugging verification-gates reversible-changes brainstorming memory-management)

CLAUDE_DIR="$HOME/.claude"
CLAUDE_AGENTS_SRC="$PROFILES/claude-code/.claude/agents"
CLAUDE_SKILLS_SRC="$PROFILES/claude-code/.claude/skills"
PI_AGENTS_SRC="$PROFILES/pi/agents"
PI_SKILLS_SRC="$PROFILES/pi/skills"

resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""; fi
}
OSH="$(resolve_openshell)"

sandbox_ready() {
  [[ -n "$OSH" ]] || return 1
  "$OSH" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk -v n="$1" 'NR>1 && $1==n && $NF=="Ready"{ok=1} END{exit !ok}'
}

precheck() {
  # Manager is the MAIN agent (CLAUDE.md absolute @-import of the repo canonical, D2), not a subagent.
  grep -qF "@$AI_STACK/fleet/manager.md" "$CLAUDE_DIR/CLAUDE.md" 2>/dev/null && [[ -f "$AI_STACK/fleet/manager.md" ]] || return 1
  [[ -f "$CLAUDE_DIR/agents/techlead.md" ]] || return 1
  sandbox_ready "$PI_SANDBOX" || return 1
  "$OSH" sandbox exec -n "$PI_SANDBOX" --no-tty -- /bin/sh -c \
    'test -f /sandbox/agents/manager/SYSTEM.md' >/dev/null 2>&1 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (agent fleet on claude-code + pi + hermes)"
  exit 0
fi

hdr "Phase 04·H — AI agent fleet (claude-code + pi + hermes)"

# --- 1) Hermes: rebuild the fleet to the 9 roles via Phase 04f directly ------
# Run the SCRIPT (not `vz-ai-stack.sh install 04f`) so we don't re-acquire the lock.
# 04f is idempotent (skips if already on the current roster).
log "Hermes: (re)building hermes-fleet-v1 to the 9 roles via Phase 04f..."
if bash "$AI_STACK/installer/phases/04f_hermes_fleet.sh"; then
  ok "Hermes fleet rebuilt (or already current)"
else
  warn "Phase 04f returned non-zero — Hermes fleet may be incomplete (check 'vz-ai-stack.sh install 04f')"
fi

# --- 2) Claude Code: copy agents + skills into ~/.claude (USER-GLOBAL) --------
# Idempotent + NON-CLOBBERING: identical files are a no-op; a file that exists
# and DIFFERS is left untouched and a <name>.ai-stack-new is written beside it.
CLAUDE_WRITTEN=()
install_file() {  # <src> <dst>
  local src="$1" dst="$2"
  [[ -f "$src" ]] || { warn "missing source: $src"; return; }
  mkdir -p "$(dirname "$dst")"
  if [[ ! -f "$dst" ]]; then
    cp "$src" "$dst"; CLAUDE_WRITTEN+=("$dst"); ok "wrote $dst"
  elif cmp -s "$src" "$dst"; then
    : # identical — no-op
  else
    cp "$src" "$dst.ai-stack-new"
    warn "$dst exists and differs — wrote $dst.ai-stack-new (review/merge; not overwritten)"
  fi
}
# The manager is the MAIN agent: a Claude Code subagent CANNOT dispatch other subagents
# (Task is main-agent-only), so "single entrance orchestrates the 8" requires the manager to be
# the main session. It installs as a managed CLAUDE.md @-import (NOT a peer subagent); the other
# 8 install as subagents. CLAUDE.md is auto-loaded GUIDANCE (not a system-prompt override).
install_main_agent() {  # manager persona: direct ABSOLUTE @-import of the repo canonical (D2) + clobber-safe block
  local canonical="$AI_STACK/fleet/manager.md" claudemd="$CLAUDE_DIR/CLAUDE.md"
  local begin="<!-- BEGIN ai-stack fleet manager (managed) -->" end="<!-- END ai-stack fleet manager (managed) -->"
  local import_line="@$canonical" legacy="$CLAUDE_DIR/fleet/manager.md"
  [[ -f "$canonical" ]] || { warn "missing manager canonical $canonical (run from a full ai-stack checkout)"; return; }
  # D2: the canonical IS the repo file (frontmatter-free, version-controlled). We do NOT copy or strip —
  # CLAUDE.md @-imports it by ABSOLUTE path (mirrors the SOUL.md import), so an edit to fleet/manager.md
  # is live in every session with no reinstall. NEVER clobber the user's own CLAUDE.md content.
  if [[ ! -f "$claudemd" ]]; then
    printf '%s\n%s\n%s\n' "$begin" "$import_line" "$end" > "$claudemd"
    ok "created $claudemd importing the fleet manager ($import_line)"
  elif grep -qF "$import_line" "$claudemd"; then
    note "$claudemd already imports the fleet manager by absolute path (current)"
  elif grep -qF "$begin" "$claudemd"; then
    # D1->D2 migration: a managed block exists but points at the old relative @fleet/manager.md.
    # Rewrite that import line in place to the absolute path (clobber-safe: temp + mv; user content kept).
    # Escape sed-replacement metachars (\, &, and the | delimiter) so an unusual $AI_STACK path can't corrupt the line.
    local tmp repl; tmp="$(mktemp)"; repl=${import_line//\\/\\\\}; repl=${repl//&/\\&}; repl=${repl//|/\\|}
    sed "s|^@fleet/manager\.md\$|$repl|" "$claudemd" > "$tmp" && mv "$tmp" "$claudemd"
    if grep -qF "$import_line" "$claudemd"; then
      ok "upgraded the managed block: @fleet/manager.md -> $import_line (D1->D2)"
      # Remove the now-orphaned D1 generated copy ONLY on a confirmed migration (never a foreign file).
      [[ -f "$legacy" ]] && rm -f "$legacy" && note "removed orphaned D1 copy $legacy (now imported from $canonical)"
    else
      warn "managed block present but no relative @fleet/manager.md line found to upgrade — inspect $claudemd"
    fi
  else
    printf '\n%s\n%s\n%s\n' "$begin" "$import_line" "$end" >> "$claudemd"
    ok "appended the managed manager import to your existing $claudemd (your content untouched)"
  fi
  [[ -f "$CLAUDE_DIR/agents/manager.md" ]] && warn "superseded: $CLAUDE_DIR/agents/manager.md (manager is the MAIN agent) — you may remove it"
  return 0
}
log "Claude Code: installing 8 specialist subagents + ${#SKILLS[@]} skills + the manager (main agent) into $CLAUDE_DIR (GLOBAL)..."
mkdir -p "$CLAUDE_DIR/agents" "$CLAUDE_DIR/skills"
for r in "${ROLES[@]}"; do [[ "$r" == manager ]] && continue; install_file "$CLAUDE_AGENTS_SRC/$r.md" "$CLAUDE_DIR/agents/$r.md"; done
for sk in "${SKILLS[@]}"; do install_file "$CLAUDE_SKILLS_SRC/$sk/SKILL.md" "$CLAUDE_DIR/skills/$sk/SKILL.md"; done
install_main_agent
ok "Claude Code: ${#CLAUDE_WRITTEN[@]} subagent/skill file(s) newly written; manager installed as the main-agent persona (existing user edits preserved)"
note "GLOBAL — active in every Claude Code session on this Mac. Remove with: rm the 8 ~/.claude/agents/*.md, the skill dirs, and the managed block in ~/.claude/CLAUDE.md (the manager is @-imported from the repo, not copied)."

# --- 3) Pi: upload the 9 SYSTEM.md (+ skills) into the pi-v1 sandbox ----------
if sandbox_ready "$PI_SANDBOX"; then
  log "Pi: uploading 9 personas + ${#SKILLS[@]} skills into $PI_SANDBOX:/sandbox/agents/..."
  for r in "${ROLES[@]}"; do
    "$OSH" sandbox exec -n "$PI_SANDBOX" --no-tty -- /bin/sh -c "mkdir -p /sandbox/agents/$r" >/dev/null 2>&1 || true
    "$OSH" sandbox upload "$PI_SANDBOX" "$PI_AGENTS_SRC/$r/SYSTEM.md" "/sandbox/agents/$r/" 2>&1 | tail -1 \
      || warn "pi upload SYSTEM.md for $r failed"
  done
  for sk in "${SKILLS[@]}"; do
    "$OSH" sandbox exec -n "$PI_SANDBOX" --no-tty -- /bin/sh -c "mkdir -p /sandbox/agents/skills/$sk" >/dev/null 2>&1 || true
    "$OSH" sandbox upload "$PI_SANDBOX" "$PI_SKILLS_SRC/$sk/SKILL.md" "/sandbox/agents/skills/$sk/" 2>&1 | tail -1 \
      || warn "pi upload skill $sk failed"
  done
  ok "Pi: personas + skills uploaded. Switch with: bin/pi-as <role>"
else
  warn "$PI_SANDBOX not Ready — skipping Pi upload (run 'vz-ai-stack.sh install 15' then re-run this phase)."
fi

# --- 4) Widen the fleet keys to the full model set (lock-free model-sync-lite) -
# Hermes + Pi reach LiteLLM with a scoped virtual key whose allowlist must
# include the subscription (claude-*-sub-*) ids, else LiteLLM 403s. The canonical
# widener is `vz-ai-stack.sh model sync`, but it re-acquires the install lock (we hold
# it). So widen in place via /key/update with the full models.yml model set.
widen_keys() {
  local master superset k kenv
  master="$(get_env LITELLM_MASTER_KEY '')"
  [[ -n "$master" ]] || { warn "LITELLM_MASTER_KEY absent — skip key widening (run 'vz-ai-stack.sh model sync')"; return; }
  command -v yq >/dev/null 2>&1 || { warn "yq absent — skip key widening"; return; }
  # Union the legacy aliases (local/local-heavy) with every models.yml
  # id — mirrors lib/models.sh::superset_members. The legacy `local` is the
  # availability-gated fallback, so dropping it would 403 the fallback path.
  superset="$(yq -o=json -I=0 '(["local","local-heavy"] + (.models | keys)) | unique' "$MODELS_YML" 2>/dev/null || true)"
  [[ "$superset" == \[*\] ]] || { warn "could not build model superset — skip key widening"; return; }
  for kenv in HERMES_LITELLM_KEY PI_LITELLM_KEY; do
    k="$(get_env "$kenv" '')"
    [[ -n "$k" ]] || { note "$kenv not set yet — skip (its phase mints it)"; continue; }
    # GW-2: reconcile OFF-ARGV — litellm_reconcile_key writes the scoped-key body to a 0600 temp
    # file and POSTs `--data @file` (loopback-fallback base, UNION semantics), instead of the old
    # inline `-d "{…\"key\":\"$k\"…}"` which leaked the SCOPED key into argv (ps / docker inspect /
    # /proc/PID/cmdline on this shared box — the secrets-never-in-argv rule the codebase enforces
    # everywhere else). It covers the same superset and logs its own ok/warn.
    litellm_reconcile_key "$kenv" "$superset" \
      || warn "could not widen $kenv allow-list — run 'vz-ai-stack.sh model sync' to finalize"
  done
}
log "Widening fleet key allowlists to cover the subscription models..."
widen_keys

stamp_mark "$PHASE"
record "phase 04·H complete: 9-role agent fleet on claude-code (~/.claude, global) + pi ($PI_SANDBOX) + hermes (hermes-fleet-v1); fleet keys widened to subscription models"
ok "Phase 04·H — AI agent fleet — complete"
note "Claude Code:  /agents  (lists the 9 globally)            Hermes: openshell sandbox connect hermes-fleet-v1"
note "Pi:           bin/pi-as <role>   (e.g. bin/pi-as backend-engineer)"
note "Canonical finalize (optional): vz-ai-stack.sh model sync   (re-renders every agent + re-widens keys)"
