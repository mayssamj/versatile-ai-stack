# Running litellm container actually has PHOENIX_COLLECTOR_HTTP_ENDPOINT in its env.
# (Different from check 04: 04 looks at .env on host; this one looks inside the container.
#  `docker restart` does NOT reload --env-file changes; full recreate is required.)
CHECKS+=(litellm_env_loaded)
CHECK_TITLE[litellm_env_loaded]="LiteLLM container has PHOENIX_COLLECTOR_HTTP_ENDPOINT non-empty"

litellm_env_loaded_diagnose() {
  if ! container_running litellm; then
    echo "litellm not running"
    return 1
  fi
  local v
  v="$(docker exec litellm env 2>/dev/null | awk -F= '$1=="PHOENIX_COLLECTOR_HTTP_ENDPOINT"{print substr($0, length($1)+2); exit}')"
  if [[ -z "$v" ]]; then
    echo "PHOENIX_COLLECTOR_HTTP_ENDPOINT is empty inside the running container"
    return 1
  fi
}

litellm_env_loaded_fix() {
  warn "Container env is set at docker-run time. 'docker restart' will NOT reload --env-file."
  warn "Need full recreate: bash bin/start-litellm.sh --recreate"
  warn "Queuing — conservative mode requires explicit confirmation."
  queue_restart litellm
}
