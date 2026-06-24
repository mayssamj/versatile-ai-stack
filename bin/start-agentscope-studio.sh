#!/usr/bin/env bash
# start-agentscope-studio.sh — managed launcher for AgentScope Studio (Phase 33, OPT-IN GUI).
#
# WHY THIS EXISTS
#   AgentScope Studio is a STANDALONE Node app (npm `@agentscope/studio`, binary
#   `as_studio`) — NOT part of the pip `agentscope` package. It is a web GUI that
#   RECEIVES OpenTelemetry trace spans your sims emit and visualizes a swarm run.
#   This launcher runs it as a managed host launchd daemon so you can reach it at
#   http://127.0.0.1:5275 while sims run. Mirrors bin/start-aionui.sh (Phase 28).
#
#   `as_studio` makes NO LLM calls of its own — it only ingests/visualizes spans.
#   Two listeners:
#     * the HTTP UI on PORT (default 3000 upstream; we pin 5275 via env PORT)
#     * an OTLP gRPC trace receiver on OTEL_GRPC_PORT (we pin 4318 — NOT the OTel
#       default 4317, which phoenix-otlp already owns; as_studio binds 0.0.0.0 so
#       :4317 would collide with / hijack Phoenix's OTLP intake).
#       It ALSO accepts OTLP/HTTP traces at http://<host>:<PORT>/v1/traces.
#   App-data/SQLite persists under ~/Library/Application Support/AgentScope-Studio/
#   (macOS) — survives a restart; nothing of ours to seed.
#
# FUNNEL INTEGRATION
#   `vz-ai-stack.sh start agentscope-studio` invokes this with NO args, so the
#   no-arg default is `install` (ensure the launchd daemon + health-gate,
#   idempotent) — NOT a foreground exec. The launchd job itself calls `run`.
#   `vz-ai-stack.sh stop agentscope-studio` → this script's `stop`.
#
# SECURITY (IMPORTANT — differs from aionui)
#   as_studio's `host:'localhost'` config default is INERT: the server actually
#   binds 0.0.0.0 (both the HTTP UI and the OTLP gRPC receiver). The "loopback"
#   intent here relies ENTIRELY on NOT exposing this host off-box (no docker
#   --publish, no router forward, firewall on). The health probe + the alias use
#   127.0.0.1 because the bind is 0.0.0.0-reachable from loopback, but treat the
#   actual posture as "open on every interface" and do not expose the box.
#
# Self-contained on purpose (launchd runs with a minimal PATH and no shell
# profile) — it resolves `as_studio` from the global npm bin and does not source
# the installer libs.
#
# Usage: start-agentscope-studio.sh [install|run|uninstall|status|stop|restart]
#   (no arg)   install  — ensure the launchd daemon is loaded + healthy (the
#                         `start agentscope-studio` entrypoint; idempotent)
#   run        exec as_studio in the foreground (what launchd calls)
#   uninstall  unload + remove the launchd job (and stop the daemon)
#   status     launchd state + live HTTP health probe
#   stop       bootout the launchd job (so KeepAlive won't respawn) + free the port
#   restart    stop, then bootstrap/kick the launchd job
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "bin/start-agentscope-studio.sh: needs bash 5+" >&2; exit 2
fi

AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="$AI_STACK/installer/state"
LOG="$STATE/agentscope-studio.launchd.log"
PLIST="$HOME/Library/LaunchAgents/com.ai-stack.agentscope-studio.plist"
LABEL="com.ai-stack.agentscope-studio"

# Tunables. Loopback PROBE is intentional (see SECURITY — the bind is actually
# 0.0.0.0). 5275 = the stack's pinned Studio HTTP port (override via PORT for
# parity with the phase/aliases). OTEL_GRPC_PORT 4318 = the OTLP gRPC receiver the
# sims export to (bin/agentscope points OTEL_EXPORTER_OTLP_TRACES_ENDPOINT here).
# 4318 (NOT the OTel default 4317): phoenix-otlp already owns :4317 and as_studio
# binds 0.0.0.0, so :4317 would collide with / hijack Phoenix's OTLP intake.
PORT="${PORT:-5275}"
OTEL_GRPC_PORT="${OTEL_GRPC_PORT:-4318}"
HOST_BIND="127.0.0.1"

mkdir -p "$STATE" "$HOME/Library/LaunchAgents"

# Resolve the as_studio binary without a login shell (launchd has a minimal PATH).
# npm global bin is typically /opt/homebrew/bin (Apple-silicon brew node) — also
# try `$(npm prefix -g)/bin` and the common nvm-ish fallbacks before giving up.
_find() {
  for p in "$@"; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done
  # last resort: ask npm where its global bin is (npm itself is on the brew PATH).
  local nb; nb="$(/opt/homebrew/bin/npm prefix -g 2>/dev/null || npm prefix -g 2>/dev/null || true)"
  [[ -n "$nb" && -x "$nb/bin/as_studio" ]] && { echo "$nb/bin/as_studio"; return 0; }
  command -v as_studio 2>/dev/null || echo ""
}
AS_STUDIO_BIN="$(_find "/opt/homebrew/bin/as_studio" "/usr/local/bin/as_studio" "$HOME/.local/bin/as_studio")"

_listening() { lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | grep -q LISTEN; }
# `|| true`: lsof exits 1 when nothing matches; guard against tripping set -e.
_pids()      { lsof -nP -tiTCP:"$PORT" -sTCP:LISTEN 2>/dev/null || true; }
_grpc_pids() { lsof -nP -tiTCP:"$OTEL_GRPC_PORT" -sTCP:LISTEN 2>/dev/null || true; }

# Probe the live endpoint. Studio serves HTTP 200 at `/` once the UI is up.
# Explicit '^200$' grep (NOT the http_ok helper — documented 000-concat bug).
_healthy() {
  curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$HOST_BIND:$PORT/" 2>/dev/null | grep -q '^200$'
}

_stop() {
  local pids; pids="$(_pids)"
  if [[ -z "$pids" ]]; then
    echo "agentscope-studio: nothing listening on :$PORT"
  else
    echo "agentscope-studio: stopping pid(s) $pids on :$PORT"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    for _ in 1 2 3 4 5; do _listening || break; sleep 1; done
    if _listening; then local fp; fp="$(_pids)"; [[ -n "$fp" ]] && { echo "agentscope-studio: force-killing"; kill -9 $fp 2>/dev/null || true; }; fi
  fi
  # The OTLP gRPC receiver shares the same as_studio process, but free :$OTEL_GRPC_PORT
  # too in case a stray child kept it (so a re-install's RunAtLoad can re-bind).
  # OWNERSHIP GUARD: only kill a PID on this port if it actually belongs to as_studio —
  # never blindly kill the port owner. (Defence-in-depth: with 4318 the Phoenix-on-4317
  # collision is already gone, but a future port reuse must not let `stop`/re-install
  # SIGKILL an unrelated listener.)
  local gp
  for gp in $(_grpc_pids); do
    local _comm; _comm="$(ps -p "$gp" -o comm= 2>/dev/null || true)"
    if [[ "$_comm" == *as_studio* ]]; then
      kill "$gp" 2>/dev/null || true
    else
      echo "agentscope-studio: :$OTEL_GRPC_PORT owned by pid $gp ($_comm), not as_studio — NOT killing" >&2
    fi
  done
  return 0   # never let a "nothing to stop" result trip set -e in callers
}

_do_install() {
  [[ -n "$AS_STUDIO_BIN" ]] || { echo "as_studio not found — enable Studio: AGENTSCOPE_STUDIO=1 bash $AI_STACK/vz-ai-stack.sh install 33 (installs npm @agentscope/studio)" >&2; exit 1; }
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$AI_STACK/bin/start-agentscope-studio.sh</string><string>run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>EnvironmentVariables</key><dict>
    <key>AI_STACK</key><string>$AI_STACK</string>
    <key>PORT</key><string>$PORT</string>
    <key>OTEL_GRPC_PORT</key><string>$OTEL_GRPC_PORT</string>
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
  echo "agentscope-studio launchd job installed ($LABEL, RunAtLoad+KeepAlive, UI $HOST_BIND:$PORT, OTLP gRPC :$OTEL_GRPC_PORT)"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do _healthy && { echo "agentscope-studio: healthy on http://$HOST_BIND:$PORT"; return 0; }; sleep 1; done
  echo "agentscope-studio: not healthy yet — check $LOG" >&2; return 0
}

case "${1:-install}" in
  install) _do_install; exit 0 ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"; _stop
    echo "agentscope-studio launchd job removed"; exit 0 ;;
  status)
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -iE 'state|pid|last exit' | head \
      || echo "launchd job not loaded"
    if _healthy; then echo "endpoint: http://$HOST_BIND:$PORT — HEALTHY (200)"; else echo "endpoint: http://$HOST_BIND:$PORT — NOT healthy"; fi
    echo "--- recent log ($LOG) ---"; tail -n 12 "$LOG" 2>/dev/null || echo "(no log yet)"; exit 0 ;;
  stop)
    # Real stop for the `stop agentscope-studio` funnel: bootout so KeepAlive won't
    # respawn, then free the port. The plist stays on disk; `start` re-bootstraps it.
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    _stop; exit 0 ;;
  restart)
    _stop
    launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null \
      || { launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true; }
    echo "agentscope-studio: restart requested"; exit 0 ;;
  run) : ;;   # fall through and exec the server (launchd entrypoint)
  *) echo "usage: start-agentscope-studio.sh [install|run|uninstall|status|stop|restart]" >&2; exit 2 ;;
esac

# --- foreground server (launchd entrypoint) -----------------------------------
[[ -n "$AS_STUDIO_BIN" ]] || { echo "as_studio not found — enable Studio: AGENTSCOPE_STUDIO=1 bash $AI_STACK/vz-ai-stack.sh install 33" >&2; exit 1; }
# Port via env (as_studio reads PORT for the UI + OTEL_GRPC_PORT for the OTLP gRPC
# receiver). Headless-safe: non-interactive, it auto-bumps a busy port and the
# browser auto-open no-ops. NO flag exists to force a loopback bind (see SECURITY).
export PORT OTEL_GRPC_PORT
exec "$AS_STUDIO_BIN"
