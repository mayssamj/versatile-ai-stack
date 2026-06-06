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

# Ensure the 'litellm' DATABASE exists — not just that the server is up. Honcho's
# Postgres provides the SERVER on :5432 but only creates the 'postgres' DB;
# NOTHING creates 'litellm' (the DB named in DATABASE_URL). On a fresh/second
# machine that absent DB makes LiteLLM's Prisma block uvicorn startup, so
# /v1/models times out (container Up, :5432 reachable, key OK — but never
# serving). Create it idempotently. Best-effort: if the pg container can't be
# reached by name we warn and let LiteLLM try (no regression vs. prior behaviour).
PG_CTR="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 -iE 'honcho.*(database|postgres|db)' || true)"
[[ -z "$PG_CTR" ]] && PG_CTR="honcho-database-1"
if docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$PG_CTR"; then
  if docker exec "$PG_CTR" psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='litellm'" 2>/dev/null | grep -q 1; then
    ok "Postgres database 'litellm' present"
  else
    log "Postgres database 'litellm' missing — creating it (LiteLLM Prisma key store)..."
    if docker exec "$PG_CTR" psql -U postgres -c "CREATE DATABASE litellm" >/dev/null 2>&1; then
      ok "created Postgres database 'litellm'"
    else
      warn "Could not auto-create 'litellm' DB via '$PG_CTR'. If LiteLLM hangs on boot, create it manually:"
      warn "    docker exec $PG_CTR psql -U postgres -c 'CREATE DATABASE litellm'"
    fi
  fi
else
  warn "Postgres container not found by name ('$PG_CTR') — skipping 'litellm' DB ensure (LiteLLM will attempt a Prisma migrate on boot)."
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
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY "")"
PHOENIX_API_KEY="$(get_env PHOENIX_API_KEY "")"
set -u

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
  --add-host=host.docker.internal:host-gateway \
  -e ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  -e OPENAI_API_KEY="$OPENAI_API_KEY" \
  -e OPENROUTER_API_KEY="$OPENROUTER_API_KEY" \
  -e GOOGLE_API_KEY="$GOOGLE_API_KEY" \
  -e LITELLM_MASTER_KEY="$LITELLM_MASTER_KEY" \
  -e PHOENIX_API_KEY="$PHOENIX_API_KEY" \
  -e PHOENIX_COLLECTOR_HTTP_ENDPOINT="$PHOENIX_ENDPOINT" \
  -e PHOENIX_PROJECT_NAME="$PHOENIX_PROJECT" \
  -e TRACE_FILE=/traces/litellm.jsonl \
  -e GUARDRAILS_AUDIT_FILE=/traces/guardrails.jsonl \
  -e PYTHONPATH=/app/config \
  -e LITELLM_LOG=INFO \
  -e DATABASE_URL="postgresql://postgres:postgres@host.docker.internal:5432/litellm" \
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
      LITELLM_MASTER_KEY PHOENIX_API_KEY

ok "started container: $NAME (http://litellm:${ALIAS_HOST_PORT[litellm]} (= ${ALIAS_IP[litellm]}:${ALIAS_HOST_PORT[litellm]}))"
record "start-litellm: pid=$$ image=$IMAGE PHOENIX_PROJECT=$PHOENIX_PROJECT"
