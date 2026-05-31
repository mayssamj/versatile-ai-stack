#!/usr/bin/env bash
# history.sh — assemble per-run CHANGELOG.d/* into one chronological view.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

DIR="$AI_STACK/CHANGELOG.d"
if [[ ! -d "$DIR" ]] || ! ls "$DIR"/*.md >/dev/null 2>&1; then
  ok "No per-run CHANGELOG entries yet."
  exit 0
fi
hdr "Assembled history (most recent last)"
for f in "$DIR"/*.md; do
  printf '\n--- %s ---\n' "$(basename "$f" .md)"
  cat "$f"
done
