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
  if [[ -z "$key" ]]; then
    err "LITELLM_MASTER_KEY is empty — run 'vz-ai-stack.sh install 00' (or 'setup') to generate it before starting LiteLLM"
    return 2
  fi
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

# litellm_smoke_ok KEY — return 0 if /v1/models returns a model list, trying
# several addresses so it works regardless of host networking quirks (macOS lo0
# aliases / OrbStack vs a plain Linux Docker host). The docker-published host
# port is the machine-agnostic ground truth, so we always include it.
litellm_smoke_ok() {
  local key="$1" url
  [[ -n "$key" ]] || return 2   # empty key → fast-fail; caller reports + diagnoses
  local -a urls=(
    "${LITELLM_BASE_URL:-http://litellm:4000}"
    "http://127.0.0.1:4000"
    "http://127.0.10.1:4000"
  )
  # Also try whatever host port the container actually publishes for 4000 (a busy
  # host may remap it). `docker port` → e.g. "0.0.0.0:4000" / "127.0.0.1:14000";
  # take the trailing :PORT, require it to be numeric, and skip 4000 (already listed).
  local hp; hp="$(docker port litellm 4000 2>/dev/null | head -1 | sed -E 's#.*:([0-9]+)$#\1#')"
  [[ "$hp" =~ ^[0-9]+$ && "$hp" != "4000" ]] && urls+=("http://127.0.0.1:${hp}")
  for url in "${urls[@]}"; do
    if curl -s --max-time 5 "${url}/v1/models" -H "Authorization: Bearer $key" 2>/dev/null \
         | grep -q '"data"'; then
      return 0
    fi
  done
  return 1
}

# litellm_diagnose — print an actionable, secret-free diagnostic when LiteLLM
# won't serve. Designed so a failing install on a remote/cold machine EXPLAINS
# itself instead of dying on a bare "did not return a model list".
litellm_diagnose() {
  local key; key="$(get_env LITELLM_MASTER_KEY "")"
  warn "──── LiteLLM diagnostics ────────────────────────────────────────"
  if container_running litellm 2>/dev/null; then
    warn "container   : running ($(docker ps --filter 'name=^litellm$' --format '{{.Status}}' 2>/dev/null))"
  else
    warn "container   : NOT running — start it: bash $AI_STACK/bin/start-litellm.sh"
  fi
  warn "published   : $(docker port litellm 2>/dev/null | tr '\n' ' ' || echo '(none)')"
  if (echo > /dev/tcp/127.0.0.1/5432) 2>/dev/null; then
    warn "postgres    : :5432 reachable (LiteLLM key store OK)"
  else
    warn "postgres    : :5432 NOT reachable — LiteLLM can't serve. Start Honcho: bash $AI_STACK/vz-ai-stack.sh install 03"
  fi
  local cenv; cenv="$(docker exec litellm printenv LITELLM_MASTER_KEY 2>/dev/null || true)"
  if [[ -n "$cenv" && -n "$key" && "$cenv" == "$key" ]]; then
    warn "master key  : container matches .env"
  elif [[ -n "$cenv" ]]; then
    warn "master key  : MISMATCH — running container holds a different key than .env."
    warn "              Fix: bash $AI_STACK/bin/start-litellm.sh --recreate"
  fi
  local raw; raw="$(curl -s --max-time 5 "${LITELLM_BASE_URL:-http://litellm:4000}/v1/models" \
                    -H "Authorization: Bearer $key" 2>&1 | tr -d '\r' | head -c 220)"
  warn "GET /v1/models -> ${raw:-<empty or timeout>}"
  warn "recent litellm logs (tail 20):"
  # Redact any sk-… token (LiteLLM logs its master key on first boot) BEFORE it
  # reaches the terminal/stderr — a tee'd install log would otherwise persist it.
  docker logs litellm --tail 20 2>&1 | sed -E 's/sk-[A-Za-z0-9_-]+/[REDACTED]/g; s/^/    /' \
    || warn "    (no logs — container missing)"
  warn "─────────────────────────────────────────────────────────────────"
  warn "Most common fix: bash $AI_STACK/bin/start-litellm.sh --recreate   then re-run: bash $AI_STACK/vz-ai-stack.sh install 01"
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
