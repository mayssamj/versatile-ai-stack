#!/usr/bin/env bash
# Phase 01 — inference plane: Ollama + LiteLLM + trace_to_file.py.
#
# Idempotency rules:
#   - Ollama brew install + brew services start: skipped if already.
#   - Model pulls: skipped if model already present in `ollama list`.
#   - LiteLLM container: if already running AND foreign (not managed by us),
#     prompts user to `vz-ai-stack.sh adopt litellm`. If already running AND
#     managed, it is HEALTH-PROBED (not trusted blindly): a managed container
#     that isn't actually serving /v1/models (stale config, old master key,
#     Postgres down, mid-boot — the classic cold/second-machine failure) is
#     recreated via start-litellm.sh --recreate so the phase self-heals.
#   - config.yaml + trace_to_file.py: written if missing, never silently
#     overwrites a user-edited file.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/validate.sh"
source "$AI_STACK/installer/lib/litellm.sh"
source "$AI_STACK/installer/lib/lmstudio.sh"   # lms_register_model (ADD-ONLY upsert)
source "$AI_STACK/installer/lib/deps.sh"        # ensure_ollama (install + env-patch + start + verify)

PHASE=01

# LOCAL-MODEL policy (operator directive 2026-07-01): nemotron-3-nano:4b is the
# ONLY local chat model. Eager-pull ONLY it (`local`/`local-heavy` both map to it,
# ~2.8GB, very light on a 24GB box) + the embedding model. No other local model is
# pulled by install OR doctor. See installer/models.yml + 'vz-ai-stack.sh model'.
REQUIRED_MODELS=(
  nemotron-3-nano:4b
  nomic-embed-text
)

precheck() {
  command -v ollama >/dev/null || return 1
  brew services list 2>/dev/null | awk '$1=="ollama" {print $2}' | grep -q started || return 1
  wait_http http://127.0.0.1:11434/api/tags 5 || return 1
  local installed; installed="$(ollama list 2>/dev/null | awk 'NR>1{print $1}')"
  for m in "${REQUIRED_MODELS[@]}"; do
    # Match bare name OR `name:tag` (default tag is `:latest`).
    echo "$installed" | grep -qE "^${m}(:|$)" || return 1
  done
  [[ -f "$AI_STACK/litellm/config.yaml" ]] || return 1
  [[ -f "$AI_STACK/litellm/trace_to_file.py" ]] || return 1
  litellm_wait_ready 5 || return 1
  # Network membership check: if litellm container exists and we're managing
  # networking, require it on the ai-stack bridge.
  if container_running litellm && container_managed litellm; then
    docker inspect litellm --format '{{json .NetworkSettings.Networks}}' \
      | grep -q '"ai-stack"' || return 1
  fi
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (inference plane)"
  exit 0
fi

hdr "Phase 01 — inference plane"

# --- Ollama: install + cross-container env-patch + start + verify (deps.sh) ---
# ensure_ollama installs ollama if missing, patches the launchd plist for
# cross-container access (OLLAMA_HOST=0.0.0.0 / ORIGINS=* / KEEP_ALIVE=30m), starts
# the service, and verifies :11434 responds. Centralizing the env-patch here (vs
# the old Phase-00 block that was skipped on a cold install because ollama wasn't
# installed yet) is what makes LiteLLM->ollama work on a fresh machine.
ensure_ollama || { err "Ollama could not be ensured"; exit 1; }

# --- Work out which default models still need pulling -------------------------
# The local-model set is tiny: nemotron-3-nano:4b (~2.8GB) + nomic-embed-text
# (~0.3GB) ≈ 3GB. No heavy local model is pulled here (nemotron is the only local
# chat model; see installer/models.yml). So an already-pulled machine needs ZERO
# new disk and must never be blocked — the space requirement below is gated on
# what is ACTUALLY missing.
INSTALLED_MODELS="$(ollama list 2>/dev/null | awk 'NR>1{print $1}')"
MISSING_MODELS=()
for m in "${REQUIRED_MODELS[@]}"; do
  if echo "$INSTALLED_MODELS" | grep -qE "^${m}(:|$)"; then
    ok "model present: $m"
  else
    MISSING_MODELS+=("$m")
  fi
done

# --- Disk-space precheck — ONLY for models we actually need to download --------
# ~3GB of models (nemotron-3-nano:4b + nomic-embed-text) + download/extract
# headroom = ~8GB. (Previously 30GB then 15GB — both stale, sized for the old
# heavy-model-era pull policy — which blocked re-installs on a full box.)
if (( ${#MISSING_MODELS[@]} )); then
  require_disk_free 8 "$HOME" || { err "Need ~8GB free to pull missing models: ${MISSING_MODELS[*]}"; exit 1; }
  for m in "${MISSING_MODELS[@]}"; do
    log "Pulling $m (this may take several minutes)..."
    if ! ollama pull "$m"; then
      err "ollama pull $m failed; cleaning partial blob..."
      ollama rm "$m" 2>/dev/null || true
      exit 1
    fi
    ok "pulled: $m"
  done
else
  ok "all default models already present — no download needed, no disk check"
fi

# --- LiteLLM config.yaml ---
if [[ ! -f "$AI_STACK/litellm/config.yaml" ]]; then
  # Ship the canonical config from prompts/ if present; else error.
  if [[ -f "$AI_STACK/prompts/config.yaml" ]]; then
    cp "$AI_STACK/prompts/config.yaml" "$AI_STACK/litellm/config.yaml"
    ok "wrote litellm/config.yaml from prompts/"
  else
    err "litellm/config.yaml missing and no template at prompts/config.yaml"
    exit 1
  fi
fi
yq -e '.model_list[0]' "$AI_STACK/litellm/config.yaml" >/dev/null || {
  err "litellm/config.yaml has no model_list — refusing to start LiteLLM"
  exit 1
}

# --- Register the canonical model IDs in config.yaml (ADD-ONLY) ----------
# So they exist BEFORE any scoped key is minted (constraint: superset-before-mint):
#   local / local-heavy / local-nemotron3-nano-4b -> Ollama nemotron-3-nano:4b (works immediately)
# We register straight from installer/models.yml when present (the canonical
# source of truth), else fall back to the hardcoded local pair. lms_register_model
# is ADD-ONLY + atomic (temp+mv) + idempotent — existing rows are untouched and
# no model is loaded/inferenced here.
MODELS_YML="$AI_STACK/installer/models.yml"
if [[ -f "$MODELS_YML" ]]; then
  while IFS= read -r _mn; do
    [[ -z "$_mn" ]] && continue
    _rt="$(yq -r ".models.\"$_mn\".runtime" "$MODELS_YML" 2>/dev/null)"
    _sv="$(yq -r ".models.\"$_mn\".served"  "$MODELS_YML" 2>/dev/null)"
    [[ -z "$_sv" || "$_sv" == "null" ]] && continue
    # Pass the per-model effort for meridian models — WITHOUT this, lms_register_model
    # defaults effort to `high` and flattens the subscription effort ladder
    # (claude-*-sub-{low,medium,high,xhigh,max}) on every install. Mirrors
    # lib/models.sh::register_model_list.
    # Mirror lib/models.sh::register_model_list arg extraction. meridian -> effort;
    # openai-compat -> api_base/key_env/rpm/tpm (else it fail-closes + sakana-* never
    # registers on a fresh `install all`, silently leaning on the hand-authored config).
    _ef=""; _ab=""; _ke=""; _rp=""; _tp=""
    case "$_rt" in
      meridian) _ef="$(yq -r ".models.\"$_mn\".effort // \"\"" "$MODELS_YML" 2>/dev/null)" ;;
      openai-compat)
        _ab="$(yq -r ".models.\"$_mn\".api_base // \"\"" "$MODELS_YML" 2>/dev/null)"
        _ke="$(yq -r ".models.\"$_mn\".key_env // \"\"" "$MODELS_YML" 2>/dev/null)"
        _rp="$(yq -r ".models.\"$_mn\".rpm // \"\"" "$MODELS_YML" 2>/dev/null)"
        _tp="$(yq -r ".models.\"$_mn\".tpm // \"\"" "$MODELS_YML" 2>/dev/null)"
        ;;
    esac
    if [[ "$(lms_register_model "$_mn" "$_sv" "$_rt" "$_ef" "$_ab" "$_ke" "$_rp" "$_tp")" == "CHANGED" ]]; then
      ok "registered $_mn ($_rt/$_sv${_ef:+, effort=$_ef}) in litellm/config.yaml"
    fi
  done < <(yq -r '.models | keys | .[]' "$MODELS_YML" 2>/dev/null)
else
  # models.yml absent (partial checkout): register the canonical always-on Ollama
  # nemotron aliases directly (matches lib/models.sh LEGACY_SUPERSET / config.yaml).
  # LM Studio models are opt-in and registered from models.yml, never here.
  lms_register_model local       nemotron-3-nano:4b ollama >/dev/null
  lms_register_model local-heavy nemotron-3-nano:4b ollama >/dev/null
  ok "registered 2 canonical model IDs in litellm/config.yaml (models.yml absent — used defaults)"
fi

# --- LiteLLM custom callback file ---
[[ -f "$AI_STACK/litellm/trace_to_file.py" ]] || {
  err "litellm/trace_to_file.py missing — should have been written by phase scaffold"
  exit 1
}

# --- Start (or HEAL) the LiteLLM container ---
# A running+managed container is NOT trusted blindly: one left over from a prior
# or partial install can be unhealthy (stale config, an old LITELLM_MASTER_KEY,
# Postgres not up, or still booting). We probe it; if it isn't actually serving
# /v1/models we recreate it (start-litellm.sh runs the Postgres precheck, injects
# the CURRENT master key, and rewrites the config) so a cold/second machine heals
# itself instead of dying on the smoke test.
if container_running litellm; then
  if container_managed litellm; then
    if litellm_wait_ready 8; then
      ok "litellm container already running and serving"
    else
      warn "litellm is running+managed but NOT serving /v1/models — recreating to heal it."
      bash "$AI_STACK/bin/start-litellm.sh" --recreate || { litellm_diagnose; exit 1; }
      litellm_wait_ready 60 || { litellm_diagnose; exit 1; }
    fi
  else
    warn "litellm is running but FOREIGN (started outside the installer)."
    warn "Run:  bash vz-ai-stack.sh adopt litellm   to take ownership."
    # Do not fail the phase — the user has a working litellm, just unmanaged.
  fi
else
  log "Starting LiteLLM..."
  bash "$AI_STACK/bin/start-litellm.sh" || { litellm_diagnose; exit 1; }
  litellm_wait_ready 60 || { litellm_diagnose; exit 1; }
fi

# --- Smoke: /v1/models lists at least one model ---
KEY="$(get_env LITELLM_MASTER_KEY)"
if [[ -z "$KEY" ]]; then
  err "LITELLM_MASTER_KEY empty — cannot smoke test"
  exit 1
fi
# Tries the alias URL, loopback :4000, the lo0 alias :4000, AND the actual
# docker-published port — so it works on macOS (lo0/OrbStack) and a plain Linux
# Docker host alike. On failure, dump a self-explaining diagnostic.
if ! litellm_smoke_ok "$KEY"; then
  err "LiteLLM /v1/models did not return a model list."
  litellm_diagnose
  exit 1
fi
ok "LiteLLM /v1/models responds"

stamp_mark "$PHASE"
record "phase 01 complete: ollama up, ${#REQUIRED_MODELS[@]} models pulled, litellm responding"
ok "Phase 01 — inference plane — complete"
