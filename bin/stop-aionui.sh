#!/usr/bin/env bash
# stop-aionui.sh — `mayssam-ai-stack.sh stop aionui` entrypoint. Delegates to the
# daemon manager's `stop` verb (bootout the launchd job so KeepAlive won't
# respawn, then free :25808). The desktop app, if open, is left alone — quit it
# from the menu bar. Re-enable the WebUI with `mayssam-ai-stack.sh start aionui`.
set -Eeuo pipefail
AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
exec bash "$AI_STACK/bin/start-aionui.sh" stop
