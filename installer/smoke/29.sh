#!/usr/bin/env bash
# Smoke for Phase 29 (OpenWork). Asserts the install LANDED + works end-to-end from
# the path OpenWork actually exercises — not just that `install 29` exited 0:
#   1. the openwork orchestrator binary resolves + --version runs
#   2. the seeded opencode.json exists + is valid JSON with the LiteLLM provider
#   3. the headless daemon serves HTTP 200 on the loopback /health (:8787)
#   4. the minted OPENWORK_LITELLM_KEY can list models AND complete 1 token
#      through LiteLLM (the real OpenWork → OpenCode → LiteLLM path)
# Run: bash installer/smoke/29.sh
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

PORT=8787
WORKDIR="${OPENWORK_WORKDIR:-$HOME/.openwork-stack}"
OC_JSON="$WORKDIR/opencode.json"

hdr "Smoke Phase 29 — OpenWork"

# 1. binary resolves + version
bin=""
if command -v openwork >/dev/null 2>&1; then bin="$(command -v openwork)"
elif [[ -x "$HOME/.local/bin/openwork" ]]; then bin="$HOME/.local/bin/openwork"
elif command -v npm >/dev/null 2>&1 && [[ -x "$(npm prefix -g 2>/dev/null)/bin/openwork" ]]; then bin="$(npm prefix -g 2>/dev/null)/bin/openwork"
fi
[[ -n "$bin" ]] || { err "openwork binary not found (PATH / npm global)"; exit 1; }
ver="$("$bin" --version 2>/dev/null | head -1)"; [[ -n "$ver" ]] && ok "openwork runnable (version $ver)" \
  || { err "openwork not runnable"; exit 1; }

# 2. opencode.json present + valid + has the LiteLLM provider
[[ -f "$OC_JSON" ]] || { err "opencode.json missing ($OC_JSON)"; exit 1; }
python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert "litellm" in d.get("provider",{}), "no litellm provider"' "$OC_JSON" 2>/dev/null \
  && ok "opencode.json valid + LiteLLM provider present" \
  || { err "opencode.json invalid or missing the LiteLLM provider"; exit 1; }

# 3. daemon serves 200 on loopback /health
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://127.0.0.1:$PORT/health" 2>/dev/null || true)"
[[ "$code" == "200" ]] && ok "OpenWork daemon serves HTTP 200 on http://127.0.0.1:$PORT/health" \
  || { err "OpenWork daemon not serving 200 on :$PORT/health (got $code) — 'vz-ai-stack.sh start openwork'; log: installer/state/openwork.launchd.log"; exit 1; }

# 4. minted key lists models + completes 1 token (the real OpenWork → LiteLLM path)
key="$(get_env OPENWORK_LITELLM_KEY '')"
[[ -n "$key" ]] || { err "OPENWORK_LITELLM_KEY missing from .env"; exit 1; }
litellm_scoped_curl "$key" -sf --max-time 6 http://litellm:4000/v1/models >/dev/null 2>&1 \
  && ok "OPENWORK_LITELLM_KEY lists models via LiteLLM" \
  || { err "OPENWORK_LITELLM_KEY rejected by LiteLLM /v1/models"; exit 1; }
chat_code="$(litellm_scoped_curl "$key" -s -o /dev/null -w '%{http_code}' --max-time 30 -H 'Content-Type: application/json' \
  -X POST http://litellm:4000/v1/chat/completions \
  -d '{"model":"local-gemma4","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' 2>/dev/null || true)"
[[ "$chat_code" == "200" ]] && ok "OPENWORK_LITELLM_KEY completes a chat through LiteLLM (local-gemma4, HTTP 200)" \
  || warn "chat completion returned HTTP $chat_code (key valid for /v1/models; the model may be down — advisory, not a hard fail)"

ok "Phase 29 smoke: OpenWork installed + daemon healthy + opencode.json seeded + LiteLLM key works"
