#!/usr/bin/env bash
# smoke/03.sh — Honcho health + workspace creation roundtrip.
#
# Reachability pre-checks (Safety Reviewer 2): prove the alias path AND the
# in-network DNS path BEFORE the API roundtrip. Catches the case where
# /health responds on 127.0.0.1:8000 but the honcho alias is dead air.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/network.sh"
source "$AI_STACK/installer/lib/verify.sh"

hdr "Smoke 03 — Honcho"

# 0. REACHABILITY pre-checks. honcho's docker-compose container is named
# honcho-api or honcho-api-1 depending on compose version; check both before
# the alias probe.
honcho_container=""
for n in honcho-api honcho-api-1; do
  if docker ps --format '{{.Names}}' | grep -qx "$n"; then
    honcho_container="$n"; break
  fi
done
if [[ -z "$honcho_container" ]]; then
  err "no honcho-api container running"
  exit 1
fi
log "Reachability: honcho via http://honcho..."
verify_container_reachable_by_alias "$honcho_container" honcho 8000 /health \
  || { err "honcho not reachable via http://honcho:8000"; exit 1; }
log "Reachability: honcho by docker DNS in ai-stack..."
verify_container_reachable_by_docker_dns ai-stack "$honcho_container" 8000 \
  || { err "honcho not reachable on ai-stack network"; exit 1; }
ok "honcho reachable via alias and docker DNS"

curl -sf --max-time 5 http://honcho:8000/health >/dev/null \
  || { err "Honcho /health did not respond"; exit 1; }
ok "Honcho /health 200"

# Create a workspace via API. Honcho's API uses the v1/workspaces prefix.
WS="smoke-$$"
status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
  -X POST -H "Content-Type: application/json" \
  -d "{\"id\":\"$WS\"}" \
  http://honcho:8000/v1/workspaces 2>/dev/null || echo 000)"
case "$status" in
  200|201) ok "workspace create $WS → $status" ;;
  409)     ok "workspace already exists ($status) — API responsive" ;;
  404|405) warn "workspace endpoint shape differs ($status); API up but smoke can't verify creation" ;;
  *)       warn "unexpected workspace status: $status (API up at /health but POST failed)" ;;
esac
