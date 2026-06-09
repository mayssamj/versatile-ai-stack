#!/usr/bin/env bash
# openshell-state-restore.sh — round-trip state extract / inject / verify for
# OpenShell sandboxes.  This is the "never lose data" primitive: it copies
# in-sandbox state OUT of a stopped or running container (or from a checkpoint
# image), folds any SQLite WAL so DBs are consistent, and can push that state
# back INTO a freshly-created sandbox via 'docker cp' — NEVER via
# 'openshell sandbox upload', which silently drops files >~4MB.
#
# Subcommands
# -----------
#   extract <name> [dest]
#     Copy /sandbox from container openshell-<name>-* to <dest> on the host.
#     If <name> looks like an image ref (contains '/') it is treated as a
#     checkpoint image: 'docker create' (NOT 'docker run' — the openshell-
#     sandbox binary is a host RO bind-mount so 'docker run' fails permission-
#     denied), then 'docker cp', then 'docker rm'.
#     After extraction, folds every *.db WAL so DBs are consistent:
#       sqlite3 <db> "PRAGMA wal_checkpoint(TRUNCATE);"
#     Prints a verification summary (profile count, .tables of kanban.db /
#     state.db if present).
#
#   into <name> <src>
#     Restore host directory <src> INTO a freshly-created live sandbox via
#       docker cp <src>/. openshell-<name>-*:/sandbox/
#     Warns if the sandbox is not in Ready state.
#     NEVER uses 'openshell sandbox upload' (silent >4MB truncation).
#
#   verify <src>
#     Assert that <src> contains the expected sandbox artifacts.  Exits non-zero
#     if any required artifact is missing or a DB cannot be opened.
#
# Lifecycle events are appended best-effort to $AI_STACK/installer/state/fleet-lifecycle.jsonl
# Exit codes: 0 = success, 1 = usage / not-found (non-fatal caller), 2 = fatal failure
set -Eeuo pipefail

AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
EVENT_LOG="$AI_STACK/installer/state/fleet-lifecycle.jsonl"

# ---------------------------------------------------------------------------
# Resolve tools under launchd's minimal PATH (OrbStack lives under $HOME).
# ---------------------------------------------------------------------------
_find() { for p in "$@"; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done; command -v "$(basename "$1")" 2>/dev/null || echo ""; }
DOCKER="$(_find /opt/homebrew/bin/docker "$HOME/.orbstack/bin/docker" /usr/local/bin/docker)"
SQLITE3="$(_find /opt/homebrew/bin/sqlite3 /usr/local/bin/sqlite3 /usr/bin/sqlite3)"
OPENSHELL="$(_find /opt/homebrew/bin/openshell /usr/local/bin/openshell)"

_ts()  { date '+%Y%m%d-%H%M%S'; }
_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# ---------------------------------------------------------------------------
# _event <event> <sandbox> [k=v ...]
# ---------------------------------------------------------------------------
_event() {
  local ev="$1" sandbox="$2"; shift 2 || true
  local extra="" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    extra="$extra,\"$k\":\"$v\""
  done
  mkdir -p "$(dirname "$EVENT_LOG")" 2>/dev/null || true
  printf '{"ts":"%s","component":"state-restore","event":"%s","sandbox":"%s"%s}\n' \
    "$(_iso)" "$ev" "$sandbox" "$extra" >> "$EVENT_LOG" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# _resolve_cid <name> — first container id (running OR exited) for the sandbox
# ---------------------------------------------------------------------------
_resolve_cid() {
  local name="$1"
  "$DOCKER" ps -aq --filter "name=openshell-${name}-" 2>/dev/null | head -1
}

# ---------------------------------------------------------------------------
# _container_status <cid> — e.g. "running", "exited"
# ---------------------------------------------------------------------------
_container_status() {
  "$DOCKER" inspect --format '{{.State.Status}}' "$1" 2>/dev/null || echo "unknown"
}

# ---------------------------------------------------------------------------
# _fold_wal <dir> — checkpoint every *.db WAL in <dir> so state is consistent
# ---------------------------------------------------------------------------
_fold_wal() {
  local dir="$1"
  [[ -z "$SQLITE3" ]] && { echo "  (sqlite3 not found — skipping WAL fold)" >&2; return 0; }
  local db count=0
  while IFS= read -r -d '' db; do
    if "$SQLITE3" "$db" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1; then
      echo "  WAL folded: $db" >&2
      count=$((count + 1))
    else
      echo "  WAL fold skipped/failed: $db (may be locked or not WAL mode)" >&2
    fi
  done < <(find "$dir" -name '*.db' -print0 2>/dev/null)
  echo "  $count database(s) WAL-folded in $dir" >&2
}

# ---------------------------------------------------------------------------
# _print_summary <dir> — verification summary printed to stdout
# ---------------------------------------------------------------------------
_print_summary() {
  local dir="$1"
  echo ""
  echo "=== Extraction summary: $dir ==="

  # Profile count (.hermes/profiles/)
  local prof_dir="$dir/.hermes/profiles"
  if [[ -d "$prof_dir" ]]; then
    local n_prof; n_prof="$(find "$prof_dir" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
    echo "  hermes profiles : $n_prof"
  else
    echo "  hermes profiles : (directory not found: $prof_dir)"
  fi

  # .tables for kanban.db and state.db
  for dbname in kanban.db state.db; do
    local dbpath; dbpath="$(find "$dir" -name "$dbname" 2>/dev/null | head -1)"
    if [[ -n "$dbpath" ]]; then
      if [[ -n "$SQLITE3" ]]; then
        local tables; tables="$("$SQLITE3" "$dbpath" ".tables" 2>&1 || echo "(error reading)")"
        echo "  $dbname tables   : $tables"
      else
        echo "  $dbname          : found (sqlite3 not available for .tables)"
      fi
    else
      echo "  $dbname          : (not found in $dir)"
    fi
  done

  # Overall file count
  local total; total="$(find "$dir" -type f 2>/dev/null | wc -l | tr -d ' ')"
  echo "  total files     : $total"
  echo "==================================="
}

# ---------------------------------------------------------------------------
# cmd_extract <name-or-image-ref> [dest]
# ---------------------------------------------------------------------------
cmd_extract() {
  local ref="${1:?usage: openshell-state-restore.sh extract <name|image-ref> [dest]}"
  local dest="${2:-}"
  [[ -n "$DOCKER" ]] || { echo "✗ extract: docker not found" >&2; _event "extract_failed" "$ref" "cause=no-docker"; return 2; }

  # Default destination: ./sandbox-restore-<ref-slug>-<ts>
  local slug; slug="$(printf '%s' "$ref" | tr -c 'a-zA-Z0-9._-' '-' | sed 's/-*$//')"
  [[ -z "$dest" ]] && dest="./sandbox-restore-${slug}-$(_ts)"

  mkdir -p "$dest"

  # Determine whether <ref> is an image ref (contains '/') or a sandbox name.
  local tmp_cid=""
  if [[ "$ref" == */* ]]; then
    # --- image ref: use 'docker create' (NOT 'docker run' — openshell-sandbox
    #     binary is a host RO bind-mount; 'docker run' fails permission-denied) ---
    echo "· extract: creating temporary container from image $ref ..." >&2
    tmp_cid="$("$DOCKER" create "$ref" 2>/dev/null)" || {
      echo "✗ extract: docker create from image $ref FAILED" >&2
      _event "extract_failed" "$ref" "cause=docker-create-failed"
      return 2
    }
    echo "  temporary container: ${tmp_cid:0:12}" >&2
    # Copy the CONTENTS of /sandbox: the trailing '/.' includes DOTFILES/dotdirs
    # (.hermes/.agents/.claude/.pi — where the real fleet state lives). Copying
    # '/sandbox' (no '/.') nests under dest/sandbox, and a subsequent '*' hoist
    # SKIPS dotfiles — the bug that stranded .hermes on the first round-trip test.
    if ! "$DOCKER" cp "${tmp_cid}:/sandbox/." "$dest/"; then
      echo "✗ extract: docker cp from image container FAILED" >&2
      "$DOCKER" rm "$tmp_cid" >/dev/null 2>&1 || true
      _event "extract_failed" "$ref" "cause=docker-cp-failed" "cid=${tmp_cid:0:12}"
      return 2
    fi
    "$DOCKER" rm "$tmp_cid" >/dev/null 2>&1 \
      && echo "  temporary container removed" >&2 \
      || echo "  (warning: docker rm of temp container failed — manual cleanup may be needed)" >&2
    tmp_cid=""  # cleared so trap does not attempt a second rm
    _event "extract_ok" "$ref" "source=image" "dest=$dest"
  else
    # --- sandbox name: cp from the live/exited container ---
    local cid; cid="$(_resolve_cid "$ref")"
    if [[ -z "$cid" ]]; then
      echo "· extract($ref): no container found (nothing to extract)" >&2
      _event "extract_skipped" "$ref" "cause=no-container"
      return 1
    fi
    local status; status="$(_container_status "$cid")"
    echo "· extract($ref): container ${cid:0:12} status=$status" >&2
    # Copy CONTENTS of /sandbox: trailing '/.' includes dotfiles/dotdirs
    # (.hermes/.agents/.claude/.pi — the real fleet state); a '*' hoist skips them.
    if ! "$DOCKER" cp "${cid}:/sandbox/." "$dest/"; then
      echo "✗ extract($ref): docker cp from container FAILED" >&2
      _event "extract_failed" "$ref" "cause=docker-cp-failed" "cid=${cid:0:12}" "status=$status"
      return 2
    fi
    _event "extract_ok" "$ref" "source=container" "cid=${cid:0:12}" "status=$status" "dest=$dest"
  fi

  # Fold WAL files so DBs are consistent before use / archival.
  _fold_wal "$dest"

  # Verification summary.
  _print_summary "$dest"

  echo ""
  echo "✓ extract($ref): state saved to $dest"
  return 0
}

# ---------------------------------------------------------------------------
# cmd_into <name> <src>
# ---------------------------------------------------------------------------
cmd_into() {
  local name="${1:?usage: openshell-state-restore.sh into <name> <src>}"
  local src="${2:?usage: openshell-state-restore.sh into <name> <src>}"
  [[ -n "$DOCKER" ]] || { echo "✗ into($name): docker not found" >&2; _event "into_failed" "$name" "cause=no-docker"; return 2; }
  [[ -d "$src" ]] || { echo "✗ into($name): source directory not found: $src" >&2; _event "into_failed" "$name" "cause=src-missing" "src=$src"; return 2; }

  local cid; cid="$(_resolve_cid "$name")"
  if [[ -z "$cid" ]]; then
    echo "✗ into($name): no container found — create the sandbox first, then restore" >&2
    _event "into_failed" "$name" "cause=no-container"
    return 2
  fi

  # Warn if sandbox is not in Ready state (container may be running but gateway
  # relay not yet Ready).
  local status; status="$(_container_status "$cid")"
  if [[ "$status" != "running" ]]; then
    echo "⚠  into($name): container ${cid:0:12} is in state '$status' (expected running/Ready)" >&2
    echo "   The copy will proceed but the sandbox may need a restart to load the new state." >&2
  fi
  if [[ -n "$OPENSHELL" ]]; then
    local osh_status
    osh_status="$("$OPENSHELL" sandbox list 2>/dev/null \
      | sed $'s/\x1b\\[[0-9;]*m//g' \
      | awk -v n="$name" 'NR>1 && $1==n {print $NF}' \
      | head -1)" || osh_status="unknown"
    if [[ "$osh_status" != "Ready" ]]; then
      echo "⚠  into($name): openshell reports sandbox state '$osh_status' (want Ready)" >&2
      echo "   Proceeding — ensure you restart the container after restore if needed." >&2
    fi
  fi

  # NEVER use 'openshell sandbox upload' — it silently truncates files >~4MB.
  # Always use docker cp for reliable, complete transfer.
  echo "· into($name): copying $src → container ${cid:0:12}:/sandbox/ ..." >&2
  if ! "$DOCKER" cp "$src/." "${cid}:/sandbox/"; then
    echo "✗ into($name): docker cp FAILED" >&2
    _event "into_failed" "$name" "cause=docker-cp-failed" "cid=${cid:0:12}" "src=$src"
    return 2
  fi

  echo "✓ into($name): state restored from $src into container ${cid:0:12}" >&2
  _event "into_ok" "$name" "cid=${cid:0:12}" "src=$src" "container_status=$status"

  echo ""
  echo "✓ into($name): restore complete."
  echo "  If the sandbox relay was already running you may need to restart the container"
  echo "  ('docker restart ${cid:0:12}') so the agent re-reads the restored state."
  return 0
}

# ---------------------------------------------------------------------------
# cmd_verify <src>
# ---------------------------------------------------------------------------
cmd_verify() {
  local src="${1:?usage: openshell-state-restore.sh verify <src>}"
  local rc=0

  echo "=== verify: $src ===" >&2

  # (1) Directory must exist.
  if [[ ! -d "$src" ]]; then
    echo "✗ verify: directory does not exist: $src" >&2
    _event "verify_failed" "" "cause=src-missing" "src=$src"
    return 2
  fi

  # (2) .hermes/profiles must be non-empty.
  local prof_dir="$src/.hermes/profiles"
  if [[ ! -d "$prof_dir" ]]; then
    echo "✗ verify: .hermes/profiles not found in $src" >&2
    rc=2
  else
    local n_prof; n_prof="$(find "$prof_dir" -maxdepth 1 -mindepth 1 -type d | wc -l | tr -d ' ')"
    if (( n_prof == 0 )); then
      echo "✗ verify: .hermes/profiles exists but is empty (no profile directories)" >&2
      rc=2
    else
      echo "✓ verify: $n_prof hermes profile(s) found" >&2
    fi
  fi

  # (3) kanban.db must exist and be openable.
  local kanban; kanban="$(find "$src" -name 'kanban.db' 2>/dev/null | head -1)"
  if [[ -z "$kanban" ]]; then
    echo "⚠  verify: kanban.db not found (may be acceptable if fleet not yet initialised)" >&2
    # Not a hard failure — a fresh sandbox may have no kanban.db yet.
  else
    if [[ -n "$SQLITE3" ]]; then
      if "$SQLITE3" "$kanban" ".tables" >/dev/null 2>&1; then
        local tables; tables="$("$SQLITE3" "$kanban" ".tables" 2>/dev/null || echo "(read error)")"
        echo "✓ verify: kanban.db opens OK (tables: $tables)" >&2
      else
        echo "✗ verify: kanban.db found but CANNOT be opened by sqlite3 — DB may be corrupt" >&2
        rc=2
      fi
    else
      echo "  verify: kanban.db found (sqlite3 not available for integrity check)" >&2
    fi
  fi

  # (4) state.db check (advisory — not all sandboxes have it).
  local statedb; statedb="$(find "$src" -name 'state.db' 2>/dev/null | head -1)"
  if [[ -n "$statedb" ]]; then
    if [[ -n "$SQLITE3" ]]; then
      if "$SQLITE3" "$statedb" ".tables" >/dev/null 2>&1; then
        echo "✓ verify: state.db opens OK" >&2
      else
        echo "✗ verify: state.db found but CANNOT be opened — DB may be corrupt" >&2
        rc=2
      fi
    fi
  fi

  if (( rc == 0 )); then
    _event "verify_ok" "" "src=$src"
    echo ""
    echo "✓ verify($src): all required artifacts present and readable"
  else
    _event "verify_failed" "" "src=$src" "rc=$rc"
    echo ""
    echo "✗ verify($src): one or more required artifacts are MISSING or CORRUPT (see above)" >&2
  fi
  return $rc
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
  extract) shift; cmd_extract "$@" ;;
  into)    shift; cmd_into    "$@" ;;
  verify)  shift; cmd_verify  "$@" ;;
  ""|-h|--help)
    cat >&2 <<'USAGE'
usage: openshell-state-restore.sh <subcommand> [args]

Subcommands:
  extract <name> [dest]    copy /sandbox state OUT of container / checkpoint image to host
  into    <name> <src>     restore host <src> INTO a freshly-created sandbox via docker cp
  verify  <src>            assert required artifacts exist; exits non-zero if not

<name> is the sandbox name (e.g. hermes-fleet-v1, pi-v1) or a checkpoint image ref (contains '/').
<dest> defaults to ./sandbox-restore-<name>-<timestamp> in the current directory.
USAGE
    exit 2 ;;
  *) echo "✗ unknown subcommand: $1  (use extract|into|verify)" >&2; exit 2 ;;
esac
