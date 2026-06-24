#!/usr/bin/env bash
# Hermetic smoke for the openai-compat render branch added to lms_register_model
# (installer/lib/lmstudio.sh). No network, no live LiteLLM. Pins the §24 council's
# render concerns for a GENERIC cloud route: literal api_key sentinel built from
# key_env (never the expanded secret), api_base passthrough (NOT hardcoded),
# required-field fail-closed, INTEGER rpm/tpm (a string churns the SHA -> false
# CHANGED -> needless restart), tpm-omitted-when-undeclared, and idempotency.
# Run: bash installer/smoke/models-openai-compat.sh
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; export AI_STACK
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh" 2>/dev/null || true
source "$AI_STACK/installer/lib/lmstudio.sh"

hdr "Smoke — openai-compat model render (generic OpenAI-compatible cloud route)"
pass=0; fail=0
yes_(){ pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
no_(){ fail=$((fail+1)); printf '  ✗ %s\n' "$1"; }
q(){ yq -r ".model_list[] | select(.model_name==\"$1\") | $2" "$LMS_CONFIG"; }

tmp="$(mktemp -d)"; export LMS_CONFIG="$tmp/config.yaml"
printf 'model_list: []\n' > "$LMS_CONFIG"

# args: <model_name> <served> openai-compat <effort> <api_base> <key_env> [rpm] [tpm]

# 1. base render: openai/<served> + api_base passthrough + literal os.environ/<KEY> sentinel
lms_register_model fugu-test fugu openai-compat "" https://api.sakana.ai/v1 SAKANA_API_KEY >/dev/null
[[ "$(q fugu-test .litellm_params.model)" == "openai/fugu" ]] \
  && yes_ "model == openai/fugu" || no_ "model wrong: '$(q fugu-test .litellm_params.model)'"
[[ "$(q fugu-test .litellm_params.api_base)" == "https://api.sakana.ai/v1" ]] \
  && yes_ "api_base is DATA (passthrough, not hardcoded)" || no_ "api_base wrong: '$(q fugu-test .litellm_params.api_base)'"
[[ "$(q fugu-test .litellm_params.api_key)" == "os.environ/SAKANA_API_KEY" ]] \
  && yes_ "api_key is the literal os.environ/<KEY_ENV> sentinel" || no_ "api_key wrong: '$(q fugu-test .litellm_params.api_key)'"
# the real secret must NEVER appear in the rendered file (sentinel only)
if grep -q 'os.environ/SAKANA_API_KEY' "$LMS_CONFIG" && ! grep -qiE 'sk-|api_key:[[:space:]]*[A-Za-z0-9_-]{16,}' "$LMS_CONFIG"; then
  yes_ "no expanded secret in the rendered config (sentinel only)"
else no_ "rendered config may contain an expanded secret"; fi
# no rpm/tpm declared -> neither key present
[[ "$(q fugu-test '.litellm_params | has("rpm")')" == "false" && "$(q fugu-test '.litellm_params | has("tpm")')" == "false" ]] \
  && yes_ "no rpm/tpm keys when undeclared" || no_ "spurious rpm/tpm rendered"

# 2. rpm/tpm cost-backstop -> rendered as YAML INTEGERS (no SHA churn)
lms_register_model ultra-test fugu-ultra openai-compat "" https://api.sakana.ai/v1 SAKANA_API_KEY 6 120000 >/dev/null
[[ "$(q ultra-test '.litellm_params.rpm | tag')" == "!!int" ]] \
  && yes_ "rpm is a YAML int" || no_ "rpm not int: $(q ultra-test '.litellm_params.rpm | tag')"
[[ "$(q ultra-test '.litellm_params.tpm | tag')" == "!!int" ]] \
  && yes_ "tpm is a YAML int" || no_ "tpm not int: $(q ultra-test '.litellm_params.tpm | tag')"
[[ "$(q ultra-test .litellm_params.rpm)" == "6" ]] \
  && yes_ "rpm value == 6" || no_ "rpm value wrong"

# 3. fail-closed: missing api_base -> non-zero AND the model is NOT written
rc=0; lms_register_model bad-noapi served openai-compat "" "" SAKANA_API_KEY >/dev/null 2>&1 || rc=$?
{ [[ "$rc" -ne 0 ]] && [[ "$(q bad-noapi .litellm_params.model)" == "" || "$(q bad-noapi .litellm_params.model)" == "null" ]]; } \
  && yes_ "missing api_base -> fail-closed (non-zero, nothing written)" || no_ "missing api_base not rejected (rc=$rc)"

# 4. fail-closed: missing key_env -> non-zero
rc=0; lms_register_model bad-nokey served openai-compat "" https://api.example/v1 "" >/dev/null 2>&1 || rc=$?
[[ "$rc" -ne 0 ]] && yes_ "missing key_env -> fail-closed (non-zero)" || no_ "missing key_env not rejected (rc=$rc)"

# 5. idempotency: re-render the same -> UNCHANGED (no needless LiteLLM restart)
res="$(lms_register_model fugu-test fugu openai-compat "" https://api.sakana.ai/v1 SAKANA_API_KEY)"
[[ "$res" == "UNCHANGED" ]] && yes_ "idempotent: 2nd identical render == UNCHANGED" || no_ "2nd render not UNCHANGED: '$res'"

# 6. converge: changing api_base on an existing entry -> CHANGED + new value in place
res="$(lms_register_model fugu-test fugu openai-compat "" https://api.sakana.ai/v2 SAKANA_API_KEY)"
{ [[ "$res" == "CHANGED" ]] && [[ "$(q fugu-test .litellm_params.api_base)" == "https://api.sakana.ai/v2" ]]; } \
  && yes_ "converge: changed api_base -> CHANGED + replaced in place" || no_ "converge failed: '$res'"

rm -rf "$tmp"
echo
if (( fail==0 )); then printf '✓ models-openai-compat: %d checks passed\n' "$pass"; exit 0
else printf '✗ models-openai-compat: %d passed, %d FAILED\n' "$pass" "$fail"; exit 1; fi
