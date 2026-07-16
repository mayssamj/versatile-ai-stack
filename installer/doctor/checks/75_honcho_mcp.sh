# Honcho memory MCP (Phase 40 — DEFAULT-ON under `install all --include-optionals` since
# 2026-07-16; opt OUT with HONCHO_MEMORY_OPT_IN=0). GRACEFUL: skip-clean when not installed —
# never red-bar a stack that declined honcho memory, or one installed before it went default-on.
#
# When installed, the SECURITY-CRITICAL part is a DRIFT-GUARD: the raw auth-off Honcho REST
# egress (honcho_memory / :8000) must stay RETIRED from BOTH sandbox policies AND the
# 04_openshell.sh generator (a regression re-opens the auth-off hole to sandboxed agents),
# and the honcho_mcp (:7082) shim stanza must be present for the fleet. It also verifies the
# claude-cli stdio registration, the shim's health, and per-profile fleet wiring.
CHECKS+=(honcho_mcp)
CHECK_TITLE[honcho_mcp]="Honcho memory MCP (default-on): raw :8000 egress retired + shim wired (skip-clean when declined)"

_honcho_mcp_resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""
  fi
}

honcho_mcp_diagnose() {
  # (0) Not installed → skip-clean (Phase 40 declined via HONCHO_MEMORY_OPT_IN=0, or the stack
  # predates the 2026-07-16 default-on flip).
  if ! compgen -G "$AI_STACK/installer/state/phase_40*.done" >/dev/null 2>&1; then
    echo "(honcho memory not installed — Phase 40 is default-on under 'install all --include-optionals'; this stack declined it (HONCHO_MEMORY_OPT_IN=0) or predates it. Wire it: vz-ai-stack.sh install honcho_mcp; skip)"
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
  # PORT-based guard (name-independent): a renamed stanza pointing at :8000 must not slip past
  # the name grep above — assert NO sandbox-policy endpoint targets port 8000 (raw honcho REST).
  grep -qE '^[[:space:]]*port:[[:space:]]*8000\b' "$fpol" "$ppol" 2>/dev/null && fails+=("  SECURITY: a sandbox-policy endpoint targets port 8000 (raw honcho REST) — must stay retired regardless of the stanza name")

  # (2) claude-cli registration (if the claude CLI is present).
  if command -v claude >/dev/null 2>&1; then
    claude mcp list 2>/dev/null | grep -q '^honcho[: ]' || fails+=("  claude-cli MCP 'honcho' not registered — run: vz-ai-stack.sh install honcho_mcp")
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
  # The endpoint is checked against $port (from HONCHO_MCP_PORT, resolved at :48), NOT a
  # hardcoded 7082: this probe used to hardcode it while (3) above honoured the env var, so a
  # custom-port install red-barred here forever no matter how correctly the fleet was wired.
  # $port is passed as an ARGV parameter (not interpolated into the script body) so "$HOME"
  # still expands INSIDE the sandbox. NB: openshell's gRPC exec rejects newlines — keep the
  # -c program on ONE line.
  local osh; osh="$(_honcho_mcp_resolve_openshell)"
  if [[ -n "$osh" ]] && "$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
       | awk 'NR>1 && $1=="hermes-fleet-v1" && $NF=="Ready"{ok=1} END{exit !ok}'; then
    local wired
    wired="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 </dev/null -- bash -c \
      'f="$HOME/.hermes/profiles/hermes_manager/config.yaml"; [[ -f "$f" ]] && grep -q "honcho:" "$f" && grep -q "host.docker.internal:$1" "$f" && echo WIRED || echo MISSING' \
      _ "$port" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
    [[ "$wired" == "WIRED" ]] || fails+=("  hermes_manager profile NOT wired to honcho MCP (got '${wired:-no-response}') — run: vz-ai-stack.sh install honcho_mcp")
  fi

  # (5) LIVE negative probe (slow / --all): the running fleet sandbox must be DENIED raw
  # honcho:8000 at the network layer. The static drift-guard above only catches SOURCE drift;
  # this catches a flaky Phase-40 live policy-apply that left the pre-retirement policy live
  # (committed files correct, running sandbox still exposed). Mirrors check 25's probe.
  if [[ "${OPENSHELL_DOCTOR_SLOW:-0}" == "1" ]] || [[ "${DOCTOR_ALL:-0}" == "1" ]]; then
    if [[ -n "$osh" ]] && "$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
         | awk 'NR>1 && $1=="hermes-fleet-v1" && $NF=="Ready"{ok=1} END{exit !ok}'; then
      local body; body="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 15 </dev/null -- \
        curl -s --connect-timeout 3 --max-time 6 -w '\n__C_%{http_code}' http://host.docker.internal:8000/ 2>/dev/null || echo '__C_000')"
      if grep -q 'policy_denied' <<<"$body" || grep -qE '__C_(000|403|502|503|522)$' <<<"$body"; then
        : # denied at the network layer — good
      else
        fails+=("  LIVE-SECURITY: hermes-fleet-v1 can still REACH raw honcho:8000 (egress NOT denied — Phase 40's live policy-apply likely failed). Re-apply: vz-ai-stack.sh install 04")
      fi
    fi
  else
    echo "  (static drift-guard only; set OPENSHELL_DOCTOR_SLOW=1 for the LIVE :8000-denied probe from inside the fleet)"
  fi

  if (( ${#fails[@]} > 0 )); then
    printf '%s\n' "${fails[@]}"
    return 1
  fi
  return 0
}

honcho_mcp_fix() {
  warn "Honcho memory MCP not fully wired, or a SECURITY regression (raw :8000 egress back) was found."
  warn "Install / re-assert:  vz-ai-stack.sh install honcho_mcp"
  warn "If honcho_memory (:8000) reappeared in a policy, revert it (it MUST stay retired) + 'install 04'."
  return 1
}
