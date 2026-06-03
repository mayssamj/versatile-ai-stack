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
#   2. On detection (DEFAULT = WARN-ONLY, data-safe): log + desktop-notify + write
#      a RED marker (surfaced by doctor check 43). It does NOT delete the sandbox —
#      deletion is destructive (loses in-sandbox runtime state), so recreation is a
#      deliberate human action: `vz-ai-stack.sh install <phases>`.
#   3. GENERIC net: any MANAGED container pegged >CPU_WARN over two samples gets
#      logged as a runaway (surfaced for `doctor`).
#
# WHY warn-only (2026-06-03): the previous version auto-deleted then rebuilt, but the
# rebuild ran under launchd's PATH (no OrbStack docker) and ALWAYS failed — destroying
# BOTH sandboxes and logging a false "done". Now destruction never happens on its own.
#
# Opt-in AI_STACK_WATCHDOG_RECREATE=1: auto-recreate, but only after verifying the
# rebuild can run (docker+openshell reachable); recreates, verifies Ready, and fails
# LOUD (RED marker + notify) — never a silent destroy-without-rebuild.
# Opt-in AI_STACK_WATCHDOG_HALT=1: `docker stop` the storming container (non-destructive,
# sandbox record preserved) to cut the CPU burn while you decide.
set -Eeuo pipefail

AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="$AI_STACK/installer/state"
LOG="$STATE/openshell-watchdog.log"
LOCK="$STATE/openshell-watchdog.lock"
INSTALL_LOCK="$STATE/.lock"               # vz-ai-stack.sh's lock dir
THROTTLE_FILE="$STATE/openshell-watchdog.last"
THROTTLE_SECS="${AI_STACK_WATCHDOG_THROTTLE:-1800}"   # don't recreate the same thing more than once / 30min
CPU_WARN="${AI_STACK_WATCHDOG_CPU_WARN:-85}"          # generic runaway threshold (%)
# SAFETY (2026-06-03 — after the watchdog destroyed both sandboxes without rebuild):
# DEFAULT IS WARN-ONLY. The watchdog NEVER auto-deletes a sandbox by default —
# deletion is destructive (loses any in-sandbox runtime state). On a storm it logs
# + desktop-notifies + writes a RED marker that `doctor` surfaces; YOU recreate when
# ready. Opt into auto-recreate (delete+rebuild, capability-checked + Ready-verified
# + fails LOUD) with AI_STACK_WATCHDOG_RECREATE=1. Opt into a non-destructive CPU-burn
# halt (docker stop, sandbox preserved) with AI_STACK_WATCHDOG_HALT=1.
RECREATE="${AI_STACK_WATCHDOG_RECREATE:-0}"
HALT="${AI_STACK_WATCHDOG_HALT:-0}"
FAILMARK="$STATE/openshell-watchdog.alert"            # RED marker → doctor check 43
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
    <key>PATH</key><string>${DOCKER:+$(dirname "$DOCKER"):}${OPENSHELL:+$(dirname "$OPENSHELL"):}/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
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

# _child_path — prepend the RESOLVED tool dirs so a shelled `vz-ai-stack.sh install`
# finds docker/openshell/brew even under launchd's minimal PATH. (DEFECT-2: the
# child installer's preflight does `command -v docker`; OrbStack's docker lives at
# ~/.orbstack/bin and was NOT on the plist PATH, so every rebuild aborted.)
_child_path() {
  local d=""
  [[ -n "$DOCKER"    ]] && d="$(dirname "$DOCKER"):"
  [[ -n "$OPENSHELL" ]] && d="$d$(dirname "$OPENSHELL"):"
  [[ -n "$BREW"      ]] && d="$d$(dirname "$BREW"):"
  printf '%s%s' "$d" "$PATH"
}

# _phase_install <cpath> <phase...> — run the recreate phases with a docker-capable
# PATH; return non-zero if ANY phase fails (DEFECT-3: no more false "done").
_phase_install() {
  local cpath="$1"; shift; local p rc=0
  for p in "$@"; do
    PATH="$cpath" bash "$AI_STACK/vz-ai-stack.sh" install "$p" >>"$LOG" 2>&1 || { rc=1; log "  install $p FAILED (rc=$?)"; }
  done
  return $rc
}

# _verify_ready <name> — poll until the sandbox reports Ready (or give up).
_verify_ready() {
  local name="$1" i
  for i in 1 2 3 4 5 6; do
    "$OPENSHELL" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
      | awk -v n="$name" 'NR>1 && $1==n && $NF=="Ready"{ok=1} END{exit !ok}' && return 0
    sleep 5
  done
  return 1
}

handle_storm() {  # handle_storm <name> <cid>
  local name="$1" cid="$2" phases
  case "$name" in
    hermes-fleet-v1)
      phases="04 04f"
      grep -q '^HERMES_TELEGRAM_BOT_TOKEN=.' "$AI_STACK/.env" 2>/dev/null && phases="$phases 20" ;;
    pi-v1) phases="15" ;;
    *)     phases="" ;;
  esac

  # DEFAULT: WARN ONLY — never auto-destroy (would lose in-sandbox state).
  if [[ "$RECREATE" != "1" ]]; then
    log "ALERT: $name has an expired-token storm (cid ${cid:0:12}). NOT auto-deleting (would discard in-sandbox state)."
    log "  Heal when ready (recreate mints a fresh token but DISCARDS in-sandbox runtime data):  bash $AI_STACK/vz-ai-stack.sh install $phases"
    if [[ "$HALT" == "1" ]]; then
      "$DOCKER" stop "$cid" >>"$LOG" 2>&1 && log "  halted the container to stop the CPU burn (sandbox record preserved; recreate to use it)" || log "  (docker stop failed)"
    fi
    printf '%s expired-token storm at %s — auto-recreate is OFF (data-safe). Heal: vz-ai-stack.sh install %s\n' \
      "$name" "$(date '+%F %T')" "$phases" > "$FAILMARK"
    notify "$name token storm — recreate manually (auto-recreate OFF)"
    return 0
  fi

  # OPT-IN auto-recreate: verify we CAN rebuild BEFORE deleting (DEFECT-1), recreate,
  # VERIFY Ready, fail LOUD on any failure (DEFECT-3).
  local cpath; cpath="$(_child_path)"
  if ! PATH="$cpath" command -v docker >/dev/null 2>&1 || [[ -z "$OPENSHELL" ]]; then
    log "REFUSING to recreate $name: rebuild prerequisites missing (docker on PATH / openshell). Sandbox LEFT INTACT — never delete without a viable rebuild."
    printf '%s storm; auto-recreate ABORTED (no docker/openshell for rebuild) — sandbox left intact %s\n' "$name" "$(date '+%F %T')" > "$FAILMARK"
    notify "⚠ $name storm — recreate aborted (rebuild prereqs missing); left intact"
    return 0
  fi
  log "RECREATING $name (opt-in; capability-checked; delete+rebuild for a fresh token)"
  notify "$name token expired — auto-recreating"
  "$OPENSHELL" sandbox delete "$name" >>"$LOG" 2>&1 || log "  (delete returned non-zero — continuing)"
  local rc=0; _phase_install "$cpath" $phases || rc=1
  if (( rc == 0 )) && _verify_ready "$name"; then
    log "  recreate of $name SUCCEEDED + verified Ready"
    rm -f "$FAILMARK"
    notify "$name recreated ✓"
  else
    log "  RECREATE of $name FAILED (install rc=$rc / not Ready) — sandbox is NOT healthy. Manual: bash $AI_STACK/vz-ai-stack.sh install $phases"
    printf '%s auto-recreate FAILED (rc=%s) at %s — sandbox missing/unhealthy; manual repair needed\n' "$name" "$rc" "$(date '+%F %T')" > "$FAILMARK"
    notify "⚠ $name recreate FAILED — needs manual repair (see doctor)"
  fi
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
      handle_storm "$name" "$cid"
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
