#!/usr/bin/env bash
# tutorial-serve.sh — `mayssam-ai-stack.sh tutorial-serve [--port N] [--ttl 30m] [--revoke]`
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
FORCE=0            # --force: free the port even from a FOREIGN holder (kill + rebind)
LAUNCH_ENABLED=0   # opt-in: --launch-enabled wires TUT_LAUNCH=1 so the page's
                   # "Launch a service" buttons can idempotently start a web UI.
HTML="$AI_STACK/doc/TUTORIAL.html"
STATE="$AI_STACK/installer/state/tutorial-token"   # holds the live ephemeral key (0600)
LITELLM="$(get_env LITELLM_BASE_URL 'http://litellm:4000')"
# Read-only backends for the Act III memory + docs-search demos. Bare hostnames resolve via
# /etc/hosts (honcho->127.0.10.6, qdrant->127.0.10.5); if a box lacks the ingress aliases the
# bare name simply won't resolve and the route degrades to {available:false}. Reads only.
# Keys are repo-canonical and intentionally asymmetric: HONCHO_BASE_URL vs QDRANT_URL (the latter
# is what 06_documents.sh / the ingester read) — do NOT "fix" QDRANT_URL into QDRANT_BASE_URL.
HONCHO_URL="$(get_env HONCHO_BASE_URL 'http://honcho:8000')"
QDRANT_URL="$(get_env QDRANT_URL 'http://qdrant:6333')"
PHOENIX_URL="$(get_env PHOENIX_BASE_URL 'http://phoenix:6006')"   # WT-E: read-only /api/traces widget (Phoenix auth is OFF on the loopback build)
CONFIG="$AI_STACK/litellm/config.yaml"
# Demo allowlist = EVERY chat model wired into LiteLLM (local + LM Studio +
# Claude-subscription + cloud), minus embedding models. Listing or calling these
# loads nothing into memory (Ollama is lazy, LM Studio is opt-in, cloud/sub are
# remote); the $0.50 budget cap + short TTL below bound any cloud/subscription
# spend. Falls back to a minimal local set if config.yaml / yq is unavailable.
DEMO_MODELS='["local","local-heavy"]'
DEMO_MODELS_DISPLAY="local,local-heavy"
EMBED_MODEL=""   # local embedding model for the /api/embed demo (added to the key allowlist only)
if command -v yq >/dev/null 2>&1 && [[ -f "$CONFIG" ]]; then
  _chat_csv="$(yq -r '.model_list[].model_name' "$CONFIG" 2>/dev/null \
    | grep -vE '^embed-' | awk 'NF' | sort -u | paste -sd, -)"
  # Pick a LOCAL embedding model for the Embeddings demo (cloud embed-* may lack a key);
  # fall back to the first embed-* if there's no local one.
  EMBED_MODEL="$(yq -r '.model_list[].model_name' "$CONFIG" 2>/dev/null | grep -E '^embed-.*local' | head -1)"
  [[ -n "$EMBED_MODEL" ]] || EMBED_MODEL="$(yq -r '.model_list[].model_name' "$CONFIG" 2>/dev/null | grep -E '^embed-' | head -1)"
  if [[ -n "$_chat_csv" ]]; then
    DEMO_MODELS_DISPLAY="$_chat_csv"                 # chat picker = chat models only
    # Key allowlist = chat models + the embedding model so POST /api/embed works. The
    # embedding model is intentionally NOT in DISPLAY (it must not show in the chat picker).
    _key_csv="$_chat_csv"; [[ -n "$EMBED_MODEL" ]] && _key_csv="${_chat_csv},${EMBED_MODEL}"
    DEMO_MODELS="$(printf '%s' "$_key_csv" | python3 -c 'import sys,json; print(json.dumps([m for m in sys.stdin.read().strip().split(",") if m]))')"
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
    --force)  FORCE=1 ;;
    --launch-enabled) LAUNCH_ENABLED=1 ;;
    -h|--help)
      cat <<EOF
mayssam-ai-stack.sh tutorial-serve [--port N] [--ttl 30m] [--force] [--revoke] [--launch-enabled]
  Serve doc/TUTORIAL.html + a loopback proxy for safe 'Try it live' demos.
  Mints an ephemeral, budget-capped LiteLLM key allowlisted to your wired models
  (auto-revoked on exit).
  --port N    loopback port (default 8899)
  --ttl 30m   key time-to-live (LiteLLM duration; default 30m)
  --force     if the port is held, kill WHATEVER holds it (even a non-tutorial process)
              and rebind. Without --force a stale tutorial-serve is auto-reaped but a
              FOREIGN holder is reported and left alone. (Manual: lsof -ti tcp:8899 | xargs kill)
  --revoke    revoke a lingering tutorial key and exit
  --launch-enabled  EXPERIMENTAL (default OFF): enable the page's "Launch a service"
              buttons — they idempotently run \`mayssam-ai-stack.sh start <svc>\` for a small
              allowlist of watchable web UIs (openwebui, phoenix, autofyn, claw3d,
              chatdev, aitown). Loopback-only. Run from the MAIN checkout: 'start'
              refuses to run from a git worktree.
EOF
      exit 0 ;;
    *) err "unknown argument: $1 (try --help)"; exit 2 ;;
  esac
  shift
done

# Validate before either value reaches a JSON payload (TTL) or a socket bind (PORT).
[[ "$PORT" =~ ^[0-9]{2,5}$ ]] || { err "invalid --port '$PORT' (expected a number)"; exit 2; }
[[ "$TTL"  =~ ^[0-9]+[smhd]$ ]] || { err "invalid --ttl '$TTL' (expected e.g. 30m, 2h, 1d)"; exit 2; }
# Refuse --force on a privileged port (<1024) — a loopback dev serve never belongs there,
# and --force would SIGKILL whatever holds it (sshd/nginx/...). 10# forces base-10 so a
# zero-padded port can't be misread as octal. (A non-root bind to <1024 fails anyway.)
if (( FORCE )) && (( 10#$PORT < 1024 )); then
  err "--force on a privileged port ($PORT, <1024) is refused — pick --port <N> ≥ 1024"; exit 2
fi

MASTER="$(get_env LITELLM_MASTER_KEY '')"
DEMO_ALIAS="tutorial-demo"   # fixed key_alias minted below; LiteLLM enforces it unique

revoke_key() {
  rm -f "$STATE"
  [[ -n "$MASTER" ]] || return 0
  # Self-heal by ALIAS, not by a stored token: a crashed/SIGKILLed run skips the
  # EXIT trap (or loses $STATE) and orphans the key, and LiteLLM's unique-alias
  # rule then makes the next mint fail hard ("Key with alias 'tutorial-demo'
  # already exists"). Deleting every key carrying our alias clears that orphan
  # regardless of whether we still hold its token.
  litellm_master_curl -s --max-time 10 -H 'Content-Type: application/json' \
    -X POST "$LITELLM/key/delete" -d "{\"key_aliases\":[\"$DEMO_ALIAS\"]}" >/dev/null 2>&1 || true
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
    elif (( FORCE )); then
      warn "Port $port held by a FOREIGN process (PID $pid) — --force: killing it."
      warn "  $cmd"
      kill "$pid" 2>/dev/null || true
      killed=1
    else
      err "Port $port is already in use by PID $pid — not a tutorial-serve process:"
      err "  $cmd"
      err "Re-run with --force to kill it and rebind, or pick another: mayssam-ai-stack.sh tutorial-serve --port <N>"
      exit 1
    fi
  done
  (( killed )) || return 0
  for i in $(seq 1 12); do            # wait up to ~6s for the holder(s) to release
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1 || { ok "freed port $port"; return 0; }
    sleep 0.5
  done
  # Last resort under --force: SIGKILL the ORIGINAL holder set captured at entry, then
  # re-check once. Reusing $holders (NOT a fresh lsof) avoids a PID-reuse race where the
  # port's PID was recycled to an unrelated process between the TERM batch and now.
  if (( FORCE )); then
    warn "Port $port still busy — --force: sending SIGKILL to the original holder(s)."
    for pid in $holders; do kill -9 "$pid" 2>/dev/null || true; done
    sleep 0.5
    lsof -nP -iTCP:"$port" -sTCP:LISTEN -t >/dev/null 2>&1 || { ok "freed port $port"; return 0; }
  fi
  err "Port $port still busy after stopping the holder(s) — retry, use --force, or use --port <N>."
  exit 1
}

[[ -n "$MASTER" ]] || { err "LITELLM_MASTER_KEY missing from .env — run 'mayssam-ai-stack.sh install 01' first."; exit 1; }
curl -sf --max-time 5 "$LITELLM/health/readiness" >/dev/null 2>&1 || litellm_master_curl -sf --max-time 5 "$LITELLM/v1/models" >/dev/null 2>&1 \
  || { err "LiteLLM not reachable at $LITELLM — start it: bash $AI_STACK/bin/start-litellm.sh"; exit 1; }

# Free the port (stop a stale own-instance / fail clearly on a foreign holder)
# BEFORE minting, so a port conflict can never strand a freshly-minted key.
ensure_port_free "$PORT"

# Revoke any stale key from a previous run, then mint a fresh ephemeral one.
revoke_key
log "Minting an ephemeral, budget-capped tutorial key allowlisted to your wired models (ttl=$TTL)..."
RESP="$(litellm_master_curl -s --max-time 15 -H 'Content-Type: application/json' \
  -X POST "$LITELLM/key/generate" \
  -d "{\"models\":${DEMO_MODELS},\"duration\":\"${TTL}\",\"max_budget\":0.5,\"budget_duration\":\"1d\",\"key_alias\":\"${DEMO_ALIAS}\",\"metadata\":{\"owner\":\"tutorial-serve\"}}")"
KEY="$(printf '%s' "$RESP" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("key",""))
except Exception: print("")')"
[[ -n "$KEY" ]] || { err "Failed to mint tutorial key. LiteLLM response:"; printf '%s\n' "$RESP" | head -3; exit 1; }
umask 077; printf '%s' "$KEY" > "$STATE"
ok "minted tutorial key (\$0.50 cap, ttl=$TTL, allowlisted to your wired models) — never exposed to the browser"

# Auto-revoke + cleanup on any exit.
trap 'revoke_key' EXIT INT TERM

[[ -f "$HTML" ]] || warn "doc/TUTORIAL.html not present yet — the page will 503 until it's built; /api demos still work."

if (( LAUNCH_ENABLED )); then
  ok "launch buttons ENABLED (--launch-enabled): the page can idempotently start watchable web UIs."
  # 'start' refuses to run from a worktree; warn early if that's where we are.
  if [[ "$(git -C "$AI_STACK" rev-parse --git-dir 2>/dev/null)" != "$(git -C "$AI_STACK" rev-parse --git-common-dir 2>/dev/null)" ]]; then
    warn "  …but this looks like a git worktree — launch will fail. Run tutorial-serve from the MAIN checkout."
  fi
fi

# NOT exec — keep the bash EXIT/INT/TERM trap alive so the key auto-revokes when
# the server stops (exec would replace the shell and orphan the trap).
# Pass the key by FILE PATH (TUT_KEY_FILE -> the 0600 $STATE file), not as an env
# var, so the secret never shows up in `ps`/process environment to other local users.
# TUT_LAUNCH gates POST /api/launch server-side (the proxy 404s the route when != "1").
TUT_PORT="$PORT" TUT_LITELLM="$LITELLM" TUT_KEY_FILE="$STATE" TUT_HTML="$HTML" TUT_ROOT="$AI_STACK" TUT_MODELS="$DEMO_MODELS_DISPLAY" TUT_LAUNCH="$LAUNCH_ENABLED" TUT_EMBED="$EMBED_MODEL" TUT_HONCHO="$HONCHO_URL" TUT_QDRANT="$QDRANT_URL" TUT_PHOENIX="$PHOENIX_URL" \
  python3 "$AI_STACK/installer/lib/tutorial_proxy.py"
