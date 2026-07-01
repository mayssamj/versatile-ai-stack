# Required Ollama models are pulled.
#
# LOCAL-MODEL policy (operator directive 2026-07-01): nemotron-3-nano:4b is the
# ONLY local chat model (the `local`/`local-heavy` default, ~2.8GB) + nomic-embed-text
# (embeddings) are the only eager-pulled models. No gemma4/qwen model is pulled by
# install OR doctor. This keeps a fresh install light on a 24GB box. See
# installer/models.yml.
CHECKS+=(ollama_models)
CHECK_TITLE[ollama_models]="Ollama running + required models pulled (nemotron-3-nano:4b, nomic-embed-text)"

_OLLAMA_REQUIRED=(
  nemotron-3-nano:4b
  nomic-embed-text
)

ollama_models_diagnose() {
  command -v ollama >/dev/null || { echo "ollama not installed"; return 1; }
  if ! curl -sf --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null; then
    echo "ollama service not responding on :11434"
    return 1
  fi
  # Cross-container bind (cheap; no inference). The LiteLLM container reaches host
  # ollama via the `ollama:host-gateway` alias, which ONLY works if ollama listens on
  # 0.0.0.0. `brew upgrade/restart ollama` regenerates the launchd plist and drops
  # OLLAMA_HOST=0.0.0.0, rebinding 127.0.0.1 → every local-* model 500s in-stack while
  # `api/tags` (queried on loopback here) still answers. Catch that here; the fix re-patches.
  if command -v lsof >/dev/null 2>&1; then
    local binds; binds="$(lsof -nP -iTCP:11434 -sTCP:LISTEN 2>/dev/null | awk 'NR>1{print $9}')"
    if [[ -n "$binds" ]] && ! printf '%s\n' "$binds" | grep -q '\*:11434'; then
      echo "ollama bound loopback-only ($(printf '%s' "$binds" | tr '\n' ' ')) — in-stack containers (LiteLLM) can't reach it; OLLAMA_HOST=0.0.0.0 was wiped (brew upgrade/restart). Fix re-asserts it."
      return 1
    fi
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
  # Re-assert the cross-container bind (OLLAMA_HOST=0.0.0.0) if it regressed — the same
  # PlistBuddy + launchctl bootout/bootstrap patch the installer uses. Idempotent: a
  # no-op when already 0.0.0.0. deps.sh is functions-only → safe to source. Source first,
  # then gate the call on the function being defined so a load failure is surfaced, not silent.
  declare -f _dep_ollama_patch_env >/dev/null 2>&1 || source "$AI_STACK/installer/lib/deps.sh" 2>/dev/null || true
  if declare -f _dep_ollama_patch_env >/dev/null 2>&1; then
    _dep_ollama_patch_env || warn "ollama: OLLAMA_HOST re-assert failed — check 'lsof -nP -iTCP:11434' (want *:11434), then re-run 'vz-ai-stack.sh doctor ollama_models'"
  else
    warn "ollama: could not load deps.sh to re-assert OLLAMA_HOST — check 'lsof -nP -iTCP:11434' (want *:11434)"
  fi
  installed="$(ollama list 2>/dev/null | awk 'NR>1{print $1}')"
  for m in "${_OLLAMA_REQUIRED[@]}"; do
    if ! echo "$installed" | grep -qE "^${m}(:|$)"; then
      log "Pulling $m ..."
      ollama pull "$m" || { ollama rm "$m" 2>/dev/null; return 1; }
    fi
  done
}
