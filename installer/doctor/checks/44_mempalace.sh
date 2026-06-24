# MemPalace (Phase 26): tool installed + bin/mempalace wrapper + hook launchers
# + palace config present + MEMPALACE_LITELLM_KEY valid against /v1/models.
#
# MemPalace is a local-first conversation-memory CLI/MCP (no daemon, no port).
# Embeddings run on-device (CoreML ONNX) — install-state is verifiable; which
# sessions have been mined is user-state, not install-state. The Claude Code
# hook WIRING is opt-in (bin/mempalace-hooks) and deliberately NOT asserted here.
#
# Conditional: skips cleanly when Phase 26 hasn't run yet (a stack predating mempalace
# joining `install all`, or a partial/resumed install that didn't reach it).
CHECKS+=(mempalace)
CHECK_TITLE[mempalace]="MemPalace installed + LiteLLM virtual key valid (Phase 26)"

mempalace_diagnose() {
  local wrapper="$AI_STACK/bin/mempalace"
  local save_l="$AI_STACK/bin/mempalace-hook-save"
  local pre_l="$AI_STACK/bin/mempalace-hook-precompact"
  local cfg="$HOME/.mempalace/config.json"
  local mp_bin
  mp_bin="$(command -v mempalace 2>/dev/null || echo "$HOME/.local/bin/mempalace")"

  # Phase 26 (mempalace) is part of `install all` (appended last). Gating still matters:
  # its footprint — the tracked bin/mempalace wrapper, the uv-installed tool in ~/.local,
  # ~/.mempalace/config.json, and MEMPALACE_LITELLM_KEY in .env — ALL survive `reset --hard`;
  # only the LiteLLM virtual key is invalidated when the key store is wiped. So footprint
  # presence alone falsely reports "installed" after a reset (and on a fresh clone, where the
  # wrapper ships tracked but the tool/key do not). The phase stamp is the one signal `reset`
  # clears, so gate on it: no phase-26 stamp ⇒ Phase 26 hasn't run on THIS stack yet (a
  # pre-change install, or a partial/resumed `install all`) ⇒ skip green.
  # NB: use compgen -G (not `ls <glob>`): doctor.sh runs under `shopt -s nullglob`, where an
  # unmatched glob word is REMOVED, making `ls` list the cwd and falsely succeed. compgen -G
  # returns 0 iff ≥1 file matches, regardless of nullglob/failglob.
  if ! compgen -G "$AI_STACK/installer/state/phase_26*.done" >/dev/null 2>&1; then
    echo "mempalace not installed in this stack — Phase 26 hasn't run yet (skipping)"
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
  if ! litellm_scoped_curl "$key" -sf --max-time 5 \
       http://litellm:4000/v1/models >/dev/null 2>&1; then
    if declare -F litellm_db_down >/dev/null && litellm_db_down; then
      echo "LiteLLM key-store DOWN (503 no_db_connection) — NOT a bad key. Heal the DB (check 05a / start honcho-database); do NOT re-mint."
      return 1
    fi
    echo "MEMPALACE_LITELLM_KEY rejected by LiteLLM /v1/models — re-mint via Phase 26"
    return 1
  fi
  # Allow-list assertion: /v1/models passing only proves the key lists SOME model —
  # the local-gemma4 fallback survives a model RENAME, so a key still scoped to the
  # OLD alias passes the probe yet SILENT-403s the model the wrapper actually calls.
  # Verify the key ALLOWS that model. Self-lookup (Bearer = the key, no ?key= in URL);
  # metadata read only — never cold-starts (routine-doctor safe).
  # Extract the model the wrapper calls — handle both generated forms:
  # ${LLM_MODEL:-<model>} (current) and a bare LLM_MODEL="<model>". Empty -> skip.
  local want
  want="$(grep -oE 'LLM_MODEL:-[A-Za-z0-9._+/-]+' "$AI_STACK/bin/mempalace" 2>/dev/null | head -1 | sed 's/^LLM_MODEL:-//')"
  [[ -n "$want" ]] || want="$(grep -oE 'LLM_MODEL="[A-Za-z0-9._+/-]+"' "$AI_STACK/bin/mempalace" 2>/dev/null | head -1 | sed -E 's/^LLM_MODEL="|"$//g')"
  if [[ -n "$want" ]]; then
    local allow
    # Empty models list ([]/null) is UNRESTRICTED in LiteLLM -> treat as wildcard.
    allow="$(litellm_scoped_curl "$key" -s --max-time 5 http://litellm:4000/key/info 2>/dev/null \
      | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
info=d.get("info")
if not isinstance(info,dict): sys.exit(0)
m=info.get("models") or []
print("__wildcard__" if (not m or any(x in ("all-proxy-models","all-team-models") for x in m)) else "\n".join(m))' 2>/dev/null)"
    if [[ -n "$allow" ]] && ! printf '%s\n' "$allow" | grep -qxF '__wildcard__' \
       && ! printf '%s\n' "$allow" | grep -qxF "$want"; then
      echo "MEMPALACE_LITELLM_KEY allow-list missing '$want' (the model bin/mempalace calls) — stale key after a model rename; re-run 'install 26' to self-heal"
      return 1
    fi
  fi
}

mempalace_fix() {
  warn "Re-run Phase 26 (idempotent — uv tool upgrade + key check + wrapper/launchers):"
  warn "    bash $AI_STACK/vz-ai-stack.sh install 26"
  return 1
}
