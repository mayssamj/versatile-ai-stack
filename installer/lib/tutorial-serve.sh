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
CONFIG="$AI_STACK/litellm/config.yaml"
# Demo allowlist = EVERY chat model wired into LiteLLM (local + LM Studio +
# Claude-subscription + cloud), minus embedding models. Listing or calling these
# loads nothing into memory (Ollama is lazy, LM Studio is opt-in, cloud/sub are
# remote); the $0.50 budget cap + short TTL below bound any cloud/subscription
# spend. Falls back to a minimal local set if config.yaml / yq is unavailable.
DEMO_MODELS='["local","local-gemma4"]'
DEMO_MODELS_DISPLAY="local,local-gemma4"
if command -v yq >/dev/null 2>&1 && [[ -f "$CONFIG" ]]; then
  _demo_csv="$(yq -r '.model_list[].model_name' "$CONFIG" 2>/dev/null \
    | grep -vE '^embed-' | awk 'NF' | sort -u | paste -sd, -)"
  if [[ -n "$_demo_csv" ]]; then
    DEMO_MODELS_DISPLAY="$_demo_csv"
    DEMO_MODELS="$(printf '%s' "$_demo_csv" | python3 -c 'import sys,json; print(json.dumps([m for m in sys.stdin.read().strip().split(",") if m]))')"
  fi
fi

# while-loop parser so BOTH `--port N`/`--ttl 30m` (space) and `--port=N`/`--ttl=30m`
# (equals) forms work (the old for-loop+shift silently dropped the space form).
while (( $# )); do
  case "$1" in
    --port=*) PORT="${1#*=}" ;;
    --port)   shift; PORT="${1:-8899}" ;;
    --ttl=*)  TTL="${1#*=}" ;;
    --ttl)    shift; TTL="${1:-30m}" ;;
    --revoke) REVOKE_ONLY=1 ;;
    -h|--help)
      cat <<EOF
vz-ai-stack.sh tutorial-serve [--port N] [--ttl 30m] [--revoke]
  Serve doc/TUTORIAL.html + a loopback proxy for safe 'Try it live' demos.
  Mints an ephemeral, budget-capped LiteLLM key allowlisted to your wired models
  (auto-revoked on exit).
  --port N    loopback port (default 8899)
  --ttl 30m   key time-to-live (LiteLLM duration; default 30m)
  --revoke    revoke a lingering tutorial key and exit
EOF
      exit 0 ;;
    *) err "unknown argument: $1 (try --help)"; exit 2 ;;
  esac
  shift
done

# Validate before either value reaches a JSON payload (TTL) or a socket bind (PORT).
[[ "$PORT" =~ ^[0-9]{2,5}$ ]] || { err "invalid --port '$PORT' (expected a number)"; exit 2; }
[[ "$TTL"  =~ ^[0-9]+[smhd]$ ]] || { err "invalid --ttl '$TTL' (expected e.g. 30m, 2h, 1d)"; exit 2; }

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

# Pre-flight the port BEFORE minting a key. A previous tutorial-serve whose
# terminal was closed (no Ctrl-C) orphans its proxy, which keeps LISTENing on the
# port; the old code then minted a key, failed to bind ("Errno 48: Address already
# in use"), revoked, and exited 1. Now: if OUR stale proxy holds the port, stop it
# and reuse the port; if a FOREIGN process holds it, fail with a clear message
# (and no wasted mint) pointing at --port.
ensure_port_free() {
  local port="$1" holders pid cmd killed=0 i
  command -v lsof >/dev/null 2>&1 || return 0   # can't check — let bind try (old behavior)
  holders="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)"
  [[ -z "$holders" ]] && return 0
  for pid in $holders; do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    if [[ "$cmd" == *tutorial_proxy.py* || "$cmd" == *tutorial-serve.sh* ]]; then
      warn "Port $port held by a stale tutorial-serve (PID $pid) — stopping it."
      kill "$pid" 2>/dev/null || true
      killed=1
    else
      err "Port $port is already in use by PID $pid — not a tutorial-serve process:"
      err "  $cmd"
      err "Free that port, or pick another: vz-ai-stack.sh tutorial-serve --port <N>"
      exit 1
    fi
  done
  (( killed )) || return 0
  for i in $(seq 1 12); do            # wait up to ~6s for the stale instance to release
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1 || { ok "freed port $port"; return 0; }
    sleep 0.5
  done
  err "Port $port still busy after stopping the stale instance — retry, or use --port <N>."
  exit 1
}

[[ -n "$MASTER" ]] || { err "LITELLM_MASTER_KEY missing from .env — run 'vz-ai-stack.sh install 01' first."; exit 1; }
curl -sf --max-time 5 "$LITELLM/health/readiness" >/dev/null 2>&1 || curl -sf --max-time 5 "$LITELLM/v1/models" -H "Authorization: Bearer $MASTER" >/dev/null 2>&1 \
  || { err "LiteLLM not reachable at $LITELLM — start it: bash $AI_STACK/bin/start-litellm.sh"; exit 1; }

# Free the port (stop a stale own-instance / fail clearly on a foreign holder)
# BEFORE minting, so a port conflict can never strand a freshly-minted key.
ensure_port_free "$PORT"

# Revoke any stale key from a previous run, then mint a fresh ephemeral one.
revoke_key
log "Minting an ephemeral, budget-capped tutorial key allowlisted to your wired models (ttl=$TTL)..."
RESP="$(curl -s --max-time 15 -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' \
  -X POST "$LITELLM/key/generate" \
  -d "{\"models\":${DEMO_MODELS},\"duration\":\"${TTL}\",\"max_budget\":0.5,\"budget_duration\":\"1d\",\"key_alias\":\"tutorial-demo\",\"metadata\":{\"owner\":\"tutorial-serve\"}}")"
KEY="$(printf '%s' "$RESP" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("key",""))
except Exception: print("")')"
[[ -n "$KEY" ]] || { err "Failed to mint tutorial key. LiteLLM response:"; printf '%s\n' "$RESP" | head -3; exit 1; }
umask 077; printf '%s' "$KEY" > "$STATE"
ok "minted tutorial key (\$0.50 cap, ttl=$TTL, allowlisted to your wired models) — never exposed to the browser"

# Auto-revoke + cleanup on any exit.
trap 'revoke_key' EXIT INT TERM

[[ -f "$HTML" ]] || warn "doc/TUTORIAL.html not present yet — the page will 503 until it's built; /api demos still work."

# NOT exec — keep the bash EXIT/INT/TERM trap alive so the key auto-revokes when
# the server stops (exec would replace the shell and orphan the trap).
# Pass the key by FILE PATH (TUT_KEY_FILE -> the 0600 $STATE file), not as an env
# var, so the secret never shows up in `ps`/process environment to other local users.
TUT_PORT="$PORT" TUT_LITELLM="$LITELLM" TUT_KEY_FILE="$STATE" TUT_HTML="$HTML" TUT_ROOT="$AI_STACK" TUT_MODELS="$DEMO_MODELS_DISPLAY" \
  python3 "$AI_STACK/installer/lib/tutorial_proxy.py"
