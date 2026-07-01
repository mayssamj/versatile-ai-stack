#!/usr/bin/env bash
# smoke/33.sh — Phase 33 (AgentScope) E2E gate. Runs the seeded AgentScope 2-agent
# exchange (agentscope/sims/smoke_sim.py) via bin/agentscope and PASSES only when both
# agents replied through LiteLLM on the scoped key.
#
# The sim self-bounds with signal.alarm (macOS has no `timeout`) and uses distinct
# exit codes: 0=both replied, 3=an agent failed (placeholder/401 key, or empty model
# output), 4=agentscope import drift, 5=AgentScope model/agent API drift. agents-replied
# is the routing proof (a placeholder/401 key yields no replies), which is a stronger,
# direct signal than a spend delta (the default local bills $0).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

hdr "Smoke 33 — AgentScope (2-agent exchange -> LiteLLM)"

VENV="$AI_STACK/agentscope/.venv"
[[ -x "$VENV/bin/python" ]] || { err "agentscope venv missing — run: vz-ai-stack.sh install 33"; exit 1; }
"$VENV/bin/python" -c "import agentscope" >/dev/null 2>&1 && ok "import agentscope OK" \
  || { err "import agentscope failed in the venv"; exit 1; }
[[ -x "$AI_STACK/bin/agentscope" ]] || { err "bin/agentscope wrapper missing — run: vz-ai-stack.sh install 33"; exit 1; }
SIM="$AI_STACK/agentscope/sims/smoke_sim.py"
[[ -f "$SIM" ]] || { err "seeded sim missing ($SIM) — re-run: vz-ai-stack.sh install 33"; exit 1; }

KEY="$(get_env AGENTSCOPE_LITELLM_KEY '')"
[[ -n "$KEY" ]] || { err "AGENTSCOPE_LITELLM_KEY absent from .env"; exit 1; }
printf '%s' "$(litellm_scoped_curl "$KEY" -s --max-time 5 http://127.0.0.1:4000/v1/models 2>/dev/null)" | grep -q '"id"' \
  && ok "scoped key lists models via LiteLLM" || { err "AGENTSCOPE_LITELLM_KEY lists no models (stale/rejected)"; exit 1; }

log "Running the seeded AgentScope 2-agent exchange via bin/agentscope (real swarm step; bounded by the sim's 180s alarm)…"
out="$("$AI_STACK/bin/agentscope" "$SIM" 2>&1)" && rc=0 || rc=$?
printf '%s\n' "$out" | sed 's/^/    /'

case "$rc" in
  0) : ;;  # both agents replied — fall through to the sentinel assertion
  4) err "AgentScope import drift (sim exit 4) — agentscope API changed; re-verify agentscope/sims/smoke_sim.py against the installed version"; exit 1 ;;
  5) err "AgentScope model/agent API drift (sim exit 5) — the OpenAICredential/Agent signature changed; fix agentscope/sims/smoke_sim.py"; exit 1 ;;
  *) err "the AgentScope sim did not pass (exit $rc) — an agent failed to reply through LiteLLM (placeholder/401 key, or empty model output?)"; exit 1 ;;
esac

# Belt-and-suspenders: parse the success sentinel and confirm replies == agents.
_line="$(printf '%s' "$out" | grep -oE 'AGENTSCOPE_SMOKE_OK agents=[0-9]+ replies=[0-9]+' | tail -1)"
_ag="${_line##*agents=}"; _ag="${_ag%% *}"
_rp="${_line##*replies=}"
[[ -n "$_ag" && "$_rp" == "$_ag" ]] \
  || { err "sim exited 0 but the sentinel parse is inconsistent (agents=${_ag:-?} replies=${_rp:-?})"; exit 1; }
ok "both AgentScope agents replied through LiteLLM (real 2-agent exchange) — traced in Phoenix (http://phoenix:6006)"

ok "Smoke 33 PASS — AgentScope 2-agent exchange runs through LiteLLM on the scoped key"
