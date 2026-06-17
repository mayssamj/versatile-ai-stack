# docker.sh — managed docker run helpers.
# Sourced by vz-ai-stack.sh after common.sh + env.sh.
#
# Every managed container is launched with three discipline rules:
#   1. Flag order is FIXED: --network/--add-host, then --env-file, then -e...,
#      then -p..., then -v..., then --restart, then IMAGE, then CMD/ARGS.
#      Mixing -e after -p/-v makes docker leak the flag to the entrypoint
#      ("No such option: -e").
#   2. Bind on the per-service 127.0.10.x alias IP (NOT bare 127.0.0.1) and
#      join the `ai-stack` bridge network. Host-from-container reaches the
#      Mac host (e.g. Ollama on :11434) via `--add-host=ollama:host-gateway`.
#      The per-service alias scheme lives in installer/lib/aliases.tsv.
#      Never --network host on macOS.
#   3. Containers get labels:
#        ai-stack.managed=true       (this installer owns it)
#        ai-stack.phase=<NN>         (which phase installed it)
#        ai-stack.partial=true       (cleared after smoke test passes)
#      vz-ai-stack.sh gc cleans partial=true orphans.

[[ -z "${AI_STACK:-}" ]] && { echo "docker.sh: AI_STACK unset" >&2; exit 2; }

# Make the engine registry available so the source-time DOCKER_HOST export at the
# END of this file can resolve the selected socket. Guarded: callers that only want
# docker.sh's container helpers (and never sourced docker-engine.sh) still work, and
# this is a one-way dependency — docker-engine.sh must NOT source docker.sh (no cycle).
[[ -f "$AI_STACK/installer/lib/docker-engine.sh" ]] && source "$AI_STACK/installer/lib/docker-engine.sh"

# Has a container with this name?
container_exists() {
  docker ps -a --format '{{.Names}}' | grep -qx "$1"
}

# Is it running?
container_running() {
  docker ps --format '{{.Names}}' | grep -qx "$1"
}

# Inspect helpers — single field, defaulted to empty.
container_label() {
  local name="$1" label="$2"
  docker inspect "$name" --format "{{ index .Config.Labels \"$label\" }}" 2>/dev/null || true
}

# Was this container created by us?
container_managed() {
  [[ "$(container_label "$1" ai-stack.managed)" == "true" ]]
}

# Run a managed container with the canonical flag ordering.
# Usage:
#   docker_run_managed NAME PHASE IMAGE [-e VAR=VAL ...] [-p HOST:CTR ...] [-v SRC:DST[:RO] ...] -- CMD [ARGS...]
# Convention: env flags come first, then ports, then volumes, then '--', then cmd/args.
docker_run_managed() {
  local name="$1" phase="$2" image="$3"; shift 3
  local env_args=() port_args=() vol_args=() cmd_args=()
  local mode=env
  for arg in "$@"; do
    case "$arg" in
      --) mode=cmd ;;
      *)
        case "$mode" in
          env)
            case "$arg" in
              -e|--env|--env-file) mode_next=env-val ;;
              -p) mode_next=port-val ;;
              -v) mode_next=vol-val ;;
              *)
                # Unknown leading flag — bail loudly
                if [[ "$arg" == -* ]]; then
                  err "docker_run_managed: unsupported flag '$arg'"
                  return 2
                fi
                ;;
            esac
            ;;
        esac
        case "$arg" in
          -e|--env)      env_args+=("$arg"); ;;
          --env-file)    env_args+=("$arg"); ;;
          -p)            port_args+=("$arg"); ;;
          -v)            vol_args+=("$arg"); ;;
          *)
            if [[ "$mode" == cmd ]]; then
              cmd_args+=("$arg")
            elif [[ ${#env_args[@]} -gt 0 && "${env_args[-1]}" =~ ^(-e|--env|--env-file)$ ]]; then
              env_args+=("$arg")
            elif [[ ${#port_args[@]} -gt 0 && "${port_args[-1]}" == "-p" ]]; then
              port_args+=("$arg")
            elif [[ ${#vol_args[@]} -gt 0 && "${vol_args[-1]}" == "-v" ]]; then
              vol_args+=("$arg")
            fi
            ;;
        esac
        ;;
    esac
  done

  docker run -d \
    --name "$name" \
    --label "ai-stack.managed=true" \
    --label "ai-stack.phase=$phase" \
    --label "ai-stack.partial=true" \
    --restart unless-stopped \
    "${env_args[@]}" \
    "${port_args[@]}" \
    "${vol_args[@]}" \
    "$image" \
    "${cmd_args[@]}"
}

# Clear the partial=true label after smoke test passes.
mark_ready() {
  local name="$1"
  docker update --label-add "ai-stack.partial=false" "$name" >/dev/null 2>&1 || true
}

# Conservative recreate guard:
#   Returns 0 (proceed) if container does not exist.
#   Returns 0 (proceed) if FORCE_RECREATE=1 or --recreate flag.
#   Otherwise prints help and returns 1 — caller bails.
recreate_guard() {
  local name="$1" recreate_flag="${2:-}"
  if container_exists "$name"; then
    if [[ "$recreate_flag" == "--recreate" || "${FORCE_RECREATE:-0}" == "1" ]]; then
      backup_before_recreate "$name"
      docker rm -f "$name" >/dev/null
      record "recreated container $name"
      return 0
    fi
    # Container exists. Refuse silent destruction.
    warn "Container '$name' already exists."
    if container_running "$name"; then
      warn "Status: running."
    fi
    warn "To replace (will backup state for stateful services): bash bin/start-${name}.sh --recreate"
    return 1
  fi
  return 0
}

# Per-container backup before destructive action (Reviewer Adversarial #2).
backup_before_recreate() {
  local name="$1"
  local data_dir="$AI_STACK/data/${name#ai-stack-}"
  local ts; ts="$(date +%Y%m%d-%H%M%S)"
  case "$name" in
    phoenix)
      log "Backing up phoenix sqlite DB before recreate..."
      # docker cp from any path: best-effort, distroless container so we use cp at file level
      docker cp "phoenix:/mnt/data/." "$AI_STACK/data/phoenix.bak-$ts" 2>/dev/null \
        && ok "Phoenix data → $AI_STACK/data/phoenix.bak-$ts" \
        || warn "Phoenix backup failed (container may be missing or distroless lacks shell); continuing."
      ;;
    falkordb)
      log "Triggering Falkor SAVE..."
      docker exec falkordb redis-cli SAVE >/dev/null 2>&1 || warn "Falkor SAVE failed; continuing."
      docker cp "falkordb:/data/." "$AI_STACK/data/falkor.bak-$ts" 2>/dev/null \
        && ok "Falkor data → $AI_STACK/data/falkor.bak-$ts" \
        || warn "Falkor backup failed."
      ;;
    qdrant)
      docker cp "qdrant:/qdrant/storage/." "$AI_STACK/data/qdrant.bak-$ts" 2>/dev/null \
        && ok "Qdrant data → $AI_STACK/data/qdrant.bak-$ts" \
        || warn "Qdrant backup failed."
      ;;
    *)
      # Stateless services (litellm, openwebui) — nothing to back up.
      :
      ;;
  esac
}

# Image-pull-if-missing.
ensure_image() {
  local image="$1"
  if ! docker image inspect "$image" >/dev/null 2>&1; then
    log "Pulling $image ..."
    docker pull "$image"
  fi
}

# host.docker.internal probe — Reviewer A #3.
probe_host_docker_internal() {
  if ! docker run --rm alpine getent hosts host.docker.internal >/dev/null 2>&1; then
    err "host.docker.internal does not resolve from inside containers."
    err "This is required for LiteLLM → Phoenix and many other paths."
    err "If you're on OrbStack: settings → Network → ensure host networking is enabled."
    return 1
  fi
  return 0
}

# Source-time DOCKER_HOST export so STANDALONE bin/start-*.sh (which source this
# file but NOT vz-ai-stack.sh) talk to the SELECTED engine, not the ambient socket.
# Idempotent + no-op when AI_STACK_DOCKER_ENGINE is empty/unset.
if declare -F engine_socket >/dev/null 2>&1 && declare -F _engine_valid >/dev/null 2>&1; then
  _ds_eng="$(get_env AI_STACK_DOCKER_ENGINE "" 2>/dev/null || true)"
  if [[ -n "${_ds_eng:-}" ]] && _engine_valid "$_ds_eng" 2>/dev/null; then
    _ds_sock="$(engine_socket "$_ds_eng" 2>/dev/null || true)"
    [[ -n "${_ds_sock:-}" ]] && export DOCKER_HOST="$_ds_sock"
  fi
  unset _ds_eng _ds_sock
fi
