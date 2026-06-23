#!/usr/bin/env bash
# Phase 34 — OASIS (camel-ai/oasis, Apache-2.0) — OPT-IN large-scale agent-swarm sim.
#
# OASIS simulates social-media agent SWARMS (agents post/follow/react/propagate in a
# shared world), scaling upstream to ~1M agents. Built on CAMEL. This is the headline
# tool of the agent-swarm-simulation set (doc/specs/2026-06-23-agent-sim-platforms-install-plan.md).
#
# ARCHETYPE = HOST VENV batch (mirrors Phase 06 / Phase 26 / Phase 32):
#   * uv venv pinned to Python 3.11 (host python3 is 3.14 — too new),
#   * bin/oasis wrapper injects the scoped LiteLLM key from .env at RUNTIME and
#     points CAMEL's OpenAI-compatible model at LiteLLM,
#   * NO container/port/hostname. Run sims via: bin/oasis oasis/sims/<file>.py
#
# Constitution honored: OPT-IN (not in install_all_phase_order); scoped key
# (OASIS_LITELLM_KEY), never master; default model local-gemma4; calls traced in
# Phoenix. Reversible: rm -rf oasis/.venv + unstamp; oasis/sims is DATA.
#
# SCALE REALITY: the 1M-agent figure is upstream — on the M4/24GB box local
# inference serializes, so a realistic on-box swarm is dozens of agents on a small
# model, or route to a cloud model (metered). Stated in services.yml + the tutorial.
#
# Standalone: bash vz-ai-stack.sh install 34   (alias: oasis)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/worktree.sh"

PHASE=34
OA_DIR="$AI_STACK/oasis"
OA_VENV="$OA_DIR/.venv"
OA_PY="$OA_VENV/bin/python"
OA_WRAPPER="$AI_STACK/bin/oasis"
OA_SIMS="$OA_DIR/sims"
OA_MODEL_DEFAULT="local-gemma4"

precheck() {
  [[ -x "$OA_PY" ]] || return 1
  [[ -x "$OA_WRAPPER" ]] || return 1
  "$OA_PY" -c "import oasis" >/dev/null 2>&1 || return 1
  local key; key="$(get_env OASIS_LITELLM_KEY '')"
  [[ -n "$key" ]] || return 1
  curl -sf --max-time 5 -H "Authorization: Bearer $key" \
    http://litellm:4000/v1/models >/dev/null 2>&1 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 34 — OASIS — already installed (use 'vz-ai-stack.sh install 34' to re-run)"
  exit 0
fi

worktree_guard "install oasis"

hdr "Phase 34 — OASIS (large-scale social-agent swarm simulation)"

# --- Preconditions ---
command -v uv >/dev/null 2>&1 || { err "uv not on PATH (Phase 14 installs it): bash $AI_STACK/vz-ai-stack.sh install 14"; exit 1; }
[[ -f "$AI_STACK/.env" ]] || { err ".env missing — run Phase 00 first."; exit 1; }
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY '')"
[[ -n "$LITELLM_MASTER_KEY" ]] || { err "LITELLM_MASTER_KEY missing — Phase 01 must run first."; exit 1; }
if ! curl -sf --max-time 4 http://litellm:4000/health/liveliness >/dev/null 2>&1 \
   && ! curl -sf --max-time 4 -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://litellm:4000/v1/models >/dev/null 2>&1; then
  err "LiteLLM not reachable at http://litellm:4000 — run 'vz-ai-stack.sh start litellm' (from MAIN)."
  exit 1
fi

# --- 1. Venv (Python 3.11) + install camel-oasis ---
mkdir -p "$OA_SIMS"
if [[ ! -x "$OA_PY" ]]; then
  log "Creating oasis venv (uv, Python 3.11)…"
  uv venv --python 3.11 "$OA_VENV" 2>&1 | tail -3 || { err "uv venv failed (uv fetches CPython 3.11 on first use — check network)"; exit 1; }
fi
log "Installing camel-oasis into the venv (a few minutes; large dep tree)…"
uv pip install --python "$OA_PY" --upgrade camel-oasis 2>&1 | tail -6 || { err "uv pip install camel-oasis failed"; exit 1; }
"$OA_PY" -c "import oasis" 2>/dev/null || { err "import oasis failed (dependency/arch problem) — see install log above"; exit 1; }
_arch="$("$OA_PY" -c 'import platform;print(platform.machine())' 2>/dev/null || echo '?')"
[[ "$_arch" == "arm64" ]] && ok "camel-oasis installed (venv python $_arch)" \
  || warn "oasis venv python reports arch '$_arch' (expected arm64) — may run under emulation"

# --- 2. Mint scoped LiteLLM key (stale-aware; mirrors Phase 26/32) ---
OA_KEY_CURRENT="$(get_env OASIS_LITELLM_KEY '')"
_oa_models="$(curl -s --max-time 5 -H "Authorization: Bearer $OA_KEY_CURRENT" http://litellm:4000/v1/models 2>/dev/null)"
if [[ -z "$OA_KEY_CURRENT" ]] || ! printf '%s' "$_oa_models" | grep -q '"id"'; then
  log "Minting scoped LiteLLM key for OASIS (local-gemma4 + *-sub fallbacks)…"
  OA_KEY_NEW="$(curl -s --max-time 15 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H 'Content-Type: application/json' -X POST http://litellm:4000/key/generate \
    -d '{"models":["local-gemma4","claude-opus-4.8-sub-xhigh","claude-sonnet-4.6-sub-high"],"key_alias":"oasis","metadata":{"owner":"oasis","purpose":"phase34"}}' \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$OA_KEY_NEW" ]] || { err "Failed to mint OASIS_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"; exit 1; }
  set_env OASIS_LITELLM_KEY "$OA_KEY_NEW"
  ok "OASIS_LITELLM_KEY minted + saved to .env (mode 0600)"
else
  ok "OASIS_LITELLM_KEY already present + valid"
fi

# --- 3. Resolve bound model (default local-gemma4) ---
OA_MODEL="$OA_MODEL_DEFAULT"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _om="$(yq -r '.assignments.oasis // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  [[ -n "$_om" && "$_om" != "null" ]] && OA_MODEL="$_om"
fi
ok "OASIS model = $OA_MODEL (routed via LiteLLM → Phoenix project ai-stack)"

# --- 4. bin/oasis wrapper (injects key from .env at RUNTIME) ---
cat > "$OA_WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
# bin/oasis — stack wrapper around the oasis venv (Phase 34). Regenerate: install 34.
# Runs a sim script in the venv with the scoped LiteLLM key + CAMEL OpenAI-compat env.
# Usage: bin/oasis oasis/sims/smoke_sim.py
set -Eeuo pipefail
AI_STACK="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
_oa_get_env() { grep -E "^\$1=" "\$AI_STACK/.env" 2>/dev/null | head -1 | cut -d= -f2-; }
PY="\$AI_STACK/oasis/.venv/bin/python"
[[ -x "\$PY" ]] || { echo "oasis venv missing — run 'bash vz-ai-stack.sh install 34'" >&2; exit 1; }
_key="\$(_oa_get_env OASIS_LITELLM_KEY)"
[[ -n "\$_key" ]] || { echo "OASIS_LITELLM_KEY absent from .env — run 'bash vz-ai-stack.sh install 34'" >&2; exit 1; }
export OASIS_LITELLM_KEY="\$_key"
export OPENAI_API_KEY="\$_key"
export OPENAI_BASE_URL="http://litellm:4000/v1"
export OASIS_MODEL="\${OASIS_MODEL:-$OA_MODEL}"
cd "\$AI_STACK"
exec "\$PY" "\$@"
WRAPEOF
chmod +x "$OA_WRAPPER"
ok "wrote $OA_WRAPPER"

# --- 5. Seed a tiny CAMEL→LiteLLM multi-agent sim (the routing proof; smoke runs it) ---
# This proves the load-bearing UNVERIFIED bit: CAMEL's OPENAI_COMPATIBLE model routed
# at LiteLLM actually drives agents. It exits non-zero unless every agent replied, so
# `vz-ai-stack.sh test 34` fails loudly if routing breaks. (A full OASIS social-graph
# sim is yours to write in oasis/sims/ — this is the minimal swarm that proves the wiring.)
cat > "$OA_SIMS/smoke_sim.py" <<'PY'
"""OASIS smoke: prove camel-oasis is installed AND a CAMEL OpenAI-compatible model
routes through LiteLLM driving a tiny multi-agent swarm. Reads OPENAI_BASE_URL /
OPENAI_API_KEY / OASIS_MODEL from env (injected by bin/oasis). Prints OASIS_SMOKE_OK
on success. NOTE: if a CAMEL API name differs in your installed version, fix the few
calls below — this is the one spot the install spec flags as 'verify at impl'."""
import os, sys

import oasis  # noqa: F401  — prove the package under test is importable

from camel.models import ModelFactory
from camel.types import ModelPlatformType
from camel.agents import ChatAgent

BASE  = os.environ.get("OPENAI_BASE_URL", "http://litellm:4000/v1")
KEY   = os.environ.get("OPENAI_API_KEY", "")
MODEL = os.environ.get("OASIS_MODEL", "local-gemma4")

model = ModelFactory.create(
    model_platform=ModelPlatformType.OPENAI_COMPATIBLE,
    model_type=MODEL,
    url=BASE,
    api_key=KEY,
    model_config_dict={"temperature": 0.7, "max_tokens": 40},
)

personas = ["an optimist", "a skeptic", "a comedian"]
replies = 0
for p in personas:
    agent = ChatAgent(system_message=f"You are {p}. Reply in ONE short sentence.", model=model)
    resp = agent.step("What do you think about swarms of AI agents?")
    txt = (resp.msgs[0].content if getattr(resp, "msgs", None) else "").strip()
    if txt:
        replies += 1
    print(f"  [{p}] {txt[:90]}")

print(f"OASIS_SMOKE_OK agents={len(personas)} replies={replies}")
sys.exit(0 if replies == len(personas) else 3)
PY
ok "seeded $OA_SIMS/smoke_sim.py"

# --- 6. Keep sims as DATA; .venv is regenerable ---
[[ -f "$OA_SIMS/.gitkeep" ]] || : > "$OA_SIMS/.gitkeep"
cat > "$OA_DIR/.gitignore" <<'GI'
# OASIS venv is regenerable (uv); oasis/sims is DATA (your sim scripts + output) — keep it.
.venv/
GI

# --- 7. Smoke gate: scoped key → LiteLLM chat completion (robust stamp gate; the CAMEL
# multi-agent proof is `vz-ai-stack.sh test 34`, run during e2e). ---
log "Smoke: scoped key → LiteLLM chat completion…"
_sc="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
  -H "Authorization: Bearer $(get_env OASIS_LITELLM_KEY '')" -H 'Content-Type: application/json' \
  -X POST http://litellm:4000/v1/chat/completions \
  -d "{\"model\":\"$OA_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":4}" 2>/dev/null || echo 000)"
[[ "$_sc" == "200" ]] || { err "scoped key chat completion returned HTTP $_sc (model $OA_MODEL via LiteLLM) — not stamping"; exit 1; }
ok "scoped key reaches $OA_MODEL through LiteLLM (HTTP 200)"

stamp_mark "$PHASE"
record "phase 34 complete: OASIS venv (py3.11) + scoped key + bin/oasis + seeded smoke sim"
ok "Phase 34 — OASIS — complete"
note "Prove the swarm:  vz-ai-stack.sh test 34     # 3 CAMEL agents reply via LiteLLM"
note "Run the demo:     bin/oasis oasis/sims/smoke_sim.py"
note "Watch it:         Phoenix → http://phoenix:6006 (project ai-stack)"
note "Write your own:   oasis/sims/<your_sim>.py  then  bin/oasis oasis/sims/<your_sim>.py"
note "Reversible:       rm -rf $OA_VENV && rm -f $AI_STACK/installer/state/phase_34.done"
