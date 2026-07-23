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
# Labels: `ai-stack.managed` (lifecycle: reset/gc/status track it) + the phase +
# `ai-stack.bridge-exempt` — SG is a host-port service (127.0.0.1:7080, reached via
# host.docker.internal), intentionally NOT on the ai-stack bridge (absent from
# aliases.tsv; dials no stack service). The exempt label tells doctor check 16 to
# skip the ai-stack-network-membership requirement for it (it would else false-flag).
#
# DUAL-bind: 127.0.0.1:7080 (host + the sandbox's host.docker.internal:7080 path)
# AND 127.0.10.20:7080 (the `sourcegraph` lo0 alias → http://sourcegraph:7080 + the
# Caddy ingress http://sourcegraph/), loopback-only, never 0.0.0.0. The alias bind
# needs the 127.0.10.20 lo0 alias (prepare-sudo) — guarded so a missing alias gives
# a clear instruction, not a cryptic "cannot assign requested address" Docker error.
SG_BIND_IP=127.0.10.20
if ! ifconfig lo0 2>/dev/null | grep -oE '127\.0\.10\.[0-9]+' | grep -qxF "$SG_BIND_IP"; then
  err "lo0 alias $SG_BIND_IP (sourcegraph) is missing — the container dual-binds it loopback-only and won't start without it."
  err "Run once:  sudo $AI_STACK/mayssam-ai-stack.sh prepare-sudo"
  exit 1
fi
docker run -d \
  --name "$NAME" \
  --label "ai-stack.managed=true" \
  --label "ai-stack.phase=$PHASE" \
  --label "ai-stack.bridge-exempt=true" \
  --platform "$PLATFORM" \
  --restart unless-stopped \
  --cpus 4 --memory 4g --memory-swap 4g \
  -p 127.0.0.1:7080:7080 \
  -p "$SG_BIND_IP":7080:7080 \
  -v "$SG_DIR/config:/etc/sourcegraph" \
  -v "$SG_DIR/data:/var/opt/sourcegraph" \
  "$IMAGE" \
  >/dev/null
ok "started container: $NAME (http://localhost:7080 + http://sourcegraph:7080 ; sandbox: host.docker.internal:7080)"
# NOTE: a sourcegraph container created BEFORE this dual-bind change stays bound to
# 127.0.0.1 only until it is recreated (`docker rm -f sourcegraph` then install);
# `docker start` of an existing container does NOT re-publish ports.
record "start-sourcegraph: pid=$$ image=$IMAGE platform=$PLATFORM"
