# Concordia (Phase 37): host-venv GABM (generative agent-based modeling) sim. OPT-IN —
# skips clean when Phase 37 hasn't run. PASS requires: venv + import concordia + import
# sentence_transformers + bin/concordia wrapper + a scoped LiteLLM key that actually lists
# models (a stale/revoked key returns 200 + empty data[], so we require a real "id"). A down
# key-store DB is reported as "heal the DB" (check 05a), NOT "re-mint".
#
# Numbered 66 (next free after 65_models_console). doctor keys checks by NAME and the count
# auto-derives from the file set, so adding this file ticks the count by one.
CHECKS+=(concordia)
CHECK_TITLE[concordia]="Concordia venv + scoped LiteLLM key (Phase 37)"

concordia_diagnose() {
  # compgen -G (not ls) — doctor.sh runs under nullglob.
  if ! compgen -G "$AI_STACK/installer/state/phase_37*.done" >/dev/null 2>&1; then
    echo "Concordia not installed in this stack — Phase 37 (opt-in) hasn't run yet (skipping)"
    return 0
  fi

  local venv="$AI_STACK/concordia/.venv"
  [[ -x "$venv/bin/python" ]] || { echo "concordia venv missing ($venv) — re-run 'mayssam-ai-stack.sh install 37'"; return 1; }
  "$venv/bin/python" -c "import concordia" >/dev/null 2>&1 || { echo "import concordia failed in the venv — re-run 'mayssam-ai-stack.sh install 37'"; return 1; }
  "$venv/bin/python" -c "import sentence_transformers" >/dev/null 2>&1 || { echo "import sentence_transformers failed (embedder missing) — re-run 'mayssam-ai-stack.sh install 37'"; return 1; }
  [[ -x "$AI_STACK/bin/concordia" ]] || { echo "bin/concordia wrapper missing — re-run 'mayssam-ai-stack.sh install 37'"; return 1; }

  local key; key="$(get_env CONCORDIA_LITELLM_KEY '')"
  [[ -n "$key" ]] || { echo "CONCORDIA_LITELLM_KEY missing from .env — re-run 'mayssam-ai-stack.sh install 37'"; return 1; }
  local models
  models="$(litellm_scoped_curl "$key" -s --max-time 5 http://litellm:4000/v1/models 2>/dev/null || true)"
  printf '%s' "$models" | grep -q '"id"' \
    || models="$(litellm_scoped_curl "$key" -s --max-time 5 http://127.0.0.1:4000/v1/models 2>/dev/null || true)"
  if ! printf '%s' "$models" | grep -q '"id"'; then
    if declare -F litellm_db_down >/dev/null 2>&1 && litellm_db_down; then
      echo "LiteLLM key-store DB is DOWN — heal it (see check 05a / 'mayssam-ai-stack.sh doctor keystore'); do NOT re-mint"
      return 1
    fi
    echo "CONCORDIA_LITELLM_KEY rejected by LiteLLM (no models) — re-mint via 'mayssam-ai-stack.sh install 37'"
    return 1
  fi
  # Allow-list drift assertion (shared helper): verifies the key ALLOWS the model Concordia
  # is bound to (models.yml .assignments.concordia, else claude-sonnet-sub-high). Non-fatal on
  # yq-absent / wildcard / empty / unparseable / LiteLLM-down; FAILs only on a genuine stale miss.
  _doctor_assert_key_allowlist "$key" CONCORDIA_LITELLM_KEY concordia "the model Concordia calls" 37 || return 1
  echo "Concordia ready (venv + import + embedder + scoped key lists models); prove the sim: mayssam-ai-stack.sh test 37"
  return 0
}

concordia_fix() {
  echo "mayssam-ai-stack.sh install 37   # rebuild venv + re-mint scoped key + refresh bin/concordia"
}
