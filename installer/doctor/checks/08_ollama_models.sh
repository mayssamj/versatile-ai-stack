# Required Ollama models are pulled.
#
# LAZY-OLLAMA policy (2026-05-31): only gemma4:e4b (the `local`/`local-gemma4`
# default) + nomic-embed-text (embeddings) are eager-pulled. qwen3.6 moved to
# LM Studio MLX (local-qwen3.6, opt-in via 'install lmstudio' / 'model sync'),
# and the LFM2.5 GGUF is no longer pre-pulled. This keeps a fresh install light
# on a 24GB box. See installer/models.yml.
CHECKS+=(ollama_models)
CHECK_TITLE[ollama_models]="Ollama running + required models pulled (gemma4:e4b, nomic-embed-text)"

_OLLAMA_REQUIRED=(
  gemma4:e4b
  nomic-embed-text
)

ollama_models_diagnose() {
  command -v ollama >/dev/null || { echo "ollama not installed"; return 1; }
  if ! curl -sf --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null; then
    echo "ollama service not responding on :11434"
    return 1
  fi
  local missing=() m installed
  installed="$(ollama list 2>/dev/null | awk 'NR>1{print $1}')"
  for m in "${_OLLAMA_REQUIRED[@]}"; do
    # match either bare `name` or `name:latest`
    if ! echo "$installed" | grep -qE "^${m}(:|$)"; then
      missing+=("$m")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    echo "missing models: ${missing[*]}"
    return 1
  fi
}

ollama_models_fix() {
  local m installed
  if ! command -v ollama >/dev/null; then
    log "Installing ollama via brew..."
    brew install ollama
  fi
  brew services start ollama 2>/dev/null || true
  installed="$(ollama list 2>/dev/null | awk 'NR>1{print $1}')"
  for m in "${_OLLAMA_REQUIRED[@]}"; do
    if ! echo "$installed" | grep -qE "^${m}(:|$)"; then
      log "Pulling $m ..."
      ollama pull "$m" || { ollama rm "$m" 2>/dev/null; return 1; }
    fi
  done
}
