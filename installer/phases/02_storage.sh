#!/usr/bin/env bash
# Phase 02 — storage plane: FalkorDB + Qdrant.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/validate.sh"

PHASE=02

precheck() {
  container_running falkordb || return 1
  container_running qdrant || return 1
  wait_http http://qdrant:6333/collections 5 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (storage plane)"
  exit 0
fi

hdr "Phase 02 — storage plane"

# --- FalkorDB ---
if container_running falkordb; then
  if container_managed falkordb; then ok "falkordb already running (managed)"
  else warn "falkordb is FOREIGN; run 'mayssam-ai-stack.sh adopt falkordb'"
  fi
else
  bash "$AI_STACK/bin/start-falkordb.sh"
fi

# --- Qdrant ---
if container_running qdrant; then
  if container_managed qdrant; then ok "qdrant already running (managed)"
  else warn "qdrant is FOREIGN; run 'mayssam-ai-stack.sh adopt qdrant'"
  fi
else
  bash "$AI_STACK/bin/start-qdrant.sh"
fi

wait_http http://qdrant:6333/collections 30 || { err "Qdrant didn't come up"; exit 1; }
ok "Qdrant /collections responds"

# FalkorDB Redis-protocol smoke: TCP connect via the alias (falkordb resolves
# to 127.0.10.7 via /etc/hosts; falkordb listens on its alias IP, not on
# 127.0.0.1). bash /dev/tcp accepts hostnames.
if (echo > /dev/tcp/falkordb/6379) 2>/dev/null; then
  ok "FalkorDB TCP falkordb:6379 accepts connections"
else
  err "FalkorDB falkordb:6379 not accepting connections"
  exit 1
fi

stamp_mark "$PHASE"
record "phase 02 complete: falkordb + qdrant up"
ok "Phase 02 — storage plane — complete"
