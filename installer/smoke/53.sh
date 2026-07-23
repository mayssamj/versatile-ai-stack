#!/usr/bin/env bash
# Smoke for the container-liveness doctor check (installer/doctor/checks/53_container_liveness.sh).
# Named 53.sh so `mayssam-ai-stack.sh test 53` resolves it (cmd_test strips after '_').
#
# WHY: doctor reported "all green" for hours while autofyn-agent crash-looped and
# llm_guard sat dead — no check asserted "every stack container that exists is
# actually running". This pins that the check:
#   - FLAGS a broken container via EACH census signal (managed label, ai-stack
#     network, derived/known compose-project)
#   - FLAGS each BROKEN STATE: exited, crash-looping (restarting), unhealthy
#   - does NOT flag: a healthy owned container, a fresh container whose healthcheck
#     is still "starting", a FOREIGN (non-stack) container, or an openshell-* one
#
# Uses throwaway alpine containers (no bind mounts -> safe from any worktree path);
# always cleans up. Skips cleanly if docker is unavailable.
# Run: bash installer/smoke/53.sh   (or: mayssam-ai-stack.sh test 53)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export AI_STACK
source "$AI_STACK/installer/lib/common.sh"

P=liveness-smoke
NAMES=("${P}-owned-dead" "${P}-owned-up" "${P}-net-dead" "${P}-proj-dead" \
  "${P}-foreign-dead" "openshell-${P}-dead" "${P}-restart-loop" \
  "${P}-unhealthy" "${P}-starting")
cleanup() { docker rm -f "${NAMES[@]}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

hdr "Smoke 53 — container liveness census"

command -v docker >/dev/null 2>&1 || { warn "docker CLI absent — skipping (not a failure)"; exit 0; }
docker info  >/dev/null 2>&1 || { warn "docker engine down — skipping (not a failure)"; exit 0; }

# Load the check into scope exactly as doctor.sh does.
declare -a CHECKS=()
declare -A CHECK_TITLE=()
source "$AI_STACK/installer/doctor/checks/53_container_liveness.sh"

run_diag() { set +e; DIAG_OUT="$(container_liveness_diagnose 2>&1)"; DIAG_RC=$?; set -e; }
flags()    { grep -q "$1" <<<"$DIAG_OUT"; }
# poll until `docker inspect -f <fmt>` equals <want>, up to <timeout>s (default 20)
poll() { local name="$1" fmt="$2" want="$3" t="${4:-20}" i; for ((i=0;i<t;i++)); do
  [[ "$(docker inspect -f "$fmt" "$name" 2>/dev/null || true)" == "$want" ]] && return 0; sleep 1; done; return 1; }

pass=0; fail=0
ok()  { pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
no()  { fail=$((fail+1)); printf '  ✗ %s\n' "$1"; printf '    --- diagnose output ---\n%s\n' "$DIAG_OUT"; }

# --- Setup throwaway containers ---
# 1. owned via LABEL + exited
docker run -d --name "${P}-owned-dead"   --label ai-stack.managed=true alpine sh -c 'exit 1' >/dev/null
# 2. owned via LABEL + healthy/up
docker run -d --name "${P}-owned-up"     --label ai-stack.managed=true alpine sleep 600 >/dev/null
# 3. owned via COMPOSE-PROJECT (autofyn) + exited  -> the autofyn census path
docker run -d --name "${P}-proj-dead"    --label com.docker.compose.project=autofyn alpine sh -c 'exit 1' >/dev/null
# 4. FOREIGN (no signal) + exited -> must NOT be flagged
docker run -d --name "${P}-foreign-dead" alpine sh -c 'exit 1' >/dev/null
# 5. openshell-* + exited. NOTE: we give it the managed label ON PURPOSE — that
#    makes it "owned", so the only reason it's skipped is the openshell-* name
#    exclusion. (A label-less container would be skipped for being unowned, which
#    would not actually test the exclusion.)
docker run -d --name "openshell-${P}-dead" --label ai-stack.managed=true alpine sh -c 'exit 1' >/dev/null
# 6. owned via NETWORK + exited (only if the real ai-stack network exists)
NET_CASE=skip
if docker network inspect ai-stack >/dev/null 2>&1; then
  docker run -d --name "${P}-net-dead" --network ai-stack alpine sh -c 'exit 1' >/dev/null && NET_CASE=run
fi
# 7. owned via LABEL + CRASH-LOOP (restarting) — the autofyn-agent failure mode
docker run -d --name "${P}-restart-loop" --restart=always --label ai-stack.managed=true alpine sh -c 'exit 1' >/dev/null
# 8. owned via LABEL + UNHEALTHY healthcheck — the llm_guard-class failure mode
docker run -d --name "${P}-unhealthy" --label ai-stack.managed=true \
  --health-cmd='false' --health-interval=1s --health-timeout=1s --health-retries=1 alpine sleep 600 >/dev/null
# 9. owned via LABEL + health=STARTING (fresh) — must NOT be flagged (grace period)
docker run -d --name "${P}-starting" --label ai-stack.managed=true \
  --health-cmd='true' --health-interval=30s --health-start-period=30s --health-timeout=1s alpine sleep 600 >/dev/null

# Let exits settle; wait for the deterministic states the assertions depend on.
sleep 2
poll "${P}-restart-loop" '{{.State.Status}}' restarting 25 || warn "restart-loop didn't reach 'restarting' in time"
poll "${P}-unhealthy"    '{{.State.Health.Status}}' unhealthy 15 || warn "unhealthy didn't reach 'unhealthy' in time"

run_diag

flags "${P}-owned-dead"     && ok "flags exited container owned via managed label"  || no "did NOT flag managed+exited"
flags "${P}-proj-dead"      && ok "flags exited container owned via compose-project" || no "did NOT flag autofyn-project+exited (the autofyn gap)"
flags "${P}-restart-loop"   && ok "flags CRASH-LOOPING container (restarting)"        || no "did NOT flag crash-loop (the autofyn-agent failure mode)"
flags "${P}-unhealthy"      && ok "flags UNHEALTHY container (healthcheck failing)"   || no "did NOT flag unhealthy"
flags "${P}-owned-up"       && no "false-flagged a HEALTHY owned container"           || ok "does not flag healthy owned container"
flags "${P}-starting"       && no "false-flagged a container in health=starting"      || ok "does not flag health=starting (grace period honored)"
flags "${P}-foreign-dead"   && no "false-flagged a FOREIGN (non-stack) container"     || ok "does not flag foreign container (scoping holds)"
flags "openshell-${P}-dead" && no "flagged an openshell-* container (should exclude)" || ok "excludes openshell-* even when owned (deferred to 24/39/43)"
[[ $DIAG_RC -ne 0 ]] && ok "diagnose returns non-zero when a broken owned container exists" || no "diagnose returned 0 despite broken owned containers"
if [[ $NET_CASE == run ]]; then
  flags "${P}-net-dead" && ok "flags exited container owned via ai-stack network" || no "did NOT flag ai-stack-network+exited"
else
  warn "ai-stack network absent — skipped the network-signal case (not a failure)"
fi

echo
if (( fail == 0 )); then printf '✓ 53 container_liveness: %d checks passed\n' "$pass"; exit 0
else printf '✗ 53 container_liveness: %d passed, %d FAILED\n' "$pass" "$fail"; exit 1; fi
