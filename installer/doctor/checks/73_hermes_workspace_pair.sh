#!/usr/bin/env bash
# 73 — Hermes Workspace ↔ agent netns pair intact, with SAFE AUTO-HEAL.
#
# WHY (v0.18.0 loopback+netns, §24 SRE review): the workspace runs on hermes-agent
# v0.18.0 whose dashboard fail-closes off-loopback, so Phase 05 binds the dashboard
# to 127.0.0.1 and puts the WORKSPACE in the agent's network namespace
# (network_mode: service:hermes-agent). That netns coupling has ONE new fragility:
# on a host reboot / OrbStack VM restart, Docker's per-container restart engine has
# no cross-container ordering guarantee, so the workspace (the netns CHILD) can try
# to start before the agent's netns exists ("cannot join network namespace of a non
# running container") and stay down. `restart: unless-stopped` MAY retry, but that
# is Docker-internal + unverified — so this check makes the recovery deterministic.
#
# SIGNATURE it heals: the agent is RUNNING but the workspace is NOT (exited/dead/
# created) — the parent-up-child-down split unique to the netns coupling. A FULL
# stop (both down) is left to the operator / check 53 (that's stop-intent, not a
# split). The heal is idempotent `docker compose up -d` (compose starts the agent
# first via depends_on, then the child in its netns) — non-destructive, no volume
# touch. AUTOHEAL=1: you asked this class to self-resolve and the heal is safe.

CHECKS+=(hermes_workspace_pair)
CHECK_TITLE[hermes_workspace_pair]="Hermes Workspace ↔ agent netns pair intact + self-heal"
AUTOHEAL[hermes_workspace_pair]=1

_HWP_WS_DIR="$AI_STACK/hermes-workspace"

# _hwp_status <service-suffix> — status of the compose container whose name ends in
# -<suffix>-<n> (hermes-agent | hermes-workspace); "" if none. Name-pattern match so
# it works regardless of the compose project name.
_hwp_status() {
  local suffix="$1" name
  name="$(docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E -- "-${suffix}-[0-9]+$" | head -1)"
  [[ -n "$name" ]] || { printf ''; return 0; }
  docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null || printf ''
}

hermes_workspace_pair_diagnose() {
  # Fail-open: the workspace UI is optional (see Phase 05) — skip if not configured.
  [[ -f "$_HWP_WS_DIR/docker-compose.yml" ]] || { echo "hermes-workspace not installed (skip)"; return 0; }
  # Only relevant under the netns model (network_mode present in the override). An
  # older bridge-model install has no netns split to heal here.
  grep -qE '^[[:space:]]*network_mode:[[:space:]]*"?service:hermes-agent"?' \
    "$_HWP_WS_DIR/docker-compose.override.yml" 2>/dev/null \
    || { echo "hermes-workspace not on the netns model (skip)"; return 0; }

  local ast wst; ast="$(_hwp_status hermes-agent)"; wst="$(_hwp_status hermes-workspace)"
  # Agent down (or both down) → not our split; the general census (check 53) / a
  # normal `start` owns that. We only act on parent-up / child-down.
  [[ "$ast" == "running" ]] || { echo "hermes-agent not running (status='${ast:-gone}') — not the netns split; skip"; return 0; }
  if [[ "$wst" != "running" ]]; then
    echo "NETNS SPLIT: hermes-agent is running but hermes-workspace is '${wst:-gone}'."
    echo "The workspace shares the agent's netns; a reboot can start the child before the"
    echo "parent's netns exists. Heal = 'docker compose up -d' in $_HWP_WS_DIR (idempotent)."
    return 1
  fi
  return 0
}

hermes_workspace_pair_fix() {
  # (1) worktree guard — never operate the live stack from a git worktree (a bind-mount
  #     path that vanishes on worktree removal → the exact class this repo hardened).
  worktree_guard_soft "hermes-workspace netns pair recovery" || return 1
  # (2) fail-open if the workspace isn't configured.
  [[ -f "$_HWP_WS_DIR/docker-compose.yml" ]] || { warn "hermes-workspace/docker-compose.yml missing — cannot heal"; return 1; }
  # (3) NON-destructive, idempotent: compose brings the agent up first (depends_on) then
  #     re-joins the workspace to its netns. Never rm, never wipe a volume.
  log "Healing hermes-workspace netns split: 'docker compose up -d' (idempotent)…"
  if ! ( cd "$_HWP_WS_DIR" && docker compose up -d ) >/dev/null 2>&1; then
    err "docker compose up -d failed in $_HWP_WS_DIR — inspect: docker compose -f $_HWP_WS_DIR/docker-compose.yml logs"
    return 1
  fi
  # (4) bounded wait for the workspace to reach running.
  local i st
  for i in $(seq 1 30); do
    st="$(_hwp_status hermes-workspace)"
    [[ "$st" == "running" ]] && { ok "hermes-workspace re-joined the agent netns (running) — UI restored."; return 0; }
    sleep 1
  done
  err "hermes-workspace still not running after 30s (status='${st:-gone}') — inspect: docker compose -f $_HWP_WS_DIR/docker-compose.yml logs hermes-workspace"
  return 1
}
