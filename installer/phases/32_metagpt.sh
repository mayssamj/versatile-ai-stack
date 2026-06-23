#!/usr/bin/env bash
# Phase 32 — MetaGPT (FoundationAgents/MetaGPT, MIT) — OPT-IN agent-swarm sim.
#
# A multi-agent "software company" role-play: one natural-language brief →
# a swarm of role agents (PM → architect → engineer → QA) collaborate to
# produce design docs, code, and tests. This is the easy on-ramp of the
# agent-swarm-simulation set (doc/specs/2026-06-23-agent-sim-platforms-install-plan.md).
#
# ARCHETYPE = HOST VENV batch (mirrors Phase 06 docs_ingestor / Phase 26 mempalace):
#   * uv venv pinned to Python 3.11 (host python3 is 3.14 — too new for MetaGPT),
#   * a bin/metagpt wrapper that injects the scoped LiteLLM key from .env at
#     RUNTIME (never baked into a repo file) and writes ~/.metagpt/config2.yaml,
#   * NO container, NO port, NO hostname. Invoke via bin/metagpt "<brief>".
#
# Constitution honored:
#   * OPT-IN: not in install_all_phase_order() — install by name/id.
#   * Scoped LiteLLM key (METAGPT_LITELLM_KEY), never the master; default model
#     local-gemma4 (+ *-sub fallbacks). Calls show up in Phoenix (ai-stack) for free.
#   * Reversible: rm -rf metagpt/.venv + unstamp; workspace (sim output) is DATA.
#
# Standalone: bash vz-ai-stack.sh install 32   (alias: metagpt)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/worktree.sh"

PHASE=32
MG_DIR="$AI_STACK/metagpt"
MG_VENV="$MG_DIR/.venv"
MG_PY="$MG_VENV/bin/python"
MG_BIN="$MG_VENV/bin/metagpt"
MG_WRAPPER="$AI_STACK/bin/metagpt"
MG_WORKSPACE="$MG_DIR/workspace"
# Default LLM (entity work routes through LiteLLM). Overridable via models.yml
# .assignments.metagpt; otherwise local-gemma4 (cheapest, on-box).
MG_MODEL_DEFAULT="local-gemma4"

precheck() {
  [[ -x "$MG_PY" && -x "$MG_BIN" ]] || return 1
  [[ -x "$MG_WRAPPER" ]] || return 1
  "$MG_PY" -c "import metagpt" >/dev/null 2>&1 || return 1
  local key; key="$(get_env METAGPT_LITELLM_KEY '')"
  [[ -n "$key" ]] || return 1
  curl -sf --max-time 5 -H "Authorization: Bearer $key" \
    http://litellm:4000/v1/models >/dev/null 2>&1 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 32 — MetaGPT — already installed (use 'vz-ai-stack.sh install 32' to re-run)"
  exit 0
fi

# Refuse to install from a linked worktree: the venv + workspace would bind to a
# path that vanishes on 'git worktree remove' (run the live stack from MAIN only).
worktree_guard "install metagpt"

hdr "Phase 32 — MetaGPT (multi-agent software-company simulation)"

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

# --- 1. Venv (Python 3.11 — host 3.14 is too new for MetaGPT) + install ---
mkdir -p "$MG_WORKSPACE"
if [[ ! -x "$MG_PY" ]]; then
  log "Creating metagpt venv (uv, Python 3.11)…"
  uv venv --python 3.11 "$MG_VENV" 2>&1 | tail -3 || { err "uv venv failed (uv fetches CPython 3.11 on first use — check network)"; exit 1; }
fi
log "Installing metagpt into the venv (a few minutes; pulls a large dep tree)…"
uv pip install --python "$MG_PY" --upgrade metagpt 2>&1 | tail -6 || { err "uv pip install metagpt failed"; exit 1; }
[[ -x "$MG_BIN" ]] || { err "metagpt console script missing at $MG_BIN after install"; exit 1; }
"$MG_PY" -c "import metagpt" 2>/dev/null || { err "import metagpt failed (dependency/arch problem) — check the install log above"; exit 1; }
# arm64 sanity (a silent amd64 fallback would be slow/broken under Rosetta).
_arch="$("$MG_PY" -c 'import platform;print(platform.machine())' 2>/dev/null || echo '?')"
[[ "$_arch" == "arm64" ]] && ok "metagpt installed (venv python $_arch): $("$MG_BIN" --version 2>/dev/null | head -1 || echo '(version unknown)')" \
  || warn "metagpt venv python reports arch '$_arch' (expected arm64) — may run under emulation; consider rebuilding the venv"

# --- 2. Mint scoped LiteLLM key (stale-aware; mirrors Phase 26) ---
MG_KEY_CURRENT="$(get_env METAGPT_LITELLM_KEY '')"
_mg_models="$(curl -s --max-time 5 -H "Authorization: Bearer $MG_KEY_CURRENT" http://litellm:4000/v1/models 2>/dev/null)"
if [[ -z "$MG_KEY_CURRENT" ]] || ! printf '%s' "$_mg_models" | grep -q '"id"'; then
  log "Minting scoped LiteLLM key for MetaGPT (local-gemma4 + *-sub fallbacks)…"
  MG_KEY_NEW="$(curl -s --max-time 15 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H 'Content-Type: application/json' -X POST http://litellm:4000/key/generate \
    -d '{"models":["local-gemma4","claude-opus-4.8-sub-xhigh","claude-sonnet-4.6-sub-high"],"key_alias":"metagpt","metadata":{"owner":"metagpt","purpose":"phase32"}}' \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$MG_KEY_NEW" ]] || { err "Failed to mint METAGPT_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"; exit 1; }
  set_env METAGPT_LITELLM_KEY "$MG_KEY_NEW"
  ok "METAGPT_LITELLM_KEY minted + saved to .env (mode 0600)"
else
  ok "METAGPT_LITELLM_KEY already present + valid"
fi

# --- 3. Resolve bound model (availability-gated; default local-gemma4) ---
MG_MODEL="$MG_MODEL_DEFAULT"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _mm="$(yq -r '.assignments.metagpt // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  [[ -n "$_mm" && "$_mm" != "null" ]] && MG_MODEL="$_mm"
fi
ok "MetaGPT LLM model = $MG_MODEL (routed via LiteLLM → Phoenix project ai-stack)"

# --- 4. bin/metagpt wrapper (injects key from .env at RUNTIME; writes ~/.metagpt/config2.yaml) ---
# The wrapper writes config2.yaml each run from the .env key (0600, in $HOME — never
# the repo), so the key lives ONLY in .env. Re-running 'install 32' or editing .env
# is picked up automatically. cd into metagpt/ so MetaGPT's ./workspace output lands
# in metagpt/workspace (tracked as DATA via .gitkeep).
cat > "$MG_WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
# bin/metagpt — stack wrapper around the metagpt venv (Phase 32). Regenerate: install 32.
# Injects the scoped LiteLLM key from .env at runtime; writes ~/.metagpt/config2.yaml.
set -Eeuo pipefail
AI_STACK="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
_mg_get_env() { grep -E "^\$1=" "\$AI_STACK/.env" 2>/dev/null | head -1 | cut -d= -f2-; }
PY="\$AI_STACK/metagpt/.venv/bin/metagpt"
[[ -x "\$PY" ]] || { echo "metagpt venv missing — run 'bash vz-ai-stack.sh install 32'" >&2; exit 1; }
_key="\$(_mg_get_env METAGPT_LITELLM_KEY)"
[[ -n "\$_key" ]] || { echo "METAGPT_LITELLM_KEY absent from .env — run 'bash vz-ai-stack.sh install 32'" >&2; exit 1; }
_model="\${METAGPT_MODEL:-$MG_MODEL}"
# config2.yaml: MetaGPT's LLM contract. Written fresh from .env (0600, in \$HOME).
mkdir -p "\$HOME/.metagpt"
umask 077
cat > "\$HOME/.metagpt/config2.yaml" <<CFG
llm:
  api_type: "openai"
  base_url: "http://litellm:4000/v1"
  api_key: "\$_key"
  model: "\$_model"
CFG
chmod 0600 "\$HOME/.metagpt/config2.yaml" 2>/dev/null || true
export OPENAI_BASE_URL="http://litellm:4000/v1" OPENAI_API_KEY="\$_key"
cd "\$AI_STACK/metagpt"   # MetaGPT writes ./workspace here
exec "\$PY" "\$@"
WRAPEOF
chmod +x "$MG_WRAPPER"
ok "wrote $MG_WRAPPER"

# --- 5. Keep the sim workspace as DATA (tracked .gitkeep → cleanup never deletes it; .venv is regenerable) ---
[[ -f "$MG_WORKSPACE/.gitkeep" ]] || : > "$MG_WORKSPACE/.gitkeep"
cat > "$MG_DIR/.gitignore" <<'GI'
# MetaGPT venv is regenerable (uv); the workspace is DATA (sim output) — keep it.
.venv/
GI

# --- 6. Smoke gate: prove the scoped key reaches a model THROUGH LiteLLM (catches a
# dead/placeholder key before stamping). A full `metagpt "<brief>"` run is the e2e step. ---
log "Smoke: scoped key → LiteLLM chat completion…"
_sc="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
  -H "Authorization: Bearer $(get_env METAGPT_LITELLM_KEY '')" -H 'Content-Type: application/json' \
  -X POST http://litellm:4000/v1/chat/completions \
  -d "{\"model\":\"$MG_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":4}" 2>/dev/null || echo 000)"
[[ "$_sc" == "200" ]] || { err "scoped key chat completion returned HTTP $_sc (model $MG_MODEL via LiteLLM) — not stamping"; exit 1; }
ok "scoped key reaches $MG_MODEL through LiteLLM (HTTP 200)"

stamp_mark "$PHASE"
record "phase 32 complete: MetaGPT venv (py3.11) + scoped key + bin/metagpt wrapper"
ok "Phase 32 — MetaGPT — complete"
note "Run a swarm:   bin/metagpt \"create a CLI 2048 game in python\"   # output → metagpt/workspace/"
note "Watch it:      Phoenix → http://phoenix:6006 (project ai-stack) traces every agent's LLM call"
note "Model:         METAGPT_MODEL=claude-opus-4.8-sub-xhigh bin/metagpt \"…\"   # bigger swarm (metered)"
note "Reversible:    rm -rf $MG_VENV && rm -f $AI_STACK/installer/state/phase_32.done"
