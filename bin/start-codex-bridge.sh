#!/usr/bin/env bash
# start-codex-bridge.sh — managed launcher for the Codex bridge: lets the stack
# use your ChatGPT Plus/Pro SUBSCRIPTION (no metered API key) for GPT-5.x from
# Open WebUI, mirroring how bin/start-meridian.sh does it for the Claude plan.
#
# WHY THIS EXISTS
#   Open WebUI (container) → LiteLLM (container) → codex-bridge (host :3457) →
#   your `codex login` OAuth → ChatGPT backend. The bridge is the `openai-oauth`
#   proxy (npx), which reads the OAuth token Codex CLI caches in
#   ~/.codex/auth.json (auto-refreshed), translates /v1/chat/completions to the
#   Codex Responses backend, and exposes an OpenAI-compatible API. LiteLLM dials
#   it exactly like Meridian/LM Studio (host.docker.internal:3457) — see the
#   `*-sub` GPT entries in litellm/config.yaml. Loopback-only (127.0.0.1, NOT
#   0.0.0.0): it fronts a live OAuth to your PERSONAL ChatGPT account — never
#   expose it off-box.
#
# ⚠ UNOFFICIAL + ToS-GRAY (unlike Meridian, which uses Anthropic's OFFICIAL SDK):
#   this wraps the ChatGPT *product* backend (chatgpt.com/backend-api/codex),
#   which is NOT the published OpenAI API. OpenAI's terms restrict automated
#   access; there is a real, non-recoverable risk of your ChatGPT account being
#   suspended. SINGLE PERSONAL ACCOUNT ONLY — pooling/sharing accounts is a clear
#   ToS violation. The metered OPENAI_API_KEY path (openai-gpt-5.5/5.4) is the
#   supported default; this only avoids metered cost. `install` requires you to
#   acknowledge this once.
#
# DAEMON, not a timer: launchd job uses RunAtLoad + KeepAlive (restarts on crash
# or after login) + ThrottleInterval (caps crash-loop churn).
#
# Self-contained on purpose (launchd runs with a minimal PATH and no shell
# profile) — it resolves its own binaries and does not source the installer libs.
#
# Usage: start-codex-bridge.sh [enable|run|install|uninstall|status|stop|restart]
#   enable     ONE COMMAND: codex login (if needed) + install + reload LiteLLM
#   install    acknowledge risk, write + load the launchd job (always-on)
#   uninstall  unload + remove the launchd job (and stop the daemon)
#   status     launchd state + live /v1/models health probe
#   stop       kill any running bridge on the port (launchd respawns if loaded)
#   restart    stop, then bootstrap/kick the launchd job
#   run        exec the bridge in the foreground (this is what launchd calls)
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "bin/start-codex-bridge.sh: needs bash 5+" >&2; exit 2
fi

AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="$AI_STACK/installer/state"
LOG="$STATE/codex-bridge.launchd.log"
PLIST="$HOME/Library/LaunchAgents/com.ai-stack.codex-bridge.plist"
LABEL="com.ai-stack.codex-bridge"

# Tunables. Loopback bind is intentional. Port 3457 sits one above Meridian
# (3456) — keep them distinct.
PORT="${CODEX_BRIDGE_PORT:-3457}"
HOST_BIND="${CODEX_BRIDGE_HOST:-127.0.0.1}"
# The proxy package run via npx. PIN this to an audited version once you've
# reviewed it (e.g. openai-oauth@1.2.3) — it fronts your ChatGPT OAuth, so treat
# it as a trusted dependency. Override with CODEX_BRIDGE_PKG to swap/vendor.
CODEX_BRIDGE_PKG="${CODEX_BRIDGE_PKG:-openai-oauth}"
# Codex CLI caches the ChatGPT OAuth here after `npx @openai/codex login`.
AUTH_FILE="${CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"

mkdir -p "$STATE" "$HOME/Library/LaunchAgents"

# Resolve binaries without a login shell (launchd has a minimal PATH).
_find() { for p in "$@"; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done; command -v "$(basename "$1")" 2>/dev/null || echo ""; }
NPX_BIN="$(_find /opt/homebrew/bin/npx /usr/local/bin/npx "$HOME/.openagents/nodejs/bin/npx")"
NODE_BIN="$(_find /opt/homebrew/bin/node /usr/local/bin/node "$HOME/.openagents/nodejs/bin/node")"
NODE_DIR=""; [[ -n "$NODE_BIN" ]] && NODE_DIR="$(dirname "$NODE_BIN")"
RUN_PATH="${NODE_DIR:+$NODE_DIR:}/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Is something already listening on the port?
_listening() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; }
# `|| true`: lsof exits 1 when nothing matches; a bare assignment would inherit
# that and trip `set -e`. _listening stays guarded (if/&&).
_pids()      { lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true; }

# Probe the live endpoint (static /v1/models, no real token needed for liveness).
_healthy() {
  curl -s -m 5 -o /dev/null -w '%{http_code}' \
    "http://$HOST_BIND:$PORT/v1/models" -H "Authorization: Bearer x" 2>/dev/null | grep -q '^200$'
}

# auth.json must exist + be non-empty before we install the daemon, else the
# proxy boots straight into a 401 crash-loop. Mirrors Meridian's `claude login`
# precondition. Also assert it isn't group/world-readable (it holds an OAuth).
_require_auth() {
  if [[ ! -s "$AUTH_FILE" ]]; then
    echo "codex-bridge: no ChatGPT auth at $AUTH_FILE" >&2
    echo "  Run this first (opens a browser, 'Sign in with ChatGPT'):" >&2
    echo "    npx --yes @openai/codex login" >&2
    return 1
  fi
  # Tighten perms if a previous tool left them open. 0600 = owner-only.
  local mode; mode="$(stat -f '%Lp' "$AUTH_FILE" 2>/dev/null || echo '')"
  if [[ -n "$mode" && "$mode" != "600" ]]; then
    chmod 600 "$AUTH_FILE" 2>/dev/null \
      && echo "codex-bridge: tightened $AUTH_FILE to 0600 (was 0$mode)" \
      || echo "codex-bridge: WARNING could not chmod 600 $AUTH_FILE (was 0$mode)" >&2
  fi
  return 0
}

# One-time, blocking risk acknowledgement on `install`. Bypass for automation
# with CODEX_BRIDGE_ACCEPT_RISK=1. NEVER shown on the launchd `run` path.
_risk_ack() {
  [[ "${CODEX_BRIDGE_ACCEPT_RISK:-0}" == "1" ]] && return 0
  cat >&2 <<'BANNER'

  ┌────────────────────────────────────────────────────────────────────┐
  │  ⚠  CODEX BRIDGE — READ BEFORE ENABLING                             │
  │                                                                    │
  │  This routes GPT-5.x through your ChatGPT subscription via the      │
  │  ChatGPT *product* backend (chatgpt.com/backend-api/codex) — NOT    │
  │  the published OpenAI API. This is UNOFFICIAL automated use.        │
  │                                                                    │
  │   • Real, non-recoverable risk: OpenAI may SUSPEND this ChatGPT     │
  │     account (the one you use interactively every day).             │
  │   • SINGLE PERSONAL ACCOUNT ONLY. Pooling/sharing = clear ToS       │
  │     violation. Do not.                                             │
  │   • It can break without notice when OpenAI changes the backend.   │
  │   • Plan-rate-limited (Plus ≈ 15–80 GPT-5.5 msgs / 5h) — a          │
  │     secondary route, not a fleet workhorse.                        │
  │   • The metered OPENAI_API_KEY path (openai-gpt-5.5/5.4) already    │
  │     works and stays the supported default.                         │
  │                                                                    │
  │  Loopback-only; holds a live OAuth on the host — never expose it.   │
  └────────────────────────────────────────────────────────────────────┘

BANNER
  if [[ ! -t 0 ]]; then
    echo "codex-bridge: non-interactive; set CODEX_BRIDGE_ACCEPT_RISK=1 to proceed." >&2
    return 1
  fi
  local reply=""
  read -r -p "  Type 'I accept' to enable the Codex bridge: " reply || true
  if [[ "$reply" != "I accept" ]]; then
    echo "codex-bridge: not acknowledged — nothing installed." >&2
    return 1
  fi
  return 0
}

_stop() {
  local pids; pids="$(_pids)"
  [[ -z "$pids" ]] && { echo "codex-bridge: nothing listening on :$PORT"; return 0; }
  echo "codex-bridge: stopping pid(s) $pids on :$PORT"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  for _ in 1 2 3 4 5; do _listening || break; sleep 1; done
  if _listening; then echo "codex-bridge: force-killing"; kill -9 $(_pids) 2>/dev/null || true; fi
  return 0   # never let a "nothing to stop" result trip `set -e` in callers
}

case "${1:-run}" in
  install)
    [[ -n "$NPX_BIN" ]] || { echo "codex-bridge: npx not found — install Node (brew install node)" >&2; exit 1; }
    _require_auth || exit 1
    _risk_ack || exit 1
    cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$AI_STACK/bin/start-codex-bridge.sh</string><string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict>
    <key>AI_STACK</key><string>$AI_STACK</string>
    <key>HOME</key><string>$HOME</string>
    <key>CODEX_BRIDGE_PORT</key><string>$PORT</string>
    <key>CODEX_BRIDGE_HOST</key><string>$HOST_BIND</string>
    <key>CODEX_BRIDGE_PKG</key><string>$CODEX_BRIDGE_PKG</string>
    <key>CODEX_AUTH_FILE</key><string>$AUTH_FILE</string>
    <key>PATH</key><string>$RUN_PATH</string>
  </dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PL
    # A pre-existing transient instance would hold the port and make launchd's
    # RunAtLoad fail — clear it first.
    _stop
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
    echo "codex-bridge launchd job installed ($LABEL, RunAtLoad+KeepAlive, $HOST_BIND:$PORT)"
    for _ in 1 2 3 4 5 6 7 8 9 10; do _healthy && { echo "codex-bridge: healthy on $HOST_BIND:$PORT"; exit 0; }; sleep 1; done
    echo "codex-bridge: not healthy yet — first run fetches the proxy via npx; check $LOG" >&2; exit 0 ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"; _stop
    echo "codex-bridge launchd job removed (your ~/.codex/auth.json is left intact)"; exit 0 ;;
  status)
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -iE 'state|pid|last exit' | head \
      || echo "launchd job not loaded"
    if _healthy; then echo "endpoint: http://$HOST_BIND:$PORT — HEALTHY (200)"; else echo "endpoint: http://$HOST_BIND:$PORT — NOT healthy"; fi
    [[ -s "$AUTH_FILE" ]] && echo "auth: $AUTH_FILE present" || echo "auth: $AUTH_FILE MISSING — run: npx --yes @openai/codex login"
    echo "--- recent log ($LOG) ---"; tail -n 12 "$LOG" 2>/dev/null || echo "(no log yet)"; exit 0 ;;
  stop)
    _stop; exit 0 ;;
  restart)
    _stop
    launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null \
      || { launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true; }
    echo "codex-bridge: restart requested"; exit 0 ;;
  enable)
    # ONE COMMAND to go from nothing -> usable: ChatGPT login (if needed) ->
    # install the daemon -> reload LiteLLM so the openai-gpt-5.*-sub models go live.
    # Interactive: `codex login` opens a browser, so it must run from a TTY.
    if [[ ! -s "$AUTH_FILE" ]]; then
      [[ -t 0 ]] || { echo "codex-bridge: no $AUTH_FILE and not a TTY — run: npx --yes @openai/codex login" >&2; exit 1; }
      [[ -n "$NPX_BIN" ]] || { echo "codex-bridge: npx not found — install Node (brew install node)" >&2; exit 1; }
      echo "codex-bridge: no ChatGPT auth yet — launching 'codex login' (a browser opens; choose 'Sign in with ChatGPT')..."
      "$NPX_BIN" --yes @openai/codex login || { echo "codex-bridge: codex login failed/cancelled" >&2; exit 1; }
    else
      echo "codex-bridge: ChatGPT auth present ($AUTH_FILE) — skipping login."
    fi
    # Idempotent: if the daemon is already loaded + healthy, there's nothing to do
    # (skip the risk banner re-prompt AND the LiteLLM recreate). Else install + reload.
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1 && _healthy; then
      echo "codex-bridge: daemon already installed + healthy on :$PORT — nothing to do."
    else
      # Install the launchd daemon (shows the one-time risk banner; health-probes the endpoint).
      "$0" install || exit $?
      # Reload LiteLLM (from the MAIN checkout this script lives in) so the *-sub routes serve.
      if [[ -x "$AI_STACK/bin/start-litellm.sh" ]]; then
        echo "codex-bridge: reloading LiteLLM so the subscription models go live..."
        bash "$AI_STACK/bin/start-litellm.sh" --recreate \
          || echo "codex-bridge: LiteLLM reload failed — run: bash $AI_STACK/bin/start-litellm.sh --recreate" >&2
      else
        echo "codex-bridge: bin/start-litellm.sh not found — reload LiteLLM yourself to serve the models" >&2
      fi
    fi
    echo "codex-bridge: ENABLED. Point agents at the subscription, e.g.:"
    echo "    bash $AI_STACK/vz-ai-stack.sh model assign all openai-gpt-5.5-sub   # whole fleet, no metered cost"
    echo "    bash $AI_STACK/vz-ai-stack.sh model assign hermes_manager openai-gpt-5.5-sub"
    echo "  or pick 'openai-gpt-5.5-sub' in Open WebUI. (Metered, no bridge needed: 'openai-gpt-5.5'.)"
    exit 0 ;;
  run) : ;;   # fall through and exec the server (launchd entrypoint)
  *) echo "usage: start-codex-bridge.sh [run|install|uninstall|status|stop|restart|enable]" >&2; exit 2 ;;
esac

# --- foreground server (launchd entrypoint) -----------------------------------
[[ -n "$NPX_BIN" ]] || { echo "codex-bridge: npx not found — install Node" >&2; exit 1; }
export PATH="$RUN_PATH"
# `--yes` so npx never blocks on an install prompt under launchd (no tty).
exec "$NPX_BIN" --yes "$CODEX_BRIDGE_PKG" \
  --port "$PORT" --host "$HOST_BIND" --oauth-file "$AUTH_FILE"
