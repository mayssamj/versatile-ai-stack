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
