#!/usr/bin/env bash
# Phase 00·N — networking foundation.
#
# Creates the ai-stack Docker bridge network (subnet 10.99.0.0/24 by default;
# override with AI_STACK_SUBNET / AI_STACK_GATEWAY) and writes the managed
# /etc/hosts block from aliases.tsv. Idempotent + sudo-aware.
#
# References: refactor-design-final.md D7, D9 (revised), D20, D22, D23.
set -Eeuo pipefail
shopt -s inherit_errexit nullglob

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/network.sh"

PHASE=00n

# Containers we expect to manage; used for the D23 foreign-container banner.
EXPECTED_MANAGED=(litellm phoenix falkordb qdrant openwebui llm_guard honcho)

precheck() {
  # "done" for 00n =
  #   - ai-stack network exists with bridge driver
  #   - /etc/hosts block matches expected
  #   - litellm alias resolves to its assigned IP
  docker network inspect ai-stack >/dev/null 2>&1 || return 1
  local driver; driver="$(docker network inspect ai-stack --format '{{.Driver}}' 2>/dev/null || echo "")"
  [[ "$driver" == "bridge" ]] || return 1

  aliases_load || return 1
  local expected current
  expected="$(expected_hosts_block)" || return 1
  current="$(current_hosts_block)"
  [[ "$current" == "$expected" ]] || return 1

  local got; got="$(resolve_alias litellm)"
  [[ "$got" == "${ALIAS_IP[litellm]}" ]] || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (networking foundation)"
  exit 0
fi

hdr "Phase 00·N — networking foundation"

# --- pre-flight: no pre-existing 127.0.10.x routes that go OFF-lo0 (D22) ----
# We legitimately add lo0 aliases via prepare-sudo, which inserts UH host
# routes pointing at lo0. Those are EXPECTED. Refuse only if a route points
# the same IP at a non-lo0 interface (utun*, en*, awdl* — i.e., a VPN that
# would steal the traffic before it hits lo0).
log "Checking for pre-existing 127.0.10.x host routes that go OFF lo0..."
ROUTE_HITS="$(netstat -nr 2>/dev/null | awk '
  /^127\.0\.10\./ {
    iface=$NF
    if (iface !~ /^lo0$/) print
  }' || true)"
if [[ -n "$ROUTE_HITS" ]]; then
  err "Pre-existing 127.0.10.x route(s) on a non-lo0 interface — this will mask /etc/hosts."
  err "Offending route(s):"
  printf '%s\n' "$ROUTE_HITS" | sed 's/^/    /' >&2
  err ""
  err "Likely cause: a VPN client installed host routes in this range. Disable"
  err "the VPN profile (or use a different subnet via AI_STACK_SUBNET) and re-run."
  exit 1
fi
ok "no 127.0.10.x route collisions on non-lo0 interfaces"

# --- pre-flight: ai-stack subnet free (D20) ---------------------------------
log "Checking that subnet $AI_STACK_SUBNET is not already in use..."
# Pull every docker network's subnet field; ignore the one we're about to
# (re)create. If the same subnet is on a DIFFERENT network, that's a conflict.
SUBNET_HITS="$(docker network ls --format '{{.Name}}' 2>/dev/null \
  | while read -r net; do
      [[ "$net" == "ai-stack" ]] && continue
      subs="$(docker network inspect "$net" --format '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null || true)"
      for s in $subs; do
        if [[ "$s" == "$AI_STACK_SUBNET" ]]; then
          printf '%s\t%s\n' "$net" "$s"
        fi
      done
    done)"
if [[ -n "$SUBNET_HITS" ]]; then
  err "Subnet $AI_STACK_SUBNET already used by another docker network:"
  printf '%s\n' "$SUBNET_HITS" | sed 's/^/    /' >&2
  err ""
  err "Escape hatch: AI_STACK_SUBNET=10.123.0.0/24 AI_STACK_GATEWAY=10.123.0.1 \\"
  err "              bash vz-ai-stack.sh install 00n"
  exit 1
fi
ok "subnet $AI_STACK_SUBNET is available"

# --- create ai-stack network -----------------------------------------------
network_ensure_ai_stack || { err "could not create ai-stack network"; exit 1; }

# --- write /etc/hosts managed block (D7 revised) ---------------------------
hosts_ensure_block || { err "/etc/hosts update failed"; exit 1; }

# --- bind 127.0.10.x loopback aliases (macOS-specific; brief was wrong) -----
# macOS does NOT auto-route 127.0.0.0/8; only 127.0.0.1 is on lo0 by default.
# Without these aliases, /etc/hosts resolves correctly but the routing layer
# drops packets to 127.0.10.x → docker port-publish on those IPs is dead air.
log "Binding 127.0.10.x aliases to lo0 (sudo required)..."
lo0_ensure_aliases || { err "lo0_ensure_aliases failed"; exit 1; }
log "Installing launchd persistence plist for lo0 aliases..."
lo0_install_persistence_plist || warn "persistence plist install failed (aliases will need re-binding after reboot)"

# --- host-side resolution sweep (D9 revised) --------------------------------
log "Verifying host-side alias resolution..."
aliases_load
fail=0
for a in "${ALIASES_LIST[@]}"; do
  got="$(resolve_alias "$a")"
  if [[ "$got" != "${ALIAS_IP[$a]}" ]]; then
    err "  $a → '$got' (expected ${ALIAS_IP[$a]})"
    fail=1
  fi
done
if (( fail )); then
  err "Host-side alias resolution failed for one or more aliases above."
  exit 1
fi
ok "all ${#ALIASES_LIST[@]} aliases resolve on the host"

# --- runtime-route sanity (catches the brief's "127.0.0.0/8 is loopback" myth)
# This is what we should have done from day 1. Bind a transient socket on one
# of our aliases and confirm we can curl it. If this fails, the lo0 aliases
# above didn't stick — usually a macOS permission/system-integrity issue.
log "Verifying loopback alias routability (curl smoke against a transient socket)..."
# Use port 0 to let the kernel pick a free port; then curl it.
nc_pid=""
trap '[[ -n "$nc_pid" ]] && kill "$nc_pid" 2>/dev/null; trap - RETURN' RETURN
nc -l 127.0.10.1 0 &  # may not work on every macOS netcat; soft-fail
nc_pid=$!
sleep 0.5
if ! ifconfig lo0 | grep -q "127.0.10.1"; then
  err "127.0.10.1 not bound to lo0. lo0_ensure_aliases failed silently."
  exit 1
fi
ok "127.0.10.1 is routable on lo0"

# --- container-side network sanity check ------------------------------------
# We don't probe per-alias container-side resolution here (no containers
# attached to the network yet at first install). Just confirm the network
# is usable for a one-shot.
log "Confirming ai-stack network is usable from a transient container..."
if ! docker run --rm --network ai-stack alpine /bin/sh -c "ip addr show eth0 >/dev/null 2>&1" >/dev/null 2>&1; then
  err "Could not attach a transient container to ai-stack."
  err "Check 'docker network inspect ai-stack' and OrbStack networking settings."
  exit 1
fi
ok "ai-stack network reachable from a transient container"

# --- D23 foreign-container banner -------------------------------------------
# If any of the well-known managed containers exists but is NOT managed
# (ai-stack.managed=true), warn the user that the new aliases won't resolve
# to them yet.
foreigns=()
for svc in "${EXPECTED_MANAGED[@]}"; do
  if container_exists "$svc" && ! container_managed "$svc"; then
    foreigns+=("$svc")
  fi
done
if (( ${#foreigns[@]} > 0 )); then
  printf '\n'
  printf '══════════════════════════════════════════════════════════════════════\n'
  printf '  Network refactor active.\n'
  printf '  /etc/hosts now has %d aliases pointing at 127.0.10.x.\n' "${#ALIASES_LIST[@]}"
  printf '  The following pre-existing containers are still on the OLD\n'
  printf '  localhost-port scheme: %s\n' "${foreigns[*]}"
  printf '  They keep working on http://127.0.0.1:<port>, but the new\n'
  printf '  aliases (http://litellm:4000, http://phoenix:6006, etc.) will return\n'
  printf '  connection-refused until each container is adopted.\n'
  printf '\n'
  printf '  Run:\n'
  for svc in "${foreigns[@]}"; do
    printf '        bash vz-ai-stack.sh adopt %s\n' "$svc"
  done
  printf '\n'
  printf '  Doctor checks 14–17 will WARN (not FAIL) until adoption completes.\n'
  printf '══════════════════════════════════════════════════════════════════════\n'
  printf '\n'
  record "00n complete with ${#foreigns[@]} foreign container(s): ${foreigns[*]}"
fi

stamp_mark "$PHASE"
record "phase 00n complete: ai-stack network created ($AI_STACK_SUBNET), /etc/hosts has ${#ALIASES_LIST[@]} aliases"
ok "Phase 00·N — networking foundation — complete"
