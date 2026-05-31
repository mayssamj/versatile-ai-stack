#!/usr/bin/env bash
# stop-deerflow.sh — bring DeerFlow down via the upstream deploy.sh.
# Idempotent: re-running on a stopped stack is harmless.
set -Eeuo pipefail

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

DF_DIR="$AI_STACK/deer-flow"
[[ -d "$DF_DIR" && -f "$DF_DIR/scripts/deploy.sh" ]] || {
  ok "DeerFlow not installed; nothing to stop."
  exit 0
}

cd "$DF_DIR"
exec bash scripts/deploy.sh down
