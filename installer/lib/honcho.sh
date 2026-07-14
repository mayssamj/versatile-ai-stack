# installer/lib/honcho.sh — Honcho v3 helpers shared by Phase 03, Phase 15,
# and doctor checks. Honcho's REST API lives at /v3/workspaces/{ws}/peers/...
#
# Usage:
#   source "$AI_STACK/installer/lib/honcho.sh"
#   honcho_peer_exists "pi"             # 0=exists, 1=missing, 2=Honcho down
#   honcho_peer_ensure "pi"             # idempotent create
#   honcho_workspace_id                  # echoes the workspace id used by phases
#
# Soft-isolation note: Honcho v3 has no API-key-scoped peer-access enforcement
# at the time of writing — a peer ID is a namespace boundary for writes, not a
# hard read boundary. Pi's policy relies on the prompt + extension-config not
# querying foreign peer IDs. Doctor check 25 reflects this honestly.

HONCHO_BASE_URL="${HONCHO_BASE_URL:-http://honcho:8000}"
HONCHO_WORKSPACE="${HONCHO_WORKSPACE_ID:-default}"

honcho_workspace_id() { echo "$HONCHO_WORKSPACE"; }

honcho_is_up() {
  curl -sf --max-time 3 "$HONCHO_BASE_URL/health" >/dev/null 2>&1
}

# honcho_ensure_embedding_env — idempotently point honcho's embedding client at LiteLLM.
# honcho's embedding base_url has NO fallback to the chat var (LLM_OPENAI_BASE_URL), so
# without these NESTED EMBEDDING_* vars honcho embeds against platform.openai.com with the
# local key -> 401 -> every search/recall/ingest 500s. Model is the LiteLLM route name
# embed-openai-small (1536-dim, matches honcho's migration-pinned vector(1536) => zero
# migration). If it CHANGES honcho/.env AND honcho is running, force-recreate ONLY api+deriver
# (NOT database/redis — the database is LiteLLM's keystore SPOF) so the new env actually loads.
# Idempotent: no change -> no restart. Returns 1 only if honcho isn't installed (no .env).
# Shared by Phase 03 (fresh install) + Phase 40 (opt-in honcho memory) so both self-heal.
honcho_ensure_embedding_env() {
  local hdir="${AI_STACK:-$HOME/ai-stack}/honcho" envf changed=0
  envf="$hdir/.env"
  [[ -f "$envf" ]] || return 1
  local model; model="$(get_env HONCHO_EMBED_MODEL embed-openai-small 2>/dev/null)"; [[ -n "$model" ]] || model="embed-openai-small"
  _hset_embed() {  # KEY VALUE — upsert into honcho/.env; sets changed=1 on modify
    local key="$1" val="$2" cur
    cur="$(grep -E "^${key}=" "$envf" 2>/dev/null | head -1 | cut -d= -f2-)"
    [[ "$cur" == "$val" ]] && return 0
    grep -v "^${key}=" "$envf" > "$envf.tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "$envf.tmp"
    mv "$envf.tmp" "$envf"; changed=1
  }
  _hset_embed EMBEDDING_MODEL_CONFIG__TRANSPORT           "openai"
  _hset_embed EMBEDDING_MODEL_CONFIG__MODEL               "$model"
  _hset_embed EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL "http://litellm.ai-stack:4000/v1"
  chmod 600 "$envf" 2>/dev/null || true
  if (( changed )); then
    ok "honcho embedding -> LiteLLM ($model)."
    if honcho_is_up 2>/dev/null || docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^honcho-api'; then
      log "Reloading honcho api+deriver to load the embedding env (database left UP — it is LiteLLM's keystore)…"
      ( cd "$hdir" && docker compose up -d --force-recreate api deriver >/dev/null 2>&1 ) \
        || warn "honcho api/deriver force-recreate failed — reload manually: (cd $hdir && docker compose up -d --force-recreate api deriver)"
      local hb; hb="${HONCHO_BASE_URL:-http://honcho:8000}"
      wait_http "${hb}/health" 60 >/dev/null 2>&1 || wait_http http://127.0.10.6:8000/health 60 >/dev/null 2>&1 || warn "honcho /health slow after reload — check 'docker logs honcho-api-1'"
    fi
  fi
  return 0
}

honcho_peer_exists() {
  local peer="$1"
  honcho_is_up || return 2
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "$HONCHO_BASE_URL/v3/workspaces/$HONCHO_WORKSPACE/peers/$peer" 2>/dev/null || true)
  case "$code" in
    2??) return 0 ;;
    404) return 1 ;;
    *)   return 2 ;;
  esac
}

honcho_peer_ensure() {
  local peer="$1"
  honcho_is_up || return 2
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -X POST "$HONCHO_BASE_URL/v3/workspaces/$HONCHO_WORKSPACE/peers" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"$peer\"}" 2>/dev/null || true)
  case "$code" in
    2??|409) return 0 ;;
    *) return 1 ;;
  esac
}
