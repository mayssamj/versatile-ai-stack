# Required Ollama models are pulled.
CHECKS+=(ollama_models)
CHECK_TITLE[ollama_models]="Ollama running + required models pulled (gemma4:e4b, qwen3.6:27b-q4_K_M, nomic-embed-text, LFM2.5-8B-A1B Q4_K_M)"

_OLLAMA_REQUIRED=(
  gemma4:e4b
  qwen3.6:27b-q4_K_M
  nomic-embed-text
  hf.co/LiquidAI/LFM2.5-8B-A1B-GGUF:Q4_K_M
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
