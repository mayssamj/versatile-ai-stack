# host.docker.internal resolves from inside containers (engine-aware).
CHECKS+=(host_docker_internal)
CHECK_TITLE[host_docker_internal]="host.docker.internal resolves inside containers"

host_docker_internal_diagnose() {
  source "$AI_STACK/installer/lib/docker-engine.sh"
  local sel addhost=()
  sel="$(get_env AI_STACK_DOCKER_ENGINE "" 2>/dev/null || true)"
  if [[ -n "$sel" ]] && _engine_valid "$sel"; then
    local ah; ah="$(engine_addhost_args "$sel" 2>/dev/null || true)"
    [[ -n "$ah" ]] && addhost=("$ah")
  fi
  docker run --rm "${addhost[@]}" alpine getent hosts host.docker.internal >/dev/null 2>&1 \
    || { echo "host.docker.internal does not resolve (engine: ${sel:-<none>})"; return 1; }
}

host_docker_internal_fix() {
  source "$AI_STACK/installer/lib/docker-engine.sh"
  local sel; sel="$(get_env AI_STACK_DOCKER_ENGINE "" 2>/dev/null || true)"
  if [[ -n "$sel" ]] && [[ "$(engine_addhost_args "$sel" 2>/dev/null || true)" == --add-host* ]]; then
    err "On $(engine_display "$sel"), managed runs apply --add-host=host.docker.internal:host-gateway automatically."
    err "If a raw container still cannot resolve it, add that flag to its 'docker run'."
    return 1
  fi
  err "Cannot auto-fix — OrbStack/Docker Desktop networking issue."
  err "Check the engine's Settings → Network → enable host networking."
  return 1
}
