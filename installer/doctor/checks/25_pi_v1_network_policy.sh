# pi-v1's network policy is enforcing: allowlisted destinations are reachable
# from inside the sandbox, denied destinations return the OpenShell egress
# proxy's deny signature: HTTP 403 with body
#   {"detail":"GET host:port/ not permitted by policy","error":"policy_denied"}
# We grep for "policy_denied" in the body — that's the unambiguous proxy
# deny marker. Allowed destinations may return any other HTTP code (200,
# 401, 404 are all "destination reached"); they will NOT contain
# "policy_denied" since the proxy only emits that string when denying.
#
# This check runs the FAST positive probes by default (3 destinations × 2s
# timeout = ~6s). The full denied-set sweep (~9 destinations × 2s = ~18s)
# only runs when OPENSHELL_DOCTOR_SLOW=1 or `bash vz-ai-stack.sh doctor --all`.
#
# What this check does NOT prove:
#   - Honcho peer-level isolation between Pi and Hermes (Honcho v3 has no
#     API-key-scoped peer enforcement; isolation is by namespace convention)
#   - That a prompt-injected Pi can't *try* to query forbidden services —
#     the policy just makes those attempts fail at the network layer
CHECKS+=(pi_v1_network_policy)
CHECK_TITLE[pi_v1_network_policy]="pi-v1 network policy: LiteLLM/docs-mcp reachable; raw Honcho :8000 + ai-stack DBs denied"

_pi_v1_np_resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""
  fi
}

# Probe a (host, port) from inside the sandbox. Returns:
#   echoes "OK"   if the proxy forwarded (any HTTP code from the actual server)
#   echoes "DENY" if the proxy refused (body contains "policy_denied")
#   echoes "WEIRD <code>" otherwise (TCP failure, timeout, etc.)
_pi_v1_np_probe() {
  local osh="$1" host="$2" port="$3"
  local body code
  body="$("$osh" sandbox exec -n pi-v1 --no-tty --timeout 15 -- \
    curl -s --connect-timeout 2 --max-time 3 -w '\n__CODE_%{http_code}' \
    "http://${host}:${port}/" 2>/dev/null || echo '__CODE_000')"
  code="$(echo "$body" | awk '/__CODE_/{sub(/^.*__CODE_/,""); print; exit}')"
  body="$(echo "$body" | sed 's/__CODE_.*//')"
  if grep -q 'policy_denied' <<<"$body"; then
    echo DENY
    return
  fi
  case "$code" in
    2??|3??|4??) echo OK ;;
    000|502|503|522) echo DENY ;;  # TCP-layer deny (rare; proxy usually returns 403 body)
    *) echo "WEIRD $code" ;;
  esac
}

pi_v1_network_policy_diagnose() {
  local osh; osh="$(_pi_v1_np_resolve_openshell)"
  [[ -n "$osh" ]] || { echo "openshell CLI not found"; return 1; }

  # Sandbox must be Ready (check 24 covers the create path).
  # openshell sandbox list emits ANSI color codes; strip them before matching.
  "$osh" sandbox list 2>/dev/null \
    | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk 'NR>1 && $1=="pi-v1" && $NF=="Ready" {ok=1} END{exit !ok}' \
    || { echo "pi-v1 not Ready — see check 24"; return 1; }

  local fails=()

  # ─── POSITIVE probes (always run; ~6s) ───
  # Allowlisted destinations per openshell/policies/pi-v1.yaml.
  local positives=(
    "host.docker.internal:4000:LiteLLM"
    "host.docker.internal:8765:docs-mcp"
  )
  local entry host port label result
  for entry in "${positives[@]}"; do
    IFS=: read -r host port label <<<"$entry"
    result="$(_pi_v1_np_probe "$osh" "$host" "$port")"
    case "$result" in
      OK) ;;
      *) fails+=("  $label ($host:$port): expected OK, got $result") ;;
    esac
  done

  # ─── NEGATIVE probes (slow; only run with --all / OPENSHELL_DOCTOR_SLOW=1) ───
  if [[ "${OPENSHELL_DOCTOR_SLOW:-0}" == "1" ]] || [[ "${DOCTOR_ALL:-0}" == "1" ]]; then
    local negatives=(
      "host.docker.internal:8000:Honcho-raw"
      "host.docker.internal:7082:honcho-mcp"
      "host.docker.internal:7083:falkordb-mcp"
      "host.docker.internal:6006:Phoenix"
      "host.docker.internal:6333:Qdrant"
      "host.docker.internal:6379:FalkorDB"
      "host.docker.internal:3001:OpenWebUI"
      "host.docker.internal:3000:Workspace"
      "host.docker.internal:8898:Unsloth"
      "host.docker.internal:3100:Paperclip"
      "host.docker.internal:3400:AutoFyn"
      "example.com:443:public-internet"
    )
    for entry in "${negatives[@]}"; do
      IFS=: read -r host port label <<<"$entry"
      result="$(_pi_v1_np_probe "$osh" "$host" "$port")"
      case "$result" in
        DENY) ;;
        *) fails+=("  $label ($host:$port): expected DENY, got $result (policy leak?)") ;;
      esac
    done
  else
    echo "  (positive probes only; set OPENSHELL_DOCTOR_SLOW=1 to also run 9 negative probes)"
  fi

  if (( ${#fails[@]} > 0 )); then
    printf '%s\n' "${fails[@]}"
    return 1
  fi
}

pi_v1_network_policy_fix() {
  warn "Reapply policy + restart sandbox to refresh enforcement:"
  warn "    openshell policy set pi-v1 --policy $AI_STACK/openshell/policies/pi-v1.yaml --wait"
  warn "If positive probes fail, check that LiteLLM dual-binds 127.0.0.1:4000"
  warn "(see bin/start-litellm.sh; CHANGELOG 2026-05-29 entry on host.docker.internal)."
  return 1
}
