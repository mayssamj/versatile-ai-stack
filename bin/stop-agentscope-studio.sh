#!/usr/bin/env bash
# stop-agentscope-studio.sh — `mayssam-ai-stack.sh stop agentscope-studio` entrypoint.
# Delegates to the daemon manager's `stop` verb (bootout the launchd job so KeepAlive
# won't respawn, then free :5275). The npm @agentscope/studio package stays installed;
# re-enable the GUI with `mayssam-ai-stack.sh start agentscope-studio`. Mirrors stop-aionui.sh.
set -Eeuo pipefail
AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
exec bash "$AI_STACK/bin/start-agentscope-studio.sh" stop
