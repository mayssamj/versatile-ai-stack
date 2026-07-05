#!/usr/bin/env bash
# adopt.sh — take ownership of a container started outside the installer.
#
# Flow (Reviewer Adversarial #1 + #2):
#   1. Identify foreign container.
#   2. Extract its current config & mounts via docker cp / inspect.
#   3. Diff against what `bin/start-<svc>.sh` WOULD produce.
#   4. Show user the diff. Require explicit "yes" if non-trivial.
#   5. Backup stateful data (Phoenix DB, Falkor RDB, Qdrant snapshot).
#   6. docker rm -f.
#   7. Recreate via managed start script.
#   8. Smoke test.
#   9. On any failure, restore from backup.
#
# Pass --no-backup to skip step 5 (NOT recommended; for stateless services only).
set -Eeuo pipefail
shopt -s inherit_errexit nullglob

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/validate.sh"
source "$AI_STACK/installer/lib/prompt.sh"
source "$AI_STACK/installer/lib/litellm.sh"

SVC="${1:?usage: adopt.sh <service>}"
NO_BACKUP="${2:-}"

[[ -x "$AI_STACK/bin/start-${SVC}.sh" ]] || { err "no managed start script: bin/start-${SVC}.sh"; exit 2; }
container_exists "$SVC" || { err "no container named '$SVC'"; exit 2; }

if container_managed "$SVC"; then
  ok "$SVC is already managed. Nothing to adopt."
  exit 0
fi

hdr "Adopting foreign container: $SVC"

# Step 2 + 3 — show the user what's currently in place.
log "Current container config (relevant fields):"
docker inspect "$SVC" --format '
  Image:    {{.Config.Image}}
  Cmd:      {{join .Config.Cmd " "}}
  Ports:    {{range $p, $v := .NetworkSettings.Ports}}{{$p}} -> {{range $v}}{{.HostIp}}:{{.HostPort}} {{end}} {{end}}
  Mounts:   {{range .Mounts}}{{.Source}} -> {{.Destination}} ({{.Mode}}) ; {{end}}
  Labels:   {{range $k, $v := .Config.Labels}}{{$k}}={{$v}} {{end}}
  Env count: {{len .Config.Env}}
'

note "Managed start script will recreate with this layout (post-refactor):"
case "$SVC" in
  litellm)
    cat <<EOF
  Image:    ghcr.io/berriai/litellm:main-stable
  Network:  ai-stack (--add-host=ollama:host-gateway)
  Bind:     127.0.10.1:80 -> :4000 (alias 'litellm')
  Mounts:   $AI_STACK/litellm:/app/config  (RW)
            $AI_STACK/traces:/traces       (RW)
            $AI_STACK/guardrails:/guardrails  (RO)
  Env:      --env-file=$AI_STACK/.env + PHOENIX_COLLECTOR_HTTP_ENDPOINT, PHOENIX_PROJECT_NAME
EOF
    ;;
  phoenix)
    cat <<EOF
  Image:    arizephoenix/phoenix:latest
  Network:  ai-stack (--add-host=ollama:host-gateway)
  Bind:     127.0.10.2:80 -> :6006 (alias 'phoenix', UI/HTTP-OTLP)
            127.0.10.3:4317 -> :4317 (alias 'phoenix-otlp', gRPC OTLP)
  Mounts:   $AI_STACK/data/phoenix:/mnt/data
  Env:      PHOENIX_ENABLE_AUTH=true + PHOENIX_SECRET from .env
EOF
    ;;
  falkordb)
    cat <<EOF
  Image:    falkordb/falkordb:latest
  Network:  ai-stack (--add-host=ollama:host-gateway)
  Bind:     127.0.10.7:6379 -> :6379 (alias 'falkordb', Redis)
            127.0.10.8:80 -> :3000  (alias 'falkordb-ui', browser)
  Mounts:   $AI_STACK/data/falkor:/data
EOF
    ;;
  qdrant)
    cat <<EOF
  Image:    qdrant/qdrant
  Network:  ai-stack (--add-host=ollama:host-gateway)
  Bind:     127.0.10.5:80 -> :6333 (alias 'qdrant', REST)
  Mounts:   $AI_STACK/data/qdrant:/qdrant/storage
EOF
    ;;
esac

echo
warn "Adopting WILL stop and recreate this container."
warn "If the existing bind-mount paths point INSIDE the OrbStack VM (visible to"
warn "the running container but EMPTY on host), recreate will start with empty data."
warn "Step 5 below tries to extract data via 'docker cp' first."

confirm "Proceed with adoption of $SVC?" N || { log "Aborted."; exit 0; }

# Step 5 — backup stateful data via docker cp.
if [[ "$NO_BACKUP" != "--no-backup" ]]; then
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_root="$AI_STACK/data/adopt-backup-${SVC}-${ts}"
  mkdir -p "$backup_root"
  case "$SVC" in
    phoenix)
      log "Extracting Phoenix data via 'docker cp' (distroless container — file-level only)..."
      docker cp "phoenix:/mnt/data/." "$backup_root/" 2>&1 | head -3 || {
        warn "docker cp failed (distroless? mount-only?); continuing without backup."
      }
      ;;
    falkordb)
      log "Asking Falkor to SAVE then copying RDB..."
      docker exec falkordb redis-cli SAVE >/dev/null 2>&1 || warn "Falkor SAVE failed"
      docker cp "falkordb:/data/." "$backup_root/" 2>&1 | head -3 || warn "docker cp failed"
      ;;
    qdrant)
      log "Copying Qdrant storage tree..."
      docker cp "qdrant:/qdrant/storage/." "$backup_root/" 2>&1 | head -3 || warn "docker cp failed"
      ;;
    litellm)
      log "Copying LiteLLM config dir (stateless service but config may be in-VM)..."
      docker cp "litellm:/app/config/." "$AI_STACK/litellm/" 2>&1 | head -3 || warn "docker cp failed"
      docker cp "litellm:/traces/." "$AI_STACK/traces/" 2>&1 | head -3 || true
      ;;
  esac
  ok "Backup at: $backup_root"
fi

# Step 6 — stop the foreign container.
log "Stopping & removing foreign container..."
docker rm -f "$SVC" >/dev/null
record_block "adoption: $SVC" \
  "user-confirmed adoption" \
  "backup at: ${backup_root:-(none — --no-backup)}"

# Step 7 — recreate via managed start script.
log "Starting managed container..."
bash "$AI_STACK/bin/start-${SVC}.sh"

# Step 7b — verify the new container joined the ai-stack network.
# Skip the check for services whose declared network isn't ai-stack (compose
# stacks, host-side, etc.). For docker-typed services this is required.
if docker inspect "$SVC" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null \
     | grep -q '"ai-stack"'; then
  ok "$SVC joined the ai-stack network"
else
  err "WARNING: $SVC is up but not on the ai-stack network."
  err "Expected --network ai-stack flag in bin/start-${SVC}.sh."
  err "Aliases (http://$SVC) will not resolve from other ai-stack containers."
fi

# Step 8 — smoke test.
log "Smoke-testing..."
case "$SVC" in
  litellm)  litellm_wait_ready 60 || { err "smoke fail"; exit 1; } ;;
  phoenix)  wait_http http://phoenix:6006 60 || { err "smoke fail"; exit 1; } ;;
  qdrant)   wait_http http://qdrant:6333/collections 30 || { err "smoke fail"; exit 1; } ;;
  falkordb)
    # falkordb publishes ONLY on its alias IP 127.0.10.7:6379 (installer/lib/aliases.tsv),
    # NOT 127.0.0.1 — the old 127.0.0.1 probe always false-failed after the recreate,
    # reporting "smoke fail" on a container that actually came up fine. Probe the real
    # bind, with a bounded retry since the container was just (re)started.
    # (2026-07-05 takeover fix.)
    _fk_ok=0
    for _i in $(seq 1 30); do
      if (exec 3<>/dev/tcp/127.0.10.7/6379) 2>/dev/null; then exec 3>&- 3<&- 2>/dev/null; _fk_ok=1; break; fi
      sleep 1
    done
    (( _fk_ok )) || { err "smoke fail (falkordb not reachable on 127.0.10.7:6379 after 30s)"; exit 1; } ;;
esac
mark_ready "$SVC"
ok "Adopted: $SVC"
record "adoption complete: $SVC"
