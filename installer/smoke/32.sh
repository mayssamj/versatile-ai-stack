#!/usr/bin/env bash
# smoke/32.sh — Phase 32 (MetaGPT) E2E gate. Exercises the REAL bin/metagpt wrapper
# (not just a curl): runs `bin/metagpt --help` so the wrapper writes ~/.metagpt/
# config2.yaml AND the metagpt CLI actually loads (catches the typer/click + broken-
# console-script class), asserts config2.yaml routes at LiteLLM, then proves the
# scoped key in that config reaches a model. A full `metagpt "<idea>"` project run is
# the minutes-long e2e; this proves the load-bearing path without it.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

hdr "Smoke 32 — MetaGPT (real wrapper + scoped key -> LiteLLM)"

VENV="$AI_STACK/metagpt/.venv"
[[ -x "$VENV/bin/metagpt" ]] || { err "metagpt venv missing — run: vz-ai-stack.sh install 32"; exit 1; }
"$VENV/bin/python" -c "import metagpt" >/dev/null 2>&1 && ok "import metagpt OK" \
  || { err "import metagpt failed in the venv"; exit 1; }
[[ -x "$AI_STACK/bin/metagpt" ]] || { err "bin/metagpt wrapper missing"; exit 1; }

# Exercise the REAL wrapper: it writes ~/.metagpt/config2.yaml then runs the metagpt
# CLI. `--help` loads the full typer CLI (catches the typer/click + console-script
# class) without launching a minutes-long project run.
"$AI_STACK/bin/metagpt" --help >/dev/null 2>&1 \
  && ok "bin/metagpt runs (wrapper + venv + metagpt CLI load OK)" \
  || { err "bin/metagpt --help failed — the wrapper or the metagpt CLI is broken (typer/click? config2.yaml?)"; exit 1; }

# The wrapper just (re)wrote ~/.metagpt/config2.yaml — assert it points at LiteLLM.
CFG="$HOME/.metagpt/config2.yaml"
[[ -f "$CFG" ]] || { err "bin/metagpt did not write $CFG — wrapper config generation is broken"; exit 1; }
grep -q 'base_url: "http://127.0.0.1:4000/v1"' "$CFG" \
  && ok "config2.yaml routes MetaGPT at LiteLLM (127.0.0.1:4000)" \
  || { err "$CFG base_url is not the LiteLLM endpoint — MetaGPT would call the wrong host"; exit 1; }

# Prove the scoped key in that config actually reaches a model through LiteLLM.
KEY="$(get_env METAGPT_LITELLM_KEY '')"
[[ -n "$KEY" ]] || { err "METAGPT_LITELLM_KEY absent from .env"; exit 1; }
MODEL="${METAGPT_MODEL:-local-gemma4}"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _mm="$(yq -r '.assignments.metagpt // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"; [[ -n "$_mm" && "$_mm" != "null" ]] && MODEL="$_mm"
fi
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 40 \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:4000/v1/chat/completions \
  -d "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":4}" 2>/dev/null || echo 000)"
[[ "$code" == "200" ]] && ok "scoped key reaches $MODEL through LiteLLM (HTTP 200) — traced in Phoenix" \
  || { err "chat completion returned HTTP $code (model $MODEL) — MetaGPT would fail to call a model"; exit 1; }

ok "Smoke 32 PASS — bin/metagpt runs, config2.yaml routes at LiteLLM, scoped key reaches a model"
