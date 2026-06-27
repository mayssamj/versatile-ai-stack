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
sleep 3   # let Socket Mode attempt its handshake
gwlog="$(hermes_gateway_log_tail 40 || true)"

if grep -viE 'reconnect|disconnect|rate.?limit|\b429\b|ping|pong' <<<"$gwlog" \
   | grep -qiE 'invalid_auth|token_revoked|token_expired|account_inactive|missing_scope|not_allowed_token_type|invalid.?token'; then
  warn "gateway log shows a Slack AUTH error — check SLACK_BOT_TOKEN (xoxb-) / SLACK_APP_TOKEN (xapp-) and the app's scopes, then re-run 'vz-ai-stack.sh install 38'."
fi
if grep -qiE 'policy_denied|egress.*deni|connection refused|failed to (connect|establish)|getaddrinfo|name resolution' <<<"$gwlog"; then
  warn "gateway log shows a BLOCKED connection — the Phase 04 'slack' egress policy may be missing a host."
  warn "  Find it: openshell sandbox exec -n $HERMES_SANDBOX -- tail -60 $HERMES_GW_LOG | grep -iE 'denied|blocked'"
fi
if grep -qiE '"?type"?[": ]*hello|socket.?mode.*(connect|open)|slack.*(connected|ready)' <<<"$gwlog"; then
  ok "Slack Socket Mode connected (hello handshake seen in the gateway log)"
fi

pid="$(hermes_gateway_pid)"
ok "hermes gateway running in $HERMES_SANDBOX (PID $pid) — Slack channel active"
note "Status: openshell sandbox exec -n $HERMES_SANDBOX -- hermes gateway status"
note "Logs:   openshell sandbox exec -n $HERMES_SANDBOX -- tail -f $HERMES_GW_LOG"
note "Stop:   openshell sandbox exec -n $HERMES_SANDBOX -- hermes gateway stop"
