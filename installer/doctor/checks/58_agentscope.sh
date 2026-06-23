# AgentScope (Phase 33): host-venv multi-agent simulation framework. OPT-IN — skips
# clean when Phase 33 hasn't run. PASS requires: venv + import agentscope + bin/agentscope
# wrapper + a scoped LiteLLM key that actually lists models (a stale/revoked key
# returns 200 + empty data[], so we require a real "id"). A down key-store DB is
# reported as "heal the DB" (check 05a), NOT "re-mint" (re-minting vs a dead DB fails).
#
# Numbered 58 per doc/specs/2026-06-23-agent-sim-platforms-install-plan.md (it fills the
# 57->59 gap left by Wave 1: MetaGPT=57, OASIS=59). doctor keys checks by NAME and the
# count auto-derives from the file set, so adding this file ticks the count by one.
#
# The optional Studio web GUI (host :5275) is a deferred follow-up; this check is for the
# core lib only — if/when Studio lands it adds a conditional :5275/ probe here.
CHECKS+=(agentscope)
CHECK_TITLE[agentscope]="AgentScope venv + scoped LiteLLM key (Phase 33)"

agentscope_diagnose() {
  # compgen -G (not ls) — doctor.sh runs under nullglob.
  if ! compgen -G "$AI_STACK/installer/state/phase_33*.done" >/dev/null 2>&1; then
    echo "AgentScope not installed in this stack — Phase 33 (opt-in) hasn't run yet (skipping)"
    return 0
  fi

  local venv="$AI_STACK/agentscope/.venv"
  [[ -x "$venv/bin/python" ]] || { echo "agentscope venv missing ($venv) — re-run 'vz-ai-stack.sh install 33'"; return 1; }
  "$venv/bin/python" -c "import agentscope" >/dev/null 2>&1 || { echo "import agentscope failed in the venv — re-run 'vz-ai-stack.sh install 33'"; return 1; }
  [[ -x "$AI_STACK/bin/agentscope" ]] || { echo "bin/agentscope wrapper missing — re-run 'vz-ai-stack.sh install 33'"; return 1; }

  local key; key="$(get_env AGENTSCOPE_LITELLM_KEY '')"
  [[ -n "$key" ]] || { echo "AGENTSCOPE_LITELLM_KEY missing from .env — re-run 'vz-ai-stack.sh install 33'"; return 1; }
  local models
  models="$(curl -s --max-time 5 -H "Authorization: Bearer $key" http://litellm:4000/v1/models 2>/dev/null || true)"
  printf '%s' "$models" | grep -q '"id"' \
    || models="$(curl -s --max-time 5 -H "Authorization: Bearer $key" http://127.0.0.1:4000/v1/models 2>/dev/null || true)"
  if ! printf '%s' "$models" | grep -q '"id"'; then
    if declare -F litellm_db_down >/dev/null 2>&1 && litellm_db_down; then
      echo "LiteLLM key-store DB is DOWN — heal it (see check 05a / 'vz-ai-stack.sh doctor keystore'); do NOT re-mint"
      return 1
    fi
    echo "AGENTSCOPE_LITELLM_KEY rejected by LiteLLM (no models) — re-mint via 'vz-ai-stack.sh install 33'"
    return 1
  fi
  echo "AgentScope ready (venv + import + scoped key lists models); prove the swarm: vz-ai-stack.sh test 33"
  return 0
}

agentscope_fix() {
  echo "vz-ai-stack.sh install 33   # rebuild venv + re-mint scoped key + refresh bin/agentscope"
}
