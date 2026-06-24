#!/usr/bin/env bash
# start-litellm.sh — managed start for LiteLLM with the canonical flag order.
#
# Idempotency: refuses to silently `docker rm -f` an existing container.
# Pass --recreate to backup-and-recreate (LiteLLM is stateless; no real backup
# is needed, but the flag is required so a typo doesn't nuke a working setup).
#
# Networking (post-refactor): joins `ai-stack` bridge network, binds to alias IP
# 127.0.10.1 (alias `litellm`) on host port 80 → container 4000. Reaches Ollama
# on the host via `--add-host=ollama:host-gateway`. Phoenix is dialed
# container-to-container via Docker DNS as http://phoenix:6006.
#
# Phoenix wiring: PHOENIX_COLLECTOR_HTTP_ENDPOINT and PHOENIX_PROJECT_NAME
# are required AND non-empty before this script will start LiteLLM. Empty
# values default to http://phoenix:6006/v1/traces / ai-stack.
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "bin/start-litellm.sh: needs bash 5+" >&2; exit 2
fi

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker-engine.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/network.sh"
aliases_load

NAME=litellm
PHASE=01
IMAGE=ghcr.io/berriai/litellm:main-stable
RECREATE_FLAG="${1:-}"

# Preconditions — abort early on missing files.
[[ -f "$AI_STACK/litellm/config.yaml" ]] || { err "litellm/config.yaml missing — run phase 01 first."; exit 1; }
[[ -f "$AI_STACK/litellm/trace_to_file.py" ]] || { err "litellm/trace_to_file.py missing — run phase 01 first."; exit 1; }
[[ -f "$AI_STACK/.env" ]] || { err ".env missing"; exit 1; }

# Validate .env doesn't have CRLF / malformed lines (docker --env-file is fussy).
load_env_strict || { err ".env has malformed lines; fix or run 'vz-ai-stack.sh doctor'."; exit 1; }

# Networking precondition: ai-stack network must exist (run Phase 00·N).
network_ensure_ai_stack || {
  err "ai-stack docker network missing. Run:  bash vz-ai-stack.sh install 00n"
  exit 1
}

# Fill defaults loudly. require_env errors out if no default and value missing.
PHOENIX_ENDPOINT="$(require_env PHOENIX_COLLECTOR_HTTP_ENDPOINT http://phoenix:6006/v1/traces)"
PHOENIX_PROJECT="$(require_env PHOENIX_PROJECT_NAME ai-stack)"

# LiteLLM's virtual-key store uses Prisma → Postgres on
# host.docker.internal:5432 (provided by the Honcho compose stack —
# `honcho-database-1`). On a cold install LiteLLM hangs uvicorn startup
# for 60s+ waiting for Prisma migrations to apply, then Phase 01 times out
# with a vague "did not come up" error. Failing loudly here catches the
# real cause before the hang. See CHANGELOG 2026-05-30. vz-ai-stack.sh now
# orders Phase 03 (Honcho) before Phase 01 (LiteLLM) to prevent this.
if ! nc -z 127.0.0.1 5432 2>/dev/null \
   && ! (echo > /dev/tcp/127.0.0.1/5432) 2>/dev/null; then
  err "Postgres at host.docker.internal:5432 is not reachable."
  err "LiteLLM needs Postgres for its Prisma-managed virtual-key store."
  err "Postgres is provided by the Honcho compose stack."
  err "Fix: run Phase 03 first:"
  err "    bash $AI_STACK/vz-ai-stack.sh install 03"
  err "Then retry: bash $AI_STACK/vz-ai-stack.sh install 01"
  exit 1
fi
ok "Postgres reachable on :5432 — LiteLLM can connect to its key store"

# Single source of truth for the LiteLLM key-store DB identity. The grant logic
# below AND the container's DATABASE_URL (built further down from these vars) both
# derive from PG_USER/PG_PASS/PG_DB, so the role we grant to can never silently
# diverge from the role LiteLLM actually connects as. PG_USER must be a LOGIN role
# on the honcho Postgres.
PG_USER="postgres"; PG_PASS="postgres"; PG_DB="litellm"
DATABASE_URL="postgresql://${PG_USER}:${PG_PASS}@host.docker.internal:5432/${PG_DB}"

# Ensure the '$PG_DB' DATABASE exists AND that '$PG_USER' (the role LiteLLM
# connects as) OWNS it and can CREATE in its `public` schema. Honcho's Postgres
# provides the SERVER on :5432 + the 'postgres' DB only; nothing creates '$PG_DB'.
# A bare CREATE DATABASE is NOT enough on PG15+/wolfi-based images: the locked-down
# `public` schema denies the login role CREATE unless it owns the DB, so Prisma's
# `migrate deploy` fails with "P1010: User `postgres` was denied access on the
# database `litellm.public`" and LiteLLM never serves /v1/models (container Up,
# :5432 reachable, key OK — but timing out). So we (1) create the DB if missing,
# (2) idempotently grant ownership + public-schema rights — which also REPAIRS a
# DB left by an earlier create-only version — then (3) PROVE the connecting role
# can actually CREATE in public before reporting success. Best-effort: if the pg
# container can't be reached by name we warn and let LiteLLM try (no regression).
PG_CTR="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 -iE 'honcho.*(database|postgres|db)' || true)"
[[ -z "$PG_CTR" ]] && PG_CTR="honcho-database-1"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CTR"; then
  if ! docker exec "$PG_CTR" psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$PG_DB'" 2>/dev/null | grep -q 1; then
    log "Postgres database '$PG_DB' missing — creating it (LiteLLM Prisma key store)..."
    docker exec "$PG_CTR" psql -U postgres -c "CREATE DATABASE $PG_DB" >/dev/null 2>&1 \
      || warn "Could not create '$PG_DB' DB via '$PG_CTR' (will still attempt grants below)."
  fi
  # Idempotent ownership + public-schema grant for the DATABASE_URL role.
  # No-op when already satisfied; fixes the P1010 'denied on public' case on a DB
  # that exists but isn't owned/usable by the connecting role. Each guarded so a
  # benign failure never aborts the start — we do NOT trust these exit codes (a
  # non-superuser ALTER OWNER can fail silently), we PROVE the end state below.
  docker exec "$PG_CTR" psql -U postgres -c "ALTER DATABASE $PG_DB OWNER TO $PG_USER;"               >/dev/null 2>&1 || true
  docker exec "$PG_CTR" psql -U postgres -c "GRANT ALL PRIVILEGES ON DATABASE $PG_DB TO $PG_USER;"   >/dev/null 2>&1 || true
  docker exec "$PG_CTR" psql -U postgres -d "$PG_DB" -c "GRANT ALL ON SCHEMA public TO $PG_USER;"    >/dev/null 2>&1 || true
  # PROVE it: can $PG_USER actually CREATE in $PG_DB.public? That is the exact
  # privilege Prisma needs and the exact one P1010 denies. The probe runs inside a
  # transaction that ROLLs BACK, so it verifies the grant without leaving any
  # artifact (a TEMP table would land in pg_temp, NOT public, and wouldn't test it).
  if docker exec "$PG_CTR" psql -U "$PG_USER" -d "$PG_DB" -v ON_ERROR_STOP=1 \
       -qtAc "BEGIN; CREATE TABLE _litellm_grant_probe (x int); ROLLBACK;" >/dev/null 2>&1; then
    ok "Postgres '$PG_DB' DB present + '$PG_USER' verified able to CREATE in public (Prisma-ready)"
  elif docker exec "$PG_CTR" psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='$PG_DB'" 2>/dev/null | grep -q 1; then
    warn "Postgres '$PG_DB' DB exists but '$PG_USER' still CANNOT create in its public schema —"
    warn "Prisma will likely fail with P1010. Run these as a Postgres superuser, then retry:"
    warn "    docker exec $PG_CTR psql -U postgres -c 'ALTER DATABASE $PG_DB OWNER TO $PG_USER'"
    warn "    docker exec $PG_CTR psql -U postgres -c 'GRANT ALL PRIVILEGES ON DATABASE $PG_DB TO $PG_USER'"
    warn "    docker exec $PG_CTR psql -U postgres -d $PG_DB -c 'GRANT ALL ON SCHEMA public TO $PG_USER'"
  else
    warn "Could not ensure '$PG_DB' DB via '$PG_CTR'. Create + grant manually, then retry:"
    warn "    docker exec $PG_CTR psql -U postgres -c 'CREATE DATABASE $PG_DB'"
    warn "    docker exec $PG_CTR psql -U postgres -c 'ALTER DATABASE $PG_DB OWNER TO $PG_USER'"
    warn "    docker exec $PG_CTR psql -U postgres -d $PG_DB -c 'GRANT ALL ON SCHEMA public TO $PG_USER'"
  fi
else
  warn "Postgres container not found by name ('$PG_CTR') — skipping '$PG_DB' DB ensure (LiteLLM will attempt a Prisma migrate on boot)."
fi

# Guard: refuse silent recreate.
recreate_guard "$NAME" "$RECREATE_FLAG" || exit 1

ensure_image "$IMAGE"

mkdir -p "$AI_STACK/traces" "$AI_STACK/guardrails"

# Per-service env injection (Reviewer Y-7). We pass ONLY the keys LiteLLM
# actually needs — provider keys for the configured models, the master key,
# and Phoenix wiring. The other ~8 keys in .env (BLAXEL_*, GITHUB_TOKEN,
# HONCHO_*, etc.) STAY OUT of LiteLLM's environment so a container compromise
# cannot leak them via `docker inspect`.
#
# Reading is host-side: source into local vars but never echo, never log.
set +u
ANTHROPIC_API_KEY="$(get_env ANTHROPIC_API_KEY "")"
OPENAI_API_KEY="$(get_env OPENAI_API_KEY "")"
OPENROUTER_API_KEY="$(get_env OPENROUTER_API_KEY "")"
GOOGLE_API_KEY="$(get_env GOOGLE_API_KEY "")"
SAKANA_API_KEY="$(get_env SAKANA_API_KEY "")"
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY "")"
PHOENIX_API_KEY="$(get_env PHOENIX_API_KEY "")"
set -u

# Engine-derived host.docker.internal add-host (LiteLLM dials Postgres at
# host.docker.internal:5432). OrbStack/Docker Desktop auto-inject it (so this is
# empty + the flag is omitted); Colima/Podman need it explicitly. Sourced from the
# engine registry — never hardcoded — so it is correct on every engine + honest.
HDI_ADDHOST=()
_litellm_eng="$(get_env AI_STACK_DOCKER_ENGINE orbstack)"
# Guard on declare -F too (matching docker.sh) — defense-in-depth if source order
# ever changes and the engine registry is not yet loaded.
if declare -F engine_addhost_args >/dev/null 2>&1 && _engine_valid "$_litellm_eng" 2>/dev/null; then
  _litellm_ah="$(engine_addhost_args "$_litellm_eng" 2>/dev/null || true)"
  [[ -n "$_litellm_ah" ]] && HDI_ADDHOST=("$_litellm_ah")
fi

# Canonical flag order: --network/--add-host, then -e..., then -p, then -v, then --restart, then IMAGE, then CMD.
# NOTE: litellm/ mount is RO (Reviewer Y-8). Container cannot tamper with
# config.yaml or the custom callbacks at runtime.
docker run -d \
  --name "$NAME" \
  --label "ai-stack.managed=true" \
  --label "ai-stack.phase=$PHASE" \
  --label "ai-stack.partial=true" \
  --restart unless-stopped \
  --network ai-stack \
  --add-host=ollama:host-gateway \
  "${HDI_ADDHOST[@]}" \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  -e OPENAI_API_KEY="$OPENAI_API_KEY" \
  -e OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
  -e GOOGLE_API_KEY="$GOOGLE_API_KEY" \
  -e SAKANA_API_KEY="$SAKANA_API_KEY" \
  -e LITELLM_MASTER_KEY="$LITELLM_MASTER_KEY" \
  -e PHOENIX_API_KEY="$PHOENIX_API_KEY" \
  -e PHOENIX_COLLECTOR_HTTP_ENDPOINT="$PHOENIX_ENDPOINT" \
  -e PHOENIX_PROJECT_NAME="$PHOENIX_PROJECT" \
  -e TRACE_FILE=/traces/litellm.jsonl \
  -e GUARDRAILS_AUDIT_FILE=/traces/guardrails.jsonl \
  -e PYTHONPATH=/app/config \
  -e LITELLM_LOG=INFO \
  -e DATABASE_URL="$DATABASE_URL" \
  -e STORE_MODEL_IN_DB=False \
  -p "${ALIAS_IP[litellm]}":"${ALIAS_HOST_PORT[litellm]}":"${ALIAS_CONTAINER_PORT[litellm]}" \
  -p 127.0.0.1:"${ALIAS_HOST_PORT[litellm]}":"${ALIAS_CONTAINER_PORT[litellm]}" \
  -v "$AI_STACK/litellm:/app/config:ro" \
  -v "$AI_STACK/traces:/traces" \
  -v "$AI_STACK/guardrails:/guardrails:ro" \
  "$IMAGE" \
  --config /app/config/config.yaml \
  >/dev/null

# Clear local copies of secrets ASAP.
unset ANTHROPIC_API_KEY OPENAI_API_KEY OPENROUTER_API_KEY GOOGLE_API_KEY \
      SAKANA_API_KEY LITELLM_MASTER_KEY PHOENIX_API_KEY

ok "started container: $NAME (http://litellm:${ALIAS_HOST_PORT[litellm]} (= ${ALIAS_IP[litellm]}:${ALIAS_HOST_PORT[litellm]}))"
record "start-litellm: pid=$$ image=$IMAGE PHOENIX_PROJECT=$PHOENIX_PROJECT"
