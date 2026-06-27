#!/usr/bin/env bash
# Phase 38 — Hermes Slack gateway (two-way, Socket Mode). OPT-IN.
#
# Adds Slack as a NATIVE channel on the SAME in-sandbox hermes gateway Phase 20
# points at Telegram. Nous Hermes runs every configured channel from ONE
# `hermes gateway run` process, so this phase just (1) writes the Slack tokens +
# allowlist into the sandbox's ~/.hermes config and (2) restarts the gateway —
# which then serves Telegram AND Slack. Slack uses SOCKET MODE (an OUTBOUND
# WebSocket to slack.com), so there is no inbound webhook / public URL; egress is
# allowlisted by Phase 04's `slack` network_policy.
#
# CONFIG (read from the HOST .env, never echoed):
#   HERMES_SLACK_BOT_TOKEN       (required)  Slack bot token  (xoxb-…)
#   HERMES_SLACK_APP_TOKEN       (required)  Slack app token  (xapp-…, Socket Mode, connections:write)
#   HERMES_SLACK_ALLOWED_USERS   (optional)  comma-list of Slack member IDs (U…) allowed to drive the fleet
#   HERMES_SLACK_ALLOW_ALL=true  (optional)  anyone in the workspace (NOT recommended)
#   HERMES_SLACK_HOME_CHANNEL    (optional)  channel ID (C…) for proactive/scheduled messages
#
# SECURITY: secure-by-default. With no allowlist AND no allow-all the Slack channel
# connects but DENIES every user — it stays silent until you set
# HERMES_SLACK_ALLOWED_USERS=<your_member_id> in .env and re-run this phase. The
# bot can drive all fleet profiles, so it must never be open by accident.
#
# Standalone:  bash vz-ai-stack.sh install 38   (aliases: hermes_slack, slack)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/hermes.sh"

PHASE=38
SANDBOX="$HERMES_SANDBOX"      # hermes-fleet-v1 (from lib/hermes.sh)

# Both Slack tokens present in the sandbox? (values never printed)
_slack_tokens_in_sandbox() {
  local osh="$1"
  "$osh" sandbox exec -n "$SANDBOX" --no-tty --timeout 20 -- \
    bash -c 'grep -q "^SLACK_BOT_TOKEN=." "$HOME/.hermes/.env" 2>/dev/null && grep -q "^SLACK_APP_TOKEN=." "$HOME/.hermes/.env" 2>/dev/null && echo YES || echo NO' \
    2>/dev/null | hermes_strip | tr -d '[:space:]'
}

# Read the EFFECTIVE Slack allowlist / allow-all from the sandbox. Slack config is
# stored in ~/.hermes/.env (hermes' save_env_value) — read that first, then fall
# back to config.yaml in case `hermes config set` routes it there. Never echoed
# elsewhere; compared, not printed.
_slack_get() {
  local osh="$1" key="$2"
  "$osh" sandbox exec -n "$SANDBOX" --no-tty --timeout 20 -- \
    bash -c "v=\$(grep -E \"^${key}=\" \"\$HOME/.hermes/.env\" 2>/dev/null | head -1 | cut -d= -f2-); [ -z \"\$v\" ] && v=\$(awk -F': *' '/^${key}:/{print \$2; exit}' \"\$HOME/.hermes/config.yaml\" 2>/dev/null); printf '%s' \"\$v\"" \
    2>/dev/null | hermes_strip | tr -d '[:space:]'
}

# Converge on declared allowlist state (the Phase-20 lesson: a precheck that passes
# on "token present + running" silently swallows allowlist edits on re-run).
_allowlist_in_sync() {
  local osh="$1" want_users want_all got_users got_all
  want_users="$(get_env HERMES_SLACK_ALLOWED_USERS '')"
  want_all="$(get_env HERMES_SLACK_ALLOW_ALL '')"
  got_users="$(_slack_get "$osh" SLACK_ALLOWED_USERS)"
  got_all="$(_slack_get "$osh" SLACK_ALLOW_ALL_USERS)"
  # Strip one surrounding quote pair if hermes ever YAML-quotes a value.
  got_users="${got_users#[\"\']}"; got_users="${got_users%[\"\']}"
  got_all="${got_all#[\"\']}";     got_all="${got_all%[\"\']}"
  if [[ -n "$want_users" ]]; then
    [[ "$got_users" == "$want_users" && "$got_all" != "true" ]] || return 1
  elif [[ "$want_all" == "true" ]]; then
    [[ "$got_all" == "true" ]] || return 1
  else
    [[ -z "$got_users" && "$got_all" != "true" ]] || return 1
  fi
  return 0
}

precheck() {
  local osh; osh="$(hermes_resolve_openshell)"; [[ -n "$osh" ]] || return 1
  [[ "$(_slack_tokens_in_sandbox "$osh")" == "YES" ]] || return 1
  "$osh" sandbox exec -n "$SANDBOX" --no-tty --timeout 25 -- hermes gateway status 2>&1 \
    | hermes_strip | grep -qi 'running' || return 1
  _allowlist_in_sync "$osh" || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 38 — Hermes Slack gateway — already running (Socket Mode)"
  exit 0
fi

hdr "Phase 38 — Hermes Slack gateway (two-way, Socket Mode)"

OSH="$(hermes_resolve_openshell)"; [[ -n "$OSH" ]] || { err "openshell not on PATH — run phase 04 first"; exit 1; }

# --- 1. Tokens (BOTH required) — from .env, never echoed ----------------------
BOT="$(get_env HERMES_SLACK_BOT_TOKEN '')"
APP="$(get_env HERMES_SLACK_APP_TOKEN '')"
if [[ -z "$BOT" || -z "$APP" ]]; then
  err "Slack needs BOTH HERMES_SLACK_BOT_TOKEN (xoxb-…) and HERMES_SLACK_APP_TOKEN (xapp-…) in .env."
  err "Create the app at https://api.slack.com/apps (see doc/HERMES-HANDSON.md §Slack), then re-run 'vz-ai-stack.sh install 38'."
  exit 1
fi
# Shape-check WITHOUT printing. Fail fast BEFORE touching the shared gateway so a
# malformed Slack token can never tear down Telegram via `run --replace`.
[[ "$BOT" == xoxb-* ]] || { err "HERMES_SLACK_BOT_TOKEN doesn't look like a bot token (expected xoxb-…)."; exit 1; }
[[ "$APP" == xapp-* ]] || { err "HERMES_SLACK_APP_TOKEN doesn't look like an app-level token (expected xapp-…, with the connections:write scope for Socket Mode)."; exit 1; }

# --- 2. Sandbox Ready + LIVE-APPLY the Slack egress policy (backstop) ---------
STATE="$(hermes_sandbox_state "$OSH")"
[[ "$STATE" == "Ready" ]] || { err "sandbox $SANDBOX not Ready (state='${STATE:-absent}') — run 'vz-ai-stack.sh install 04'"; exit 1; }
# Phase 04's heredoc is the SOURCE OF TRUTH for the policy; here we LIVE-APPLY it
# (the Phase-27 backstop pattern). Writing the YAML alone does NOT update the
# running sandbox's landlock egress — only `openshell policy set` does — so without
# this step Socket Mode would get policy_denied on every Slack host until the next
# `install 04`. Applying the FULL policy is safe: it's the complete file (all
# existing stanzas + slack), identical to what Phase 04 applies.
POLICY="$AI_STACK/openshell/policies/hermes-fleet-v1.yaml"
if [[ -f "$POLICY" ]] && grep -q 'name: slack' "$POLICY"; then
  log "Applying network policy (incl. Slack egress) to $SANDBOX (live backstop)..."
  "$OSH" policy set "$SANDBOX" --policy "$POLICY" --wait --timeout 60 >/dev/null 2>&1 \
    || warn "policy set returned non-zero — if Slack won't connect, re-run 'vz-ai-stack.sh install 04'"
else
  warn "policy file is missing a 'slack' stanza ($POLICY) — Slack egress may be blocked; re-run 'vz-ai-stack.sh install 04'."
fi

# --- 3. Push BOTH tokens into the sandbox (stdin, not argv/logs) --------------
log "Setting SLACK_BOT_TOKEN inside $SANDBOX (piped via stdin — not logged)..."
printf '%s' "$BOT" | "$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 30 -- \
  bash -c 'read -r T; hermes config set SLACK_BOT_TOKEN "$T" >/dev/null' >/dev/null 2>&1 \
  || { err "failed to set SLACK_BOT_TOKEN in sandbox"; exit 1; }
log "Setting SLACK_APP_TOKEN inside $SANDBOX (piped via stdin — not logged)..."
printf '%s' "$APP" | "$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 30 -- \
  bash -c 'read -r T; hermes config set SLACK_APP_TOKEN "$T" >/dev/null' >/dev/null 2>&1 \
  || { err "failed to set SLACK_APP_TOKEN in sandbox"; exit 1; }

# --- 4. Allowlist (secure-by-default) ----------------------------------------
ALLOW_USERS="$(get_env HERMES_SLACK_ALLOWED_USERS '')"
ALLOW_ALL="$(get_env HERMES_SLACK_ALLOW_ALL '')"
LOCKED=1
if [[ -n "$ALLOW_USERS" ]]; then
  # Slack member IDs start with U (user) or W (Enterprise Grid), comma-separated.
  if [[ "$ALLOW_USERS" =~ ^[UW][A-Z0-9]+(,[UW][A-Z0-9]+)*$ ]]; then
    "$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 30 -- \
      hermes config set SLACK_ALLOWED_USERS "$ALLOW_USERS" >/dev/null 2>&1 || warn "failed to set SLACK_ALLOWED_USERS"
    "$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 20 -- \
      hermes config set SLACK_ALLOW_ALL_USERS false >/dev/null 2>&1 || true
    ok "allowlist set: only Slack member id(s) [$ALLOW_USERS] may drive the fleet"
    LOCKED=0
  else
    err "HERMES_SLACK_ALLOWED_USERS must be Slack member id(s) (start with U or W), comma-separated."
    err "  Find yours in Slack: your profile → ⋮ (More) → Copy member ID."
    exit 1
  fi
elif [[ "$ALLOW_ALL" == "true" ]]; then
  "$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 30 -- \
    hermes config set SLACK_ALLOW_ALL_USERS true >/dev/null 2>&1 || warn "failed to set SLACK_ALLOW_ALL_USERS"
  warn "OPEN ACCESS (HERMES_SLACK_ALLOW_ALL=true) — anyone in the workspace can drive the fleet. Prefer HERMES_SLACK_ALLOWED_USERS."
  LOCKED=0
else
  # Desired = LOCKED. Clear any stale allowlist/open-access so it actually denies
  # all AND the precheck converges (no perpetual re-apply).
  "$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 20 -- \
    hermes config set SLACK_ALLOWED_USERS "" >/dev/null 2>&1 || true
  "$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 20 -- \
    hermes config set SLACK_ALLOW_ALL_USERS false >/dev/null 2>&1 || true
fi

# --- 5. Optional home channel ------------------------------------------------
HOME_CH="$(get_env HERMES_SLACK_HOME_CHANNEL '')"
if [[ -n "$HOME_CH" ]]; then
  if [[ "$HOME_CH" =~ ^[CGD][A-Z0-9]+$ ]]; then
    "$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 20 -- \
      hermes config set SLACK_HOME_CHANNEL "$HOME_CH" >/dev/null 2>&1 || warn "failed to set SLACK_HOME_CHANNEL"
  else
    warn "HERMES_SLACK_HOME_CHANNEL='$HOME_CH' doesn't look like a channel id (C…/G…/D…) — skipping."
  fi
fi

# --- 6. Verify BOTH tokens landed (grep, never cat) --------------------------
if [[ "$(_slack_tokens_in_sandbox "$OSH")" != "YES" ]]; then
  err "Slack tokens not both found in sandbox ~/.hermes/.env after set — aborting."
  exit 1
fi
ok "Slack tokens configured in $SANDBOX (~/.hermes/.env, values not logged)"

# --- 7. Start/restart the gateway (serves Slack + any other channel) ---------
log "Starting the Slack gateway (Socket Mode)..."
bash "$AI_STACK/bin/start-hermes-slack.sh" || { err "gateway failed to start"; exit 1; }

stamp_mark "$PHASE"
record "phase 38 complete: hermes slack gateway (Socket Mode) running in $SANDBOX; locked=$LOCKED"
ok "Phase 38 — Hermes Slack gateway — complete"
if [[ "$LOCKED" == "1" ]]; then
  echo ""
  warn "════════════════════════════════════════════════════════════════════"
  warn " SLACK BOT IS LOCKED: no allowlist configured → it will DENY every user."
  warn " The gateway is connected to Slack, but won't respond until you:"
  warn "   1. In Slack: your profile → ⋮ (More) → Copy member ID (U…)"
  warn "   2. Add to .env:   HERMES_SLACK_ALLOWED_USERS=<your_member_id>"
  warn "   3. Re-run:        bash vz-ai-stack.sh install 38"
  warn "════════════════════════════════════════════════════════════════════"
else
  note "DM your Hermes app in Slack (or @mention it in a channel it's in) — it routes to the fleet."
fi
note "Status: openshell sandbox exec -n $SANDBOX -- hermes gateway status"
note "Logs:   openshell sandbox exec -n $SANDBOX -- tail -f $HERMES_GW_LOG"
note "Stop:   openshell sandbox exec -n $SANDBOX -- hermes gateway stop"
