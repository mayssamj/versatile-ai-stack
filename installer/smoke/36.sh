#!/usr/bin/env bash
# smoke/36.sh — Phase 36 (AI Town) E2E gate. Proves the install LANDED + the town is
# actually wired to LiteLLM — NOT just that `install 36` exited 0, and NOT just a 200.
#
# What it asserts (the real AI-Town → LiteLLM path):
#   1. the compose stack is up (≥3 running members under project `aitown`)
#   2. the frontend serves HTTP 200 on the loopback alias :5273
#   3. the scoped AITOWN_LITELLM_KEY lists models AND completes 1 token through LiteLLM
#      (model local-gemma4) — the exact chat path the town's characters use
#   4. the Convex backend is WIRED: LLM_API_URL is set to host.docker.internal:4000
#      (via container env OR `convex env get`) — so the town routes, not silent-defaults
#
# agent-call proof: AI Town's character loop is Convex-internal (no REST verb triggers a
# single agent step on demand), so the direct scoped-key chat completion in (3) is the
# faithful proxy for "a character can call the model", and (4) proves the town is pointed
# at that path. A bare frontend-200 is liveness, not proof.
#
# Run: bash installer/smoke/36.sh
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/network.sh"
aliases_load

AT_DIR="$AI_STACK/ai-town"
AT_PROJECT="aitown"
AT_IP="${ALIAS_IP[aitown]:-127.0.10.19}"
AT_FE_PORT="${ALIAS_HOST_PORT[aitown]:-5273}"
AT_BE_PORT="3210"
# Host→backend admin URL: the override publishes Convex on the loopback ALIAS $AT_IP, NOT
# 127.0.0.1, so the host-side `npx convex env get` must dial $AT_IP:$AT_BE_PORT (else
# "TypeError: fetch failed"). Mirrors the phase's AT_CONVEX_URL.
AT_CONVEX_URL="http://${AT_IP}:${AT_BE_PORT}"
AT_CONVEX_LLM_URL="http://host.docker.internal:4000"
AT_MODEL_DEFAULT="local-gemma4"

hdr "Smoke 36 — AI Town (Convex compose stack → LiteLLM)"

# 0. installed?
[[ -f "$AT_DIR/docker-compose.yml" && -f "$AT_DIR/docker-compose.override.yml" ]] \
  || { err "AI Town not installed (missing $AT_DIR/docker-compose*.yml) — run: vz-ai-stack.sh install 36"; exit 1; }
docker info >/dev/null 2>&1 || { err "docker daemon not reachable"; exit 1; }

# 1. compose stack up (≥3 running)
_running="$( (cd "$AT_DIR" && docker compose -p "$AT_PROJECT" ps --status running -q 2>/dev/null | grep -c .) || true)"
[[ "${_running:-0}" -ge 3 ]] && ok "compose stack up ($_running/3 members running, project $AT_PROJECT)" \
  || { err "compose stack not fully up (only ${_running:-0}/3) — 'vz-ai-stack.sh start aitown'"; exit 1; }

# 2. frontend serves 200 (loopback alias)
code="$(curl -sL -o /dev/null -w '%{http_code}' --max-time 8 "http://$AT_IP:$AT_FE_PORT/" 2>/dev/null || true)"
[[ "$code" == "200" ]] && ok "frontend serves HTTP 200 on http://$AT_IP:$AT_FE_PORT/ (alias http://aitown:$AT_FE_PORT/)" \
  || { err "frontend not serving 200 on :$AT_FE_PORT (got $code) — Vite may still be building; 'docker compose -p $AT_PROJECT logs frontend'"; exit 1; }

# 3. scoped key lists models + completes 1 token (the real character → LiteLLM path)
KEY="$(get_env AITOWN_LITELLM_KEY '')"
[[ -n "$KEY" ]] || { err "AITOWN_LITELLM_KEY absent from .env"; exit 1; }
printf '%s' "$(curl -s --max-time 5 -H "Authorization: Bearer $KEY" http://127.0.0.1:4000/v1/models 2>/dev/null)" | grep -q '"id"' \
  && ok "scoped key lists models via LiteLLM" \
  || { err "AITOWN_LITELLM_KEY lists no models (stale/rejected) — re-mint: vz-ai-stack.sh install 36"; exit 1; }

# Resolve the bound model (models.yml override → default).
AT_MODEL="$AT_MODEL_DEFAULT"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _am="$(yq -r '.assignments.aitown // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  [[ -n "$_am" && "$_am" != "null" ]] && AT_MODEL="$_am"
fi
chat_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -X POST http://127.0.0.1:4000/v1/chat/completions \
  -d "{\"model\":\"$AT_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":4}" 2>/dev/null || echo 000)"
[[ "$chat_code" == "200" ]] && ok "scoped key completes a chat through LiteLLM ($AT_MODEL, HTTP 200) — the town's character path works" \
  || { err "scoped-key chat completion returned HTTP $chat_code ($AT_MODEL via LiteLLM) — the character path is broken"; exit 1; }

# 4. the backend is actually WIRED. The AUTHORITATIVE check is `convex env get` — Convex
# vars set via `convex env set` live in the backend's internal KV DB and are NOT surfaced
# as container OS env, so `printenv` inside the container is (almost) always empty for our
# custom LLM_* vars. The container-env check below is therefore a belt-and-suspenders
# first try; the `convex env get` path is MANDATORY and must PROVE the wiring — a smoke
# that can exit 0 without proving step 4 is not a gate. Missing AITOWN_ADMIN_KEY or npx is
# a FAIL (the wiring is unprovable, not "probably fine").
_be_env="$( (cd "$AT_DIR" && docker compose -p "$AT_PROJECT" exec -T backend printenv LLM_API_URL 2>/dev/null) | tr -d '\r' )"
if [[ "$_be_env" == "$AT_CONVEX_LLM_URL" ]]; then
  ok "backend container env LLM_API_URL=$AT_CONVEX_LLM_URL (town is wired to LiteLLM)"
else
  _admin="$(get_env AITOWN_ADMIN_KEY '')"
  [[ -n "$_admin" ]] || { err "AITOWN_ADMIN_KEY absent from .env — cannot run the authoritative 'convex env get' wiring check. Re-run 'install 36' (step 7 mints + persists it)."; exit 1; }
  command -v npx >/dev/null 2>&1 || { err "npx not on PATH — cannot run 'convex env get' to PROVE the town is wired. node@22 is a core dep: 'vz-ai-stack.sh deps'."; exit 1; }
  _cvx_get="$( (cd "$AT_DIR" && env CONVEX_SELF_HOSTED_URL="$AT_CONVEX_URL" CONVEX_SELF_HOSTED_ADMIN_KEY="$_admin" npx --yes convex env get LLM_API_URL 2>/dev/null) | tr -d '\r' )"
  [[ "$_cvx_get" == "$AT_CONVEX_LLM_URL" ]] \
    && ok "Convex env LLM_API_URL=$AT_CONVEX_LLM_URL (via convex env get) — town is wired" \
    || { err "Convex LLM_API_URL is not '$AT_CONVEX_LLM_URL' (container env empty AND convex env get returned '${_cvx_get:-<none>}') — the town is NOT wired to LiteLLM; re-run 'install 36' step 8"; exit 1; }
fi

ok "Smoke 36 PASS — AI Town stack up, frontend 200, scoped key drives a model through LiteLLM, town wired to host.docker.internal:4000"
note "Watch the town live: http://aitown:$AT_FE_PORT/   ·   trace calls in Phoenix → http://phoenix:6006 (project ai-stack)"
