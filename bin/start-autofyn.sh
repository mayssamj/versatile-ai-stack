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

# Make the :stable image's /app win over the mounted /workspace. autofyn's own compose mounts
# `.:/workspace` with working_dir=/workspace for DEV mode (live source overrides the baked image),
# but the stack runs autofyn as a RUNTIME off :stable, and the host checkout is a clone of the PUBLIC
# repo that LAGS the image (even production@HEAD lacks SANDBOX_KIND_DOCKER). So `python -m server`
# puts cwd=/workspace on sys.path[0] and the stale /workspace/config/constants.py SHADOWS
# /app/config/constants.py → `ImportError: cannot import name 'SANDBOX_KIND_DOCKER'` → crash-loop
# (the watchdog W1 then halts the agent). PYTHONSAFEPATH=1 (py3.11+) disables the automatic
# cwd/script-dir sys.path prepend so /app (PYTHONPATH=/app) wins. Injected via a stack-managed
# compose override (compose auto-merges docker-compose.override.yml) so autofyn's own compose stays
# pristine for actual autofyn devs. Idempotent.
_af_override="$AF/docker-compose.override.yml"
if [[ ! -f "$_af_override" ]] || ! grep -q 'PYTHONSAFEPATH:' "$_af_override" 2>/dev/null; then
  cat > "$_af_override" <<'YAML'
# ai-stack managed (bin/start-autofyn.sh / doctor check 69) — do NOT hand-edit.
# PYTHONSAFEPATH=1 makes the :stable image's /app win over the mounted /workspace (a clone of the
# public repo that LAGS the image): without it `python -m server` puts cwd=/workspace on sys.path[0]
# and the stale /workspace/config/constants.py shadows /app/config/constants.py → ImportError. py3.11+.
services:
  agent:
    environment:
      PYTHONSAFEPATH: "1"
YAML
  ok "autofyn: wrote docker-compose.override.yml (PYTHONSAFEPATH=1 — image /app wins over the /workspace shadow)"
fi

case "${1:-}" in
  --recreate)  (cd "$AF" && docker compose down && docker compose up -d) ;;
  *)           (cd "$AF" && docker compose up -d) ;;
esac
ok "autofyn compose up"
