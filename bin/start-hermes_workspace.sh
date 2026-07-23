#!/usr/bin/env bash
# start-hermes_workspace.sh — compose-based.
# Networking: if upstream compose joins the ai-stack network, the `workspace`
# alias (127.0.10.10:80 → :3000) becomes live. Otherwise this is informational.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/network.sh"
aliases_load
WS="$AI_STACK/hermes-workspace"
if [[ ! -f "$WS/docker-compose.yml" ]]; then
  note "hermes-workspace upstream not present — skipping start."
  note "Configure manually after Phase 05; alias 'workspace' (${ALIAS_IP[workspace]:-127.0.10.10}:80 → :${ALIAS_CONTAINER_PORT[workspace]:-3000}) is reserved."
  exit 0
fi

# Networking precondition: ai-stack network must exist (run Phase 00·N).
network_ensure_ai_stack || {
  err "ai-stack docker network missing. Run:  bash mayssam-ai-stack.sh install 00n"
  exit 1
}

case "${1:-}" in
  --recreate)  (cd "$WS" && docker compose down && docker compose up -d) ;;
  *)           (cd "$WS" && docker compose up -d) ;;
esac
ok "hermes_workspace compose up"
