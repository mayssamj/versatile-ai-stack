#!/usr/bin/env bash
# Phase 01·H — Phoenix observability.
#
# Drops bin/start-phoenix.sh (already shipped) and starts (or detects foreign)
# the container. Adds `arize_phoenix` to LiteLLM callbacks list iff missing.
#
# Conservative-recreate: if LiteLLM is foreign, we do NOT recreate it just
# because we mutated config.yaml — we queue a restart instead.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/validate.sh"
source "$AI_STACK/installer/lib/litellm.sh"

PHASE=01h

precheck() {
  # PHOENIX_SECRET non-empty & policy-compliant.
  local sec; sec="$(get_env PHOENIX_SECRET "")"
  [[ -n "$sec" && ${#sec} -ge 32 ]] || return 1
  [[ "$sec" =~ [0-9] && "$sec" =~ [a-z] ]] || return 1
  # Phoenix UI returns 200 — try alias first, fall back to loopback IP.
  local ep="${PHOENIX_BASE_URL:-$(get_env PHOENIX_BASE_URL http://phoenix:6006)}"
  wait_http "$ep" 5 || wait_http http://127.0.10.2 5 || return 1
  # arize_phoenix in callbacks.
  litellm_has_callback "arize_phoenix" || return 1
  # Network membership: phoenix container on ai-stack bridge (when managed).
  if container_running phoenix && container_managed phoenix; then
    docker inspect phoenix --format '{{json .NetworkSettings.Networks}}' \
      | grep -q '"ai-stack"' || return 1
  fi
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (phoenix observability)"
  exit 0
fi

hdr "Phase 01·H — Phoenix observability"

# --- Generate PHOENIX_SECRET if absent ---
SECRET="$(get_env PHOENIX_SECRET "")"
if [[ -z "$SECRET" ]]; then
  log "Generating PHOENIX_SECRET (JWT signing key)..."
  SECRET="$(openssl rand -hex 32)"
  set_env PHOENIX_SECRET "$SECRET"
fi

# --- Start (or report foreign) Phoenix ---
if container_running phoenix; then
  if container_managed phoenix; then
    ok "phoenix container already running and managed"
  else
    warn "phoenix is running but FOREIGN."
    warn "Run:  bash vz-ai-stack.sh adopt phoenix   to take ownership."
  fi
else
  log "Starting Phoenix..."
  bash "$AI_STACK/bin/start-phoenix.sh"
  # Try alias first (post-refactor), then loopback fallback.
  PHOENIX_SMOKE="${PHOENIX_BASE_URL:-$(get_env PHOENIX_BASE_URL http://phoenix:6006)}"
  wait_http "$PHOENIX_SMOKE" 60 || wait_http http://127.0.10.2 60 \
    || { err "Phoenix UI didn't come up"; exit 1; }
fi

# --- Wire LiteLLM callbacks ---
log "Ensuring arize_phoenix is in litellm callbacks..."
PHOENIX_CB_BEFORE="$(litellm_has_callback arize_phoenix && echo "present" || echo "missing")"
litellm_ensure_callback "arize_phoenix" || exit 1

if [[ "$PHOENIX_CB_BEFORE" == "missing" ]]; then
  # config.yaml changed → litellm needs a restart to pick up the new callback.
  # Conservative: queue, don't auto-recreate.
  queue_restart litellm
  warn "litellm config.yaml updated. Queued restart (run: vz-ai-stack.sh apply-restarts)."
fi

# --- Verify Phoenix env vars are correct in .env ---
# Post-refactor: LiteLLM (in container) reaches Phoenix via Docker DNS at
# http://phoenix:6006/v1/traces — native HTTP-OTLP port, not the host alias.
ep="$(get_env PHOENIX_COLLECTOR_HTTP_ENDPOINT "")"
pn="$(get_env PHOENIX_PROJECT_NAME "")"
if [[ "$ep" != "http://phoenix:6006/v1/traces" ]]; then
  warn "PHOENIX_COLLECTOR_HTTP_ENDPOINT is '$ep' (expected http://phoenix:6006/v1/traces)"
fi
[[ -z "$pn" ]] && set_env PHOENIX_PROJECT_NAME ai-stack

stamp_mark "$PHASE"
record "phase 01·H complete: phoenix running, arize_phoenix in callbacks (was $PHOENIX_CB_BEFORE)"
ok "Phase 01·H — Phoenix observability — complete"
note "First login (web UI): admin@localhost / admin → forced password reset."
note "Open:  http://phoenix:6006  (or http://127.0.10.2 if alias not yet active)"
