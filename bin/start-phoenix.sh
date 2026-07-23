#!/usr/bin/env bash
# start-phoenix.sh — managed start for Phoenix.
#
# Auth is OFF in this build (PHOENIX_ENABLE_AUTH=false). Rationale:
#  - Single-developer local install, no multi-user/team scenario.
#  - Phoenix binds only to 127.0.10.2 (loopback alias) — never LAN-exposed.
#  - Auth-on required a manual UI step (mint API key, paste into .env)
#    that broke "zero manual setup". Phoenix doesn't expose key creation
#    via an unauthenticated API, so it can't be automated cleanly.
#  - Without auth, LiteLLM's OTLP push works on first try and the
#    ai-stack project auto-creates on first trace.
# PHOENIX_SECRET still signs session tokens (Phoenix internal); ≥32 chars.
#
# Networking (post-refactor): single container exposes TWO endpoints on the
# ai-stack network — alias `phoenix` (UI/HTTP-OTLP, 127.0.10.2:80 → :6006) AND
# alias `phoenix-otlp` (gRPC OTLP, 127.0.10.3:4317 → :4317). Container --name
# stays `phoenix`; phoenix-otlp is a host-side /etc/hosts alias on a separate
# loopback IP, not a Docker DNS alias.
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "bin/start-phoenix.sh: needs bash 5+" >&2; exit 2
fi

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/network.sh"
aliases_load

NAME=phoenix
PHASE=01h
IMAGE=arizephoenix/phoenix:latest
RECREATE_FLAG="${1:-}"

[[ -f "$AI_STACK/.env" ]] || { err ".env missing"; exit 1; }
load_env_strict || { err ".env has malformed lines; run 'mayssam-ai-stack.sh doctor'."; exit 1; }

# Networking precondition: ai-stack network must exist (run Phase 00·N).
network_ensure_ai_stack || {
  err "ai-stack docker network missing. Run:  bash mayssam-ai-stack.sh install 00n"
  exit 1
}

# PHOENIX_SECRET is mandatory; auto-generate if missing/empty.
SECRET="$(get_env PHOENIX_SECRET "")"
if [[ -z "$SECRET" ]]; then
  warn "PHOENIX_SECRET empty; generating one and writing back to .env"
  SECRET="$(openssl rand -hex 32)"
  set_env PHOENIX_SECRET "$SECRET"
fi
# Validate: ≥32 chars, ≥1 digit + ≥1 lowercase.
if (( ${#SECRET} < 32 )) || ! [[ "$SECRET" =~ [0-9] ]] || ! [[ "$SECRET" =~ [a-z] ]]; then
  err "PHOENIX_SECRET fails policy (≥32 chars, ≥1 digit, ≥1 lowercase). Regenerate."
  exit 1
fi

recreate_guard "$NAME" "$RECREATE_FLAG" || exit 1
ensure_image "$IMAGE"
mkdir -p "$AI_STACK/data/phoenix"

# Per-service env injection (Reviewer Y-7). Phoenix only needs its own
# SECRET; we never pass provider keys, master keys, or any other secrets.
docker run -d \
  --name "$NAME" \
  --label "ai-stack.managed=true" \
  --label "ai-stack.phase=$PHASE" \
  --label "ai-stack.partial=true" \
  --restart unless-stopped \
  --network ai-stack \
  --add-host=ollama:host-gateway \
  -e PHOENIX_WORKING_DIR=/mnt/data \
  -e PHOENIX_ENABLE_AUTH=false \
  -e PHOENIX_SECRET="$SECRET" \
  -p "${ALIAS_IP[phoenix]}":"${ALIAS_HOST_PORT[phoenix]}":"${ALIAS_CONTAINER_PORT[phoenix]}" \
  -p "${ALIAS_IP[phoenix-otlp]}":"${ALIAS_HOST_PORT[phoenix-otlp]}":"${ALIAS_CONTAINER_PORT[phoenix-otlp]}" \
  -v "$AI_STACK/data/phoenix:/mnt/data" \
  "$IMAGE" \
  >/dev/null

ok "started container: $NAME (UI http://phoenix:${ALIAS_HOST_PORT[phoenix]}, OTLP gRPC http://phoenix-otlp:${ALIAS_HOST_PORT[phoenix-otlp]})"
note "Auth is OFF (loopback-only deployment); no login or API key needed."
record "start-phoenix: pid=$$ image=$IMAGE"
