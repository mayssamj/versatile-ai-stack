#!/usr/bin/env bash
# start-aitown.sh — managed launcher for the AI Town compose stack (Phase 36).
#
# WHY THIS EXISTS
#   AI Town is a 3-container Convex compose stack (backend + frontend + dashboard)
#   under the stable project name `aitown`. This is the single funnel that brings it
#   up, enforces per-container resource caps, and health-gates the frontend — so
#   `vz-ai-stack.sh start aitown` (no args → `install`) and the phase do the IDENTICAL
#   thing. It is a COMPOSE stack, so it does NOT use docker.sh's recreate_guard
#   (docker-run only); it drives `docker compose` directly like start-honcho.sh /
#   start-deerflow.sh / start-autofyn.sh.
#
# RESOURCE CAPS (constitution: caps on EVERY container)
#   The override declares deploy.resources.limits (compose v2 honors these on
#   `docker compose up`). As a belt-and-suspenders enforce/verify pass — so the cap
#   holds even on an engine that ignores `deploy:` — this script ALSO runs
#   `docker update --memory/--cpus` on each container after up and asserts the limit
#   actually landed (docker inspect HostConfig.Memory != 0).
#
# DATA SAFETY (constitution §8 + [[project_fleet_durability]])
#   The Convex world is a SQLite DB BIND-MOUNTED to $AI_STACK/data/aitown/convex, so
#   no `down -v` can wipe it. Teardown default = `down` (PRESERVES). `uninstall --nuke`
#   does `down -v` + removes the data dir AFTER a timestamped backup, and warns that
#   the admin key is invalidated (regenerate via `install 36`).
#
# Usage: start-aitown.sh [install|run|up|uninstall|stop|status|restart] [--nuke] [--recreate]
#   (no arg) / install / up   bring the stack up (build if needed) + caps + health-gate
#   run                       alias of install (the `start aitown` entrypoint)
#   stop                      `docker compose down` (PRESERVES the world; idempotent)
#   uninstall [--nuke]        down (no -v). --nuke = down -v + rm data (backup-first)
#   status                    compose ps + caps + live frontend health probe
#   restart                   down, then up
#   --recreate (with up)      down then up (force a fresh container set; data preserved)
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "bin/start-aitown.sh: needs bash 5+" >&2; exit 2
fi

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/network.sh"
aliases_load

AT_DIR="$AI_STACK/ai-town"
AT_DATA="$AI_STACK/data/aitown"
AT_PROJECT="aitown"
AT_IP="${ALIAS_IP[aitown]:-127.0.10.19}"
AT_FE_PORT="${ALIAS_HOST_PORT[aitown]:-5273}"

# Per-service caps (service-name → "memBytes cpus"). Kept in sync with the override's
# deploy.resources.limits; this is the enforce/verify floor.
declare -A AT_CAP_MEM=( [backend]=3221225472 [frontend]=2147483648 [dashboard]=1073741824 )  # 3g / 2g / 1g
declare -A AT_CAP_CPU=( [backend]=2.0        [frontend]=2.0        [dashboard]=1.0 )

# Compose helper: always pass BOTH files so `up` and `down` match (override carries the
# project name, ports, caps, restart policy, bind mount).
_compose() {
  ( cd "$AT_DIR" && docker compose -p "$AT_PROJECT" -f docker-compose.yml -f docker-compose.override.yml "$@" )
}

_present() { [[ -f "$AT_DIR/docker-compose.yml" && -f "$AT_DIR/docker-compose.override.yml" ]]; }

_healthy() {
  curl -sL -m 5 -o /dev/null -w '%{http_code}' "http://$AT_IP:$AT_FE_PORT/" 2>/dev/null | grep -q '^200$'
}

# Resolve a container id for a compose service (empty if not up).
_cid() { _compose ps -q "$1" 2>/dev/null | head -1; }

# Belt-and-suspenders cap enforce + VERIFY. Asserts the limit actually landed.
_apply_caps() {
  local svc cid memlimit cpus
  for svc in backend frontend dashboard; do
    cid="$(_cid "$svc")"
    [[ -n "$cid" ]] || { warn "caps: $svc has no running container — skipping (start may have partially failed)"; continue; }
    docker update --memory "${AT_CAP_MEM[$svc]}" --memory-swap "${AT_CAP_MEM[$svc]}" --cpus "${AT_CAP_CPU[$svc]}" "$cid" >/dev/null 2>&1 || true
    memlimit="$(docker inspect -f '{{.HostConfig.Memory}}' "$cid" 2>/dev/null || echo 0)"
    if [[ "${memlimit:-0}" -gt 0 ]]; then
      ok "caps: $svc → mem $(( memlimit / 1024 / 1024 ))MB, cpus ${AT_CAP_CPU[$svc]} (verified)"
    else
      warn "caps: $svc memory limit did NOT land (HostConfig.Memory=0) — the engine may reject live --memory updates; the override's deploy.limits still apply on a fresh 'up'."
    fi
  done
}

_do_up() {
  _present || { err "AI Town not installed at $AT_DIR — run 'bash $AI_STACK/vz-ai-stack.sh install 36' first."; exit 1; }
  network_ensure_ai_stack || { err "ai-stack docker network missing. Run: bash $AI_STACK/vz-ai-stack.sh install 00n"; exit 1; }
  mkdir -p "$AT_DATA/convex"

  # Idempotent: if all 3 are already running, this is a no-op success (print the line
  # cmd_start greps for so a reconciled start doesn't pop a browser tab).
  local running; running="$(_compose ps --status running -q 2>/dev/null | grep -c . || true)"
  if [[ "${1:-}" != "--recreate" && "${running:-0}" -ge 3 ]]; then
    ok "aitown already running (3 containers up; use --recreate to rebuild — data preserved)"
    _apply_caps
    return 0
  fi
  [[ "${1:-}" == "--recreate" ]] && { log "aitown: --recreate → compose down (data preserved on the bind mount) then up"; _compose down || true; }

  log "aitown: docker compose up -d --build (FIRST build is HEAVY: Ubuntu+Node18+npm, several minutes)…"
  _compose up -d --build 2>&1 | tail -15 || { err "compose up failed — check 'docker compose -p $AT_PROJECT logs'"; exit 1; }

  _apply_caps

  # Health-gate the frontend (Vite can take a while on a cold/first build).
  log "aitown: waiting for the frontend on http://$AT_IP:$AT_FE_PORT/ (Vite cold-start can take 60-120s)…"
  local up=0 i
  for i in $(seq 1 60); do _healthy && { up=1; break; }; sleep 3; done
  if (( up )); then
    ok "aitown up — frontend healthy on http://$AT_IP:$AT_FE_PORT/  (alias: http://aitown:$AT_FE_PORT/)"
  else
    warn "aitown: frontend not serving 200 yet on http://$AT_IP:$AT_FE_PORT/ — the build/Vite may still be coming up. Watch: docker compose -p $AT_PROJECT logs -f frontend"
  fi
}

_do_status() {
  if ! _present; then echo "aitown not installed (no $AT_DIR/docker-compose.yml)"; return 0; fi
  echo "--- compose ps (project $AT_PROJECT) ---"
  _compose ps 2>/dev/null || echo "(compose ps failed — engine down?)"
  echo "--- caps ---"
  local svc cid mem
  for svc in backend frontend dashboard; do
    cid="$(_cid "$svc")"; [[ -n "$cid" ]] || { echo "  $svc: (not running)"; continue; }
    mem="$(docker inspect -f '{{.HostConfig.Memory}}' "$cid" 2>/dev/null || echo 0)"
    echo "  $svc: mem $(( ${mem:-0} / 1024 / 1024 ))MB"
  done
  if _healthy; then echo "frontend: http://$AT_IP:$AT_FE_PORT/ — HEALTHY (200)"; else echo "frontend: http://$AT_IP:$AT_FE_PORT/ — NOT healthy (building / down)"; fi
}

_do_uninstall() {
  _present || { ok "aitown not installed; nothing to stop."; exit 0; }
  if [[ "${1:-}" == "--nuke" ]]; then
    warn "aitown --nuke: 'docker compose down -v' WIPES the Convex world (SQLite) AND invalidates the admin key."
    # Backup-first checkpoint (fleet-durability discipline): copy the bind-mounted world
    # before any destructive step, so even --nuke is recoverable.
    if [[ -d "$AT_DATA/convex" ]]; then
      local ts bak; ts="$(date +%Y%m%d-%H%M%S)"; bak="$AT_DATA.bak-$ts"
      log "Checkpoint: $AT_DATA → $bak (backup-before-delete)…"
      # Fail-CLOSED: if the backup does not verifiably exist, do NOT wipe the world.
      # The old code warned and PROCEEDED to `down -v` + `rm -rf` even when the
      # backup failed — defeating the "backup-before-delete" discipline and losing
      # the Convex world irrecoverably. Matches reset.sh's nuke guard (AI_STACK_FORCE_WIPE
      # to override). (2026-07-05 takeover fix.)
      if cp -a "$AT_DATA" "$bak" 2>/dev/null && [[ -d "$bak/convex" ]]; then
        ok "world backed up → $bak"
      elif [[ "${AI_STACK_FORCE_WIPE:-0}" == "1" ]]; then
        warn "world backup FAILED but AI_STACK_FORCE_WIPE=1 — proceeding (you may lose the Convex world)"
      else
        err "ABORTING aitown --nuke: world backup failed and AI_STACK_FORCE_WIPE!=1 — NOTHING removed."
        err "Fix the backup target (disk space / perms), or set AI_STACK_FORCE_WIPE=1 to wipe anyway."
        exit 1
      fi
    fi
    _compose down -v 2>&1 | tail -8 || true
    rm -rf "$AT_DATA"
    note "aitown world removed. Re-install: 'vz-ai-stack.sh install 36' (regenerates the admin key + re-pushes the schema). Backup kept above."
    ok "aitown nuked (down -v + data removed; backup retained)"
  else
    _compose down 2>&1 | tail -8 || true
    ok "aitown stopped (compose down — the world at $AT_DATA/convex is PRESERVED)"
  fi
}

case "${1:-install}" in
  install|run|up|"")
    shift || true
    _do_up "${1:-}"
    exit 0 ;;
  stop)
    _present || { ok "aitown not installed; nothing to stop."; exit 0; }
    _compose down 2>&1 | tail -8 || true
    ok "aitown stopped (compose down — world preserved)"; exit 0 ;;
  uninstall)
    shift || true
    _do_uninstall "${1:-}"
    exit 0 ;;
  restart)
    _present || { err "aitown not installed"; exit 1; }
    _compose down || true
    _do_up
    exit 0 ;;
  status)
    _do_status
    exit 0 ;;
  *)
    echo "usage: start-aitown.sh [install|run|up|stop|uninstall [--nuke]|restart|status] [--recreate]" >&2
    exit 2 ;;
esac
