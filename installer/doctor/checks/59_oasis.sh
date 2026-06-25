# OASIS (Phase 34): host-venv large-scale social-agent swarm sim. OPT-IN — skips
# clean when Phase 34 hasn't run. PASS requires: venv + import oasis + bin/oasis
# wrapper + a scoped LiteLLM key that actually lists models (a stale/revoked key
# returns 200 + empty data[], so we require a real "id"). A down key-store DB is
# reported as "heal the DB" (check 05a), NOT "re-mint" (re-minting vs a dead DB fails).
#
# Numbered 59 per doc/specs/2026-06-23-agent-sim-platforms-install-plan.md (58 is
# reserved for AgentScope / Phase 33, Wave 2). doctor keys checks by NAME and the
# count auto-derives from the file set, so the 57->59 gap is intentional, not a
# missing check.
CHECKS+=(oasis)
CHECK_TITLE[oasis]="OASIS venv + scoped LiteLLM key (Phase 34)"

oasis_diagnose() {
  # compgen -G (not ls) — doctor.sh runs under nullglob.
  if ! compgen -G "$AI_STACK/installer/state/phase_34*.done" >/dev/null 2>&1; then
    echo "OASIS not installed in this stack — Phase 34 (opt-in) hasn't run yet (skipping)"
    return 0
  fi

  local venv="$AI_STACK/oasis/.venv"
  [[ -x "$venv/bin/python" ]] || { echo "oasis venv missing ($venv) — re-run 'vz-ai-stack.sh install 34'"; return 1; }
  "$venv/bin/python" -c "import oasis" >/dev/null 2>&1 || { echo "import oasis failed in the venv — re-run 'vz-ai-stack.sh install 34'"; return 1; }
  [[ -x "$AI_STACK/bin/oasis" ]] || { echo "bin/oasis wrapper missing — re-run 'vz-ai-stack.sh install 34'"; return 1; }

  local key; key="$(get_env OASIS_LITELLM_KEY '')"
  [[ -n "$key" ]] || { echo "OASIS_LITELLM_KEY missing from .env — re-run 'vz-ai-stack.sh install 34'"; return 1; }
  local models
  models="$(litellm_scoped_curl "$key" -s --max-time 5 http://litellm:4000/v1/models 2>/dev/null || true)"
  printf '%s' "$models" | grep -q '"id"' \
    || models="$(litellm_scoped_curl "$key" -s --max-time 5 http://127.0.0.1:4000/v1/models 2>/dev/null || true)"
  if ! printf '%s' "$models" | grep -q '"id"'; then
    if declare -F litellm_db_down >/dev/null 2>&1 && litellm_db_down; then
      echo "LiteLLM key-store DB is DOWN — heal it (see check 05a / 'vz-ai-stack.sh doctor keystore'); do NOT re-mint"
      return 1
    fi
    echo "OASIS_LITELLM_KEY rejected by LiteLLM (no models) — re-mint via 'vz-ai-stack.sh install 34'"
    return 1
  fi
  # Allow-list drift assertion (shared helper — see _doctor_assert_key_allowlist in
  # common.sh): the /v1/models probe above only proves the key lists SOME model; this
  # verifies it ALLOWS the model OASIS is bound to (models.yml .assignments.oasis, else
  # local-gemma4). Non-fatal on yq-absent / wildcard / empty / unparseable / LiteLLM-down;
  # FAILs (with its own message) only on a genuine stale-key miss.
  _doctor_assert_key_allowlist "$key" OASIS_LITELLM_KEY oasis "the model OASIS calls" 34 || return 1
  echo "OASIS ready (venv + import + scoped key lists models); prove the swarm: vz-ai-stack.sh test 34"
  return 0
}

oasis_fix() {
  echo "vz-ai-stack.sh install 34   # rebuild venv + re-mint scoped key + refresh bin/oasis"
}
