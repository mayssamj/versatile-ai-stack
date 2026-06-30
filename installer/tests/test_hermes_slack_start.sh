#!/usr/bin/env bash
# Offline lifecycle tests for bin/start-hermes-slack.sh.
set -Eeuo pipefail

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 -- got: >>>$2<<<"; FAIL=$((FAIL + 1)); }
assert_contains() { printf '%s' "$3" | grep -qF "$2" && pass "$1" || fail "$1" "$3"; }
assert_not_contains() { printf '%s' "$3" | grep -qF "$2" && fail "$1" "$3" || pass "$1"; }

WORKTREE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TESTDIR="$(mktemp -d)"
trap 'rm -rf "$TESTDIR"' EXIT

FAKE_OPEN="$TESTDIR/openshell"
CALLS="$TESTDIR/calls.log"

cat > "$FAKE_OPEN" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

CALLS="${FAKE_OPEN_CALLS:?}"
echo "$*" >> "$CALLS"

if [[ "${1:-}" == "sandbox" && "${2:-}" == "get" ]]; then
  echo "Phase: Ready"
  exit 0
fi

if [[ "${1:-}" == "sandbox" && "${2:-}" == "upload" ]]; then
  echo "UPLOAD" >> "$CALLS"
  exit 0
fi

if [[ "${1:-}" == "sandbox" && "${2:-}" == "exec" ]]; then
  args=("$@")
  cmd_start=0
  for i in "${!args[@]}"; do
    if [[ "${args[$i]}" == "--" ]]; then
      cmd_start=$((i + 1))
      break
    fi
  done
  cmd=("${args[@]:$cmd_start}")
  joined="${cmd[*]}"
  case "$joined" in
    *"hermes config set platforms.slack.enabled false"*)
      echo "CONFIG_FALSE" >> "$CALLS"
      exit "${FAKE_CONFIG_FALSE_RC:-0}"
      ;;
    *"hermes config set platforms.slack.enabled true"*)
      echo "CONFIG_TRUE" >> "$CALLS"
      exit 0
      ;;
    *"nohup hermes gateway run --replace"*)
      echo "GATEWAY_RUN" >> "$CALLS"
      exit 0
      ;;
    *"hermes gateway status"*)
      echo "running PID: 4242"
      exit 0
      ;;
    *"bash /sandbox/fleet-boot/hermes_slack_role_router_start.sh"*)
      echo "ROUTER_START" >> "$CALLS"
      exit 0
      ;;
    *"tail -80 /sandbox/.hermes-slack-role-router.log"*)
      if [[ "${FAKE_HANDSHAKE:-ok}" == "missing" ]]; then
        echo "router booted"
      else
        echo "A new session has been established"
      fi
      exit 0
      ;;
    *"cat /sandbox/.hermes-slack/health.json"*)
      if [[ "${FAKE_HEALTH:-ok}" == "missing" ]]; then
        exit 1
      else
        echo '{"connected": true, "bot_user_id": "UBOT", "pid": 777, "queue_depth": 0, "updated_at": 1800000000}'
      fi
      exit 0
      ;;
    *"tail -80 /sandbox/.hermes-gateway.log"*|*"tail -120 /sandbox/.hermes-gateway.log"*)
      echo "slack socket mode connected hello"
      exit 0
      ;;
    *"cat /sandbox/.hermes-slack-role-router.pid"*)
      echo "777"
      exit 0
      ;;
    *".hermes-slack-role-router.pid"*)
      echo "ROUTER_STOP" >> "$CALLS"
      exit 0
      ;;
    *)
      exit 0
      ;;
  esac
fi

exit 0
EOF
chmod +x "$FAKE_OPEN"

run_start() {
  local env_file="$1"
  shift || true
  env \
    ENV_FILE="$env_file" \
    HERMES_OPEN_SHELL_BIN="$FAKE_OPEN" \
    FAKE_OPEN_CALLS="$CALLS" \
    "$@" \
    bash "$WORKTREE/bin/start-hermes-slack.sh" 2>&1
}

scenario_router_success() {
  local label="router enabled starts role router"
  : > "$CALLS"
  local env_file="$TESTDIR/router.env"
  : > "$env_file"

  local out
  out="$(run_start "$env_file")"
  local calls
  calls="$(cat "$CALLS")"

  assert_contains "$label: disables native Slack" "CONFIG_FALSE" "$calls"
  assert_contains "$label: restarts native gateway" "GATEWAY_RUN" "$calls"
  assert_contains "$label: starts router" "ROUTER_START" "$calls"
  assert_contains "$label: observes handshake" "Hermes Slack role router connected" "$out"
  assert_not_contains "$label: does not enable native Slack" "CONFIG_TRUE" "$calls"
}

scenario_handshake_failure_stops_router() {
  local label="handshake failure stops role router"
  : > "$CALLS"
  local env_file="$TESTDIR/no-handshake.env"
  : > "$env_file"

  set +e
  local out
  out="$(run_start "$env_file" FAKE_HANDSHAKE=missing)"
  local rc=$?
  set -e
  local calls
  calls="$(cat "$CALLS")"

  [[ "$rc" -ne 0 ]] && pass "$label: exits non-zero" || fail "$label: exits non-zero" "$out"
  assert_contains "$label: cleanup called" "ROUTER_STOP" "$calls"
}

scenario_health_failure_stops_router() {
  local label="health failure stops role router"
  : > "$CALLS"
  local env_file="$TESTDIR/no-health.env"
  : > "$env_file"

  set +e
  local out
  out="$(run_start "$env_file" FAKE_HEALTH=missing)"
  local rc=$?
  set -e
  local calls
  calls="$(cat "$CALLS")"

  [[ "$rc" -ne 0 ]] && pass "$label: exits non-zero" || fail "$label: exits non-zero" "$out"
  assert_contains "$label: cleanup called" "ROUTER_STOP" "$calls"
}

scenario_rollback_native() {
  local label="role-router false rolls back to native Slack"
  : > "$CALLS"
  local env_file="$TESTDIR/native.env"
  printf 'HERMES_SLACK_ROLE_ROUTER=false\n' > "$env_file"

  local out
  out="$(run_start "$env_file")"
  local calls
  calls="$(cat "$CALLS")"

  assert_contains "$label: stops router first" "ROUTER_STOP" "$calls"
  assert_contains "$label: enables native Slack" "CONFIG_TRUE" "$calls"
  assert_contains "$label: restarts native gateway" "GATEWAY_RUN" "$calls"
  assert_contains "$label: reports gateway running" "hermes gateway running" "$out"
  assert_not_contains "$label: does not start router" "ROUTER_START" "$calls"
}

echo "=== Hermes Slack start-script offline tests ==="
scenario_router_success
scenario_handshake_failure_stops_router
scenario_health_failure_stops_router
scenario_rollback_native
echo "=== Results: PASS=$PASS FAIL=$FAIL ==="
[[ "$FAIL" -eq 0 ]]
