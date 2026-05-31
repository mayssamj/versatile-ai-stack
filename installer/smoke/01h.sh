#!/usr/bin/env bash
# smoke/01h.sh — Phoenix end-to-end: trace lands in ai-stack project.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/validate.sh"

hdr "Smoke 01·H — Phoenix"

KEY="$(get_env LITELLM_MASTER_KEY)"
PKEY="$(get_env PHOENIX_API_KEY "")"

# 1. UI 200
wait_http http://phoenix:6006 5 || { err "Phoenix UI not responding"; exit 1; }
ok "Phoenix UI responds (200)"

# 2. Send an inference
log "Sending one inference call (Phoenix probe)..."
curl -s --max-time 30 \
  -H "Authorization: Bearer $KEY" -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"phoenix smoke 42"}],"max_tokens":3}' \
  http://litellm:4000/v1/chat/completions >/dev/null
ok "inference dispatched"

# 3. Wait for OTel batch flush
sleep 10

# 4. Probe Phoenix /v1/projects
log "Looking for 'ai-stack' project in Phoenix..."
if [[ -n "$PKEY" ]]; then
  body="$(curl -s --max-time 5 -H "Authorization: Bearer $PKEY" http://phoenix:6006/v1/projects)"
else
  body="$(curl -s --max-time 5 http://phoenix:6006/v1/projects)"
fi

if echo "$body" | grep -qiE 'unauthorized|invalid token'; then
  warn "/v1/projects requires auth — set PHOENIX_API_KEY in .env (UI → Settings → API Keys)."
  warn "Smoke can't verify traces landed without a key. Open the UI manually to confirm."
  exit 1
fi

if echo "$body" | jq -r '.data[]?.name' 2>/dev/null | grep -qxF 'ai-stack'; then
  ok "Phoenix has 'ai-stack' project — traces are flowing"
else
  err "'ai-stack' project not found in Phoenix"
  echo "$body" | jq '.data[]?.name' 2>/dev/null
  warn "Check litellm logs for OTel export errors: docker logs litellm | grep -i otlp"
  exit 1
fi
ok "smoke 01·H complete"
