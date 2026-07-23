# Hermes fleet profiles route LLM calls through LiteLLM (Phase 04f).
#
# hermes-agent v0.15.2 has NO `llm.*` config namespace (the pre-2026-05-30
# bootstrap wrote a dead `llm:` block + a placeholder api_key, so Hermes
# silently never reached local models). The working shape is per-profile:
#   model.provider: custom:litellm
#   providers.litellm.base_url: http://host.docker.internal:4000/v1
# This check confirms the representative hermes_manager profile is wired that way.
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
    echo "sandbox hermes-fleet-v1 not Ready (state='${state:-absent}') — run 'mayssam-ai-stack.sh install 04'"
    return 1
  fi
  # Inspect the rendered profile config WITHOUT printing it (it holds the key).
  local wired
  wired="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 -- bash -c \
    'f="$HOME/.hermes/profiles/hermes_manager/config.yaml"; [[ -f "$f" ]] && grep -q "provider: custom:litellm" "$f" && grep -q "base_url: http://host.docker.internal:4000" "$f" && echo WIRED || echo MISSING' \
    2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
  if [[ "$wired" != "WIRED" ]]; then
    echo "hermes_manager profile is NOT routed to LiteLLM (got '${wired:-no-response}')"
    echo "  Hermes would resolve provider 'auto' and never reach local models."
    return 1
  fi
  # Frankenfleet guard: the in-sandbox profile SET must equal the models.yml roster.
  # A half-run / interrupted 04f rebuild can leave stale OLD profiles or a mixed set
  # (REPLACE semantics). Compare sorted sets (ignore the built-in `default`).
  if command -v yq >/dev/null 2>&1; then
    local want got
    want="$(yq -r '.kinds | to_entries | map(select(.value.kind=="hermes-profile")) | .[].key' "$AI_STACK/installer/models.yml" 2>/dev/null | sort | tr '\n' ' ')"
    got="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 -- /bin/sh -c 'ls -1 "$HOME"/.hermes/profiles 2>/dev/null' 2>/dev/null \
      | sed $'s/\x1b\\[[0-9;]*m//g' | grep -vxE '[[:space:]]*|default' | sort | tr '\n' ' ')"
    if [[ -n "$want" && "$got" != "$want" ]]; then
      echo "in-sandbox hermes profile set != models.yml roster (stale/half-built fleet)"
      echo "  want: $want"
      echo "  got:  $got"
      return 1
    fi
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
  if ! litellm_scoped_curl "$hk" -sf --max-time 5 http://litellm:4000/v1/models >/dev/null 2>&1; then
    if declare -F litellm_db_down >/dev/null && litellm_db_down; then
      echo "LiteLLM key-store DOWN (503 no_db_connection) — NOT a bad key. Heal the DB (check 05a / start honcho-database); do NOT re-mint."
      return 1
    fi
    echo "HERMES_LITELLM_KEY present but rejected by LiteLLM /v1/models (key revoked?)"
    return 1
  fi
  # GW-3: a key that LISTS /v1/models can still be LOCAL-ONLY while the profiles route to CLOUD —
  # LiteLLM enforces the allow-list SERVER-SIDE, so the bot would 403 every DM (the drift a
  # standalone `install 04f` self-heal could leave; the minted allow-list and the bound model are
  # two sources of truth — L9). Read the ACTUAL bound model from the live hermes_manager config
  # (no availability-gate guesswork) and, when it is a CLOUD model, assert the key covers it.
  local bound kmodels
  # Read the bound model.default from the live config. Require the `default:` be INDENTED (so a
  # stray top-level `default:` can't match — it's nested under `model:`), and STRIP YAML quotes on
  # the host side (a quoted `default: "claude-opus-sub-max"` would otherwise keep the quotes and
  # never match the bare model id in the key allow-list -> a false-positive doctor failure).
  bound="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 -- /bin/sh -c \
    'f="$HOME/.hermes/profiles/hermes_manager/config.yaml"; sed -n "s/^[[:space:]][[:space:]]*default:[[:space:]]*//p" "$f" 2>/dev/null | head -1' \
    2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]' | sed 's/["'\'']//g')"
  if [[ -n "$bound" && "$bound" != local && "$bound" != local-* ]]; then
    kmodels="$(litellm_scoped_curl "$hk" -s --max-time 5 http://litellm:4000/key/info 2>/dev/null \
      | python3 -c 'import sys,json
try: d=json.load(sys.stdin); m=(d.get("info") or {}).get("models") or []
except Exception: sys.exit(0)
print("__wildcard__" if (not m or any(x in ("all-proxy-models","all-team-models") for x in m)) else "\n".join(m))' 2>/dev/null || true)"
    if [[ -n "$kmodels" ]] && ! grep -qxF '__wildcard__' <<<"$kmodels" && ! grep -qxF "$bound" <<<"$kmodels"; then
      echo "HERMES_LITELLM_KEY does NOT cover the bound cloud model '$bound' (key is local-scoped) — gateway DMs would 403 server-side"
      echo "  Heal: mayssam-ai-stack.sh install 04f  (now reconciles the key to the bound models)"
      return 1
    fi
  fi
  return 0
}

hermes_routing_fix() {
  warn "Re-run Phase 04f to (re)mint the Hermes key + configure profile routing:"
  warn "    bash $AI_STACK/mayssam-ai-stack.sh install 04f"
  return 1
}
