#!/usr/bin/env bash
# stop-hermes_workspace.sh — bring the Hermes Workspace compose stack down.
# Symmetric counterpart to start-hermes_workspace.sh; backs the `Stop:` line
# cmd_start advertises. Idempotent: re-running on a stopped/absent stack is harmless.
set -Eeuo pipefail

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

WS="$AI_STACK/hermes-workspace"
[[ -f "$WS/docker-compose.yml" ]] || {
  ok "hermes-workspace not installed; nothing to stop."
  exit 0
}

cd "$WS" || { err "cannot cd to $WS"; exit 1; }
docker compose down
ok "hermes_workspace compose down"
