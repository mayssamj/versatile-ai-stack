#!/usr/bin/env bash
# Phase 25 — LM Studio (MLX engine) as a SECOND local runtime behind LiteLLM.
#
# WHY: on Apple Silicon, Apple's MLX engine can beat llama.cpp/GGUF (Ollama's
# backend) for small/short-context decode, and — concretely for this stack — it
# is the way to run LiquidAI LFM2.5 with WORKING tool calling (the Ollama GGUF
# build reports "does not support tools"). We do NOT replace Ollama: LM Studio is
# added as a parallel OpenAI-compatible provider so LiteLLM can route a few
# `local-...-mlx` model slugs to it. Ollama stays the default (embeddings, Lumen,
# the model library all untouched). See doc/ALTERNATIVES.md + the 2026-05-31 assessment.
#
# WHAT THIS PHASE DOES (idempotent, host tool — not a container):
#   1. Ensure LM Studio is present (use an existing /Applications/LM Studio.app,
#      else `brew install --cask lm-studio`) and the `lms` CLI is bootstrapped.
#   2. Start the OpenAI-compatible server on :1234, BOUND so the LiteLLM container
#      can reach it via host.docker.internal (LM Studio has NO auth — see SECURITY).
#   3. Ensure the LFM2.5 MLX weights are on disk (pull from HF into LM Studio's
#      models dir if missing — LM Studio's catalog doesn't index LFM2.5 yet).
#   4. Load it, discover the served model id, and idempotently add a
#      `local-lfm2-mlx` entry to litellm/config.yaml → host.docker.internal:1234.
#   5. Restart LiteLLM and verify a chat completion routes :4000 → :1234 → MLX.
#
# SECURITY: the server binds 0.0.0.0:1234 so the OrbStack container can reach it
# (host loopback isn't reachable from a container). LM Studio has no auth, so this
# exposes the LLM to your LAN. On a trusted/work network that's the usual tradeoff
# for a host LLM server; restrict via a firewall or LM Studio's network toggle if
# you're on an untrusted network.
#
# Standalone:  bash vz-ai-stack.sh install 25   (or:  vz-ai-stack.sh install lmstudio)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
# Shared LM Studio helpers (served-id discovery, config.yaml yq-upsert, RAM
# policy). Factored out so Phase 25 + lib/models.sh share ONE implementation.
source "$AI_STACK/installer/lib/lmstudio.sh"

PHASE=25
LMS_PORT=1234
LMS_URL="http://127.0.0.1:${LMS_PORT}"
MLX_REPO="LiquidAI/LFM2.5-8B-A1B-MLX-4bit"      # 4-bit (~5GB) — RAM-friendly on 24GB
MLX_DIR="$HOME/.lmstudio/models/${MLX_REPO}"
LITELLM_SLUG="local-lfm2-mlx"
CONFIG="$AI_STACK/litellm/config.yaml"
LMS_CONFIG="$CONFIG"   # lib/lmstudio.sh writes here

# Thin shims kept for this phase's existing call sites — delegate to the lib so
# there is exactly one implementation (NO behaviour change for LFM2.5).
_lms() { lms_cli; }
_app_present() { [[ -d "/Applications/LM Studio.app" ]]; }
_server_up() { lms_server_up; }
_served_llm_id() { lms_served_first; }

precheck() {
  _app_present || return 1
  [[ -n "$(_lms)" ]] || return 1
  _server_up || return 1
  # Assignment-driven: complete when every models.yml-ASSIGNED lmstudio MLX slug
  # is wired into config.yaml. The LFM2.5 demo (LITELLM_SLUG=local-lfm2-mlx) is
  # required only when explicitly opted in via LMS_LOAD_LFM2=1.
  if [[ "${LMS_LOAD_LFM2:-0}" == "1" ]]; then
    grep -q "model_name: ${LITELLM_SLUG}\b" "$CONFIG" 2>/dev/null || return 1
  fi
  local _yml="$AI_STACK/installer/models.yml" _s
  if [[ -f "$_yml" ]] && command -v yq >/dev/null 2>&1; then
    while IFS= read -r _s; do
      [[ -z "$_s" ]] && continue
      yq -r '.assignments | to_entries | .[].value' "$_yml" 2>/dev/null | grep -qxF "$_s" || continue
      grep -q "model_name: ${_s}\b" "$CONFIG" 2>/dev/null || return 1
    done < <(yq -r '.models | to_entries | .[] | select(.value.runtime=="lmstudio") | .key' "$_yml" 2>/dev/null)
  fi
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 25 — LM Studio — already wired ($LITELLM_SLUG → $LMS_URL)"
  exit 0
fi

hdr "Phase 25 — LM Studio (MLX) as a second runtime behind LiteLLM"

# --- 0. macOS only (MLX is Apple Silicon) ---------------------------------
if [[ "$(uname -s)" != "Darwin" ]]; then
  warn "LM Studio/MLX targets macOS; this host is $(uname -s). Skipping (non-fatal)."
  exit 0
fi

# --- 1. Ensure LM Studio.app + lms CLI ------------------------------------
if ! _app_present; then
  if command -v brew >/dev/null 2>&1; then
    log "Installing LM Studio (brew install --cask lm-studio)..."
    brew install --cask lm-studio 2>&1 | tail -5 || true
  fi
fi
if ! _app_present; then
  warn "LM Studio.app not present and brew install didn't land it. Install it from https://lmstudio.ai then re-run 'vz-ai-stack.sh install lmstudio'. (non-fatal)"
  exit 0
fi
LMS="$(_lms)"
if [[ -z "$LMS" ]]; then
  warn "lms CLI not found. Open LM Studio.app once (it bootstraps the CLI), or run its bundled lms bootstrap, then re-run. (non-fatal)"
  exit 0
fi
ok "LM Studio present; lms CLI at $LMS"

# ⚠️ CPU CAVEAT: on this machine the LM Studio *desktop app* idle-spins at
# ~0.8–1 core even with NO model loaded and the server stopped (observed 42–88%).
# So this is an OPT-IN phase: run it only when you actively want MLX tool-calling,
# and QUIT LM Studio (`lms server stop` + quit the app) when done. For a headless,
# lighter alternative that doesn't idle-spin, prefer `mlx_lm.server` (pip mlx-lm).
# --- 2. Start the OpenAI-compatible server (bound for container access) ----
if ! _server_up; then
  if [[ "${LMS_AUTOSTART:-}" == "1" ]]; then
    warn "LMS_AUTOSTART=1 — starting LM Studio. Its desktop app idle-spins ~0.8 core; quit it when done (lms server stop + quit the app)."
    log "Starting LM Studio server on 0.0.0.0:${LMS_PORT}..."
    "$LMS" server start -p "$LMS_PORT" --bind 0.0.0.0 2>&1 | tail -3 || true
    sleep 3
    if ! _server_up; then
      warn "LM Studio server not reachable on $LMS_URL after start. (non-fatal — re-run later)"
      exit 0
    fi
  else
    # OPT-IN: do NOT auto-start. Auto-starting the server here (and the big-MLX
    # auto-load below) is what swap-thrash-locked the Mac 2026-06-01. The user
    # starts LM Studio deliberately when they have the RAM for it.
    note "LM Studio server not running and LMS_AUTOSTART unset — LM Studio is OPT-IN (its app idle-spins CPU; big MLX models need lots of RAM)."
    note "To use MLX models:  $LMS server start -p ${LMS_PORT} --bind 0.0.0.0   then re-run 'vz-ai-stack.sh install lmstudio'  (or set LMS_AUTOSTART=1 for a one-shot start)."
    exit 0
  fi
fi
ok "LM Studio server up on $LMS_URL"

# --- 3. ASSIGNMENT-DRIVEN MLX load (the default) ---------------------------
# Load ONLY models that an agent is actually assigned in installer/models.yml
# (the canonical MLX slugs local-qwen3.6 / local-qwen3-coder). If nothing is
# assigned, NOTHING is loaded — LM Studio does not auto-load a model. Best-effort,
# non-fatal: the canonical config.yaml rows already exist (Phase 01); here we make
# the running LM Studio actually serve an assigned id so `model sync` can promote
# the agents off the gemma4 fallback. (To also disable LM Studio's OWN auto-load,
# turn off "JIT model loading" + "load last model on launch" in its app settings.)
MODELS_YML="$AI_STACK/installer/models.yml"
_lms_registered=0   # config.yaml actually CHANGED -> LiteLLM needs a reload
_lms_assigned=0     # at least one agent is assigned an MLX slug (loadable or not)
if [[ -f "$MODELS_YML" ]]; then
  while IFS= read -r _slug; do
    [[ -z "$_slug" ]] && continue
    case "$_slug" in local-qwen3.6|local-qwen3-coder) : ;; *) continue ;; esac
    _served="$(yq -r ".models.\"$_slug\".served" "$MODELS_YML" 2>/dev/null)"
    _ttl="$(yq -r ".models.\"$_slug\".ttl // 1800" "$MODELS_YML" 2>/dev/null)"
    [[ -z "$_served" || "$_served" == "null" ]] && continue
    # Skip unless an agent is actually assigned this slug.
    if ! yq -r '.assignments | to_entries | .[].value' "$MODELS_YML" 2>/dev/null | grep -qxF "$_slug"; then
      continue
    fi
    _lms_assigned=1
    log "Loading assigned MLX model $_slug ($_served) per the one-big-MLX policy..."
    if lms_load_big "$_served" "$_ttl"; then
      # Only a CHANGED config.yaml warrants a LiteLLM restart (idempotent re-runs
      # return UNCHANGED — don't bounce LiteLLM for nothing).
      case "$(lms_register_model "$_slug" "$_served" lmstudio)" in
        CHANGED)   ok "registered $_slug → $_served in litellm/config.yaml"; _lms_registered=1 ;;
        UNCHANGED) ok "$_slug already registered ($_served) in litellm/config.yaml" ;;
        *)         warn "could not register $_slug in config.yaml" ;;
      esac
    else
      warn "$_slug ($_served) not loadable right now — config row stays; agent stays on the fallback until 'model sync'"
    fi
  done < <(yq -r '.models | keys | .[]' "$MODELS_YML" 2>/dev/null)
fi

# --- LFM2.5 demo is OPT-IN (NOT auto-loaded) -------------------------------
# By DEFAULT this phase loads only the assigned MLX models above — it will NOT
# download or load the LFM2.5 demo model. Set LMS_LOAD_LFM2=1 to set up LFM2.5
# (a ~5GB MLX model with working tool-calling, handy for A/B vs the Ollama GGUF).
if [[ "${LMS_LOAD_LFM2:-0}" != "1" ]]; then
  if (( _lms_registered )); then
    log "Restarting LiteLLM to pick up the newly-registered assigned MLX model(s)..."
    docker restart litellm >/dev/null 2>&1 || warn "docker restart litellm failed — restart it manually"
    for _ in $(seq 1 30); do curl -s -o /dev/null --max-time 2 http://litellm:4000/health/liveliness 2>/dev/null && break; sleep 2; done
    ok "LiteLLM reloaded — assigned MLX model(s) now servable"
  elif (( _lms_assigned )); then
    note "Assigned MLX model(s) are already registered or not loadable right now — no LiteLLM restart needed; run 'vz-ai-stack.sh model sync' once they load."
  else
    note "No agent is assigned an LM Studio MLX model — nothing loaded (LM Studio does NOT auto-load a model)."
    note "Assign one, then re-run:  vz-ai-stack.sh model assign <agent> local-qwen3.6   (or local-qwen3-coder)"
  fi
  note "LFM2.5 demo is opt-in: set LMS_LOAD_LFM2=1 to download + load it (~5GB)."
  stamp_mark "$PHASE"
  record "phase 25: LM Studio server wired; assignment-driven MLX load only (registered=${_lms_registered}); LFM2.5 opt-in (not loaded)"
  ok "Phase 25 — LM Studio — complete (assignment-driven; LFM2.5 opt-in)"
  exit 0
fi
# LMS_LOAD_LFM2=1 → fall through to the LFM2.5 setup below.

# --- 4. (opt-in) Ensure the LFM2.5 MLX weights are on disk -----------------
# LM Studio's catalog doesn't index LFM2.5 yet (very new), so `lms get` can't
# resolve it; pull the weights from HF straight into LM Studio's models dir.
# Presence is gated on the actual WEIGHTS (*.safetensors), not just config.json —
# a partial download leaves config/tokenizer behind but no weights.
_weights_present() { ls "$MLX_DIR"/*.safetensors >/dev/null 2>&1; }
if ! _weights_present; then
  if ! command -v uv >/dev/null 2>&1 && ! command -v uvx >/dev/null 2>&1; then
    warn "uv/uvx not on PATH — needed to fetch $MLX_REPO from HF. Run 'vz-ai-stack.sh install 14' (ships uv), then re-run. (non-fatal)"
    exit 0
  fi
  log "Downloading $MLX_REPO from HF into LM Studio's models dir (~5GB)..."
  mkdir -p "$MLX_DIR"
  # Modern huggingface_hub CLI entry point is `hf download` (legacy
  # `huggingface-cli download` just prints help on current versions). hf download
  # resumes partial downloads, so re-running after an interruption completes it.
  if ! uvx --from huggingface_hub hf download "$MLX_REPO" --local-dir "$MLX_DIR" 2>&1 | tail -4; then
    warn "HF download of $MLX_REPO failed (network?). (non-fatal — re-run later)"
    exit 0
  fi
fi
_weights_present || { warn "$MLX_REPO weights incomplete at $MLX_DIR (no .safetensors). (non-fatal — re-run later)"; exit 0; }
ok "LFM2.5 MLX weights present at $MLX_DIR"

# --- 4. Load it + discover the served model id -----------------------------
log "Loading the MLX model into LM Studio (JIT/explicit)..."
"$LMS" load "$MLX_REPO" -y >/dev/null 2>&1 || "$LMS" load "${MLX_REPO,,}" -y >/dev/null 2>&1 || true
sleep 2
MLX_ID="$(_served_llm_id)"
if [[ -z "$MLX_ID" ]]; then
  warn "Could not determine the served LLM id from $LMS_URL/v1/models (model not loaded?)."
  warn "Load it in the LM Studio UI or 'lms load', then re-run. (non-fatal)"
  exit 0
fi
ok "LM Studio is serving model id: $MLX_ID"

# --- 5. Wire LiteLLM: add the local-lfm2-mlx provider (idempotent) ---------
# Uses the shared lms_register_model (ADD-ONLY yq-upsert, atomic temp+mv,
# idempotent) instead of an inline `yq +=` — same result for LFM2.5.
command -v yq >/dev/null 2>&1 || { err "yq not on PATH (Phase 00 installs it)"; exit 1; }
case "$(lms_register_model "$LITELLM_SLUG" "$MLX_ID" lmstudio)" in
  CHANGED)   ok "added $LITELLM_SLUG (model openai/$MLX_ID)" ;;
  UNCHANGED) ok "$LITELLM_SLUG already in litellm/config.yaml" ;;
  *)         err "failed to inject $LITELLM_SLUG into config.yaml"; exit 1 ;;
esac

# --- 6. Restart LiteLLM (reloads config.yaml) + verify the pipe ------------
log "Restarting LiteLLM to load the new model..."
docker restart litellm >/dev/null 2>&1 || warn "docker restart litellm failed — restart it manually"
# Wait for LiteLLM to come back.
for _ in $(seq 1 30); do curl -s -o /dev/null --max-time 2 http://litellm:4000/health/liveliness 2>/dev/null && break; sleep 2; done

MASTER="$(get_env LITELLM_MASTER_KEY '')"
log "Verifying :4000 → :1234 → MLX (chat completion via LiteLLM)..."
RESP="$(curl -s --max-time 90 http://litellm:4000/v1/chat/completions \
  -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' \
  -d "{\"model\":\"$LITELLM_SLUG\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly: MLX-OK\"}],\"max_tokens\":16}" 2>/dev/null \
  | python3 -c 'import sys,json
try: print(json.load(sys.stdin)["choices"][0]["message"]["content"][:60])
except Exception as e: print("")' 2>/dev/null)"
if [[ -n "$RESP" ]]; then
  ok "LiteLLM → LM Studio (MLX) round-trip OK — model replied: $(printf '%s' "$RESP" | tr -d '\n')"
else
  warn "Round-trip through LiteLLM produced no content (model still loading, or scoped key needed)."
  warn "Re-test: curl http://litellm:4000/v1/chat/completions -H \"Authorization: Bearer \$LITELLM_MASTER_KEY\" -d '{\"model\":\"$LITELLM_SLUG\",...}'"
fi

stamp_mark "$PHASE"
record "phase 25 complete: LM Studio (MLX) wired as $LITELLM_SLUG → $LMS_URL (model $MLX_ID); Ollama unchanged"
ok "Phase 25 — LM Studio (MLX) — complete"
note "New model behind LiteLLM:  $LITELLM_SLUG  (LFM2.5 MLX — has working tool-calling, unlike the Ollama GGUF build)"
note "A/B vs Ollama: point a Hermes profile at it, e.g. (relay must be up):"
note "  openshell sandbox exec -n hermes-fleet-v1 -- hermes --profile hermes_software_engineer config set providers.litellm.model $LITELLM_SLUG"
note "  then run the same task on local-lfm2 (Ollama) vs $LITELLM_SLUG (MLX) and compare tok/s + tool-calls in Phoenix (http://phoenix:6006)."
note "NOTE: to let SCOPED virtual keys (Pi/ACE/Hermes/RLM) use this model, add '$LITELLM_SLUG' to their allowlists (re-mint, or 'litellm key update'). The master key already works."
note "Server: $LMS  |  lms ps (loaded) |  lms server status  |  Ollama is untouched (still the default)."
warn "WHEN DONE: quit LM Studio to reclaim CPU →  $LMS server stop  + quit the LM Studio app."
warn "Lighter headless alternative (no idle-spin): pip install mlx-lm; mlx_lm.server --model $MLX_DIR --port $LMS_PORT"
