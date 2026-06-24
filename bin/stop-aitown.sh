#!/usr/bin/env bash
# stop-aitown.sh — bring the AI Town compose stack down (Phase 36).
# Symmetric counterpart to start-aitown.sh; backs the `Stop:` line cmd_start advertises
# (aitown is a compose stack whose container names != svc, so the generic cmd_stop
# fallbacks would miss it). Delegates to start-aitown.sh's `stop` so there's ONE
# teardown path. Idempotent: re-running on a stopped/absent stack is harmless.
#
# DATA-SAFE: this is `docker compose down` (NO -v) — it PRESERVES the Convex world
# (SQLite bind-mounted at $AI_STACK/data/aitown/convex). To wipe everything use
# `bash bin/start-aitown.sh uninstall --nuke` (backup-first; invalidates the admin key).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

AT_DIR="$AI_STACK/ai-town"
[[ -f "$AT_DIR/docker-compose.yml" ]] || { ok "aitown not installed; nothing to stop."; exit 0; }

exec bash "$AI_STACK/bin/start-aitown.sh" stop
