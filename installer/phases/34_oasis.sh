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
# (OASIS_LITELLM_KEY), never master; default model local; calls traced in
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
OA_MODEL_DEFAULT="claude-opus-sub-xhigh"   # platform default; cheap on-box override: OA_MODEL=local
# Host-venv tools route to 127.0.0.1:4000 (always reachable from the host shell);
# the container DNS name litellm:4000 also works once core Phase 00n writes the
# /etc/hosts alias, so install-time probes try litellm first then fall back.
OA_LLM_HOST="http://litellm:4000"
OA_LLM_FALLBACK="http://127.0.0.1:4000"

precheck() {
  [[ -x "$OA_PY" ]] || return 1
  [[ -x "$OA_WRAPPER" ]] || return 1
  "$OA_PY" -c "import oasis" >/dev/null 2>&1 || return 1
  local key; key="$(get_env OASIS_LITELLM_KEY '')"
  [[ -n "$key" ]] || return 1
  litellm_scoped_curl "$key" -sf --max-time 5 "$OA_LLM_HOST/v1/models" >/dev/null 2>&1 \
    || litellm_scoped_curl "$key" -sf --max-time 5 "$OA_LLM_FALLBACK/v1/models" >/dev/null 2>&1 \
    || return 1
  # allow-list drift gate: fail precheck when the scoped key no longer covers the bound model +
  # mint fallbacks, so re-install re-reconciles via /key/update (control-plane). See phase 32.
  local _bm="$OA_MODEL_DEFAULT"
  if command -v yq >/dev/null 2>&1 && [[ -f "$AI_STACK/installer/models.yml" ]]; then
    local _a; _a="$(yq -r '.assignments.oasis // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
    [[ -n "$_a" && "$_a" != "null" ]] && _bm="$_a"
  fi
  litellm_key_covers OASIS_LITELLM_KEY "$_bm" local claude-opus-sub-xhigh claude-sonnet-sub-high || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 34 — OASIS — already installed (precheck passed + stamped; nothing to do)"
  exit 0
fi

worktree_guard "install oasis"

hdr "Phase 34 — OASIS (large-scale social-agent swarm simulation)"

# --- Preconditions ---
command -v uv >/dev/null 2>&1 || { err "uv not on PATH (Phase 14 installs it): bash $AI_STACK/vz-ai-stack.sh install 14"; exit 1; }
[[ -f "$AI_STACK/.env" ]] || { err ".env missing — run Phase 00 first."; exit 1; }
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY '')"
[[ -n "$LITELLM_MASTER_KEY" ]] || { err "LITELLM_MASTER_KEY missing — Phase 01 must run first."; exit 1; }
# Reachability: resolve the LiteLLM base URL ONCE — prefer the container alias
# (litellm:4000, present after core Phase 00n writes /etc/hosts) but fall back to
# 127.0.0.1:4000 (always reachable from the host shell, even before 00n). Reusing the
# RESOLVED base for the mint + smoke calls below removes the /etc/hosts ordering
# dependency the §24 council flagged (2026-06-23) — without it, install 34 before 00n
# would abort on a litellm: NXDOMAIN even though 127.0.0.1:4000 is alive.
OA_LLM_BASE=""
if   curl -sf --max-time 4 "$OA_LLM_HOST/health/liveliness" >/dev/null 2>&1; then OA_LLM_BASE="$OA_LLM_HOST"
elif curl -sf --max-time 4 "$OA_LLM_FALLBACK/health/liveliness" >/dev/null 2>&1; then OA_LLM_BASE="$OA_LLM_FALLBACK"
elif litellm_master_curl -sf --max-time 4 "$OA_LLM_FALLBACK/v1/models" >/dev/null 2>&1; then OA_LLM_BASE="$OA_LLM_FALLBACK"
fi
[[ -n "$OA_LLM_BASE" ]] || { err "LiteLLM not reachable at $OA_LLM_HOST or $OA_LLM_FALLBACK — run 'vz-ai-stack.sh start litellm' (from MAIN)."; exit 1; }
ok "LiteLLM reachable at $OA_LLM_BASE"

# --- 1. Venv (Python 3.11) + install camel-oasis ---
mkdir -p "$OA_SIMS"
if [[ ! -x "$OA_PY" ]]; then
  log "Creating oasis venv (uv, Python 3.11)…"
  uv venv --python 3.11 "$OA_VENV" 2>&1 | tail -3 || { err "uv venv failed (uv fetches CPython 3.11 on first use — check network)"; exit 1; }
fi
log "Installing camel-oasis into the venv (a few minutes; large dep tree)…"
uv pip install --python "$OA_PY" --upgrade camel-oasis 2>&1 | tail -6 || { err "uv pip install camel-oasis failed"; exit 1; }
"$OA_PY" -c "import oasis" 2>/dev/null || { err "import oasis failed (dependency/arch problem) — see install log above"; exit 1; }
# arm64 sanity — a silent amd64/Rosetta venv is slow + may break; the spec (§1.8)
# requires asserting native arm64 BEFORE stamping, so this is a hard fail (not a warn).
_arch="$("$OA_PY" -c 'import platform;print(platform.machine())' 2>/dev/null || echo '?')"
if [[ "$_arch" == "arm64" ]]; then
  ok "camel-oasis installed (venv python $_arch)"
elif [[ "$_arch" == "?" ]]; then
  warn "could not detect the oasis venv python arch — continuing (verify it is native arm64)"
else
  err "oasis venv python is '$_arch', not arm64 — refusing to stamp an emulated install (spec §1.8). Rebuild: rm -rf '$OA_VENV' && uv python install 3.11"; exit 1
fi

# --- 2. Mint scoped LiteLLM key (stale-aware; mirrors Phase 26/32) ---
OA_KEY_CURRENT="$(get_env OASIS_LITELLM_KEY '')"
# Only probe with the existing key when there IS one (an empty 'Bearer ' just logs a
# spurious 401 in LiteLLM's audit trail).
_oa_models=""
[[ -n "$OA_KEY_CURRENT" ]] && _oa_models="$(litellm_scoped_curl "$OA_KEY_CURRENT" -s --max-time 5 "$OA_LLM_BASE/v1/models" 2>/dev/null)"
if [[ -z "$OA_KEY_CURRENT" ]] || ! printf '%s' "$_oa_models" | grep -q '"id"'; then
  log "Minting scoped LiteLLM key for OASIS (local + *-sub fallbacks)…"
  OA_KEY_NEW="$(litellm_master_curl -s --max-time 15 \
    -H 'Content-Type: application/json' -X POST "$OA_LLM_BASE/key/generate" \
    -d '{"models":["local","claude-opus-sub-xhigh","claude-sonnet-sub-high"],"key_alias":"oasis","metadata":{"owner":"oasis","purpose":"phase34"}}' \
    | "$OA_PY" -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$OA_KEY_NEW" ]] || { err "Failed to mint OASIS_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"; exit 1; }
  set_env OASIS_LITELLM_KEY "$OA_KEY_NEW"
  ok "OASIS_LITELLM_KEY minted + saved to .env (mode 0600)"
else
  ok "OASIS_LITELLM_KEY already present + valid"
fi

# --- 3. Resolve bound model (default local) ---
OA_MODEL="$OA_MODEL_DEFAULT"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _om="$(yq -r '.assignments.oasis // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  [[ -n "$_om" && "$_om" != "null" ]] && OA_MODEL="$_om"
fi
ok "OASIS model = $OA_MODEL (routed via LiteLLM → Phoenix project ai-stack)"
# Self-heal the key's allow-list against the model the app ACTUALLY calls ($OA_MODEL,
# which an operator may have re-assigned) PLUS the mint fallbacks. The mint only re-mints
# when the key is fully dead, so a rename/re-assign leaves a stale key SILENT-403ing the
# bound model (`model sync` never touches this key). See litellm_reconcile_key (common.sh).
litellm_reconcile_key OASIS_LITELLM_KEY "$OA_MODEL" local claude-opus-sub-xhigh claude-sonnet-sub-high

# --- 4. bin/oasis wrapper (injects key from .env at RUNTIME) ---
# The wrapper points at 127.0.0.1:4000 — the host-shell route that always resolves
# (the container DNS name litellm:4000 only resolves after Phase 00n writes /etc/hosts).
cat > "$OA_WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
# bin/oasis — stack wrapper around the oasis venv (Phase 34). Regenerate: install 34.
# Runs a sim script in the venv with the scoped LiteLLM key + CAMEL OpenAI-compat env.
# Default model ($OA_MODEL) is baked at install time; override at runtime with OASIS_MODEL.
# Usage: bin/oasis oasis/sims/smoke_sim.py
set -Eeuo pipefail
AI_STACK="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
# last-wins on duplicate .env keys (matches installer/lib/env.sh get_env semantics)
_oa_get_env() { grep -E "^\$1=" "\$AI_STACK/.env" 2>/dev/null | tail -1 | cut -d= -f2-; }
PY="\$AI_STACK/oasis/.venv/bin/python"
[[ -x "\$PY" ]] || { echo "oasis venv missing — run 'bash vz-ai-stack.sh install 34'" >&2; exit 1; }
_key="\$(_oa_get_env OASIS_LITELLM_KEY)"
[[ -n "\$_key" ]] || { echo "OASIS_LITELLM_KEY absent from .env — run 'bash vz-ai-stack.sh install 34'" >&2; exit 1; }
export OASIS_LITELLM_KEY="\$_key"
export OPENAI_API_KEY="\$_key"
export OPENAI_BASE_URL="http://127.0.0.1:4000/v1"
export OASIS_MODEL="\${OASIS_MODEL:-$OA_MODEL}"
cd "\$AI_STACK"
exec "\$PY" "\$@"
WRAPEOF
chmod +x "$OA_WRAPPER"
ok "wrote $OA_WRAPPER"

# --- 5. Seed a tiny CAMEL→LiteLLM multi-agent sim (the routing proof; smoke runs it) ---
# Verified against camel 0.2.78 (2026-06-23): the OpenAI-compatible platform enum is
# OPENAI_COMPATIBLE_MODEL; model_type takes a plain LiteLLM model-id string; create()
# uses url= + api_key=. local is a *reasoning* model — a small max_tokens is
# spent entirely 'thinking' and returns EMPTY content, so max_tokens is 512.
cat > "$OA_SIMS/smoke_sim.py" <<'PY'
"""OASIS smoke: prove camel-oasis is installed AND a CAMEL OpenAI-compatible model
routes through LiteLLM driving a tiny multi-agent swarm. Reads OPENAI_BASE_URL /
OPENAI_API_KEY / OASIS_MODEL from env (injected by bin/oasis). Prints
'OASIS_SMOKE_OK agents=N replies=N' and exits 0 only when EVERY agent replied.

Verified against camel 0.2.78 (2026-06-23). Distinct exit codes let the caller tell
an API drift (4/5) from an auth/routing failure (3): 0=all replied, 3=some agent did
not reply (placeholder/401 key, or empty model output), 4=import drift, 5=ModelFactory
API drift. local reasons before it answers, hence max_tokens=512."""
import os, sys, signal

# Hard wall-clock guard so a hung/queued model can't block `test 34` forever
# (macOS has no `timeout`; signal.alarm is portable + dependency-free).
signal.alarm(180)

try:
    import oasis  # noqa: F401  — prove the package under test imports
    from camel.models import ModelFactory
    from camel.types import ModelPlatformType
    from camel.agents import ChatAgent
except Exception as e:  # import/API drift — NOT an auth problem
    print(f"OASIS_SMOKE_IMPORT_FAIL: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(4)

BASE  = os.environ.get("OPENAI_BASE_URL", "http://127.0.0.1:4000/v1")
KEY   = os.environ.get("OPENAI_API_KEY", "")
MODEL = os.environ.get("OASIS_MODEL", "claude-opus-sub-xhigh")

try:
    model = ModelFactory.create(
        model_platform=ModelPlatformType.OPENAI_COMPATIBLE_MODEL,
        model_type=MODEL, url=BASE, api_key=KEY,
        model_config_dict={"temperature": 0.7, "max_tokens": 512},
    )
except Exception as e:  # construction rejected = CAMEL API drift, not a key problem
    print(f"OASIS_SMOKE_MODEL_FAIL: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(5)

personas = ["an optimist", "a skeptic", "a comedian"]
replies = 0
for p in personas:
    try:
        agent = ChatAgent(system_message=f"You are {p}. Reply in ONE short sentence.", model=model)
        resp = agent.step("What do you think about swarms of AI agents?")
        txt = (resp.msgs[0].content if getattr(resp, "msgs", None) else "").strip()
        if txt:
            replies += 1
        print(f"  [{p}] {txt[:90]}")
    except Exception as e:  # a per-agent call failure (401, network, model)
        print(f"  [{p}] AGENT_FAIL: {type(e).__name__}: {str(e)[:120]}")

print(f"OASIS_SMOKE_OK agents={len(personas)} replies={replies}")
sys.exit(0 if replies == len(personas) else 3)
PY
ok "seeded $OA_SIMS/smoke_sim.py"

# --- 6. Keep sims as DATA; .venv is regenerable (the oasis/ tree itself is git-ignored
# at the repo root so install output is not untracked noise in the main checkout). ---
[[ -f "$OA_SIMS/.gitkeep" ]] || : > "$OA_SIMS/.gitkeep"
cat > "$OA_DIR/.gitignore" <<'GI'
# OASIS venv is regenerable (uv); oasis/sims is DATA (your sim scripts + output) — keep it.
.venv/
GI

# --- 7. Smoke gate: prove the REAL CAMEL swarm path BEFORE stamping, so a broken CAMEL
# wiring fails the INSTALL (not just a later `test 34`). A fast key-reachability curl
# first gives a clear error if the KEY is the problem; then the seeded multi-agent sim
# (bounded by its own signal.alarm). ---
# On `upgrade all` (AI_STACK_UPGRADE=1, exported by up_phase_rerun) SKIP the live
# scoped-key + sim smoke below: it drives real/metered model calls, and a routine
# upgrade must NOT do unsolicited inference (mechanism-audit #2 + the operator's
# no-unsolicited-inference stance). The venv, scoped key, wrapper and seeded sim
# are already re-asserted above; stamp and move on. The full verified smoke still
# runs on the install path (and via `vz-ai-stack.sh test 34`).
if [[ "${AI_STACK_UPGRADE:-0}" == 1 ]]; then
  note "upgrade re-assert: skipping the live OASIS/CAMEL smoke (no unsolicited metered inference on 'upgrade'). Run 'vz-ai-stack.sh install 34' for the full verified smoke."
else
log "Smoke: scoped key → LiteLLM chat completion…"
_oa_key="$(get_env OASIS_LITELLM_KEY '')"
_sc="$(litellm_scoped_curl "$_oa_key" -s -o /dev/null -w '%{http_code}' --max-time 30 \
  -H 'Content-Type: application/json' \
  -X POST "$OA_LLM_BASE/v1/chat/completions" \
  -d "{\"model\":\"$OA_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":4}" 2>/dev/null || echo 000)"
[[ "$_sc" == "200" ]] || { err "scoped key chat completion returned HTTP $_sc (model $OA_MODEL via LiteLLM) — not stamping"; exit 1; }
ok "scoped key reaches $OA_MODEL through LiteLLM (HTTP 200)"

log "Smoke: real CAMEL swarm via the seeded sim (verifies the OASIS wiring before stamping; ~30-60s on a cold model)…"
_simout="$(OPENAI_BASE_URL="$OA_LLM_FALLBACK/v1" OPENAI_API_KEY="$_oa_key" OASIS_MODEL="$OA_MODEL" "$OA_PY" "$OA_SIMS/smoke_sim.py" 2>&1)" && _simrc=0 || _simrc=$?
printf '%s\n' "$_simout" | sed 's/^/    /'
[[ $_simrc -eq 0 ]] || { err "the seeded CAMEL sim did not pass (rc=$_simrc) — OASIS wiring unverified, not stamping"; exit 1; }
ok "CAMEL swarm replied through LiteLLM on the scoped key — OASIS wiring verified"
fi

stamp_mark "$PHASE"
record "phase 34 complete: OASIS venv (py3.11) + scoped key + bin/oasis + CAMEL-verified smoke sim"
ok "Phase 34 — OASIS — complete"
note "Prove the swarm:  vz-ai-stack.sh test 34     # 3 CAMEL agents reply via LiteLLM"
note "Run the demo:     bin/oasis oasis/sims/smoke_sim.py"
note "Watch it:         Phoenix → http://phoenix:6006 (project ai-stack)"
note "Write your own:   oasis/sims/<your_sim>.py  then  bin/oasis oasis/sims/<your_sim>.py"
note "Reversible:       rm -rf $OA_VENV && rm -f $AI_STACK/installer/state/phase_34.done"
