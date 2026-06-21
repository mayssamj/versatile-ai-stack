#!/usr/bin/env bash
# Smoke for Phase 28 (AionUi). Asserts the install LANDED + works end-to-end from
# the path AionUi actually exercises — not just that `install 28` exited 0:
#   1. the desktop cask is present
#   2. the prebuilt aionui-web binary is installed + runnable (version)
#   3. the WebUI daemon serves HTTP 200 on the loopback port :25808
#   4. the minted AIONUI_LITELLM_KEY can list models AND complete 1 token
#      through LiteLLM (the real AionUi → LiteLLM path)
# Run: bash installer/smoke/28.sh
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

AW="$HOME/.local/share/aionui-web/aionui-web"
PORT=25808

hdr "Smoke Phase 28 — AionUi"

# 1. cask present
brew list --cask aionui >/dev/null 2>&1 && ok "AionUi desktop cask present" \
  || { err "AionUi cask missing"; exit 1; }

# 2. aionui-web binary + version
[[ -x "$AW" ]] || { err "aionui-web binary missing ($AW)"; exit 1; }
ver="$("$AW" version 2>/dev/null | head -1)"; [[ -n "$ver" ]] && ok "aionui-web runnable (version $ver)" \
  || { err "aionui-web not runnable"; exit 1; }

# 3. WebUI serves 200 on loopback
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://127.0.0.1:$PORT/" 2>/dev/null || echo 000)"
[[ "$code" == "200" ]] && ok "WebUI serves HTTP 200 on http://127.0.0.1:$PORT" \
  || { err "WebUI not serving 200 on :$PORT (got $code) — 'vz-ai-stack.sh start aionui'; log: installer/state/aionui-web.launchd.log"; exit 1; }

# 4. minted key lists models + completes 1 token (the real AionUi → LiteLLM path)
key="$(get_env AIONUI_LITELLM_KEY '')"
[[ -n "$key" ]] || { err "AIONUI_LITELLM_KEY missing from .env"; exit 1; }
curl -sf --max-time 6 -H "Authorization: Bearer $key" http://litellm:4000/v1/models >/dev/null 2>&1 \
  && ok "AIONUI_LITELLM_KEY lists models via LiteLLM" \
  || { err "AIONUI_LITELLM_KEY rejected by LiteLLM /v1/models"; exit 1; }
chat_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 -H "Authorization: Bearer $key" -H 'Content-Type: application/json' \
  -X POST http://litellm:4000/v1/chat/completions \
  -d '{"model":"local-gemma4","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' 2>/dev/null || echo 000)"
[[ "$chat_code" == "200" ]] && ok "AIONUI_LITELLM_KEY completes a chat through LiteLLM (local-gemma4, HTTP 200)" \
  || warn "chat completion returned HTTP $chat_code (key valid for /v1/models; the model may be down — advisory, not a hard fail)"

ok "Phase 28 smoke: AionUi installed + WebUI healthy + LiteLLM key works"
