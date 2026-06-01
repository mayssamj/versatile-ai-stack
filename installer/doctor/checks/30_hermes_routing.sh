# Hermes fleet profiles route LLM calls through LiteLLM (Phase 04f).
#
# hermes-agent v0.15.2 has NO `llm.*` config namespace (the pre-2026-05-30
# bootstrap wrote a dead `llm:` block + a placeholder api_key, so Hermes
# silently never reached local models). The working shape is per-profile:
#   model.provider: custom:litellm
#   providers.litellm.base_url: http://host.docker.internal:4000/v1
# This check confirms the representative hermes_cos profile is wired that way.
# It never prints the api_key. CHANGELOG 2026-05-30.
CHECKS+=(hermes_routing)
CHECK_TITLE[hermes_routing]="Hermes profiles route to LiteLLM (provider=custom:litellm, Phase 04f)"

_hermes_routing_resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""
  fi
}

hermes_routing_diagnose() {
  local osh; osh="$(_hermes_routing_resolve_openshell)"
  if [[ -z "$osh" ]]; then
    echo "openshell CLI not found (Phase 04 not complete)"
    return 1
  fi
  # Sandbox must be Ready before we can exec into it.
  local state
  state="$("$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk 'NR>1 && $1=="hermes-fleet-v1" {print $NF; exit}')"
  if [[ "$state" != "Ready" ]]; then
    echo "sandbox hermes-fleet-v1 not Ready (state='${state:-absent}') — run 'install.sh install 04'"
    return 1
  fi
  # Inspect the rendered profile config WITHOUT printing it (it holds the key).
  local wired
  wired="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 -- bash -c \
    'f="$HOME/.hermes/profiles/hermes_cos/config.yaml"; [[ -f "$f" ]] && grep -q "provider: custom:litellm" "$f" && grep -q "base_url: http://host.docker.internal:4000" "$f" && echo WIRED || echo MISSING' \
    2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
  if [[ "$wired" != "WIRED" ]]; then
    echo "hermes_cos profile is NOT routed to LiteLLM (got '${wired:-no-response}')"
    echo "  Hermes would resolve provider 'auto' and never reach local models."
    return 1
  fi
  # Confirm a Hermes virtual key exists + is accepted by LiteLLM (no value echo).
  local hk
  hk="$(get_env HERMES_LITELLM_KEY '' 2>/dev/null)"
  if [[ -z "$hk" ]]; then
    echo "HERMES_LITELLM_KEY missing from .env (profile wired but no key minted)"
    return 1
  fi
  # If the 'litellm' alias doesn't resolve (prepare-sudo not run), the probe
  # below returns 000 and would mis-report the key as revoked. Defer.
  dscacheutil -q host -a name litellm 2>/dev/null | grep -q ip_address || { echo "(litellm alias unresolved — see checks 15/19) [skip]"; return 0; }
  if ! curl -sf --max-time 5 -H "Authorization: Bearer $hk" http://litellm:4000/v1/models >/dev/null 2>&1; then
    echo "HERMES_LITELLM_KEY present but rejected by LiteLLM /v1/models (key revoked?)"
    return 1
  fi
  return 0
}

hermes_routing_fix() {
  warn "Re-run Phase 04f to (re)mint the Hermes key + configure profile routing:"
  warn "    bash $AI_STACK/install.sh install 04f"
  return 1
}
