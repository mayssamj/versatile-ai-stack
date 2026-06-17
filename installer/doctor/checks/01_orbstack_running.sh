# Selected Docker engine reachable.
CHECKS+=(orbstack_running)
CHECK_TITLE[orbstack_running]="Selected Docker engine reachable"

orbstack_running_diagnose() {
  source "$AI_STACK/installer/lib/docker-engine.sh"
  local sel; sel="$(get_env AI_STACK_DOCKER_ENGINE "")"
  if [[ -z "$sel" ]]; then
    # No selection yet: fall back to the legacy any-daemon probe so a
    # fresh/local-only box is not red before first selection — but WARN loudly
    # that an unpinned engine is a split-brain risk (selection should have run
    # in Phase 00 preflight). Not a hard failure (return 0) so a brand-new box
    # is not red, but the message is a hard warn, not a silent green.
    docker info >/dev/null 2>&1 || { echo "no engine selected and docker info failed (run: vz-ai-stack.sh docker-engine select)"; return 1; }
    echo "WARN: no engine pinned (AI_STACK_DOCKER_ENGINE empty) — split-brain risk; ambient docker reachable. Pin: vz-ai-stack.sh docker-engine select"
    return 0
  fi
  _engine_valid "$sel" || { echo "AI_STACK_DOCKER_ENGINE='$sel' invalid"; return 1; }
  if ! engine_running "$sel"; then
    echo "selected engine '$sel' ($(engine_display "$sel")) not reachable on $(engine_socket "$sel" 2>/dev/null || echo '?')"
    return 1
  fi
}

orbstack_running_fix() {
  source "$AI_STACK/installer/lib/docker-engine.sh"
  local sel; sel="$(get_env AI_STACK_DOCKER_ENGINE "")"
  [[ -n "$sel" ]] || sel="$(engine_select)" || return 1
  engine_ensure "$sel" || return 1
  engine_pin "$sel" || return 1
}
