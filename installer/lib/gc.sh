#!/usr/bin/env bash
# gc.sh — list & clean partial container orphans (ai-stack.partial=true).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/prompt.sh"

hdr "Garbage collection — partial containers"
mapfile -t PARTIALS < <(docker ps -a --filter "label=ai-stack.partial=true" --format '{{.Names}}')
if (( ${#PARTIALS[@]} == 0 )); then
  ok "No partial containers found."
  exit 0
fi
echo "Found partial containers (started but never marked ready):"
printf '  - %s\n' "${PARTIALS[@]}"
if confirm "Remove all of them?" N; then
  for c in "${PARTIALS[@]}"; do
    docker rm -f "$c" >/dev/null && ok "removed $c"
  done
else
  log "Aborted; partial containers preserved."
fi
