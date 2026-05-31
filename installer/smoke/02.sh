#!/usr/bin/env bash
# smoke/02.sh — FalkorDB + Qdrant roundtrip.
#
# Reachability pre-checks (Safety Reviewer 2): verify each alias and each
# in-network DNS path BEFORE running the protocol-level roundtrip. A failure
# here means the storage plane's network wiring is broken, not the apps.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/network.sh"
source "$AI_STACK/installer/lib/verify.sh"

hdr "Smoke 02 — storage plane"

# 0. REACHABILITY pre-checks.
log "Reachability: qdrant via http://qdrant..."
verify_container_reachable_by_alias qdrant qdrant 6333 / \
  || { err "qdrant not reachable via http://qdrant:6333"; exit 1; }
log "Reachability: qdrant by docker DNS on ai-stack..."
verify_container_reachable_by_docker_dns ai-stack qdrant 6333 \
  || { err "qdrant not reachable by docker DNS"; exit 1; }
ok "qdrant reachable via alias and docker DNS"

log "Reachability: falkordb TCP on ai-stack DNS..."
verify_container_reachable_by_docker_dns ai-stack falkordb 6379 \
  || { err "falkordb redis port not reachable in-network"; exit 1; }
ok "falkordb reachable on ai-stack DNS"

# Qdrant: create test collection, check it exists, delete.
log "Qdrant: create+list+delete test collection..."
COLL="smoke-test-$$"
curl -s -X PUT --max-time 5 \
  -H "Content-Type: application/json" \
  -d '{"vectors":{"size":4,"distance":"Cosine"}}' \
  "http://qdrant:6333/collections/$COLL" >/dev/null || { err "Qdrant create failed"; exit 1; }
curl -s --max-time 3 "http://qdrant:6333/collections" | jq -r '.result.collections[].name' \
  | grep -qxF "$COLL" || { err "Qdrant collection not listed"; exit 1; }
curl -s -X DELETE --max-time 5 "http://qdrant:6333/collections/$COLL" >/dev/null
ok "Qdrant roundtrip OK"

# FalkorDB: Redis ping via redis-cli inside the container.
log "FalkorDB: PING + GRAPH.QUERY test..."
docker exec falkordb redis-cli PING | grep -qx PONG || { err "FalkorDB PING failed"; exit 1; }
docker exec falkordb redis-cli GRAPH.QUERY smoke_test 'CREATE (n:Test {ok:true}) RETURN n' >/dev/null \
  || { err "GRAPH.QUERY failed"; exit 1; }
docker exec falkordb redis-cli GRAPH.DELETE smoke_test >/dev/null || true
ok "FalkorDB graph roundtrip OK"
