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

  # Shared, StartedAt-gated detector (one source of truth with the installer +
  # watchdog). The legacy inline `--since 3m` grep here counted PRE-restart logs too,
  # so doctor reported a FALSE STORM for ~3 min after a watchdog heal; storm_detect
  # gates on the container's last restart so a just-healed sandbox reads green.
  [[ -f "$AI_STACK/installer/lib/storm-detect.sh" ]] && source "$AI_STACK/installer/lib/storm-detect.sh"
  local storming="" unknown="" cid rc
  for name in hermes-fleet-v1 pi-v1; do
    cid="$("$docker" ps -q --filter "name=openshell-${name}-" 2>/dev/null | head -1)"
    [[ -n "$cid" ]] || continue
    if declare -F storm_detect >/dev/null 2>&1; then
      rc=0; storm_detect "$docker" "$cid" || rc=$?
      case "$rc" in
        0) storming="${storming}${name} ";;
        2) unknown="${unknown}${name} ";;   # wedged-docker read — UNKNOWN, not green
      esac
    else
      local logs; logs="$("$docker" logs "$cid" --since 3m --tail 60 2>&1 || true)"
      { grep -q 'ExpiredSignature' <<<"$logs" \
        || (( $(grep -cE 'log push (stream lost, reconnecting|reconnected \(attempt)' <<<"$logs") >= 8 )); } \
        && storming="${storming}${name} "
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
    [[ -n "$unknown" ]] && echo "  note: also could NOT read logs for [${unknown% }] (docker wedged/timeout) — their storm status is UNKNOWN, re-check when responsive"
    echo "  Heal now (HALT-by-default, non-destructive): bash $AI_STACK/bin/openshell-watchdog.sh run   (watchdog: $wd)"
    return 1
  fi
  echo "  (no token-storm on the sandboxes; auto-healing watchdog: $wd)"
  [[ -n "$unknown" ]] && echo "  note: could not read logs for [${unknown% }] (docker wedged/timeout) — storm status UNKNOWN, re-check when the daemon is responsive"
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
