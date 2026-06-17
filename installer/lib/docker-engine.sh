# docker-engine.sh — the Docker-engine registry: single source of truth for
# per-engine probes, sockets, and host.docker.internal handling.
# Sourced after common.sh + env.sh (engine_socket/engine_select need get_env/set_env).
#
# Value space of AI_STACK_DOCKER_ENGINE (.env): orbstack | docker-desktop | colima | podman
# All `docker -H … info` probes are timeout-bounded so a wedged daemon never hangs us.

[[ -z "${AI_STACK:-}" ]] && { echo "docker-engine.sh: AI_STACK unset" >&2; exit 2; }

# Priority order is also the NO_PROMPT tie-break order (spec §key-decisions 3).
ENGINE_IDS="orbstack docker-desktop colima podman"

# _engine_valid <id> — exit 0 if id is one of ENGINE_IDS.
_engine_valid() {
  local id="$1" e
  for e in $ENGINE_IDS; do [[ "$e" == "$id" ]] && return 0; done
  return 1
}

# engine_display <id> — human label.
engine_display() {
  case "$1" in
    orbstack)       printf '%s' "OrbStack" ;;
    docker-desktop) printf '%s' "Docker Desktop" ;;
    colima)         printf '%s' "Colima" ;;
    podman)         printf '%s' "Podman" ;;
    *) err "engine_display: unknown engine id: $1"; return 2 ;;
  esac
}

# engine_addhost_args <id> — emit the host.docker.internal flag ONLY for engines
# that do not auto-inject it (Colima, Podman). OrbStack/Docker Desktop: nothing.
engine_addhost_args() {
  case "$1" in
    orbstack|docker-desktop) : ;;   # auto-injected; emit nothing
    colima|podman)           printf '%s' "--add-host=host.docker.internal:host-gateway" ;;
    *) err "engine_addhost_args: unknown engine id: $1"; return 2 ;;
  esac
}

# _engine_docker_timeout <secs> -- <cmd...> — run a docker probe with a hard cap.
# macOS ships no coreutils `timeout`; use a background pid + kill fallback.
_engine_docker_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"; return $?
  fi
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
  local killer=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill -TERM "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  return $rc
}

# engine_socket <id> — echo the resolved DOCKER_HOST value (unix://… or tcp://…).
# Probed/derived, never blindly assumed. Returns 1 (empty) if unresolvable.
engine_socket() {
  local id="$1"
  _engine_valid "$id" || { err "engine_socket: unknown engine id: $id"; return 2; }
  case "$id" in
    orbstack)
      printf '%s' "unix://$HOME/.orbstack/run/docker.sock"
      ;;
    docker-desktop)
      # Prefer Docker Desktop's own context endpoint as source of truth.
      # WRAPPED in the timeout so a wedged docker CLI cannot hang the central export.
      local ep
      ep="$(_engine_docker_timeout 6 docker context inspect desktop-linux \
              --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || true)"
      if [[ -n "$ep" ]]; then printf '%s' "$ep"; return 0; fi
      if [[ -S "$HOME/.docker/run/docker.sock" ]]; then
        printf '%s' "unix://$HOME/.docker/run/docker.sock"; return 0
      fi
      if [[ -S /var/run/docker.sock ]]; then
        printf '%s' "unix:///var/run/docker.sock"; return 0
      fi
      return 1
      ;;
    colima)
      # `colima status` prints a `socket:` line; fall back to the conventional path.
      # WRAPPED in the timeout — a wedged colima CLI must not hang the export.
      local sock
      sock="$(_engine_docker_timeout 6 colima status 2>&1 | awk -F': *' '/[Ss]ocket:/{print $2; exit}' || true)"
      if [[ "$sock" == unix://* ]]; then printf '%s' "$sock"; return 0; fi
      local conv="$HOME/.colima/${COLIMA_PROFILE:-default}/docker.sock"
      if [[ -S "$conv" ]]; then printf '%s' "unix://$conv"; return 0; fi
      log "engine_socket colima: socket path ASSUMED ($conv) — unverified on this host"
      return 1
      ;;
    podman)
      # PodmanSocket.Path speaks the Docker API (podman 5.x). UNVERIFIED on this box.
      # WRAPPED in the timeout — podman machine inspect can hang on a wedged VM.
      local p
      p="$(_engine_docker_timeout 6 podman machine inspect \
             --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || true)"
      if [[ -n "$p" && -S "$p" ]]; then printf '%s' "unix://$p"; return 0; fi
      log "engine_socket podman: socket path ASSUMED via 'podman machine inspect' — unverified on this host"
      return 1
      ;;
  esac
}

# engine_installed <id> — exit 0 if the engine's app/binary is present.
engine_installed() {
  local id="$1"
  _engine_valid "$id" || { err "engine_installed: unknown engine id: $id"; return 2; }
  case "$id" in
    orbstack)
      [[ -d /Applications/OrbStack.app ]] && return 0
      brew list --cask orbstack >/dev/null 2>&1 && return 0
      command -v orb >/dev/null 2>&1 && return 0
      return 1 ;;
    docker-desktop)
      [[ -d /Applications/Docker.app ]] && return 0
      brew list --cask docker-desktop >/dev/null 2>&1 && return 0
      brew list --cask docker >/dev/null 2>&1 && return 0   # legacy cask name
      return 1 ;;
    colima)
      command -v colima >/dev/null 2>&1 ;;
    podman)
      command -v podman >/dev/null 2>&1 ;;
  esac
}

# engine_detect_installed — echo installed engine ids, one per line, priority order.
engine_detect_installed() {
  local e
  for e in $ENGINE_IDS; do engine_installed "$e" && printf '%s\n' "$e"; done
}

# engine_running <id> — exit 0 if THAT engine's daemon answers (timeout-bounded).
engine_running() {
  local id="$1" sock
  _engine_valid "$id" || { err "engine_running: unknown engine id: $id"; return 2; }
  sock="$(engine_socket "$id" 2>/dev/null)" || return 1
  [[ -n "$sock" ]] || return 1
  _engine_docker_timeout 6 docker -H "$sock" info >/dev/null 2>&1
}

# engine_detect_running — echo running engine ids, one per line, priority order.
engine_detect_running() {
  local e
  for e in $ENGINE_IDS; do engine_running "$e" && printf '%s\n' "$e"; done
}
