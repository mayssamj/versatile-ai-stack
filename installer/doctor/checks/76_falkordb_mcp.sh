# FalkorDB graph-memory MCP (opt-in Phase 41). GRACEFUL: skip-clean when not installed.
#
# When installed it verifies: (drift-guard) the falkordb_mcp (:7083) shim egress is PRESENT for
# the fleet AND no sandbox policy targets raw falkordb:6379 (the token-gated shim must be the
# only path — sandboxes never reach raw FalkorDB); the claude-cli stdio registration; the shim's
# /healthz; and per-profile fleet wiring. Unlike check 75 (honcho) there is no retired-egress to
# assert — slice 4 is purely additive — but the "no raw :6379 egress" guard keeps it that way.
CHECKS+=(falkordb_mcp)
CHECK_TITLE[falkordb_mcp]="FalkorDB graph memory MCP (opt-in): shim wired + raw :6379 denied (skip-clean when absent)"

_falkordb_mcp_resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""
  fi
}

falkordb_mcp_diagnose() {
  # (0) Not installed → skip-clean (opt-in Phase 41).
  if ! compgen -G "$AI_STACK/installer/state/phase_41*.done" >/dev/null 2>&1; then
    echo "(FalkorDB graph memory not installed — opt-in Phase 41: vz-ai-stack.sh install falkordb_mcp; skip)"
    return 0
  fi

  local fails=()
  local fpol="$AI_STACK/openshell/policies/hermes-fleet-v1.yaml"
  local ppol="$AI_STACK/openshell/policies/pi-v1.yaml"

  # (1) DRIFT-GUARD: shim egress present for the fleet; raw :6379 NEVER opened to a sandbox.
  grep -qE '^[[:space:]]*falkordb_mcp:' "$fpol" 2>/dev/null || fails+=("  falkordb_mcp (:7083) shim egress MISSING from hermes-fleet-v1.yaml — re-run 'vz-ai-stack.sh install 04'")
  grep -qE '^[[:space:]]*port:[[:space:]]*6379\b' "$fpol" "$ppol" 2>/dev/null && fails+=("  SECURITY: a sandbox-policy endpoint targets raw falkordb :6379 — sandboxes must reach FalkorDB only via the :7083 shim")

  # (2) claude-cli registration (if the claude CLI is present).
  if command -v claude >/dev/null 2>&1; then
    claude mcp list 2>/dev/null | grep -q '^falkordb[: ]' || fails+=("  claude-cli MCP 'falkordb' not registered — run: vz-ai-stack.sh install falkordb_mcp")
  fi

  # (3) shim health (the fleet's http daemon). /healthz also reports FalkorDB reachability.
  local port; port="$(get_env FALKORDB_MCP_PORT '7083')"
  local hz; hz="$(curl -s --max-time 3 "http://127.0.0.1:$port/healthz" 2>/dev/null || true)"
  if [[ -z "$hz" ]]; then
    fails+=("  falkordb-mcp shim not answering on 127.0.0.1:$port — start it: vz-ai-stack.sh start falkordb_mcp")
  elif ! grep -q '"falkordb":true' <<<"$hz"; then
    echo "  (shim up but FalkorDB backend unreachable per /healthz — check falkordb is running)"
  fi

  # (4) fleet wiring — only when a hermes-fleet-v1 sandbox is Ready.
  local osh; osh="$(_falkordb_mcp_resolve_openshell)"
  if [[ -n "$osh" ]] && "$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
       | awk 'NR>1 && $1=="hermes-fleet-v1" && $NF=="Ready"{ok=1} END{exit !ok}'; then
    local wired
    wired="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 </dev/null -- bash -c \
      'f="$HOME/.hermes/profiles/hermes_manager/config.yaml"; [[ -f "$f" ]] && grep -q "falkordb:" "$f" && grep -q "host.docker.internal:7083" "$f" && echo WIRED || echo MISSING' \
      2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
    [[ "$wired" == "WIRED" ]] || fails+=("  hermes_manager profile NOT wired to FalkorDB MCP (got '${wired:-no-response}') — run: vz-ai-stack.sh install falkordb_mcp")
  fi

  if (( ${#fails[@]} > 0 )); then
    printf '%s\n' "${fails[@]}"
    return 1
  fi
  return 0
}

falkordb_mcp_fix() {
  warn "FalkorDB graph memory MCP not fully wired (or a raw :6379 sandbox egress appeared). Install/re-assert:"
  warn "    vz-ai-stack.sh install falkordb_mcp"
  return 1
}
