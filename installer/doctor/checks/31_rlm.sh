# RLM (Recursive Language Models) installed + LiteLLM-routed (Phase 18).
#
# Verifies the rlms venv imports, the bin/rlm wrapper + runner exist, rlm/.env
# routes through LiteLLM, and RLM_LITELLM_KEY is accepted. Skips cleanly when
# RLM was never installed (rlm/.venv absent). Never prints the key.
CHECKS+=(rlm_install)
CHECK_TITLE[rlm_install]="RLM installed + LiteLLM virtual key valid (Phase 18)"

rlm_install_diagnose() {
  local rlm_dir="$AI_STACK/rlm"
  # Not installed yet → skip (don't fail a stack that never ran Phase 18).
  if [[ ! -x "$rlm_dir/.venv/bin/python" ]]; then
    echo "RLM not installed (rlm/.venv absent) — run 'install.sh install 18' to add it. [skip]"
    return 0
  fi
  "$rlm_dir/.venv/bin/python" -c 'import rlm' 2>/dev/null || { echo "rlms not importable in rlm/.venv — re-run 'install 18'"; return 1; }
  [[ -f "$rlm_dir/run_rlm.py" ]]   || { echo "rlm/run_rlm.py missing — re-run 'install 18'"; return 1; }
  [[ -x "$AI_STACK/bin/rlm" ]]     || { echo "bin/rlm wrapper missing — re-run 'install 18'"; return 1; }
  grep -q '^OPENAI_BASE_URL=http://litellm:4000/v1' "$rlm_dir/.env" 2>/dev/null \
    || { echo "rlm/.env does not route to LiteLLM (OPENAI_BASE_URL) — re-run 'install 18'"; return 1; }
  local k; k="$(get_env RLM_LITELLM_KEY '')"
  [[ -n "$k" ]] || { echo "RLM_LITELLM_KEY missing from .env — re-run 'install 18'"; return 1; }
  curl -sf --max-time 5 -H "Authorization: Bearer $k" http://litellm:4000/v1/models >/dev/null 2>&1 \
    || { echo "RLM_LITELLM_KEY rejected by LiteLLM (revoked/rotated?) — re-run 'install 18'"; return 1; }
  return 0
}

rlm_install_fix() {
  warn "Re-run Phase 18 to (re)install rlms + mint the key + write bin/rlm:"
  warn "    bash $AI_STACK/install.sh install 18"
  return 1
}
