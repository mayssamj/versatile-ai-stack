#!/usr/bin/env bash
# openshell-watchdog.sh — auto-heal the OpenShell sandbox "expired-token storm".
#
# THE FAILURE (seen twice): an OpenShell sandbox's short-lived gateway token
# expires (~1h uptime — NOT ~8h; corrected 2026-06-19). The in-sandbox agent then
# retries its log-push / inference-route gRPC with NO backoff — hundreds of
# reconnects/second ("invalid token: ExpiredSignature", "log push stream lost,
# reconnecting") — pegging ~36% CPU per sandbox, and the container restart-loops.
# A gateway restart does NOT refresh the token. RECREATING mints a fresh one but
# DESTROYS /sandbox; the NON-destructive cure is an in-place host RE-MINT — the host
# holds the gateway Ed25519 key and the gateway validates statelessly (no jti),
# verified 2026-06-19. See the REMINT path (bin/openshell-jwt-mint.py) below.
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
# SAFETY (2026-06-03 + 2026-06-08 incidents):
#  • NEVER auto-DELETE by default — deletion is destructive (loses in-sandbox state).
#    Auto-recreate (delete+rebuild, capability-checked, Ready-verified, CHECKPOINT-FIRST,
#    fails LOUD) stays OPT-IN via AI_STACK_WATCHDOG_RECREATE=1.
#  • HALT-BY-DEFAULT (2026-06-08): a detected storm is on an already-DEAD sandbox, so a
#    cgroup cap + `docker stop` loses NOTHING and is reversible (docker start) — whereas
#    a host hang requiring a hard reboot is NOT. When warn-only, the overnight storm
#    pegged the host into a forced reboot. So on a storm we now CAP cpu/mem then stop the
#    container to kill the CPU burn immediately. Set AI_STACK_WATCHDOG_HALT=0 to revert.
RECREATE="${AI_STACK_WATCHDOG_RECREATE:-0}"
HALT="${AI_STACK_WATCHDOG_HALT:-1}"
FAILMARK="$STATE/openshell-watchdog.alert"            # RED marker → doctor check 43
# Managed sandbox set; override via AI_STACK_WATCHDOG_SANDBOXES="a b c" (testing / extra sandboxes).
read -ra SANDBOXES <<< "${AI_STACK_WATCHDOG_SANDBOXES:-hermes-fleet-v1 pi-v1}"

# --- Persistence via in-place token RE-MINT (opt-in; added 2026-06-19) --------
# The expired-token storm's only non-destructive cure is a fresh token. Recreate
# mints one but DESTROYS /sandbox; verified 2026-06-19 that the gateway validates
# statelessly (no jti) so a host-minted token mirroring the claims with a fresh exp
# is ACCEPTED — letting us refresh the SAME sandbox in place (bin/openshell-jwt-mint.py).
#   REMINT=1   → heal a storm by re-minting (+restart) instead of halt/recreate, AND
#                proactively re-mint BEFORE expiry so the storm never starts.
#   PERSIST=1  → managed sandboxes are long-lived: restart=unless-stopped (survive a
#                docker/system restart — safe now: capped + the watchdog re-mints any
#                post-restart storm within one cycle) + the timer runs at boot (RunAtLoad).
# Both default OFF (shared-repo safety); `install` bakes the chosen values into the plist.
REMINT="${AI_STACK_WATCHDOG_REMINT:-0}"
PERSIST="${AI_STACK_SANDBOX_PERSIST:-0}"
REMINT_THRESHOLD="${AI_STACK_WATCHDOG_REMINT_THRESHOLD:-900}"   # proactively re-mint when < N s to expiry
# NOTE: the two re-mint paths differ BY DESIGN — proactive (pre-expiry) rewrites the
# token file with NO restart (best-effort, zero-blip); reactive (storm detected) always
# re-mints + docker restart (the PROVEN heal). There is intentionally no restart toggle.
MINT="$AI_STACK/bin/openshell-jwt-mint.py"
TOKDIR="$HOME/.local/state/openshell/docker-sandbox-tokens/default"

mkdir -p "$STATE"
# Resolve tools (launchd has a minimal PATH).
_find() { for p in "$@"; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done; command -v "$(basename "$1")" 2>/dev/null || echo ""; }
DOCKER="$(_find /opt/homebrew/bin/docker "$HOME/.orbstack/bin/docker" /usr/local/bin/docker)"

# Engine-aware: do NOT assume OrbStack. Prefer the gateway.env DOCKER_HOST (the
# gateway's own source of truth); fall back to the registry from AI_STACK_DOCKER_ENGINE.
if [[ -z "${DOCKER_HOST:-}" ]]; then
  _gw_dh="$(grep -E '^DOCKER_HOST=' "$HOME/.config/openshell/gateway.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  if [[ -n "${_gw_dh:-}" ]]; then
    export DOCKER_HOST="$_gw_dh"
  elif [[ -n "${AI_STACK:-}" && -f "$AI_STACK/installer/lib/docker-engine.sh" ]]; then
    # shellcheck disable=SC1090
    source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
    source "$AI_STACK/installer/lib/docker-engine.sh"
    _eng="$(get_env AI_STACK_DOCKER_ENGINE "" 2>/dev/null || true)"
    if [[ -n "${_eng:-}" ]] && _engine_valid "$_eng" 2>/dev/null; then
      _dh="$(engine_socket "$_eng" 2>/dev/null || true)"; [[ -n "${_dh:-}" ]] && export DOCKER_HOST="$_dh"
    fi
  fi
  unset _gw_dh _eng _dh 2>/dev/null || true
fi
OPENSHELL="$(_find /opt/homebrew/bin/openshell /usr/local/bin/openshell)"
BREW="$(_find /opt/homebrew/bin/brew /usr/local/bin/brew)"
# For in-place re-mint: python3 (stdlib only — the minter shells to openssl) + an
# OpenSSL 3.x that can sign the PKCS#8-v2 Ed25519 key (macOS LibreSSL may not).
PYTHON3="$(_find /usr/bin/python3 /opt/homebrew/bin/python3)"
OPENSSL="$(_find /opt/homebrew/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl /usr/bin/openssl)"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
notify() { /usr/bin/osascript -e "display notification \"$1\" with title \"ai-stack watchdog\"" >/dev/null 2>&1 || true; }

# --- subcommands: manage the launchd timer (install/uninstall/status) ---------
PLIST="$HOME/Library/LaunchAgents/com.ai-stack.openshell-watchdog.plist"
LABEL="com.ai-stack.openshell-watchdog"
INTERVAL="${AI_STACK_WATCHDOG_INTERVAL:-180}"   # check every 3 min (was 600; bounds a storm faster)
case "${1:-run}" in
  install)
    mkdir -p "$HOME/Library/LaunchAgents"
    # Persistence: run at boot/login (RunAtLoad) so sandboxes recover after a VM cycle.
    RUNATLOAD="<false/>"; [[ "$PERSIST" == "1" ]] && RUNATLOAD="<true/>"
    cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$AI_STACK/bin/openshell-watchdog.sh</string><string>run</string>
  </array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key>$RUNATLOAD
  <key>EnvironmentVariables</key><dict>
    <key>AI_STACK</key><string>$AI_STACK</string>
    <key>AI_STACK_WATCHDOG_HALT</key><string>${HALT}</string>
    <key>AI_STACK_WATCHDOG_RECREATE</key><string>${RECREATE}</string>
    <key>AI_STACK_WATCHDOG_REMINT</key><string>${REMINT}</string>
    <key>AI_STACK_SANDBOX_PERSIST</key><string>${PERSIST}</string>
    <key>AI_STACK_WATCHDOG_REMINT_THRESHOLD</key><string>${REMINT_THRESHOLD}</string>
    <!-- The `docker` CLI is engine-AGNOSTIC: Docker Desktop / Colima / Podman all
         install it to /opt/homebrew/bin (resolved FIRST by _find, before
         ~/.orbstack/bin), so this PATH works for every engine. The ENGINE itself
         is selected by DOCKER_HOST (exported above from gateway.env / the registry),
         not by which CLI dir is on PATH. -->
    <key>PATH</key><string>${DOCKER:+$(dirname "$DOCKER"):}${OPENSHELL:+$(dirname "$OPENSHELL"):}/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>$STATE/openshell-watchdog.launchd.log</string>
  <key>StandardErrorPath</key><string>$STATE/openshell-watchdog.launchd.log</string>
</dict></plist>
PL
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
    # Fire one cycle NOW so persistence takes effect immediately (don't wait a full
    # interval). RunAtLoad covers boot; this covers install-time + shrinks the post-reboot
    # window where an auto-restarted container could briefly storm before the first cycle.
    launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl start "$LABEL" 2>/dev/null || true
    echo "openshell-watchdog launchd job installed ($LABEL, every ${INTERVAL}s; RunAtLoad=$([[ "$PERSIST" == 1 ]] && echo true || echo false))"; exit 0 ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"; echo "openshell-watchdog launchd job removed"; exit 0 ;;
  status)
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -iE 'state|pid|last exit|runs' | head \
      || echo "launchd job not loaded"
    echo "--- persistence mode (baked into installed plist) ---"
    grep -E 'AI_STACK_WATCHDOG_REMINT|AI_STACK_SANDBOX_PERSIST|RunAtLoad' "$PLIST" 2>/dev/null \
      | sed -E 's/<key>|<\/key>|<string>|<\/string>|<|\/>/ /g; s/  +/ /g; s/^ //' \
      || echo "(plist not installed)"
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

# --- in-place token re-mint (persistence) -----------------------------------
_token_path() {  # _token_path <cid> -> echo sandbox.jwt path (rc 1 if absent)
  local cid="$1" uuid
  uuid="$("$DOCKER" inspect "$cid" --format '{{.Name}}' 2>/dev/null \
    | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  [[ -n "$uuid" && -f "$TOKDIR/$uuid/sandbox.jwt" ]] || return 1
  echo "$TOKDIR/$uuid/sandbox.jwt"
}
_token_secs_left() {  # _token_secs_left <tokenpath> -> echo seconds-to-expiry
  [[ -n "$PYTHON3" && -f "$MINT" && -f "$1" ]] || return 1
  OPENSSL_BIN="$OPENSSL" "$PYTHON3" "$MINT" --token "$1" --exp-only 2>/dev/null
}
_remint_file() {  # _remint_file <name> <tok> -> 0 if a fresh token was written
  [[ -n "$PYTHON3" && -f "$MINT" && -n "$OPENSSL" ]] || { log "  re-mint($1): python3/minter/openssl unavailable"; return 1; }
  OPENSSL_BIN="$OPENSSL" "$PYTHON3" "$MINT" --token "$2" --write >>"$LOG" 2>&1 \
    || { log "  re-mint($1): mint FAILED (original token + .bak intact)"; return 1; }
}
# Reactive heal (PROVEN path): re-mint + docker restart (forces re-bootstrap on the
# fresh token) + relaunch in-sandbox daemons that a restart kills. State in /sandbox
# survives a docker restart, so this is NON-destructive (no delete, no recreate).
_remint_heal() {  # _remint_heal <name> <cid> -> 0 healed
  local name="$1" cid="$2" tok relaunch cpath
  tok="$(_token_path "$cid")" || { log "  re-mint($name): no token file"; return 1; }
  _remint_file "$name" "$tok" || return 1
  "$DOCKER" restart "$cid" >>"$LOG" 2>&1 || { log "  re-mint($name): docker restart failed"; return 1; }
  # rc 2 = minted + restarted but not Ready YET. Caller must NOT fall through to the
  # destructive halt/recreate (that would discard the fresh-token state); next cycle re-checks.
  _verify_ready "$name" || { log "  re-mint($name): minted+restarted, not Ready yet — leaving it for the next cycle"; return 2; }
  # Relaunch in-sandbox daemons a docker restart kills. /sandbox state itself survives a
  # restart. hermes-fleet-v1 runs the persistent Telegram gateway (phase 20); pi-v1 has NO
  # persistent daemon (Pi is launched on demand by bin/pi), so it needs no relaunch.
  case "$name" in hermes-fleet-v1) relaunch="20" ;; *) relaunch="" ;; esac
  if [[ -n "$relaunch" ]]; then
    cpath="$(_child_path)"
    _phase_install "$cpath" $relaunch || log "  re-mint($name): daemon relaunch (phase $relaunch) had issues"
  fi
  return 0
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

  # PERSISTENCE (REMINT=1): try the NON-DESTRUCTIVE in-place re-mint heal FIRST —
  # keeps the SAME sandbox + /sandbox state (no delete, no recreate). Only fall
  # through to the destructive halt/recreate paths if re-mint is unavailable/fails.
  if [[ "$REMINT" == "1" ]]; then
    local _rc=0; _remint_heal "$name" "$cid" || _rc=$?
    if (( _rc == 0 )); then
      log "  HEALED $name via in-place token re-mint + restart (state preserved, no recreate)"
      rm -f "$FAILMARK"; notify "$name token re-minted ✓ (persisted, no data loss)"
      return 0
    elif (( _rc == 2 )); then
      log "  $name re-minted + restarted, awaiting Ready — NOT halting/recreating (fresh-token state preserved; re-checked next cycle)"
      return 0
    fi
    log "  re-mint heal FAILED for $name (mint/restart error, rc=$_rc) — falling back to the halt/recreate path"
  fi

  # DEFAULT (RECREATE!=1): NEVER auto-destroy. With HALT=1 (now default) cap + stop the
  # storming container to kill the CPU burn — non-destructive (writable layer preserved;
  # docker start re-runs it), and the host hang it prevents is NOT recoverable.
  if [[ "$RECREATE" != "1" ]]; then
    log "ALERT: $name has an expired-token storm (cid ${cid:0:12}). NOT auto-deleting (state preserved)."
    log "  Heal when ready (state is checkpointed first; restore via bin/openshell-state-restore.sh):  bash $AI_STACK/vz-ai-stack.sh install $phases"
    if [[ "$HALT" == "1" ]]; then
      # Cap CPU/mem on the LIVE container first so even the detection window cannot
      # starve the host (best-effort: OrbStack may not honor a live cgroup edit — never
      # let that block the stop).
      "$DOCKER" update --cpus 0.5 --memory 2g "$cid" >>"$LOG" 2>&1 \
        && log "  capped storming container to 0.5cpu/2g (bounds the burn)" || true
      # Best-effort checkpoint before halting (halt is non-destructive; this also
      # protects the state as a keep-labeled image against a later prune). Never blocks.
      bash "$AI_STACK/bin/openshell-checkpoint.sh" "$name" storm-halt >>"$LOG" 2>&1 \
        && log "  checkpointed $name before halt (keep-labeled image)" \
        || log "  (pre-halt checkpoint skipped/failed — halt is still non-destructive)"
      "$DOCKER" stop "$cid" >>"$LOG" 2>&1 \
        && log "  halted the container to stop the CPU burn (record preserved; restart/recreate to use it)" \
        || log "  (docker stop failed)"
    fi
    printf '%s expired-token storm at %s — auto-recreate OFF (data-safe; halted+checkpointed). Heal: vz-ai-stack.sh install %s\n' \
      "$name" "$(date '+%F %T')" "$phases" > "$FAILMARK"
    notify "$name token storm — halted+checkpointed; recreate when ready (auto-recreate OFF)"
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
  log "RECREATING $name (opt-in; capability-checked; CHECKPOINT-first; delete+rebuild for a fresh token)"
  notify "$name token expired — checkpointing then auto-recreating"
  # H3 — FAIL-CLOSED: checkpoint must succeed (rc 0) or report no-container (rc 1)
  # before we delete. rc 2 = commit/verify failed → REFUSE to delete (this is exactly
  # the 2026-06-03 'destroy-before-verify → rebuild fails → data lost' vector).
  local _ck_rc=0
  bash "$AI_STACK/bin/openshell-checkpoint.sh" "$name" recreate >>"$LOG" 2>&1 || _ck_rc=$?
  if (( _ck_rc == 2 )); then
    log "  REFUSING to recreate $name: pre-delete checkpoint FAILED — sandbox LEFT INTACT (never delete without a verified backup)."
    printf '%s auto-recreate ABORTED: checkpoint failed at %s — sandbox left intact, needs manual repair\n' "$name" "$(date '+%F %T')" > "$FAILMARK"
    notify "⚠ $name recreate aborted — checkpoint failed; left intact"
    return 0
  fi
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

# Loud guards for the silent-failure configs the review flagged (run once per cycle).
if [[ "$PERSIST" == "1" && "$REMINT" != "1" ]]; then
  log "WARNING: PERSIST=1 but REMINT!=1 — NOT applying restart=unless-stopped (unsafe without the re-mint heal). Re-install with AI_STACK_WATCHDOG_REMINT=1."
fi
if [[ "$REMINT" == "1" ]]; then
  if [[ -z "$OPENSSL" ]] || "$OPENSSL" version 2>/dev/null | grep -qi 'libressl'; then
    log "WARNING: REMINT=1 but no OpenSSL 3.x resolved (got '${OPENSSL:-none}'); macOS LibreSSL cannot sign the gateway key — re-mint WILL fail. Run: brew install openssl@3."
  fi
fi

acted=0
for name in "${SANDBOXES[@]}"; do
  cid="$("$DOCKER" ps -q --filter "name=openshell-${name}-" 2>/dev/null | head -1)"
  [[ -n "$cid" ]] || continue

  # Persistence: keep managed containers on restart=unless-stopped so they survive a
  # docker/system restart (safe now: capped + the storm-heal below re-mints any
  # post-restart storm within one cycle — not the 2026-06-08 uncapped/no-heal vector).
  # restart=unless-stopped is ONLY safe paired with REMINT (the heal that re-mints a
  # post-restart storm). Without REMINT an auto-resurrected sandbox could storm with only
  # the destructive halt/recreate fallback — so require BOTH. (A loud warning for the
  # PERSIST=1/REMINT=0 misconfig is emitted once per cycle below the loop.)
  if [[ "$PERSIST" == "1" && "$REMINT" == "1" ]]; then
    cur_rp="$("$DOCKER" inspect "$cid" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo)"
    [[ "$cur_rp" != "unless-stopped" ]] && { "$DOCKER" update --restart=unless-stopped "$cid" >>"$LOG" 2>&1 \
      && log "persistence: $name restart-policy -> unless-stopped" || true; }
  fi

  storming=0; _is_storming "$cid" && storming=1

  # PROACTIVE re-mint: refresh the token in place BEFORE it expires so the storm never
  # starts. No restart (best-effort — relies on the relay re-reading the file; the
  # reactive storm-heal below is the PROVEN safety net if the relay cached the old token).
  if [[ "$REMINT" == "1" && "$storming" == "0" ]]; then
    tok="$(_token_path "$cid" 2>/dev/null || true)"
    if [[ -n "$tok" ]]; then
      left="$(_token_secs_left "$tok" 2>/dev/null || echo)"
      if [[ "$left" =~ ^-?[0-9]+$ ]] && (( left < REMINT_THRESHOLD )); then
        log "PROACTIVE re-mint $name (~${left}s to expiry < ${REMINT_THRESHOLD}s; in place, no restart)"
        _remint_file "$name" "$tok" && acted=1 || true
      fi
    fi
  fi

  if [[ "$storming" == "1" ]]; then
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
