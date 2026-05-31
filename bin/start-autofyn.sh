#!/usr/bin/env bash
# start-autofyn.sh — compose-based.
# Networking: if upstream compose joins the ai-stack network, the `autofyn`
# alias (127.0.10.13:80 → :3400) becomes live. Otherwise this is informational.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/network.sh"
aliases_load
AF="$AI_STACK/autofyn"
if [[ ! -f "$AF/docker-compose.yml" ]]; then
  note "autofyn upstream not present — skipping start."
  note "Configure manually after Phase 07; alias 'autofyn' (${ALIAS_IP[autofyn]:-127.0.10.13}:80 → :${ALIAS_CONTAINER_PORT[autofyn]:-3400}) is reserved."
  exit 0
fi

# Networking precondition: ai-stack network must exist (run Phase 00·N).
network_ensure_ai_stack || {
  err "ai-stack docker network missing. Run:  bash install.sh install 00n"
  exit 1
}

case "${1:-}" in
  --recreate)  (cd "$AF" && docker compose down && docker compose up -d) ;;
  *)           (cd "$AF" && docker compose up -d) ;;
esac
ok "autofyn compose up"
