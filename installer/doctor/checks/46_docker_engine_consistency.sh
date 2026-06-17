# Engine consistency / no split-brain: AMBIENT CLI context, gateway.env, and every
# ai-stack.managed container all live on the SELECTED engine.
CHECKS+=(docker_engine_consistency)
CHECK_TITLE[docker_engine_consistency]="Docker engine consistency (no split-brain)"

docker_engine_consistency_diagnose() {
  source "$AI_STACK/installer/lib/docker-engine.sh"
  local sel; sel="$(get_env AI_STACK_DOCKER_ENGINE "")"
  # No selection → check 47 owns that; pass-as-skip here.
  if [[ -z "$sel" ]] || ! _engine_valid "$sel"; then
    echo "(no engine selected — see check 47)"; return 0
  fi
  local sock; sock="$(engine_socket "$sel" 2>/dev/null || echo '')"
  [[ -n "$sock" ]] || { echo "cannot resolve socket for selected engine '$sel'"; return 1; }

  local bad=0
  # (a) The USER'S AMBIENT context (what their OTHER shells see) resolves to the
  # selected engine. Measure with env -u DOCKER_HOST so we do NOT just validate the
  # var doctor itself exported (which would always equal $sock — a self-defeating check).
  local ctx_host
  ctx_host="$(env -u DOCKER_HOST docker context inspect "$(env -u DOCKER_HOST docker context show 2>/dev/null)" \
                --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || echo '')"
  if [[ -n "$ctx_host" && "$ctx_host" != "$sock" ]]; then
    echo "ambient docker context socket ($ctx_host) != selected ($sock) — other shells use a different engine"; bad=1
  fi
  # (b) gateway.env DOCKER_HOST == selected socket.
  local gw; gw="$(grep -E '^DOCKER_HOST=' "$HOME/.config/openshell/gateway.env" 2>/dev/null | tail -1 | cut -d= -f2- || echo '')"
  if [[ -n "$gw" && "$gw" != "$sock" ]]; then
    echo "gateway.env DOCKER_HOST ($gw) != selected ($sock)"; bad=1
  fi
  # (c) REAL stranded-container detection: enumerate every OTHER installed+running
  # engine's socket and look for ai-stack.managed containers living there. If any
  # are found on a NON-selected engine, that is split-brain → fail with guidance.
  local other osock stranded=""
  for other in $ENGINE_IDS; do
    [[ "$other" == "$sel" ]] && continue
    engine_installed "$other" || continue
    engine_running "$other"   || continue
    osock="$(engine_socket "$other" 2>/dev/null || echo '')"; [[ -n "$osock" ]] || continue
    local found
    found="$(_engine_docker_timeout 6 docker -H "$osock" ps -a \
              --filter label=ai-stack.managed=true --format '{{.Names}}' 2>/dev/null | tr '\n' ' ' || true)"
    [[ -n "${found// }" ]] && stranded+="  on $other ($(engine_display "$other")): ${found% }"$'\n'
  done
  if [[ -n "$stranded" ]]; then
    echo "ai-stack.managed container(s) STRANDED on a non-selected engine:"; printf '%s' "$stranded"; bad=1
  fi
  return $bad
}

docker_engine_consistency_fix() {
  source "$AI_STACK/installer/lib/docker-engine.sh"
  local sel; sel="$(get_env AI_STACK_DOCKER_ENGINE "")"
  [[ -n "$sel" ]] && _engine_valid "$sel" || { err "no valid engine selected — run check 47 fix"; return 1; }
  # Re-pin: rewrites gateway.env + exports DOCKER_HOST. Does NOT touch containers.
  engine_pin "$sel" || return 1
  warn "Re-pinned gateway.env + DOCKER_HOST to '$sel'."
  warn "If managed containers are stranded in ANOTHER engine, this does NOT move them:"
  warn "  - re-pin to where they live (vz-ai-stack.sh docker-engine set <that-engine>), OR"
  warn "  - guided recreate on the selected engine (re-run the relevant install phase)."
  warn "Never auto-destroyed (conservative recreate_guard philosophy)."
  return 0
}
