# OpenShell-watchdog alert — surfaces a pending watchdog event so it can NEVER be
# silent again. The watchdog (bin/openshell-watchdog.sh) writes
# installer/state/openshell-watchdog.alert when it detects an expired-token storm
# (default = warn-only, sandbox NOT deleted) or when an OPT-IN auto-recreate failed.
# Background: on 2026-06-03 the old watchdog auto-deleted both sandboxes and could
# not rebuild them (docker not on its PATH), logging a false "done". This check is
# the loud, visible backstop for that class of failure.
CHECKS+=(watchdog_alert)
CHECK_TITLE[watchdog_alert]="OpenShell watchdog has no pending storm/destroy alert"

watchdog_alert_diagnose() {
  local mark="$AI_STACK/installer/state/openshell-watchdog.alert"
  [[ -f "$mark" ]] || { echo "(no watchdog alert — sandboxes not flagged)"; return 0; }
  echo "OpenShell watchdog raised an alert (a sandbox hit an expired-token storm):"
  sed 's/^/    /' "$mark"
  echo "  Heal: recreate the affected sandbox(es) — e.g. 'mayssam-ai-stack.sh install 04 04f 15 20 04h'."
  echo "  (Recreate now CHECKPOINTS in-sandbox state FIRST; restore it with: bash $AI_STACK/bin/openshell-state-restore.sh <name>.)"
  echo "  Then clear this alert: rm '$mark'  (or it clears automatically on a verified auto-recreate)."
  return 1
}

watchdog_alert_fix() {
  # Non-destructive on purpose: recreation loses in-sandbox state, so it stays a
  # deliberate human action. We only point at the heal command.
  warn "Watchdog alert present — recreate when ready (recreate CHECKPOINTS state first; restore via openshell-state-restore.sh):"
  warn "    bash $AI_STACK/mayssam-ai-stack.sh install 04 04f 15 20 04h"
  warn "Then: rm $AI_STACK/installer/state/openshell-watchdog.alert"
  return 1
}
