# OpenShell sandboxes are not in an expired-token CPU storm (+ watchdog installed).
#
# Guards the failure that has hit twice: a sandbox's gateway token expires (1h, verified 2026-06-08),
# the in-sandbox agent retries log-push with NO backoff (hundreds/sec) →
# "ExpiredSignature" / "reconnecting" storm pegging ~36% CPU per sandbox. This
# check FAILS if a live storm is detected, and notes whether the auto-healing
# launchd watchdog (bin/openshell-watchdog.sh) is loaded. Read-only; no recreate.
CHECKS+=(openshell_storm)
CHECK_TITLE[openshell_storm]="OpenShell sandboxes not in a token-expiry CPU storm (Phase 04 watchdog)"

_oss_docker() {
  for p in /opt/homebrew/bin/docker "$HOME/.orbstack/bin/docker" /usr/local/bin/docker; do
    [[ -x "$p" ]] && { echo "$p"; return 0; }
  done
  command -v docker 2>/dev/null || echo ""
}

openshell_storm_diagnose() {
  local docker; docker="$(_oss_docker)"
  [[ -n "$docker" ]] || { echo "docker not found — OpenShell not in use here. [skip]"; return 0; }

  # Watchdog launchd job loaded? (informational — surfaced, not a hard fail.)
  local wd="not loaded"
  launchctl print "gui/$(id -u)/com.ai-stack.openshell-watchdog" >/dev/null 2>&1 && wd="loaded"

  local storming="" cid logs
  for name in hermes-fleet-v1 pi-v1; do
    cid="$("$docker" ps -q --filter "name=openshell-${name}-" 2>/dev/null | head -1)"
    [[ -n "$cid" ]] || continue
    logs="$("$docker" logs "$cid" --since 3m --tail 60 2>&1 || true)"
    if grep -q 'ExpiredSignature' <<<"$logs" \
       || (( $(grep -cE 'log push (stream lost, reconnecting|reconnected \(attempt)' <<<"$logs") >= 8 )); then
      storming="${storming}${name} "
    fi
  done

  # H10 — surface prune-vulnerable stopped sandboxes: a `docker container prune` would
  # wipe their writable layer (all in-sandbox state). Non-failing note.
  local stopped
  stopped="$("$docker" ps -aq --filter "name=openshell-" --filter "status=exited" 2>/dev/null | wc -l | tr -d ' ')"

  # H4 migration — warn if the watchdog plist is STALE (predates the HALT/RECREATE env
  # keys); a stale plist runs warn-only regardless of code defaults. Re-install fixes it.
  local plist="$HOME/Library/LaunchAgents/com.ai-stack.openshell-watchdog.plist"
  local stale_plist=""
  [[ "$wd" == "loaded" && -f "$plist" ]] && ! grep -q 'AI_STACK_WATCHDOG_HALT' "$plist" 2>/dev/null && stale_plist=1

  if [[ -n "$storming" ]]; then
    echo "STORM: sandbox(es) [${storming% }] are in an expired-token retry loop (high CPU)."
    echo "  Heal now (HALT-by-default, non-destructive): bash $AI_STACK/bin/openshell-watchdog.sh run   (watchdog: $wd)"
    return 1
  fi
  echo "  (no token-storm on the sandboxes; auto-healing watchdog: $wd)"
  [[ "${stopped:-0}" != "0" ]] && echo "  note: $stopped stopped OpenShell container(s) on disk — checkpoint before any 'docker container prune': bash $AI_STACK/bin/openshell-checkpoint.sh <name>"
  [[ -n "$stale_plist" ]] && echo "  note: watchdog plist is STALE (no HALT env) → runs warn-only. Refresh: bash $AI_STACK/bin/openshell-watchdog.sh install"
  return 0
}

openshell_storm_fix() {
  warn "Run the watchdog to detect + (HALT-by-default, non-destructive) bound any storming sandbox:"
  warn "    bash $AI_STACK/bin/openshell-watchdog.sh run"
  warn "Ensure the periodic guard is installed (regenerates the plist with the HALT/RECREATE env):"
  warn "    bash $AI_STACK/bin/openshell-watchdog.sh install"
  # H6 — HARD-PIN RECREATE=0 so 'doctor --fix' can NEVER inherit an ambient
  # AI_STACK_WATCHDOG_RECREATE=1 and silently delete sandboxes without a checkpoint
  # (the 2026-06-03 repeat vector). The watchdog caps + halts the storm — data-safe.
  AI_STACK_WATCHDOG_RECREATE=0 bash "$AI_STACK/bin/openshell-watchdog.sh" run >/dev/null 2>&1 || true
  return 1
}
