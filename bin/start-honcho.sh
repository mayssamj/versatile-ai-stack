#!/usr/bin/env bash
# start-honcho.sh — compose-based service.
# --recreate brings the whole stack down + up; otherwise just `compose up -d`.
#
# Networking (post-refactor): honcho-api + deriver join the external ai-stack
# bridge network via docker-compose.override.yml (written by Phase 03). The
# api binds to host alias `honcho` (127.0.10.6:80 → :8000). Cross-stack calls
# to LiteLLM use fully-qualified DNS `litellm.ai-stack:4000` (per D28) because
# honcho-api is on multiple networks.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/network.sh"
aliases_load
HONCHO_DIR="$AI_STACK/honcho"
[[ -f "$HONCHO_DIR/docker-compose.yml" ]] || { err "honcho/docker-compose.yml missing — run phase 03 first"; exit 1; }
[[ -f "$HONCHO_DIR/docker-compose.override.yml" ]] || { err "honcho/docker-compose.override.yml missing — run phase 03 first"; exit 1; }

# Networking precondition: ai-stack network must exist (run Phase 00·N).
network_ensure_ai_stack || {
  err "ai-stack docker network missing. Run:  bash vz-ai-stack.sh install 00n"
  exit 1
}

case "${1:-}" in
  --recreate)
    (cd "$HONCHO_DIR" && docker compose down)
    (cd "$HONCHO_DIR" && docker compose up -d)
    ;;
  *)
    (cd "$HONCHO_DIR" && docker compose up -d)
    ;;
esac
ok "honcho compose up (api at http://honcho:8000 → ${ALIAS_IP[honcho]}:80)"
