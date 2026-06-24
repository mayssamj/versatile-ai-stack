#!/usr/bin/env bash
# integration-tests/05-hermes-dashboard-failover.sh
#
# OPT-IN regression test for the hardened Hermes Workspace image: when the
# Hermes dashboard (:9119) is DOWN but the gateway (:8642) is up, the workspace
# falls back to the gateway sessions path. The UNHARDENED image crashes there
# with a 500 "Cannot read properties of undefined (reading 'map')"; the hardened
# image (.aistack-build/Dockerfile guards `sessions2.map`) must instead return
# HTTP 200 with an EMPTY list and recover when the dashboard returns.
#
# This MUTATES the live stack (stops the dashboard s6 service, restarts the
# workspace) and restores it, so it is NOT part of the always-on smoke. Run it
# explicitly after an install:
#   AISTACK_INTEGRATION=1 bash installer/integration-tests/05-hermes-dashboard-failover.sh
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

if [[ "${AISTACK_INTEGRATION:-}" != "1" ]]; then
  warn "integration test skipped — set AISTACK_INTEGRATION=1 to run (it stops the dashboard + restarts the workspace, then restores)."
  exit 0
fi

hdr "Integration 05 — Hermes Workspace dashboard-down failover"

AG="$(docker ps --format '{{.Names}}' | grep hermes-workspace | grep hermes-agent | head -1)"
WS="$(docker ps --format '{{.Names}}' | grep hermes-workspace | grep -v hermes-agent | head -1)"
[[ -n "$AG" && -n "$WS" ]] || { warn "agent/workspace containers not running — skipping"; exit 0; }

# s6-svc lives under /command in this base image; the dashboard scandir is
# /run/service/dashboard. Resolve the binary so we don't depend on PATH.
S6SVC="$(docker exec "$AG" sh -c 'command -v s6-svc 2>/dev/null || ls /command/s6-svc 2>/dev/null' | head -1)"
[[ -n "$S6SVC" ]] || { warn "s6-svc not found in the agent image — cannot toggle the dashboard; skipping"; exit 0; }

restore() {
  docker exec "$AG" "$S6SVC" -u /run/service/dashboard >/dev/null 2>&1 || true
  docker restart "$WS" >/dev/null 2>&1 || true
}
trap restore EXIT  # always bring the dashboard back, even on failure

wait_healthy() { # $1 = container
  for _ in $(seq 1 30); do
    [[ "$(docker inspect "$1" --format '{{.State.Health.Status}}' 2>/dev/null)" == "healthy" ]] && return 0
    sleep 2
  done
  return 1
}

fail=0

log "1/4 — taking the dashboard DOWN (gateway stays up)"
docker exec "$AG" "$S6SVC" -d /run/service/dashboard
sleep 3
# curl -w always prints %{http_code} (000 on connect failure). Use `|| true` —
# NOT `|| echo 000` — so a non-zero curl exit (the dashboard IS down here) does
# not abort the assignment under `set -e`, and there is no "000000" double-print.
dash="$(docker exec "$AG" sh -c 'curl -s -o /dev/null -w "%{http_code}" --max-time 4 http://127.0.0.1:9119/api/status' 2>/dev/null || true)"; dash="${dash:-000}"
gw="$(docker exec "$AG" sh -c 'curl -s -o /dev/null -w "%{http_code}" --max-time 4 http://127.0.0.1:8642/health' 2>/dev/null || true)"; gw="${gw:-000}"
[[ "$dash" != "200" && "$gw" == "200" ]] \
  && ok "dashboard down ($dash), gateway up ($gw)" \
  || { warn "expected dashboard down + gateway 200, got dashboard=$dash gateway=$gw"; }

log "2/4 — forcing the workspace to re-probe (dashboard now unavailable)"
docker restart "$WS" >/dev/null 2>&1
wait_healthy "$WS" || warn "workspace did not report healthy in time"

log "3/4 — THE ASSERTION: /api/sessions must be 200 + empty, NOT a 500 crash"
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://workspace:3000/api/sessions 2>/dev/null || true)"; code="${code:-000}"
body="$(curl -s --max-time 10 http://workspace:3000/api/sessions 2>/dev/null | head -c 200 || true)"
if [[ "$code" == "200" ]] && printf '%s' "$body" | grep -q '"sessions"'; then
  ok "dashboard DOWN → /api/sessions = 200 (graceful: $body) — hardening holds"
else
  err "dashboard DOWN → /api/sessions = HTTP $code (body: $body) — the hardened guard did NOT hold (a 500 means the unpatched base is running; re-run 'vz-ai-stack.sh install 05')"
  fail=1
fi

log "4/4 — restoring the dashboard + verifying recovery"
docker exec "$AG" "$S6SVC" -u /run/service/dashboard >/dev/null 2>&1
sleep 3
docker restart "$WS" >/dev/null 2>&1
wait_healthy "$WS" || true
rcode="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 http://workspace:3000/api/sessions 2>/dev/null || true)"; rcode="${rcode:-000}"
[[ "$rcode" == "200" ]] && ok "dashboard restored → /api/sessions = 200 (recovered)" \
  || { warn "post-restore /api/sessions = HTTP $rcode"; }

# Leave the EXIT trap ARMED through both exits — restore is idempotent (s6-svc -u
# on an already-up service is a no-op; the extra workspace bounce is harmless) so
# the dashboard is guaranteed back even if step 4's restore partially failed.
if [[ "$fail" == 0 ]]; then
  ok "dashboard-down failover: PASS"; exit 0
else
  err "dashboard-down failover: FAIL"; exit 1
fi
