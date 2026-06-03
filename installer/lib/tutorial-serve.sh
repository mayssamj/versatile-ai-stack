#!/usr/bin/env bash
# tutorial-serve.sh — `vz-ai-stack.sh tutorial-serve [--port N] [--ttl 30m] [--revoke]`
#
# Serves doc/TUTORIAL.html with safe 'Try it live' demos. Mints an EPHEMERAL,
# LOCAL-ONLY, budget-capped, short-TTL LiteLLM virtual key, then runs a loopback
# proxy (installer/lib/tutorial_proxy.py) that injects the key SERVER-SIDE — the
# browser never holds a token. The key auto-revokes on Ctrl-C / exit (and via
# LiteLLM's own TTL); `--revoke` kills a lingering one.
set -Eeuo pipefail
shopt -s inherit_errexit
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

PORT=8899
TTL="30m"
REVOKE_ONLY=0
HTML="$AI_STACK/doc/TUTORIAL.html"
STATE="$AI_STACK/installer/state/tutorial-token"   # holds the live ephemeral key (0600)
LITELLM="$(get_env LITELLM_BASE_URL 'http://litellm:4000')"
# Local runtimes only — keeps the live demo FREE (no subscription quota) + safe.
DEMO_MODELS='["local","local-gemma4","local-qwen3.6","local-qwen3-coder"]'
DEMO_MODELS_DISPLAY="local,local-gemma4,local-qwen3.6,local-qwen3-coder"

for a in "$@"; do
  case "$a" in
    --port=*) PORT="${a#*=}" ;;
    --port)   shift; PORT="${1:-8899}" ;;
    --ttl=*)  TTL="${a#*=}" ;;
    --revoke) REVOKE_ONLY=1 ;;
    -h|--help)
      cat <<EOF
vz-ai-stack.sh tutorial-serve [--port N] [--ttl 30m] [--revoke]
  Serve doc/TUTORIAL.html + a loopback proxy for safe 'Try it live' demos.
  Mints an ephemeral, local-only, budget-capped LiteLLM key (auto-revoked on exit).
  --port N    loopback port (default 8899)
  --ttl 30m   key time-to-live (LiteLLM duration; default 30m)
  --revoke    revoke a lingering tutorial key and exit
EOF
      exit 0 ;;
  esac
done

MASTER="$(get_env LITELLM_MASTER_KEY '')"

revoke_key() {
  local k; k="$(cat "$STATE" 2>/dev/null || true)"
  [[ -n "$k" && -n "$MASTER" ]] || { rm -f "$STATE"; return 0; }
  curl -s --max-time 10 -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' \
    -X POST "$LITELLM/key/delete" -d "{\"keys\":[\"$k\"]}" >/dev/null 2>&1 || true
  rm -f "$STATE"
  ok "revoked tutorial demo key"
}

if (( REVOKE_ONLY )); then
  revoke_key; exit 0
fi

[[ -n "$MASTER" ]] || { err "LITELLM_MASTER_KEY missing from .env — run 'vz-ai-stack.sh install 01' first."; exit 1; }
curl -sf --max-time 5 "$LITELLM/health/readiness" >/dev/null 2>&1 || curl -sf --max-time 5 "$LITELLM/v1/models" -H "Authorization: Bearer $MASTER" >/dev/null 2>&1 \
  || { err "LiteLLM not reachable at $LITELLM — start it: bash $AI_STACK/bin/start-litellm.sh"; exit 1; }

# Revoke any stale key from a previous run, then mint a fresh ephemeral one.
revoke_key
log "Minting an ephemeral, local-only, budget-capped tutorial key (ttl=$TTL)..."
RESP="$(curl -s --max-time 15 -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' \
  -X POST "$LITELLM/key/generate" \
  -d "{\"models\":${DEMO_MODELS},\"duration\":\"${TTL}\",\"max_budget\":0.5,\"budget_duration\":\"1d\",\"key_alias\":\"tutorial-demo\",\"metadata\":{\"owner\":\"tutorial-serve\"}}")"
KEY="$(printf '%s' "$RESP" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("key",""))
except Exception: print("")')"
[[ -n "$KEY" ]] || { err "Failed to mint tutorial key. LiteLLM response:"; printf '%s\n' "$RESP" | head -3; exit 1; }
umask 077; printf '%s' "$KEY" > "$STATE"
ok "minted tutorial key (local-only, \$0.50 cap, ttl=$TTL) — never exposed to the browser"

# Auto-revoke + cleanup on any exit.
trap 'revoke_key' EXIT INT TERM

[[ -f "$HTML" ]] || warn "doc/TUTORIAL.html not present yet — the page will 503 until it's built; /api demos still work."

# NOT exec — keep the bash EXIT/INT/TERM trap alive so the key auto-revokes when
# the server stops (exec would replace the shell and orphan the trap).
TUT_PORT="$PORT" TUT_LITELLM="$LITELLM" TUT_KEY="$KEY" TUT_HTML="$HTML" TUT_MODELS="$DEMO_MODELS_DISPLAY" \
  python3 "$AI_STACK/installer/lib/tutorial_proxy.py"
