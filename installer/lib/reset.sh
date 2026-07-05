#!/usr/bin/env bash
# reset.sh — tiered destructive reset.
#   soft:  clears phase stamps + bin/. Keeps .env, data/, containers.
#   hard:  + `docker rm -f` managed containers + tear down ai-stack docker
#          network + data/* backed up to data.bak-<ts>/. Leaves /etc/hosts.
#   nuke:  + .env (backed up) + ollama models + /etc/hosts block removed.
#          User must type 'nuke ai-stack' literally.
#
# Non-interactive: `vz-ai-stack.sh reset --confirm hard --yes` exports
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
  WILL clear:  installer/state/*.done, *.alert, CHANGELOG.d/*
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
  WILL clear:  installer/state/*.done, *.alert, CHANGELOG.d/*
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
    # Loop in the CURRENT shell via process substitution (NOT a pipe) so a per-volume
    # skip is never lost in a subshell; use `warn` (not `err`) so a skip can't abort the reset.
    local v vbak
    while IFS= read -r v; do
      [[ -n "$v" ]] || continue
      # H8 — BACK UP the named volume BEFORE removing it (honcho_redis-data, autofyn_*,
      # hermes-workspace_* hold real DB/agent state with no other backup). Fail-CLOSED:
      # if the backup can't be written+verified, REFUSE the rm unless AI_STACK_FORCE_WIPE=1.
      vbak="$AI_STACK/data/volume-backups/${RESET_TS:-manual}"
      mkdir -p "$vbak" 2>/dev/null || true
      if docker run --rm -v "$v":/data:ro -v "$vbak":/out alpine \
           tar czf "/out/${v}.tgz" -C /data . >/dev/null 2>&1 && [[ -s "$vbak/${v}.tgz" ]]; then
        ok "backed up volume $v -> data/volume-backups/${RESET_TS:-manual}/${v}.tgz"
      elif [[ "${AI_STACK_FORCE_WIPE:-0}" == "1" ]]; then
        warn "volume $v backup FAILED but AI_STACK_FORCE_WIPE=1 — removing anyway"
      else
        warn "REFUSING to remove volume $v: backup failed (set AI_STACK_FORCE_WIPE=1 to wipe anyway)"; continue
      fi
      docker volume rm "$v" >/dev/null 2>&1 && ok "removed volume $v" || true
    done < <(docker volume ls -q --filter "label=com.docker.compose.project=$proj" 2>/dev/null)
    while IFS= read -r n; do
      [[ -n "$n" ]] && docker network rm "$n" >/dev/null 2>&1 && ok "removed network $n" || true
    done < <(docker network ls --format '{{.Name}}' --filter "label=com.docker.compose.project=$proj" 2>/dev/null)
  done
}

# Delete every OpenShell sandbox (hermes-fleet-v1, pi-v1, ...) so a fresh install
# recreates them cleanly. Best-effort; the gateway owns the actual containers.
teardown_openshell_sandboxes() {
  # H8 — resolve the gateway-MATCHING brew binary first. A bare PATH `openshell` may be
  # a version-skewed uv install that half-deletes (orphaning the gateway record).
  local osh=""
  if [[ -x /opt/homebrew/bin/openshell ]]; then osh=/opt/homebrew/bin/openshell
  else osh="$(command -v openshell 2>/dev/null || true)"; fi
  [[ -n "$osh" ]] || return 0
  # Loop in the CURRENT shell via process substitution (NOT a pipe): the fail-closed
  # _ck==2 guard + `continue` must execute in this shell, not a trapped pipe subshell.
  local sb _ck
  while IFS= read -r sb; do
    [[ -n "$sb" ]] || continue
    # H3 — CHECKPOINT before delete (this loop also catches user `fleet new` sandboxes
    # that hold real agent state). Fail-CLOSED: rc 2 = commit/verify failed → SKIP the
    # delete (leave it intact) unless AI_STACK_FORCE_WIPE=1.
    _ck=0; bash "$AI_STACK/bin/openshell-checkpoint.sh" "$sb" reset >/dev/null 2>&1 || _ck=$?
    if (( _ck == 2 )) && [[ "${AI_STACK_FORCE_WIPE:-0}" != "1" ]]; then
      warn "skipping delete of '$sb': pre-delete checkpoint FAILED (set AI_STACK_FORCE_WIPE=1 to delete anyway)"
      continue
    fi
    "$osh" sandbox delete "$sb" >/dev/null 2>&1 && ok "deleted openshell sandbox $sb (checkpointed)" \
      || warn "could not delete sandbox $sb (delete it manually if it lingers)"
  done < <("$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | awk 'NR>1 && $1!="" {print $1}')
  # H8 — orphan-token sweep, GUARDED: only clear bootstrap-token dirs when NO sandbox
  # remains. A silently-failed delete must NOT strip a still-running sandbox's token
  # (that would brick it). If any sandbox still lists, skip the sweep entirely.
  local remaining; remaining="$("$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | awk 'NR>1 && $1!="" {print $1}' | head -1)"
  if [[ -n "$remaining" ]]; then
    warn "orphan-token sweep SKIPPED: sandbox(es) still present (a failed delete must not strip a live token)"
  else
    local tokroot="$HOME/.local/state/openshell/docker-sandbox-tokens/default" d
    if [[ -d "$tokroot" ]]; then
      for d in "$tokroot"/*/; do
        [[ -d "$d" ]] && rm -rf "$d" 2>/dev/null && ok "cleaned orphan token dir $(basename "$d" | cut -c1-8)" || true
      done
    fi
  fi
}

# Stop every host-side daemon the stack starts via bin/start-<svc>.sh. These are
# NOT docker containers, so teardown_compose_projects / the ai-stack.managed
# sweep never touch them — after a hard/nuke they would keep holding their ports
# and break the next `install all` with "Port :X bound by another process".
#
# Derivation: services.yml entries with type python-bg | node-bg that run on the
# host (docs_mcp :8765, paperclip :3100 + its alias relay, unsloth :8898,
# claw3d :4310, claw3d_bridge :7780). hermes-telegram is intentionally EXCLUDED
# — it runs INSIDE the pi/hermes OpenShell sandbox and dies with
# teardown_openshell_sandboxes, so it is not a host daemon. compose/docker
# services (honcho, deerflow, autofyn, litellm, ...) are covered elsewhere.
#
# Each entry is "pidfile:port" where pidfile is the basename under
# installer/state (note claw3d-bridge.pid uses a hyphen, unlike its service
# name claw3d_bridge) and port is the TCP port to free if a stray process still
# holds it. Use port="" when there is no fixed port to reclaim.
HOST_DAEMONS=(
  "docs_mcp.pid:8765"
  "paperclip.pid:3100"
  "paperclip-relay.pid:3100"   # paperclip's 127.0.10.14:3100→127.0.0.1 forwarder (child daemon)
  "unsloth.pid:8898"
  "claw3d.pid:4310"
  "claw3d-bridge.pid:7780"
)

# kill_pid PID LABEL — SIGTERM, wait briefly, SIGKILL if still alive. Idempotent:
# silently returns if the pid is bogus or already dead.
kill_pid() {
  local pid="$1" label="$2" i=0
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  kill -0 "$pid" 2>/dev/null || return 0
  kill "$pid" 2>/dev/null || true
  while (( i < 5 )); do
    kill -0 "$pid" 2>/dev/null || { ok "stopped $label (pid $pid)"; return 0; }
    sleep 1; i=$((i+1))
  done
  kill -9 "$pid" 2>/dev/null || true
  sleep 1
  kill -0 "$pid" 2>/dev/null \
    && warn "could not kill $label (pid $pid) — stop it manually" \
    || ok "stopped $label (pid $pid, SIGKILL)"
}

# Stop all host daemons + free their ports + clear stale pidfiles. Idempotent,
# no-op if already stopped, loud (logs each stop). Always best-effort: a missing
# pidfile or already-dead process is fine.
teardown_host_daemons() {
  local entry pidfile port pidpath pid svc stray_pids spid
  for entry in "${HOST_DAEMONS[@]}"; do
    pidfile="${entry%%:*}"
    port="${entry#*:}"
    svc="${pidfile%.pid}"
    pidpath="$AI_STACK/installer/state/$pidfile"
    # (1) Stop the recorded PID (the daemon and any tracked child) if present.
    if [[ -f "$pidpath" ]]; then
      pid="$(cat "$pidpath" 2>/dev/null || echo "")"
      kill_pid "$pid" "$svc"
      rm -f "$pidpath"
    fi
    # (2) Free the known port even if the pidfile was stale/missing — a process
    #     whose pidfile we never recorded (or that recycled the PID) can still
    #     be squatting the port and would block the next install. Kill every
    #     LISTEN owner; lsof prints one PID per matching line.
    [[ -n "$port" ]] || continue
    # Capture LISTEN owners up-front. The `|| true` is load-bearing: lsof exits 1
    # when nothing is listening — the COMMON case right after we just killed the
    # daemon — and under `set -Eeuo pipefail` that 1 would abort the whole reset.
    # Looping over the captured var (not a pipe) also keeps kill_pid in THIS shell.
    stray_pids="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | sort -u || true)"
    for spid in $stray_pids; do
      [[ "$spid" =~ ^[0-9]+$ ]] || continue
      warn "stray process holding :$port (pid $spid) after $svc teardown — killing"
      kill_pid "$spid" "stray :$port owner"
    done
  done

  # (3) paperclip spawns a multi-process TREE (pnpm -> tsx -> dev-runner -> server)
  #     PLUS an embedded Postgres (:54329), tracked by paperclip's OWN adoptable-
  #     service registry, NOT by installer/state/paperclip.pid. If a half-dead
  #     watcher lingers (server stopped, process survives), the next `pnpm dev`
  #     ADOPTS it ("already running") and never starts a real server — so the relay
  #     forwards to a dead 127.0.0.1:3100 and `doctor` check 17 goes red. Steps
  #     (1)+(2) can't catch that (wrong pid; port already released). Sweep the whole
  #     tree BY PATH. Bracketed patterns ([t]ools) so this never matches the reset
  #     process itself. Does NOT touch ~/.paperclip data (user data, like models).
  local _pp _swept=0
  for _pp in '[t]ools/paperclip' '[.]paperclip/instances/default/db'; do
    if pgrep -f "$_pp" >/dev/null 2>&1; then pkill -TERM -f "$_pp" 2>/dev/null || true; _swept=1; fi
  done
  if (( _swept )); then
    sleep 2
    for _pp in '[t]ools/paperclip' '[.]paperclip/instances/default/db'; do
      if pgrep -f "$_pp" >/dev/null 2>&1; then pkill -KILL -f "$_pp" 2>/dev/null || true; fi
    done
    ok "swept stray paperclip process tree (dev-runner + embedded Postgres)"
  fi
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
    # Staged Hermes fleet artifacts (souls + bootstrap) are host-side; the sandbox
    # was deleted above, so clear these too — otherwise a re-rendered roster could
    # inherit a previous fleet's staged souls.
    rm -f "$AI_STACK"/openshell/fleet-souls/*.md "$AI_STACK"/openshell/fleet-bootstrap/bootstrap.sh 2>/dev/null || true
    # Sweep straggler pidfiles. teardown_host_daemons already removed the
    # HOST_DAEMONS ones; this also clears pidfiles for SANDBOX-resident daemons
    # (e.g. hermes-telegram.pid — the gateway runs inside hermes-fleet-v1 and dies
    # with it, leaving only a stale host pidfile). The openshell-watchdog is a
    # launchd job (no .pid file), so this can't orphan it. All host processes are
    # stopped by now, so any surviving .pid is stale.
    rm -f "$AI_STACK"/installer/state/*.pid
    rm -f "$AI_STACK"/installer/state/models-pending*.txt   # stale model-binding intents
    rm -rf "$AI_STACK"/CHANGELOG.d/*
    ok "soft reset complete."
    ;;
  hard)
    if ! confirm "Proceed with hard reset?" N; then exit 0; fi
    RESET_TS="$(date +%Y%m%d-%H%M%S)"; ts="$RESET_TS"
    log "Backing up data/ → data.bak-${ts}/ (H8: aborts the wipe if this fails)"
    # H7 — snapshot the gateway identity plane FIRST (DB + signing key) so a kid rotation
    # or torn DB stays recoverable (best-effort; non-fatal if the tool isn't present yet).
    [[ -x "$AI_STACK/bin/openshell-identity-backup.sh" ]] && bash "$AI_STACK/bin/openshell-identity-backup.sh" backup >/dev/null 2>&1 || true
    if cp -R "$AI_STACK/data" "$AI_STACK/data.bak-${ts}" && [[ -d "$AI_STACK/data.bak-${ts}" ]]; then
      ok "data/ backed up → data.bak-${ts}/"
    elif [[ "${AI_STACK_FORCE_WIPE:-0}" == "1" ]]; then
      warn "data/ backup FAILED but AI_STACK_FORCE_WIPE=1 — proceeding with the wipe"
    else
      err "ABORTING hard reset: data/ backup failed and AI_STACK_FORCE_WIPE!=1 — NOTHING wiped. Fix the cause or re-run with AI_STACK_FORCE_WIPE=1."
      exit 1
    fi
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
    while IFS= read -r c; do docker rm -f "$c" >/dev/null && ok "removed $c"; done \
      < <(docker ps -a --filter "label=ai-stack.managed=true" --format '{{.Names}}')
    # (4) Host-side daemons (docs_mcp, paperclip, unsloth, claw3d, claw3d-bridge)
    #     — NOT containers, so nothing above stops them; they'd keep their ports
    #     and break the next install. Free the ports + clear stale pidfiles.
    log "Stopping host daemons (docs_mcp, paperclip, unsloth, claw3d, claw3d-bridge)..."
    teardown_host_daemons
    log "Removing ai-stack docker network..."
    remove_ai_stack_network
    rm -f "$AI_STACK"/installer/state/phase_*.done
    # Staged Hermes fleet artifacts (souls + bootstrap) are host-side; the sandbox
    # was deleted above, so clear these too — otherwise a re-rendered roster could
    # inherit a previous fleet's staged souls.
    rm -f "$AI_STACK"/openshell/fleet-souls/*.md "$AI_STACK"/openshell/fleet-bootstrap/bootstrap.sh 2>/dev/null || true
    # Sweep straggler pidfiles. teardown_host_daemons already removed the
    # HOST_DAEMONS ones; this also clears pidfiles for SANDBOX-resident daemons
    # (e.g. hermes-telegram.pid — the gateway runs inside hermes-fleet-v1 and dies
    # with it, leaving only a stale host pidfile). The openshell-watchdog is a
    # launchd job (no .pid file), so this can't orphan it. All host processes are
    # stopped by now, so any surviving .pid is stale.
    rm -f "$AI_STACK"/installer/state/*.pid
    rm -f "$AI_STACK"/installer/state/models-pending*.txt   # stale model-binding intents
    # The OpenShell watchdog alert names a sandbox that teardown_openshell_sandboxes
    # just deleted — clear it so a stale storm/destroy alert can't survive the wipe
    # and fail doctor check 43 after the next install.
    rm -f "$AI_STACK"/installer/state/*.alert
    rm -rf "$AI_STACK"/CHANGELOG.d/*
    rm -rf "$AI_STACK"/data/{phoenix,falkor,qdrant,honcho,openwebui}/*
    # Bare-hostname host ingress (Phase 31, opt-in): a launchd daemon isn't a
    # HOST_DAEMONS pidfile, so teardown_host_daemons can't catch it — bootout the
    # root Caddy daemon + remove its plist/Caddyfile/logs + free :80/:443.
    [[ -f "$AI_STACK/installer/lib/ingress.sh" ]] && bash "$AI_STACK/installer/lib/ingress.sh" teardown hard || true
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
    RESET_TS="$(date +%Y%m%d-%H%M%S)"; ts="$RESET_TS"
    log "NUKE: backing up data/ + .env + gateway identity (H8: abort if a backup fails)"
    [[ -x "$AI_STACK/bin/openshell-identity-backup.sh" ]] && bash "$AI_STACK/bin/openshell-identity-backup.sh" backup >/dev/null 2>&1 || true
    if cp -R "$AI_STACK/data" "$AI_STACK/data.bak-${ts}" 2>/dev/null && [[ -d "$AI_STACK/data.bak-${ts}" ]]; then
      ok "data/ backed up → data.bak-${ts}/"
    elif [[ "${AI_STACK_FORCE_WIPE:-0}" == "1" ]]; then
      warn "data/ backup FAILED but AI_STACK_FORCE_WIPE=1 — proceeding with the nuke"
    else
      err "ABORTING nuke: data/ backup failed and AI_STACK_FORCE_WIPE!=1 — NOTHING removed."; exit 1
    fi
    if [[ -f "$AI_STACK/.env" ]]; then
      if cp -p "$AI_STACK/.env" "$AI_STACK/.env.bak-${ts}" && [[ -s "$AI_STACK/.env.bak-${ts}" ]]; then
        ok ".env backed up → .env.bak-${ts}"
      elif [[ "${AI_STACK_FORCE_WIPE:-0}" == "1" ]]; then
        warn ".env backup FAILED but AI_STACK_FORCE_WIPE=1 — proceeding (you may lose secrets/keys)"
      else
        err "ABORTING nuke: .env backup failed and AI_STACK_FORCE_WIPE!=1 — NOTHING removed (avoids the 2026-06-05 .env-loss class)."
        exit 1
      fi
    fi
    log "Deleting OpenShell sandboxes..."
    teardown_openshell_sandboxes
    log "Tearing down compose projects (honcho, deerflow, autofyn, hermes-workspace)..."
    teardown_compose_projects
    log "Stopping + removing managed ai-stack containers..."
    # A nuke must be EXHAUSTIVE: one container that fails to remove (odd state,
    # engine hiccup) must not abort the whole sweep under `set -e` and leave a
    # half-nuked stack. Warn + continue; surface any that could not be removed.
    # (2026-07-05 takeover fix.)
    local _rm_failed=()
    while IFS= read -r c; do
      docker rm -f "$c" >/dev/null 2>&1 || _rm_failed+=("$c")
    done < <(docker ps -a --filter "label=ai-stack.managed=true" --format '{{.Names}}')
    if (( ${#_rm_failed[@]} > 0 )); then
      warn "Could not remove ${#_rm_failed[@]} container(s): ${_rm_failed[*]} — remove manually: docker rm -f ${_rm_failed[*]}"
    fi
    # Sourcegraph data (~/.sourcegraph-local) lives OUTSIDE the repo data/ tree, so
    # the data/ backup above never covers it. The managed-label sweep removed the
    # container but not this dir. NUKE = remove everything → back it up (fail-closed,
    # same discipline as data//.env) then delete. (hard/soft INTENTIONALLY keep it so
    # bootstrap re-adopts the index + token on the next `install sourcegraph`.)
    if [[ -d "$HOME/.sourcegraph-local" ]]; then
      if tar czf "$AI_STACK/sourcegraph-local.bak-${ts}.tgz" -C "$HOME" .sourcegraph-local 2>/dev/null \
           && [[ -s "$AI_STACK/sourcegraph-local.bak-${ts}.tgz" ]]; then
        ok "~/.sourcegraph-local backed up → sourcegraph-local.bak-${ts}.tgz"
        rm -rf "$HOME/.sourcegraph-local" && ok "removed ~/.sourcegraph-local"
      elif [[ "${AI_STACK_FORCE_WIPE:-0}" == "1" ]]; then
        warn "~/.sourcegraph-local backup FAILED but AI_STACK_FORCE_WIPE=1 — removing anyway"
        rm -rf "$HOME/.sourcegraph-local"
      else
        warn "~/.sourcegraph-local backup failed — LEAVING it in place (re-run with AI_STACK_FORCE_WIPE=1 to force)"
      fi
    fi
    log "Stopping host daemons (docs_mcp, paperclip, unsloth, claw3d, claw3d-bridge)..."
    teardown_host_daemons
    log "Removing ai-stack docker network..."
    remove_ai_stack_network
    rm -f "$AI_STACK"/installer/state/phase_*.done
    # Staged Hermes fleet artifacts (souls + bootstrap) are host-side; the sandbox
    # was deleted above, so clear these too — otherwise a re-rendered roster could
    # inherit a previous fleet's staged souls.
    rm -f "$AI_STACK"/openshell/fleet-souls/*.md "$AI_STACK"/openshell/fleet-bootstrap/bootstrap.sh 2>/dev/null || true
    # Sweep straggler pidfiles. teardown_host_daemons already removed the
    # HOST_DAEMONS ones; this also clears pidfiles for SANDBOX-resident daemons
    # (e.g. hermes-telegram.pid — the gateway runs inside hermes-fleet-v1 and dies
    # with it, leaving only a stale host pidfile). The openshell-watchdog is a
    # launchd job (no .pid file), so this can't orphan it. All host processes are
    # stopped by now, so any surviving .pid is stale.
    rm -f "$AI_STACK"/installer/state/*.pid
    rm -f "$AI_STACK"/installer/state/models-pending*.txt   # stale model-binding intents
    rm -f "$AI_STACK"/installer/state/*.alert   # watchdog alert names a now-deleted sandbox (check 43)
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
    # Bare-hostname ingress (Phase 31): bootout the root Caddy daemon, remove its
    # plist/Caddyfile/logs, untrust the local CA + wipe the Caddy data dir.
    [[ -f "$AI_STACK/installer/lib/ingress.sh" ]] && bash "$AI_STACK/installer/lib/ingress.sh" teardown nuke || true
    if command -v ollama >/dev/null; then
      log "Removing all Ollama models..."
      ollama list 2>/dev/null | awk 'NR>1{print $1}' | while IFS= read -r m; do
        ollama rm "$m" 2>/dev/null && ok "ollama rm $m"
      done
    fi
    ok "NUKE complete. Backups under data.bak-${ts}/ and .env.bak-${ts}."
    ;;
esac
