# MetaGPT (Phase 32): host-venv multi-agent software-company sim. OPT-IN — skips
# clean when Phase 32 hasn't run. PASS requires: venv + import + bin wrapper +
# a scoped LiteLLM key that actually lists models (a stale/revoked key returns
# 200 + empty data[], so we require a real "id"). A down key-store DB is reported
# as "heal the DB" (check 05a), NOT "re-mint" — re-minting against a dead DB fails.
CHECKS+=(metagpt)
CHECK_TITLE[metagpt]="MetaGPT venv + scoped LiteLLM key (Phase 32)"

metagpt_diagnose() {
  # compgen -G (not ls) — doctor.sh runs under nullglob.
  if ! compgen -G "$AI_STACK/installer/state/phase_32*.done" >/dev/null 2>&1; then
    echo "MetaGPT not installed in this stack — Phase 32 (opt-in) hasn't run yet (skipping)"
    return 0
  fi

  local venv="$AI_STACK/metagpt/.venv"
  [[ -x "$venv/bin/metagpt" ]] || { echo "metagpt venv missing ($venv) — re-run 'vz-ai-stack.sh install 32'"; return 1; }
  "$venv/bin/python" -c "import metagpt" >/dev/null 2>&1 || { echo "import metagpt failed in the venv — re-run 'vz-ai-stack.sh install 32'"; return 1; }
  [[ -x "$AI_STACK/bin/metagpt" ]] || { echo "bin/metagpt wrapper missing — re-run 'vz-ai-stack.sh install 32'"; return 1; }

  local key; key="$(get_env METAGPT_LITELLM_KEY '')"
  [[ -n "$key" ]] || { echo "METAGPT_LITELLM_KEY missing from .env — re-run 'vz-ai-stack.sh install 32'"; return 1; }
  local models
  models="$(litellm_scoped_curl "$key" -s --max-time 5 http://litellm:4000/v1/models 2>/dev/null || true)"
  printf '%s' "$models" | grep -q '"id"' \
    || models="$(litellm_scoped_curl "$key" -s --max-time 5 http://127.0.0.1:4000/v1/models 2>/dev/null || true)"
  if ! printf '%s' "$models" | grep -q '"id"'; then
    if declare -F litellm_db_down >/dev/null 2>&1 && litellm_db_down; then
      echo "LiteLLM key-store DB is DOWN — heal it (see check 05a / 'vz-ai-stack.sh doctor keystore'); do NOT re-mint"
      return 1
    fi
    echo "METAGPT_LITELLM_KEY rejected by LiteLLM (no models) — re-mint via 'vz-ai-stack.sh install 32'"
    return 1
  fi
  # Allow-list drift assertion (shared helper — see _doctor_assert_key_allowlist in
  # common.sh): the /v1/models probe above only proves the key lists SOME model; this
  # verifies it ALLOWS the model MetaGPT is bound to (models.yml .assignments.metagpt, else
  # local). Non-fatal on yq-absent / wildcard / empty / unparseable / LiteLLM-down;
  # FAILs (with its own message) only on a genuine stale-key miss.
  _doctor_assert_key_allowlist "$key" METAGPT_LITELLM_KEY metagpt "the model MetaGPT calls" 32 || return 1
  echo "MetaGPT ready (venv + import + scoped key lists models); run: bin/metagpt \"<brief>\""
  return 0
}

metagpt_fix() {
  echo "vz-ai-stack.sh install 32   # rebuild venv + re-mint scoped key + refresh bin/metagpt"
}
