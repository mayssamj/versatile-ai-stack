# FalkorDB graph-memory MCP (opt-in Phase 41). GRACEFUL: skip-clean when not installed.
#
# When installed it verifies: (drift-guard) the falkordb_mcp (:7083) shim egress is PRESENT for
# the fleet AND no sandbox policy targets raw falkordb:6379 (the token-gated shim must be the
# only path — sandboxes never reach raw FalkorDB); the claude-cli stdio registration; the shim's
# /healthz; per-profile fleet wiring; and (under --all/OPENSHELL_DOCTOR_SLOW) a LIVE Redis-PING
# probe from inside the fleet asserting raw :6379 is denied. Unlike check 75 (honcho) there is no
# retired-egress to assert — slice 4 is purely additive — but the "no raw :6379 egress" guards
# (static + live) keep it that way.
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
    echo "(FalkorDB graph memory not installed — opt-in Phase 41: mayssam-ai-stack.sh install falkordb_mcp; skip)"
    return 0
  fi

  local fails=()
  local fpol="$AI_STACK/openshell/policies/hermes-fleet-v1.yaml"
  local ppol="$AI_STACK/openshell/policies/pi-v1.yaml"

  # (1) DRIFT-GUARD: shim egress present for the fleet; raw :6379 NEVER opened to a sandbox.
  grep -qE '^[[:space:]]*falkordb_mcp:' "$fpol" 2>/dev/null || fails+=("  falkordb_mcp (:7083) shim egress MISSING from hermes-fleet-v1.yaml — re-run 'mayssam-ai-stack.sh install 04'")
  grep -qE '^[[:space:]]*port:[[:space:]]*6379\b' "$fpol" "$ppol" 2>/dev/null && fails+=("  SECURITY: a sandbox-policy endpoint targets raw falkordb :6379 — sandboxes must reach FalkorDB only via the :7083 shim")

  # (2) claude-cli registration (if the claude CLI is present).
  if command -v claude >/dev/null 2>&1; then
    claude mcp list 2>/dev/null | grep -q '^falkordb[: ]' || fails+=("  claude-cli MCP 'falkordb' not registered — run: mayssam-ai-stack.sh install falkordb_mcp")
  fi

  # (3) shim health (the fleet's http daemon). /healthz also reports FalkorDB reachability.
  local port; port="$(get_env FALKORDB_MCP_PORT '7083')"
  local hz; hz="$(curl -s --max-time 3 "http://127.0.0.1:$port/healthz" 2>/dev/null || true)"
  if [[ -z "$hz" ]]; then
    fails+=("  falkordb-mcp shim not answering on 127.0.0.1:$port — start it: mayssam-ai-stack.sh start falkordb_mcp")
  elif ! grep -q '"falkordb":true' <<<"$hz"; then
    echo "  (shim up but FalkorDB backend unreachable per /healthz — check falkordb is running)"
  fi

  # (4) fleet wiring — only when a hermes-fleet-v1 sandbox is Ready.
  # The endpoint is checked against $port (from FALKORDB_MCP_PORT, resolved at :41), NOT a
  # hardcoded 7083: this probe used to hardcode it while (3) above honoured the env var, so a
  # custom-port install red-barred here forever no matter how correctly the fleet was wired.
  # $port is passed as an ARGV parameter (not interpolated into the script body) so "$HOME"
  # still expands INSIDE the sandbox. NB: openshell's gRPC exec rejects newlines — keep the
  # -c program on ONE line.
  local osh; osh="$(_falkordb_mcp_resolve_openshell)"
  if [[ -n "$osh" ]] && "$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
       | awk 'NR>1 && $1=="hermes-fleet-v1" && $NF=="Ready"{ok=1} END{exit !ok}'; then
    local wired
    wired="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 </dev/null -- bash -c \
      'f="$HOME/.hermes/profiles/hermes_manager/config.yaml"; [[ -f "$f" ]] && grep -q "falkordb:" "$f" && grep -q "host.docker.internal:$1" "$f" && echo WIRED || echo MISSING' \
      _ "$port" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
    [[ "$wired" == "WIRED" ]] || fails+=("  hermes_manager profile NOT wired to FalkorDB MCP (got '${wired:-no-response}') — run: mayssam-ai-stack.sh install falkordb_mcp")
  fi

  # (5) LIVE negative probe (slow / --all): the running fleet sandbox must be DENIED raw
  # falkordb:6379 at the network layer. The static drift-guard (1) only catches SOURCE drift;
  # this catches a live policy that diverged from the committed files (sandbox actually exposed).
  # NB: :6379 speaks Redis (RESP), not HTTP — a curl http-code probe (like check 75's :8000 one)
  # can't tell "denied" from "reachable-but-not-HTTP" (both surface as 000), so we send a real
  # Redis PING over /dev/tcp: only a genuinely-reachable raw Redis replies +PONG. (Residual, as in
  # check 75: if FalkorDB itself is down, connect-refused also looks "denied" — best-effort live check.)
  if [[ "${OPENSHELL_DOCTOR_SLOW:-0}" == "1" ]] || [[ "${DOCTOR_ALL:-0}" == "1" ]]; then
    if [[ -n "$osh" ]] && "$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
         | awk 'NR>1 && $1=="hermes-fleet-v1" && $NF=="Ready"{ok=1} END{exit !ok}'; then
      local pong; pong="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 15 </dev/null -- \
        bash -c 'exec 3<>/dev/tcp/host.docker.internal/6379 2>/dev/null && printf "PING\r\n" >&3 && { IFS= read -t 4 -r line <&3 2>/dev/null; printf "%s" "$line"; }' \
        2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g')"
      if grep -q 'PONG' <<<"$pong"; then
        fails+=("  LIVE-SECURITY: hermes-fleet-v1 can REACH raw falkordb:6379 (got a Redis PONG — egress NOT denied). Sandboxes must reach FalkorDB only via the :7083 shim. Re-apply: mayssam-ai-stack.sh install 04")
      fi
    fi
  else
    echo "  (static drift-guard only; set OPENSHELL_DOCTOR_SLOW=1 for the LIVE :6379-denied probe from inside the fleet)"
  fi

  if (( ${#fails[@]} > 0 )); then
    printf '%s\n' "${fails[@]}"
    return 1
  fi
  return 0
}

falkordb_mcp_fix() {
  warn "FalkorDB graph memory MCP not fully wired (or a raw :6379 sandbox egress appeared). Install/re-assert:"
  warn "    mayssam-ai-stack.sh install falkordb_mcp"
  return 1
}
