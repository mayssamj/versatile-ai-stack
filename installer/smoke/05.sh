#!/usr/bin/env bash
# smoke/05.sh — host UIs respond.
#
# Reachability pre-check (Safety Reviewer 2): for each UI container, prove
# the alias path BEFORE relying on the HTTP response. wait_http waits up to
# 30s on a curl that may time out for routing reasons; verify_container_
# reachable_by_alias gives an immediate, specific diagnosis.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/network.sh"
source "$AI_STACK/installer/lib/verify.sh"
source "$AI_STACK/installer/lib/validate.sh"

hdr "Smoke 05 — host UIs"

# 0. REACHABILITY pre-check for openwebui.
log "Reachability: openwebui via http://openwebui..."
verify_container_reachable_by_alias openwebui openwebui 8080 / \
  || { err "openwebui not reachable via http://openwebui:8080"; exit 1; }
ok "openwebui reachable via alias"

wait_http http://openwebui:8080 30 || { err "openwebui not responding at http://openwebui:8080"; exit 1; }
ok "Open WebUI responds (200)"

# Hermes Workspace is optional — only probe if its container is running.
if docker ps --format '{{.Names}}' | grep -qx hermes-workspace; then
  if verify_container_reachable_by_alias hermes-workspace workspace 3000 / 2>/dev/null; then
    ok "Hermes Workspace responds at http://workspace:3000"
  else
    warn "Hermes Workspace container running but http://workspace:3000 did not respond"
  fi
else
  warn "Hermes Workspace not running (skipped clone or upstream unavailable)"
fi
