#!/usr/bin/env bash
# Hermetic smoke for the openai + codex-bridge model render branches added to
# lms_register_model (installer/lib/lmstudio.sh). No network, no live LiteLLM.
# Pins the §24 council's render concerns: literal api_key sentinel, INTEGER
# rpm/tpm (a string would churn the SHA -> false CHANGED -> needless restart),
# optional-effort omit (the gpt-5.5-pro case), and idempotency.
# Run: bash installer/smoke/models-gpt.sh
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; export AI_STACK
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh" 2>/dev/null || true
source "$AI_STACK/installer/lib/lmstudio.sh"

hdr "Smoke — GPT model render (openai + codex-bridge)"
pass=0; fail=0
yes_(){ pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
no_(){ fail=$((fail+1)); printf '  ✗ %s\n' "$1"; }
q(){ yq -r ".model_list[] | select(.model_name==\"$1\") | $2" "$LMS_CONFIG"; }

tmp="$(mktemp -d)"; export LMS_CONFIG="$tmp/config.yaml"
printf 'model_list: []\n' > "$LMS_CONFIG"

# 1. openai render: literal api_key sentinel + reasoning_effort + openai/<served>
lms_register_model gpt-test-5.5 gpt-5.5 openai xhigh >/dev/null
[[ "$(q gpt-test-5.5 .litellm_params.api_key)" == "os.environ/OPENAI_API_KEY" ]] \
  && yes_ "openai: api_key is the literal env-ref sentinel" || no_ "openai api_key wrong: '$(q gpt-test-5.5 .litellm_params.api_key)'"
[[ "$(q gpt-test-5.5 .litellm_params.model)" == "openai/gpt-5.5" ]] \
  && yes_ "openai: model == openai/gpt-5.5" || no_ "openai model wrong"
[[ "$(q gpt-test-5.5 .litellm_params.reasoning_effort)" == "xhigh" ]] \
  && yes_ "openai: reasoning_effort == xhigh" || no_ "openai reasoning_effort wrong"

# 2. openai with NO effort -> no reasoning_effort key (the gpt-5.5-pro case)
lms_register_model gpt-test-pro gpt-5.5-pro openai "" >/dev/null
[[ "$(q gpt-test-pro '.litellm_params | has("reasoning_effort")')" == "false" ]] \
  && yes_ "openai no-effort: reasoning_effort omitted (no spurious null)" || no_ "pro should have NO reasoning_effort"

# 3. codex-bridge render: bridge api_base + dummy key + INTEGER rpm/tpm + reasoning_effort
lms_register_model gpt-test-sub gpt-5.5 codex-bridge high >/dev/null
[[ "$(q gpt-test-sub .litellm_params.api_base)" == *":3457/v1" ]] \
  && yes_ "codex-bridge: api_base -> :3457/v1" || no_ "codex-bridge api_base wrong"
[[ "$(q gpt-test-sub .litellm_params.api_key)" == "codex-bridge" ]] \
  && yes_ "codex-bridge: dummy api_key" || no_ "codex-bridge api_key wrong"
[[ "$(q gpt-test-sub '.litellm_params.rpm | tag')" == "!!int" ]] \
  && yes_ "codex-bridge: rpm is a YAML int (no SHA churn)" || no_ "rpm not int: $(q gpt-test-sub '.litellm_params.rpm | tag')"
[[ "$(q gpt-test-sub .litellm_params.reasoning_effort)" == "high" ]] \
  && yes_ "codex-bridge: reasoning_effort == high" || no_ "codex-bridge reasoning_effort wrong"

# 4. idempotency: re-render the same -> UNCHANGED (no needless LiteLLM restart)
res="$(lms_register_model gpt-test-sub gpt-5.5 codex-bridge high)"
[[ "$res" == "UNCHANGED" ]] && yes_ "idempotent: 2nd render == UNCHANGED" || no_ "2nd render not UNCHANGED: '$res'"

rm -rf "$tmp"
echo
if (( fail==0 )); then printf '✓ models-gpt: %d checks passed\n' "$pass"; exit 0
else printf '✗ models-gpt: %d passed, %d FAILED\n' "$pass" "$fail"; exit 1; fi
