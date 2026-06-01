#!/usr/bin/env bash
# start-openwebui.sh — Open WebUI wired to LiteLLM via Docker DNS.
# Auth OFF for personal-local use; if you ever expose this beyond localhost,
# flip WEBUI_AUTH=True.
# Networking: alias `openwebui` (127.0.10.9:80 → :8080). Internally dials
# LiteLLM at http://litellm:4000/v1 (container-to-container via Docker DNS,
# native LiteLLM port — NOT the host-side :80 alias).
set -Eeuo pipefail
if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "needs bash 5+" >&2; exit 2
fi
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/network.sh"
aliases_load
NAME=openwebui; PHASE=05; IMAGE=ghcr.io/open-webui/open-webui:main
RECREATE_FLAG="${1:-}"
load_env_strict || { err ".env malformed"; exit 1; }
KEY="$(require_env LITELLM_MASTER_KEY "")"
[[ -n "$KEY" ]] || { err "LITELLM_MASTER_KEY empty; run phase 00 first."; exit 1; }

# Networking precondition: ai-stack network must exist (run Phase 00·N).
network_ensure_ai_stack || {
  err "ai-stack docker network missing. Run:  bash install.sh install 00n"
  exit 1
}

recreate_guard "$NAME" "$RECREATE_FLAG" || exit 1
ensure_image "$IMAGE"
mkdir -p "$AI_STACK/data/openwebui"
# RAG embeddings are wired to the stack's local Ollama (nomic-embed-text, already
# pulled by Phase 01). Without RAG_EMBEDDING_ENGINE=ollama, Open WebUI blocks its
# first boot downloading sentence-transformers/all-MiniLM-L6-v2 from HuggingFace —
# which, on a cold volume after `reset --hard`, leaves the HTTP server unstarted
# (doctor alias probe gets HTTP 000, container reported unhealthy). Local + offline.
docker run -d \
  --name "$NAME" \
  --label "ai-stack.managed=true" \
  --label "ai-stack.phase=$PHASE" \
  --label "ai-stack.partial=true" \
  --restart unless-stopped \
  --network ai-stack \
  --add-host=ollama:host-gateway \
  -e OPENAI_API_BASE_URL=http://litellm:4000/v1 \
  -e OPENAI_API_KEY="$KEY" \
  -e WEBUI_AUTH=False \
  -e RAG_EMBEDDING_ENGINE=ollama \
  -e RAG_OLLAMA_BASE_URL=http://ollama:11434 \
  -e RAG_EMBEDDING_MODEL=nomic-embed-text \
  -p "${ALIAS_IP[openwebui]}":"${ALIAS_HOST_PORT[openwebui]}":"${ALIAS_CONTAINER_PORT[openwebui]}" \
  -v "$AI_STACK/data/openwebui:/app/backend/data" \
  "$IMAGE" \
  >/dev/null
ok "started container: $NAME (http://openwebui:8080 → ${ALIAS_IP[openwebui]}:80)"
record "start-openwebui: pid=$$"
