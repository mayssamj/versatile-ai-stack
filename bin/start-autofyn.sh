#!/usr/bin/env bash
# start-autofyn.sh — compose-based.
# Networking: if upstream compose joins the ai-stack network, the `autofyn`
# alias (127.0.10.13:80 → :3400) becomes live. Otherwise this is informational.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/network.sh"
aliases_load
AF="$AI_STACK/autofyn"
if [[ ! -f "$AF/docker-compose.yml" ]]; then
  note "autofyn upstream not present — skipping start."
  note "Configure manually after Phase 07; alias 'autofyn' (${ALIAS_IP[autofyn]:-127.0.10.13}:80 → :${ALIAS_CONTAINER_PORT[autofyn]:-3400}) is reserved."
  exit 0
fi

# Networking precondition: ai-stack network must exist (run Phase 00·N).
network_ensure_ai_stack || {
  err "ai-stack docker network missing. Run:  bash vz-ai-stack.sh install 00n"
  exit 1
}

# Bind the dashboard's published ports to BOTH 127.0.0.1 (so http://localhost:3400
# keeps working) AND autofyn's loopback alias 127.0.10.13 (so http://autofyn:3400 +
# the Caddy ingress http://autofyn/ work) — replacing upstream's 0.0.0.0 all-
# interfaces publish that exposed the dashboard to the LAN. Idempotent (marker-
# guarded; the patched "IP:PORT:PORT" form also won't re-match). The alias bind
# needs the 127.0.10.13 lo0 alias (prepare-sudo) — guarded below so a missing alias
# gives a clear instruction instead of a cryptic Docker "cannot assign" failure.
AF_BIND_IP="${ALIAS_IP[autofyn]:-127.0.10.13}"
if ! ifconfig lo0 2>/dev/null | grep -oE '127\.0\.10\.[0-9]+' | grep -qxF "$AF_BIND_IP"; then
  err "lo0 alias $AF_BIND_IP (autofyn) is missing — the dashboard binds it loopback-only and won't start without it."
  err "Run once:  sudo $AI_STACK/vz-ai-stack.sh prepare-sudo"
  exit 1
fi
if AF_IP="$AF_BIND_IP" python3 - "$AF/docker-compose.yml" <<'PYEOF'
import os, re, sys
p = sys.argv[1]; ip = os.environ["AF_IP"]
s = open(p).read()
if "ai-stack: loopback bind" in s:
    sys.exit(0)  # already patched — idempotent no-op
new, n = re.subn(
    r'\n( *)- "(340[01]:340[01])"',
    lambda m: '\n%s- "127.0.0.1:%s"\n%s- "%s:%s"  # ai-stack: loopback bind'
              % (m.group(1), m.group(2), m.group(1), ip, m.group(2)),
    s)
if n == 0:
    sys.exit(1)
open(p, "w").write(new)
PYEOF
then ok "autofyn: dashboard ports bound to 127.0.0.1 + ${AF_BIND_IP} (no 0.0.0.0)"
else warn "autofyn: dashboard ports not patched (compose format changed?) — may still bind 0.0.0.0"; fi

case "${1:-}" in
  --recreate)  (cd "$AF" && docker compose down && docker compose up -d) ;;
  *)           (cd "$AF" && docker compose up -d) ;;
esac
ok "autofyn compose up"
