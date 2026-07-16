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
  trap 'lock_release' EXIT INT TERM
}

# lock_release — remove the lock dir. SINGLE source of truth for lock cleanup, so a
# caller that supersedes the EXIT trap (e.g. upgrade.sh's upgrade_on_exit) redoes the
# cleanup by CALLING this, not by duplicating the rm — if lock cleanup ever grows beyond
# the dir, both the lock trap and the superseding caller track it for free.
lock_release() { rm -rf "$LOCKDIR" 2>/dev/null || true; }   # never let cleanup abort an EXIT trap

# --- phase stamp files (Reviewer B #3, Adversarial #5) ----------------------
# Stamps are an ADVISORY cache. Every phase has its own precheck() that
# re-verifies actual state. Stamp + failing precheck = re-enter phase.

stamp_mark()  { touch "$STATE_DIR/phase_${1}.done"; }
stamp_clear() { rm -f "$STATE_DIR/phase_${1}.done"; }
stamp_check() { [[ -f "$STATE_DIR/phase_${1}.done" ]]; }

# --- openshell sandbox presence (EPIPE-safe) --------------------------------
# sandbox_present <osh> <name> — true when `openshell sandbox list` reports a sandbox
# whose NAME column (column 1) equals <name>, in any Phase. False when <osh> is empty,
# when the gateway/CLI errors, or when the name is absent. Lives in common.sh because
# it is the only lib every sandbox-touching phase already sources (04, 30, 39, 40, 41).
#
# WHY awk, AND NOT `"$osh" sandbox list | grep -q "$name"` — DO NOT "simplify" it back:
#   `grep -q` exits the instant it matches. On a MIDDLE row that closes the pipe while
#   the Rust `openshell` binary still has rows to print. Rust sets SIGPIPE to SIG_IGN, so
#   instead of dying quietly it PANICS ("failed printing to stdout: Broken pipe (os error
#   32)") and exits 101. Under `set -o pipefail` that 101 becomes the PIPELINE's status,
#   so `if ... | grep -q "$name"; then` evaluates FALSE even though grep MATCHED — and the
#   `2>/dev/null` hides the panic. Observed PIPESTATUS=[101 0] (openshell=101, grep=0).
#   Reproduced 8/10 under /bin/bash on 2026-07-16: a clean-slate `install all
#   --include-optionals` silently skipped the hermes-fleet docs (:8765) + falkordb (:7083)
#   MCP wiring, stamped both phases .done, and left doctor checks 74/76 red-barred.
#   NB: it does NOT reproduce under zsh — verify any change to this helper with /bin/bash.
#
#   awk is immune because it DRAINS stdin to EOF before deciding, so the writer never sees
#   EPIPE. Corollary: never add `exit` to this awk program (nor pipe this into `head`,
#   `grep -q`, or `awk ... {exit}`) — any early reader exit reintroduces the exact race.
#
# Regression test: installer/smoke/sandbox-present.sh
sandbox_present() {
  local osh="$1" name="$2"
  [[ -n "$osh" && -n "$name" ]] || return 1   # empty name would match a trailing blank row ($1=="")
  # `openshell sandbox list` emits a header row + ANSI color codes; strip and skip them.
  "$osh" sandbox list 2>/dev/null </dev/null \
    | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk -v n="$name" 'NR>1 && $1==n {f=1} END{exit !f}'
}

# sandbox_ready <osh> <name> — stricter sibling of sandbox_present: true only when the
# sandbox is listed AND its Phase (last column) is exactly "Ready". Same awk form, same
# EPIPE-immunity rules — every caveat in sandbox_present's comment applies verbatim.
#
# WHY a separate helper, and why the WIRING branches gate on THIS one:
#   sandbox_present is a presence test, so it is TRUE for a fleet that is still Creating /
#   Terminating. In that window `sandbox exec` fails, which makes wiring impossible — but the
#   verify-then-stamp probes (_mem_hermes_*_wired) are deliberately LENIENT about a non-Ready
#   fleet (they `return 0` = "nothing to assert"), so a phase that ENTERED its wiring branch
#   would see the wiring "verified" VACUOUSLY, print a FALSE ok, and stamp .done unwired.
#   Gating the wiring branch on Ready sends a non-Ready fleet down the GENUINE-SKIP branch
#   (stamp + exit 0), which is correct: nothing was attempted, and 04f re-wires later.
#   Mirrors doctor checks 74/75/76, which likewise only assert against a Ready fleet.
sandbox_ready() {
  local osh="$1" name="$2"
  [[ -n "$osh" && -n "$name" ]] || return 1
  "$osh" sandbox list 2>/dev/null </dev/null \
    | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk -v n="$name" 'NR>1 && $1==n && $NF=="Ready" {f=1} END{exit !f}'
}

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
# bound model the way the phase does (models.yml `.assignments.<key>`, else local)
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
  [[ -n "$want" && "$want" != "null" ]] || want="local"
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
    echo "$key_env allow-list missing '$want' ($model_descr) — stale key after a model rename/re-assign; self-heal: 'vz-ai-stack.sh install $phase' (its precheck now re-reconciles on allow-list drift), or reconcile every scoped key at once with 'vz-ai-stack.sh model sync'"
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

# ============================================================================
# Scoped-key CATALOG-DRIFT reconciliation (systemic fix for the ca08cc1 shrink).
# The block above (litellm_reconcile_key) only WIDENS (union). A catalog REMOVAL
# needs EXACT convergence (drop stale extras) + the 7 opt-in consumers brought
# under reconciliation. All control-plane only (/key/info + /key/update) — no
# model is ever loaded. See installer/tests/test_scoped_key_catalog_reconcile.sh.
# ============================================================================

# _sets_equal <listA> <listB> — true iff the two NEWLINE-delimited lists are equal
# as SETS (order- and dupe-insensitive; blank lines ignored).
_sets_equal() {
  local a b
  a="$(printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u)"
  b="$(printf '%s\n' "$2" | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u)"
  [[ "$a" == "$b" ]]
}

# _litellm_key_allowlist <key> — echo the scoped key's live model allow-list, one per
# line. Echoes the literal "__wildcard__" for an UNRESTRICTED key (empty models list,
# or the all-proxy-models/all-team-models sentinel — both mean "everything" in
# LiteLLM). Echoes NOTHING when LiteLLM is unreachable on every base, so callers can
# tell "unreachable" apart from "restricted to []" and never build a narrowing update
# from a falsely-empty list. SELF-LOOKUP read (Authorization: Bearer <key>, no ?key= in
# the URL) so the scoped secret never lands in an access log. (Callers that also need
# the base in-scope resolve it themselves — litellm_reconcile_key_exact re-inlines the
# read loop — because this returns only the list via a command-substitution subshell.)
_litellm_key_allowlist() {
  local key="$1" base cur=""
  [[ -n "$key" ]] || return 0
  for base in "${LITELLM_BASE_URL:-http://litellm:4000}" "http://127.0.0.1:4000"; do
    cur="$(litellm_scoped_curl "$key" -s --max-time 5 "$base/key/info" 2>/dev/null \
      | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
info=d.get("info")
if not isinstance(info,dict): sys.exit(0)
m=info.get("models") or []
print("__wildcard__" if (not m or any(x in ("all-proxy-models","all-team-models") for x in m)) else "\n".join(m))' 2>/dev/null || true)"
    [[ -n "$cur" ]] && break
  done
  printf '%s' "$cur"
}

# litellm_key_covers <KEY_ENV> <model...|'["m1",...]'> — READ-ONLY coverage predicate.
# Returns 0 (covered — do NOT force a re-run) when the scoped key's live allow-list
# already contains EVERY requested model, OR the key is wildcard/unrestricted, OR
# LiteLLM is unreachable, OR the response can't be parsed (soft-on-ambiguous, so a
# precheck-fail means REAL drift, never a LiteLLM blip). Returns 1 ONLY when the key is
# reachable + non-wildcard + genuinely MISSING a requested model. Drops empty args;
# accepts positional names OR one JSON array. Control-plane self-lookup only (no model
# load). Built on _litellm_key_allowlist so the scoped secret never lands in a log.
litellm_key_covers() {
  local key_env="$1"; shift
  local want=()
  if [[ $# -eq 1 && "$1" == \[* ]]; then
    local _mj _l
    _mj="$(printf '%s' "$1" | python3 -c 'import sys,json
try: print("\n".join(json.load(sys.stdin)))
except Exception: pass' 2>/dev/null || true)"
    while IFS= read -r _l; do [[ -n "$_l" ]] && want+=("$_l"); done <<< "$_mj"
  else
    want=("$@")
  fi
  local _kept=() _x
  for _x in "${want[@]}"; do [[ -n "$_x" ]] && _kept+=("$_x"); done
  want=("${_kept[@]}")
  [[ ${#want[@]} -gt 0 ]] || return 0     # nothing to check -> covered
  local key; key="$(get_env "$key_env" '')"
  [[ -n "$key" ]] || return 0             # no key minted -> can't judge -> soft-covered
  local cur; cur="$(_litellm_key_allowlist "$key")"
  [[ -z "$cur" ]] && return 0             # unreachable -> soft-covered (never force re-run on a blip)
  printf '%s\n' "$cur" | grep -qxF '__wildcard__' && return 0   # unrestricted -> covers everything
  local m
  for m in "${want[@]}"; do
    printf '%s\n' "$cur" | grep -qxF "$m" || return 1   # genuinely missing a requested model
  done
  return 0
}

# litellm_reconcile_key_exact <KEY_ENV> <model...|'["m1",...]'> — converge a scoped key
# to EXACTLY <models>. The EXACT-convergence sibling of litellm_reconcile_key (which
# only WIDENS): this ADDS missing entries AND REMOVES stale EXTRAS — a slug renamed/
# removed from the catalog (e.g. the ca08cc1 nemotron-only cull) that a widen-only pass
# can never drop. One /key/update REPLACE, same key string (no .env churn, no restart).
# Idempotent (no-op when already set-equal). This is the primitive model sync P3b + the
# doctor _fix call to remove drift.
# SAFETY ("never narrow a key we still need") lives in the CALLER's set (fleet=superset;
# opt-in=scoped_key_registry_models UNION any live assignment). WILDCARD-safe (unrestricted
# key untouched), EMPTY-safe (empty intended = no-op; POSTing [] would WIDEN), UNREACHABLE-
# safe (empty read = skip). WARN-non-fatal; the scoped key never hits argv/stdout/logs.
litellm_reconcile_key_exact() {
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
  # Drop empty model args — never keep a key allowing "".
  local _kept=() _x
  for _x in "${desired[@]}"; do [[ -n "$_x" ]] && _kept+=("$_x"); done
  desired=("${_kept[@]}")
  [[ ${#desired[@]} -gt 0 ]] || return 0    # empty intended == unrestricted; never POST []
  local master key base cur=""
  master="$(get_env LITELLM_MASTER_KEY '')"
  key="$(get_env "$key_env" '')"
  [[ -n "$key" && -n "$master" ]] || return 0   # key not minted (consumer not installed) -> skip
  # Read the live allow-list AND resolve the base IN-SCOPE (not via a command-substituted
  # helper whose _LL_KEY_BASE side-effect would be trapped in the subshell) so the base is
  # available for the /key/update below. Mirrors litellm_reconcile_key's proven loop.
  for base in "${LITELLM_BASE_URL:-http://litellm:4000}" "http://127.0.0.1:4000"; do
    cur="$(litellm_scoped_curl "$key" -s --max-time 5 "$base/key/info" 2>/dev/null \
      | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
info=d.get("info")
if not isinstance(info,dict): sys.exit(0)
m=info.get("models") or []
print("__wildcard__" if (not m or any(x in ("all-proxy-models","all-team-models") for x in m)) else "\n".join(m))' 2>/dev/null || true)"
    [[ -n "$cur" ]] && break
  done
  if [[ -z "$cur" ]] || printf '%s\n' "$cur" | grep -qxF '__wildcard__'; then return 0; fi
  _sets_equal "$cur" "$(printf '%s\n' "${desired[@]}")" && return 0   # already EXACT
  log "Reconciling $key_env allow-list -> EXACTLY {${desired[*]}} (catalog drift: add missing + drop stale extras)…"
  # New list = EXACTLY the desired set (deduped, order-stable), built with json.dumps
  # (no shell-injection of model names / the key into the JSON body).
  local body resp
  local _rx=''; case $- in *x*) _rx=1; set +x;; esac
  body="$(_RK_KEY="$key" _RK_DES="$(printf '%s\n' "${desired[@]}")" python3 -c '
import json,os
out=[]
for x in os.environ["_RK_DES"].splitlines():
    if x and x not in out: out.append(x)
print(json.dumps({"key":os.environ["_RK_KEY"],"models":out}))' 2>/dev/null || true)"
  [[ -n "$_rx" ]] && set -x
  [[ -n "$body" ]] || { warn "reconcile-exact $key_env: could not build request body"; return 0; }
  # POST the scoped-key-bearing body from a 0600 temp file via --data @file (key off
  # argv); a SUBSHELL EXIT trap removes it on every path, isolated from the outer lock.
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
    ok "$key_env allow-list converged to EXACTLY {${desired[*]}}"
  else
    warn "Could not reconcile $key_env allow-list (LiteLLM /key/update failed) — drifted-model calls may 403"
  fi
}

# scoped_key_registry — the SINGLE SOURCE OF TRUTH for the 7 OPT-IN consumer scoped keys
# (metagpt/agentscope/oasis/chatdev/aitown/concordia/openwork). These mint a hardcoded
# allow-list at their own phase and are NOT in the models.yml `kinds` fleet, so `model
# sync` never reconciled them — a catalog rename/removal silently drifted them + 403'd the
# renamed model. `model sync` P3b iterates this (converging each EXISTING key EXACT via
# litellm_reconcile_key_exact); the regression test asserts registry==phase-mint. One row:
#   KEY_ENV|ALIAS|OWNER|MODELS_JSON     ('|' — never appears in a model name)
# MODELS_JSON MUST equal that phase's mint list (the regression test asserts this).
# (mempalace/aionui keep their own phase-time union reconcile — out of scope here.)
scoped_key_registry() {
  cat <<'EOF'
METAGPT_LITELLM_KEY|metagpt|metagpt|["local","claude-opus-sub-xhigh","claude-sonnet-sub-high"]
AGENTSCOPE_LITELLM_KEY|agentscope|agentscope|["local","claude-opus-sub-xhigh","claude-sonnet-sub-high"]
OASIS_LITELLM_KEY|oasis|oasis|["local","claude-opus-sub-xhigh","claude-sonnet-sub-high"]
CHATDEV_LITELLM_KEY|chatdev|chatdev|["local","claude-opus-sub-xhigh","claude-sonnet-sub-high"]
AITOWN_LITELLM_KEY|aitown|aitown|["local","embed-local","claude-opus-sub-xhigh","claude-sonnet-sub-high"]
CONCORDIA_LITELLM_KEY|concordia|concordia|["claude-sonnet-sub-high","claude-opus-sub-xhigh","local"]
OPENWORK_LITELLM_KEY|openwork|openwork|["claude-opus-sub-xhigh","claude-opus-sub-high","claude-sonnet-sub-high","local"]
EOF
}

# scoped_key_registry_models <KEY_ENV> — echo the intended allow-list JSON array for a
# registered opt-in key (empty when not in the registry).
scoped_key_registry_models() {
  local want="$1" ke al ow mj
  while IFS='|' read -r ke al ow mj; do
    [[ -z "$ke" ]] && continue
    if [[ "$ke" == "$want" ]]; then printf '%s\n' "$mj"; return 0; fi
  done < <(scoped_key_registry)
  return 0
}
