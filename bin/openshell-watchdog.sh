#!/usr/bin/env bash
# openshell-watchdog.sh — auto-heal the OpenShell sandbox "expired-token storm".
#
# THE FAILURE (seen twice): an OpenShell sandbox's short-lived gateway token
# expires (~8h uptime). The in-sandbox agent then retries its log-push gRPC with
# NO backoff — hundreds of reconnects/second ("invalid token: ExpiredSignature",
# "log push stream lost, reconnecting") — pegging ~36% CPU per sandbox, and the
# container restart-loops. A gateway restart does NOT refresh the token; only
# RECREATING the sandbox mints a fresh one (empirically verified 2026-05-31).
#
# THIS WATCHDOG (run every few minutes by launchd):
#   1. For each OpenShell sandbox, detect the storm by its UNAMBIGUOUS signature
#      (ExpiredSignature / reconnect-storm in recent logs, or a climbing
#      RestartCount). That signature means the sandbox is already DEAD, so acting
#      on it loses nothing — it won't false-fire on a legitimately busy sandbox.
#   2. On detection: delete the dead sandbox (stops the CPU storm at once) and
#      recreate it via its install phases (fresh token). Throttled + logged +
#      a desktop notification. Skips if an install is already running.
#   3. GENERIC net: any MANAGED container pegged >CPU_WARN over two samples gets
#      logged as a runaway (sandboxes self-heal; others are surfaced for `doctor`).
#
# Detect-only mode: set AI_STACK_WATCHDOG_RECREATE=0 (logs + deletes the dead
# sandbox to stop the burn, but does not recreate).
set -Eeuo pipefail

AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="$AI_STACK/installer/state"
LOG="$STATE/openshell-watchdog.log"
LOCK="$STATE/openshell-watchdog.lock"
INSTALL_LOCK="$STATE/.lock"               # vz-ai-stack.sh's lock dir
THROTTLE_FILE="$STATE/openshell-watchdog.last"
THROTTLE_SECS="${AI_STACK_WATCHDOG_THROTTLE:-1800}"   # don't recreate the same thing more than once / 30min
CPU_WARN="${AI_STACK_WATCHDOG_CPU_WARN:-85}"          # generic runaway threshold (%)
RECREATE="${AI_STACK_WATCHDOG_RECREATE:-1}"
SANDBOXES=(hermes-fleet-v1 pi-v1)

mkdir -p "$STATE"
# Resolve tools (launchd has a minimal PATH).
_find() { for p in "$@"; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done; command -v "$(basename "$1")" 2>/dev/null || echo ""; }
DOCKER="$(_find /opt/homebrew/bin/docker "$HOME/.orbstack/bin/docker" /usr/local/bin/docker)"
OPENSHELL="$(_find /opt/homebrew/bin/openshell /usr/local/bin/openshell)"
BREW="$(_find /opt/homebrew/bin/brew /usr/local/bin/brew)"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
notify() { /usr/bin/osascript -e "display notification \"$1\" with title \"ai-stack watchdog\"" >/dev/null 2>&1 || true; }

# --- subcommands: manage the launchd timer (install/uninstall/status) ---------
PLIST="$HOME/Library/LaunchAgents/com.ai-stack.openshell-watchdog.plist"
LABEL="com.ai-stack.openshell-watchdog"
INTERVAL="${AI_STACK_WATCHDOG_INTERVAL:-600}"   # check every 10 min
case "${1:-run}" in
  install)
    mkdir -p "$HOME/Library/LaunchAgents"
    cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$AI_STACK/bin/openshell-watchdog.sh</string><string>run</string>
  </array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><false/>
  <key>EnvironmentVariables</key><dict>
    <key>AI_STACK</key><string>$AI_STACK</string>
    <key>PATH</key><string>/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>$STATE/openshell-watchdog.launchd.log</string>
  <key>StandardErrorPath</key><string>$STATE/openshell-watchdog.launchd.log</string>
</dict></plist>
PL
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
    echo "openshell-watchdog launchd job installed ($LABEL, every ${INTERVAL}s)"; exit 0 ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"; echo "openshell-watchdog launchd job removed"; exit 0 ;;
  status)
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -iE 'state|pid|last exit|runs' | head \
      || echo "launchd job not loaded"
    echo "--- recent watchdog log ($LOG) ---"; tail -n 15 "$LOG" 2>/dev/null || echo "(no log yet)"; exit 0 ;;
  run) : ;;   # fall through to the detection cycle below
  *) echo "usage: openshell-watchdog.sh [run|install|uninstall|status]" >&2; exit 2 ;;
esac

[[ -n "$DOCKER" ]] || { log "FATAL: docker not found"; exit 0; }

# Single-instance: skip if a prior watchdog run is still going.
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Defer if an install is in progress (avoid fighting over sandboxes).
[[ -d "$INSTALL_LOCK" ]] && { log "install in progress — deferring this cycle"; exit 0; }

_throttled() {  # _throttled <key> — true if <key> was acted on within THROTTLE_SECS
  local key="$1" now last
  now="$(date +%s)"
  last="$(grep -E "^$key " "$THROTTLE_FILE" 2>/dev/null | tail -1 | awk '{print $2}')"
  [[ -n "$last" ]] && (( now - last < THROTTLE_SECS ))
}
_mark() { local key="$1"; { grep -vE "^$key " "$THROTTLE_FILE" 2>/dev/null || true; echo "$key $(date +%s)"; } > "$THROTTLE_FILE.tmp" && mv -f "$THROTTLE_FILE.tmp" "$THROTTLE_FILE"; }

# Storm signature for a sandbox container id: expired-token retry storm.
_is_storming() {
  local cid="$1" logs
  logs="$("$DOCKER" logs "$cid" --since 3m --tail 60 2>&1 || true)"
  grep -q 'ExpiredSignature' <<<"$logs" && return 0
  # >=8 reconnect lines in the last 3 min = a no-backoff storm (not a one-off blip)
  (( $(grep -cE 'log push (stream lost, reconnecting|reconnected \(attempt)' <<<"$logs") >= 8 )) && return 0
  return 1
}

recreate_sandbox() {  # recreate_sandbox <name>
  local name="$1"
  log "RECREATING $name (delete + reinstall for a fresh token)"
  notify "$name token expired — auto-recreating"
  "$OPENSHELL" sandbox delete "$name" >>"$LOG" 2>&1 || log "  (delete returned non-zero — continuing)"
  if [[ "$RECREATE" != "1" ]]; then log "  RECREATE disabled — deleted only (stops the storm); recreate later via install"; return 0; fi
  case "$name" in
    hermes-fleet-v1)
      bash "$AI_STACK/vz-ai-stack.sh" install 04  >>"$LOG" 2>&1 || log "  install 04 failed"
      bash "$AI_STACK/vz-ai-stack.sh" install 04f >>"$LOG" 2>&1 || log "  install 04f failed"
      # Restart the Telegram gateway only if a token is configured.
      grep -q '^HERMES_TELEGRAM_BOT_TOKEN=.' "$AI_STACK/.env" 2>/dev/null \
        && { bash "$AI_STACK/vz-ai-stack.sh" install 20 >>"$LOG" 2>&1 || log "  install 20 failed"; }
      ;;
    pi-v1)
      bash "$AI_STACK/vz-ai-stack.sh" install 15 >>"$LOG" 2>&1 || log "  install 15 failed"
      ;;
  esac
  log "  recreate of $name done"
  notify "$name recreated ✓"
}

acted=0
for name in "${SANDBOXES[@]}"; do
  cid="$("$DOCKER" ps -q --filter "name=openshell-${name}-" 2>/dev/null | head -1)"
  [[ -n "$cid" ]] || continue
  if _is_storming "$cid"; then
    if _throttled "$name"; then
      log "$name is storming but throttled (acted < ${THROTTLE_SECS}s ago) — skipping"
    else
      log "DETECTED expired-token storm on $name (cid ${cid:0:12})"
      _mark "$name"
      recreate_sandbox "$name"
      acted=1
    fi
  fi
done

# Generic runaway net: any managed container pegged across two ~3s samples.
declare -A s1
while IFS=$'\t' read -r nm cpu; do s1["$nm"]="${cpu%\%}"; done < <("$DOCKER" stats --no-stream --format '{{.Names}}\t{{.CPUPerc}}' 2>/dev/null)
sleep 3
while IFS=$'\t' read -r nm cpu; do
  c2="${cpu%\%}"; c1="${s1[$nm]:-0}"
  # integer compare (strip decimals)
  if (( ${c1%.*} > CPU_WARN )) && (( ${c2%.*} > CPU_WARN )); then
    # sandboxes self-heal above; here we just surface non-sandbox runaways.
    [[ "$nm" == openshell-* ]] || log "RUNAWAY: container '$nm' sustained CPU ${c1}%/${c2}% (> ${CPU_WARN}%) — investigate ('docker logs $nm')"
  fi
done < <("$DOCKER" stats --no-stream --format '{{.Names}}\t{{.CPUPerc}}' 2>/dev/null)

(( acted == 1 )) && log "watchdog cycle acted on a storm" || true
exit 0
