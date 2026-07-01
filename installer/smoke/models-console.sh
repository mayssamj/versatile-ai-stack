#!/usr/bin/env bash
# Hermetic smoke for the Model & Agent Console proxy (installer/lib/models_proxy.py).
# NO live LiteLLM, NO container, NO network mutation. Boots the proxy in --read-only
# mode against an ISOLATED SANDBOX copy of {models.yml, config.yaml} on a loopback
# port, then pins the council-locked API + security contract:
#   * GET /api/state returns the enriched shape (models/assignments/parked/kinds/
#     fallbacks/openrouter_routes/key_env_present).
#   * POST /api/stage runs the REAL `model edit --no-sync` in its own sandbox and
#     returns a TRUE models.yml diff — but never mutates the source files.
#   * a refused change (remove the default model) comes back as a CLEAN 400, not a 500.
#   * a non-loopback Host header is rejected (403) — DNS-rebinding guard.
#   * POST /api/apply is refused (403) in --read-only mode.
#   * the sandbox source files are byte-identical after state+stage (no leak to disk).
# Run: bash installer/smoke/models-console.sh
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; export AI_STACK
source "$AI_STACK/installer/lib/common.sh"

hdr "Smoke — Model & Agent Console proxy (read-only, hermetic)"
pass=0; fail=0
yes_(){ pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
no_(){ fail=$((fail+1)); printf '  ✗ %s\n' "$1"; }

PROXY="$AI_STACK/installer/lib/models_proxy.py"
[[ -f "$PROXY" ]] || { no_ "models_proxy.py present"; printf '✗ models-console: proxy missing\n'; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "python3 unavailable [skip]"; exit 0; }
command -v curl    >/dev/null 2>&1 || { echo "curl unavailable [skip]"; exit 0; }

# Isolated sandbox so the smoke can NEVER touch the repo's real models.yml/config.yaml.
tmp="$(mktemp -d)"
cp "$AI_STACK/installer/models.yml"   "$tmp/models.yml"
cp "$AI_STACK/litellm/config.yaml"    "$tmp/config.yaml"
printf '# smoke env (empty)\n' > "$tmp/.env"
b_models="$(shasum "$tmp/models.yml" | awk '{print $1}')"
b_config="$(shasum "$tmp/config.yaml" | awk '{print $1}')"

# Pick a free high port (avoid the live 8898 default).
PORT=8893
H='-H Host:127.0.0.1'

# Boot the proxy: MC_* (proxy config) + exported MODELS_YML/CONFIG so even /api/state's
# `model list` reads the sandbox, not the repo. No MC_KEY_FILE -> /api/test stays 503.
MODELS_YML="$tmp/models.yml" CONFIG="$tmp/config.yaml" \
MC_PORT="$PORT" MC_LITELLM="http://127.0.0.1:4000" MC_KEY_FILE="" MC_HTML="$AI_STACK/doc/MODELS.html" \
  MC_ROOT="$AI_STACK" MC_MODELS_SH="$AI_STACK/installer/lib/models.sh" \
  MC_EMBED_SH="$AI_STACK/installer/lib/embeddings.sh" MC_START_LITELLM="$AI_STACK/bin/start-litellm.sh" \
  MC_MODELS_YML="$tmp/models.yml" MC_CONFIG="$tmp/config.yaml" MC_ENV_FILE="$tmp/.env" MC_READONLY=1 \
  python3 "$PROXY" >"$tmp/proxy.log" 2>&1 &
PROXY_PID=$!
cleanup(){ kill "$PROXY_PID" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT INT TERM

# Wait for the listener (up to ~5s).
up=0
for _ in $(seq 1 25); do
  curl -s $H -o /dev/null "http://127.0.0.1:$PORT/api/health" && { up=1; break; }
  sleep 0.2
done
(( up )) && yes_ "proxy booted + /api/health reachable on loopback" || { no_ "proxy did not boot"; cat "$tmp/proxy.log"; }

# 1. /api/state enriched shape.
state="$(curl -s $H "http://127.0.0.1:$PORT/api/state")"
echo "$state" | python3 -c 'import sys,json
d=json.load(sys.stdin)
need=["default","primary","models","assignments","parked","kinds","fallbacks","openrouter_routes","key_env_present","read_only"]
miss=[k for k in need if k not in d]
assert not miss, "missing keys: %s"%miss
assert isinstance(d["models"],dict) and d["models"], "no models"
assert d["read_only"] is True, "read_only flag not propagated"
' 2>/dev/null && yes_ "/api/state returns the enriched, read-only shape" || no_ "/api/state shape wrong"

# 2. /api/stage edit -> real models.yml diff, no live mutation.
stg="$(curl -s $H -X POST "http://127.0.0.1:$PORT/api/stage" \
  -d '{"op":"edit","args":{"name":"local","field":"note","value":"SMOKE-CONSOLE-NOTE"}}')"
echo "$stg" | python3 -c 'import sys,json
d=json.load(sys.stdin)
assert d.get("ok") is True, d
assert "SMOKE-CONSOLE-NOTE" in d.get("models_diff",""), "diff missing the staged note"
assert d.get("needs_recreate") is False, "edit should not need recreate"
' 2>/dev/null && yes_ "/api/stage edit -> true models.yml diff (sandbox), needs_recreate=false" || no_ "/api/stage edit failed: $stg"

# 3. refused change (remove .default) -> CLEAN 400, not a 500/crash.
code="$(curl -s $H -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/stage" \
  -d '{"op":"remove","args":{"name":"local"}}')"
[[ "$code" == "400" ]] && yes_ "removing the default model -> clean 400 (guard surfaced, no crash)" || no_ "remove-default expected 400, got $code"

# 4. non-loopback Host -> 403 (DNS-rebinding guard).
code="$(curl -s -H 'Host: evil.example.com' -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/stage" -d '{}')"
[[ "$code" == "403" ]] && yes_ "non-loopback Host -> 403 (rebinding guard)" || no_ "foreign Host expected 403, got $code"

# 5. apply refused in read-only.
code="$(curl -s $H -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/apply" \
  -d '{"op":"edit","args":{"name":"local","field":"note","value":"x"}}')"
[[ "$code" == "403" ]] && yes_ "POST /api/apply -> 403 in --read-only mode" || no_ "read-only apply expected 403, got $code"

# 6. sandbox source files untouched (no write leaked out of stage's own temp).
a_models="$(shasum "$tmp/models.yml" | awk '{print $1}')"
a_config="$(shasum "$tmp/config.yaml" | awk '{print $1}')"
{ [[ "$b_models" == "$a_models" && "$b_config" == "$a_config" ]]; } \
  && yes_ "source models.yml + config.yaml byte-identical after state+stage" || no_ "source files mutated by a read-only session!"

# 7. cross-origin POST -> 403 (CSRF guard: Origin host not loopback). Complements no-CORS.
code="$(curl -s $H -H 'Origin: http://evil.example.com' -o /dev/null -w '%{http_code}' \
  -X POST "http://127.0.0.1:$PORT/api/stage" -d '{"op":"edit","args":{"name":"local","field":"note","value":"x"}}')"
[[ "$code" == "403" ]] && yes_ "cross-origin POST (foreign Origin) -> 403 (CSRF guard)" || no_ "cross-origin POST expected 403, got $code"

# 8. argv leading-dash smuggling -> clean 400 (a value/name starting with '-' is rejected).
code="$(curl -s $H -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/stage" \
  -d '{"op":"assign","args":{"agent":"--dry-run","model":"local"}}')"
[[ "$code" == "400" ]] && yes_ "leading-dash arg ('--dry-run') -> clean 400 (argv-smuggling guard)" || no_ "dash-arg expected 400, got $code"

# 9. add op (ollama) stages a true diff in the sandbox (or 400 if already declared — both OK).
stg="$(curl -s $H -X POST "http://127.0.0.1:$PORT/api/stage" \
  -d '{"op":"add","args":{"runtime":"ollama","served":"smoke-test:tag","name":"local-smoke-test","big":false}}')"
echo "$stg" | python3 -c 'import sys,json
d=json.load(sys.stdin)
assert d.get("ok") is True and "local-smoke-test" in d.get("models_diff",""), d
assert d.get("needs_recreate") is False, "ollama add should not need recreate"
' 2>/dev/null && yes_ "/api/stage add(ollama) -> true diff, needs_recreate=false" || no_ "add(ollama) stage failed: $stg"

# 10. add op (openai-compat, NEW key_env) -> needs_recreate=true (the highest-risk gate).
stg="$(curl -s $H -X POST "http://127.0.0.1:$PORT/api/stage" \
  -d '{"op":"add","args":{"runtime":"openai-compat","served":"x","api_base":"https://api.example/v1","key_env":"SMOKE_NEW_KEY","name":"smoke-oc"}}')"
echo "$stg" | python3 -c 'import sys,json
d=json.load(sys.stdin)
assert d.get("ok") is True, d
assert d.get("needs_recreate") is True, "new vendor key_env must flag needs_recreate"
# MEDIUM-1 regression: the config render-plan must NOT over-capture P3/P4 sections.
cd=d.get("config_diff","")
assert "widening plan" not in cd and "render plan" not in cd, "config_diff over-captured sync P3/P4 output"
' 2>/dev/null && yes_ "/api/stage add(openai-compat new key) -> needs_recreate=true + clean render-plan (no P3/P4 bleed)" || no_ "add(openai-compat) stage failed: $stg"

# 11. /api/test -> 503 when no key minted (LiteLLM best-effort degraded).
code="$(curl -s $H -o /dev/null -w '%{http_code}' -X POST "http://127.0.0.1:$PORT/api/test" -d '{"model":"local"}')"
[[ "$code" == "503" ]] && yes_ "/api/test -> 503 when no test key (best-effort degrade)" || no_ "no-key test expected 503, got $code"

echo
if (( fail==0 )); then printf '✓ models-console: %d checks passed\n' "$pass"; exit 0
else printf '✗ models-console: %d passed, %d FAILED\n' "$pass" "$fail"; exit 1; fi
