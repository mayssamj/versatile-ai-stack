# docker.sh — managed docker run helpers.
# Sourced by mayssam-ai-stack.sh after common.sh + env.sh.
#
# Every managed container is launched with three discipline rules:
#   1. Flag order is FIXED: --name, then the --label×3, then --restart, then any
#      engine-derived --add-host (injected AFTER --restart and BEFORE env/ports/vols/
#      IMAGE), then --env-file, then -e..., then -p..., then -v..., then IMAGE, then
#      CMD/ARGS. Mixing -e after -p/-v makes docker leak the flag to the entrypoint
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
#      mayssam-ai-stack.sh gc cleans partial=true orphans.

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

  # Engine-conditional host.docker.internal (Colima/Podman need it explicitly).
  local _eng _addhost=()
  _eng="$(get_env AI_STACK_DOCKER_ENGINE "" 2>/dev/null || true)"
  if [[ -n "$_eng" ]] && declare -F engine_addhost_args >/dev/null 2>&1 && _engine_valid "$_eng" 2>/dev/null; then
    local _ah; _ah="$(engine_addhost_args "$_eng" 2>/dev/null || true)"
    [[ -n "$_ah" ]] && _addhost=("$_ah")
  fi

  # A freshly-created container is partial=true and, by definition, NOT yet ready — it
  # must re-earn "ready" via its own smoke test (mark_ready). Drop any stale marker so
  # a recreated name can't inherit a prior life's readiness. (2026-07-05 §24 review.)
  clear_ready_marker "$name"
  docker run -d \
    --name "$name" \
    --label "ai-stack.managed=true" \
    --label "ai-stack.phase=$phase" \
    --label "ai-stack.partial=true" \
    --restart unless-stopped \
    "${_addhost[@]}" \
    "${env_args[@]}" \
    "${port_args[@]}" \
    "${vol_args[@]}" \
    "$image" \
    "${cmd_args[@]}"
}

# Mark a container ready after its smoke test passes.
# IMPORTANT: Docker labels are IMMUTABLE post-create and `docker update` has NO
# --label flag (verified: `docker update --help` lists none), so the old
# `docker update --label-add "ai-stack.partial=false" ... || true` was a SILENT
# NO-OP for EVERY managed container — the ai-stack.partial=true label set at
# creation never cleared, so `mayssam-ai-stack.sh gc` classified the entire healthy
# running stack as "partial orphans" and offered to `docker rm -f` all of it.
# (2026-07-05 takeover fix.)
#
# Since the label can't be mutated, record readiness in a durable state marker
# instead. gc consults this marker AND the container's running-state so a healthy
# container is never treated as an orphan. Best-effort (never aborts a start
# script): a missing marker just means gc falls back to the running-state check.
mark_ready() {
  local name="$1"
  [[ -n "${STATE_DIR:-}" ]] || return 0
  mkdir -p "$STATE_DIR/ready" 2>/dev/null || return 0
  : > "$STATE_DIR/ready/$name" 2>/dev/null || true
}

# container_ready_marked NAME — true if mark_ready recorded this container ready.
container_ready_marked() {
  [[ -n "${STATE_DIR:-}" && -f "$STATE_DIR/ready/$1" ]]
}

# clear_ready_marker NAME — drop a container's readiness marker. Call it wherever a
# container is REMOVED or a fresh partial=true container is about to be CREATED, so a
# name recreated after a removal (recreate, `reset` tier, manual `docker rm`) can't
# inherit a prior life's marker and be wrongly excluded from gc (gc excludes running
# OR ready-marked). Best-effort; a missing STATE_DIR / marker is a no-op.
clear_ready_marker() {
  [[ -n "${STATE_DIR:-}" ]] && rm -f "$STATE_DIR/ready/$1" 2>/dev/null || true
}

# Idempotent recreate / reconcile guard.
#   Returns 0 (caller proceeds to `docker run`) when the container does NOT exist,
#     or when --recreate / FORCE_RECREATE=1 (after backup + rm).
#   For an EXISTING container WE OWN (ai-stack.managed=true) and no --recreate, we
#     reconcile in place and `exit 0` the calling start script (NO docker run):
#       - already running -> no-op success ("already running")
#       - stopped         -> `docker start` (preserves data/volumes) ("was stopped — restarted")
#     This is what makes every bin/start-*.sh idempotent, so `install`/`start`
#     RECOVER a stopped stack (e.g. after you stop containers to free CPU) instead
#     of aborting the phase. start scripts are always run as a subprocess
#     (`bash "$script"`, never sourced — verified cmd_start + phase scripts), so the
#     exit is contained; cmd_start maps the "already running"/fresh distinction from
#     the printed message.
#   For a FOREIGN container (not managed by us) -> refuse (return 1); the caller
#     bails so we never touch something we did not create.
recreate_guard() {
  local name="$1" recreate_flag="${2:-}"
  if container_exists "$name"; then
    if [[ "$recreate_flag" == "--recreate" || "${FORCE_RECREATE:-0}" == "1" ]]; then
      backup_before_recreate "$name"
      # `-v` reaps the container's ANONYMOUS volumes with it (image VOLUME scratch /
      # single-path mask-guards); named volumes and host binds are never touched by -v.
      # This guard is the highest-traffic recreate path, so without -v every recreate
      # leaked one anon volume per VOLUME-declaring image (§24 2026-07-20 audit: ~1.5GB).
      # ⚠ LATENT TRAP: backup_before_recreate covers phoenix/falkor/qdrant only. A future
      # service that keeps REAL STATE in an anonymous volume (none does today — audited)
      # must add itself there BEFORE recreating through this guard, or -v wipes it.
      docker rm -fv "$name" >/dev/null
      clear_ready_marker "$name"   # new container must re-earn ready via its smoke test
      record "recreated container $name"
      return 0
    fi
    if container_managed "$name"; then
      if container_running "$name"; then
        ok "$name already running (use --recreate to rebuild)"
        exit 0
      fi
      if docker start "$name" >/dev/null 2>&1; then
        ok "$name was stopped — restarted, data preserved (use --recreate to rebuild)"
        record "reconciled stopped container $name (docker start)"
        exit 0
      fi
      warn "$name exists but failed to start; rebuild with: bash bin/start-${name}.sh --recreate"
      return 1
    fi
    # Foreign container — never silently destroy something we don't own.
    warn "Container '$name' already exists and is NOT managed by ai-stack."
    warn "Adopt it (mayssam-ai-stack.sh adopt $name) or replace: bash bin/start-${name}.sh --recreate"
    return 1
  fi
  # Container absent → the caller is about to `docker run` a fresh partial=true one.
  # Clear any marker left by a prior life removed OUTSIDE this guard (a `reset` tier, a
  # manual `docker rm`), so the fresh container re-earns ready. This is the root-cause
  # spot for every service that reconciles through recreate_guard. (2026-07-05 §24 review.)
  clear_ready_marker "$name"
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

# --- anonymous-volume hygiene (§24 council 2026-07-20) -----------------------
# Anonymous volumes (engine label com.docker.volume.anonymous) are minted by
# single-path `-v /path` mask-guards (chatdev/ai-town node_modules), image VOLUME
# directives, and the OpenShell supervisor's sandbox homes (the gateway strips
# --label, so those are invisible to every label-filtered teardown). The 2026-07-20
# persistence audit found NO service keeps contracted state in one — but a dangling
# volume is NON-RECOVERABLE once removed, so `remove` tar-backs-up each volume
# first, fail-CLOSED (mirror of reset.sh's H8 named-volume discipline).
#
#   docker_anon_orphans list
#       print every dangling anonymous volume name, one per line (read-only).
#   docker_anon_orphans remove <backup-dir> <name>...
#       back up + remove EXACTLY the named volumes. Callers pass an explicit,
#       already-disclosed set — this verb never enumerates-and-removes on its
#       own, so a caller bug cannot turn it into a blind engine-wide sweep.
#       Backup failure SKIPS that volume unless AI_STACK_FORCE_WIPE=1.
#       Returns 1 if any volume was kept/failed, else 0.
docker_anon_orphans() {
  local mode="${1:-list}"; shift || true
  case "$mode" in
    list)
      # rc PROPAGATES (no 2>/dev/null, no forced return 0): reset's entry snapshot
      # must distinguish "no orphans" from "engine unreachable" — a fail-OPEN list
      # would let a mid-run engine hiccup misclassify pre-existing orphans as
      # run-orphaned (§24 adversarial, blocking). The awk shape-guard keeps only
      # engine-minted 64-hex anonymous names, so a user-created NAMED volume that
      # merely carries the label is never treated as debris.
      docker volume ls -q --filter dangling=true --filter label=com.docker.volume.anonymous \
        | awk '$0 ~ /^[0-9a-f]{64}$/'
      ;;
    remove)
      # No ${1:?}: that expansion KILLS the sourcing shell mid-teardown on a caller
      # mistake — warn + return 2 keeps the contract without the shell-killing class.
      local vbak="${1:-}"
      if [[ -z "$vbak" ]]; then warn "docker_anon_orphans remove: backup dir required"; return 2; fi
      shift
      local v _kept=0
      for v in "$@"; do
        [[ -n "$v" ]] || continue
        mkdir -p "$vbak" 2>/dev/null || true
        if docker run --rm -v "$v":/data:ro -v "$vbak":/out alpine \
             tar czf "/out/${v}.tgz" -C /data . >/dev/null 2>&1 && [[ -s "$vbak/${v}.tgz" ]]; then
          :
        elif [[ "${AI_STACK_FORCE_WIPE:-0}" == "1" ]]; then
          warn "anon volume ${v:0:12}… backup FAILED but AI_STACK_FORCE_WIPE=1 — removing anyway"
        else
          warn "KEEPING anon volume ${v:0:12}…: backup failed (AI_STACK_FORCE_WIPE=1 to remove anyway)"
          _kept=$((_kept+1)); continue
        fi
        if docker volume rm "$v" >/dev/null 2>&1; then
          ok "removed anon volume ${v:0:12}… (tar in $(basename "$vbak")/)"
        else
          warn "could not remove anon volume ${v:0:12}…"
          _kept=$((_kept+1))
        fi
      done
      if (( _kept > 0 )); then return 1; fi
      return 0
      ;;
    *)
      warn "docker_anon_orphans: unknown mode '$mode' (list|remove)"
      return 2
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

# host.docker.internal probe — Reviewer A #3. Engine-aware: on Colima/Podman the
# alias only resolves when the probe container itself carries the add-host flag, so
# we derive it from the selected engine (empty on OrbStack/Docker Desktop).
probe_host_docker_internal() {
  local _eng _addhost=()
  _eng="$(get_env AI_STACK_DOCKER_ENGINE "" 2>/dev/null || true)"
  if [[ -n "$_eng" ]] && declare -F engine_addhost_args >/dev/null 2>&1 && _engine_valid "$_eng" 2>/dev/null; then
    local _ah; _ah="$(engine_addhost_args "$_eng" 2>/dev/null || true)"
    [[ -n "$_ah" ]] && _addhost=("$_ah")
  fi
  if ! docker run --rm "${_addhost[@]}" alpine getent hosts host.docker.internal >/dev/null 2>&1; then
    err "host.docker.internal does not resolve from inside containers."
    err "This is required for LiteLLM → host Postgres/Phoenix and other paths."
    err "If you're on OrbStack/Docker Desktop: Settings → Network → ensure host networking is enabled."
    err "If you're on Colima/Podman: the host-dialing service (LiteLLM) injects"
    err "  --add-host=host.docker.internal:host-gateway from the engine registry."
    err "  Any OTHER container that needs it must add that flag to its own 'docker run'."
    return 1
  fi
  return 0
}

# Source-time DOCKER_HOST export so STANDALONE bin/start-*.sh (which source this
# file but NOT mayssam-ai-stack.sh) talk to the SELECTED engine, not the ambient socket.
# Idempotent + no-op when AI_STACK_DOCKER_ENGINE is empty/unset.
if declare -F engine_socket >/dev/null 2>&1 && declare -F _engine_valid >/dev/null 2>&1; then
  _ds_eng="$(get_env AI_STACK_DOCKER_ENGINE "" 2>/dev/null || true)"
  if [[ -n "${_ds_eng:-}" ]] && _engine_valid "$_ds_eng" 2>/dev/null; then
    _ds_sock="$(engine_socket "$_ds_eng" 2>/dev/null || true)"
    [[ -n "${_ds_sock:-}" ]] && export DOCKER_HOST="$_ds_sock"
  fi
  unset _ds_eng _ds_sock
fi
