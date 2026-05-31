# litellm.sh — callback chain helpers.
# Sourced after common.sh + env.sh + docker.sh.
#
# Per Reviewer A #1: file-first, list-second, recreate-third, verify-fourth.
# Callback files that don't exist would crash LiteLLM at startup with
# ImportError. Always assert file exists + Python import succeeds before
# yq-mutating config.yaml.

[[ -z "${AI_STACK:-}" ]] && { echo "litellm.sh: AI_STACK unset" >&2; exit 2; }

LITELLM_CONFIG="$AI_STACK/litellm/config.yaml"

# litellm_has_callback MODULE
# Returns 0 if MODULE is in litellm_settings.callbacks list of config.yaml.
litellm_has_callback() {
  local mod="$1"
  yq -r '.litellm_settings.callbacks[]?' "$LITELLM_CONFIG" 2>/dev/null \
    | grep -qxF "$mod"
}

# litellm_ensure_callback MODULE [FILE_RELATIVE_TO_LITELLM_DIR]
# If FILE is given, verify it exists before adding. Mutate config.yaml
# idempotently (unique list). Caller is responsible for recreating LiteLLM
# afterwards (or calling litellm_recreate_and_verify).
litellm_ensure_callback() {
  local mod="$1" file="${2:-}"
  if [[ -n "$file" ]]; then
    if [[ ! -f "$AI_STACK/litellm/$file" ]]; then
      err "litellm callback file missing: litellm/$file"
      return 1
    fi
  fi
  if litellm_has_callback "$mod"; then
    note "callback already present: $mod"
    return 0
  fi
  yq -i ".litellm_settings.callbacks |= ((. // []) + [\"$mod\"] | unique)" "$LITELLM_CONFIG"
  ok "added callback: $mod"
}

# litellm_remove_callback MODULE
litellm_remove_callback() {
  local mod="$1"
  if ! litellm_has_callback "$mod"; then
    return 0
  fi
  yq -i ".litellm_settings.callbacks |= ((. // []) - [\"$mod\"])" "$LITELLM_CONFIG"
  ok "removed callback: $mod"
}

# Issue a chat completion. Returns 0 on HTTP 200.
litellm_chat_ping() {
  local model="${1:-local}"
  local key; key="$(get_env LITELLM_MASTER_KEY)"
  curl -s -o /dev/null -w '%{http_code}\n' \
    --max-time 30 \
    ${LITELLM_BASE_URL:-http://litellm:4000}/v1/chat/completions \
    -H "Authorization: Bearer $key" \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$model\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}" \
  | grep -qx '200'
}

# Wait for /v1/models to return a non-empty list (LiteLLM ready signal).
litellm_wait_ready() {
  local timeout="${1:-60}" i=0
  local key; key="$(get_env LITELLM_MASTER_KEY)"
  while (( i < timeout )); do
    if curl -s --max-time 3 ${LITELLM_BASE_URL:-http://litellm:4000}/v1/models \
        -H "Authorization: Bearer $key" 2>/dev/null \
        | grep -q '"data"'; then
      return 0
    fi
    sleep 1
    i=$((i+1))
  done
  err "LiteLLM /v1/models did not respond within ${timeout}s"
  return 1
}

# Assert a callback was loaded by inspecting docker logs.
litellm_assert_callback_loaded() {
  local mod="$1" since="${2:-1m}"
  if docker logs --since "$since" litellm 2>&1 \
       | grep -qiE "${mod}|$(echo "$mod" | tr '.' '_')|arize_phoenix"; then
    return 0
  fi
  warn "callback '$mod' not seen in recent litellm logs (may still be working — verify smoke test)"
  return 1
}
