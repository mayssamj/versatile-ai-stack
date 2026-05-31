# PHOENIX_COLLECTOR_HTTP_ENDPOINT non-empty in .env (the most-hit landmine).
CHECKS+=(phoenix_endpoint_set)
CHECK_TITLE[phoenix_endpoint_set]="PHOENIX_COLLECTOR_HTTP_ENDPOINT set in .env"

phoenix_endpoint_set_diagnose() {
  local v; v="$(get_env PHOENIX_COLLECTOR_HTTP_ENDPOINT "")"
  if [[ -z "$v" ]]; then echo "PHOENIX_COLLECTOR_HTTP_ENDPOINT is empty in .env"; return 1; fi
  if [[ "$v" != http://* && "$v" != https://* ]]; then
    echo "PHOENIX_COLLECTOR_HTTP_ENDPOINT is not a valid URL: $v"
    return 1
  fi
}

phoenix_endpoint_set_fix() {
  # Post-refactor (Reviewer Y-16): the correct default is the Docker DNS
  # name on the ai-stack network, not the old host.docker.internal value.
  # LiteLLM reads this env var inside its container; on ai-stack, `phoenix`
  # resolves to the Phoenix container's own internal port 6006.
  set_env PHOENIX_COLLECTOR_HTTP_ENDPOINT "http://phoenix:6006/v1/traces"
  set_env PHOENIX_PROJECT_NAME "ai-stack"
  warn "Wrote defaults. LiteLLM needs restart to pick up new env vars."
  queue_restart litellm
}
