#!/usr/bin/env bash
# start-meridian.sh — managed launcher for Meridian, the host bridge that lets
# the stack use your Claude Pro/Max SUBSCRIPTION (no API key) from Open WebUI.
#
# WHY THIS EXISTS
#   Open WebUI (container) → LiteLLM (container) → Meridian (host :3456) →
#   your `claude login` OAuth → Anthropic. Meridian reuses the Claude Code
#   OAuth in your macOS Keychain (auto-refreshed) and exposes an
#   OpenAI/Anthropic-compatible API. LiteLLM dials it exactly like LM Studio
#   (host.docker.internal:3456) — see the `*-sub` model entries in
#   litellm/config.yaml. OrbStack forwards host loopback into containers, so
#   Meridian stays bound to 127.0.0.1 (NOT 0.0.0.0): it holds a live OAuth and,
#   in internal mode, runs the agent loop (tool/file access) on the host — do
#   NOT expose it off-box.
#
# DAEMON, not a timer: unlike openshell-watchdog (StartInterval), Meridian is a
# long-running server, so the launchd job uses RunAtLoad + KeepAlive (launchd
# restarts it if it crashes or after login).
#
# Self-contained on purpose (launchd runs with a minimal PATH and no shell
# profile) — it resolves its own binaries and does not source the installer libs.
#
# Usage: start-meridian.sh [run|install|uninstall|status|stop|restart]
#   install    write + load the launchd job (always-on, survives reboot)
#   uninstall  unload + remove the launchd job (and stop the daemon)
#   status     launchd state + live /v1/models health probe
#   stop       kill any running Meridian on the port (launchd will respawn if loaded)
#   restart    stop, then bootstrap/kick the launchd job
#   run        exec Meridian in the foreground (this is what launchd calls)
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "bin/start-meridian.sh: needs bash 5+" >&2; exit 2
fi

AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="$AI_STACK/installer/state"
LOG="$STATE/meridian.launchd.log"
PLIST="$HOME/Library/LaunchAgents/com.ai-stack.meridian.plist"
LABEL="com.ai-stack.meridian"

# Tunables (mirror Meridian's own env knobs). Loopback bind is intentional.
PORT="${MERIDIAN_PORT:-3456}"
HOST_BIND="${MERIDIAN_HOST:-127.0.0.1}"

# --- Canonical model pins (the fix for the silent Opus 4.7-vs-4.8 drift) -------
# Meridian collapses every Claude request to an SDK alias (opus/sonnet/haiku) and
# resolves that alias to a HARDCODED CANONICAL_*_MODEL baked into the installed
# Meridian build. On 1.42.1 the Opus pin is `claude-opus-4-7`, so a request for
# `claude-opus-4-8` was silently served as 4.7 (and the response `model` field
# only ECHOED the requested id — cosmetic, not what served it). Meridian honors
# MERIDIAN_DEFAULT_*_MODEL env overrides which WIN over the internal pin, so we
# pin the served model deterministically here — version-resilient (works on
# 1.42.1; immune to a future build silently moving its canonical pin).
# Opus + Sonnet MUST match the wire ids ai-stack routes in litellm/config.yaml
# (the `claude-{opus,sonnet}-sub-*` model_list entries); doctor check 41 asserts
# that equality so the two can't drift apart. Haiku has NO `*-sub-*` route today —
# its pin is harmless version-resilient defense (Meridian collapses all three SDK
# aliases) and is not cross-checked. Override via the env to route elsewhere.
MERIDIAN_DEFAULT_OPUS_MODEL="${MERIDIAN_DEFAULT_OPUS_MODEL:-claude-opus-4-8}"
MERIDIAN_DEFAULT_SONNET_MODEL="${MERIDIAN_DEFAULT_SONNET_MODEL:-claude-sonnet-4-6}"
MERIDIAN_DEFAULT_HAIKU_MODEL="${MERIDIAN_DEFAULT_HAIKU_MODEL:-claude-haiku-4-5}"

mkdir -p "$STATE" "$HOME/Library/LaunchAgents"

# Resolve binaries without a login shell (launchd has a minimal PATH).
_find() { for p in "$@"; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done; command -v "$(basename "$1")" 2>/dev/null || echo ""; }
MERIDIAN_BIN="$(_find "$HOME/.openagents/nodejs/bin/meridian" /opt/homebrew/bin/meridian /usr/local/bin/meridian)"
NODE_BIN="$(_find "$HOME/.openagents/nodejs/bin/node" /opt/homebrew/bin/node /usr/local/bin/node)"
# Meridian's shebang is `env node`, so node's dir must be on PATH when we exec it.
NODE_DIR=""; [[ -n "$NODE_BIN" ]] && NODE_DIR="$(dirname "$NODE_BIN")"
RUN_PATH="${NODE_DIR:+$NODE_DIR:}/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"

# Is something already listening on the port?
_listening() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; }
# `|| true`: lsof exits 1 when nothing matches; a bare `pids=$(_pids)` would
# otherwise inherit that and trip `set -e`. _listening stays guarded (if/&&).
_pids()      { lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true; }

# Probe the live endpoint (static /v1/models, no token needed for liveness).
_healthy() {
  curl -s -m 5 -o /dev/null -w '%{http_code}' \
    "http://$HOST_BIND:$PORT/v1/models" -H "Authorization: Bearer x" 2>/dev/null | grep -q '^200$'
}

# Seed Meridian's default "effort": force extended thinking ON for every adapter.
# Meridian models effort as a tri-state per-adapter toggle (disabled/adaptive/
# enabled) in ~/.config/meridian/sdk-features.json — `enabled` is the ceiling it
# exposes (no high/max/xhigh budget knob). DEFAULT IS 'disabled', so without this
# the subscription models answer with thinking off. Write only if the file is
# ABSENT — once it exists the user owns it (Meridian's /settings UI rewrites it).
_ensure_thinking_default() {
  local f="$HOME/.config/meridian/sdk-features.json"
  [[ -e "$f" ]] && { echo "meridian: sdk-features.json exists — leaving thinking config as-is ($f)"; return 0; }
  mkdir -p "$HOME/.config/meridian"
  local on='{ "thinking": "enabled", "thinkingPassthrough": true }'
  cat > "$f" <<JSON
{
  "opencode": $on,
  "passthrough": $on,
  "claude-code": $on,
  "crush": $on,
  "droid": $on,
  "forgecode": $on,
  "pi": $on
}
JSON
  echo "meridian: seeded thinking=enabled (max effort) for all adapters → $f"
}

_stop() {
  local pids; pids="$(_pids)"
  [[ -z "$pids" ]] && { echo "meridian: nothing listening on :$PORT"; return 0; }
  echo "meridian: stopping pid(s) $pids on :$PORT"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  for _ in 1 2 3 4 5; do _listening || break; sleep 1; done
  if _listening; then echo "meridian: force-killing"; kill -9 $(_pids) 2>/dev/null || true; fi
  return 0   # never let a "nothing to stop" result trip `set -e` in callers
}

case "${1:-run}" in
  install)
    [[ -n "$MERIDIAN_BIN" ]] || { echo "meridian not found — run: npm install -g @rynfar/meridian" >&2; exit 1; }
    cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$AI_STACK/bin/start-meridian.sh</string><string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <!-- CA-5 (CrowdStrike EDR politeness): cap crash-loop churn so a startup/egress failure
       (e.g. a Zscaler-blocked OAuth refresh) can't respawn with no backoff and draw EDR
       anomalous-process-churn attention. Matches the codex-bridge sibling. -->
  <key>ThrottleInterval</key><integer>10</integer>
  <key>EnvironmentVariables</key><dict>
    <key>AI_STACK</key><string>$AI_STACK</string>
    <key>MERIDIAN_PORT</key><string>$PORT</string>
    <key>MERIDIAN_HOST</key><string>$HOST_BIND</string>
    <key>MERIDIAN_DEFAULT_OPUS_MODEL</key><string>$MERIDIAN_DEFAULT_OPUS_MODEL</string>
    <key>MERIDIAN_DEFAULT_SONNET_MODEL</key><string>$MERIDIAN_DEFAULT_SONNET_MODEL</string>
    <key>MERIDIAN_DEFAULT_HAIKU_MODEL</key><string>$MERIDIAN_DEFAULT_HAIKU_MODEL</string>
    <key>PATH</key><string>$RUN_PATH</string>
  </dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PL
    _ensure_thinking_default
    # A pre-existing transient instance (e.g. a manual `meridian &`) would hold
    # the port and make launchd's RunAtLoad fail — clear it first.
    _stop
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
    echo "meridian launchd job installed ($LABEL, RunAtLoad+KeepAlive, $HOST_BIND:$PORT)"
    for _ in 1 2 3 4 5 6 7 8; do _healthy && { echo "meridian: healthy on $HOST_BIND:$PORT"; exit 0; }; sleep 1; done
    echo "meridian: not healthy yet — check $LOG" >&2; exit 0 ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"; _stop
    echo "meridian launchd job removed"; exit 0 ;;
  status)
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -iE 'state|pid|last exit' | head \
      || echo "launchd job not loaded"
    if _healthy; then echo "endpoint: http://$HOST_BIND:$PORT — HEALTHY (200)"; else echo "endpoint: http://$HOST_BIND:$PORT — NOT healthy"; fi
    echo "--- recent log ($LOG) ---"; tail -n 12 "$LOG" 2>/dev/null || echo "(no log yet)"; exit 0 ;;
  stop)
    _stop; exit 0 ;;
  restart)
    _stop
    launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null \
      || { launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true; }
    echo "meridian: restart requested"; exit 0 ;;
  run) : ;;   # fall through and exec the server (launchd entrypoint)
  *) echo "usage: start-meridian.sh [run|install|uninstall|status|stop|restart]" >&2; exit 2 ;;
esac

# --- foreground server (launchd entrypoint) -----------------------------------
[[ -n "$MERIDIAN_BIN" ]] || { echo "meridian not found — run: npm install -g @rynfar/meridian" >&2; exit 1; }
export PATH="$RUN_PATH"
export MERIDIAN_PORT="$PORT" MERIDIAN_HOST="$HOST_BIND"
# Pin the served Claude model (overrides Meridian's internal CANONICAL_*_MODEL).
export MERIDIAN_DEFAULT_OPUS_MODEL MERIDIAN_DEFAULT_SONNET_MODEL MERIDIAN_DEFAULT_HAIKU_MODEL
exec "$MERIDIAN_BIN"
