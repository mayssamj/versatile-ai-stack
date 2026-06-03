#!/usr/bin/env bash
# smoke/00n.sh — networking foundation smoke (Safety Reviewer 2).
#
# Runs after Phase 00·N completes. This is the smoke that the Phase 01
# incident proved was missing — a verifying probe of the routing chain
# BEFORE any service container is launched. If this passes, Phase 01 can
# trust that docker port-publish to 127.0.10.x will actually carry traffic.
#
# This is a thin wrapper around Phase 00·V's probes — Phase 00·V exists for
# the install-time flow (decides whether to proceed); 00n.sh exists for the
# `vz-ai-stack.sh test 00n` flow (operator runs it on demand to gate a release).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/network.sh"
source "$AI_STACK/installer/lib/verify.sh"

hdr "Smoke 00·N — networking foundation"

aliases_load || { err "could not load aliases.tsv"; exit 1; }

# 1. /etc/hosts ownership.
log "/etc/hosts owner = root:wheel, mode 644..."
verify_etc_hosts_correctly_owned || { err "/etc/hosts ownership regressed"; exit 1; }
ok "/etc/hosts ownership OK"

# 2. Every alias bound to lo0 AND routable.
log "loopback alias routability sweep (all ${#ALIASES_LIST[@]} aliases)..."
verify_sweep_aliases || { err "alias routability sweep failed"; exit 1; }
ok "all ${#ALIASES_LIST[@]} aliases bound to lo0 and routable"

# 3. DNS resolution matches.
log "litellm DNS resolution..."
verify_dns_flush_propagates litellm "${ALIAS_IP[litellm]}" \
  || { err "DNS resolution mismatch"; exit 1; }
ok "litellm resolves correctly via dscacheutil + getent"

# 4. host-gateway works.
log "--add-host=ollama:host-gateway works inside a container..."
verify_add_host_works ollama \
  || { err "host-gateway support broken"; exit 1; }
ok "host-gateway resolves in container probes"

# 5. End-to-end routing chain (the actual Phase 01 bug repro).
log "docker port-publish to 127.0.10.x → curl → 200 ..."
PROBE_IP="${ALIAS_IP[phoenix-otlp]}"
verify_docker_port_publish_actually_routes "$PROBE_IP" 65183 \
  || { err "end-to-end routing chain broken"; exit 1; }
ok "docker publish → lo0 → host curl works end-to-end"

ok "Smoke 00·N — networking foundation — complete"
