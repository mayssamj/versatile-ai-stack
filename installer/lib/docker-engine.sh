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
