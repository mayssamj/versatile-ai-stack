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

# --- Slack-specific post-checks on the in-sandbox gateway log -----------------
# Socket Mode emits a `hello` event on a successful WSS handshake. Auth failures
# show invalid_auth / token_revoked / missing_scope / not_allowed_token_type.
# Benign churn (reconnect/ping/pong/rate-limit) is filtered BEFORE matching errors.
sleep 6   # let Socket Mode complete its WSS handshake (can take 3–8s under load)
gwlog="$(hermes_gateway_log_tail 60 || true)"

# A genuine Slack AUTH failure is fatal — do NOT let the caller (Phase 38) stamp
# success on it. Filter benign Socket-Mode churn (reconnect/ping/pong/429) first.
if grep -viE 'reconnect|disconnect|rate.?limit|\b429\b|ping|pong' <<<"$gwlog" \
   | grep -qiE 'invalid_auth|token_revoked|token_expired|account_inactive|missing_scope|not_allowed_token_type|invalid.?token'; then
  err "Slack AUTH error in the gateway log — check SLACK_BOT_TOKEN (xoxb-) / SLACK_APP_TOKEN (xapp-) and the app's OAuth scopes (re-install the Slack app after any scope change), then re-run 'vz-ai-stack.sh install 38'."
  exit 1
fi

# Positive proof (hello) vs blocked egress. Socket Mode emits a `hello` event on a
# successful WSS handshake; a blocked host shows policy_denied/refused. Failing on
# a clear block (and NOT on mere absence of hello) is what keeps a non-connected
# bot from being stamped "installed".
hello=0; blocked=0
grep -qiE '"?type"?[": ]*hello|socket.?mode.*(connect|open)|slack.*(connected|ready)' <<<"$gwlog" && hello=1
grep -qiE 'policy_denied|egress.*deni|connection refused|failed to (connect|establish)|getaddrinfo|name resolution' <<<"$gwlog" && blocked=1

if (( hello )); then
  ok "Slack Socket Mode connected (hello handshake seen in the gateway log)"
elif (( blocked )); then
  err "Slack Socket Mode could NOT connect — egress is BLOCKED (a Slack host is missing from the Phase 04 'slack' policy)."
  err "  See the denied host: openshell sandbox exec -n $HERMES_SANDBOX -- tail -60 $HERMES_GW_LOG | grep -iE 'denied|blocked'"
  err "  Add it to the 'slack' stanza in installer/phases/04_openshell.sh AND openshell/policies/hermes-fleet-v1.yaml, then re-run 'vz-ai-stack.sh install 38'."
  exit 1
else
  note "Slack 'hello' not yet confirmed (it can take a few seconds under load) — but no error seen. Verify with:"
  note "  openshell sandbox exec -n $HERMES_SANDBOX -- tail -40 $HERMES_GW_LOG | grep -i hello"
fi

pid="$(hermes_gateway_pid)"
ok "hermes gateway running in $HERMES_SANDBOX (PID $pid) — Slack channel active"
note "Status: openshell sandbox exec -n $HERMES_SANDBOX -- hermes gateway status"
note "Logs:   openshell sandbox exec -n $HERMES_SANDBOX -- tail -f $HERMES_GW_LOG"
note "Stop:   openshell sandbox exec -n $HERMES_SANDBOX -- hermes gateway stop"
