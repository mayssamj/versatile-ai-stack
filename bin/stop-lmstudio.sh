#!/usr/bin/env bash
# stop-lmstudio.sh — guarded, idempotent server-only stop for LM Studio.
#
# Symmetric counterpart to start-lmstudio.sh. `vz-ai-stack.sh stop lmstudio`
# routes here (cmd_stop prefers bin/stop-<svc>.sh). LM Studio has no PID file and
# is not a container/brew service, so the generic cmd_stop fallbacks don't cover
# it — this script backs the `Stop:` line that cmd_start advertises.
#
# Guard chain mirrors start-lmstudio.sh:
#   a) bash 5 guard
#   b) macOS-only (no-op refusal elsewhere)
#   c) lms CLI bootstrapped (sourced from installer/lib/lmstudio.sh)
#   d) idempotent: server already down → ok + exit 0
#   e) lms server stop
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "bin/stop-lmstudio.sh: needs bash 5+" >&2; exit 2
fi

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

# --- b. macOS-only --------------------------------------------------------------
if [[ "$(uname)" != "Darwin" ]]; then
  ok "LM Studio is macOS-only; nothing to stop on this host."
  exit 0
fi

# --- c. Source the shared lib (LMS_PORT, lms_cli, lms_server_up) -----------------
source "$AI_STACK/installer/lib/lmstudio.sh"

LMS="$(lms_cli 2>/dev/null || echo "")"
if [[ -z "$LMS" ]]; then
  # No CLI ⇒ LM Studio was never bootstrapped ⇒ nothing to stop.
  ok "lms CLI not found — LM Studio server not running; nothing to stop."
  exit 0
fi

# --- d. Idempotent: already down → success --------------------------------------
if ! lms_server_up; then
  ok "LM Studio server already stopped (:${LMS_PORT})."
  exit 0
fi

# --- e. Stop the server ---------------------------------------------------------
log "Stopping LM Studio server on :${LMS_PORT}..."
"$LMS" server stop 2>&1 | tail -2 || true

# Confirm (best-effort).
i=0
while (( i < 10 )); do
  lms_server_up || break
  sleep 1; i=$(( i + 1 ))
done

if lms_server_up; then
  warn "LM Studio server still answering on :${LMS_PORT} after stop — quit the LM Studio app manually if it persists."
  exit 1
fi
ok "Stopped LM Studio server (:${LMS_PORT}). (The desktop app may still be open — quit it to free CPU.)"
