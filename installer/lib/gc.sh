#!/usr/bin/env bash
# gc.sh — list & clean partial container orphans (ai-stack.partial=true).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/prompt.sh"

hdr "Garbage collection — partial containers"
# A container is a genuine orphan only if it was started but never came up cleanly.
# The ai-stack.partial=true label CANNOT be cleared (Docker labels are immutable;
# `docker update` has no --label flag — see mark_ready in docker.sh), so EVERY
# managed container — including the healthy running stack — carries partial=true
# forever. Reaping on the label alone would `docker rm -f` the entire live stack.
# So we exclude any partial-labeled container that is currently RUNNING or was
# recorded ready by mark_ready (installer/state/ready/<name>). Only genuinely
# stuck containers (not running, never marked ready) are offered for removal.
# (2026-07-05 takeover fix.)
_gc_running() { docker ps --format '{{.Names}}' | grep -qx "$1"; }
_gc_ready_marked() { [[ -f "$STATE_DIR/ready/$1" ]]; }
mapfile -t LABELED < <(docker ps -a --filter "label=ai-stack.partial=true" --format '{{.Names}}')
PARTIALS=(); EXCLUDED=()
for _c in ${LABELED[@]+"${LABELED[@]}"}; do
  if _gc_running "$_c" || _gc_ready_marked "$_c"; then
    EXCLUDED+=("$_c")
  else
    PARTIALS+=("$_c")
  fi
done
if (( ${#EXCLUDED[@]} > 0 )); then
  note "Excluded ${#EXCLUDED[@]} healthy/ready container(s) from GC (running or mark_ready'd): ${EXCLUDED[*]}"
fi
if (( ${#PARTIALS[@]} == 0 )); then
  ok "No partial container orphans found."
  exit 0
fi
echo "Found partial container orphans (started but never came up / never marked ready):"
printf '  - %s\n' "${PARTIALS[@]}"
if confirm "Remove all of them?" N; then
  for c in "${PARTIALS[@]}"; do
    docker rm -f "$c" >/dev/null && { rm -f "$STATE_DIR/ready/$c" 2>/dev/null || true; ok "removed $c"; }
  done
else
  log "Aborted; partial containers preserved."
fi
