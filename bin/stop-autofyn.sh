#!/usr/bin/env bash
# stop-autofyn.sh — bring the autofyn compose stack down.
# Symmetric counterpart to start-autofyn.sh; backs the `Stop:` line cmd_start
# advertises. Idempotent: re-running on a stopped/absent stack is harmless.
set -Eeuo pipefail

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

AF="$AI_STACK/autofyn"
[[ -f "$AF/docker-compose.yml" ]] || {
  ok "autofyn not installed; nothing to stop."
  exit 0
}

cd "$AF" || { err "cannot cd to $AF"; exit 1; }
docker compose down
ok "autofyn compose down"
