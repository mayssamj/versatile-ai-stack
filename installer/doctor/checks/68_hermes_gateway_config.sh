# Hermes gateway CONFIG complete + self-healing from a host snapshot (companion to watchdog W5).
#
# The gateway config (model/provider/fallback + SLACK_ALLOWED_USERS/HOME) lives in the sandbox's
# EPHEMERAL /sandbox/.hermes/config.yaml. A sandbox recreate, or a relay-hang during Phase 04f's
# `hermes config set`, can GUT it (seen 2026-06-29: a 2-line config — no model/provider → the bot
# can't infer AND Slack auth breaks at once). This check keeps a HOST snapshot of a COMPLETE config
# and RESTORES it when the live config is gutted (self-heal), then relaunches the gateway. Skips
# cleanly when the hermes-fleet sandbox isn't running. Uses docker (NOT the openshell relay, which
# HANGS under the very thrash that causes the gut). NEVER prints the scoped key the config holds.
source "$AI_STACK/installer/lib/hermes.sh" 2>/dev/null || true
CHECKS+=(hermes_gateway_config)
CHECK_TITLE[hermes_gateway_config]="Hermes gateway config complete (self-heal from host snapshot)"

hermes_gateway_config_diagnose() {
  local live
  live="$(hermes_gw_config_read 2>/dev/null)" || { echo "hermes-fleet sandbox not running — skip"; return 0; }
  # PROMOTABLE (healthy cloud) → keep the host snapshot fresh. PASS.
  if hermes_gw_config_promotable "$live"; then
    hermes_gw_snapshot >/dev/null 2>&1 || true
    echo "  (complete cloud config: model+provider present; host snapshot refreshed)"
    return 0
  fi
  # GUTTED (a true truncation) → self-heal from a healthy snapshot.
  if hermes_gw_config_gutted "$live"; then
    if hermes_gw_restore >/dev/null 2>&1; then
      _hermes_gw_relaunch_docker || true
      echo "  AUTO-HEALED: gateway config was GUTTED (no model/provider) — restored from host snapshot + relaunched gateway"
      return 0
    fi
    echo "gateway config is GUTTED (no model/provider) and no healthy host snapshot — re-run 'vz-ai-stack.sh install 04f'"
    return 1
  fi
  # Complete-but-LOCAL (won't snapshot — a restore would load a local model + OOM) — surface, don't fail.
  if hermes_gw_config_complete "$live"; then
    echo "  gateway config is COMPLETE but the default model looks LOCAL — NOT snapshotting (a local restore would OOM the box). Set a cloud default if unintended: 'vz-ai-stack.sh model ...'"
    return 0
  fi
  # Incomplete but NOT a clean gut (large — possible Hermes schema change) — do NOT auto-restore.
  echo "gateway config is INCOMPLETE but not a clean truncation (schema change?) — NOT auto-restoring. Inspect: 'vz-ai-stack.sh hermes config show'"
  return 1
}

hermes_gateway_config_fix() {
  warn "Restore or rebuild the Hermes gateway config:"
  warn "  vz-ai-stack.sh hermes config restore     # from the host snapshot (installer/state/)"
  warn "  vz-ai-stack.sh install 04f               # rebuild the per-profile + gateway config"
  warn "  NOTE: after a destructive sandbox RECREATE the Slack allowlist also needs"
  warn "        HERMES_SLACK_ALLOWED_USERS in the host .env (or re-run 'hermes slack allow <id>')."
  return 1
}
