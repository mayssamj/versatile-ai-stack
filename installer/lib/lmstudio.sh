# lmstudio.sh — shared LM Studio (MLX) helpers used by Phase 25 + the model
# binding feature (lib/models.sh).
#
# Factored out of installer/phases/25_lmstudio.sh so the served-id discovery,
# the config.yaml yq-upsert, and the "load ONE big MLX model" RAM policy live in
# exactly one place. NO behaviour change for the LFM2.5 path — Phase 25 keeps its
# own slug/repo constants and just calls these.
#
# Source order: common.sh (log/ok/warn/err) must already be sourced. We source
# it defensively here so the lib is usable standalone.
[[ -z "${AI_STACK:-}" ]] && { echo "lmstudio.sh: AI_STACK unset" >&2; exit 2; }
[[ -n "${C_RESET+x}" ]] || source "$AI_STACK/installer/lib/common.sh"

LMS_PORT="${LMS_PORT:-1234}"
LMS_URL="${LMS_URL:-http://127.0.0.1:${LMS_PORT}}"
LMS_CONFIG="${LMS_CONFIG:-$AI_STACK/litellm/config.yaml}"

# Resolve the lms CLI (bootstrapped at ~/.lmstudio/bin/lms, else in the app
# bundle). Echoes the path, or empty + returns 1.
lms_cli() {
  if [[ -x "$HOME/.lmstudio/bin/lms" ]]; then echo "$HOME/.lmstudio/bin/lms"; return 0; fi
  local appcli="/Applications/LM Studio.app/Contents/Resources/app/.webpack/lms"
  [[ -x "$appcli" ]] && { echo "$appcli"; return 0; }
  echo ""; return 1
}

# lms_server_up — is the OpenAI-compatible server answering on :1234?
lms_server_up() {
  curl -s -o /dev/null --max-time 4 "$LMS_URL/v1/models" 2>/dev/null
}

# lms_served_ids — print every non-embedding model id LM Studio is serving,
# one per line (empty if none / server down).
lms_served_ids() {
  curl -s --max-time 5 "$LMS_URL/v1/models" 2>/dev/null \
    | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get("data",[]):
    i=m.get("id","")
    if i and "embed" not in i.lower():
        print(i)' 2>/dev/null
}

# lms_served_first — the first served LLM id (Phase 25 compatibility helper).
lms_served_first() { lms_served_ids | head -1; }

# lms_is_served <served> — is exactly this served id currently served?
lms_is_served() {
  local want="$1"
  [[ -n "$want" ]] || return 1
  lms_served_ids | grep -qxF "$want"
}

# lms_register_model <model_name> <served> <runtime>
# yq-UPSERT one entry into litellm/config.yaml's model_list, keyed on
# model_name (replace litellm_params in place if it exists, else append).
# Atomic temp+mv. Returns 0 + prints CHANGED to stdout if the file's bytes
# changed, 0 + prints UNCHANGED otherwise; non-zero on hard failure.
#   ollama   => model: ollama_chat/<served>, api_base: http://ollama:11434
#   lmstudio => model: openai/<served>,      api_base: http://host.docker.internal:<port>/v1, api_key: lm-studio
lms_register_model() {
  local model_name="$1" served="$2" runtime="$3"
  command -v yq >/dev/null 2>&1 || { err "yq not on PATH (Phase 00 installs it)"; return 1; }
  [[ -f "$LMS_CONFIG" ]] || { err "litellm config not found: $LMS_CONFIG"; return 1; }

  # Build the desired litellm_params as a yq expression input via env strenv.
  local tmp before after
  tmp="$(mktemp "${LMS_CONFIG}.XXXXXX")" || return 1
  cp "$LMS_CONFIG" "$tmp"
  before="$(shasum -a 256 "$LMS_CONFIG" | awk '{print $1}')"

  # Step A: append a bare {model_name: <MN>} entry IFF it is not already there
  # (add-only; legacy entries are never touched). any_c() with a single
  # condition matches each list element directly. The select-guard makes the
  # `with(...)` a no-op when the entry already exists, so this is idempotent.
  if ! MN="$model_name" yq -i 'with(select(.model_list | any_c(.model_name == strenv(MN)) | not); .model_list += [{"model_name": strenv(MN)}])' "$tmp"; then
    rm -f "$tmp"; err "yq append failed for $model_name"; return 1
  fi
  # Step B: set litellm_params IN PLACE on the matching entry (replace whatever
  # was there — this is how we converge a changed served id without restarting
  # on every run).
  if [[ "$runtime" == "ollama" ]]; then
    MN="$model_name" SV="$served" yq -i '(.model_list[] | select(.model_name == strenv(MN)) | .litellm_params) = {"model": "ollama_chat/" + strenv(SV), "api_base": "http://ollama:11434"}' "$tmp" \
      || { rm -f "$tmp"; err "yq set-params failed for $model_name"; return 1; }
  else
    MN="$model_name" SV="$served" PRT="$LMS_PORT" yq -i '(.model_list[] | select(.model_name == strenv(MN)) | .litellm_params) = {"model": "openai/" + strenv(SV), "api_base": "http://host.docker.internal:" + strenv(PRT) + "/v1", "api_key": "lm-studio"}' "$tmp" \
      || { rm -f "$tmp"; err "yq set-params failed for $model_name"; return 1; }
  fi

  after="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [[ "$before" == "$after" ]]; then
    rm -f "$tmp"
    echo "UNCHANGED"
    return 0
  fi
  mv -f "$tmp" "$LMS_CONFIG"
  echo "CHANGED"
  return 0
}

# lms_load_big <served> <ttl>
# Enforce the one-big-MLX-at-a-time RAM policy on a 24GB box:
#   1. If <served> is already served, return 0 (idempotent).
#   2. Unload any OTHER currently-loaded model (lms ps -> lms unload) so the two
#      ~17GB MLX models never coexist.
#   3. lms load <served> --identifier <served> --ttl <ttl> -y
#   4. Verify <served> now shows in /v1/models (returns non-zero if not).
# Best-effort, non-fatal: returns non-zero so the caller can availability-gate.
lms_load_big() {
  local served="$1" ttl="${2:-1800}"
  local lms; lms="$(lms_cli)"
  [[ -n "$lms" ]] || { warn "lms CLI not found — cannot load $served"; return 1; }
  lms_server_up || { warn "LM Studio server not up on $LMS_URL — cannot load $served"; return 1; }

  if lms_is_served "$served"; then
    note "LM Studio already serving $served"
    return 0
  fi

  # Unload OTHER loaded models so only one big MLX model is resident.
  local other
  while IFS= read -r other; do
    [[ -z "$other" ]] && continue
    [[ "$other" == "$served" ]] && continue
    log "Unloading other LM Studio model '$other' (one-big-MLX RAM policy)..."
    "$lms" unload "$other" >/dev/null 2>&1 || "$lms" unload --all >/dev/null 2>&1 || true
  done < <(lms_served_ids)

  log "Loading $served into LM Studio (ttl=${ttl}s)..."
  "$lms" load "$served" --identifier "$served" --ttl "$ttl" -y >/dev/null 2>&1 \
    || "$lms" load "$served" --ttl "$ttl" -y >/dev/null 2>&1 \
    || { warn "lms load $served returned non-zero"; }
  sleep 2

  if lms_is_served "$served"; then
    ok "LM Studio serving $served"
    return 0
  fi
  warn "LM Studio did not surface '$served' in /v1/models after load (still loading? wrong id?)"
  return 1
}
