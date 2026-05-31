#!/usr/bin/env bash
# start-falkordb.sh — graph DB + browser UI on the ai-stack network.
#
# Two protocols on two aliases (same container):
#   alias `falkordb`    127.0.10.7:6379 → :6379  (Redis protocol; native port)
#   alias `falkordb-ui` 127.0.10.8:80   → :3000  (browser UI; HTTP)
# The old 127.0.0.1:3010 remap is DROPPED — under alias scheme there is no
# port collision (browser UI lives at its own .8 IP).
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
NAME=falkordb; PHASE=02; IMAGE=falkordb/falkordb:latest
RECREATE_FLAG="${1:-}"

# Networking precondition: ai-stack network must exist (run Phase 00·N).
network_ensure_ai_stack || {
  err "ai-stack docker network missing. Run:  bash install.sh install 00n"
  exit 1
}

recreate_guard "$NAME" "$RECREATE_FLAG" || exit 1
ensure_image "$IMAGE"
mkdir -p "$AI_STACK/data/falkor"
docker run -d \
  --name "$NAME" \
  --label "ai-stack.managed=true" \
  --label "ai-stack.phase=$PHASE" \
  --label "ai-stack.partial=true" \
  --restart unless-stopped \
  --network ai-stack \
  --add-host=ollama:host-gateway \
  -p "${ALIAS_IP[falkordb]}":"${ALIAS_HOST_PORT[falkordb]}":"${ALIAS_CONTAINER_PORT[falkordb]}" \
  -p "${ALIAS_IP[falkordb-ui]}":"${ALIAS_HOST_PORT[falkordb-ui]}":"${ALIAS_CONTAINER_PORT[falkordb-ui]}" \
  -v "$AI_STACK/data/falkor:/data" \
  "$IMAGE" \
  >/dev/null
ok "started container: $NAME (Redis falkordb:6379, browser http://falkordb-ui:3000)"
record "start-falkordb: pid=$$"
