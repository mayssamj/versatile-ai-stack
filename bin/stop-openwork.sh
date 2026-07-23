#!/usr/bin/env bash
# stop-openwork.sh — `mayssam-ai-stack.sh stop openwork` entrypoint. Delegates to the
# daemon manager's `stop` verb (bootout the launchd job so KeepAlive won't
# respawn, then free :8787 and reap the workspace-scoped OpenCode sidecars).
# Re-enable with `mayssam-ai-stack.sh start openwork`.
set -Eeuo pipefail
AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
exec bash "$AI_STACK/bin/start-openwork.sh" stop
