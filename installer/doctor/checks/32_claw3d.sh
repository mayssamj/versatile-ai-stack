# claw3d 3D agent office + stack-agents bridge healthy (Phase 19).
#
# Verifies the bridge serves its custom-runtime contract (/health + /state with
# agents) and the claw3d UI responds. Skips cleanly (passes) when claw3d was
# never installed. Does NOT exercise the agents (that needs the OpenShell relay
# + would be slow) — only the bridge contract + UI liveness.
CHECKS+=(claw3d)
CHECK_TITLE[claw3d]="claw3d office + stack-agents bridge healthy (Phase 19)"

_claw3d_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 4 "$1" 2>/dev/null || echo 000; }

claw3d_diagnose() {
  local bridge="http://127.0.0.1:${CLAW3D_BRIDGE_PORT:-7780}"
  local ui="http://127.0.0.1:${CLAW3D_PORT:-4310}"
  # Not installed → skip (optional UI tooling).
  if [[ ! -d "$AI_STACK/claw3d/node_modules" ]]; then
    echo "claw3d not installed — run 'install.sh install 19' to add it. [skip]"
    return 0
  fi
  [[ -f "$AI_STACK/claw3d-bridge/bridge.py" ]] || { echo "claw3d-bridge/bridge.py missing — re-run 'install 19'"; return 1; }
  if [[ "$(_claw3d_code "$bridge/health")" == "000" ]]; then
    echo "bridge not serving on $bridge — start: bash $AI_STACK/bin/start-claw3d-bridge.sh"
    return 1
  fi
  # bridge /state should enumerate agents
  local n
  n="$(curl -s --max-time 4 "$bridge/state" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("active",{})))' 2>/dev/null || echo 0)"
  if [[ "${n:-0}" -lt 1 ]]; then echo "bridge /state lists no agents (got ${n:-0})"; return 1; fi
  if [[ "$(_claw3d_code "$ui/")" == "000" ]]; then
    echo "claw3d UI not serving on $ui — start: bash $AI_STACK/bin/start-claw3d.sh"
    return 1
  fi
  echo "  (bridge: $n agents; UI up at $ui — open in a browser, click Connect)"
  return 0
}

claw3d_fix() {
  warn "Restart the bridge + claw3d UI:"
  warn "    bash $AI_STACK/bin/start-claw3d-bridge.sh && bash $AI_STACK/bin/start-claw3d.sh"
  warn "Or re-run the phase:  bash $AI_STACK/install.sh install 19"
  bash "$AI_STACK/bin/start-claw3d-bridge.sh" >/dev/null 2>&1 || true
  bash "$AI_STACK/bin/start-claw3d.sh" >/dev/null 2>&1 || true
  return 1
}
