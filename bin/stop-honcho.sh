#!/usr/bin/env bash
# stop-honcho.sh — bring the Honcho compose stack down.
# Backs the `Stop:` line cmd_start advertises (honcho is a compose service whose
# container names != svc, so the generic cmd_stop fallbacks miss it).
#
# BLAST RADIUS: Honcho's compose stack also runs the Postgres that LiteLLM uses
# for its Prisma virtual-key store (honcho-database-1 on host.docker.internal:5432).
# Stopping honcho therefore takes LiteLLM's key store offline. We warn (consistent
# with the ollama/openshell stop warnings) but proceed. Idempotent.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

HONCHO_DIR="$AI_STACK/honcho"
[[ -f "$HONCHO_DIR/docker-compose.yml" ]] || {
  ok "honcho not installed; nothing to stop."
  exit 0
}

warn "Honcho's stack also hosts the Postgres LiteLLM depends on (virtual-key store)."
warn "Stopping honcho takes LiteLLM's key store offline — restart with 'vz-ai-stack.sh start honcho'."

cd "$HONCHO_DIR" || { err "cannot cd to $HONCHO_DIR"; exit 1; }
# Include the override (ai-stack network wiring) so `down` matches `up`.
if [[ -f "$HONCHO_DIR/docker-compose.override.yml" ]]; then
  docker compose -f docker-compose.yml -f docker-compose.override.yml down
else
  docker compose down
fi
ok "honcho compose down"
