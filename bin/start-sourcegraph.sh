#!/usr/bin/env bash
# start-sourcegraph.sh — local self-hosted Sourcegraph (opt-in Phase 27).
#
# Single-container `sourcegraph/server:6.12.5040` — the LAST single-container tag
# (7.0 removed it). amd64-only image; runs under emulation on Apple Silicon, so
# we pass --platform linux/amd64 explicitly (Docker's default would try the
# host arch manifest, which does not exist).
#
# AUTO-START: --restart unless-stopped means the container comes back whenever the
# Docker engine daemon restarts (incl. at login/boot). On OrbStack / Docker
# Desktop the daemon auto-starts at login, so SG survives a reboot. On Colima /
# Podman the engine daemon does NOT auto-start by default — see `help sourcegraph`
# (the autostart guarantee is the engine's, not a launchd unit we add).
#
# NETWORKING: published on 127.0.0.1:7080 (loopback only — NOT 0.0.0.0, so SG is
# not exposed on the LAN). The hermes-fleet-v1 OpenShell sandbox reaches it via
# host.docker.internal:7080, which inside the sandbox VM resolves to the Mac's
# 127.0.0.1 (same mechanism start-litellm.sh relies on for its 127.0.0.1 bind).
# Claude Code on the host reaches it at http://localhost:7080. SG is a host-port
# service, NOT an ai-stack-network alias service — it is intentionally absent from
# installer/lib/aliases.tsv and does not join the ai-stack bridge (it dials no
# other stack service).
#
# DATA: ~/.sourcegraph-local/{config,data} (OUTSIDE the repo data/ tree by design
# — preserves the existing index + admin token across container recreate). Phase
# 27 owns idempotent bootstrap (site-init / token mint / repo indexing).
set -Eeuo pipefail
if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "bin/start-sourcegraph.sh: needs bash 5+" >&2; exit 2
fi
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker-engine.sh"   # DOCKER_HOST for the selected engine
source "$AI_STACK/installer/lib/docker.sh"

NAME=sourcegraph
PHASE=27
IMAGE="sourcegraph/server:6.12.5040"
PLATFORM="linux/amd64"
SG_DIR="$HOME/.sourcegraph-local"
RECREATE_FLAG="${1:-}"

recreate_guard "$NAME" "$RECREATE_FLAG" || exit 1

# Platform-aware image fetch: ensure_image's bare `docker pull` would resolve the
# host-arch (arm64) manifest, which does not exist for this image — pull amd64.
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  log "Pulling $IMAGE (--platform $PLATFORM; amd64-emulated) ..."
  docker pull --platform "$PLATFORM" "$IMAGE"
fi

mkdir -p "$SG_DIR/config" "$SG_DIR/data"

# Resource caps (carried from the verified live run): an amd64-emulated container
# must never become a CPU/RAM floor on a 24GB M-series box (project_cpu_gotchas).
docker run -d \
  --name "$NAME" \
  --label "ai-stack.managed=true" \
  --label "ai-stack.phase=$PHASE" \
  --platform "$PLATFORM" \
  --restart unless-stopped \
  --cpus 4 --memory 4g --memory-swap 4g \
  -p 127.0.0.1:7080:7080 \
  -v "$SG_DIR/config:/etc/sourcegraph" \
  -v "$SG_DIR/data:/var/opt/sourcegraph" \
  "$IMAGE" \
  >/dev/null
ok "started container: $NAME (http://localhost:7080 ; sandbox: host.docker.internal:7080)"
record "start-sourcegraph: pid=$$ image=$IMAGE platform=$PLATFORM"
