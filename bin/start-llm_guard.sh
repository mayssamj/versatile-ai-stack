#!/usr/bin/env bash
# start-llm_guard.sh — second-layer prompt scanner sidecar (optional).
# Networking: alias `llm-guard` (127.0.10.12:80 → :8000). On the ai-stack
# network so LiteLLM guardrails can dial http://llm-guard:8000 directly
# from inside the LiteLLM container.
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
NAME=llm_guard; PHASE=04g; IMAGE=laiyer/llm-guard-api:latest
RECREATE_FLAG="${1:-}"
load_env_strict || { err ".env malformed"; exit 1; }
TOKEN="$(require_env LITELLM_MASTER_KEY "")"

# Networking precondition: ai-stack network must exist (run Phase 00·N).
network_ensure_ai_stack || {
  err "ai-stack docker network missing. Run:  bash vz-ai-stack.sh install 00n"
  exit 1
}

recreate_guard "$NAME" "$RECREATE_FLAG" || exit 1
ensure_image "$IMAGE"
docker run -d \
  --name "$NAME" \
  --label "ai-stack.managed=true" \
  --label "ai-stack.phase=$PHASE" \
  --label "ai-stack.partial=true" \
  --restart unless-stopped \
  --network ai-stack \
  --network-alias llm-guard \
  --add-host=ollama:host-gateway \
  -e SCAN_FAIL_FAST=true \
  -e LOG_LEVEL=INFO \
  -e AUTH_TOKEN="$TOKEN" \
  --memory=4g \
  -p "${ALIAS_IP[llm-guard]}":"${ALIAS_HOST_PORT[llm-guard]}":"${ALIAS_CONTAINER_PORT[llm-guard]}" \
  "$IMAGE" \
  >/dev/null
ok "started container: $NAME (REST http://llm-guard:8000 → ${ALIAS_IP[llm-guard]}:80)"
record "start-llm_guard: pid=$$"
