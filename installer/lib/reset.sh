#!/usr/bin/env bash
# reset.sh — tiered destructive reset.
#   soft:  clears phase stamps + bin/. Keeps .env, data/, containers.
#   hard:  + `docker rm -f` managed containers + tear down ai-stack docker
#          network + data/* backed up to data.bak-<ts>/. Leaves /etc/hosts.
#   nuke:  + .env (backed up) + ollama models + /etc/hosts block removed.
#          User must type 'nuke ai-stack' literally.
#
# Non-interactive: `install.sh reset --confirm hard --yes` exports
# AI_STACK_ASSUME_YES=1 so the soft/hard y/n gate auto-accepts (see prompt.sh).
# The nuke typed gate is NOT a confirm() and stays manual regardless of --yes.
#
# D17 revised: hard now also removes the ai-stack network (symmetric tear-down
# of containers + network — no asymmetric state where containers exist on a
# stale network). /etc/hosts removal stays in nuke only because reserved
# aliases pointing at nothing are not destructive.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/prompt.sh"
# network.sh provides network_remove_ai_stack + hosts_remove_block.
# It may not exist yet during a fresh checkout — source defensively.
if [[ -f "$AI_STACK/installer/lib/network.sh" ]]; then
  source "$AI_STACK/installer/lib/network.sh"
fi

TIER="${1:-soft}"

print_blast_radius() {
  case "$TIER" in
    soft)
      cat <<EOF
soft reset — blast radius:
  WILL clear:  installer/state/*.done, CHANGELOG.d/*
  WILL keep:   .env, data/, all running containers, ollama models, /etc/hosts, ai-stack network
EOF
      ;;
    hard)
      cat <<EOF
hard reset — blast radius:
  WILL clear:  installer/state/*.done, CHANGELOG.d/*
  WILL remove: OpenShell sandboxes (hermes-fleet-v1, pi-v1, ...)
  WILL remove: compose projects honcho/deerflow/autofyn/hermes-workspace
               (their containers + named volumes incl. honcho_redis-data)
  WILL remove: all containers labeled ai-stack.managed=true
  WILL remove: ai-stack docker network
  WILL backup: data/ → data.bak-<ts>/  (then start fresh)
  WILL keep:   .env, ollama + models, docker images, /etc/hosts ai-stack block
EOF
      ;;
    nuke)
      cat <<EOF
NUKE reset — blast radius:
  WILL clear:  installer/state/*.done, CHANGELOG.d/*
  WILL remove: OpenShell sandboxes + compose projects (containers + volumes)
  WILL remove: all containers labeled ai-stack.managed=true
  WILL remove: ai-stack docker network
  WILL backup: data/ → data.bak-<ts>/ AND .env → .env.bak-<ts>
  WILL remove: .env
  WILL remove: /etc/hosts ai-stack block (sudo prompt)
  WILL remove: ALL pulled Ollama models (multi-GB re-download next time)
EOF
      ;;
    *)
      err "reset: unknown tier '$TIER'; use soft|hard|nuke"
      exit 2
      ;;
  esac
}

print_blast_radius

# Tear down every ai-stack docker-compose project — containers + project-scoped
# networks + named volumes — by LABEL. Robust without needing each compose file
# (deploy.sh-style projects run compose from their own subdir with their own -f).
# Covers honcho (incl. its redis-data volume), deerflow, autofyn, hermes-workspace.
teardown_compose_projects() {
  local proj ids
  for proj in honcho hermes-workspace autofyn deer-flow; do
    ids="$(docker ps -aq --filter "label=com.docker.compose.project=$proj" 2>/dev/null || true)"
    if [[ -n "$ids" ]]; then
      # shellcheck disable=SC2086  # intentional word-split of the id list
      docker rm -f $ids >/dev/null 2>&1 && ok "removed compose project '$proj' containers" || true
    fi
    docker volume ls -q --filter "label=com.docker.compose.project=$proj" 2>/dev/null | while IFS= read -r v; do
      [[ -n "$v" ]] && docker volume rm "$v" >/dev/null 2>&1 && ok "removed volume $v" || true
    done
    docker network ls --format '{{.Name}}' --filter "label=com.docker.compose.project=$proj" 2>/dev/null | while IFS= read -r n; do
      [[ -n "$n" ]] && docker network rm "$n" >/dev/null 2>&1 && ok "removed network $n" || true
    done
  done
}

# Delete every OpenShell sandbox (hermes-fleet-v1, pi-v1, ...) so a fresh install
# recreates them cleanly. Best-effort; the gateway owns the actual containers.
teardown_openshell_sandboxes() {
  command -v openshell >/dev/null 2>&1 || return 0
  local sb
  openshell sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk 'NR>1 && $1!="" {print $1}' | while IFS= read -r sb; do
    [[ -n "$sb" ]] || continue
    openshell sandbox delete "$sb" >/dev/null 2>&1 && ok "deleted openshell sandbox $sb" \
      || warn "could not delete sandbox $sb (delete it manually if it lingers)"
  done
}

# Helper: remove the ai-stack network if the helper is available, else best-effort.
remove_ai_stack_network() {
  if declare -F network_remove_ai_stack >/dev/null 2>&1; then
    network_remove_ai_stack || warn "network_remove_ai_stack reported failure (continuing)"
  else
    warn "lib/network.sh not present; removing ai-stack network via docker directly."
    if docker network ls --format '{{.Name}}' | grep -qx ai-stack; then
      docker network rm ai-stack >/dev/null 2>&1 \
        && ok "removed docker network: ai-stack" \
        || warn "docker network rm ai-stack failed (containers may still be attached)"
    fi
  fi
}

case "$TIER" in
  soft)
    if ! confirm "Proceed with soft reset?" N; then exit 0; fi
    rm -f "$AI_STACK"/installer/state/phase_*.done
    rm -rf "$AI_STACK"/CHANGELOG.d/*
    ok "soft reset complete."
    ;;
  hard)
    if ! confirm "Proceed with hard reset?" N; then exit 0; fi
    ts="$(date +%Y%m%d-%H%M%S)"
    log "Backing up data/ → data.bak-${ts}/"
    cp -R "$AI_STACK/data" "$AI_STACK/data.bak-${ts}" || warn "data backup failed (continuing)"
    # Tear everything down BEFORE removing the ai-stack network so nothing stays
    # attached (a dangling external-network ref breaks the next `compose up`).
    # (1) OpenShell sandboxes (gateway-managed containers on openshell-docker).
    log "Deleting OpenShell sandboxes..."
    teardown_openshell_sandboxes
    # (2) All ai-stack compose projects by label — containers + their named
    #     volumes (incl. honcho_redis-data) + project networks.
    log "Tearing down compose projects (honcho, deerflow, autofyn, hermes-workspace)..."
    teardown_compose_projects
    # (3) Single-container managed services (litellm, phoenix, qdrant, ...).
    log "Stopping + removing managed ai-stack containers..."
    docker ps -a --filter "label=ai-stack.managed=true" --format '{{.Names}}' \
      | while IFS= read -r c; do docker rm -f "$c" >/dev/null && ok "removed $c"; done
    log "Removing ai-stack docker network..."
    remove_ai_stack_network
    rm -f "$AI_STACK"/installer/state/phase_*.done
    rm -rf "$AI_STACK"/CHANGELOG.d/*
    rm -rf "$AI_STACK"/data/{phoenix,falkor,qdrant,honcho,openwebui}/*
    ok "hard reset complete. Backups under data.bak-${ts}/"
    note "/etc/hosts ai-stack block left in place (run 'reset --confirm nuke' to remove)."
    ;;
  nuke)
    printf 'Type "nuke ai-stack" (exactly) to confirm: '
    read -r ans
    if [[ "$ans" != "nuke ai-stack" ]]; then
      err "Confirmation did not match. Aborted."
      exit 1
    fi
    ts="$(date +%Y%m%d-%H%M%S)"
    cp -R "$AI_STACK/data" "$AI_STACK/data.bak-${ts}" 2>/dev/null || true
    cp -p "$AI_STACK/.env" "$AI_STACK/.env.bak-${ts}" 2>/dev/null || true
    log "Deleting OpenShell sandboxes..."
    teardown_openshell_sandboxes
    log "Tearing down compose projects (honcho, deerflow, autofyn, hermes-workspace)..."
    teardown_compose_projects
    log "Stopping + removing managed ai-stack containers..."
    docker ps -a --filter "label=ai-stack.managed=true" --format '{{.Names}}' \
      | while IFS= read -r c; do docker rm -f "$c" >/dev/null; done
    log "Removing ai-stack docker network..."
    remove_ai_stack_network
    rm -f "$AI_STACK"/installer/state/phase_*.done
    rm -rf "$AI_STACK"/CHANGELOG.d/*
    rm -rf "$AI_STACK"/data/{phoenix,falkor,qdrant,honcho,openwebui}/*
    rm -f "$AI_STACK"/.env
    log "Removing /etc/hosts ai-stack block (sudo prompt)..."
    if declare -F hosts_remove_block >/dev/null 2>&1; then
      hosts_remove_block || warn "hosts_remove_block reported failure (continuing)"
    else
      warn "lib/network.sh not present; /etc/hosts block must be removed manually."
      warn "Look for lines between '# >>> ai-stack' and '# <<< ai-stack' markers."
    fi
    # Tear down macOS loopback aliases + persistence plist (mirrors what
    # prepare-sudo installed).
    if declare -F lo0_remove_aliases >/dev/null 2>&1; then
      log "Removing 127.0.10.x loopback aliases..."
      lo0_remove_aliases || warn "lo0_remove_aliases reported failure (continuing)"
    fi
    if declare -F lo0_uninstall_persistence_plist >/dev/null 2>&1; then
      log "Removing loopback persistence plist..."
      lo0_uninstall_persistence_plist || warn "plist uninstall reported failure (continuing)"
    fi
    if command -v ollama >/dev/null; then
      log "Removing all Ollama models..."
      ollama list 2>/dev/null | awk 'NR>1{print $1}' | while IFS= read -r m; do
        ollama rm "$m" 2>/dev/null && ok "ollama rm $m"
      done
    fi
    ok "NUKE complete. Backups under data.bak-${ts}/ and .env.bak-${ts}."
    ;;
esac
