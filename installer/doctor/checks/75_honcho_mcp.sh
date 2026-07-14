# Honcho memory MCP (opt-in Phase 40). GRACEFUL: skip-clean when not installed — never
# red-bar a stack that didn't opt into honcho memory.
#
# When installed, the SECURITY-CRITICAL part is a DRIFT-GUARD: the raw auth-off Honcho REST
# egress (honcho_memory / :8000) must stay RETIRED from BOTH sandbox policies AND the
# 04_openshell.sh generator (a regression re-opens the auth-off hole to sandboxed agents),
# and the honcho_mcp (:7082) shim stanza must be present for the fleet. It also verifies the
# claude-cli stdio registration, the shim's health, and per-profile fleet wiring.
CHECKS+=(honcho_mcp)
CHECK_TITLE[honcho_mcp]="Honcho memory MCP (opt-in): raw :8000 egress retired + shim wired (skip-clean when absent)"

_honcho_mcp_resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""
  fi
}

honcho_mcp_diagnose() {
  # (0) Not installed → skip-clean (opt-in Phase 40).
  if ! compgen -G "$AI_STACK/installer/state/phase_40*.done" >/dev/null 2>&1; then
    echo "(honcho memory not installed — opt-in Phase 40: HONCHO_MEMORY_OPT_IN=1 vz-ai-stack.sh install honcho_mcp; skip)"
    return 0
  fi

  local fails=()
  local gen="$AI_STACK/installer/phases/04_openshell.sh"
  local fpol="$AI_STACK/openshell/policies/hermes-fleet-v1.yaml"
  local ppol="$AI_STACK/openshell/policies/pi-v1.yaml"

  # (1) SECURITY DRIFT-GUARD (always-on): the raw honcho_memory (:8000) egress must be GONE
  # from the generator + both committed policies; the honcho_mcp (:7082) shim stanza present.
  grep -qE '^[[:space:]]*honcho_memory:' "$gen"  2>/dev/null && fails+=("  SECURITY: raw honcho_memory (:8000) egress is BACK in installer/phases/04_openshell.sh — it must stay retired")
  grep -qE '^[[:space:]]*honcho_memory:' "$fpol" 2>/dev/null && fails+=("  SECURITY: raw honcho_memory (:8000) egress is BACK in hermes-fleet-v1.yaml — must stay retired")
  grep -qE '^[[:space:]]*honcho_memory:' "$ppol" 2>/dev/null && fails+=("  SECURITY: raw honcho_memory (:8000) egress is BACK in pi-v1.yaml — must stay retired")
  grep -qE '^[[:space:]]*honcho_mcp:' "$fpol" 2>/dev/null || fails+=("  honcho_mcp (:7082) shim egress MISSING from hermes-fleet-v1.yaml — re-run 'vz-ai-stack.sh install 04'")

  # (2) claude-cli registration (if the claude CLI is present).
  if command -v claude >/dev/null 2>&1; then
    claude mcp list 2>/dev/null | grep -q '^honcho[: ]' || fails+=("  claude-cli MCP 'honcho' not registered — run: HONCHO_MEMORY_OPT_IN=1 vz-ai-stack.sh install honcho_mcp")
  fi

  # (3) shim health (the fleet's http daemon). /healthz also reports honcho reachability.
  local port; port="$(get_env HONCHO_MCP_PORT '7082')"
  local hz; hz="$(curl -s --max-time 3 "http://127.0.0.1:$port/healthz" 2>/dev/null || true)"
  if [[ -z "$hz" ]]; then
    fails+=("  honcho-mcp shim not answering on 127.0.0.1:$port — start it: vz-ai-stack.sh start honcho_mcp")
  elif ! grep -q '"honcho":true' <<<"$hz"; then
    echo "  (shim up but Honcho backend unreachable per /healthz — check honcho is running)"
  fi

  # (4) fleet wiring — only when a hermes-fleet-v1 sandbox is Ready.
  local osh; osh="$(_honcho_mcp_resolve_openshell)"
  if [[ -n "$osh" ]] && "$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
       | awk 'NR>1 && $1=="hermes-fleet-v1" && $NF=="Ready"{ok=1} END{exit !ok}'; then
    local wired
    wired="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 </dev/null -- bash -c \
      'f="$HOME/.hermes/profiles/hermes_manager/config.yaml"; [[ -f "$f" ]] && grep -q "honcho:" "$f" && grep -q "host.docker.internal:7082" "$f" && echo WIRED || echo MISSING' \
      2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
    [[ "$wired" == "WIRED" ]] || fails+=("  hermes_manager profile NOT wired to honcho MCP (got '${wired:-no-response}') — run: vz-ai-stack.sh install honcho_mcp")
  fi

  if (( ${#fails[@]} > 0 )); then
    printf '%s\n' "${fails[@]}"
    return 1
  fi
  return 0
}

honcho_mcp_fix() {
  warn "Honcho memory MCP not fully wired, or a SECURITY regression (raw :8000 egress back) was found."
  warn "Install / re-assert:  HONCHO_MEMORY_OPT_IN=1 vz-ai-stack.sh install honcho_mcp"
  warn "If honcho_memory (:8000) reappeared in a policy, revert it (it MUST stay retired) + 'install 04'."
  return 1
}
