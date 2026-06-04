# MemPalace (Phase 26): tool installed + bin/mempalace wrapper + hook launchers
# + palace config present + MEMPALACE_LITELLM_KEY valid against /v1/models.
#
# MemPalace is a local-first conversation-memory CLI/MCP (no daemon, no port).
# Embeddings run on-device (CoreML ONNX) — install-state is verifiable; which
# sessions have been mined is user-state, not install-state. The Claude Code
# hook WIRING is opt-in (bin/mempalace-hooks) and deliberately NOT asserted here.
#
# Conditional: skips cleanly when MemPalace isn't installed (Phase 26 not selected).
CHECKS+=(mempalace)
CHECK_TITLE[mempalace]="MemPalace installed + LiteLLM virtual key valid (Phase 26)"

mempalace_diagnose() {
  local wrapper="$AI_STACK/bin/mempalace"
  local save_l="$AI_STACK/bin/mempalace-hook-save"
  local pre_l="$AI_STACK/bin/mempalace-hook-precompact"
  local cfg="$HOME/.mempalace/config.json"
  local mp_bin
  mp_bin="$(command -v mempalace 2>/dev/null || echo "$HOME/.local/bin/mempalace")"

  # Not installed at all → Phase 26 not selected; skip green.
  if [[ ! -x "$mp_bin" ]] && ! command -v mempalace >/dev/null 2>&1 && [[ ! -x "$wrapper" ]]; then
    echo "mempalace not installed — Phase 26 not selected (skipping)"
    return 0
  fi
  if [[ ! -x "$mp_bin" ]] && ! command -v mempalace >/dev/null 2>&1; then
    echo "bin/mempalace wrapper present but the mempalace tool is missing — re-run Phase 26 (uv tool install drift)"
    return 1
  fi
  if [[ ! -x "$wrapper" ]]; then
    echo "missing $wrapper — Phase 26 did not write the wrapper"
    return 1
  fi
  if [[ ! -x "$save_l" || ! -x "$pre_l" ]]; then
    echo "missing hook launcher(s) — re-run Phase 26 (expected bin/mempalace-hook-{save,precompact})"
    return 1
  fi
  if [[ ! -f "$cfg" ]]; then
    echo "palace not initialized — '$wrapper init <dir> --yes' (or re-run Phase 26)"
    return 1
  fi
  local key
  key="$(get_env MEMPALACE_LITELLM_KEY '')"
  if [[ -z "$key" ]]; then
    echo "MEMPALACE_LITELLM_KEY missing from .env — re-run Phase 26"
    return 1
  fi
  if ! curl -sf --max-time 5 -H "Authorization: Bearer $key" \
       http://litellm:4000/v1/models >/dev/null 2>&1; then
    echo "MEMPALACE_LITELLM_KEY rejected by LiteLLM /v1/models — re-mint via Phase 26"
    return 1
  fi
}

mempalace_fix() {
  warn "Re-run Phase 26 (idempotent — uv tool upgrade + key check + wrapper/launchers):"
  warn "    bash $AI_STACK/vz-ai-stack.sh install 26"
  return 1
}
