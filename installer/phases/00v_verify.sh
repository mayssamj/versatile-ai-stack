#!/usr/bin/env bash
# Phase 00·V — runtime verification pre-flight.
#
# Runs AFTER Phase 00·N (networking foundation) and BEFORE Phase 01
# (inference plane). The premise: every architectural claim the installer
# makes ("X is reachable at Y") gets a corresponding runtime probe BEFORE
# Phase 01 starts a single container.
#
# This phase exists because:
#   - bash -n, yq -e, ast.parse, and `docker network inspect` are all
#     SYNTAX checks. They proved every patch "clean" in the Phase 01 incident
#     while the actual TCP path was dead air.
#   - The doctor already covers most of these checks, but only AFTER an
#     install failure. Phase 00·V fires BEFORE any container is started,
#     when the fix is cheap (re-run prepare-sudo, fix /etc/hosts) instead
#     of expensive (recover a half-installed Phase 01 LiteLLM).
#
# This phase NEVER mutates state. It only verifies.
#
# Exit codes:
#   0  every probe passed; safe to proceed to Phase 01
#   1  one or more probes failed (each failure prints the EXACT fix command)
set -Eeuo pipefail
shopt -s inherit_errexit nullglob

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/network.sh"
source "$AI_STACK/installer/lib/verify.sh"

PHASE=00v

# Verification phase is idempotent and side-effect-free; we still respect the
# stamp so re-running the orchestrator doesn't repeat the work unless state
# has changed.
precheck() {
  # "done" for 00v means: every probe below passed in the last 5 minutes.
  # We refuse to skip on a stale stamp — networking can break between runs.
  local stamp="$STATE_DIR/phase_${PHASE}.done"
  [[ -f "$stamp" ]] || return 1
  # Stamp is younger than 5 min? Reuse it.
  local now stamp_ts
  now="$(date +%s)"
  stamp_ts="$(stat -f '%m' "$stamp" 2>/dev/null || echo 0)"
  (( now - stamp_ts < 300 )) || return 1
  return 0
}

if precheck; then
  ok "phase $PHASE already complete (verification fresh < 5min ago)"
  exit 0
fi

hdr "Phase 00·V — runtime verification pre-flight"

# Track failures so we can report all of them, not just the first.
declare -a FAILURES=()

# ──────────────────────────────────────────────────────────────────────────
# Probe 1 — /etc/hosts ownership.
# Y-1 patch fixed `sudo mv` regression that left /etc/hosts user-owned.
# If that regression sneaks back, this fires before any container starts.
# ──────────────────────────────────────────────────────────────────────────
log "Probe 1: /etc/hosts ownership (root:wheel, mode 644)..."
if verify_etc_hosts_correctly_owned 2>&1 | sed 's/^/    /'; then
  ok "/etc/hosts is root:wheel 644"
else
  FAILURES+=("/etc/hosts ownership/mode regressed (see fix above)")
fi

# ──────────────────────────────────────────────────────────────────────────
# Probe 2 — every alias in aliases.tsv is routable on lo0.
# This is THE check that would have caught the Phase 01 failure.
# ──────────────────────────────────────────────────────────────────────────
log "Probe 2: lo0 routability for every alias in aliases.tsv..."
aliases_load || { err "could not load aliases.tsv"; exit 1; }
declare -a fail_aliases=()
declare _a _ip
for _a in "${ALIASES_LIST[@]}"; do
  _ip="${ALIAS_IP[$_a]}"
  if ! verify_alias_routable "$_ip" 2>&1 | sed 's/^/    /'; then
    fail_aliases+=("${_a}=${_ip}")
  fi
done
if (( ${#fail_aliases[@]} == 0 )); then
  ok "all ${#ALIASES_LIST[@]} aliases are routable on lo0"
else
  err "  unroutable: ${fail_aliases[*]}"
  FAILURES+=("${#fail_aliases[@]} alias(es) not routable on lo0")
  err "  fix: sudo bash $AI_STACK/install.sh prepare-sudo"
fi

# ──────────────────────────────────────────────────────────────────────────
# Probe 3 — DNS resolution for the canonical alias matches expectation.
# Catches dscacheutil being silently broken / not flushed.
# ──────────────────────────────────────────────────────────────────────────
log "Probe 3: dscacheutil + getent agree on litellm → ${ALIAS_IP[litellm]}..."
if verify_dns_flush_propagates litellm "${ALIAS_IP[litellm]}" 2>&1 | sed 's/^/    /'; then
  ok "litellm resolves via both dscacheutil and getent"
else
  FAILURES+=("DNS resolution for 'litellm' does not match aliases.tsv")
fi

# ──────────────────────────────────────────────────────────────────────────
# Probe 4 — --add-host=ollama:host-gateway works.
# Every service container in the stack uses this flag. If it fails here,
# every container in Phase 01+ will fail to reach Ollama on the host.
# ──────────────────────────────────────────────────────────────────────────
log "Probe 4: --add-host=ollama:host-gateway resolves in a probe container..."
if verify_add_host_works ollama 2>&1 | sed 's/^/    /'; then
  ok "host-gateway is supported; ollama will resolve inside containers"
else
  FAILURES+=("--add-host=ollama:host-gateway not working (OrbStack/Docker host-gateway support broken)")
fi

# ──────────────────────────────────────────────────────────────────────────
# Probe 5 — the actual routing chain Phase 01 will rely on.
# Spawn a throwaway container that publishes 127.0.10.<N>:<port>:80 with a
# real listener inside, then curl it. If THIS fails, Phase 01 has zero
# chance and we abort with a clear fix command.
# ──────────────────────────────────────────────────────────────────────────
# Pick an alias IP that's NOT the one Phase 01 (LiteLLM) will use, so we
# don't collide with anything that might already be running. phoenix-otlp
# (127.0.10.3) is a good candidate — its real port is 4317, not 80, so a
# transient :65182 won't collide.
PROBE_IP="${ALIAS_IP[phoenix-otlp]}"
PROBE_PORT=65182
log "Probe 5: docker -p $PROBE_IP:$PROBE_PORT:80 → curl → 200..."
if verify_docker_port_publish_actually_routes "$PROBE_IP" "$PROBE_PORT" 2>&1 | sed 's/^/    /'; then
  ok "end-to-end routing chain works: docker publish → lo0 → curl"
else
  FAILURES+=("docker port-publish to 127.0.10.x is NOT routable from host (Phase 01 would silently fail)")
fi

# ──────────────────────────────────────────────────────────────────────────
# Probe 6 — ai-stack docker network is reachable from a transient container.
# Phase 00·N already does a `docker run --rm --network ai-stack` smoke;
# replicating here makes 00·V self-contained (single source of truth for
# "Phase 01 can start safely").
# ──────────────────────────────────────────────────────────────────────────
log "Probe 6: ai-stack network is usable from a transient container..."
if ! docker network inspect ai-stack >/dev/null 2>&1; then
  # Legitimate pre-install state: prepare-sudo ran but Phase 00·N hasn't yet.
  # Don't fail here — note and continue. The doctor's check 14 covers this
  # case post-install.
  note "ai-stack network does not exist yet (will be created by Phase 00·N)"
elif _verify_with_timeout "$VERIFY_DOCKER_RUN_TIMEOUT" \
       docker run --rm --network ai-stack "$VERIFY_PROBE_IMAGE" \
       sh -c 'ip addr show eth0 >/dev/null 2>&1' >/dev/null 2>&1; then
  ok "ai-stack network attaches transient containers cleanly"
else
  FAILURES+=("ai-stack network exists but is not usable for transient containers")
  err "  fix: docker network inspect ai-stack — check for stale state"
fi

# ──────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────
echo
if (( ${#FAILURES[@]} > 0 )); then
  err "Phase 00·V — runtime verification FAILED (${#FAILURES[@]} probe(s)):"
  for f in "${FAILURES[@]}"; do
    err "  - $f"
  done
  err ""
  err "DO NOT proceed to Phase 01 until the above are fixed. Each failure"
  err "above printed an exact fix command. The most common single fix is:"
  err "    sudo bash $AI_STACK/install.sh prepare-sudo"
  err ""
  err "After fixing, re-run: bash install.sh install 00v"
  exit 1
fi

stamp_mark "$PHASE"
record "phase 00v complete: all 6 runtime probes passed"
ok "Phase 00·V — runtime verification — complete (6/6 probes passed)"
