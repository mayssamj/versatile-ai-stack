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
#     local (+ *-sub fallbacks). Calls show up in Phoenix (ai-stack) for free.
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
# .assignments.metagpt or MG_MODEL env; otherwise the platform default
# claude-opus-sub-xhigh. For cheap on-box runs: MG_MODEL=local (key-scoped).
MG_MODEL_DEFAULT="claude-opus-sub-xhigh"
# Host-venv tools route to 127.0.0.1:4000 (always reachable from the host shell);
# the container DNS name litellm:4000 also works once core Phase 00n writes the
# /etc/hosts alias, so install-time probes try litellm first then fall back.
MG_LLM_HOST="http://litellm:4000"
MG_LLM_FALLBACK="http://127.0.0.1:4000"

precheck() {
  [[ -x "$MG_PY" && -x "$MG_BIN" ]] || return 1
  [[ -x "$MG_WRAPPER" ]] || return 1
  "$MG_PY" -c "import metagpt" >/dev/null 2>&1 || return 1
  local key; key="$(get_env METAGPT_LITELLM_KEY '')"
  [[ -n "$key" ]] || return 1
  litellm_scoped_curl "$key" -sf --max-time 5 "$MG_LLM_HOST/v1/models" >/dev/null 2>&1 \
    || litellm_scoped_curl "$key" -sf --max-time 5 "$MG_LLM_FALLBACK/v1/models" >/dev/null 2>&1 \
    || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 32 — MetaGPT — already installed (precheck passed + stamped; nothing to do)"
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
# Reachability: resolve the LiteLLM base URL ONCE — prefer the container alias
# (litellm:4000, present after core Phase 00n writes /etc/hosts) but fall back to
# 127.0.0.1:4000 (always reachable from the host shell, even before 00n). Reusing the
# RESOLVED base for the mint + smoke calls below removes the /etc/hosts ordering
# dependency the §24 council flagged (2026-06-23) — without it, install 32 before 00n
# would abort on a litellm: NXDOMAIN even though 127.0.0.1:4000 is alive.
MG_LLM_BASE=""
if   curl -sf --max-time 4 "$MG_LLM_HOST/health/liveliness" >/dev/null 2>&1; then MG_LLM_BASE="$MG_LLM_HOST"
elif curl -sf --max-time 4 "$MG_LLM_FALLBACK/health/liveliness" >/dev/null 2>&1; then MG_LLM_BASE="$MG_LLM_FALLBACK"
elif litellm_master_curl -sf --max-time 4 "$MG_LLM_FALLBACK/v1/models" >/dev/null 2>&1; then MG_LLM_BASE="$MG_LLM_FALLBACK"
fi
[[ -n "$MG_LLM_BASE" ]] || { err "LiteLLM not reachable at $MG_LLM_HOST or $MG_LLM_FALLBACK — run 'vz-ai-stack.sh start litellm' (from MAIN)."; exit 1; }
ok "LiteLLM reachable at $MG_LLM_BASE"

# --- 1. Venv (Python 3.11 — host 3.14 is too new for MetaGPT) + install ---
mkdir -p "$MG_WORKSPACE"
if [[ ! -x "$MG_PY" ]]; then
  log "Creating metagpt venv (uv, Python 3.11)…"
  uv venv --python 3.11 "$MG_VENV" 2>&1 | tail -3 || { err "uv venv failed (uv fetches CPython 3.11 on first use — check network)"; exit 1; }
fi
log "Installing metagpt into the venv (a few minutes; pulls a large dep tree)…"
# metagpt 0.8.x depends on semantic-kernel==0.4.3.dev0 (a pre-release); without
# --prerelease=allow, uv backtracks to the ancient metagpt v0.1 which pins the
# unbuildable pandas 1.4.1 (Cython compile error on arm64). Pin 0.8.2 for repro.
uv pip install --python "$MG_PY" --prerelease=allow "metagpt==0.8.2" 2>&1 | tail -8 \
  || { err "uv pip install metagpt failed (needs --prerelease=allow for semantic-kernel==0.4.3.dev0)"; exit 1; }
# metagpt 0.8.2 pins typer 0.9.0, whose CLI crashes against click 8.1+ (typer's
# get_command vs click 8.1) — typer >=0.12 restores it (verified: `metagpt --help` → 0).
uv pip install --python "$MG_PY" "typer>=0.12" 2>&1 | tail -3 \
  || { err "failed to upgrade typer (the metagpt CLI needs typer>=0.12 for click 8.1+)"; exit 1; }
[[ -x "$MG_BIN" ]] || { err "metagpt console script missing at $MG_BIN after install"; exit 1; }
"$MG_PY" -c "import metagpt" 2>/dev/null || { err "import metagpt failed (dependency/arch problem) — check the install log above"; exit 1; }
# arm64 sanity — a silent amd64/Rosetta venv is slow + may break; the spec (§1.8)
# requires asserting native arm64 BEFORE stamping, so this is a hard fail (not a warn).
_arch="$("$MG_PY" -c 'import platform;print(platform.machine())' 2>/dev/null || echo '?')"
if [[ "$_arch" == "arm64" ]]; then
  ok "metagpt installed (venv python $_arch): $("$MG_BIN" --version 2>/dev/null | head -1 || echo '(version unknown)')"
elif [[ "$_arch" == "?" ]]; then
  warn "could not detect the metagpt venv python arch — continuing (verify it is native arm64)"
else
  err "metagpt venv python is '$_arch', not arm64 — refusing to stamp an emulated install (spec §1.8). Rebuild: rm -rf '$MG_VENV' && uv python install 3.11"; exit 1
fi

# --- 2. Mint scoped LiteLLM key (stale-aware; mirrors Phase 26) ---
MG_KEY_CURRENT="$(get_env METAGPT_LITELLM_KEY '')"
# Only probe with the existing key when there IS one (an empty 'Bearer ' just logs a
# spurious 401 in LiteLLM's audit trail).
_mg_models=""
[[ -n "$MG_KEY_CURRENT" ]] && _mg_models="$(litellm_scoped_curl "$MG_KEY_CURRENT" -s --max-time 5 "$MG_LLM_BASE/v1/models" 2>/dev/null)"
if [[ -z "$MG_KEY_CURRENT" ]] || ! printf '%s' "$_mg_models" | grep -q '"id"'; then
  log "Minting scoped LiteLLM key for MetaGPT (local + *-sub fallbacks)…"
  MG_KEY_NEW="$(litellm_master_curl -s --max-time 15 \
    -H 'Content-Type: application/json' -X POST "$MG_LLM_BASE/key/generate" \
    -d '{"models":["local","claude-opus-sub-xhigh","claude-sonnet-sub-high"],"key_alias":"metagpt","metadata":{"owner":"metagpt","purpose":"phase32"}}' \
    | "$MG_PY" -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$MG_KEY_NEW" ]] || { err "Failed to mint METAGPT_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"; exit 1; }
  set_env METAGPT_LITELLM_KEY "$MG_KEY_NEW"
  ok "METAGPT_LITELLM_KEY minted + saved to .env (mode 0600)"
else
  ok "METAGPT_LITELLM_KEY already present + valid"
fi

# --- 3. Resolve bound model (availability-gated; default local) ---
MG_MODEL="$MG_MODEL_DEFAULT"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _mm="$(yq -r '.assignments.metagpt // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  [[ -n "$_mm" && "$_mm" != "null" ]] && MG_MODEL="$_mm"
fi
ok "MetaGPT LLM model = $MG_MODEL (routed via LiteLLM → Phoenix project ai-stack)"
# Self-heal the key's allow-list against the model the app ACTUALLY calls ($MG_MODEL,
# which an operator may have re-assigned) PLUS the mint fallbacks. The mint only re-mints
# when the key is fully dead, so a rename/re-assign leaves a stale key SILENT-403ing the
# bound model (`model sync` never touches this key). See litellm_reconcile_key (common.sh).
litellm_reconcile_key METAGPT_LITELLM_KEY "$MG_MODEL" local claude-opus-sub-xhigh claude-sonnet-sub-high

# --- 4. bin/metagpt wrapper (injects key from .env at RUNTIME; writes ~/.metagpt/config2.yaml) ---
# The wrapper writes config2.yaml each run from the .env key (0600, in $HOME — never
# the repo), so the key lives ONLY in .env. The \$ escapes keep $_key/$_model as
# RUNTIME references in the generated wrapper (the key is NOT baked at install time).
# Default model ($MG_MODEL) IS baked at install time; override at runtime with
# METAGPT_MODEL, or re-run 'install 32' after changing models.yml. Routes to
# 127.0.0.1:4000 (the host-shell route that always resolves).
cat > "$MG_WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
# bin/metagpt — stack wrapper around the metagpt venv (Phase 32). Regenerate: install 32.
# Injects the scoped LiteLLM key from .env at runtime; writes ~/.metagpt/config2.yaml.
set -Eeuo pipefail
AI_STACK="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
# last-wins on duplicate .env keys (matches installer/lib/env.sh get_env semantics)
_mg_get_env() { grep -E "^\$1=" "\$AI_STACK/.env" 2>/dev/null | tail -1 | cut -d= -f2-; }
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
  base_url: "http://127.0.0.1:4000/v1"
  api_key: "\$_key"
  model: "\$_model"
CFG
chmod 0600 "\$HOME/.metagpt/config2.yaml" 2>/dev/null || true
export OPENAI_BASE_URL="http://127.0.0.1:4000/v1" OPENAI_API_KEY="\$_key"
cd "\$AI_STACK/metagpt"   # MetaGPT writes ./workspace here
exec "\$PY" "\$@"
WRAPEOF
chmod +x "$MG_WRAPPER"
ok "wrote $MG_WRAPPER"

# --- 5. Keep the sim workspace as DATA (the metagpt/ tree is git-ignored at the repo
# root so install output is not untracked noise in the main checkout). ---
[[ -f "$MG_WORKSPACE/.gitkeep" ]] || : > "$MG_WORKSPACE/.gitkeep"
cat > "$MG_DIR/.gitignore" <<'GI'
# MetaGPT venv is regenerable (uv); the workspace is DATA (sim output) — keep it.
.venv/
GI

# --- 6. Smoke gate: exercise the REAL bin/metagpt wrapper (it writes config2.yaml +
# loads the metagpt CLI) AND prove the scoped key reaches a model THROUGH LiteLLM,
# before stamping. A full `metagpt "<idea>"` run is the minutes-long e2e (test 32). ---
log "Smoke: bin/metagpt wrapper loads (writes ~/.metagpt/config2.yaml + the metagpt CLI runs)…"
"$MG_WRAPPER" --help >/dev/null 2>&1 || { err "bin/metagpt --help failed — wrapper or metagpt CLI broken; not stamping"; exit 1; }
ok "bin/metagpt runs end-to-end (wrapper + venv + CLI)"
log "Smoke: scoped key → LiteLLM chat completion…"
_sc="$(litellm_scoped_curl "$(get_env METAGPT_LITELLM_KEY '')" -s -o /dev/null -w '%{http_code}' --max-time 30 \
  -H 'Content-Type: application/json' \
  -X POST "$MG_LLM_BASE/v1/chat/completions" \
  -d "{\"model\":\"$MG_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":4}" 2>/dev/null || echo 000)"
[[ "$_sc" == "200" ]] || { err "scoped key chat completion returned HTTP $_sc (model $MG_MODEL via LiteLLM) — not stamping"; exit 1; }
ok "scoped key reaches $MG_MODEL through LiteLLM (HTTP 200)"

stamp_mark "$PHASE"
record "phase 32 complete: MetaGPT venv (py3.11) + scoped key + bin/metagpt wrapper"
ok "Phase 32 — MetaGPT — complete"
note "Prove the wrapper: vz-ai-stack.sh test 32     # runs bin/metagpt end-to-end"
note "Run a swarm:   bin/metagpt \"create a CLI 2048 game in python\"   # output → metagpt/workspace/"
note "Watch it:      Phoenix → http://phoenix:6006 (project ai-stack) traces every agent's LLM call"
note "Model:         default is claude-opus-sub-xhigh. Cheap on-box: METAGPT_MODEL=local bin/metagpt \"…\""
note "Reversible:    rm -rf $MG_VENV && rm -f $AI_STACK/installer/state/phase_32.done"
