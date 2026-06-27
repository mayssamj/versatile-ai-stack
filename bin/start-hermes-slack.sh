#!/usr/bin/env bash
# start-hermes-slack.sh — (re)start the hermes gateway so it serves SLACK (Socket
# Mode) for the fleet, alongside any other configured channel (e.g. Telegram).
#
# ARCHITECTURE (same as Telegram, Phase 20): the gateway runs INSIDE the
# hermes-fleet-v1 OpenShell sandbox, self-persists after the launching exec closes,
# and its Slack Socket-Mode WebSocket dials slack.com DIRECTLY (Phase 04 `slack`
# egress policy) — NOT through the OpenShell relay, so it survives relay idle-
# timeouts. ONE gateway process serves EVERY configured channel, so this
# `run --replace` also (re)starts Telegram if it's configured — it converges, it
# does not clobber. Lifecycle = hermes' own `gateway status/stop`. Tokens +
# allowlist must already be in the sandbox (Phase 38 writes them).
set -Eeuo pipefail
if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
  echo "needs bash 5+" >&2; exit 2
fi
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/hermes.sh"

log "(Re)starting hermes gateway inside $HERMES_SANDBOX for Slack (config from ~/.hermes/.env)..."
if ! hermes_gateway_restart; then
  err "gateway did not come up. status:"; echo "${HERMES_GW_STATUS:-<none>}" >&2
  err "log tail:"; hermes_gateway_log_tail 15 >&2 || true
  exit 1
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
  err "Slack token/auth error in the gateway log — check SLACK_BOT_TOKEN (xoxb-) / SLACK_APP_TOKEN (xapp-, connections:write) are valid and not revoked, then re-run 'vz-ai-stack.sh install 38'."
  exit 1
fi
# FATAL — egress blocked: the landlock denied a SLACK host (policy_denied is the
# OpenShell-specific signal; scope to a slack/wss host so unrelated denials don't count).
if grep -iE 'policy_denied|egress.*deni' <<<"$gwlog" | grep -qiE 'slack|wss'; then
  host="$(grep -iE 'policy_denied|egress.*deni' <<<"$gwlog" | grep -oiE '[a-z0-9.-]+\.slack\.com' | head -1)"
  err "Slack Socket Mode egress is BLOCKED — host '${host:-<a slack host>}' is missing from the Phase 04 'slack' policy."
  err "  Add it to the 'slack' stanza in installer/phases/04_openshell.sh AND openshell/policies/hermes-fleet-v1.yaml, then re-run 'vz-ai-stack.sh install 38'."
  exit 1
fi

# ADVISORIES (non-fatal — DMs still work) --------------------------------------
need="$(grep -oiE "needed': '[a-z:,_]+'" <<<"$gwlog" | head -1 | sed -E "s/.*'([a-z:,_]+)'/\1/")"
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
