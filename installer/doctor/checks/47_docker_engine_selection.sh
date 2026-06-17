# Engine selection present & valid: AI_STACK_DOCKER_ENGINE set + still installed.
CHECKS+=(docker_engine_selection)
CHECK_TITLE[docker_engine_selection]="Docker engine selection present & valid"

docker_engine_selection_diagnose() {
  source "$AI_STACK/installer/lib/docker-engine.sh"
  local sel; sel="$(get_env AI_STACK_DOCKER_ENGINE "" 2>/dev/null || true)"
  if [[ -z "$sel" ]]; then
    echo "AI_STACK_DOCKER_ENGINE not set (run: vz-ai-stack.sh docker-engine select)"; return 1
  fi
  if ! _engine_valid "$sel"; then
    echo "AI_STACK_DOCKER_ENGINE='$sel' is not a valid id (want: $ENGINE_IDS)"; return 1
  fi
  if ! engine_installed "$sel"; then
    echo "selected engine '$sel' ($(engine_display "$sel")) is no longer installed"; return 1
  fi
  return 0
}

docker_engine_selection_fix() {
  source "$AI_STACK/installer/lib/docker-engine.sh"
  local sel; sel="$(engine_select)" || return 1
  engine_ensure "$sel" || return 1
  engine_pin "$sel" || return 1
}
