# Hermes Telegram gateway healthy (Phase 20).
#
# Verifies the native hermes gateway (bot @vz_hermes_controller_bot) is running
# INSIDE hermes-fleet-v1 and its token is configured there. Skips cleanly
# (passes) when HERMES_TELEGRAM_BOT_TOKEN isn't set — the gateway is an optional
# add-on. NEVER prints the token and makes NO external Telegram API call (it only
# reads in-sandbox `hermes gateway status` + the in-sandbox gateway log).
CHECKS+=(hermes_telegram)
CHECK_TITLE[hermes_telegram]="Hermes Telegram gateway running (Phase 20, @vz_hermes_controller_bot)"
FIX_CAPABLE[hermes_telegram]=1   # <name>_fix MUTATES state (see doctor.sh FIX_CAPABLE)

_htg_resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell; else echo ""; fi
}

hermes_telegram_diagnose() {
  local tok; tok="$(get_env HERMES_TELEGRAM_BOT_TOKEN '' 2>/dev/null)"
  if [[ -z "$tok" ]]; then
    echo "HERMES_TELEGRAM_BOT_TOKEN not set — Telegram gateway not configured. [skip]"
    return 0
  fi

  local osh; osh="$(_htg_resolve_openshell)"
  if [[ -z "$osh" ]]; then
    echo "openshell CLI not found (Phase 04 not complete)"
    return 1
  fi
  # Sandbox must be Ready to probe.
  local state
  state="$("$osh" sandbox get hermes-fleet-v1 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | awk '/^[[:space:]]*Phase:/ {print $2; exit}')"
  if [[ "$state" != "Ready" ]]; then
    echo "sandbox hermes-fleet-v1 not Ready (state='${state:-absent}') — run 'mayssam-ai-stack.sh install 04'"
    return 1
  fi

  # Gateway daemon alive inside the sandbox?
  local status
  status="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 25 -- hermes gateway status 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')"
  if ! grep -qi 'running' <<<"$status"; then
    echo "gateway not running in sandbox — start: bash $AI_STACK/bin/start-hermes-telegram.sh (or 'mayssam-ai-stack.sh install 20')"
    return 1
  fi

  # Token present inside the sandbox? (value never printed)
  local has
  has="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 -- \
    bash -c 'grep -q "^TELEGRAM_BOT_TOKEN=." "$HOME/.hermes/.env" 2>/dev/null && echo YES || echo NO' \
    2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
  if [[ "$has" == "NO" ]]; then
    echo "gateway up but TELEGRAM_BOT_TOKEN not in sandbox ~/.hermes/.env — re-run 'mayssam-ai-stack.sh install 20'"
    return 1
  fi

  # Genuine auth errors in the in-sandbox gateway log are hard failures. Two
  # benign patterns are excluded first:
  #   - "409 conflict": `run --replace` always emits a transient 409 while
  #     Telegram expires the prior long-poll (~50s); it self-heals.
  #   - the allowlist warning ("All unauthorized users will be denied") contains
  #     the word "unauthorized" but is NOT an auth failure — filter it out so it
  #     doesn't false-match the regex below.
  local gwlog
  gwlog="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 -- bash -c 'tail -40 /sandbox/.hermes-gateway.log 2>/dev/null' 2>&1 | sed $'s/\x1b\\[[0-9;]*m//g')"
  # Drop benign lines first: the allowlist warning (contains "unauthorized" but
  # is not a failure) AND the transient 409/conflict/reconnect churn that
  # `run --replace` emits while Telegram expires the prior long-poll (self-heals).
  # Then match only REAL auth-failure shapes — a bare "401" appears in benign
  # contexts, so anchor to Telegram's actual error wording instead.
  if grep -viE 'allowlist|users will be denied|409|conflict|reconnect' <<<"$gwlog" \
    | grep -qiE 'unauthorized|invalid token|error_code["[:space:]:]*401'; then
    echo "gateway log shows an auth error — the bot token may be revoked or malformed"
    return 1
  fi

  # Locked (no allowlist) is SECURE but means the bot denies everyone — surface it.
  local allow_users allow_all
  allow_users="$(get_env HERMES_TELEGRAM_ALLOWED_USERS '' 2>/dev/null)"
  allow_all="$(get_env HERMES_TELEGRAM_ALLOW_ALL '' 2>/dev/null)"
  if [[ -z "$allow_users" && "$allow_all" != "true" ]]; then
    echo "  (running but LOCKED: no allowlist → denies all users. Set HERMES_TELEGRAM_ALLOWED_USERS=<your_id> in .env + re-run 'install 20')"
    return 0
  fi
  if [[ -n "$allow_users" ]]; then
    echo "  (running; allowlisted to Telegram id(s) [$allow_users])"
  else
    echo "  (running; OPEN ACCESS — HERMES_TELEGRAM_ALLOW_ALL=true)"
  fi
  return 0
}

hermes_telegram_fix() {
  warn "Restart the Telegram gateway:"
  warn "    bash $AI_STACK/bin/start-hermes-telegram.sh"
  warn "Or re-run the phase:  bash $AI_STACK/mayssam-ai-stack.sh install 20"
  bash "$AI_STACK/bin/start-hermes-telegram.sh" >/dev/null 2>&1 || true
  return 1
}
