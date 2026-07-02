#!/usr/bin/env bash
# Phase 37 — Concordia (google-deepmind/concordia, Apache-2.0) — OPT-IN GABM sim.
#
# Concordia is DeepMind's library for Generative Agent-Based Modeling (GABM): LLM-driven
# agents act in a shared world mediated by a GAME MASTER entity (tabletop-RPG-inspired)
# that validates/resolves every action against world-state and conservation rules. It is
# the RESEARCH-EXPERIMENT member of the agent-sim set — controlled social-science scenarios
# (negotiation, governance, elections, economic dilemmas), distinct from OASIS (emergent
# social-media swarm), MetaGPT/ChatDev (software team), AgentScope (DIY framework), AI Town
# (persistent world). Companion paper arXiv:2312.03664.
#
# ARCHETYPE = HOST VENV batch (mirrors Phase 32/33/34):
#   * uv venv pinned to Python 3.12 (gdm-concordia requires 3.12+ — NOTE: the other sims
#     pin 3.11; Concordia is the first 3.12 host-venv sim),
#   * bin/concordia wrapper injects the scoped LiteLLM key at RUNTIME + points Concordia's
#     GptLanguageModel (OpenAI-compatible) at LiteLLM,
#   * NO container/port/hostname. Run sims via: bin/concordia concordia/sims/<file>.py
#
# DEFAULT MODEL = claude-opus-sub-xhigh — the tier all 6 opt-in sims use (NOT the platform
# default: that is claude-opus-sub-max for unassigned agents + the fleet; "no silent local
# models"), same as the other 5 sims.
# The install SMOKE/gate, however, runs claude-sonnet-sub-high (CC_SMOKE_MODEL) for the
# heavy seeded sim: Concordia fires MANY component LLM calls CONCURRENTLY per step
# (entity_agent._parallel_call_ → concurrency.run_tasks) — a 1-step sim is ~26 calls — so
# at opus xhigh-effort the gate would exceed its timeout (~8-13 min). sonnet-sub-high
# proves the wiring fast (~3 min, spike 2026-06-25, llm_calls=26); the user-facing default
# stays the capable opus-xhigh. (The fast reachability curl still pings the real default.)
# local is selectable but TIMES OUT (a single local Ollama model serializes the
# concurrent calls; spike-verified). Routed via LiteLLM scoped key → traced in Phoenix.
#
# Constitution honored: OPT-IN (not in install_all_phase_order); scoped key
# (CONCORDIA_LITELLM_KEY), never master. Reversible: rm -rf concordia/.venv + unstamp;
# concordia/sims is DATA.
#
# SCALE REALITY: GABM is LLM-call-heavy (Game Master + every entity + every component,
# concurrently per step). On the M4/24GB box realistic sims are a handful of entities for
# a few steps; a 2-entity/2-step sim is ~6 min on a cloud-sub model. Stated in services.yml.
#
# Standalone: bash vz-ai-stack.sh install 37   (alias: concordia)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/worktree.sh"

PHASE=37
CC_DIR="$AI_STACK/concordia"
CC_VENV="$CC_DIR/.venv"
CC_PY="$CC_VENV/bin/python"
CC_WRAPPER="$AI_STACK/bin/concordia"
CC_SIMS="$CC_DIR/sims"
CC_MODEL_DEFAULT="claude-opus-sub-xhigh"          # platform default (models.yml) — what bin/concordia uses
CC_SMOKE_MODEL="claude-sonnet-sub-high"           # FAST model for the install gate's seeded sim only (opus-xhigh × ~26 calls/step would blow the timeout)
CC_EMBEDDER_DEFAULT="sentence-transformers/all-MiniLM-L6-v2"
# Host-venv tools route to 127.0.0.1:4000 (always reachable from the host shell); the
# container DNS name litellm:4000 also works once core Phase 00n writes /etc/hosts, so
# install-time probes try litellm first then fall back (resolve-once, below).
CC_LLM_HOST="http://litellm:4000"
CC_LLM_FALLBACK="http://127.0.0.1:4000"

precheck() {
  [[ -x "$CC_PY" ]] || return 1
  [[ -x "$CC_WRAPPER" ]] || return 1
  "$CC_PY" -c "import concordia" >/dev/null 2>&1 || return 1
  "$CC_PY" -c "import openai" >/dev/null 2>&1 || return 1
  "$CC_PY" -c "import sentence_transformers" >/dev/null 2>&1 || return 1
  local key; key="$(get_env CONCORDIA_LITELLM_KEY '')"
  [[ -n "$key" ]] || return 1
  litellm_scoped_curl "$key" -sf --max-time 5 "$CC_LLM_HOST/v1/models" >/dev/null 2>&1 \
    || litellm_scoped_curl "$key" -sf --max-time 5 "$CC_LLM_FALLBACK/v1/models" >/dev/null 2>&1 \
    || return 1
  # allow-list drift gate: fail precheck when the scoped key no longer covers the bound model +
  # mint fallbacks, so re-install re-reconciles via /key/update (control-plane). See phase 32.
  local _bm="$CC_MODEL_DEFAULT"
  if command -v yq >/dev/null 2>&1 && [[ -f "$AI_STACK/installer/models.yml" ]]; then
    local _a; _a="$(yq -r '.assignments.concordia // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
    [[ -n "$_a" && "$_a" != "null" ]] && _bm="$_a"
  fi
  litellm_key_covers CONCORDIA_LITELLM_KEY "$_bm" claude-sonnet-sub-high claude-opus-sub-xhigh local || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 37 — Concordia — already installed (precheck passed + stamped; nothing to do)"
  exit 0
fi

worktree_guard "install concordia"

hdr "Phase 37 — Concordia (DeepMind generative agent-based modeling / GABM)"

# --- Preconditions ---
command -v uv >/dev/null 2>&1 || { err "uv not on PATH (Phase 14 installs it): bash $AI_STACK/vz-ai-stack.sh install 14"; exit 1; }
[[ -f "$AI_STACK/.env" ]] || { err ".env missing — run Phase 00 first."; exit 1; }
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY '')"
[[ -n "$LITELLM_MASTER_KEY" ]] || { err "LITELLM_MASTER_KEY missing — Phase 01 must run first."; exit 1; }
# Resolve the LiteLLM base URL ONCE (prefer container alias, fall back to 127.0.0.1 which
# always resolves from the host shell). Mirrors the OASIS §24 fix (removes the /etc/hosts
# ordering dependency).
CC_LLM_BASE=""
if   curl -sf --max-time 4 "$CC_LLM_HOST/health/liveliness" >/dev/null 2>&1; then CC_LLM_BASE="$CC_LLM_HOST"
elif curl -sf --max-time 4 "$CC_LLM_FALLBACK/health/liveliness" >/dev/null 2>&1; then CC_LLM_BASE="$CC_LLM_FALLBACK"
elif litellm_master_curl -sf --max-time 4 "$CC_LLM_FALLBACK/v1/models" >/dev/null 2>&1; then CC_LLM_BASE="$CC_LLM_FALLBACK"
fi
[[ -n "$CC_LLM_BASE" ]] || { err "LiteLLM not reachable at $CC_LLM_HOST or $CC_LLM_FALLBACK — run 'vz-ai-stack.sh start litellm' (from MAIN)."; exit 1; }
ok "LiteLLM reachable at $CC_LLM_BASE"

# --- 1. Venv (Python 3.12) + install gdm-concordia + sentence-transformers ---
mkdir -p "$CC_SIMS"
if [[ ! -x "$CC_PY" ]]; then
  log "Creating concordia venv (uv, Python 3.12)…"
  uv venv --python 3.12 "$CC_VENV" 2>&1 | tail -3 || { err "uv venv failed (uv fetches CPython 3.12 on first use — check network)"; exit 1; }
fi
# Pin gdm-concordia to the version this phase's seeded sim + smoke were verified against
# (the v1->v2 restructure churned the API; an unpinned upgrade could break the prefab keys).
# NEITHER openai NOR sentence-transformers is a HARD gdm-concordia dependency, but both are
# REQUIRED at runtime: the contrib OpenAI-compatible wrapper (GptLanguageModel) imports
# `openai`, and Concordia's associative memory needs a sentence_embedder. Install both
# explicitly (sentence-transformers pulls torch; verified clean arm64). The missing `openai`
# is the bug the from-main live-verify caught — a fresh venv has no openai → smoke IMPORT_FAIL.
log "Installing gdm-concordia==2.4.0 + openai + sentence-transformers into the venv (a few minutes; pulls torch)…"
uv pip install --python "$CC_PY" "gdm-concordia==2.4.0" "openai>=1.3.0" "sentence-transformers>=2.0.0" 2>&1 | tail -8 \
  || { err "uv pip install gdm-concordia/openai/sentence-transformers failed"; exit 1; }
"$CC_PY" -c "import concordia" 2>/dev/null || { err "import concordia failed (dependency/arch problem) — see install log above"; exit 1; }
"$CC_PY" -c "import openai" 2>/dev/null || { err "import openai failed — the contrib GptLanguageModel wrapper needs it (not a hard gdm-concordia dep)"; exit 1; }
"$CC_PY" -c "import sentence_transformers" 2>/dev/null || { err "import sentence_transformers failed — embedder unavailable"; exit 1; }
# arm64 sanity — a silent amd64/Rosetta venv is slow + may break; assert native arm64 BEFORE
# stamping (hard fail, mirrors OASIS §1.8).
_arch="$("$CC_PY" -c 'import platform;print(platform.machine())' 2>/dev/null || echo '?')"
if [[ "$_arch" == "arm64" ]]; then
  ok "gdm-concordia + sentence-transformers installed (venv python $_arch)"
elif [[ "$_arch" == "?" ]]; then
  warn "could not detect the concordia venv python arch — continuing (verify it is native arm64)"
else
  err "concordia venv python is '$_arch', not arm64 — refusing to stamp an emulated install. Rebuild: rm -rf '$CC_VENV' && uv python install 3.12"; exit 1
fi

# --- 1b. Pre-fetch the embedder model so the smoke (and first run) is not the first download ---
CC_EMBEDDER="$CC_EMBEDDER_DEFAULT"
[[ -n "${CONCORDIA_EMBEDDER:-}" ]] && CC_EMBEDDER="$CONCORDIA_EMBEDDER"
log "Pre-fetching the sentence-transformers embedder ($CC_EMBEDDER; ~90MB first time)…"
"$CC_PY" - "$CC_EMBEDDER" <<'PYWARM' 2>&1 | tail -2 || warn "embedder pre-fetch failed (the smoke will download it on first run)"
import sys
from sentence_transformers import SentenceTransformer
SentenceTransformer(sys.argv[1])
print("embedder cached")
PYWARM

# --- 2. Mint scoped LiteLLM key (stale-aware; mirrors Phase 34) ---
CC_KEY_CURRENT="$(get_env CONCORDIA_LITELLM_KEY '')"
_cc_models=""
[[ -n "$CC_KEY_CURRENT" ]] && _cc_models="$(litellm_scoped_curl "$CC_KEY_CURRENT" -s --max-time 5 "$CC_LLM_BASE/v1/models" 2>/dev/null)"
if [[ -z "$CC_KEY_CURRENT" ]] || ! printf '%s' "$_cc_models" | grep -q '"id"'; then
  log "Minting scoped LiteLLM key for Concordia (sonnet-sub default + opus-sub + local)…"
  CC_KEY_NEW="$(litellm_master_curl -s --max-time 15 \
    -H 'Content-Type: application/json' -X POST "$CC_LLM_BASE/key/generate" \
    -d '{"models":["claude-sonnet-sub-high","claude-opus-sub-xhigh","local"],"key_alias":"concordia","metadata":{"owner":"concordia","purpose":"phase37"}}' \
    | "$CC_PY" -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$CC_KEY_NEW" ]] || { err "Failed to mint CONCORDIA_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"; exit 1; }
  set_env CONCORDIA_LITELLM_KEY "$CC_KEY_NEW"
  ok "CONCORDIA_LITELLM_KEY minted + saved to .env (mode 0600)"
else
  ok "CONCORDIA_LITELLM_KEY already present + valid"
fi

# --- 3. Resolve bound model (default claude-opus-sub-xhigh, the platform default; the heavy smoke runs CC_SMOKE_MODEL — see header) ---
CC_MODEL="$CC_MODEL_DEFAULT"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _cm="$(yq -r '.assignments.concordia // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  [[ -n "$_cm" && "$_cm" != "null" ]] && CC_MODEL="$_cm"
fi
ok "Concordia model = $CC_MODEL (routed via LiteLLM → Phoenix project ai-stack)"
# Self-heal the key's allow-list against the model the app ACTUALLY calls plus fallbacks
# (a rename/re-assign otherwise leaves a stale key silent-403ing the bound model).
litellm_reconcile_key CONCORDIA_LITELLM_KEY "$CC_MODEL" claude-sonnet-sub-high claude-opus-sub-xhigh local

# --- 4. bin/concordia wrapper (injects key from .env at RUNTIME) ---
cat > "$CC_WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
# bin/concordia — stack wrapper around the concordia venv (Phase 37). Regenerate: install 37.
# Runs a sim script in the venv with the scoped LiteLLM key + OpenAI-compat env, so Concordia's
# GptLanguageModel(api_base=…) routes through LiteLLM. Default model ($CC_MODEL) + embedder
# ($CC_EMBEDDER) are baked at install time; override at runtime with CONCORDIA_MODEL / CONCORDIA_EMBEDDER.
# Usage: bin/concordia concordia/sims/smoke_sim.py
set -Eeuo pipefail
AI_STACK="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
_cc_get_env() { grep -E "^\$1=" "\$AI_STACK/.env" 2>/dev/null | tail -1 | cut -d= -f2-; }
PY="\$AI_STACK/concordia/.venv/bin/python"
[[ -x "\$PY" ]] || { echo "concordia venv missing — run 'bash vz-ai-stack.sh install 37'" >&2; exit 1; }
_key="\$(_cc_get_env CONCORDIA_LITELLM_KEY)"
[[ -n "\$_key" ]] || { echo "CONCORDIA_LITELLM_KEY absent from .env — run 'bash vz-ai-stack.sh install 37'" >&2; exit 1; }
export CONCORDIA_LITELLM_KEY="\$_key"
export OPENAI_API_KEY="\$_key"
export OPENAI_BASE_URL="http://127.0.0.1:4000/v1"
export CONCORDIA_MODEL="\${CONCORDIA_MODEL:-$CC_MODEL}"
export CONCORDIA_EMBEDDER="\${CONCORDIA_EMBEDDER:-$CC_EMBEDDER}"
cd "\$AI_STACK"
exec "\$PY" "\$@"
WRAPEOF
chmod +x "$CC_WRAPPER"
ok "wrote $CC_WRAPPER"

# --- 5. Seed a tiny Concordia GABM sim (the routing proof; smoke runs it) ---
# Verified against gdm-concordia 2.4.0 (2026-06-25): prefab registry via
# helper_functions.get_package_classes; keys basic__Entity / generic__GameMaster;
# Simulation(config, model, embedder).play(max_steps=). The model is a _CountingModel
# subclass so we can PROVE real LLM calls happened (the GABM analog of OASIS's reply count).
cat > "$CC_SIMS/smoke_sim.py" <<'PY'
"""Concordia smoke: prove gdm-concordia is installed AND a GABM sim (2 entities + a Game
Master + sequential engine) runs end-to-end with real LLM calls routed through LiteLLM,
plus the sentence-transformers embedder. Reads OPENAI_BASE_URL / OPENAI_API_KEY /
CONCORDIA_MODEL / CONCORDIA_EMBEDDER from env (injected by bin/concordia). Prints
'CONCORDIA_SMOKE_OK entities=2 steps=1 llm_calls=N' and exits 0 only when the sim drove
>=1 real LLM call.

Exit codes: 0=ok (sim ran + >=1 LLM call); 3=routing/auth/timeout fail or 0 calls
(placeholder/401 key, empty output, or a single local model serializing Concordia's
CONCURRENT per-step calls until they time out); 4=import drift; 5=model/embedder/sim
construction drift; 6=sim runtime drift; 7=wall-clock alarm.

DEFAULT MODEL (bin/concordia) = claude-opus-sub-xhigh (platform default); this seeded
smoke is invoked with the faster claude-sonnet-sub-high because Concordia fires ~26
concurrent calls/step and opus xhigh-effort would blow the gate timeout. local
serializes the concurrent calls → times out (spike-verified 2026-06-25)."""
import os, sys, signal

def _alarm(signum, frame):
    sys.stderr.write("CONCORDIA_SMOKE_TIMEOUT: exceeded wall-clock alarm\n")
    sys.stderr.flush()
    os._exit(7)
signal.signal(signal.SIGALRM, _alarm)
signal.alarm(int(os.environ.get("CONCORDIA_SMOKE_ALARM", "420")))

try:
    import numpy as np
    import concordia  # noqa: F401  — prove the package under test imports
    from concordia.contrib.language_models.openai.gpt_model import GptLanguageModel
    from concordia.utils import helper_functions
    from concordia.typing import prefab as prefab_lib
    import concordia.prefabs.entity as entity_prefabs
    import concordia.prefabs.game_master as gm_prefabs
    from concordia.prefabs.simulation import generic as simulation
    from sentence_transformers import SentenceTransformer
except Exception as e:  # import/API drift — NOT an auth problem
    print(f"CONCORDIA_SMOKE_IMPORT_FAIL: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(4)

BASE  = os.environ.get("OPENAI_BASE_URL", "http://127.0.0.1:4000/v1")
KEY   = os.environ.get("OPENAI_API_KEY", "")
MODEL = os.environ.get("CONCORDIA_MODEL", "claude-opus-sub-xhigh")
EMB   = os.environ.get("CONCORDIA_EMBEDDER", "sentence-transformers/all-MiniLM-L6-v2")


class _CountingModel(GptLanguageModel):
    """Counts every real LLM call the sim drives (routing + machinery proof)."""
    calls = 0

    def _sample_text(self, *a, **k):  # the single path both sample_text + sample_choice use
        type(self).calls += 1
        return super()._sample_text(*a, **k)


try:
    model = _CountingModel(model_name=MODEL, api_key=KEY, api_base=BASE)
    _st = SentenceTransformer(EMB)

    def embedder(text: str) -> "np.ndarray":
        return np.asarray(_st.encode(text), dtype=np.float32)

    prefabs = {
        **helper_functions.get_package_classes(entity_prefabs),
        **helper_functions.get_package_classes(gm_prefabs),
    }
    instances = [
        prefab_lib.InstanceConfig(prefab="basic__Entity", role=prefab_lib.Role.ENTITY,
                                  params={"name": "Alice", "goal": "make a new friend in the village"}),
        prefab_lib.InstanceConfig(prefab="basic__Entity", role=prefab_lib.Role.ENTITY,
                                  params={"name": "Bob", "goal": "find someone to explore the market with"}),
        prefab_lib.InstanceConfig(prefab="generic__GameMaster", role=prefab_lib.Role.GAME_MASTER,
                                  params={"name": "rules"}),
    ]
    config = prefab_lib.Config(
        prefabs=prefabs, instances=instances,
        default_premise="Alice and Bob meet in the village square on a sunny afternoon.",
        default_max_steps=1,
    )
    sim = simulation.Simulation(config=config, model=model, embedder=embedder)
except Exception as e:  # construction rejected = Concordia API drift, not a key problem
    print(f"CONCORDIA_SMOKE_BUILD_FAIL: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(5)

try:
    sim.play(max_steps=1)
except Exception as e:  # an auth/routing/timeout failure surfaces as an OpenAI/httpx error
    name = type(e).__name__
    routing = ("APITimeout", "APIConnection", "Authentication", "ReadTimeout",
               "ConnectTimeout", "RateLimit", "APIStatus", "PermissionDenied", "NotFound")
    if any(s in name for s in routing):
        print(f"CONCORDIA_SMOKE_ROUTING_FAIL: {name}: {str(e)[:160]}", file=sys.stderr)
        sys.exit(3)
    print(f"CONCORDIA_SMOKE_RUNTIME_FAIL: {name}: {str(e)[:200]}", file=sys.stderr)
    sys.exit(6)

print(f"CONCORDIA_SMOKE_OK entities=2 steps=1 llm_calls={_CountingModel.calls}")
sys.exit(0 if _CountingModel.calls > 0 else 3)
PY
ok "seeded $CC_SIMS/smoke_sim.py"

# --- 6. sims = DATA; .venv is regenerable (concordia/ tree itself git-ignored at repo root) ---
[[ -f "$CC_SIMS/.gitkeep" ]] || : > "$CC_SIMS/.gitkeep"
cat > "$CC_DIR/.gitignore" <<'GI'
# Concordia venv is regenerable (uv); concordia/sims is DATA (your sim scripts + output) — keep it.
.venv/
GI

# --- 7. Smoke gate: prove the REAL GABM path BEFORE stamping. Fast scoped-key curl first
# (clear error if the KEY is the problem), then the seeded 1-step sim (bounded by its alarm). ---
# On `upgrade all` (AI_STACK_UPGRADE=1, exported by up_phase_rerun) SKIP the live
# scoped-key + GABM sim smoke below: it drives real/metered model calls (the sim
# fans out ~26 calls/step on claude-sonnet-sub-high), and a routine upgrade must
# NOT do unsolicited inference (mechanism-audit #2 + the operator's no-unsolicited-
# inference stance). The venv, scoped key, wrapper and seeded sim are already
# re-asserted above; stamp and move on. The full verified smoke still runs on the
# install path (and via `vz-ai-stack.sh test 37`).
if [[ "${AI_STACK_UPGRADE:-0}" == 1 ]]; then
  note "upgrade re-assert: skipping the live Concordia GABM smoke (no unsolicited metered inference on 'upgrade'). Run 'vz-ai-stack.sh install 37' for the full verified smoke."
else
log "Smoke: scoped key → LiteLLM chat completion…"
_cc_key="$(get_env CONCORDIA_LITELLM_KEY '')"
_sc="$(litellm_scoped_curl "$_cc_key" -s -o /dev/null -w '%{http_code}' --max-time 30 \
  -H 'Content-Type: application/json' \
  -X POST "$CC_LLM_BASE/v1/chat/completions" \
  -d "{\"model\":\"$CC_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":8}" 2>/dev/null || echo 000)"
[[ "$_sc" == "200" ]] || { err "scoped key chat completion returned HTTP $_sc (model $CC_MODEL via LiteLLM) — not stamping"; exit 1; }
ok "scoped key reaches $CC_MODEL through LiteLLM (HTTP 200)"

log "Smoke: real Concordia GABM sim via the seeded sim on $CC_SMOKE_MODEL (verifies the wiring before stamping; ~2-4 min — the fast gate model, not the opus-xhigh default)…"
_simout="$(OPENAI_BASE_URL="$CC_LLM_FALLBACK/v1" OPENAI_API_KEY="$_cc_key" CONCORDIA_MODEL="$CC_SMOKE_MODEL" CONCORDIA_EMBEDDER="$CC_EMBEDDER" "$CC_PY" "$CC_SIMS/smoke_sim.py" 2>&1)" && _simrc=0 || _simrc=$?
printf '%s\n' "$_simout" | grep -vE '^(Loading weights|Warning: You are sending)' | sed 's/^/    /'
[[ $_simrc -eq 0 ]] || { err "the seeded Concordia sim did not pass (rc=$_simrc) — GABM wiring unverified, not stamping (3=routing/timeout, 4=import, 5=build, 6=runtime, 7=alarm)"; exit 1; }
ok "Concordia GABM sim ran through LiteLLM on the scoped key — wiring verified"
fi

stamp_mark "$PHASE"
record "phase 37 complete: Concordia venv (py3.12) + sentence-transformers + scoped key + bin/concordia + GABM-verified smoke sim"
ok "Phase 37 — Concordia — complete"
note "Prove the sim:    vz-ai-stack.sh test 37     # a 1-step GABM sim runs via LiteLLM"
note "Run the demo:     bin/concordia concordia/sims/smoke_sim.py"
note "Watch it:         Phoenix → http://phoenix:6006 (project ai-stack)"
note "Write your own:   concordia/sims/<your_sim>.py  then  bin/concordia concordia/sims/<your_sim>.py"
note "Model note:       default $CC_MODEL (platform default); the install gate runs $CC_SMOKE_MODEL (faster). local TIMES OUT — Concordia fans out concurrent calls; Ollama serializes"
note "Reversible:       rm -rf $CC_VENV && rm -f $AI_STACK/installer/state/phase_37.done"
