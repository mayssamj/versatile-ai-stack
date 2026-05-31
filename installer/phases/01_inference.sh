#!/usr/bin/env bash
# Phase 01 — inference plane: Ollama + LiteLLM + trace_to_file.py.
#
# Idempotency rules:
#   - Ollama brew install + brew services start: skipped if already.
#   - Model pulls: skipped if model already present in `ollama list`.
#   - LiteLLM container: if already running AND foreign (not managed by us),
#     prompts user to `install.sh adopt litellm`. If already running AND
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

PHASE=01

REQUIRED_MODELS=(
  gemma4:e4b
  qwen3.6:27b-q4_K_M
  nomic-embed-text
  # Liquid AI LFM2.5-8B-A1B (Nov 2025): 8.3B total / 1.5B active MoE,
  # 131K ctx. Q4_K_M is 5.16GB — fits alongside other models on 24GB
  # M-series. Surfaced as `local-lfm2` in litellm/config.yaml.
  hf.co/LiquidAI/LFM2.5-8B-A1B-GGUF:Q4_K_M
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
    warn "Run:  bash install.sh adopt litellm   to take ownership."
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
