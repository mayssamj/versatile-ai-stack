#!/usr/bin/env bash
# start-hermes-telegram.sh — (re)start hermes-agent's NATIVE Telegram gateway for
# the fleet, bound to @vz_hermes_controller_bot.
#
# ARCHITECTURE: the gateway runs INSIDE the hermes-fleet-v1 OpenShell sandbox and
# is self-persisting — a process started in the sandbox is reparented to the
# container's init and keeps running after the launching `exec` stream closes
# (verified: it survives host disconnect). Its Telegram long-poll goes
# container → api.telegram.org DIRECTLY (Phase 04 `telegram` egress policy), NOT
# through the OpenShell relay, so it also survives the relay's idle-timeout. So
# there is NO host daemon and NO host PID file: hermes' own `gateway
# status/stop/restart` (inside the sandbox) is the lifecycle handle.
#
# This script just (re)starts it idempotently with `run --replace` (ends with
# exactly one gateway running the latest ~/.hermes/.env config) and verifies it
# came up. Token + allowlist must already be in the sandbox (Phase 20 writes them).
set -Eeuo pipefail
if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do [[ -x "$b" ]] && exec "$b" "$0" "$@"; done
  echo "needs bash 5+" >&2; exit 2
fi
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

SANDBOX=hermes-fleet-v1
GW_LOG=/sandbox/.hermes-gateway.log   # in-sandbox path

resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell; else echo ""; fi
}
OSH="$(resolve_openshell)"; [[ -n "$OSH" ]] || { err "openshell not on PATH — run phase 04"; exit 1; }

_strip() { tr -d '\000' | sed $'s/\x1b\\[[0-9;]*m//g'; }   # drop NULs (hermes' box-draw banner) + ANSI

# Sandbox must be Ready (relay up) to issue the start exec.
state="$("$OSH" sandbox get "$SANDBOX" 2>/dev/null | _strip | awk '/^[[:space:]]*Phase:/ {print $2; exit}')"
[[ "$state" == "Ready" ]] || { err "sandbox $SANDBOX not Ready (state='${state:-absent}') — OpenShell relay down? 'brew services restart openshell'"; exit 1; }

log "(Re)starting hermes Telegram gateway inside $SANDBOX (config from ~/.hermes/.env)..."
# Detach inside the sandbox: nohup + disown so the exec returns while the gateway
# persists. --replace tears down any prior gateway first (idempotent).
"$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 45 -- \
  bash -c "nohup hermes gateway run --replace >$GW_LOG 2>&1 & disown; sleep 4; echo detached" \
  >/dev/null 2>&1 || { err "failed to launch gateway in sandbox"; exit 1; }

sleep 2
status="$("$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 30 -- hermes gateway status 2>&1 | _strip)"
if ! grep -qi 'running' <<<"$status"; then
  err "gateway did not come up. status:"; echo "$status" >&2
  err "log tail:"; "$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 20 -- bash -c "tail -15 $GW_LOG 2>/dev/null" 2>&1 | _strip >&2 || true
  exit 1
fi

# Surface auth/allowlist signals from the in-sandbox log. NOTE: we do NOT flag
# "409 conflict" — `run --replace` always produces a transient 409 while Telegram
# expires the prior instance's long-poll (~50s); it self-heals. Only genuine auth
# failures (unauthorized / invalid token / 401) are real problems.
gwlog="$("$OSH" sandbox exec -n "$SANDBOX" --no-tty --timeout 20 -- bash -c "tail -25 $GW_LOG 2>/dev/null" 2>&1 | _strip || true)"
# Filter the benign allowlist warning ("All unauthorized users will be denied")
# before matching — it contains "unauthorized" but is not an auth failure.
if grep -viE 'allowlist|users will be denied' <<<"$gwlog" | grep -qiE 'unauthorized|invalid token|\b401\b'; then
  warn "gateway log shows an auth error — the bot token may be revoked or malformed. Check the token in .env."
fi
if grep -qi 'No user allowlists configured' <<<"$gwlog"; then
  warn "Bot is LOCKED: no allowlist → all users denied. Set HERMES_TELEGRAM_ALLOWED_USERS=<your_telegram_id> in .env + re-run 'vz-ai-stack.sh install 20'."
fi
pid="$(grep -oiE 'PID: *[0-9]+' <<<"$status" | grep -oE '[0-9]+' | head -1 || echo '?')"
ok "hermes Telegram gateway running in $SANDBOX (PID $pid) — @vz_hermes_controller_bot polling api.telegram.org"
note "Status: openshell sandbox exec -n $SANDBOX -- hermes gateway status"
note "Stop:   openshell sandbox exec -n $SANDBOX -- hermes gateway stop"
note "Logs:   openshell sandbox exec -n $SANDBOX -- tail -f $GW_LOG"
