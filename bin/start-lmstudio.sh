#!/usr/bin/env bash
# start-lmstudio.sh — guarded, idempotent server-only start for LM Studio.
#
# Guard chain (each failure = clear refusal naming the right command):
#   a) bash 5 guard
#   b) macOS-only (MLX is Apple Silicon / macOS)
#   c) /Applications/LM Studio.app must be installed
#   d) lms CLI must be bootstrapped (sourced from installer/lib/lmstudio.sh)
#   e) idempotent: already up → ok + exit 0
#   f) start server → wait up to 30s
#   g) success: print CPU-idle-spin warning + model-sync reminder
#
# The authoritative URL/Stop report line + browser-open are handled by
# cmd_start (mayssam-ai-stack.sh) — this script only brings the server up.
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "bin/start-lmstudio.sh: needs bash 5+" >&2; exit 2
fi

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

# --- b. macOS-only guard ------------------------------------------------------
if [[ "$(uname)" != "Darwin" ]]; then
  err "LM Studio is macOS-only; on this host use a \`local\` Ollama model or LM Studio on a Mac."
  exit 1
fi

# --- c. /Applications/LM Studio.app must exist --------------------------------
if [[ ! -d "/Applications/LM Studio.app" ]]; then
  err "LM Studio is not installed — /Applications/LM Studio.app not found."
  err "Set it up first:  mayssam-ai-stack.sh install lmstudio"
  exit 1
fi

# --- d. Source the shared lib (LMS_PORT, lms_cli, lms_server_up, etc.) --------
source "$AI_STACK/installer/lib/lmstudio.sh"

# Bootstrap the lms CLI (lib exposes lms_cli which searches the known paths).
LMS="$(lms_cli 2>/dev/null || echo "")"
if [[ -z "$LMS" ]]; then
  err "lms CLI not found. Open LM Studio.app once (it bootstraps the CLI at ~/.lmstudio/bin/lms), then retry."
  err "Set up via:  mayssam-ai-stack.sh install lmstudio"
  exit 1
fi

# --- e. Idempotent: already running → success ---------------------------------
if lms_server_up; then
  ok "LM Studio server already running on :${LMS_PORT}"
  exit 0
fi

# --- f. Start the server + wait up to 30s -------------------------------------
log "Starting LM Studio server on 0.0.0.0:${LMS_PORT} (bound for container access)..."
"$LMS" server start -p "${LMS_PORT}" --bind 0.0.0.0 2>&1 | tail -3 || true

i=0
while (( i < 30 )); do
  if lms_server_up; then
    break
  fi
  sleep 1
  i=$(( i + 1 ))
done

if ! lms_server_up; then
  err "LM Studio server did not come up on :${LMS_PORT} within 30s."
  print_inference_hint
  exit 1
fi

ok "LM Studio server up on :${LMS_PORT} (http://127.0.0.1:${LMS_PORT})"

# --- g. Reminders -------------------------------------------------------------
warn "LM Studio's app idle-spins ~0.8 core; quit it when done: \`lms server stop\` + quit the app"
note "No model auto-loads — assign one in models.yml + run \`mayssam-ai-stack.sh model sync\`"
note "Endpoint:  http://127.0.0.1:${LMS_PORT}/v1  (OpenAI-compatible; LiteLLM routes local-nemotron3-nano-4b-mlx through here)"
