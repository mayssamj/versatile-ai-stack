#!/usr/bin/env bash
# Phase 17 — ACE (Agentic Context Engineering).
#
# ACE is a Python research framework (arXiv 2510.04618, Zhang/Olukotun et al.)
# that lets agents self-improve by treating their LLM context as an evolving
# "playbook." Three roles iterate over a task dataset:
#   Generator → produces candidate solutions
#   Reflector → critiques + extracts lessons
#   Curator   → applies structured "delta updates" to a persistent playbook
#                (default 80k-token budget)
# The output is a Markdown-shaped playbook you can paste into any agent's
# system prompt as a long-form expertise injection.
#
# Why it earns its own phase:
#   - Different role than AutoFyn / Hermes fleet / Pi (those USE a context).
#     ACE MANUFACTURES the context they should use.
#   - Pure batch CLI — no daemon, no port, no MCP transport. Closest cousin
#     architecturally is Phase 14 (Unsloth) — both are "train a thing, then
#     export an artifact." Unsloth → model weights; ACE → playbook.
#
# What this phase does (idempotent):
#   1. git clone or fetch+checkout https://github.com/ace-agent/ace (pinned SHA).
#   2. `uv sync` to create the venv from pyproject.toml.
#   3. Mint a LiteLLM virtual key (ACE_LITELLM_KEY) scoped to local models,
#      mirrors Phase 15's PI_LITELLM_KEY pattern.
#   4. Render $ACE_DIR/.env with:
#        OPENAI_API_KEY=$ACE_LITELLM_KEY
#        OPENAI_BASE_URL=http://litellm:4000/v1
#      (the openai Python SDK ≥1.0 respects OPENAI_BASE_URL, which routes
#      every call through LiteLLM → Phoenix tracing for free.)
#   5. chmod 0700 the results directory.
#   6. Write bin/ace wrapper (cd's into ACE_DIR + execs uv run).
#   7. Smoke test: `bin/ace --help` exits 0. We do NOT run a full eval here
#      (multi-GB datasets + millions of LLM tokens).
#
# Sandbox? No. ACE makes API calls + runs sklearn/faiss on local datasets.
# It does NOT exec model-generated code. Same risk profile as Phase 14
# (Unsloth). If user ever runs the AppWorld task (agent-interaction sim
# which DOES execute generated tool calls), they should move into pi-v1.
#
# Standalone install: `bash vz-ai-stack.sh install 17`.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/validate.sh"

PHASE=17
ACE_DIR="$AI_STACK/ace"
ACE_REPO="https://github.com/ace-agent/ace.git"
# Pin a known-good SHA. Update via: cd ace && git rev-parse HEAD
ACE_PIN="${ACE_PIN:-main}"   # Phase 17 first install captures HEAD when ACE_PIN=main
ACE_VENV="$ACE_DIR/.venv"
ACE_RESULTS="$ACE_DIR/results"
ACE_WRAPPER="$AI_STACK/bin/ace"

precheck() {
  [[ -d "$ACE_DIR/.git" ]] || return 1
  [[ -x "$ACE_VENV/bin/python" ]] || return 1
  [[ -x "$ACE_WRAPPER" ]] || return 1
  [[ -f "$ACE_DIR/.env" ]] || return 1
  grep -q '^OPENAI_BASE_URL=http://litellm:4000/v1' "$ACE_DIR/.env" 2>/dev/null || return 1
  local ace_key
  ace_key="$(get_env ACE_LITELLM_KEY '')"
  [[ -n "$ace_key" ]] || return 1
  curl -sf --max-time 5 -H "Authorization: Bearer $ace_key" \
    http://litellm:4000/v1/models >/dev/null 2>&1 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 17 — ACE — already installed (use 'vz-ai-stack.sh install 17' to re-run)"
  exit 0
fi

hdr "Phase 17 — ACE (Agentic Context Engineering)"

# --- Preconditions ---
command -v uv >/dev/null 2>&1 || {
  err "uv not on PATH. uv is installed by Phase 14 (Unsloth). Run:"
  err "  bash $AI_STACK/vz-ai-stack.sh install 14"
  exit 1
}
command -v git >/dev/null 2>&1 || { err "git not on PATH."; exit 1; }
[[ -f "$AI_STACK/.env" ]] || { err ".env missing — run Phase 00 first."; exit 1; }

LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY '')"
if [[ -z "$LITELLM_MASTER_KEY" ]]; then
  err "LITELLM_MASTER_KEY missing from .env — Phase 01 must run first."
  exit 1
fi

if ! curl -sf --max-time 3 http://litellm:4000/health >/dev/null 2>&1 \
   && ! curl -sf --max-time 3 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
        http://litellm:4000/v1/models >/dev/null 2>&1; then
  err "LiteLLM not reachable at http://litellm:4000 — run 'stack start litellm'."
  exit 1
fi

# --- 1. Clone or update repo ---
if [[ ! -d "$ACE_DIR/.git" ]]; then
  log "Cloning ACE from $ACE_REPO..."
  git clone "$ACE_REPO" "$ACE_DIR" 2>&1 | tail -3 || { err "git clone failed"; exit 1; }
fi
(
  cd "$ACE_DIR"
  if [[ "$ACE_PIN" != "main" ]]; then
    log "Checking out pinned SHA $ACE_PIN..."
    git fetch --quiet origin && git checkout --quiet "$ACE_PIN"
  fi
)
ok "ACE source at $ACE_DIR ($(cd "$ACE_DIR" && git rev-parse --short HEAD))"

# --- 2. uv sync ---
log "Creating venv via uv sync (first run downloads ~600 MB of deps)..."
(cd "$ACE_DIR" && uv sync 2>&1 | tail -10) \
  || { err "uv sync failed"; exit 1; }
[[ -x "$ACE_VENV/bin/python" ]] || { err "venv python missing after uv sync"; exit 1; }
ok "venv ready: $ACE_VENV"

# --- 3. Mint LiteLLM virtual key (mirrors Phase 15 pattern) ---
ACE_KEY_CURRENT="$(get_env ACE_LITELLM_KEY '')"
if [[ -z "$ACE_KEY_CURRENT" ]] \
   || ! curl -sf --max-time 5 -H "Authorization: Bearer $ACE_KEY_CURRENT" \
        http://litellm:4000/v1/models >/dev/null 2>&1; then
  # Mint against the fixed SUPERSET so `vz-ai-stack.sh model assign/sync` can re-point
  # ACE without re-minting. Canonical IDs are registered in config.yaml by Phase
  # 01 first (superset-before-mint).
  log "Minting LiteLLM virtual key for ACE (models=superset[local,local-gemma4,local-heavy,local-lfm2,local-qwen3-coder,local-qwen3.6])..."
  ACE_KEY_NEW="$(curl -s --max-time 15 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H 'Content-Type: application/json' \
    -X POST http://litellm:4000/key/generate \
    -d '{"models":["local","local-gemma4","local-heavy","local-lfm2","local-qwen3-coder","local-qwen3.6"],"key_alias":"ace-context-engineering","metadata":{"owner":"ace","purpose":"phase17"}}' \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  if [[ -z "$ACE_KEY_NEW" ]]; then
    err "Failed to mint ACE_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"
    exit 1
  fi
  set_env ACE_LITELLM_KEY "$ACE_KEY_NEW"
  ok "ACE_LITELLM_KEY minted + saved to .env (mode 0600)"
else
  ok "ACE_LITELLM_KEY already present + valid"
fi

# --- 4. Render ACE's .env to route through LiteLLM ---
ACE_KEY_NOW="$(get_env ACE_LITELLM_KEY '')"
# ACE's bound model from installer/models.yml (availability-gated). ACE's
# assignment defaults to local-gemma4 (an Ollama model, always servable). If
# ACE upstream IGNORES OPENAI_MODEL/ACE_DEFAULT_MODEL, the binding is
# allowlist-only — `vz-ai-stack.sh model list` flags ACE as "(allowlist-only)" so it
# never falsely reads as model-bound.
ACE_MODEL="local"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _am="$(yq -r '.assignments.ace // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  _art="$(yq -r ".models.\"$_am\".runtime" "$AI_STACK/installer/models.yml" 2>/dev/null)"
  # Gate: only render an lmstudio slug if :1234 is up + it's in config.yaml.
  if [[ -n "$_am" && "$_am" != "null" ]]; then
    if [[ "$_art" == "lmstudio" ]] \
       && ! { curl -s -o /dev/null --max-time 3 http://127.0.0.1:1234/v1/models 2>/dev/null \
              && grep -qF "model_name: ${_am}" "$AI_STACK/litellm/config.yaml" 2>/dev/null; }; then
      ACE_MODEL="$(yq -r '.default' "$AI_STACK/installer/models.yml" 2>/dev/null)"
    else
      ACE_MODEL="$_am"
    fi
  fi
fi
set_env ACE_DEFAULT_MODEL "$ACE_MODEL"
# Other provider keys are set to "unused" to satisfy any unconditional
# `from X import Y` in ACE's provider files.
cat > "$ACE_DIR/.env" <<ENVEOF
# ai-stack: rendered by installer/phases/17_ace.sh on $(date -u +%FT%TZ).
# Do not edit; re-run 'bash vz-ai-stack.sh install 17' to regenerate.
OPENAI_API_KEY=$ACE_KEY_NOW
OPENAI_BASE_URL=http://litellm:4000/v1
OPENAI_MODEL=$ACE_MODEL
ACE_DEFAULT_MODEL=$ACE_MODEL
SAMBANOVA_API_KEY=unused
TOGETHER_API_KEY=unused
COMMONSTACK_API_KEY=unused
ENVEOF
chmod 0600 "$ACE_DIR/.env"
ok "wrote $ACE_DIR/.env (mode 0600; LiteLLM-routed; model=$ACE_MODEL)"

# --- 5. Results dir ---
mkdir -p "$ACE_RESULTS" && chmod 0700 "$ACE_RESULTS"

# --- 6. bin/ace wrapper ---
cat > "$ACE_WRAPPER" <<'WRAPEOF'
#!/usr/bin/env bash
# bin/ace — thin wrapper around ACE inside its uv venv.
# Routes all LLM calls through LiteLLM via OPENAI_BASE_URL (set in
# $AI_STACK/ace/.env, loaded automatically by python-dotenv).
#
# Subcommands map to ACE's eval modules (see github.com/ace-agent/ace).
# Examples:
#   ace finance finer --mode eval_only --save_path results/smoke
#   ace appworld --task my_task
#   ace --help
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ACE_DIR="$AI_STACK/ace"
[[ -d "$ACE_DIR/.git" ]] || { echo "ACE not installed — run 'bash vz-ai-stack.sh install 17'" >&2; exit 1; }

case "${1:-}" in
  --help|-h|"")
    cat <<'HELP'
ace — Agentic Context Engineering (Phase 17)
usage:
  ace finance <task> [args]     # FiNER, XBRL, etc.
  ace appworld [args]           # AppWorld task (executes generated tool calls — use pi-v1 sandbox)
  ace <module> [args]           # raw `uv run python -m <module>`
  ace --help

Output → ~/ai-stack/ace/results/
Routes via LiteLLM → Phoenix project ai-stack.
HELP
    exit 0
    ;;
  appworld)
    # AppWorld executes model-generated tool calls. Running on the host
    # bypasses pi-v1's policy guardrails. Reviewer C: require explicit
    # confirmation. Set ACE_APPWORLD_ALLOW=1 to skip the prompt.
    if [[ "${ACE_APPWORLD_ALLOW:-0}" != "1" ]]; then
      echo "WARNING: 'ace appworld' executes model-generated tool calls on the host." >&2
      echo "         For real evals, run inside the pi-v1 OpenShell sandbox instead." >&2
      echo "         Continue anyway? [y/N] " >&2
      read -r ans
      [[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || { echo "aborted." >&2; exit 1; }
    fi
    shift
    exec env -C "$ACE_DIR" uv run python -m "eval.appworld.run" "$@"
    ;;
  finance)
    task="${2:-}"
    [[ -n "$task" ]] || { echo "usage: ace finance <finer|xbrl|...>" >&2; exit 2; }
    shift 2
    exec env -C "$ACE_DIR" uv run python -m "eval.finance.$task.run" "$@"
    ;;
  *)
    mod="$1"; shift
    exec env -C "$ACE_DIR" uv run python -m "$mod" "$@"
    ;;
esac
WRAPEOF
chmod +x "$ACE_WRAPPER"
ok "wrote $ACE_WRAPPER"

# --- 7. Smoke test: wrapper runs (hard-err per Reviewer A) ---
if ! "$ACE_WRAPPER" --help >/dev/null 2>&1; then
  err "bin/ace --help failed — wrapper broken; phase will not stamp."
  err "Inspect: $ACE_WRAPPER and re-run 'bash vz-ai-stack.sh install 17'."
  exit 1
fi
ok "bin/ace --help: smoke-test passed"

# --- 8. Capture pin (Reviewer C: ACE_PIN=main is supply-chain regression) ---
# Record the SHA we installed against so subsequent runs (or doctor) can
# detect upstream drift without silently pulling new commits.
ACE_SHA="$(cd "$ACE_DIR" && git rev-parse HEAD 2>/dev/null || echo unknown)"
if [[ "$ACE_SHA" != "unknown" ]]; then
  set_env ACE_PIN "$ACE_SHA"
  ok "ACE_PIN captured: $ACE_SHA → .env"
fi

stamp_mark "$PHASE"
record "phase 17 complete: ACE cloned + venv + virtual key + .env + bin/ace wrapper"
ok "Phase 17 — ACE — complete"
note "Try:   $ACE_WRAPPER --help"
note "Eval:  $ACE_WRAPPER finance finer --mode eval_only --save_path results/smoke"
note "Logs:  ls -la $ACE_RESULTS"
note "Each run writes a playbook artifact under results/. Paste into agent prompts."
