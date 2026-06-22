# OpenShell gateway is UP on :17670 AND manageable via brew services.
#
# Closes two gaps that NO other check covered (the user-reported blind spot:
# "install warns that openshell isn't a brew service, but doctor doesn't detect
#  nor fix it"):
#
#   1. LIVENESS. The gateway is a HOST launchd process, not a container — so the
#      container-liveness census (check 53) EXPLICITLY excludes `openshell-*` and
#      never sees it, and check 39 only catches the in-sandbox token-storm. Nothing
#      asserted the gateway PORT itself is up. If :17670 is dead the whole OpenShell
#      fleet is dead while doctor stays green. -> hard FAIL.
#
#   2. MANAGEABILITY. Recent Homebrew REFUSES to load a formula from an untrusted
#      third-party tap (nvidia/openshell), so `brew services list` SILENTLY OMITS
#      openshell even when its formula + launchd plist are installed and the gateway
#      is running. Phase 04 then takes its "(uv-installed only?)" else-branch and
#      SURRENDERS lifecycle management — engine-switch restart (04_openshell.sh DOCKER_HOST
#      block) and crash recovery (lib/openshell.sh tier-3 `brew services restart`)
#      are DISABLED. The gateway still WORKS, so this is a DEGRADED-not-down state;
#      but the doctor harness has no WARN state and a PASSING check's output is muted
#      (doctor.sh runs diagnose with `>/dev/null 2>&1` on the pass path), so a green
#      here would re-create the exact "doctor doesn't detect it" blind spot the user
#      reported. We therefore surface it as a FAIL that clears the moment the
#      documented action is taken. (§24 council debated green+[WARN] vs red and chose
#      red precisely because green is invisible on the default `doctor` run.)
#
# Read-only. There is intentionally NO `_fix`: the only remediation for the
# untrusted-tap case is `brew trust nvidia/openshell`, which tells Homebrew to load
# and EXECUTE that tap's arbitrary Ruby — a security-posture change (team-protocol
# §5). It must be a human decision, never auto-healed. The remediation is printed
# in the diagnose detail (shown on failure) instead.
#
# NOTE on brew calls: macOS has no `timeout`/`gtimeout` by default and there is no
# portable timeout helper in lib/, so the `brew services` calls below follow the
# repo-wide un-timed pattern (phase 04 itself calls `brew services` un-timed). A
# portable timeout wrapper is a tracked follow-up; `brew services info` on an
# untrusted tap errors fast in practice.

# Namespaced (every check is sourced into one shell — a bare GATEWAY_PORT would leak).
# Hardcoded to match GATEWAY_PORT=17670 in installer/phases/04_openshell.sh and the
# port_listening 17670 in installer/lib/openshell.sh — keep all three in sync. (No env
# override here: it would imply a port contract that phase 04 / the lib don't honor.)
_54_GW_PORT=17670

CHECKS+=(openshell_gateway)
CHECK_TITLE[openshell_gateway]="OpenShell gateway up on :$_54_GW_PORT & brew-manageable"

# Is the openshell binary installed at all? (brew Cellar symlink first, then PATH —
# the same precedence Phase 04's resolve_openshell uses.)
_osg_installed() {
  [[ -x /opt/homebrew/bin/openshell ]] || command -v openshell >/dev/null 2>&1
}

# Seam so the smoke can drive the brew-absent (uv/pipx-only) path hermetically.
_osg_has_brew() { command -v brew >/dev/null 2>&1; }

openshell_gateway_diagnose() {
  # Not installed -> OpenShell isn't in use on this box. Nothing to assert.
  if ! _osg_installed; then
    echo "openshell not installed — OpenShell not in use here. [skip]"
    return 0
  fi

  # Is the gateway port listening? (port_listening: installer/lib/validate.sh, sourced
  # by doctor.sh — also used by check 23.)
  local up=no; port_listening "$_54_GW_PORT" && up=yes

  # Can brew manage it? Non-empty state in `brew services list` == brew can see it.
  # On a box with no brew at all (uv/pipx-only install) there is no brew lifecycle.
  local have_brew=no; _osg_has_brew && have_brew=yes
  local svc="" untrusted=no
  if [[ "$have_brew" == yes ]]; then
    svc="$(brew services list 2>/dev/null | awk '$1=="openshell"{print $2; exit}')"
    # Distinguish the untrusted-tap cause: recent Homebrew refuses to LOAD the formula.
    # The pattern is anchored to openshell so a generic load-refusal elsewhere can't
    # misfire. NOTE: this matches Homebrew's CURRENT error prose; if a future Homebrew
    # changes the wording, detection degrades to the generic "no brew service" cause
    # below — the check still REDS (svc stays empty), only the cause line is less specific.
    if [[ -z "$svc" ]]; then
      grep -qiE 'untrusted tap|Refusing to load formula.*openshell' \
        <<<"$(brew services info openshell 2>&1 || true)" && untrusted=yes
    fi
  fi

  local logp; logp="$(brew --prefix 2>/dev/null || echo /opt/homebrew)/var/log/openshell.log"

  # --- DOWN: the hard failure — the fleet can't run. ---
  if [[ "$up" == no ]]; then
    echo "gateway DOWN: nothing listening on :$_54_GW_PORT (the OpenShell fleet can't run)."
    if [[ "$untrusted" == yes ]]; then
      echo "  cause: brew can't manage it (untrusted tap) AND it isn't running."
      echo "  start: brew trust nvidia/openshell && brew services start openshell"
      echo "         (brew-independent: launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/homebrew.mxcl.openshell.plist)"
    elif [[ "$have_brew" == yes ]]; then
      echo "  start: brew services start openshell"
    else
      echo "  start (no brew on PATH): launchctl bootstrap gui/\$(id -u) ~/Library/LaunchAgents/homebrew.mxcl.openshell.plist"
    fi
    echo "  diagnose: tail -50 $logp"
    return 1
  fi

  # --- UP but UNMANAGEABLE: DEGRADED, not down. The gateway WORKS; only brew-managed
  #     lifecycle (engine-switch restart, crash recovery) is unavailable. ---
  if [[ -z "$svc" ]]; then
    echo "gateway UP on :$_54_GW_PORT and WORKING, but UNMANAGEABLE via brew services (DEGRADED, not an outage)."
    if [[ "$untrusted" == yes ]]; then
      echo "  cause: Homebrew won't load formula nvidia/openshell/openshell (untrusted tap),"
      echo "         so 'brew services' can't see it -> engine-switch restart + crash recovery are DISABLED."
      echo "  [SECURITY DECISION] restore brew lifecycle by trusting the tap (runs its code): brew trust nvidia/openshell"
    elif [[ "$have_brew" == no ]]; then
      echo "  cause: brew is not on PATH (uv/pipx install) — there is no brew-managed lifecycle."
      echo "         engine-switch restart + crash recovery are unavailable; start/stop the gateway manually."
    else
      echo "  cause: no brew service for openshell (the formula has no service, or a non-brew install)."
      echo "         brew-managed lifecycle (engine-switch restart, crash recovery) is unavailable."
    fi
    return 1
  fi

  # UP + brew-manageable. (An 'error'/'stopped' brew state with the port still up
  # means someone started it manually — user-facing reality is fine, so: green.)
  echo "  (gateway up on :$_54_GW_PORT; brew service state: $svc)"
  return 0
}
