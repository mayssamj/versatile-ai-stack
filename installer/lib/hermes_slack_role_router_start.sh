#!/usr/bin/env bash
# Start/restart the ai-stack Hermes Slack role router inside hermes-fleet-v1.
set -Eeuo pipefail

pid_file=/sandbox/.hermes-slack-role-router.pid
log_file=/sandbox/.hermes-slack-role-router.log
router=/sandbox/fleet-boot/hermes_slack_role_router.py

if [[ -s "$pid_file" ]]; then
  old="$(cat "$pid_file" 2>/dev/null || true)"
  if [[ -n "$old" ]] && kill -0 "$old" 2>/dev/null; then
    kill -- "-$old" 2>/dev/null || kill "$old" 2>/dev/null || true
    for _ in 1 2 3 4 5; do
      kill -0 "$old" 2>/dev/null || break
      sleep 1
    done
    kill -0 "$old" 2>/dev/null && { kill -9 -- "-$old" 2>/dev/null || kill -9 "$old" 2>/dev/null || true; }
  fi
fi

set -a
[[ -f "$HOME/.hermes/.env" ]] && . "$HOME/.hermes/.env"
set +a
export HERMES_CONFIG_PATH="${HERMES_CONFIG_PATH:-$HOME/.hermes/config.yaml}"

# Absolute venv python (the W2 gateway idiom — /sandbox/.venv/bin/hermes): bare
# `python3` resolves to the uv-managed system python in any NON-login shell
# (watchdog W2b's docker exec, a post-restart relaunch), where /sandbox/.venv's
# site-packages (slack_bolt) are invisible — the router then dies in seconds
# behind a MISLEADING "Slack dependencies are missing" (live 2026-07-22: deps
# were present + importable via the venv python the whole time; only openshell
# relay sessions source the profile that puts .venv/bin first on PATH).
py=/sandbox/.venv/bin/python3
[ -x "$py" ] || py=python3
nohup setsid "$py" "$router" > "$log_file" 2>&1 &
echo "$!" > "$pid_file"
sleep 4
kill -0 "$(cat "$pid_file")"
