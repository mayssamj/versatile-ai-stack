# PHOENIX_API_KEY is set in .env if Phoenix has auth enabled.
# Without this, LiteLLM's OTLP exporter gets 401 from Phoenix and traces
# silently never land. Detected by the "Failed to export batch code: 401"
# line in litellm logs.
CHECKS+=(phoenix_api_key)
CHECK_TITLE[phoenix_api_key]="PHOENIX_API_KEY set (auth-on Phoenix needs it to accept OTLP)"

phoenix_api_key_diagnose() {
  # Only relevant if Phoenix is running with auth ON.
  container_running phoenix || return 0
  # Probe auth state — if /v1/projects returns 401, auth is on.
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://phoenix:6006/v1/projects 2>/dev/null)"
  if [[ "$status" != "401" ]]; then
    # Auth off (or another response) — PHOENIX_API_KEY not required.
    return 0
  fi
  local key; key="$(get_env PHOENIX_API_KEY "")"
  if [[ -z "$key" ]]; then
    echo "Phoenix has auth ON but PHOENIX_API_KEY is empty in .env."
    echo "Symptom: litellm logs show 'Failed to export batch code: 401, reason: Invalid token'."
    echo "Fix: log in to http://phoenix:6006 → Settings → API Keys → create key, then paste into .env."
    return 1
  fi
  # If PHOENIX_API_KEY exists in .env but litellm logs still show 401s in the last 5 min:
  if container_running litellm; then
    if docker logs --since 5m litellm 2>&1 | grep -q "Failed to export batch code: 401"; then
      echo "PHOENIX_API_KEY in .env but litellm STILL getting 401 — env var not reaching container."
      echo "Fix: bash bin/start-litellm.sh --recreate"
      return 1
    fi
  fi
}

phoenix_api_key_fix() {
  warn "Cannot auto-generate Phoenix API keys via API. Manual step:"
  warn "  1. open http://phoenix:6006"
  warn "  2. log in (admin@localhost / your password)"
  warn "  3. Settings → API Keys → create a new key"
  warn "  4. paste into .env:  PHOENIX_API_KEY=<key>"
  warn "  5. bash install.sh apply-restarts   # picks up the new var in litellm"
  return 1
}
