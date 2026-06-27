# Hermes Slack gateway healthy (Phase 38).
#
# Verifies the native hermes gateway is serving Slack (Socket Mode) INSIDE
# hermes-fleet-v1 and BOTH Slack tokens are configured there. Skips cleanly
# (passes) when HERMES_SLACK_BOT_TOKEN isn't set — Slack is an opt-in add-on.
# NEVER prints the tokens and makes NO external Slack API call (it only reads
# in-sandbox `hermes gateway status` + the in-sandbox gateway log).
#
# Liveness model: assert gateway running + both tokens present + NO auth error +
# NO blocked egress. We do NOT require the Socket-Mode `hello` event here (it is
# emitted once at connect and scrolls out of the log tail on a long-running
# gateway — requiring it would false-fail a healthy bot). The positive `hello`
# proof is asserted by bin/start-hermes-slack.sh at (re)start time instead.
CHECKS+=(hermes_slack)
CHECK_TITLE[hermes_slack]="Hermes Slack gateway running (Phase 38, Socket Mode)"

_hsg_resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell; else echo ""; fi
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

  # Gateway daemon alive inside the sandbox?
  local status
  status="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 25 -- hermes gateway status 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')"
  if ! grep -qi 'running' <<<"$status"; then
    echo "gateway not running in sandbox — start: bash $AI_STACK/bin/start-hermes-slack.sh (or 'vz-ai-stack.sh install 38')"
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

  # Genuine Slack auth errors are hard failures. Filter benign Socket-Mode churn
  # first (reconnect/ping/pong/rate-limit) so it can't false-match below.
  local gwlog
  gwlog="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 -- bash -c 'tail -120 /sandbox/.hermes-gateway.log 2>/dev/null' 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')"
  if grep -viE 'reconnect|disconnect|rate.?limit|\b429\b|ping|pong' <<<"$gwlog" \
     | grep -qiE 'invalid_auth|token_revoked|token_expired|account_inactive|missing_scope|not_allowed_token_type'; then
    echo "gateway log shows a Slack auth error — a token may be revoked/malformed or the app is missing a scope (re-install the Slack app after scope changes)"
    return 1
  fi

  # Blocked egress = Socket Mode can't connect even though the process is up.
  if grep -qiE 'policy_denied|egress.*deni' <<<"$gwlog"; then
    echo "gateway log shows BLOCKED egress — a Slack host is missing from the Phase 04 'slack' policy (tail /sandbox/.hermes-gateway.log | grep denied)"
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
    echo "  (running; OPEN ACCESS — HERMES_SLACK_ALLOW_ALL=true)"
  fi
  return 0
}

hermes_slack_fix() {
  warn "Restart the Slack gateway:  bash $AI_STACK/bin/start-hermes-slack.sh"
  warn "Or re-run the phase:        bash $AI_STACK/vz-ai-stack.sh install 38"
  bash "$AI_STACK/bin/start-hermes-slack.sh" >/dev/null 2>&1 || true
  return 1
}
