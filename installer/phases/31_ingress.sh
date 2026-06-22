#!/usr/bin/env bash
# Phase 31 — bare-hostname host ingress (http(s)://litellm/). OPT-IN extra.
#
# A host-native Caddy binds each HTTP service's own 127.0.10.x:80/:443 and
# reverse-proxies to its native-port publish, giving the Mac browser port-free
# http://litellm/ + https://litellm/ — while name:port and container traffic are
# untouched. NOT in install_all_phase_order (opt-in). Needs a host Caddy (brew)
# and sudo to bind <1024 (a root LaunchDaemon).
#
# Standalone: bash vz-ai-stack.sh install 31   (or:  vz-ai-stack.sh install ingress)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/ingress.sh"

PHASE=31

# Done == caddy present AND the daemon is loaded.
precheck() {
  command -v caddy >/dev/null 2>&1 || return 1
  launchctl print "system/$INGRESS_LABEL" >/dev/null 2>&1 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (ingress daemon loaded)"
  exit 0
fi

hdr "Phase 31 — bare-hostname host ingress (http(s)://litellm/)"

# Caddy prerequisite — soft-fail (exit 0, no stamp) so a later re-run completes.
if ! command -v caddy >/dev/null 2>&1; then
  if command -v brew >/dev/null 2>&1; then
    log "Installing caddy (brew install caddy)..."
    brew install caddy 2>&1 | tail -5 || true
  fi
fi
if ! command -v caddy >/dev/null 2>&1; then
  warn "caddy not on PATH — install it ('brew install caddy'), then re-run 'vz-ai-stack.sh install ingress'."
  ok   "Phase 31 — skipped (caddy unavailable); not stamped — re-run later."
  exit 0
fi
ok "caddy present: $(ingress_caddy_bin) ($(caddy version 2>/dev/null | head -1))"

# Generate + validate the Caddyfile, then bring the daemon up (needs sudo to bind :80/:443).
ingress_up || true

if launchctl print "system/$INGRESS_LABEL" >/dev/null 2>&1; then
  stamp_mark "$PHASE"
  record "phase 31 complete: bare-hostname ingress (caddy, com.ai-stack.ingress daemon)"
  ok "Phase 31 — bare-hostname host ingress — complete"
  note "Browse:  http://litellm/   https://litellm/   (run 'vz-ai-stack.sh ingress trust' once for trusted https)"
  note "name:port and container traffic are unchanged — this only ADDS the port-free host form."
else
  warn "ingress daemon not loaded yet (binding :80/:443 needs sudo)."
  note "Finish with:  sudo bash vz-ai-stack.sh ingress up"
  ok   "Phase 31 — ran (Caddyfile generated); daemon not loaded, not stamped."
fi
exit 0
