#!/usr/bin/env bash
# Phase 20 — Hermes Telegram gateway (bot @vz_hermes_controller_bot).
#
# hermes-agent ships a NATIVE multi-platform gateway (`hermes gateway run`). This
# phase points it at Telegram so you can DM the bot to reach the whole fleet from
# your phone. The gateway runs INSIDE the hermes-fleet-v1 sandbox (long-polling
# api.telegram.org — allowlisted by Phase 04's `telegram` network_policy) and is
# held alive by a HOST daemon (bin/start-hermes-telegram.sh) since the sandbox has
# no init system.
#
# CONFIG (all read from the HOST .env, never echoed):
#   HERMES_TELEGRAM_BOT_TOKEN        (required)  bot token from @BotFather
#   HERMES_TELEGRAM_ALLOWED_USERS    (optional)  comma-list of numeric Telegram
#                                                user IDs allowed to drive the fleet
#   HERMES_TELEGRAM_ALLOW_ALL=true   (optional)  open access — anyone who finds the
#                                                bot can use it (NOT recommended)
#
# SECURITY: the gateway is secure-by-default. With no allowlist AND no allow-all,
# it connects but DENIES every user — the bot stays silent until you set
# HERMES_TELEGRAM_ALLOWED_USERS=<your_id> in .env and re-run this phase. This is
# deliberate: the bot can drive 7 agent profiles, so it must not be open by accident.
#
# Standalone:  bash install.sh install 20
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

PHASE=20
SANDBOX=hermes-fleet-v1
GW_LOG=/sandbox/.hermes-gateway.log   # in-sandbox path

resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell; else echo ""; fi
}

# Does the sandbox's ~/.hermes/.env already carry the bot token? (value never printed)
_token_in_sandbox() {
  local osh="$1"
  "$osh" sandbox exec -n "$SANDBOX" --no-tty --timeout 20 -- \
    bash -c 'grep -q "^TELEGRAM_BOT_TOKEN=." "$HOME/.hermes/.env" 2>/dev/null && echo YES || echo NO' \
    2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]'
}

# Is the in-sandbox gateway running? (hermes tracks its own daemon)
_gateway_running() {
  local osh="$1"
  "$osh" sandbox exec -n "$SANDBOX" --no-tty --timeout 25 -- hermes gateway status 2>&1 \
    | sed $'s/\x1b\\[[0-9;]*m//g' | grep -qi 'running'
}

precheck() {
  local osh; osh="$(resolve_openshell)"; [[ -n "$osh" ]] || return 1
  [[ "$(_token_in_sandbox "$osh")" == "YES" ]] || return 1
  _gateway_running "$osh" || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 20 — Hermes Telegram gateway — already running (@vz_hermes_controller_bot)"
  exit 0
fi

hdr "Phase 20 — Hermes Telegram gateway (@vz_hermes_controller_bot)"

OSH="$(resolve_openshell)"; [[ -n "$OSH" ]] || { err "openshell not on PATH — run phase 04 first"; exit 1; }

# --- 1. Token (required) — read from .env, never echo ---------------------
TGT="$(get_env HERMES_TELEGRAM_BOT_TOKEN '')"
if [[ -z "$TGT" ]]; then
  err "HERMES_TELEGRAM_BOT_TOKEN missing from .env."
  err "Add it (from @BotFather for @vz_hermes_controller_bot) then re-run 'install.sh install 20'."
  exit 1
fi
# Sanity-check shape WITHOUT printing the value: Telegram tokens are <id>:<secret>.
if [[ "$TGT" != *:* ]]; then
  err "HERMES_TELEGRAM_BOT_TOKEN does not look like a Telegram token (expected <id>:<secret>)."
  exit 1
fi

# --- 2. Sandbox must be Ready (relay up) ----------------------------------
STATE="$("$OSH" sandbox get "$SANDBOX" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | awk '/^[[:space:]]*Phase:/ {print $2; exit}')"
[[ "$STATE" == "Ready" ]] || { err "sandbox $SANDBOX not Ready (state='${STATE:-absent}') — run 'install.sh install 04' (OpenShell relay down? 'brew services restart openshell')"; exit 1; }

# Confirm Phase 04 wired the Telegram egress policy (else long-poll is blocked).
if ! "$OSH" sandbox get "$SANDBOX" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | grep -qi 'telegram'; then
  warn "no 'telegram' network_policy on $SANDBOX — api.telegram.org egress may be blocked."
  warn "Re-run 'install.sh install 04' to apply the policy, then re-run this phase."
fi

# --- 3. Push the token into the sandbox's ~/.hermes/.env (stdin, not argv) -
log "Setting TELEGRAM_BOT_TOKEN inside $SANDBOX (piped via stdin — not logged)..."
printf '%s' "$TGT" | "$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 30 -- \
  bash -c 'read -r T; hermes config set TELEGRAM_BOT_TOKEN "$T" >/dev/null' \
  >/dev/null 2>&1 || { err "failed to set TELEGRAM_BOT_TOKEN in sandbox"; exit 1; }

# --- 4. Allowlist (secure-by-default) -------------------------------------
ALLOW_USERS="$(get_env HERMES_TELEGRAM_ALLOWED_USERS '')"
ALLOW_ALL="$(get_env HERMES_TELEGRAM_ALLOW_ALL '')"
LOCKED=1
if [[ -n "$ALLOW_USERS" ]]; then
  # Numeric IDs, comma-separated (e.g. "12345678" or "12345678,87654321"). Validate.
  if [[ "$ALLOW_USERS" =~ ^[0-9]+(,[0-9]+)*$ ]]; then
    "$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 30 -- \
      hermes config set TELEGRAM_ALLOWED_USERS "$ALLOW_USERS" >/dev/null 2>&1 \
      || warn "failed to set TELEGRAM_ALLOWED_USERS"
    # Clear any prior allow-all so the allowlist actually constrains.
    "$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 20 -- \
      hermes config set GATEWAY_ALLOW_ALL_USERS false >/dev/null 2>&1 || true
    ok "allowlist set: only Telegram user id(s) [$ALLOW_USERS] may drive the fleet"
    LOCKED=0
  else
    err "HERMES_TELEGRAM_ALLOWED_USERS must be numeric Telegram user id(s), comma-separated."
    err "  Got a non-numeric value. (Find your id by DMing @userinfobot on Telegram.)"
    exit 1
  fi
elif [[ "$ALLOW_ALL" == "true" ]]; then
  "$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 30 -- \
    hermes config set GATEWAY_ALLOW_ALL_USERS true >/dev/null 2>&1 \
    || warn "failed to set GATEWAY_ALLOW_ALL_USERS"
  warn "OPEN ACCESS enabled (HERMES_TELEGRAM_ALLOW_ALL=true) — ANYONE who finds"
  warn "@vz_hermes_controller_bot can drive your fleet. Prefer HERMES_TELEGRAM_ALLOWED_USERS."
  LOCKED=0
fi

# --- 5. Verify the token landed (grep, never cat) -------------------------
if [[ "$(_token_in_sandbox "$OSH")" != "YES" ]]; then
  err "TELEGRAM_BOT_TOKEN not found in sandbox ~/.hermes/.env after set — aborting."
  exit 1
fi
ok "bot token configured in $SANDBOX (~/.hermes/.env, value not logged)"

# --- 6. Start the gateway daemon ------------------------------------------
log "Starting the Telegram gateway daemon..."
bash "$AI_STACK/bin/start-hermes-telegram.sh" || { err "gateway daemon failed to start"; exit 1; }

stamp_mark "$PHASE"
record "phase 20 complete: hermes telegram gateway (@vz_hermes_controller_bot) running in $SANDBOX; locked=$LOCKED"
ok "Phase 20 — Hermes Telegram gateway — complete"
if [[ "$LOCKED" == "1" ]]; then
  echo ""
  warn "════════════════════════════════════════════════════════════════════"
  warn " BOT IS LOCKED: no allowlist configured → it will DENY every user."
  warn " The gateway is connected to Telegram, but won't respond until you:"
  warn "   1. DM @userinfobot on Telegram to get your numeric user id"
  warn "   2. Add to .env:   HERMES_TELEGRAM_ALLOWED_USERS=<your_id>"
  warn "   3. Re-run:        bash install.sh install 20"
  warn " (Or set HERMES_TELEGRAM_ALLOW_ALL=true for open access — not advised.)"
  warn "════════════════════════════════════════════════════════════════════"
else
  note "DM @vz_hermes_controller_bot on Telegram — it routes to the Hermes fleet."
fi
note "Status: openshell sandbox exec -n $SANDBOX -- hermes gateway status"
note "Logs:   openshell sandbox exec -n $SANDBOX -- tail -f $GW_LOG"
note "Stop:   openshell sandbox exec -n $SANDBOX -- hermes gateway stop"
