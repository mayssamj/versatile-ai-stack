# Sourcegraph fleet MCP (opt-in Phase 27). GRACEFUL by design: when Sourcegraph
# is not installed (no token at ~/.sourcegraph-local/sg-token) this returns 0 with
# a neutral skip note — it must NEVER red-bar a healthy stack that simply didn't
# opt into code search.
#
# When SG IS installed it verifies, fast (ALWAYS-ON):
#   1. the durable network-policy stanza `sourcegraph_mcp` is present in the
#      committed policy (drift guard — catches a stanza-less regeneration), AND
#   2. if a Hermes fleet sandbox is Ready, that a representative profile actually
#      carries the mcp_servers.sourcegraph stanza (fleet wired).
# With --all / OPENSHELL_DOCTOR_SLOW=1 it also does a LIVE check: the sandbox can
# reach SG through the landlock (not policy_denied) AND SG's MCP endpoint is alive
# with a valid token. It NEVER uses `hermes mcp test` (verified buggy vs SG — its
# probe sends a bad Accept and 400s); the real keyword_search E2E lives in the
# smoke test (installer/smoke/27.sh → `vz-ai-stack.sh test sourcegraph`).
CHECKS+=(sourcegraph_mcp)
CHECK_TITLE[sourcegraph_mcp]="Sourcegraph fleet MCP (opt-in): policy stanza + fleet wiring (skip-clean when SG absent)"

_sg_mcp_resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""
  fi
}

sourcegraph_mcp_diagnose() {
  local tok_file="$HOME/.sourcegraph-local/sg-token"
  # (0) Not installed → skip-clean (opt-in; never red-bar).
  if [[ ! -s "$tok_file" ]]; then
    echo "(Sourcegraph not installed — opt-in Phase 27; skip)"
    return 0
  fi

  local fails=()

  # (1) ALWAYS-ON drift guard: the durable stanza must be in the committed policy
  # (the 04_openshell.sh heredoc regenerates this file; a stanza-less copy means
  # the next install 04 / recreate would silently drop SG reachability).
  local policy="$AI_STACK/openshell/policies/hermes-fleet-v1.yaml"
  if [[ -f "$policy" ]] && grep -q 'sourcegraph_mcp' "$policy"; then
    :
  else
    fails+=("  network-policy stanza 'sourcegraph_mcp' MISSING from $policy (durable reachability regression — re-add to the 04_openshell.sh heredoc)")
  fi

  # (2) Container installed-but-stopped → soft note, still pass (start it).
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx sourcegraph; then
    echo "  (SG token present but container stopped — run: vz-ai-stack.sh start sourcegraph)"
  fi

  local osh; osh="$(_sg_mcp_resolve_openshell)"
  local sandbox_ready=0
  if [[ -n "$osh" ]] && "$osh" sandbox list 2>/dev/null \
       | sed $'s/\x1b\\[[0-9;]*m//g' \
       | awk 'NR>1 && $1=="hermes-fleet-v1" && $NF=="Ready" {ok=1} END{exit !ok}'; then
    sandbox_ready=1
  fi

  # (3) ALWAYS-ON (when a fleet exists): a representative profile must be wired.
  if (( sandbox_ready )); then
    local wired
    wired="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 </dev/null -- bash -c \
      'f="$HOME/.hermes/profiles/hermes_manager/config.yaml"; [[ -f "$f" ]] && grep -q "sourcegraph:" "$f" && grep -q "host.docker.internal:7080" "$f" && echo WIRED || echo MISSING' \
      2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
    if [[ "$wired" != "WIRED" ]]; then
      fails+=("  hermes_manager profile is NOT wired to Sourcegraph MCP (got '${wired:-no-response}') — run: vz-ai-stack.sh install 04f")
    fi
  else
    echo "  (no Hermes fleet sandbox Ready — nothing to wire yet)"
  fi

  # (S) SLOW / --all: live reachability through the landlock + SG MCP liveness.
  if [[ "${OPENSHELL_DOCTOR_SLOW:-0}" == "1" ]] || [[ "${DOCTOR_ALL:-0}" == "1" ]]; then
    if (( sandbox_ready )); then
      local body
      body="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 15 </dev/null -- \
        curl -s --connect-timeout 3 --max-time 6 -w '\n__C_%{http_code}' http://host.docker.internal:7080/ 2>/dev/null || echo '__C_000')"
      if grep -q 'policy_denied' <<<"$body"; then
        fails+=("  LIVE: sandbox→SG is policy_denied (sourcegraph_mcp not in the LIVE applied policy — re-run: vz-ai-stack.sh install 04, or install 27 re-applies it)")
      fi
    fi
    # SG MCP liveness + token validity (host side; never prints the token).
    local mcp_code
    mcp_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 -X POST http://localhost:7080/.api/mcp \
      -H "Authorization: token $(cat "$tok_file")" -H 'Content-Type: application/json' \
      -H 'Accept: application/json, text/event-stream' \
      -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"doctor","version":"1"}}}' 2>/dev/null || echo 000)"
    [[ "$mcp_code" == "200" ]] || fails+=("  LIVE: SG MCP initialize returned HTTP $mcp_code (expected 200 — SG down or token invalid)")
  else
    echo "  (static checks only; set OPENSHELL_DOCTOR_SLOW=1 or run 'doctor --all' for the live reachability + MCP probe)"
  fi

  if (( ${#fails[@]} > 0 )); then
    printf '%s\n' "${fails[@]}"
    return 1
  fi
  return 0
}

sourcegraph_mcp_fix() {
  warn "Sourcegraph fleet MCP not fully wired. To deploy + bootstrap + wire in one step:"
  warn "    vz-ai-stack.sh install sourcegraph"
  warn "If SG is already up and only the fleet needs (re)wiring:"
  warn "    vz-ai-stack.sh install 04f"
  warn "If the LIVE policy lacks the stanza (sandbox→SG policy_denied), re-apply it:"
  warn "    vz-ai-stack.sh install 04        # regenerates + applies the sourcegraph_mcp stanza"
  return 1
}
