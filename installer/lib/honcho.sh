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

# honcho_ensure_embedding_env — idempotently point honcho's embedding client at LiteLLM AND keep
# honcho's pgvector schema dim in sync with the assigned embedder (§24 council 2026-07-15).
# honcho's embedding base_url has NO fallback to the chat var (LLM_OPENAI_BASE_URL), so without
# these NESTED EMBEDDING_* vars honcho embeds against platform.openai.com with the local key ->
# 401 -> every search/recall/ingest 500s. The embedder is resolved from models.yml
# .embedding_assignments.honcho (HONCHO_EMBED_MODEL overrides; embed-openai-small back-compat
# fallback): EMBEDDING_MODEL_CONFIG__MODEL takes the LiteLLM ROUTE (NOT the registry key — they
# differ, e.g. embed-nomic -> route embed-local), EMBEDDING_VECTOR_DIMENSIONS takes the model DIM.
# DIMENSIONS_MODE=never: honcho sizes its pgvector schema from EMBEDDING_VECTOR_DIMENSIONS but
# never forwards a `dimensions=` param to the embed call (local nomic is natively 768; the cloud
# embed-openai-small-768 route bakes dimensions:768 at the LiteLLM layer).
#
# CRITICAL ORDERING (why this is not a simple env flip): honcho's api AND deriver run a boot-time
# embedding-schema validator (src/main.py lifespan + deriver/__main__.py) that RAISES and
# crash-loops (restart=unless-stopped, no bypass) whenever the configured dim != the physical
# pgvector dim. So we must reconcile the SCHEMA to $dim BEFORE any api boots at $dim. We do that
# with ONE-OFF containers that run the script directly (`--entrypoint /app/.venv/bin/python`,
# because docker/entrypoint.sh hardcodes `fastapi run` and ignores args): provision_db.py (Alembic
# — creates vector(1536) on a fresh volume, no-op otherwise) then configure_embeddings.py (idempotent
# ALTER to $dim; snapshots+replays the exact HNSW indexdef; refuses on non-null embeddings). The
# reconcile is driven off the LIVE pgvector dim (NOT the .env `changed` flag) so a re-run self-heals
# a half-applied state. On a fresh box (api not yet up) we reconcile the schema and let the CALLER
# (Phase 03, after it sets AUTH_USE_AUTH) boot the api at the now-matching dim; on an existing box
# (api up) we recreate the api ourselves so it reloads the new route/dim + re-validates.
# database/redis are NEVER recreated — the database is LiteLLM's keystore SPOF.
# Returns 1 only if honcho isn't installed (no .env). Shared by Phase 03 + Phase 40.
honcho_ensure_embedding_env() {
  local hdir="${AI_STACK:-$HOME/ai-stack}/honcho" envf changed=0
  local myml="${AI_STACK:-$HOME/ai-stack}/installer/models.yml"
  envf="$hdir/.env"
  [[ -f "$envf" ]] || return 1
  # Resolve embedder: HONCHO_EMBED_MODEL override -> models.yml assignment -> embed-openai-small.
  local mkey route dim
  mkey="$(get_env HONCHO_EMBED_MODEL '' 2>/dev/null || true)"
  if [[ -z "$mkey" ]]; then
    if command -v yq >/dev/null 2>&1; then
      mkey="$(yq -r '.embedding_assignments.honcho // ""' "$myml" 2>/dev/null || true)"
    else
      warn "yq not found — cannot read models.yml .embedding_assignments.honcho; using embed-openai-small (schema stays 1536). Install yq to honor the assignment."
    fi
  fi
  [[ -z "$mkey" || "$mkey" == "null" ]] && mkey="embed-openai-small"
  if command -v yq >/dev/null 2>&1; then
    route="$(yq -r ".embeddings[\"$mkey\"].route // \"\"" "$myml" 2>/dev/null || true)"
    dim="$(yq -r ".embeddings[\"$mkey\"].dim // \"\"" "$myml" 2>/dev/null || true)"
  fi
  [[ -z "$route" || "$route" == "null" ]] && route="$mkey"   # key doubles as route for openai-small
  [[ "$dim" =~ ^[0-9]+$ ]] || dim=""
  _hset_embed() {  # KEY VALUE — upsert into honcho/.env; sets changed=1 on modify
    local key="$1" val="$2" cur
    cur="$(grep -E "^${key}=" "$envf" 2>/dev/null | head -1 | cut -d= -f2-)"
    [[ "$cur" == "$val" ]] && return 0
    grep -v "^${key}=" "$envf" > "$envf.tmp" 2>/dev/null || true
    printf '%s=%s\n' "$key" "$val" >> "$envf.tmp"
    mv "$envf.tmp" "$envf"; changed=1
  }
  # Dim-INDEPENDENT env is safe up-front. The dim-COUPLED vars (MODEL/route + VECTOR_DIMENSIONS) are
  # set ONLY AFTER the pgvector schema actually reaches the target dim (via _hset_target_embedder) —
  # otherwise a 768 route on a 1536 schema PASSES honcho's boot validator (schema==VECTOR_DIMENSIONS)
  # yet raises ValueError on EVERY embed (silent breakage, worse than the crash-loop). §24 re-council.
  _hset_embed EMBEDDING_MODEL_CONFIG__TRANSPORT           "openai"
  _hset_embed EMBEDDING_MODEL_CONFIG__OVERRIDES__BASE_URL "http://litellm.ai-stack:4000/v1"
  _hset_embed EMBEDDING_MODEL_CONFIG__DIMENSIONS_MODE     "never"
  _hset_target_embedder() {  # point .env at the $dim route — call ONLY once the schema is at $dim
    _hset_embed EMBEDDING_MODEL_CONFIG__MODEL "$route"
    [[ -n "$dim" ]] && _hset_embed EMBEDDING_VECTOR_DIMENSIONS "$dim"
    chmod 600 "$envf" 2>/dev/null || true
  }
  chmod 600 "$envf" 2>/dev/null || true

  # No live schema to mismatch on these paths -> set the target optimistically + return.
  command -v docker >/dev/null 2>&1 || { _hset_target_embedder; (( changed )) && ok "honcho embedding env -> route '$route' (docker absent; pgvector schema unchanged)."; return 0; }
  { [[ -f "$hdir/docker-compose.yml" ]] || [[ -f "$hdir/compose.yaml" ]] || [[ -f "$hdir/docker-compose.yaml" ]]; } || { _hset_target_embedder; return 0; }
  [[ -n "$dim" ]] || { _hset_target_embedder; (( changed )) && ok "honcho embedding env -> route '$route' (no dim resolved; pgvector schema left as-is)."; return 0; }

  # Was the api already up? existing box -> we recreate it; fresh box -> caller boots it after AUTH.
  local api_was_up=0
  docker ps --format '{{.Names}}' 2>/dev/null | grep -q '^honcho-api' && api_was_up=1

  # DB must be HEALTHY before the one-off provision/configure (they use --no-deps, skipping the compose
  # service_healthy gate; provision has no connect-retry -> a cold Postgres would race). --wait blocks
  # on the pg_isready healthcheck. Fail loudly rather than silently skip the reconcile.
  if ! ( cd "$hdir" && docker compose up -d --wait database redis >/dev/null 2>&1 ); then
    warn "honcho database/redis not healthy (docker compose up --wait failed) — NOT reconciling the pgvector dim; leaving the honcho embedder unchanged so the api stays bootable."
    return 0
  fi
  ( cd "$hdir" && docker compose run --rm --no-deps --entrypoint /app/.venv/bin/python api scripts/provision_db.py >/dev/null 2>&1 ) \
    || warn "honcho provision (alembic) one-off failed — pgvector schema may be absent"

  # Read the LIVE physical pgvector dim (relkind='r' excludes HNSW index relations).
  local cur
  cur="$(docker exec honcho-database-1 psql -U postgres -d postgres -tAc "SELECT DISTINCT regexp_replace(format_type(a.atttypid,a.atttypmod),'[^0-9]','','g') FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE c.relkind='r' AND n.nspname='public' AND c.relname IN ('documents','message_embeddings') AND a.attname='embedding' AND NOT a.attisdropped;" 2>/dev/null | tr -d ' ' | grep -v '^$' | head -1 || true)"
  if [[ -z "$cur" ]]; then
    warn "honcho pgvector schema dim could not be read (DB not ready / schema absent) — NOT reconciling and NOT switching the embedder (avoids booting the api at a mismatched dim)."
    return 0
  fi

  # Reconcile the schema to $dim via a one-off (bypasses the crashing validator). Deriver is quiesced.
  local reconciled=0 altered=0
  if [[ "$cur" == "$dim" ]]; then
    reconciled=1
  else
    log "honcho pgvector dim $cur -> $dim: quiescing deriver + reconciling via scripts/configure_embeddings.py…"
    ( cd "$hdir" && docker compose stop deriver >/dev/null 2>&1 ) || true
    # configure_embeddings.py REFUSES if either table holds a non-null embedding. Those embeddings are
    # DERIVED (regenerable from the messages) — HONCHO_EMBED_FORCE_REINDEX=1 clears them so the migration
    # proceeds (the deriver re-embeds at the new dim). Default is SAFE: refuse + tell the operator.
    if [[ "${HONCHO_EMBED_FORCE_REINDEX:-0}" == "1" ]]; then
      warn "HONCHO_EMBED_FORCE_REINDEX=1 — clearing derived embeddings (documents + message_embeddings) to migrate $cur -> $dim (messages are kept; the deriver re-embeds at the new dim)."
      docker exec honcho-database-1 psql -U postgres -d postgres -c "TRUNCATE TABLE public.documents, public.message_embeddings;" >/dev/null 2>&1 || warn "  truncate failed — configure may still refuse."
    fi
    if ( cd "$hdir" && docker compose run --rm --no-deps -e EMBEDDING_VECTOR_DIMENSIONS="$dim" --entrypoint /app/.venv/bin/python api scripts/configure_embeddings.py --yes >/dev/null 2>&1 ); then
      ok "honcho pgvector schema reconciled $cur -> $dim."; reconciled=1; altered=1
    else
      warn "configure_embeddings.py REFUSED to reconcile $cur -> $dim — honcho holds non-null embeddings at dim=$cur. Honcho is LEFT at its working dim=$cur (assignment '$mkey' NOT applied; doctor check 77 will flag it). To migrate: HONCHO_EMBED_FORCE_REINDEX=1 vz-ai-stack.sh install honcho_mcp (clears the regenerable derived embeddings)."
    fi
  fi

  if (( reconciled )); then
    _hset_target_embedder      # schema is now at $dim -> safe to point the embedder at the $dim route
  else
    dim="$cur"                 # leave the existing (working) embedder untouched so honcho keeps functioning
  fi

  # Recreate the api only if it was up AND something changed (env or schema); always (re)start the deriver.
  if (( api_was_up )); then
    if (( changed || altered )); then
      log "honcho: recreate api at dim=$dim + restart deriver…"
      ( cd "$hdir" && docker compose up -d --force-recreate api >/dev/null 2>&1 ) \
        || warn "honcho api force-recreate failed — reload manually: (cd $hdir && docker compose up -d --force-recreate api)"
      local hb; hb="${HONCHO_BASE_URL:-http://honcho:8000}"
      wait_http "${hb}/health" 60 >/dev/null 2>&1 || wait_http http://127.0.10.6:8000/health 60 >/dev/null 2>&1 || warn "honcho /health slow after reload — check 'docker logs honcho-api-1'"
    fi
    ( cd "$hdir" && docker compose up -d deriver >/dev/null 2>&1 ) || warn "honcho deriver restart failed — start manually: (cd $hdir && docker compose up -d deriver)"
    ok "honcho embedding -> route '$route' (pgvector dim=$dim)."
  else
    ok "honcho embedding env -> route '$route' (pgvector dim=$dim); api boots at this dim on the caller's compose up."
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
