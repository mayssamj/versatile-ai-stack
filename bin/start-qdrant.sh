#!/usr/bin/env bash
# start-qdrant.sh — vector store on the ai-stack network.
# Bound to alias `qdrant` (127.0.10.5:80 → :6333 REST).
# gRPC :6334 host publish is reserved (.5:6334:6334) but out of scope here.
set -Eeuo pipefail
if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "needs bash 5+" >&2; exit 2
fi
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/network.sh"
aliases_load
NAME=qdrant; PHASE=02; IMAGE=qdrant/qdrant
RECREATE_FLAG="${1:-}"

# Networking precondition: ai-stack network must exist (run Phase 00·N).
network_ensure_ai_stack || {
  err "ai-stack docker network missing. Run:  bash vz-ai-stack.sh install 00n"
  exit 1
}

recreate_guard "$NAME" "$RECREATE_FLAG" || exit 1
ensure_image "$IMAGE"
mkdir -p "$AI_STACK/data/qdrant"
docker run -d \
  --name "$NAME" \
  --label "ai-stack.managed=true" \
  --label "ai-stack.phase=$PHASE" \
  --label "ai-stack.partial=true" \
  --restart unless-stopped \
  --network ai-stack \
  --add-host=ollama:host-gateway \
  -p "${ALIAS_IP[qdrant]}":"${ALIAS_HOST_PORT[qdrant]}":"${ALIAS_CONTAINER_PORT[qdrant]}" \
  -v "$AI_STACK/data/qdrant:/qdrant/storage" \
  "$IMAGE" \
  >/dev/null
ok "started container: $NAME (REST http://qdrant:6333 → ${ALIAS_IP[qdrant]}:80)"
record "start-qdrant: pid=$$"
