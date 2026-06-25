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
  # Fail fast on an unset key rather than sending a bare `Authorization: Bearer `
  # (which LiteLLM answers with an opaque 401). Callers see a clear cause + non-zero.
  [[ -n "$_m" ]] || { warn 'litellm_master_curl: LITELLM_MASTER_KEY is unset/empty — skipping authenticated call'; return 1; }
  # Suppress xtrace while the secret is live: if any caller runs under `set -x`, the
  # printf below would otherwise trace the fully-expanded key to stderr/any debug log.
  local _x=''; case $- in *x*) _x=1; set +x;; esac
  printf 'header = "Authorization: Bearer %s"\n' "$_m" | curl --config - "$@"
  local _rc=$?
  [[ -n "$_x" ]] && set -x
  return $_rc
}

# --- litellm_scoped_curl: run curl authenticated with a SCOPED LiteLLM key ------
# Usage: litellm_scoped_curl <key> <curl-args...>   (pass the scoped key as $1, then
# DROP the -H "Authorization: Bearer ..." at the call site and pass everything else
# — -s, --max-time, -X, -d, the URL — through unchanged).
# Companion to litellm_master_curl: a per-phase/fleet scoped key is still an sk-...
# secret, and -H "Authorization: Bearer $key" puts it in the process arg list (visible
# in `ps`/—/proc/PID/cmdline to any local process). This injects the Authorization
# header via curl `--config` on STDIN so the secret never appears in argv. The call
# site must NOT also feed curl data on stdin (e.g. `-d @-`) — stdin is consumed by the
# config; all current callers use inline `-d '...'` or send no body.
# SCOPE: generic — injects ANY bearer token passed as $1 via curl --config STDIN, for any
# bearer-authenticated endpoint. Written for LiteLLM scoped keys; also used for PHOENIX_API_KEY
# (09_phoenix check + smoke/01h -> phoenix:6006) as of worktree-cred-argv-finish. (Renaming to a
# neutral `bearer_curl` is a deferred follow-up — it would touch ~50 call sites.)
litellm_scoped_curl() {
  local _k="$1"; shift
  # Fail fast on an empty key (clear cause + non-zero), mirroring litellm_master_curl;
  # callers already guard on a non-empty key, so this only catches a programming slip.
  [[ -n "$_k" ]] || { warn 'litellm_scoped_curl: scoped key is empty — skipping authenticated call'; return 1; }
  # Suppress xtrace while the secret is live: a caller under `set -x` would otherwise
  # trace the fully-expanded key to stderr/any debug log. Mirrors litellm_master_curl.
  local _x=''; case $- in *x*) _x=1; set +x;; esac
  printf 'header = "Authorization: Bearer %s"\n' "$_k" | curl --config - "$@"
  local _rc=$?
  [[ -n "$_x" ]] && set -x
  return $_rc
}

# --- _doctor_assert_key_allowlist: shared agent-sim allow-list drift check ----
# Usage: _doctor_assert_key_allowlist <scoped_key> <KEY_ENV_NAME> <yq_assignment_key> \
#                                     <model_descr> <phase_num>
#
# DRY extraction of the allow-list assertion duplicated across doctor checks 57-61
# (MetaGPT/AgentScope/OASIS/ChatDev/AI Town). After the per-check /v1/models probe has
# already proved the scoped key lists SOME model, this verifies the key actually ALLOWS
# the specific model the sim is bound to: a key still scoped to an OLD alias after a model
# rename/re-assign passes /v1/models yet SILENT-403s the model the sim calls. Resolves the
# bound model the way the phase does (models.yml `.assignments.<key>`, else local-gemma4)
# and self-looks-up the scoped key's allow-list via /key/info (Bearer = the scoped key via
# litellm_scoped_curl, no ?key= in the URL; metadata read only — never cold-starts).
#
# Probe order is LOOPBACK-FIRST (127.0.0.1:4000 then litellm:4000), standardized from the
# old per-check split (61 was already loopback-first; 57-60 were litellm-first): doctor runs
# in the host shell, where the litellm:4000 alias only resolves if Phase 00n wrote /etc/hosts
# — trying it first burns a guaranteed ~5s timeout on boxes without that entry. Loopback is
# always reachable from the host, so it is strictly >= the old order (no regression). The
# SIBLING /v1/models probe in checks 57-60 is still litellm-first (out of this E+F refactor's
# scope — it is not the duplicated block; 61's /v1/models is already loopback-first); aligning
# it loopback-first is a tracked follow-up.
#
# Returns 1 + an echoed diagnostic ONLY when the allow-list is parseable, non-wildcard, and
# genuinely MISSING the bound model (the real drift) — the caller propagates with `|| return
# 1`, and doctor re-runs the diagnose to surface the message. Returns 0 (non-fatal) on every
# soft case so a transient blip never red-bars a working stack: wildcard/unrestricted key,
# empty/unparseable /key/info, or LiteLLM unreachable. When yq is ABSENT it cannot resolve
# the bound model, so it WARNs (no longer a fully-silent skip — visible in any FAIL detail /
# direct diagnose run; on a clean PASS doctor shows nothing by design) and returns 0.
_doctor_assert_key_allowlist() {
  # Suppress xtrace for the in-function key-handling: under `set -x` the `local key=$1`
  # assignment below would otherwise trace `+ local key=sk-...` to stderr. Mirrors the
  # xtrace discipline of litellm_master_curl / litellm_scoped_curl (which this calls — it
  # self-suppresses its own internals too). NOTE: this does NOT close the caller-side trace
  # of the invocation line itself (`+ _doctor_assert_key_allowlist sk-...`), which bash emits
  # with args expanded BEFORE the body runs — a pre-existing whole-codebase property of
  # passing "$key" to ANY function under set -x (the old inline `litellm_scoped_curl "$key"`
  # leaked identically), and no installer code runs under `set -x`. Restored before the
  # parse/echo (which never reference the key) and in the yq-absent early return.
  local _xt=''; case $- in *x*) _xt=1; set +x;; esac
  local key="$1" key_env="$2" yq_key="$3" model_descr="$4" phase="$5"
  if ! command -v yq >/dev/null 2>&1; then
    [[ -n "$_xt" ]] && set -x
    warn "$key_env allow-list assertion skipped (yq not installed) — cannot resolve the bound model to verify the scoped key allows it; install yq to enable this drift check"
    return 0
  fi
  local want
  want="$(yq -r ".assignments.${yq_key} // \"\"" "$AI_STACK/installer/models.yml" 2>/dev/null || true)"
  [[ -n "$want" && "$want" != "null" ]] || want="local-gemma4"
  local allow
  allow="$(litellm_scoped_curl "$key" -s --max-time 5 http://127.0.0.1:4000/key/info 2>/dev/null || litellm_scoped_curl "$key" -s --max-time 5 http://litellm:4000/key/info 2>/dev/null || true)"
  [[ -n "$_xt" ]] && set -x
  allow="$(printf '%s' "$allow" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
info=d.get("info")
if not isinstance(info,dict): sys.exit(0)
m=info.get("models") or []
print("__wildcard__" if (not m or any(x in ("all-proxy-models","all-team-models") for x in m)) else "\n".join(m))' 2>/dev/null || true)"
  if [[ -n "$allow" ]] && ! printf '%s\n' "$allow" | grep -qxF '__wildcard__' \
     && ! printf '%s\n' "$allow" | grep -qxF "$want"; then
    echo "$key_env allow-list missing '$want' ($model_descr) — stale key after a model rename/re-assign; re-run 'vz-ai-stack.sh install $phase' to self-heal"
    return 1
  fi
  return 0
}

# --- _probe_meridian_up / _probe_codex_bridge_up: shared, memoized, retried ---
#
# PROCESS-SCOPED memoization: the result is cached in a bash variable for the
# lifetime of the current process ONLY. It does NOT persist to any file under
# installer/state and is NOT shared across separate `model sync` invocations.
# This eliminates the cold-start race where the first agent's probe times out
# (daemon just starting) while all subsequent agents see a warm, cached result.
#
# Retry policy: first attempt uses a 5-second timeout; on failure two more
# retries at 3 seconds each. Total max budget: ~11 seconds per process, once.
#
# Callers (models.sh meridian_up / codex_bridge_up, check40 _mb_meridian_up)
# MUST call the shared helpers rather than raw curl so all surfaces are
# consistent and the memoization cache is shared within each invocation.
_PROBE_MERIDIAN_CACHE=""      # "up" | "down" | "" (uncached)
_PROBE_CODEX_BRIDGE_CACHE=""  # "up" | "down" | "" (uncached)

_probe_meridian_up() {
  # Return cached result if already probed this process.
  if [[ "$_PROBE_MERIDIAN_CACHE" == "up" ]]; then return 0; fi
  if [[ "$_PROBE_MERIDIAN_CACHE" == "down" ]]; then return 1; fi
  # First attempt: 5-second budget (cold daemon may need a moment).
  if curl -sf --max-time 5 "http://127.0.0.1:${MERIDIAN_PORT:-3456}/v1/models" \
       -H "Authorization: Bearer x" >/dev/null 2>&1; then
    _PROBE_MERIDIAN_CACHE="up"; return 0
  fi
  # Retry 1 and 2 at 3 seconds each.
  local i
  for i in 1 2; do
    if curl -sf --max-time 3 "http://127.0.0.1:${MERIDIAN_PORT:-3456}/v1/models" \
         -H "Authorization: Bearer x" >/dev/null 2>&1; then
      _PROBE_MERIDIAN_CACHE="up"; return 0
    fi
  done
  _PROBE_MERIDIAN_CACHE="down"; return 1
}

_probe_codex_bridge_up() {
  # Return cached result if already probed this process.
  if [[ "$_PROBE_CODEX_BRIDGE_CACHE" == "up" ]]; then return 0; fi
  if [[ "$_PROBE_CODEX_BRIDGE_CACHE" == "down" ]]; then return 1; fi
  # First attempt: 5-second budget (cold daemon may need a moment).
  if curl -sf --max-time 5 "http://127.0.0.1:${CODEX_BRIDGE_PORT:-3457}/v1/models" \
       -H "Authorization: Bearer x" >/dev/null 2>&1; then
    _PROBE_CODEX_BRIDGE_CACHE="up"; return 0
  fi
  # Retry 1 and 2 at 3 seconds each.
  local i
  for i in 1 2; do
    if curl -sf --max-time 3 "http://127.0.0.1:${CODEX_BRIDGE_PORT:-3457}/v1/models" \
         -H "Authorization: Bearer x" >/dev/null 2>&1; then
      _PROBE_CODEX_BRIDGE_CACHE="up"; return 0
    fi
  done
  _PROBE_CODEX_BRIDGE_CACHE="down"; return 1
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
    cur="$(litellm_scoped_curl "$key" -s --max-time 5 "$base/key/info" 2>/dev/null \
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
  # xtrace-suppress the key-live window (body holds the scoped key) — mirrors the helpers'
  # own set+x discipline so a `set -x` caller can't trace the key to stderr/any debug log.
  local _rx=''; case $- in *x*) _rx=1; set +x;; esac
  body="$(_RK_KEY="$key" _RK_CUR="$cur" _RK_DES="$(printf '%s\n' "${desired[@]}")" python3 -c '
import json,os
out=[]
for x in (os.environ["_RK_CUR"].splitlines() + os.environ["_RK_DES"].splitlines()):
    if x and x != "__wildcard__" and x not in out: out.append(x)
print(json.dumps({"key":os.environ["_RK_KEY"],"models":out}))' 2>/dev/null || true)"
  [[ -n "$_rx" ]] && set -x
  [[ -n "$body" ]] || { warn "reconcile $key_env: could not build request body"; return 0; }
  # POST the SCOPED-key-bearing body from a 0600 temp file (mktemp defaults to 0600) via
  # --data @file so the scoped key never lands in argv (the master-key auth is already off-argv
  # via litellm_master_curl's --config STDIN; --data @file reads the file, not STDIN, so there
  # is no collision). Done inside a SUBSHELL whose OWN EXIT trap removes the file on EVERY exit
  # path (normal / errexit / SIGINT / SIGTERM) — isolated, so it never clobbers the outer lock
  # trap. xtrace stays off inside while the key is written.
  resp="$(
    case $- in *x*) set +x;; esac
    _bf="$(mktemp 2>/dev/null)" || exit 0
    trap 'rm -f "$_bf"' EXIT
    printf '%s' "$body" > "$_bf" || exit 0
    litellm_master_curl -s --max-time 15 -H 'Content-Type: application/json' \
      -X POST "$base/key/update" --data @"$_bf" 2>/dev/null || true
  )"
  if printf '%s' "$resp" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(1 if "error" in d else 0)' 2>/dev/null; then
    ok "$key_env allow-list now covers {${desired[*]}}"
  else
    warn "Could not reconcile $key_env allow-list (LiteLLM /key/update failed) — renamed-model calls may 403"
  fi
}
