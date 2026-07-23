# ACE (Phase 17): repo cloned + venv ready + bin/ace wrapper +
# .env routed through LiteLLM + ACE_LITELLM_KEY valid against /v1/models.
#
# ACE is a batch CLI (no daemon, no port). Install-state is verifiable:
# repo present, venv buildable, virtual key live. Run-state (which evals
# have been done, which playbooks exist) is user-state, not install-state.
#
# Conditional: skips cleanly when ace/ doesn't exist (Phase 17 not selected).
CHECKS+=(ace)
CHECK_TITLE[ace]="ACE installed + LiteLLM virtual key valid (Phase 17)"

ace_diagnose() {
  local ace_dir="$AI_STACK/ace"
  local venv="$ace_dir/.venv"
  local env_file="$ace_dir/.env"
  local wrapper="$AI_STACK/bin/ace"

  if [[ ! -d "$ace_dir/.git" ]]; then
    echo "ace/ not present — Phase 17 not installed (skipping)"
    return 0
  fi
  if [[ ! -x "$venv/bin/python" ]]; then
    echo "missing $venv/bin/python — uv sync drift; re-run Phase 17"
    return 1
  fi
  if [[ ! -x "$wrapper" ]]; then
    echo "missing $wrapper — Phase 17 did not write the bin/ace wrapper"
    return 1
  fi
  if [[ ! -f "$env_file" ]]; then
    echo "missing $env_file — Phase 17 did not render the env file"
    return 1
  fi
  if ! grep -q '^OPENAI_BASE_URL=http://litellm:4000/v1' "$env_file"; then
    echo "$env_file: OPENAI_BASE_URL not pointed at http://litellm:4000/v1 — ACE will hit api.openai.com"
    return 1
  fi
  local ace_key
  ace_key="$(get_env ACE_LITELLM_KEY '')"
  if [[ -z "$ace_key" ]]; then
    echo "ACE_LITELLM_KEY missing from .env"
    return 1
  fi
  if ! litellm_scoped_curl "$ace_key" -sf --max-time 5 \
       http://litellm:4000/v1/models >/dev/null 2>&1; then
    if declare -F litellm_db_down >/dev/null && litellm_db_down; then
      echo "LiteLLM key-store DOWN (503 no_db_connection) — NOT a bad key. Heal the DB (check 05a / start honcho-database); do NOT re-mint."
      return 1
    fi
    echo "ACE_LITELLM_KEY rejected by LiteLLM /v1/models — re-mint via Phase 17"
    return 1
  fi
}

ace_fix() {
  warn "Re-run Phase 17 (idempotent — git fetch + uv sync + key check):"
  warn "    bash $AI_STACK/mayssam-ai-stack.sh install 17"
  return 1
}
