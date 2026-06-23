#!/usr/bin/env bash
# smoke/32.sh — Phase 32 (MetaGPT) E2E gate. Proves the install LANDED and the
# scoped key actually reaches a model THROUGH LiteLLM — not just "install exited 0".
# (A full `metagpt "<brief>"` swarm run is the live e2e step; it's minutes long, so
# the smoke proves the load-bearing path: venv + import + key → real chat completion.)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

hdr "Smoke 32 — MetaGPT (venv + scoped key → LiteLLM)"

VENV="$AI_STACK/metagpt/.venv"
[[ -x "$VENV/bin/metagpt" ]] || { err "metagpt venv missing — run: vz-ai-stack.sh install 32"; exit 1; }
"$VENV/bin/python" -c "import metagpt" >/dev/null 2>&1 && ok "import metagpt OK ($("$VENV/bin/metagpt" --version 2>/dev/null | head -1))" \
  || { err "import metagpt failed in the venv"; exit 1; }
[[ -x "$AI_STACK/bin/metagpt" ]] || { err "bin/metagpt wrapper missing"; exit 1; }

KEY="$(get_env METAGPT_LITELLM_KEY '')"
[[ -n "$KEY" ]] || { err "METAGPT_LITELLM_KEY absent from .env"; exit 1; }
printf '%s' "$(curl -s --max-time 5 -H "Authorization: Bearer $KEY" http://litellm:4000/v1/models 2>/dev/null)" | grep -q '"id"' \
  && ok "scoped key lists models via LiteLLM" || { err "METAGPT_LITELLM_KEY lists no models (stale/rejected)"; exit 1; }

MODEL="${METAGPT_MODEL:-local-gemma4}"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _mm="$(yq -r '.assignments.metagpt // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"; [[ -n "$_mm" && "$_mm" != "null" ]] && MODEL="$_mm"
fi
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 40 \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -X POST http://litellm:4000/v1/chat/completions \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":4}" 2>/dev/null || echo 000)"
[[ "$code" == "200" ]] && ok "real chat completion via $MODEL through LiteLLM (HTTP 200) — traced in Phoenix" \
  || { err "chat completion returned HTTP $code (model $MODEL) — MetaGPT would fail to call a model"; exit 1; }

ok "Smoke 32 PASS — MetaGPT installed + scoped key reaches a model through LiteLLM"
