# common.sh — log, color, lock, paths, per-run id, CHANGELOG entry helper.
# Sourced by vz-ai-stack.sh. Do not run directly.
#
# Assumes AI_STACK and bash 5+ are already established by the caller.

[[ -z "${AI_STACK:-}" ]] && { echo "common.sh: AI_STACK unset" >&2; exit 2; }

# --- color & log -------------------------------------------------------------
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_DIM=$'\033[2m'
else
  C_RESET="" C_BOLD="" C_RED="" C_GREEN="" C_YELLOW="" C_BLUE="" C_DIM=""
fi

ts() { date "+%Y-%m-%d %H:%M:%S"; }

log()  { printf '%s %s\n'   "${C_DIM}[$(ts)]${C_RESET}" "$*"; }
ok()   { printf '%s %s\n'   "${C_GREEN}✓${C_RESET}"     "$*"; }
warn() { printf '%s %s\n'   "${C_YELLOW}⚠${C_RESET}"    "$*" >&2; }
err()  { printf '%s %s\n'   "${C_RED}✗${C_RESET}"       "$*" >&2; }
note() { printf '%s %s\n'   "${C_BLUE}·${C_RESET}"      "$*"; }

# Header for a phase or subcommand boundary.
hdr() {
  printf '\n%s%s%s\n' "${C_BOLD}" "$*" "${C_RESET}"
  printf '%s\n' "${C_DIM}$(printf '%.0s─' $(seq 1 ${#1}))${C_RESET}"
}

# --- per-run id + CHANGELOG.d ------------------------------------------------
# Avoid CHANGELOG.md race conditions by writing per-run files.
# vz-ai-stack.sh history compiles them.
RUN_ID="${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
export RUN_ID
RUN_LOG="$AI_STACK/CHANGELOG.d/${RUN_ID}.md"
mkdir -p "$(dirname "$RUN_LOG")"

# Append a one-line entry to the per-run log (and stderr so the user sees it).
record() {
  printf '%s — %s\n' "$(ts)" "$*" >> "$RUN_LOG"
}

# Append a multi-line section.
record_block() {
  local title="$1"; shift
  {
    printf '\n### %s — %s\n\n' "$(ts)" "$title"
    printf '%s\n' "$@"
  } >> "$RUN_LOG"
}

# --- paths -------------------------------------------------------------------
ENV_FILE="${ENV_FILE:-$AI_STACK/.env}"
SERVICES_YML="$AI_STACK/services.yml"
BIN_DIR="$AI_STACK/bin"
STATE_DIR="$AI_STACK/installer/state"
DOCTOR_DIR="$AI_STACK/installer/doctor"
PHASES_DIR="$AI_STACK/installer/phases"
SMOKE_DIR="$AI_STACK/installer/smoke"
RESTARTS_FILE="$STATE_DIR/restarts-needed.txt"

mkdir -p "$STATE_DIR"

# --- lock (mkdir-as-atomic; macOS-portable; Reviewer B #5, Adversarial #8) ---
LOCKDIR="$STATE_DIR/.lock"

lock_acquire() {
  local force="${LOCK_FORCE:-0}"
  local tries=0
  while ! mkdir "$LOCKDIR" 2>/dev/null; do
    if [[ -f "$LOCKDIR/pid" ]]; then
      local held; held="$(cat "$LOCKDIR/pid" 2>/dev/null || echo "?")"
      # Stale-lock recovery: PID not alive → break.
      if [[ "$held" =~ ^[0-9]+$ ]] && ! kill -0 "$held" 2>/dev/null; then
        warn "Removing stale lock (pid $held is not alive)."
        rm -rf "$LOCKDIR"
        continue
      fi
      if (( force == 1 )); then
        warn "Force-breaking lock held by pid $held."
        rm -rf "$LOCKDIR"
        continue
      fi
      err "Another vz-ai-stack.sh/doctor is running (pid $held). Re-run with LOCK_FORCE=1 to break."
      exit 3
    fi
    (( ++tries > 30 )) && {
      err "Lock acquisition timed out at $LOCKDIR"
      exit 3
    }
    sleep 1
  done
  echo "$$" > "$LOCKDIR/pid"
  echo "$RUN_ID" > "$LOCKDIR/run-id"
  # shellcheck disable=SC2064
  trap "rm -rf '$LOCKDIR'" EXIT INT TERM
}

# --- phase stamp files (Reviewer B #3, Adversarial #5) ----------------------
# Stamps are an ADVISORY cache. Every phase has its own precheck() that
# re-verifies actual state. Stamp + failing precheck = re-enter phase.

stamp_mark()  { touch "$STATE_DIR/phase_${1}.done"; }
stamp_clear() { rm -f "$STATE_DIR/phase_${1}.done"; }
stamp_check() { [[ -f "$STATE_DIR/phase_${1}.done" ]]; }

# --- restart queue (Reviewer Adversarial #12) -------------------------------
queue_restart() {
  local svc="$1"
  touch "$RESTARTS_FILE"
  if ! grep -qxF "$svc" "$RESTARTS_FILE"; then
    echo "$svc" >> "$RESTARTS_FILE"
    record "queued restart: $svc (downstream config change)"
  fi
}

# --- atomic-write helper (preserves 0600) -----------------------------------
atomic_write() {
  local dest="$1"
  local tmp
  tmp="$(mktemp "${dest}.XXXXXX")" || return 1
  chmod 600 "$tmp"
  cat > "$tmp"
  mv -f "$tmp" "$dest"
}

# --- litellm_master_curl: run curl authenticated with the LiteLLM MASTER key ----
# Usage: litellm_master_curl <curl-args...>   (DROP the -H "Authorization: Bearer ..."
# at the call site; pass everything else — -s, -X, -d, the URL — through unchanged).
# The master key is the highest-privilege credential in the stack; passing it via
# `-H` puts it in the process arg list (visible in `ps`/—/proc/PID/cmdline to any
# local process). This injects the Authorization header via curl `--config` on STDIN
# so the secret never appears in argv. NOTE: the call site must NOT also feed curl
# data on stdin (e.g. `-d @-`) — stdin is consumed by the config; all current callers
# use inline `-d '...'`.
litellm_master_curl() {
  local _m; _m="$(get_env LITELLM_MASTER_KEY '')"
  printf 'header = "Authorization: Bearer %s"\n' "$_m" | curl --config - "$@"
}

# --- litellm_reconcile_key: self-heal a scoped key's model allow-list --------
# Usage: litellm_reconcile_key <KEY_ENV> <model...>           (positional names)
#        litellm_reconcile_key <KEY_ENV> '["m1","m2",...]'    (one JSON array)
#
# Per-phase consumer keys (mempalace/metagpt/agentscope/oasis/chatdev/aitown/
# aionui/openwork) are minted with a HARDCODED model allow-list and only re-mint
# when the key is fully dead (can't list ANY model). So a model RENAME leaves the
# key allowing only the OLD alias while the app calls the NEW one — a SILENT 403
# the liveness guard misses (`model sync` only widens the fleet `kinds:` keys,
# never these). This idempotently ensures the key allows every requested model by
# widening it IN PLACE via /key/update — same key string (no .env churn, no app
# restart), to the UNION of its current list and the requested models (NEVER
# narrows). No-op when already covered. WARN-non-fatal. Safe under `set -Eeuo
# pipefail`: every curl/parse is guarded so a transient LiteLLM outage degrades to
# warn, never aborts the phase.
#   - SELF-LOOKUP read (Authorization: Bearer <the key>, no ?key= in the URL) so
#     the scoped secret never lands in an access log.
#   - WILDCARD-safe: a key scoped to LiteLLM's all-proxy-models/all-team-models
#     sentinel already covers everything and is left untouched (never narrowed).
litellm_reconcile_key() {
  local key_env="$1"; shift
  local desired=()
  if [[ $# -eq 1 && "$1" == \[* ]]; then
    local _mj _l
    _mj="$(printf '%s' "$1" | python3 -c 'import sys,json
try: print("\n".join(json.load(sys.stdin)))
except Exception: pass' 2>/dev/null || true)"
    while IFS= read -r _l; do [[ -n "$_l" ]] && desired+=("$_l"); done <<< "$_mj"
  else
    desired=("$@")
  fi
  # Drop empty model args (e.g. an unset $X_MODEL) — never widen a key to allow "".
  local _kept=() _x
  for _x in "${desired[@]}"; do [[ -n "$_x" ]] && _kept+=("$_x"); done
  desired=("${_kept[@]}")
  [[ ${#desired[@]} -gt 0 ]] || return 0
  local master key base cur
  master="$(get_env LITELLM_MASTER_KEY '')"
  key="$(get_env "$key_env" '')"
  [[ -n "$key" && -n "$master" ]] || return 0
  # Resolve a reachable base: prefer LITELLM_BASE_URL / the litellm:4000 ingress alias,
  # then the always-published loopback — mirrors the phases' own probe-and-fallback so a
  # box without the bare-hostname ingress still self-heals. Live allow-list via self-
  # lookup. "__wildcard__" => UNRESTRICTED key — an empty models list ([]/null) means
  # unrestricted in LiteLLM (verified), so treat it like the all-proxy/all-team sentinels
  # and NEVER narrow it. Empty OUTPUT (not "__wildcard__") => LiteLLM unreachable on both
  # bases -> skip (can't heal a down gateway; next install/doctor retries) and, crucially,
  # never POST a narrowing update built from a falsely-empty current list.
  cur=""
  for base in "${LITELLM_BASE_URL:-http://litellm:4000}" "http://127.0.0.1:4000"; do
    cur="$(curl -s --max-time 5 -H "Authorization: Bearer $key" "$base/key/info" 2>/dev/null \
      | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)            # no/invalid response -> print NOTHING (unreachable, not "[]")
info=d.get("info")
if not isinstance(info,dict): sys.exit(0)  # error payload / no info -> not a real allow-list
m=info.get("models") or []
print("__wildcard__" if (not m or any(x in ("all-proxy-models","all-team-models") for x in m)) else "\n".join(m))' 2>/dev/null || true)"
    [[ -n "$cur" ]] && break
  done
  if [[ -z "$cur" ]] || printf '%s\n' "$cur" | grep -qxF '__wildcard__'; then return 0; fi
  local missing=0 m
  for m in "${desired[@]}"; do
    printf '%s\n' "$cur" | grep -qxF "$m" || { missing=1; break; }
  done
  [[ $missing -eq 0 ]] && return 0    # already covers every requested model
  log "Reconciling $key_env allow-list -> +{${desired[*]}} (model-rename drift)…"
  # New list = union(current, requested), built with json.dumps (no shell-injection
  # of model names / the key into the JSON body); deduped, order-stable.
  local body resp
  body="$(_RK_KEY="$key" _RK_CUR="$cur" _RK_DES="$(printf '%s\n' "${desired[@]}")" python3 -c '
import json,os
out=[]
for x in (os.environ["_RK_CUR"].splitlines() + os.environ["_RK_DES"].splitlines()):
    if x and x != "__wildcard__" and x not in out: out.append(x)
print(json.dumps({"key":os.environ["_RK_KEY"],"models":out}))' 2>/dev/null || true)"
  [[ -n "$body" ]] || { warn "reconcile $key_env: could not build request body"; return 0; }
  resp="$(litellm_master_curl -s --max-time 15 -H 'Content-Type: application/json' \
    -X POST "$base/key/update" -d "$body" 2>/dev/null || true)"
  if printf '%s' "$resp" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(1 if "error" in d else 0)' 2>/dev/null; then
    ok "$key_env allow-list now covers {${desired[*]}}"
  else
    warn "Could not reconcile $key_env allow-list (LiteLLM /key/update failed) — renamed-model calls may 403"
  fi
}
