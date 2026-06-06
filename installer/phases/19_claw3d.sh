#!/usr/bin/env bash
# Phase 19 — claw3d (3D agent office) + the stack-agents bridge.
#
# claw3d (github.com/iamlukethedev/claw3d) is a Next.js 3D "virtual office" that
# visualizes AI agents. It connects to an upstream runtime; we give it ONE
# generic upstream — the stack-agents bridge (claw3d-bridge/bridge.py) — which
# implements claw3d's "custom HTTP runtime" contract (/health, /state, /registry,
# /v1/chat/completions) and routes chat AUTHENTICALLY to every isolated agent:
#   - Hermes profiles ×9  → openshell sandbox exec → `hermes --profile X -z`
#   - Pi                  → openshell sandbox exec → `pi -p` in pi-v1
#   - DeerFlow            → POST :2026 LangGraph /runs/wait
# (AutoFyn is reserved as a future kind="task-launcher" — see bridge.py.)
#
# Both are HOST services (the bridge shells out to openshell + http; claw3d is a
# Node UI). claw3d serves at http://localhost:<port>; the bridge is internal on
# 127.0.0.1:<bridge port>. adapterType=custom is manual-connect in claw3d — the
# bridge URL is pre-filled via settings.json so it's one "Connect" click.
#
# Requires a LIVE OpenShell relay for the Hermes/Pi chat paths (HANDOFF §2.1);
# the bridge fails fast + shows "agent unavailable" if the relay is down.
#
# Standalone: `bash vz-ai-stack.sh install 19`.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/validate.sh"

PHASE=19
CLAW_DIR="$AI_STACK/claw3d"
CLAW_REPO="https://github.com/iamlukethedev/claw3d"
BRIDGE="$AI_STACK/claw3d-bridge/bridge.py"
CLAW3D_PORT="${CLAW3D_PORT:-4310}"
BRIDGE_PORT="${CLAW3D_BRIDGE_PORT:-7780}"
BRIDGE_URL="http://127.0.0.1:${BRIDGE_PORT}"
SETTINGS_DIR="$HOME/.openclaw/claw3d"

precheck() {
  [[ -d "$CLAW_DIR/node_modules" && -f "$CLAW_DIR/server/index.js" ]] || return 1
  [[ -f "$BRIDGE" ]] || return 1
  grep -q '^CLAW3D_GATEWAY_ADAPTER_TYPE=custom' "$CLAW_DIR/.env" 2>/dev/null || return 1
  # both services serving
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$BRIDGE_URL/health" 2>/dev/null)" != "000" ]] || return 1
  [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${CLAW3D_PORT}/" 2>/dev/null)" != "000" ]] || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 19 — claw3d — already running (open http://localhost:${CLAW3D_PORT})"
  exit 0
fi

hdr "Phase 19 — claw3d (3D agent office) + stack-agents bridge"

command -v node >/dev/null || { err "node not on PATH — run phase 00"; exit 1; }
command -v npm  >/dev/null || { err "npm not on PATH — run phase 00"; exit 1; }
command -v python3 >/dev/null || { err "python3 not on PATH"; exit 1; }
[[ -f "$BRIDGE" ]] || { err "bridge missing at $BRIDGE (claw3d-bridge/bridge.py)"; exit 1; }

# --- 1. Clone claw3d (idempotent) ---
if [[ ! -d "$CLAW_DIR/.git" ]]; then
  log "Cloning claw3d..."
  git clone --depth 1 "$CLAW_REPO" "$CLAW_DIR" 2>&1 | tail -3 || { err "git clone claw3d failed"; exit 1; }
fi

# --- 2. npm install (idempotent) ---
if [[ ! -d "$CLAW_DIR/node_modules" ]]; then
  log "Installing claw3d deps (npm install)..."
  ( cd "$CLAW_DIR" && npm install --no-audit --no-fund 2>&1 | tail -5 ) || { err "npm install failed"; exit 1; }
fi
[[ -f "$CLAW_DIR/server/index.js" ]] || { err "claw3d server/index.js missing after install"; exit 1; }

# --- 3. Wire claw3d → the bridge (custom HTTP runtime), all-local, no cloud ---
# .env (env-level) + ~/.openclaw/claw3d/settings.json (server reads this for the
# pre-filled gateway URL + adapterType). Voice (ElevenLabs) + Spotify left unset.
cat > "$CLAW_DIR/.env" <<ENVEOF
# ai-stack: rendered by installer/phases/19_claw3d.sh. Points claw3d at the
# stack-agents bridge (custom HTTP runtime). No cloud features.
NEXT_PUBLIC_GATEWAY_URL=$BRIDGE_URL
CLAW3D_GATEWAY_URL=$BRIDGE_URL
CLAW3D_GATEWAY_ADAPTER_TYPE=custom
CUSTOM_RUNTIME_ALLOWLIST=127.0.0.1,localhost
UPSTREAM_ALLOWLIST=127.0.0.1,localhost
DEBUG=false
ENVEOF
mkdir -p "$SETTINGS_DIR"
cat > "$SETTINGS_DIR/settings.json" <<JSONEOF
{ "gateway": { "url": "$BRIDGE_URL", "adapterType": "custom" } }
JSONEOF
chmod 600 "$SETTINGS_DIR/settings.json" 2>/dev/null || true
ok "wrote claw3d/.env + $SETTINGS_DIR/settings.json (custom runtime → $BRIDGE_URL)"

# --- 4. Start the bridge, then claw3d ---
log "Starting claw3d-bridge..."
CLAW3D_BRIDGE_PORT="$BRIDGE_PORT" bash "$AI_STACK/bin/start-claw3d-bridge.sh" || { err "bridge failed to start"; exit 1; }
log "Starting claw3d UI..."
CLAW3D_PORT="$CLAW3D_PORT" bash "$AI_STACK/bin/start-claw3d.sh" || { err "claw3d failed to start"; exit 1; }

# --- 5. Smoke: bridge contract + agent count ---
AGENTS_N="$(curl -s --max-time 5 "$BRIDGE_URL/state" | python3 -c 'import sys,json; print(len(json.load(sys.stdin).get("active",{})))' 2>/dev/null || echo 0)"
ok "bridge serving $AGENTS_N agents; claw3d UI up"

stamp_mark "$PHASE"
record "phase 19 complete: claw3d UI (:$CLAW3D_PORT) + stack-agents bridge (:$BRIDGE_PORT, $AGENTS_N agents)"
ok "Phase 19 — claw3d — complete"
note "Open:    http://localhost:${CLAW3D_PORT}    (click Connect — bridge URL $BRIDGE_URL is pre-filled)"
note "Agents:  Hermes ×7 + Pi + DeerFlow (authentic; needs the OpenShell relay up for Hermes/Pi)"
note "Bridge:  $BRIDGE_URL/state   (curl to see the agent registry)"
note "Logs:    installer/state/claw3d.log  +  installer/state/claw3d-bridge.log"
