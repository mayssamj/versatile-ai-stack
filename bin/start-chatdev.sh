#!/usr/bin/env bash
# start-chatdev.sh — managed launcher for ChatDev 2.0 "DevAll" (Phase 35, opt-in).
#
# WHAT THIS RUNS
#   ChatDev 2.0's default branch is a WEB APP, not a CLI: a Vue 3 + Vite frontend
#   (dev server, container port 5173) talking to a FastAPI/uvicorn backend
#   (server_main.py, container port 6400). Both processes need the SAME source
#   tree ($AI_STACK/chatdev/repo), so the simplest container shape is ONE derived
#   image (Dockerfile here) run as TWO managed containers off that one image:
#     • chatdev-backend  — uvicorn server_main:app  (container :6400)
#     • chatdev          — npm run dev (Vite)        (container :5173 → host 5274)
#   Picked over upstream's bind-mount `compose.yml` because the platform's
#   discipline (one ai-stack network, loopback-only publish, --memory/--cpus caps,
#   ai-stack.managed labels, recreate_guard idempotency) is hand-rolled per
#   `docker run` here — exactly the start-qdrant.sh / start-openwebui.sh pattern —
#   and a baked image survives a worktree removal (a bind-mount into the repo would
#   not; cf. feedback_worktree_breaks_live_stack). The frontend is the `chatdev`
#   alias; the backend joins the network but publishes on its own loopback IP.
#
# LLM ROUTING (OpenAI-compatible → LiteLLM)
#   The backend reads BASE_URL=http://litellm:4000/v1 (container-to-container via
#   Docker DNS — the NATIVE LiteLLM port, not the host :80 alias) and API_KEY=the
#   scoped CHATDEV_LITELLM_KEY (minted by Phase 35, never the master). Workflow YAML
#   agent nodes default to ${BASE_URL}/${API_KEY}; the model is the node `name:`.
#   Written into chatdev/repo/.env (Phase 35 owns that; this script does not touch it).
#
# SECURITY
#   Frontend published on 127.0.10.18 (loopback alias) ONLY; backend on the same IP,
#   its own port. Never 0.0.0.0. CORS_ALLOW_ORIGINS is pinned to the loopback origins.
#
# Usage: start-chatdev.sh [install|run|status|stop|uninstall] [--recreate]
#   (no arg) / install  — ensure the image is built + both containers up (idempotent;
#                         the `start chatdev` entrypoint). Pass --recreate to rebuild.
#   run                 — alias of install (the funnel calls this for `start`)
#   status              — container state + live HTTP health on both ports
#   stop                — docker stop both containers (data/image preserved)
#   uninstall           — docker rm -f both containers (image + repo kept; full
#                         teardown is the phase's documented rollback)
set -Eeuo pipefail
if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "bin/start-chatdev.sh: needs bash 5+" >&2; exit 2
fi
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/network.sh"
aliases_load

PHASE=35
NAME=chatdev                 # the frontend container == the `chatdev` alias
BE_NAME=chatdev-backend      # the FastAPI/uvicorn backend
IMAGE="ai-stack/chatdev:local"
CD_DIR="$AI_STACK/chatdev"
CD_REPO="$CD_DIR/repo"
DOCKERFILE="$CD_DIR/Dockerfile"

# Ports (pre-assigned). Frontend host 5274 → container 5173; backend 6400 both sides.
FE_HOST_PORT="${ALIAS_HOST_PORT[chatdev]:-5274}"
FE_CTR_PORT="${ALIAS_CONTAINER_PORT[chatdev]:-5173}"
FE_IP="${ALIAS_IP[chatdev]:-127.0.10.18}"
BE_PORT="${CHATDEV_BACKEND_PORT:-6400}"

# Resource caps — a Node dev server + a Python backend must never become a CPU/RAM
# floor on the 24GB M4 (project_cpu_gotchas).
FE_CPUS="${CHATDEV_FE_CPUS:-2}";  FE_MEM="${CHATDEV_FE_MEM:-1g}"
BE_CPUS="${CHATDEV_BE_CPUS:-2}";  BE_MEM="${CHATDEV_BE_MEM:-2g}"

ARG1="${1:-install}"; RECREATE_FLAG="${2:-}"
# Allow `start-chatdev.sh --recreate` (flag as $1, the start-qdrant.sh ergonomics).
if [[ "$ARG1" == "--recreate" ]]; then RECREATE_FLAG="--recreate"; ARG1="install"; fi

_be_health() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$FE_IP:$BE_PORT/docs" 2>/dev/null | grep -q '^200$'; }
_fe_health() { curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$FE_IP:$FE_HOST_PORT/" 2>/dev/null | grep -q '^200$'; }

case "$ARG1" in
  status)
    for n in "$BE_NAME" "$NAME"; do
      if container_running "$n"; then ok "$n running"; else warn "$n not running"; fi
    done
    _be_health && ok "backend HEALTHY (http://$FE_IP:$BE_PORT/docs 200)" || warn "backend not serving 200 on :$BE_PORT"
    _fe_health && ok "frontend HEALTHY (http://$FE_IP:$FE_HOST_PORT/ 200)" || warn "frontend not serving 200 on :$FE_HOST_PORT"
    exit 0 ;;
  stop)
    docker stop "$NAME" "$BE_NAME" >/dev/null 2>&1 || true
    ok "chatdev: stopped both containers (data + image preserved; 'start chatdev' brings them back)"
    exit 0 ;;
  uninstall)
    docker rm -f "$NAME" "$BE_NAME" >/dev/null 2>&1 || true
    ok "chatdev: removed both containers (image $IMAGE + chatdev/repo kept)"
    note "Full teardown: docker rmi $IMAGE ; rm -rf $CD_DIR ; rm -f $AI_STACK/installer/state/phase_${PHASE}.done"
    exit 0 ;;
  install|run) : ;;   # fall through to the bring-up
  *) echo "usage: start-chatdev.sh [install|run|status|stop|uninstall] [--recreate]" >&2; exit 2 ;;
esac

# --- bring-up ---------------------------------------------------------------
[[ -d "$CD_REPO" ]]   || { err "ChatDev source missing ($CD_REPO) — run 'vz-ai-stack.sh install 35' first (it clones the repo)."; exit 1; }
[[ -f "$DOCKERFILE" ]] || { err "Dockerfile missing ($DOCKERFILE) — run 'vz-ai-stack.sh install 35' (it writes it)."; exit 1; }
[[ -f "$CD_REPO/.env" ]] || { err "chatdev/repo/.env missing — run 'vz-ai-stack.sh install 35' (it writes the LiteLLM wiring)."; exit 1; }

network_ensure_ai_stack || { err "ai-stack docker network missing. Run: bash vz-ai-stack.sh install 00n"; exit 1; }

# Build the derived image (idempotent: only when missing OR --recreate). The build
# is native arm64 — ChatDev 2.0 deps (faiss/cartopy/etc) ship prebuilt arm64 wheels,
# so there is no amd64 emulation here.
if [[ "$RECREATE_FLAG" == "--recreate" || "${FORCE_RECREATE:-0}" == "1" ]] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "Building $IMAGE (Python 3.12 + uv sync + Node + frontend deps; first build is several minutes)…"
  docker build -t "$IMAGE" -f "$DOCKERFILE" "$CD_DIR" 2>&1 | tail -8 || { err "docker build failed for $IMAGE"; exit 1; }
  ok "built image: $IMAGE"
fi

# --- backend container (start FIRST so the frontend has an API to proxy) ------
recreate_guard "$BE_NAME" "$RECREATE_FLAG" || exit 1
docker run -d \
  --name "$BE_NAME" \
  --label "ai-stack.managed=true" \
  --label "ai-stack.phase=$PHASE" \
  --label "ai-stack.partial=true" \
  --restart unless-stopped \
  --cpus "$BE_CPUS" --memory "$BE_MEM" --memory-swap "$BE_MEM" \
  --network ai-stack \
  --add-host=ollama:host-gateway \
  --env-file "$CD_REPO/.env" \
  -p "$FE_IP":"$BE_PORT":6400 \
  -v "$CD_REPO:/app" \
  "$IMAGE" \
  uvicorn server_main:app --host 0.0.0.0 --port 6400 \
  >/dev/null
ok "started container: $BE_NAME (FastAPI http://$FE_IP:$BE_PORT → litellm:4000 via Docker DNS)"

# --- frontend container (the `chatdev` alias) ---------------------------------
recreate_guard "$NAME" "$RECREATE_FLAG" || exit 1
docker run -d \
  --name "$NAME" \
  --label "ai-stack.managed=true" \
  --label "ai-stack.phase=$PHASE" \
  --label "ai-stack.partial=true" \
  --restart unless-stopped \
  --cpus "$FE_CPUS" --memory "$FE_MEM" --memory-swap "$FE_MEM" \
  --network ai-stack \
  --add-host=ollama:host-gateway \
  -e "VITE_API_BASE_URL=http://$FE_IP:$BE_PORT" \
  -p "$FE_IP":"$FE_HOST_PORT":"$FE_CTR_PORT" \
  -v "$CD_REPO:/app" \
  -w /app/frontend \
  "$IMAGE" \
  npm run dev -- --host 0.0.0.0 --port "$FE_CTR_PORT" \
  >/dev/null
ok "started container: $NAME (Vite http://$FE_IP:$FE_HOST_PORT → chatdev:$FE_CTR_PORT)"
record "start-chatdev: pid=$$ image=$IMAGE fe=$FE_HOST_PORT be=$BE_PORT"
