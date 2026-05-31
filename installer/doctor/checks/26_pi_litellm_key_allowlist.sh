# PI_LITELLM_KEY is minted, present in .env, and LiteLLM enforces its
# model allowlist at the proxy layer.
#
# Asserts:
#   1. PI_LITELLM_KEY exists in .env (Phase 15 minted it).
#   2. GET /v1/models with the virtual key returns exactly the 3 allowlisted
#      model_names: local, local-heavy, local-lfm2 (sorted).
#   3. POST /v1/chat/completions with model=claude-opus is rejected with
#      a "key not allowed" 4xx error — proves the allowlist is server-side
#      and not just client-side (Pi's extension config alone wouldn't stop
#      a compromised extension from requesting any model).
#
# Pre-condition: LiteLLM must be healthy. If LiteLLM is down we WARN-skip
# rather than fail-cascade.
CHECKS+=(pi_litellm_key_allowlist)
CHECK_TITLE[pi_litellm_key_allowlist]="LiteLLM virtual key PI_LITELLM_KEY enforces model allowlist server-side"

_pi_litellm_litellm_up() {
  curl -sf --max-time 3 http://litellm:4000/health/readiness >/dev/null 2>&1
}

pi_litellm_key_allowlist_diagnose() {
  # Skip with WARN if LiteLLM isn't responding — avoids cascade-failure.
  if ! _pi_litellm_litellm_up; then
    echo "  (LiteLLM not responding — skipping; see check 11 + Phase 01)"
    return 0
  fi

  local pi_key
  pi_key="$(get_env PI_LITELLM_KEY '' 2>/dev/null || echo '')"
  if [[ -z "$pi_key" ]]; then
    echo "PI_LITELLM_KEY missing from .env — re-run 'bash install.sh install 15'"
    return 1
  fi

  # (1) /v1/models returns exactly the allowlisted set.
  local models_json
  models_json="$(curl -s --max-time 5 -H "Authorization: Bearer $pi_key" \
    http://litellm:4000/v1/models 2>/dev/null || echo '')"
  if [[ -z "$models_json" ]]; then
    echo "GET /v1/models with PI_LITELLM_KEY returned no body"
    return 1
  fi
  local got_models
  got_models="$(echo "$models_json" \
    | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
    print(",".join(sorted(m["id"] for m in d.get("data",[]))))
except Exception as e:
    print("ERR:"+str(e))' 2>/dev/null)"
  if [[ "$got_models" != "local,local-heavy,local-lfm2" ]]; then
    echo "PI_LITELLM_KEY surfaces models='$got_models' (expected 'local,local-heavy,local-lfm2')"
    return 1
  fi

  # (2) Denied-model chat completion returns a 4xx with "key not allowed".
  # We use grep -q on a substring instead of the full message because
  # LiteLLM has reworded this between minor versions.
  local denied_body
  denied_body="$(curl -s --max-time 5 -H "Authorization: Bearer $pi_key" \
    -H 'Content-Type: application/json' \
    -d '{"model":"claude-opus","messages":[{"role":"user","content":"x"}],"max_tokens":1}' \
    http://litellm:4000/v1/chat/completions 2>/dev/null || echo '')"
  if ! echo "$denied_body" | grep -qi "key not allowed"; then
    echo "POST chat with model=claude-opus did NOT return 'key not allowed' — allowlist may be bypassed!"
    echo "  body: ${denied_body:0:200}"
    return 1
  fi
}

pi_litellm_key_allowlist_fix() {
  warn "Re-mint PI_LITELLM_KEY by re-running Phase 15:"
  warn "    bash $AI_STACK/install.sh install 15"
  warn "(Phase 15 detects an invalid key and re-mints automatically.)"
  return 1
}
