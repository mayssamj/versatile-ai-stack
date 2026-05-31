# Lumen (Phase 16): vendored binary present + version match + embedding model
# pulled in Ollama + bin/lumen wrapper present.
#
# Lumen is a stdio MCP subprocess, not a daemon — there is no port to probe,
# no /health endpoint, no PID file. This check asserts the install-state
# (artifact + dependencies), not user-state (which indexes exist). Whether
# any index has actually been built is left to the user; `bin/lumen index
# <path>` builds one on demand.
CHECKS+=(lumen)
CHECK_TITLE[lumen]="Lumen MCP binary + ollama embedding model present (Phase 16)"

_LUMEN_VERSION="0.0.41"
_LUMEN_ASSET="lumen-${_LUMEN_VERSION}-darwin-arm64"
_LUMEN_EMBED_MODEL="ordis/jina-embeddings-v2-base-code"

lumen_diagnose() {
  local bin="$AI_STACK/vendor/lumen/$_LUMEN_ASSET"
  if [[ ! -x "$bin" ]]; then
    echo "vendored binary missing: $bin (run 'bash install.sh install 16')"
    return 1
  fi
  local v
  v="$("$bin" version 2>/dev/null | head -1 | tr -d '[:space:]')"
  if [[ "$v" != "$_LUMEN_VERSION" ]]; then
    echo "binary reports version '$v' but expected $_LUMEN_VERSION — re-pin or re-run phase 16"
    return 1
  fi
  if [[ ! -x "$AI_STACK/bin/lumen" ]]; then
    echo "wrapper missing: $AI_STACK/bin/lumen"
    return 1
  fi
  # Lumen needs an Ollama embedding model. Check that it's pulled.
  if ! command -v ollama >/dev/null 2>&1; then
    echo "ollama CLI missing (Phase 01 not complete)"
    return 1
  fi
  if ! ollama list 2>/dev/null | awk 'NR>1{print $1}' \
       | grep -qE "^${_LUMEN_EMBED_MODEL}(:|$)"; then
    echo "embedding model '$_LUMEN_EMBED_MODEL' not in 'ollama list' — re-run phase 16"
    return 1
  fi
}

lumen_fix() {
  warn "Re-run Phase 16 (idempotent):"
  warn "    bash $AI_STACK/install.sh install 16"
  return 1
}
