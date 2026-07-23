#!/usr/bin/env bash
# start-hermes-slack.sh — (re)start Slack access for the Hermes fleet.
#
# Default architecture: ai-stack's role router owns Slack Socket Mode so one app
# can address multiple Hermes roles (`techlead:`, `backend:`, `delivery:`). The
# upstream Hermes native gateway still runs for Telegram/other native channels,
# but its Slack adapter is disabled before the router starts to avoid duplicate
# Socket Mode consumers. Set HERMES_SLACK_ROLE_ROUTER=false to stop the router and
# return Slack to upstream Hermes native handling.
set -Eeuo pipefail
if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
  echo "needs bash 5+" >&2; exit 2
fi
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/hermes.sh"

role_router_enabled() {
  [[ "$(get_env HERMES_SLACK_ROLE_ROUTER 'true')" != "false" ]]
}

stop_role_router() {
  local osh
  osh="$(hermes_resolve_openshell)"
  [[ -n "$osh" ]] || { err "openshell not on PATH — run phase 04"; return 1; }
  "$osh" sandbox exec -n "$HERMES_SANDBOX" --no-tty --timeout 20 -- bash -c '
    pid_file=/sandbox/.hermes-slack-role-router.pid
    if [ ! -s "$pid_file" ]; then
      exit 0
    fi
    old="$(cat "$pid_file" 2>/dev/null || true)"
    if [ -n "$old" ] && kill -0 "$old" 2>/dev/null; then
      kill -- "-$old" 2>/dev/null || kill "$old" 2>/dev/null || true
      for _ in 1 2 3 4 5; do
        kill -0 "$old" 2>/dev/null || break
        sleep 1
      done
      kill -0 "$old" 2>/dev/null && { kill -9 -- "-$old" 2>/dev/null || kill -9 "$old" 2>/dev/null || true; }
    fi
    rm -f "$pid_file"
  ' >/dev/null 2>&1 || { err "failed to stop existing Slack role router"; return 1; }
}

start_role_router() {
  local osh router_src launcher_src router_log router_health role_pid rolelog health pid
  osh="$(hermes_resolve_openshell)"
  [[ -n "$osh" ]] || { err "openshell not on PATH — run phase 04"; return 1; }

  router_src="$AI_STACK/installer/lib/hermes_slack_role_router.py"
  launcher_src="$AI_STACK/installer/lib/hermes_slack_role_router_start.sh"
  [[ -f "$router_src" ]] || { err "missing Slack role router source: $router_src"; return 1; }
  [[ -f "$launcher_src" ]] || { err "missing Slack role router launcher: $launcher_src"; return 1; }

  "$osh" sandbox exec -n "$HERMES_SANDBOX" --no-tty --timeout 20 -- \
    mkdir -p /sandbox/fleet-boot >/dev/null 2>&1 || return 1
  "$osh" sandbox upload --no-git-ignore "$HERMES_SANDBOX" "$router_src" /sandbox/fleet-boot/ >/dev/null 2>&1 \
    || { err "failed to upload Slack role router into $HERMES_SANDBOX"; return 1; }
  "$osh" sandbox upload --no-git-ignore "$HERMES_SANDBOX" "$launcher_src" /sandbox/fleet-boot/ >/dev/null 2>&1 \
    || { err "failed to upload Slack role router launcher into $HERMES_SANDBOX"; return 1; }

  router_log="/sandbox/.hermes-slack-role-router.log"
  router_health="/sandbox/.hermes-slack/health.json"
  role_pid="/sandbox/.hermes-slack-role-router.pid"
  "$osh" sandbox exec -n "$HERMES_SANDBOX" --no-tty --timeout 30 -- \
    bash /sandbox/fleet-boot/hermes_slack_role_router_start.sh >/dev/null 2>&1 \
    || {
      err "Slack role router did not stay running"
      "$osh" sandbox exec -n "$HERMES_SANDBOX" --no-tty --timeout 20 -- \
        tail -60 "$router_log" 2>/dev/null | hermes_strip >&2 || true
      return 1
    }

  sleep 3
  rolelog="$("$osh" sandbox exec -n "$HERMES_SANDBOX" --no-tty --timeout 20 -- \
    bash -c "tail -80 $router_log 2>/dev/null" 2>&1 | hermes_strip)"
  if grep -qiE 'invalid_auth|token_revoked|token_expired|account_inactive|not_allowed_token_type|SlackApiError' <<<"$rolelog"; then
    err "Slack role router log shows an auth/API error — check SLACK_BOT_TOKEN / SLACK_APP_TOKEN and re-run install 38."
    echo "$rolelog" >&2
    stop_role_router || true
    return 1
  fi
  if grep -qiE 'A new session|Bolt app is running|Socket Mode.*connected' <<<"$rolelog"; then
    ok "Hermes Slack role router connected over Socket Mode"
  else
    err "Slack role router started but Socket Mode handshake was not observed."
    echo "$rolelog" >&2
    stop_role_router || true
    return 1
  fi
  pid="$("$osh" sandbox exec -n "$HERMES_SANDBOX" --no-tty --timeout 20 -- cat "$role_pid" 2>/dev/null | hermes_strip | tr -d '[:space:]')"
  health="$("$osh" sandbox exec -n "$HERMES_SANDBOX" --no-tty --timeout 20 -- \
    cat "$router_health" 2>/dev/null | hermes_strip || true)"
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
    err "Slack role router started but did not publish fresh healthy Socket Mode state."
    echo "$rolelog" >&2
    stop_role_router || true
    return 1
  fi
  ok "Hermes Slack role router running in $HERMES_SANDBOX (PID ${pid:-?})"
}

log "(Re)starting hermes gateway inside $HERMES_SANDBOX for Slack (config from ~/.hermes/.env)..."
if role_router_enabled; then
  log "Slack role router enabled; disabling native Hermes Slack adapter before gateway restart..."
  OSH="$(hermes_resolve_openshell)"
  [[ -n "$OSH" ]] || { err "openshell not on PATH — run phase 04"; exit 1; }
  "$OSH" sandbox exec -n "$HERMES_SANDBOX" --no-tty --timeout 20 -- \
    hermes config set platforms.slack.enabled false >/dev/null 2>&1 \
    || { err "could not disable native Hermes Slack adapter; refusing to start a second Slack consumer"; exit 1; }
  if ! hermes_gateway_restart; then
    err "native Hermes gateway did not restart after disabling Slack; refusing to start a second Slack consumer."
    err "status: ${HERMES_GW_STATUS:-<none>}"
    exit 1
  fi
  start_role_router || exit 1
  note "Status: openshell sandbox exec -n $HERMES_SANDBOX -- cat /sandbox/.hermes-slack-role-router.pid"
  note "Logs:   openshell sandbox exec -n $HERMES_SANDBOX -- tail -f /sandbox/.hermes-slack-role-router.log"
  note "Stop:   openshell sandbox exec -n $HERMES_SANDBOX -- bash -c 'kill \"\$(cat /sandbox/.hermes-slack-role-router.pid)\"'"
  exit 0
else
  log "Slack role router disabled; stopping ai-stack router before enabling upstream Hermes native Slack..."
  stop_role_router || exit 1
  OSH="$(hermes_resolve_openshell)"
  [[ -n "$OSH" ]] || { err "openshell not on PATH — run phase 04"; exit 1; }
  "$OSH" sandbox exec -n "$HERMES_SANDBOX" --no-tty --timeout 20 -- \
    hermes config set platforms.slack.enabled true >/dev/null 2>&1 \
    || { err "could not enable native Hermes Slack adapter"; exit 1; }
  if ! hermes_gateway_restart; then
    err "gateway did not come up. status:"; echo "${HERMES_GW_STATUS:-<none>}" >&2
    err "log tail:"; hermes_gateway_log_tail 15 >&2 || true
    exit 1
  fi
fi

# --- Slack post-checks on the in-sandbox gateway log --------------------------
# The gateway log is SHARED (Telegram, MCP tools, cron), so detection is SCOPED to
# Slack lines — a generic 'failed to connect' from an unrelated MCP server must not
# read as a Slack problem. Only an unambiguous Slack TOKEN failure or a Slack-host
# egress denial is fatal; a missing scope / channel send-error are advisories (the
# DM path still works), and absence of an explicit 'hello' is NOT a failure.
sleep 6   # let Socket Mode complete its WSS handshake (can take 3–8s under load)
gwlog="$(hermes_gateway_log_tail 80 || true)"
slacklog="$(grep -iE 'slack|socket\.?mode|wss[.-][a-z0-9]*\.?slack' <<<"$gwlog" \
  | grep -viE 'reconnect|disconnect|rate.?limit|\b429\b|ping|pong|mcp_tool|sourcegraph')"

# FATAL — the Slack TOKEN itself is bad (the bot can't work at all).
if grep -qiE 'invalid_auth|token_revoked|token_expired|account_inactive|not_allowed_token_type|invalid.?token' <<<"$slacklog"; then
  err "Slack token/auth error in the gateway log — check SLACK_BOT_TOKEN (xoxb-) / SLACK_APP_TOKEN (xapp-, connections:write) are valid and not revoked, then re-run 'mayssam-ai-stack.sh install 38'."
  exit 1
fi
# FATAL — egress blocked: the landlock denied a SLACK host (policy_denied is the
# OpenShell-specific signal; scope to a slack/wss host so unrelated denials don't count).
if grep -iE 'policy_denied|egress.*deni' <<<"$gwlog" | grep -qiE 'slack|wss'; then
  host="$(grep -iE 'policy_denied|egress.*deni' <<<"$gwlog" | grep -oiE '[a-z0-9.-]+\.slack\.com' | head -1 || true)"
  err "Slack Socket Mode egress is BLOCKED — host '${host:-<a slack host>}' is missing from the Phase 04 'slack' policy."
  err "  Add it to the 'slack' stanza in installer/phases/04_openshell.sh AND openshell/policies/hermes-fleet-v1.yaml, then re-run 'mayssam-ai-stack.sh install 38'."
  exit 1
fi

# ADVISORIES (non-fatal — DMs still work) --------------------------------------
need="$(grep -oiE "needed': '[a-z:,_]+'" <<<"$gwlog" | head -1 | sed -E "s/.*'([a-z:,_]+)'/\1/" || true)"
[[ -n "$need" ]] && warn "Slack wants an extra OAuth scope: '${need}'. The bot works for DMs without it; to enable it add the scope at api.slack.com → your app → OAuth & Permissions → Bot Token Scopes, then Reinstall to Workspace."
if grep -qiE 'chat\.postmessage|send error|not_in_channel|channel_not_found' <<<"$slacklog"; then
  warn "Slack rejected a channel post — usually a HOME channel the bot hasn't joined. If you set HERMES_SLACK_HOME_CHANNEL, /invite the bot to that channel (or unset it). DMs are unaffected."
fi

# Positive connect proof (best-effort; absence is NOT a failure).
if grep -qiE '"?type"?[": ]*hello|socket\.?mode.*(connect|open)|slack.*(connected|ready|listening)' <<<"$slacklog"; then
  ok "Slack Socket Mode connected (handshake seen in the gateway log)"
else
  note "Slack 'hello' not explicitly logged — the gateway is up and reached the Slack API; confirm with a test DM."
  note "  Live log: openshell sandbox exec -n $HERMES_SANDBOX -- tail -f $HERMES_GW_LOG"
fi

pid="$(hermes_gateway_pid)"
ok "hermes gateway running in $HERMES_SANDBOX (PID $pid) — Slack channel active"
note "Status: openshell sandbox exec -n $HERMES_SANDBOX -- hermes gateway status"
note "Logs:   openshell sandbox exec -n $HERMES_SANDBOX -- tail -f $HERMES_GW_LOG"
note "Stop:   openshell sandbox exec -n $HERMES_SANDBOX -- hermes gateway stop"
