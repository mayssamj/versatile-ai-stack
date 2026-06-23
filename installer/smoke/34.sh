#!/usr/bin/env bash
# smoke/34.sh — Phase 34 (OASIS) E2E gate. Proves the REAL swarm path: the seeded
# CAMEL multi-agent sim (oasis/sims/smoke_sim.py) drives agents THROUGH LiteLLM on
# the scoped key — not just "install exited 0" or a bare HTTP 200.
#
# Why agents-replied (not a spend delta) is the gate: the spec's intent is to catch
# the literal-placeholder-key 401 class. A 401/placeholder key makes every CAMEL
# agent fail to get a completion -> the sim reports replies < agents -> we FAIL. That
# is a stronger, directly-verified proof than a LiteLLM spend counter (which bills 0
# for the default local-gemma4, so a spend delta would be unreliable here).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

hdr "Smoke 34 — OASIS (CAMEL multi-agent swarm -> LiteLLM)"

VENV="$AI_STACK/oasis/.venv"
[[ -x "$VENV/bin/python" ]] || { err "oasis venv missing — run: vz-ai-stack.sh install 34"; exit 1; }
"$VENV/bin/python" -c "import oasis" >/dev/null 2>&1 && ok "import oasis OK" \
  || { err "import oasis failed in the venv"; exit 1; }
[[ -x "$AI_STACK/bin/oasis" ]] || { err "bin/oasis wrapper missing — run: vz-ai-stack.sh install 34"; exit 1; }
SIM="$AI_STACK/oasis/sims/smoke_sim.py"
[[ -f "$SIM" ]] || { err "seeded sim missing ($SIM) — re-run: vz-ai-stack.sh install 34"; exit 1; }

KEY="$(get_env OASIS_LITELLM_KEY '')"
[[ -n "$KEY" ]] || { err "OASIS_LITELLM_KEY absent from .env"; exit 1; }
printf '%s' "$(curl -s --max-time 5 -H "Authorization: Bearer $KEY" http://litellm:4000/v1/models 2>/dev/null)" | grep -q '"id"' \
  && ok "scoped key lists models via LiteLLM" || { err "OASIS_LITELLM_KEY lists no models (stale/rejected)"; exit 1; }

log "Running the seeded CAMEL multi-agent sim via bin/oasis (real swarm step; a cold local model can take ~30-60s)…"
out="$("$AI_STACK/bin/oasis" "$SIM" 2>&1)" && rc=0 || rc=$?
printf '%s\n' "$out" | sed 's/^/    /'
printf '%s' "$out" | grep -q 'OASIS_SMOKE_OK' \
  || { err "sim did not print OASIS_SMOKE_OK — agents failed to reply via LiteLLM (placeholder/401 key?) rc=$rc"; exit 1; }

# Require EVERY persona to have replied (replies == agents). A 401 yields replies < agents.
_line="$(printf '%s' "$out" | grep -oE 'agents=[0-9]+ replies=[0-9]+' | tail -1)"
_ag="${_line#agents=}"; _ag="${_ag%% *}"
_rp="${_line##*replies=}"
[[ -n "$_ag" && "$_rp" == "$_ag" ]] \
  || { err "only ${_rp:-?}/${_ag:-?} agents replied through LiteLLM — routing is broken"; exit 1; }
ok "all $_ag CAMEL agents replied through LiteLLM (real swarm step) — traced in Phoenix (http://phoenix:6006)"

ok "Smoke 34 PASS — OASIS CAMEL swarm runs through LiteLLM on the scoped key"
