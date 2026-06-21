#!/usr/bin/env bash
# Smoke for recreate_guard idempotency (installer/lib/docker.sh).
#
# WHY: `install all` aborted at a phase whenever a managed container existed but was
# STOPPED (e.g. after the user stops containers to free CPU): recreate_guard refused
# ("already exists, use --recreate") -> start script exit 1 -> set -e phase abort.
# The fix makes recreate_guard RECONCILE managed containers idempotently. This pins
# all four states so a future edit can't regress the recovery path.
#
#   managed + stopped -> `docker start` (data preserved), guard exits 0
#   managed + running -> no-op success, guard exits 0, container untouched
#   foreign (unmanaged) -> refuse (return 1), container untouched
#   absent -> proceed to docker run (return 0)
#
# Uses a throwaway alpine container (no bind mounts -> safe from any worktree path);
# always cleans up. Skips cleanly if docker is unavailable.
# Run: bash installer/smoke/recreate_guard.sh
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/docker.sh"

N=recreate-guard-smoke
cleanup() { docker rm -f "$N" "${N}-hold" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

hdr "Smoke recreate_guard — idempotent reconcile"

command -v docker >/dev/null 2>&1 || { warn "docker CLI absent — skipping (not a failure)"; exit 0; }
docker info  >/dev/null 2>&1 || { warn "docker engine down — skipping (not a failure)"; exit 0; }

running() { [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }

# Case 1: managed + stopped -> restarted (the bug this fixes)
docker run -d --name "$N" --label ai-stack.managed=true alpine sleep 600 >/dev/null
docker stop "$N" >/dev/null
running "$N" && { err "setup: container should be stopped"; exit 1; }
rc=0; ( recreate_guard "$N" "" ) >/dev/null 2>&1 || rc=$?
[[ $rc -eq 0 ]] || { err "stopped+managed: guard rc=$rc, want 0"; exit 1; }
running "$N"   || { err "stopped+managed: container was NOT restarted"; exit 1; }
ok "stopped+managed -> docker start (data preserved)"

# Case 2: managed + running -> no-op success
rc=0; ( recreate_guard "$N" "" ) >/dev/null 2>&1 || rc=$?
[[ $rc -eq 0 ]] || { err "running+managed: guard rc=$rc, want 0"; exit 1; }
running "$N"   || { err "running+managed: container stopped unexpectedly"; exit 1; }
ok "running+managed -> no-op success"

# Case 3: foreign (no managed label) -> refuse, untouched
docker rm -f "$N" >/dev/null
docker run -d --name "$N" alpine sleep 600 >/dev/null
docker stop "$N" >/dev/null
rc=0; ( recreate_guard "$N" "" ) >/dev/null 2>&1 || rc=$?
[[ $rc -eq 1 ]] || { err "foreign: guard rc=$rc, want 1 (refuse)"; exit 1; }
running "$N"  && { err "foreign: container was started — must stay untouched!"; exit 1; }
ok "foreign -> refused, untouched"

# Case 4: absent -> proceed (return 0)
docker rm -f "$N" >/dev/null
rc=0; ( recreate_guard "$N" "" ) >/dev/null 2>&1 || rc=$?
[[ $rc -eq 0 ]] || { err "absent: guard rc=$rc, want 0 (proceed)"; exit 1; }
ok "absent -> proceed to docker run"

# Case 5: managed + stopped, but `docker start` FAILS -> refuse (rc 1), untouched.
# Force the failure with a host-port collision (a 2nd container steals the port).
docker rm -f "$N" "${N}-hold" >/dev/null 2>&1 || true
PORT=53921
if lsof -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  warn "port $PORT busy — skipping docker-start-fails case (not a failure)"
else
  docker run -d --name "$N" --label ai-stack.managed=true -p "127.0.0.1:${PORT}:80" alpine sleep 600 >/dev/null
  docker stop "$N" >/dev/null
  docker run -d --name "${N}-hold" -p "127.0.0.1:${PORT}:80" alpine sleep 600 >/dev/null  # steal the port
  rc=0; ( recreate_guard "$N" "" ) >/dev/null 2>&1 || rc=$?
  docker rm -f "${N}-hold" >/dev/null 2>&1 || true
  [[ $rc -eq 1 ]] || { err "start-fails: guard rc=$rc, want 1 (refuse when docker start fails)"; exit 1; }
  running "$N" && { err "start-fails: container must stay stopped"; exit 1; }
  ok "managed+stopped, docker start fails -> refused (rc 1)"
fi

ok "recreate_guard idempotency: all cases pass"
