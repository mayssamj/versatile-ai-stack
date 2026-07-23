# OpenWork (Phase 29): headless openwork-orchestrator daemon (loopback :8787) +
# seeded opencode.json (LiteLLM provider) + scoped LiteLLM virtual key. OpenWork is
# an OPT-IN OpenCode-powered Cowork workspace (no ai-stack container — the
# orchestrator is an npm-installed prebuilt binary run as a host launchd daemon).
#
# Conditional: skips clean when Phase 29 hasn't run (the opt-in case). Gate on the
# phase stamp — the binary/key/config footprint can survive a reset, but the stamp
# is what `reset` clears, so it's the one reliable "installed on THIS stack" signal.
CHECKS+=(openwork)
CHECK_TITLE[openwork]="OpenWork daemon healthy on :8787 + LiteLLM key valid (Phase 29)"

openwork_diagnose() {
  local workdir="${OPENWORK_WORKDIR:-$HOME/.openwork-stack}"
  local oc_json="$workdir/opencode.json"
  # NB: compgen -G (not `ls <glob>`) — doctor.sh runs under nullglob, where an
  # unmatched glob is REMOVED and `ls` would list cwd and falsely succeed.
  if ! compgen -G "$AI_STACK/installer/state/phase_29*.done" >/dev/null 2>&1; then
    echo "OpenWork not installed in this stack — Phase 29 (opt-in) hasn't run yet (skipping)"
    return 0
  fi

  # Resolve the openwork binary (npm global bin may not be on the doctor PATH).
  local bin=""
  if command -v openwork >/dev/null 2>&1; then bin="$(command -v openwork)"
  elif [[ -x "$HOME/.local/bin/openwork" ]]; then bin="$HOME/.local/bin/openwork"
  elif command -v npm >/dev/null 2>&1 && [[ -x "$(npm prefix -g 2>/dev/null)/bin/openwork" ]]; then bin="$(npm prefix -g 2>/dev/null)/bin/openwork"
  fi
  [[ -n "$bin" ]] || { echo "openwork binary not found on PATH/npm-global — re-run 'mayssam-ai-stack.sh install 29'"; return 1; }
  "$bin" --version >/dev/null 2>&1 || { echo "openwork present but '--version' fails (binary not runnable) — re-run 'mayssam-ai-stack.sh install 29'"; return 1; }

  [[ -f "$oc_json" ]] || { echo "opencode.json missing ($oc_json) — re-run 'mayssam-ai-stack.sh install 29'"; return 1; }

  # Health: openwork-server serves HTTP 200 at /health when up. Explicit '^200$'
  # grep (NOT the http_ok helper — documented 000-concat false-healthy bug).
  if ! curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8787/health 2>/dev/null | grep -q '^200$'; then
    echo "openwork daemon not serving 200 on :8787/health — 'mayssam-ai-stack.sh start openwork' (first run downloads OpenCode sidecars; check installer/state/openwork.launchd.log)"
    return 1
  fi

  local key; key="$(get_env OPENWORK_LITELLM_KEY '')"
  [[ -n "$key" ]] || { echo "OPENWORK_LITELLM_KEY missing from .env — re-run 'mayssam-ai-stack.sh install 29'"; return 1; }
  # Gate the key probe on LiteLLM reachability so a down LiteLLM doesn't red-bar this.
  if ! litellm_scoped_curl "$key" -sf --max-time 5 http://litellm:4000/v1/models >/dev/null 2>&1; then
    if declare -F litellm_db_down >/dev/null && litellm_db_down; then
      echo "LiteLLM key-store DOWN (503 no_db_connection) — NOT a bad key. Heal the DB (check 05a / start honcho-database); do NOT re-mint."
      return 1
    fi
    if curl -sf --max-time 3 http://litellm:4000/health >/dev/null 2>&1; then
      echo "OPENWORK_LITELLM_KEY rejected by LiteLLM /v1/models — re-mint via 'mayssam-ai-stack.sh install 29'"
      return 1
    fi
    echo "LiteLLM not reachable — start it ('mayssam-ai-stack.sh start litellm'), then re-check"
    return 1
  fi

  # Cross-check: every model in opencode.json must be a ROUTABLE model_name in LiteLLM's
  # config. A version-less naming cutover ('model sync') renames the routable model_names
  # but does NOT re-seed this write-once opencode.json / scoped key, so stale names 400 at
  # completion while the daemon + key still look healthy (this check used to miss that).
  # Parse-only, no inference. NB: validate against config.yaml's model_list (the routable
  # set) — NOT the scoped key's /v1/models, which can still list stale aliases that 400.
  local cfg="$AI_STACK/litellm/config.yaml"
  if command -v yq >/dev/null 2>&1 && [[ -f "$cfg" ]]; then
    local routable stale=() m
    local -a cfg_models=()
    routable="$(yq -r -oy '.model_list[].model_name' "$cfg" 2>/dev/null)"
    # mapfile (not unquoted word-split): a model name with a space/glob char would
    # otherwise split into multiple tokens or vanish under doctor.sh's nullglob.
    mapfile -t cfg_models < <(yq -r -oy '.provider.litellm.models | keys | .[]' "$oc_json" 2>/dev/null)
    if [[ -n "$routable" && ${#cfg_models[@]} -gt 0 ]]; then
      for m in "${cfg_models[@]}"; do
        printf '%s\n' "$routable" | grep -qx "$m" || stale+=("$m")
      done
      if (( ${#stale[@]} > 0 )); then
        echo "opencode.json model(s) not routable in LiteLLM config: ${stale[*]} — names drifted (version-less rename). Re-seed: rm '$oc_json' + 'rm $AI_STACK/installer/state/phase_29*.done' + 'mayssam-ai-stack.sh install 29'"
        return 1
      fi
    fi
  fi
  return 0
}

openwork_fix() {
  warn "(Re)start the OpenWork daemon, or re-run the phase (both idempotent):"
  warn "    bash $AI_STACK/mayssam-ai-stack.sh start openwork"
  warn "    bash $AI_STACK/mayssam-ai-stack.sh install 29"
  return 1
}
