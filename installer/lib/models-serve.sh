#!/usr/bin/env bash
# models-serve.sh — `vz-ai-stack.sh models-serve [--port N] [--ttl 30m] [--read-only] [--revoke]`
#
# Serves doc/MODELS.html — the Model & Agent Console — plus a loopback proxy
# (installer/lib/models_proxy.py) that WRAPS the `model` CLI to view/stage/apply
# changes to models.yml + litellm/config.yaml from a browser instead of hand-editing.
#
# Unlike tutorial-serve (which proxies inference and therefore HARD-fails if LiteLLM
# is down), this console's primary job is CONFIG management, which works fully offline.
# So the ephemeral LiteLLM key is BEST-EFFORT: it is minted only to back ONE optional
# route — POST /api/test, a single smoke call that catches the classic "model reports
# added but 404s at first real call" failure — and the console still runs without it.
#
# Security mirrors tutorial-serve exactly: loopback bind, Host-pin, narrow static
# allowlist (no .js/.json/.env/.sh/.yml), the key lives only in a 0600 file injected
# server-side (never in the browser, never in `ps`), and it auto-revokes on exit.
#
# OPERATE THIS FROM THE MAIN CHECKOUT — `apply` may restart/recreate the live LiteLLM
# container, which bind-mounts the workspace path; running it from a git worktree can
# break the live stack (see feedback_worktree_breaks_live_stack).
set -Eeuo pipefail
shopt -s inherit_errexit
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"

PORT=8898                          # one above tutorial-serve's 8899 default
TTL="30m"
REVOKE_ONLY=0
FORCE=0                            # --force: free the port even from a FOREIGN holder (kill + rebind)
READ_ONLY=0                        # --read-only: view + stage (sandbox) only; POST /api/apply 403s
HTML="$AI_STACK/doc/MODELS.html"
STATE="$AI_STACK/installer/state/models-console-token"   # holds the live ephemeral key (0600)
LITELLM="$(get_env LITELLM_BASE_URL 'http://litellm:4000')"
CONFIG="$AI_STACK/litellm/config.yaml"

# Test-route allowlist = EVERY chat model wired into LiteLLM (minus embeddings), so a
# freshly-added model can be smoke-tested. Mirrors tutorial-serve's derivation. The
# $0.50 budget cap + short TTL bound any cloud/subscription spend from the test button.
TEST_MODELS='["local","local-heavy"]'
if command -v yq >/dev/null 2>&1 && [[ -f "$CONFIG" ]]; then
  _chat_csv="$(yq -r '.model_list[].model_name' "$CONFIG" 2>/dev/null \
    | grep -vE '^embed-' | awk 'NF' | sort -u | paste -sd, -)"
  if [[ -n "$_chat_csv" ]]; then
    TEST_MODELS="$(printf '%s' "$_chat_csv" | python3 -c 'import sys,json; print(json.dumps([m for m in sys.stdin.read().strip().split(",") if m]))')"
  fi
fi

while (( $# )); do
  case "$1" in
    --port=*) PORT="${1#*=}" ;;
    --port)   shift; PORT="${1:-8898}" ;;
    --ttl=*)  TTL="${1#*=}" ;;
    --ttl)    shift; TTL="${1:-30m}" ;;
    --read-only) READ_ONLY=1 ;;
    --revoke) REVOKE_ONLY=1 ;;
    --force)  FORCE=1 ;;
    -h|--help)
      cat <<EOF
vz-ai-stack.sh models-serve [--port N] [--ttl 30m] [--read-only] [--force] [--revoke]
  Serve doc/MODELS.html (the Model & Agent Console) + a loopback proxy that wraps
  the \`model\` CLI to view / stage / apply model + agent-binding changes via UI.
  --port N      loopback port (default 8898)
  --ttl 30m     ephemeral test-key time-to-live (LiteLLM duration; default 30m)
  --read-only   view + stage (diff) only; POST /api/apply is refused (no writes)
  --force       if the port is held, kill WHATEVER holds it (even a non-models-serve
                process) and rebind. Without --force a stale models-serve is auto-reaped
                but a FOREIGN holder is reported and left alone. (Manual: lsof -ti tcp:8898 | xargs kill)
  --revoke      revoke a lingering console key and exit
  Run from the MAIN checkout — apply may restart/recreate the live LiteLLM container.
EOF
      exit 0 ;;
    *) err "unknown argument: $1 (try --help)"; exit 2 ;;
  esac
  shift
done

[[ "$PORT" =~ ^[0-9]{2,5}$ ]] || { err "invalid --port '$PORT' (expected a number)"; exit 2; }
[[ "$TTL"  =~ ^[0-9]+[smhd]$ ]] || { err "invalid --ttl '$TTL' (expected e.g. 30m, 2h, 1d)"; exit 2; }
# Refuse --force on a privileged port (<1024) — a loopback dev serve never belongs there,
# and --force would SIGKILL whatever holds it (sshd/nginx/...). 10# forces base-10 so a
# zero-padded port can't be misread as octal. (A non-root bind to <1024 fails anyway.)
if (( FORCE )) && (( 10#$PORT < 1024 )); then
  err "--force on a privileged port ($PORT, <1024) is refused — pick --port <N> ≥ 1024"; exit 2
fi

MASTER="$(get_env LITELLM_MASTER_KEY '')"
CONSOLE_ALIAS="models-console"   # fixed key_alias minted below; LiteLLM enforces it unique

revoke_key() {
  rm -f "$STATE"
  [[ -n "$MASTER" ]] || return 0
  # Self-heal by ALIAS, not by a stored token: a crashed/SIGKILLed run skips the
  # EXIT trap (or loses $STATE) and orphans the key, and LiteLLM's unique-alias
  # rule then makes the next mint fail hard ("Key with alias 'models-console'
  # already exists"). Deleting every key carrying our alias clears that orphan
  # regardless of whether we still hold its token.
  litellm_master_curl -s --max-time 10 -H 'Content-Type: application/json' \
    -X POST "$LITELLM/key/delete" -d "{\"key_aliases\":[\"$CONSOLE_ALIAS\"]}" >/dev/null 2>&1 || true
  ok "revoked models-console test key"
}

if (( REVOKE_ONLY )); then
  revoke_key; exit 0
fi

# Pre-flight the port BEFORE minting (a previous run whose terminal was closed orphans
# its proxy, which keeps LISTENing). Reuse our own stale port; fail clearly on a foreign one.
ensure_port_free() {
  local port="$1" holders pid cmd killed=0 i
  command -v lsof >/dev/null 2>&1 || return 0
  holders="$(lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null || true)"
  [[ -z "$holders" ]] && return 0
  for pid in $holders; do
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    if [[ "$cmd" == *models_proxy.py* || "$cmd" == *models-serve.sh* ]]; then
      warn "Port $port held by a stale models-serve (PID $pid) — stopping it."
      kill "$pid" 2>/dev/null || true
      killed=1
    elif (( FORCE )); then
      warn "Port $port held by a FOREIGN process (PID $pid) — --force: killing it."
      warn "  $cmd"
      kill "$pid" 2>/dev/null || true
      killed=1
    else
      err "Port $port is already in use by PID $pid — not a models-serve process:"
      err "  $cmd"
      err "Re-run with --force to kill it and rebind, or pick another: vz-ai-stack.sh models-serve --port <N>"
      exit 1
    fi
  done
  (( killed )) || return 0
  for i in $(seq 1 12); do
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

ensure_port_free "$PORT"

# If we're in a git worktree, FORCE read-only. Apply restarts/recreates the live LiteLLM
# container, which bind-mounts the workspace path — doing that from a worktree breaks the
# live stack (feedback_worktree_breaks_live_stack). Read + stage (sandbox diff) are safe
# from anywhere, so we keep those working and only disable writes. A warn alone is too
# easy to miss once the server starts and all reads succeed.
if [[ "$(git -C "$AI_STACK" rev-parse --git-dir 2>/dev/null)" != "$(git -C "$AI_STACK" rev-parse --git-common-dir 2>/dev/null)" ]]; then
  if (( ! READ_ONLY )); then
    warn "git worktree detected — FORCING --read-only (apply would restart the live LiteLLM and can break the stack)."
    warn "  to apply changes, run models-serve from the MAIN checkout."
    READ_ONLY=1
  else
    note "git worktree detected — already --read-only; read + stage are safe here."
  fi
fi

# BEST-EFFORT mint: the console runs fine without a key (config editing is offline).
# A key only enables the optional POST /api/test smoke route.
KEY=""
if [[ -n "$MASTER" ]] && { curl -sf --max-time 5 "$LITELLM/health/readiness" >/dev/null 2>&1 || litellm_master_curl -sf --max-time 5 "$LITELLM/v1/models" >/dev/null 2>&1; }; then
  revoke_key   # clear any stale key from a prior run
  log "Minting an ephemeral, budget-capped test key (ttl=$TTL) for the optional smoke-test button..."
  RESP="$(litellm_master_curl -s --max-time 15 -H 'Content-Type: application/json' \
    -X POST "$LITELLM/key/generate" \
    -d "{\"models\":${TEST_MODELS},\"duration\":\"${TTL}\",\"max_budget\":0.5,\"budget_duration\":\"1d\",\"key_alias\":\"${CONSOLE_ALIAS}\",\"metadata\":{\"owner\":\"models-serve\"}}")"
  KEY="$(printf '%s' "$RESP" | python3 -c 'import sys,json
try: print(json.load(sys.stdin).get("key",""))
except Exception: print("")')"
  if [[ -n "$KEY" ]]; then
    umask 077; printf '%s' "$KEY" > "$STATE"
    ok "minted models-console test key (\$0.50 cap, ttl=$TTL) — never exposed to the browser"
    trap 'revoke_key' EXIT INT TERM
  else
    warn "could not mint a test key (POST /api/test will be unavailable) — config management still works."
    warn "LiteLLM response:"; printf '%s\n' "$RESP" | head -3
  fi
else
  warn "LiteLLM not reachable (or no master key) — running WITHOUT a test key; config management still works."
fi

[[ -f "$HTML" ]] || warn "doc/MODELS.html not present yet — the page will 503 until it's built; /api routes still work."
(( READ_ONLY )) && ok "read-only mode: stage/diff allowed, POST /api/apply refused (no writes)."

# NOT exec — keep the bash EXIT/INT/TERM trap alive so the key auto-revokes when the
# server stops. Pass the key by FILE PATH (MC_KEY_FILE), never inline, so it never
# shows up in `ps`. The proxy reads vendor key_env values from .env SERVER-SIDE and
# only ever sends key VAR NAMES (+ presence booleans) to the browser.
MC_PORT="$PORT" MC_LITELLM="$LITELLM" MC_KEY_FILE="$STATE" MC_HTML="$HTML" MC_ROOT="$AI_STACK" \
  MC_MODELS_SH="$AI_STACK/installer/lib/models.sh" MC_EMBED_SH="$AI_STACK/installer/lib/embeddings.sh" \
  MC_START_LITELLM="$AI_STACK/bin/start-litellm.sh" \
  MC_MODELS_YML="$AI_STACK/installer/models.yml" MC_CONFIG="$CONFIG" MC_ENV_FILE="${ENV_FILE:-$AI_STACK/.env}" \
  MC_READONLY="$READ_ONLY" \
  python3 "$AI_STACK/installer/lib/models_proxy.py"
