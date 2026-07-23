#!/usr/bin/env bash
# start-aionui.sh — managed launcher for the AionUi WebUI server (Phase 28).
#
# WHY THIS EXISTS
#   AionUi ships two faces: the desktop app (brew --cask aionui) and a headless
#   WebUI server (the prebuilt, bun-compiled `aionui-web` standalone binary from
#   GitHub Releases, installed to ~/.local/share/aionui-web by Phase 28). This
#   launcher runs the WebUI server as a managed, loopback-only host daemon so you
#   can reach the Cowork workspace in a browser at http://127.0.0.1:25808.
#
#   The binary is self-contained: it spawns its OWN bundled aioncore backend
#   (~/.local/share/aionui-web/bundled-aioncore/<plat-arch>/aioncore) and serves
#   bundled static assets — no Node, no separate backend install.
#
# FUNNEL INTEGRATION
#   `mayssam-ai-stack.sh start aionui` invokes this with NO args, so the no-arg default
#   is `install` (ensure the launchd daemon + health-gate, idempotent) — NOT a
#   foreground exec. The launchd job itself calls `run` (the foreground server).
#   `mayssam-ai-stack.sh stop aionui` → bin/stop-aionui.sh → this script's `stop`.
#
# SECURITY
#   Bound to 127.0.0.1 ONLY (never --remote / 0.0.0.0). In local/loopback mode
#   aioncore disables authentication — correct ONLY because the port is loopback
#   (same posture as every localhost stack service). Do NOT expose it off-box.
#
# Self-contained on purpose (launchd runs with a minimal PATH and no shell
# profile) — it resolves its own binary and does not source the installer libs.
#
# Usage: start-aionui.sh [install|run|uninstall|status|stop|restart]
#   (no arg)   install  — ensure the launchd daemon is loaded + healthy (the
#                         `start aionui` entrypoint; idempotent)
#   run        exec aionui-web in the foreground (what launchd calls)
#   uninstall  unload + remove the launchd job (and stop the daemon)
#   status     launchd state + live HTTP health probe
#   stop       bootout the launchd job (so KeepAlive won't respawn) + free the port
#   restart    stop, then bootstrap/kick the launchd job
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "bin/start-aionui.sh: needs bash 5+" >&2; exit 2
fi

AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="$AI_STACK/installer/state"
LOG="$STATE/aionui-web.launchd.log"
PLIST="$HOME/Library/LaunchAgents/com.ai-stack.aionui-web.plist"
LABEL="com.ai-stack.aionui-web"

# Tunables. Loopback bind is intentional (see SECURITY). 25808 = aionui-web prod default.
PORT="${AIONUI_WEB_PORT:-25808}"
HOST_BIND="127.0.0.1"
DATA_DIR="${AIONUI_DATA_DIR:-$HOME/.aionui-web}"

mkdir -p "$STATE" "$HOME/Library/LaunchAgents"

# Resolve the aionui-web binary without a login shell (launchd has a minimal PATH).
_find() { for p in "$@"; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done; command -v "$(basename "$1")" 2>/dev/null || echo ""; }
AIONUI_WEB_BIN="$(_find "$HOME/.local/share/aionui-web/aionui-web" "$HOME/.local/bin/aionui-web")"

_listening() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; }
# `|| true`: lsof exits 1 when nothing matches; guard against tripping set -e.
_pids()      { lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true; }

# Probe the live endpoint. The WebUI serves HTTP 200 at `/` once aioncore is up.
# Explicit '^200$' grep (NOT the http_ok helper — documented 000-concat bug).
_healthy() {
  curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$HOST_BIND:$PORT/" 2>/dev/null | grep -q '^200$'
}

_stop() {
  local pids; pids="$(_pids)"
  [[ -z "$pids" ]] && { echo "aionui-web: nothing listening on :$PORT"; return 0; }
  echo "aionui-web: stopping pid(s) $pids on :$PORT"
  # shellcheck disable=SC2086
  kill $pids 2>/dev/null || true
  for _ in 1 2 3 4 5; do _listening || break; sleep 1; done
  if _listening; then local fp; fp="$(_pids)"; [[ -n "$fp" ]] && { echo "aionui-web: force-killing"; kill -9 $fp 2>/dev/null || true; }; fi
  pkill -f "bundled-aioncore/.*--data-dir $DATA_DIR" 2>/dev/null || true
  return 0   # never let a "nothing to stop" result trip set -e in callers
}

_do_install() {
  [[ -n "$AIONUI_WEB_BIN" ]] || { echo "aionui-web not found — run: bash $AI_STACK/mayssam-ai-stack.sh install 28" >&2; exit 1; }
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$AI_STACK/bin/start-aionui.sh</string><string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>EnvironmentVariables</key><dict>
    <key>AI_STACK</key><string>$AI_STACK</string>
    <key>AIONUI_WEB_PORT</key><string>$PORT</string>
    <key>AIONUI_DATA_DIR</key><string>$DATA_DIR</string>
    <key>AIONUI_OPEN_BROWSER</key><string>0</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PL
  # A pre-existing transient instance would hold the port and make RunAtLoad fail.
  _stop
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
  echo "aionui-web launchd job installed ($LABEL, RunAtLoad+KeepAlive, $HOST_BIND:$PORT)"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do _healthy && { echo "aionui-web: healthy on http://$HOST_BIND:$PORT"; return 0; }; sleep 1; done
  echo "aionui-web: not healthy yet — check $LOG" >&2; return 0
}

case "${1:-install}" in
  install) _do_install; exit 0 ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"; _stop
    echo "aionui-web launchd job removed"; exit 0 ;;
  status)
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -iE 'state|pid|last exit' | head \
      || echo "launchd job not loaded"
    if _healthy; then echo "endpoint: http://$HOST_BIND:$PORT — HEALTHY (200)"; else echo "endpoint: http://$HOST_BIND:$PORT — NOT healthy"; fi
    echo "--- recent log ($LOG) ---"; tail -n 12 "$LOG" 2>/dev/null || echo "(no log yet)"; exit 0 ;;
  stop)
    # Real stop for the `stop aionui` funnel: bootout so KeepAlive won't respawn,
    # then free the port. The plist stays on disk; `start aionui` re-bootstraps it.
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    _stop; exit 0 ;;
  restart)
    _stop
    launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null \
      || { launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true; }
    echo "aionui-web: restart requested"; exit 0 ;;
  run) : ;;   # fall through and exec the server (launchd entrypoint)
  *) echo "usage: start-aionui.sh [install|run|uninstall|status|stop|restart]" >&2; exit 2 ;;
esac

# --- foreground server (launchd entrypoint) -----------------------------------
[[ -n "$AIONUI_WEB_BIN" ]] || { echo "aionui-web not found — run: bash $AI_STACK/mayssam-ai-stack.sh install 28" >&2; exit 1; }
export AIONUI_PORT="$PORT" AIONUI_DATA_DIR="$DATA_DIR" AIONUI_OPEN_BROWSER=0
# Loopback only: NO --remote. --no-open: a daemon never opens a browser itself.
exec "$AIONUI_WEB_BIN" start --port "$PORT" --no-open
