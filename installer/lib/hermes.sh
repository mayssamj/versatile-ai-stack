#!/usr/bin/env bash
# installer/lib/hermes.sh — shared helpers for the Hermes messaging gateway.
#
# The native hermes gateway runs INSIDE the hermes-fleet-v1 OpenShell sandbox and
# serves EVERY configured channel from a SINGLE process (`hermes gateway run`).
# Telegram is wired by Phase 20, Slack by Phase 38 — both restart this one gateway,
# so the restart primitive lives here (ONE place) and each phase/start-script does
# only its own channel-specific log post-checks.
#
# NOT a standalone script — `source` it AFTER installer/lib/common.sh (it uses err).

# Allow callers to override, but default to the fleet sandbox + its gateway log.
HERMES_SANDBOX="${HERMES_SANDBOX:-hermes-fleet-v1}"
HERMES_GW_LOG="${HERMES_GW_LOG:-/sandbox/.hermes-gateway.log}"   # in-sandbox path

# Drop NULs (hermes' box-draw banner) + ANSI so downstream grep/awk are robust.
hermes_strip() { tr -d '\000' | sed $'s/\x1b\\[[0-9;]*m//g'; }

hermes_resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell; else echo ""; fi
}

# Echo the sandbox's Phase state (e.g. "Ready"); empty if absent.
hermes_sandbox_state() {
  local osh="$1"
  "$osh" sandbox get "$HERMES_SANDBOX" 2>/dev/null | hermes_strip \
    | awk '/^[[:space:]]*Phase:/ {print $2; exit}'
}

# Tail the in-sandbox gateway log (channel post-checks read this). $1 = lines (25).
hermes_gateway_log_tail() {
  local osh n="${1:-25}"; osh="$(hermes_resolve_openshell)"; [[ -n "$osh" ]] || return 1
  "$osh" sandbox exec -n "$HERMES_SANDBOX" --no-tty --timeout 20 -- \
    bash -c "tail -$n $HERMES_GW_LOG 2>/dev/null" 2>&1 | hermes_strip
}

# Best-effort PID from a `hermes gateway status` string ('?' if absent).
hermes_gateway_pid() {
  grep -oiE 'PID:? *[0-9]+' <<<"${1:-${HERMES_GW_STATUS:-}}" | grep -oE '[0-9]+' | head -1 || echo '?'
}

# (Re)start the ONE gateway so it re-reads ~/.hermes/.env + config.yaml and serves
# EVERY configured channel. Idempotent: `run --replace` tears down any prior gateway
# and ends with exactly one running. CHANNEL-AGNOSTIC — callers do their own per-
# channel log post-checks. On success returns 0 and leaves the status text in
# HERMES_GW_STATUS; on failure returns 1 (HERMES_GW_STATUS still holds what we saw).
hermes_gateway_restart() {
  local osh; osh="$(hermes_resolve_openshell)"
  [[ -n "$osh" ]] || { err "openshell not on PATH — run phase 04"; return 1; }

  local state; state="$(hermes_sandbox_state "$osh")"
  if [[ "$state" != "Ready" ]]; then
    err "sandbox $HERMES_SANDBOX not Ready (state='${state:-absent}') — OpenShell relay down? 'brew services restart openshell'"
    return 1
  fi

  # Detach inside the sandbox: nohup + disown so the exec returns while the gateway
  # persists (reparented to the container init). --replace ensures exactly one.
  "$osh" sandbox exec -n "$HERMES_SANDBOX" --no-tty --timeout 45 -- \
    bash -c "nohup hermes gateway run --replace >$HERMES_GW_LOG 2>&1 & disown; sleep 4; echo detached" \
    >/dev/null 2>&1 || { err "failed to launch gateway in sandbox $HERMES_SANDBOX"; return 1; }

  sleep 2
  HERMES_GW_STATUS="$("$osh" sandbox exec -n "$HERMES_SANDBOX" --no-tty --timeout 30 -- hermes gateway status 2>&1 | hermes_strip)"
  grep -qi 'running' <<<"$HERMES_GW_STATUS"
}
