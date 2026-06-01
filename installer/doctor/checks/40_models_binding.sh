# Model<->agent binding (installer/models.yml) is valid and rendered everywhere.
#
# Asserts (WARN-skip / advisory where appropriate — never red for an opt-in
# service that is simply down):
#   1. models.yml is valid + every assignment/default resolves to a declared model.
#   2. Every models.yml model is in litellm/config.yaml AND a master-key chat_ping
#      (max_tokens 1) returns 200 — lmstudio models are advisory-yellow when :1234
#      is down (NOT red).
#   3. DRIFT: rendered == declared (availability-gated) across ALL surfaces:
#      the 7 Hermes profiles (exec-grep; NO key echo), Pi (PI_DEFAULT_MODEL +
#      bin/pi), DeerFlow (config.yaml reasoning tier), ACE/RLM (.env).
#   4. ALLOWLIST COVERAGE: for each agent with key_env, GET /v1/models under that
#      key includes the assigned (effective) model. NEVER prints a key.
#
# WARN-skip (return 0) when LiteLLM is down or the hermes sandbox isn't Ready.
# Fix hint: 'bash install.sh model sync'.
CHECKS+=(models_binding)
CHECK_TITLE[models_binding]="Model<->agent binding (models.yml) valid + rendered (install.sh model sync)"

_mb_yml() { echo "$AI_STACK/installer/models.yml"; }
_mb_cfg() { echo "$AI_STACK/litellm/config.yaml"; }

_mb_litellm_up() { curl -sf --max-time 3 http://litellm:4000/health/readiness >/dev/null 2>&1; }
_mb_lms_up()     { curl -s -o /dev/null --max-time 3 http://127.0.0.1:1234/v1/models 2>/dev/null; }

_mb_osh() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""; fi
}
_mb_hermes_ready() {
  local osh; osh="$(_mb_osh)"; [[ -n "$osh" ]] || return 1
  "$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk 'NR>1 && $1=="hermes-fleet-v1" && $NF=="Ready" {ok=1} END{exit !ok}'
}

# Effective (availability-gated) model for an agent, computed the same way
# lib/models.sh does: lmstudio slug only when :1234 up AND served, else default.
_mb_effective() {
  local agent="$1" yml; yml="$(_mb_yml)"
  local declared default rt served
  declared="$(yq -r ".assignments.\"$agent\"" "$yml" 2>/dev/null)"
  default="$(yq -r '.default' "$yml" 2>/dev/null)"
  rt="$(yq -r ".models.\"$declared\".runtime" "$yml" 2>/dev/null)"
  if [[ "$rt" != "lmstudio" ]]; then echo "$declared"; return; fi
  served="$(yq -r ".models.\"$declared\".served" "$yml" 2>/dev/null)"
  if _mb_lms_up && yq -e ".model_list[] | select(.model_name == \"$declared\")" "$(_mb_cfg)" >/dev/null 2>&1; then
    # confirm LiteLLM serves it under the master key
    local key; key="$(get_env LITELLM_MASTER_KEY '')"
    if [[ -n "$key" ]] && curl -s --max-time 5 http://litellm:4000/v1/models -H "Authorization: Bearer $key" 2>/dev/null \
         | python3 -c 'import sys,json; w=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if any(m.get("id")==w for m in d.get("data",[])) else 1)' "$declared"; then
      echo "$declared"; return
    fi
  fi
  echo "$default"
}

# key covers model? (never prints the key)
_mb_key_covers() {
  local key="$1" want="$2"
  [[ -n "$key" ]] || return 1
  curl -s --max-time 5 http://litellm:4000/v1/models -H "Authorization: Bearer $key" 2>/dev/null \
    | python3 -c 'import sys,json; w=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if any(m.get("id")==w for m in d.get("data",[])) else 1)' "$want"
}

models_binding_diagnose() {
  local yml cfg; yml="$(_mb_yml)"; cfg="$(_mb_cfg)"
  command -v yq >/dev/null 2>&1 || { echo "yq not on PATH"; return 1; }
  [[ -f "$yml" ]] || { echo "  (installer/models.yml absent — feature not in use [skip])"; return 0; }

  # (1) Validate via the lib (fail-closed). Reuse lib/models.sh's validate by
  # running `model list` quietly — it exits 2 only on invalid models.yml.
  if ! bash "$AI_STACK/installer/lib/models.sh" list >/dev/null 2>&1; then
    echo "models.yml invalid or unresolvable (run: bash install.sh model list)"
    return 1
  fi

  # WARN-skip when LiteLLM is down (avoid cascade).
  if ! _mb_litellm_up; then
    echo "  (LiteLLM not responding — skipping binding checks; see check 11 + Phase 01)"
    return 0
  fi

  local lms_up=0; _mb_lms_up && lms_up=1
  local master; master="$(get_env LITELLM_MASTER_KEY '' 2>/dev/null || echo '')"
  local fail=0 advisory=""

  # (2) Every models.yml model in config.yaml + chat_ping 200 (lmstudio advisory).
  local m rt
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    rt="$(yq -r ".models.\"$m\".runtime" "$yml" 2>/dev/null)"
    if ! yq -e ".model_list[] | select(.model_name == \"$m\")" "$cfg" >/dev/null 2>&1; then
      echo "model '$m' missing from litellm/config.yaml (run: bash install.sh model sync)"
      fail=1; continue
    fi
    # chat_ping (max_tokens 1)
    local code
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
      http://litellm:4000/v1/chat/completions -H "Authorization: Bearer $master" \
      -H 'Content-Type: application/json' \
      -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}" 2>/dev/null || echo 000)"
    if [[ "$code" != "200" ]]; then
      if [[ "$rt" == "lmstudio" && "$lms_up" != "1" ]]; then
        advisory="${advisory}    (advisory) lmstudio model '$m' not servable — LM Studio :1234 down (HTTP $code)\n"
      else
        echo "model '$m' chat_ping returned HTTP $code (expected 200)"
        fail=1
      fi
    fi
  done < <(yq -r '.models | keys | .[]' "$yml")

  # (3)+(4) DRIFT + ALLOWLIST coverage across every agent surface.
  local hermes_ready=0; _mb_hermes_ready && hermes_ready=1
  local a kind keyenv eff rendered
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    kind="$(yq -r ".kinds.\"$a\".kind" "$yml" 2>/dev/null)"
    keyenv="$(yq -r ".kinds.\"$a\".key_env // \"\"" "$yml" 2>/dev/null)"
    eff="$(_mb_effective "$a")"

    # ALLOWLIST coverage (skip if no key_env; deerflow uses master key).
    if [[ -n "$keyenv" && "$keyenv" != "null" ]]; then
      local kv; kv="$(get_env "$keyenv" '' 2>/dev/null || echo '')"
      if [[ -z "$kv" ]]; then
        echo "agent '$a' key_env $keyenv missing from .env (run the phase or: bash install.sh model sync)"
        fail=1
      else
        if ! _mb_key_covers "$kv" "$eff"; then
          echo "agent '$a' scoped key does NOT allow its effective model '$eff' (run: bash install.sh model sync)"
          fail=1
        fi
        # Superset-drift guard (review #6): scoped keys are minted with the FULL
        # canonical superset (see 'install.sh model superset'), so a phase/bridge
        # that hardcoded a stale/narrow allowlist is caught HERE rather than
        # silently 403-ing a future `model assign`. Only assert for canonical IDs
        # actually registered in config.yaml.
        local _cm
        for _cm in local-qwen3.6 local-qwen3-coder; do
          if yq -e ".model_list[] | select(.model_name == \"$_cm\")" "$cfg" >/dev/null 2>&1 \
             && ! _mb_key_covers "$kv" "$_cm"; then
            echo "agent '$a' scoped key $keyenv missing canonical '$_cm' (superset drift — run: bash install.sh model sync)"
            fail=1
          fi
        done
      fi
    fi

    # DRIFT: rendered == effective.
    rendered=""
    case "$kind" in
      pi)  rendered="$(get_env PI_DEFAULT_MODEL '' 2>/dev/null || echo '')" ;;
      ace) rendered="$(get_env ACE_DEFAULT_MODEL '' 2>/dev/null || echo '')" ;;
      rlm) rendered="$(get_env RLM_MODEL '' 2>/dev/null || echo '')" ;;
      deerflow)
        local df="$AI_STACK/deer-flow/config.yaml"
        [[ -f "$df" ]] && rendered="$(yq -r '.models[] | select(.name == "local-heavy") | .model' "$df" 2>/dev/null | head -1)" ;;
      hermes-profile)
        if [[ "$hermes_ready" == "1" ]]; then
          local osh profile; osh="$(_mb_osh)"; profile="$(yq -r ".kinds.\"$a\".profile" "$yml" 2>/dev/null)"
          rendered="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty -- bash -c \
            "grep -E '^[[:space:]]*model:' \"\$HOME/.hermes/profiles/$profile/config.yaml\" 2>/dev/null | head -1 | awk '{print \$2}'" \
            2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
        fi ;;
    esac
    # Only flag DRIFT when we could actually read a rendered value AND the
    # surface exists. Unreadable (sandbox not ready / .env not present) => skip.
    if [[ -n "$rendered" && "$rendered" != "$eff" ]]; then
      echo "agent '$a' DRIFT: rendered='$rendered' but declared/effective='$eff' (run: bash install.sh model sync)"
      fail=1
    fi
  done < <(yq -r '.assignments | keys | .[]' "$yml")

  if [[ -n "$advisory" ]]; then printf '%b' "$advisory"; fi
  (( fail == 0 )) || return 1
  echo "  (models.yml valid; every model wired + servable; no drift; scoped keys cover assignments)"
  return 0
}

models_binding_fix() {
  warn "Re-render every agent + the LiteLLM model_list from installer/models.yml:"
  warn "    bash $AI_STACK/install.sh model sync"
  return 1
}
