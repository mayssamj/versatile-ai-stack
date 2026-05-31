# pi-v1 OpenShell sandbox exists, Ready, and using a current policy hash.
#
# The sandbox is Pi's quarantine (see Phase 15). It must be Ready before
# anything in bin/pi works. We also compute the sha256 of the local
# pi-v1.yaml policy and warn if the sandbox is running an older policy
# (you've edited the YAML but haven't restarted the sandbox).
CHECKS+=(pi_v1_sandbox)
CHECK_TITLE[pi_v1_sandbox]="pi-v1 OpenShell sandbox is Ready (Phase 15)"

_pi_v1_resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""
  fi
}

pi_v1_sandbox_diagnose() {
  local osh; osh="$(_pi_v1_resolve_openshell)"
  if [[ -z "$osh" ]]; then
    echo "openshell CLI not found (Phase 04 not complete)"
    return 1
  fi
  # openshell sandbox list emits ANSI color codes; strip them before matching.
  local state
  state="$("$osh" sandbox list 2>/dev/null \
    | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk 'NR>1 && $1=="pi-v1" {print $NF; exit}')"
  if [[ -z "$state" ]]; then
    echo "sandbox pi-v1 does not exist — run 'bash install.sh install 15'"
    return 1
  fi
  if [[ "$state" != "Ready" ]]; then
    echo "sandbox pi-v1 is in state '$state' (expected Ready)"
    return 1
  fi
  # Policy hash drift: warn (not fail) if the on-disk YAML doesn't match
  # the policy the sandbox loaded. OpenShell doesn't surface the loaded
  # hash directly, so this check is informational only.
  local policy="$AI_STACK/openshell/policies/pi-v1.yaml"
  if [[ -f "$policy" ]]; then
    local sha
    sha="$(shasum -a 256 "$policy" 2>/dev/null | awk '{print substr($1,1,12)}')"
    [[ -n "$sha" ]] && echo "  (policy file sha256: $sha — re-apply with 'openshell policy set pi-v1 --policy $policy' after edits)"
  fi
}

pi_v1_sandbox_fix() {
  warn "Re-run Phase 15 to recreate the sandbox + apply current policy:"
  warn "    bash $AI_STACK/install.sh install 15"
  return 1
}
