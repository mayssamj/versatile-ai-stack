#!/usr/bin/env bash
# Phase 01 — inference plane: Ollama + LiteLLM + trace_to_file.py.
#
# Idempotency rules:
#   - Ollama brew install + brew services start: skipped if already.
#   - Model pulls: skipped if model already present in `ollama list`.
#   - LiteLLM container: if already running AND foreign (not managed by us),
#     prompts user to `vz-ai-stack.sh adopt litellm`. If already running AND
#     managed, leaves it alone unless config.yaml has been mutated since
#     container start (then queues a restart).
#   - config.yaml + trace_to_file.py: written if missing, never silently
#     overwrites a user-edited file.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/validate.sh"
source "$AI_STACK/installer/lib/litellm.sh"
source "$AI_STACK/installer/lib/lmstudio.sh"   # lms_register_model (ADD-ONLY upsert)

PHASE=01

# LAZY-OLLAMA policy (2026-05-31): eager-pull ONLY the default chat model
# (gemma4:e4b = `local`/`local-gemma4`) + the embedding model. qwen3.6 moved to
# LM Studio MLX (local-qwen3.6, opt-in) and the LFM2.5 GGUF is no longer
# pre-pulled — both keep a fresh install light on a 24GB box. See
# installer/models.yml + 'vz-ai-stack.sh model'. (local-heavy/local-lfm2 stay in
# litellm/config.yaml as ADD-ONLY legacy slugs; they just 404 until pulled.)
REQUIRED_MODELS=(
  gemma4:e4b
  nomic-embed-text
)

precheck() {
  command -v ollama >/dev/null || return 1
  brew services list 2>/dev/null | awk '$1=="ollama" {print $2}' | grep -q started || return 1
  wait_http http://127.0.0.1:11434/api/tags 5 || return 1
  local installed; installed="$(ollama list 2>/dev/null | awk 'NR>1{print $1}')"
  for m in "${REQUIRED_MODELS[@]}"; do
    # Match bare name OR `name:tag` (default tag is `:latest`).
    echo "$installed" | grep -qE "^${m}(:|$)" || return 1
  done
  [[ -f "$AI_STACK/litellm/config.yaml" ]] || return 1
  [[ -f "$AI_STACK/litellm/trace_to_file.py" ]] || return 1
  litellm_wait_ready 5 || return 1
  # Network membership check: if litellm container exists and we're managing
  # networking, require it on the ai-stack bridge.
  if container_running litellm && container_managed litellm; then
    docker inspect litellm --format '{{json .NetworkSettings.Networks}}' \
      | grep -q '"ai-stack"' || return 1
  fi
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (inference plane)"
  exit 0
fi

hdr "Phase 01 — inference plane"

# --- Ollama brew install + start ---
if ! command -v ollama >/dev/null; then
  log "Installing Ollama..."
  brew install ollama
fi
if ! brew services list 2>/dev/null | awk '$1=="ollama" {print $2}' | grep -q started; then
  log "Starting Ollama brew service..."
  brew services start ollama
fi
wait_http http://127.0.0.1:11434/api/tags 30 || { err "Ollama did not come up"; exit 1; }
ok "Ollama running"

# --- Disk-space precheck for models ---
require_disk_free 30 "$HOME" || { err "Need 30GB free for Ollama models"; exit 1; }

# --- Pull required models if missing ---
INSTALLED_MODELS="$(ollama list 2>/dev/null | awk 'NR>1{print $1}')"
for m in "${REQUIRED_MODELS[@]}"; do
  if echo "$INSTALLED_MODELS" | grep -qE "^${m}(:|$)"; then
    ok "model present: $m"
    continue
  fi
  log "Pulling $m (this may take several minutes)..."
  if ! ollama pull "$m"; then
    err "ollama pull $m failed; cleaning partial blob..."
    ollama rm "$m" 2>/dev/null || true
    exit 1
  fi
  ok "pulled: $m"
done

# --- LiteLLM config.yaml ---
if [[ ! -f "$AI_STACK/litellm/config.yaml" ]]; then
  # Ship the canonical config from prompts/ if present; else error.
  if [[ -f "$AI_STACK/prompts/config.yaml" ]]; then
    cp "$AI_STACK/prompts/config.yaml" "$AI_STACK/litellm/config.yaml"
    ok "wrote litellm/config.yaml from prompts/"
  else
    err "litellm/config.yaml missing and no template at prompts/config.yaml"
    exit 1
  fi
fi
yq -e '.model_list[0]' "$AI_STACK/litellm/config.yaml" >/dev/null || {
  err "litellm/config.yaml has no model_list — refusing to start LiteLLM"
  exit 1
}

# --- Register the 3 canonical model IDs in config.yaml (ADD-ONLY) ----------
# So they exist BEFORE any scoped key is minted (constraint: superset-before-mint):
#   local-gemma4      -> Ollama gemma4:e4b   (works immediately)
#   local-qwen3.6     -> LM Studio MLX       (row exists but 503s until 'install lmstudio')
#   local-qwen3-coder -> LM Studio MLX       (idem)
# We register straight from installer/models.yml when present (the canonical
# source of truth), else fall back to the hardcoded triple. lms_register_model
# is ADD-ONLY + atomic (temp+mv) + idempotent — legacy slugs are untouched and
# no model is loaded/inferenced here (lazy-Ollama).
MODELS_YML="$AI_STACK/installer/models.yml"
if [[ -f "$MODELS_YML" ]]; then
  while IFS= read -r _mn; do
    [[ -z "$_mn" ]] && continue
    _rt="$(yq -r ".models.\"$_mn\".runtime" "$MODELS_YML" 2>/dev/null)"
    _sv="$(yq -r ".models.\"$_mn\".served"  "$MODELS_YML" 2>/dev/null)"
    [[ -z "$_sv" || "$_sv" == "null" ]] && continue
    # Pass the per-model effort for meridian models — WITHOUT this, lms_register_model
    # defaults effort to `high` and flattens the subscription effort ladder
    # (claude-*-sub-{low,medium,high,xhigh,max}) on every install. Mirrors
    # lib/models.sh::register_model_list.
    _ef=""; [[ "$_rt" == "meridian" ]] && _ef="$(yq -r ".models.\"$_mn\".effort // \"\"" "$MODELS_YML" 2>/dev/null)"
    if [[ "$(lms_register_model "$_mn" "$_sv" "$_rt" "$_ef")" == "CHANGED" ]]; then
      ok "registered $_mn ($_rt/$_sv${_ef:+, effort=$_ef}) in litellm/config.yaml"
    fi
  done < <(yq -r '.models | keys | .[]' "$MODELS_YML" 2>/dev/null)
else
  # models.yml absent (partial checkout): register the canonical triple directly.
  lms_register_model local-gemma4      gemma4:e4b                        ollama   >/dev/null
  lms_register_model local-qwen3.6     qwen/qwen3.6-27b                  lmstudio >/dev/null
  lms_register_model local-qwen3-coder qwen3-coder-30b-a3b-instruct-mlx  lmstudio >/dev/null
  ok "registered 3 canonical model IDs in litellm/config.yaml (models.yml absent — used defaults)"
fi

# --- LiteLLM custom callback file ---
[[ -f "$AI_STACK/litellm/trace_to_file.py" ]] || {
  err "litellm/trace_to_file.py missing — should have been written by phase scaffold"
  exit 1
}

# --- Start (or report foreign) LiteLLM container ---
if container_running litellm; then
  if container_managed litellm; then
    ok "litellm container already running and managed"
  else
    warn "litellm is running but FOREIGN (started outside the installer)."
    warn "Run:  bash vz-ai-stack.sh adopt litellm   to take ownership."
    # Do not fail the phase — the user has a working litellm, just unmanaged.
  fi
else
  log "Starting LiteLLM..."
  bash "$AI_STACK/bin/start-litellm.sh"
  litellm_wait_ready 60 || { err "LiteLLM did not come up"; exit 1; }
fi

# --- Smoke: /v1/models lists at least one model ---
KEY="$(get_env LITELLM_MASTER_KEY)"
if [[ -z "$KEY" ]]; then
  err "LITELLM_MASTER_KEY empty — cannot smoke test"
  exit 1
fi
# Smoke against the alias URL (post-refactor). If /etc/hosts isn't yet
# populated, fall back to the loopback IP directly.
LITELLM_SMOKE="${LITELLM_BASE_URL:-$(get_env LITELLM_BASE_URL http://litellm:4000)}"
if ! curl -s --max-time 5 "${LITELLM_SMOKE}/v1/models" \
     -H "Authorization: Bearer $KEY" | grep -q '"data"'; then
  warn "Alias smoke (${LITELLM_SMOKE}/v1/models) failed; retrying via 127.0.10.1..."
  if ! curl -s --max-time 5 http://127.0.10.1/v1/models \
       -H "Authorization: Bearer $KEY" | grep -q '"data"'; then
    err "LiteLLM /v1/models did not return a model list"
    exit 1
  fi
fi
ok "LiteLLM /v1/models responds"

stamp_mark "$PHASE"
record "phase 01 complete: ollama up, ${#REQUIRED_MODELS[@]} models pulled, litellm responding"
ok "Phase 01 — inference plane — complete"
