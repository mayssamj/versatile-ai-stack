# Hermes Slack gateway healthy (Phase 38).
#
# Verifies the ai-stack Slack role router (default) or upstream native Slack
# fallback is serving Slack (Socket Mode) INSIDE hermes-fleet-v1 and BOTH Slack
# tokens are configured there. Skips cleanly
# (passes) when HERMES_SLACK_BOT_TOKEN isn't set — Slack is an opt-in add-on.
# NEVER prints the tokens and makes NO external Slack API call (it only reads
# in-sandbox `hermes gateway status` + the in-sandbox gateway log).
#
# Liveness model: in role-router mode assert pid alive + structured health
# `connected=true` + both tokens present + no auth/egress error. Native fallback
# keeps the older gateway log checks.
CHECKS+=(hermes_slack)
CHECK_TITLE[hermes_slack]="Hermes Slack gateway running (Phase 38, Socket Mode)"

_hsg_resolve_openshell() {
  if [[ -n "${HERMES_OPEN_SHELL_BIN:-}" && -x "$HERMES_OPEN_SHELL_BIN" ]]; then echo "$HERMES_OPEN_SHELL_BIN"
  elif [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell; else echo ""; fi
}

_hsg_role_router_enabled() {
  [[ "$(get_env HERMES_SLACK_ROLE_ROUTER 'true' 2>/dev/null)" != "false" ]]
}

hermes_slack_diagnose() {
  local tok; tok="$(get_env HERMES_SLACK_BOT_TOKEN '' 2>/dev/null)"
  if [[ -z "$tok" ]]; then
    echo "HERMES_SLACK_BOT_TOKEN not set — Slack gateway not configured. [skip]"
    return 0
  fi

  local osh; osh="$(_hsg_resolve_openshell)"
  if [[ -z "$osh" ]]; then
    echo "openshell CLI not found (Phase 04 not complete)"
    return 1
  fi

  # Sandbox must be Ready to probe.
  local state
  state="$("$osh" sandbox get hermes-fleet-v1 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | awk '/^[[:space:]]*Phase:/ {print $2; exit}')"
  if [[ "$state" != "Ready" ]]; then
    echo "sandbox hermes-fleet-v1 not Ready (state='${state:-absent}') — run 'vz-ai-stack.sh install 04'"
    return 1
  fi

  # BOTH tokens present inside the sandbox? (values never printed)
  local has
  has="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 -- \
    bash -c 'grep -q "^SLACK_BOT_TOKEN=." "$HOME/.hermes/.env" 2>/dev/null && grep -q "^SLACK_APP_TOKEN=." "$HOME/.hermes/.env" 2>/dev/null && echo YES || echo NO' \
    2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
  if [[ "$has" == "NO" ]]; then
    echo "gateway up but SLACK_BOT_TOKEN/SLACK_APP_TOKEN not both in sandbox ~/.hermes/.env — re-run 'vz-ai-stack.sh install 38'"
    return 1
  fi

  if _hsg_role_router_enabled; then
    local pid alive routerlog health
    pid="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 -- cat /sandbox/.hermes-slack-role-router.pid 2>/dev/null \
      | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
    alive="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 -- \
      bash -c 'pid="$(cat /sandbox/.hermes-slack-role-router.pid 2>/dev/null || true)"; [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && echo YES || echo NO' \
      2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
    if [[ "$alive" != "YES" ]]; then
      echo "Slack role router is not running — start: bash $AI_STACK/bin/start-hermes-slack.sh (or 'vz-ai-stack.sh install 38')"
      return 1
    fi
    routerlog="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 -- bash -c 'tail -120 /sandbox/.hermes-slack-role-router.log 2>/dev/null' 2>&1 | LC_ALL=C sed $'s/\x1b\\[[0-9;]*m//g')"
    if grep -qiE 'invalid_auth|token_revoked|token_expired|account_inactive|not_allowed_token_type|SlackApiError' <<<"$routerlog"; then
      echo "Slack role-router log shows an auth/API error — token/scope may be wrong or revoked"
      return 1
    fi
    if grep -iE 'policy_denied|egress.*deni' <<<"$routerlog" | grep -qiE 'slack|wss'; then
      echo "Slack role-router log shows BLOCKED Slack egress — a Slack host is missing from the Phase 04 'slack' policy"
      return 1
    fi
    health="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 -- cat /sandbox/.hermes-slack/health.json 2>/dev/null \
      | sed $'s/\x1b\\[[0-9;]*m//g')"
    if ! HEALTH_JSON="$health" ROUTER_PID="$pid" python3 - <<'PY' >/dev/null 2>&1
import json, os, sys, time
try:
    data = json.loads(os.environ["HEALTH_JSON"])
except Exception:
    sys.exit(1)
if not data.get("connected"):
    sys.exit(1)
if str(data.get("pid", "")) != os.environ.get("ROUTER_PID", ""):
    sys.exit(1)
updated = int(data.get("updated_at") or 0)
if time.time() - updated > 120:
    sys.exit(1)
PY
    then
      echo "Slack role router is running but /sandbox/.hermes-slack/health.json is missing, stale, or for a different pid"
      return 1
    fi
    local allow_users allow_all
    allow_users="$(get_env HERMES_SLACK_ALLOWED_USERS '' 2>/dev/null)"
    allow_all="$(get_env HERMES_SLACK_ALLOW_ALL '' 2>/dev/null)"
    if [[ -z "$allow_users" ]]; then
      if [[ "$allow_all" == "true" ]]; then
        echo "  (role router running but LOCKED: HERMES_SLACK_ALLOW_ALL is ignored in operator mode. Set HERMES_SLACK_ALLOWED_USERS=<your_member_id> in .env + re-run 'install 38')"
      else
        echo "  (role router running but LOCKED: no allowlist → denies all users. Set HERMES_SLACK_ALLOWED_USERS=<your_member_id> in .env + re-run 'install 38')"
      fi
      return 0
    fi
    echo "  (role router running; PID ${pid:-?}; virtual role targets + mission threads enabled)"
    return 0
  fi

  # Gateway daemon alive inside the sandbox?
  local status
  status="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 25 -- hermes gateway status 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')"
  if ! grep -qi 'running' <<<"$status"; then
    echo "gateway not running in sandbox — start: bash $AI_STACK/bin/start-hermes-slack.sh (or 'vz-ai-stack.sh install 38')"
    return 1
  fi

  # Detection is SCOPED to Slack lines — the gateway log is SHARED (Telegram, MCP
  # tools, cron), so an unrelated 'failed to connect' / policy_denied must not red
  # this Slack check. Benign Socket-Mode churn is filtered too.
  local gwlog slacklog
  gwlog="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 -- bash -c 'tail -120 /sandbox/.hermes-gateway.log 2>/dev/null' 2>&1 | LC_ALL=C sed $'s/\x1b\\[[0-9;]*m//g')"
  slacklog="$(grep -iE 'slack|socket' <<<"$gwlog" | grep -viE 'reconnect|disconnect|rate.?limit|\b429\b|ping|pong|mcp_tool|sourcegraph')"
  # Fatal = the TOKEN itself is bad. A missing OAuth scope is NOT failed here (the bot
  # still works for DMs); the install/start path surfaces the needed scope as a warning.
  if grep -qiE 'invalid_auth|token_revoked|token_expired|account_inactive|not_allowed_token_type' <<<"$slacklog"; then
    echo "gateway log shows a Slack token/auth error — a token may be revoked or malformed (re-run 'vz-ai-stack.sh install 38')"
    return 1
  fi
  # Blocked egress = the landlock denied a SLACK host (scope to slack/wss).
  if grep -iE 'policy_denied|egress.*deni' <<<"$gwlog" | grep -qiE 'slack|wss'; then
    echo "gateway log shows BLOCKED Slack egress — a Slack host is missing from the Phase 04 'slack' policy (tail /sandbox/.hermes-gateway.log | grep -i denied)"
    return 1
  fi

  # Locked (no allowlist) is SECURE but means the bot denies everyone — surface it.
  local allow_users allow_all
  allow_users="$(get_env HERMES_SLACK_ALLOWED_USERS '' 2>/dev/null)"
  allow_all="$(get_env HERMES_SLACK_ALLOW_ALL '' 2>/dev/null)"
  if [[ -z "$allow_users" && "$allow_all" != "true" ]]; then
    echo "  (running but LOCKED: no allowlist → denies all users. Set HERMES_SLACK_ALLOWED_USERS=<your_member_id> in .env + re-run 'install 38')"
    return 0
  fi
  if [[ -n "$allow_users" ]]; then
    echo "  (running; allowlisted to Slack member id(s) [$allow_users])"
  else
    echo "  (running; HERMES_SLACK_ALLOW_ALL=true in native Slack mode)"
  fi
  return 0
}

hermes_slack_fix() {
  warn "Self-healing Hermes Slack by re-running Phase 38 converge."
  bash "$AI_STACK/installer/phases/38_hermes_slack.sh" >/dev/null 2>&1 || return 1
  hermes_slack_diagnose >/dev/null 2>&1
}
