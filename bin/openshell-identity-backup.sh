#!/usr/bin/env bash
# openshell-identity-backup.sh — H7 gateway identity-plane backup.
#
# THE RISK: the gateway DB (openshell.db, journal_mode=delete) and JWT signing
# material (signing.pem, kid, public.pem) are the MASTER identity plane for
# every OpenShell sandbox.  Corruption or accidental key-regen while sandbox
# tokens are outstanding BRICKS every sandbox — including all checkpoint images
# (which embed the old public key as their authorization anchor).  This script
# provides four hardening operations:
#
#   backup      (default) — consistent DB snapshot via sqlite3 .backup + key cp;
#                integrity-verified; rotates to newest N copies.
#   list        — display existing identity backups.
#   guard-regen — gate: print loud refusal + exit 1 if any sandbox tokens exist.
#   enable-wal  — EXPLICIT maintenance op (quiesce-first); dry-runs unless
#                 AI_STACK_CONFIRM_WAL=1.
#   install     — install a daily launchd timer (label
#                 com.ai-stack.openshell-identity-backup).
#   uninstall   — remove the timer.
#
# Tunables (env):
#   OPENSHELL_IDENTITY_KEEP  — how many backup dirs to retain (default 14)
#   AI_STACK_ALLOW_KEY_REGEN — guard-regen override (must be set to 1 deliberately)
#   AI_STACK_CONFIRM_WAL     — enable-wal confirmation (must be set to 1)
#
# Exit codes: 0 = success/safe, 1 = nothing present / unsafe condition, 2 = hard failure.
set -Eeuo pipefail

AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
KEEP="${OPENSHELL_IDENTITY_KEEP:-14}"

# Gateway state paths (verified locations).
GW_STATE="$HOME/.local/state/openshell"
GW_DB="$GW_STATE/gateway/openshell.db"
JWT_DIR="$GW_STATE/homebrew/tls/jwt"
TOKEN_DIR="$GW_STATE/docker-sandbox-tokens/default"

BACKUP_ROOT="$AI_STACK/data/openshell-identity-backups"
EVENT_LOG="$AI_STACK/installer/state/fleet-lifecycle.jsonl"
STATE="$AI_STACK/installer/state"

# --- tool resolution (launchd has a minimal PATH) ----------------------------
_find() { for p in "$@"; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done; command -v "$(basename "$1")" 2>/dev/null || echo ""; }
SQLITE3="$(_find /opt/homebrew/bin/sqlite3 /usr/local/bin/sqlite3 /usr/bin/sqlite3)"
OPENSHELL="$(_find /opt/homebrew/bin/openshell /usr/local/bin/openshell)"
BREW="$(_find /opt/homebrew/bin/brew /usr/local/bin/brew)"

# --- helpers -----------------------------------------------------------------
_ts()   { date '+%Y%m%d-%H%M%S'; }
_iso()  { date '+%Y-%m-%dT%H:%M:%S%z'; }
_log()  { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# Append one structured JSONL lifecycle record.  Best-effort; never fails caller.
_event() {
  local ev="$1" comp="${2:-identity-backup}"; shift 2 || true
  local extra="" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    extra="$extra,\"$k\":\"$v\""
  done
  mkdir -p "$(dirname "$EVENT_LOG")" 2>/dev/null || true
  printf '{"ts":"%s","component":"%s","event":"%s"%s}\n' \
    "$(_iso)" "$comp" "$ev" "$extra" >> "$EVENT_LOG" 2>/dev/null || true
}

# --- subcommand: backup -------------------------------------------------------
cmd_backup() {
  local ts; ts="$(_ts)"
  local out="$BACKUP_ROOT/$ts"

  _log "identity-backup: starting backup → $out"

  # Require sqlite3.
  if [[ -z "$SQLITE3" ]]; then
    _log "ERROR: sqlite3 not found — cannot create a consistent DB snapshot"
    _event "identity_backup_failed" "identity-backup" "cause=no-sqlite3"
    return 2
  fi

  # The DB must exist.
  if [[ ! -f "$GW_DB" ]]; then
    _log "WARNING: gateway DB not found at $GW_DB — nothing to back up"
    _event "identity_backup_skipped" "identity-backup" "cause=no-db"
    return 1
  fi

  mkdir -p "$out"

  # Consistent online backup (sqlite3 .backup handles journal_mode=delete safely;
  # a plain cp can produce a torn read when the journal is active).
  if ! "$SQLITE3" "$GW_DB" ".backup $out/openshell.db" 2>&1; then
    _log "ERROR: sqlite3 .backup FAILED — removing partial output"
    rm -rf "$out"
    _event "identity_backup_failed" "identity-backup" "cause=sqlite-backup-failed"
    return 2
  fi

  # Copy signing material (preserve timestamps + permissions).
  local key_copied=0
  for f in signing.pem kid public.pem; do
    local src="$JWT_DIR/$f"
    if [[ -f "$src" ]]; then
      cp -p "$src" "$out/$f"
      key_copied=1
    else
      _log "WARNING: key file missing: $src (may not exist yet)"
    fi
  done

  # Verify: integrity_check on the backup DB must return 'ok'.
  local ic
  ic="$("$SQLITE3" "$out/openshell.db" 'PRAGMA integrity_check;' 2>&1 || echo "FAILED")"
  if [[ "$ic" != "ok" ]]; then
    _log "ERROR: backup DB integrity_check returned: $ic — marking backup invalid"
    # Write a sentinel so the dir is not silently trusted.
    printf 'INTEGRITY_FAILED: %s\n' "$ic" > "$out/INVALID"
    _event "identity_backup_failed" "identity-backup" "cause=integrity-check-failed" "dir=$out"
    return 2
  fi

  # Verify: key files must be non-empty (if they were present at source).
  if (( key_copied == 1 )); then
    for f in signing.pem kid public.pem; do
      local dst="$out/$f"
      if [[ -f "$dst" ]] && [[ ! -s "$dst" ]]; then
        _log "ERROR: key file $f was copied but is empty in backup"
        printf 'EMPTY_KEY: %s\n' "$f" >> "$out/INVALID"
        _event "identity_backup_failed" "identity-backup" "cause=empty-key-file" "file=$f" "dir=$out"
        return 2
      fi
    done
  fi

  _log "identity-backup: backup verified OK → $out"
  _event "identity_backup_ok" "identity-backup" "dir=$out" "integrity=ok"

  # Prune: retain the newest $KEEP backup directories.
  _prune_old
  return 0
}

# _prune_old — delete all but the newest $KEEP dirs under BACKUP_ROOT.
_prune_old() {
  local dirs n=0
  # ls -1t sorts newest-first; mapfile requires bash 4+.
  mapfile -t dirs < <(ls -1t "$BACKUP_ROOT" 2>/dev/null)
  for d in "${dirs[@]}"; do
    n=$(( n + 1 ))
    if (( n > KEEP )); then
      rm -rf "${BACKUP_ROOT:?}/$d"
      _log "identity-backup: pruned old backup $d (keep=${KEEP})"
    fi
  done
}

# --- subcommand: list ---------------------------------------------------------
cmd_list() {
  if [[ ! -d "$BACKUP_ROOT" ]] || [[ -z "$(ls -A "$BACKUP_ROOT" 2>/dev/null)" ]]; then
    echo "No identity backups found under $BACKUP_ROOT"
    return 0
  fi
  printf '%-22s  %-8s  %s\n' "TIMESTAMP" "STATUS" "PATH"
  local d
  for d in $(ls -1t "$BACKUP_ROOT" 2>/dev/null); do
    local full="$BACKUP_ROOT/$d"
    local status="ok"
    [[ -f "$full/INVALID" ]] && status="INVALID"
    printf '%-22s  %-8s  %s\n' "$d" "$status" "$full"
  done
}

# --- subcommand: guard-regen --------------------------------------------------
# Exit 0 = SAFE to regen (no outstanding tokens, no live sandboxes).
# Exit 1 = UNSAFE (tokens exist); prints a loud refusal.
cmd_guard_regen() {
  # Explicit override: the caller MUST set this deliberately.
  if [[ "${AI_STACK_ALLOW_KEY_REGEN:-0}" == "1" ]]; then
    _log "guard-regen: AI_STACK_ALLOW_KEY_REGEN=1 — override accepted; proceeding (verify you know what you are doing)"
    _event "guard_regen_bypassed" "identity-backup" "override=AI_STACK_ALLOW_KEY_REGEN"
    return 0
  fi

  local unsafe=0

  # Check 1: are there bootstrap-token dirs for any sandbox?
  if [[ -d "$TOKEN_DIR" ]]; then
    local token_count
    token_count="$(find "$TOKEN_DIR" -name 'sandbox.jwt' 2>/dev/null | wc -l | tr -d ' ')"
    if (( token_count > 0 )); then
      unsafe=1
      printf '\n'
      printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
      printf '!!  DANGER: %d outstanding sandbox bootstrap token(s) found under     !!\n' "$token_count"
      printf '!!  %s\n' "$TOKEN_DIR"
      printf '!!                                                                     !!\n'
      printf '!!  Regenerating signing.pem/kid while tokens exist WILL BRICK every  !!\n'
      printf '!!  sandbox and every checkpoint image — the old public key is baked  !!\n'
      printf '!!  into each.  This cannot be undone without manual key surgery.     !!\n'
      printf '!!                                                                     !!\n'
      printf '!!  If you truly understand the consequences, set:                    !!\n'
      printf '!!    AI_STACK_ALLOW_KEY_REGEN=1 bash %s guard-regen\n' "$0"
      printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
      printf '\n'
    fi
  fi

  # Check 2: is `openshell sandbox list` non-empty (live sandboxes)?
  if [[ -n "$OPENSHELL" ]]; then
    local sb_out sb_count
    sb_out="$("$OPENSHELL" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tail -n +2 | grep -v '^\s*$' || true)"
    sb_count="$(printf '%s' "$sb_out" | grep -c . 2>/dev/null || echo 0)"
    if (( sb_count > 0 )); then
      unsafe=1
      printf '\n'
      printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
      printf '!!  DANGER: %d live sandbox(es) reported by openshell sandbox list.   !!\n' "$sb_count"
      printf '!!  These sandboxes hold tokens signed with the CURRENT key.          !!\n'
      printf '!!  Delete/recreate them ALL before regenerating the signing material !!\n'
      printf '!!  — or set AI_STACK_ALLOW_KEY_REGEN=1 if you accept the risk.      !!\n'
      printf '!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!\n'
      printf '\n'
    fi
  else
    _log "guard-regen: openshell binary not found; skipping live-sandbox check (conservative)"
    # Conservative: if we cannot check, don't block — but warn.
    _log "guard-regen: WARNING — could not verify sandbox list; proceeding cautiously"
  fi

  if (( unsafe == 1 )); then
    _event "guard_regen_blocked" "identity-backup" "reason=outstanding-tokens-or-sandboxes"
    return 1
  fi

  _log "guard-regen: SAFE — no outstanding sandbox tokens and no live sandboxes"
  _event "guard_regen_safe" "identity-backup"
  return 0
}

# --- subcommand: enable-wal ---------------------------------------------------
# An EXPLICIT, guarded maintenance op.  Dry-runs unless AI_STACK_CONFIRM_WAL=1.
cmd_enable_wal() {
  cat <<'PLAN'

=== enable-wal: PLAN ===
This command switches the gateway DB to WAL (Write-Ahead Logging) journal mode.

WHY:  WAL allows concurrent readers during a write, reduces corruption risk on
      hard-reset, and is generally safer for a long-running gateway process.

WHY NOT AUTO:  Switching journal_mode on a LIVE DB without quiescing the gateway
      can corrupt it (the gateway holds open file handles with the current mode
      cached; a mode switch mid-flight tears the journal).  Hence: gateway MUST be
      stopped, mode switched, then restarted.

STEPS (what will run when AI_STACK_CONFIRM_WAL=1):
  1. backup          — consistent snapshot before any change (abort if backup fails)
  2. brew services stop openshell
  3. sqlite3 <db> "PRAGMA journal_mode=WAL;"
  4. brew services start openshell

TO RUN:  AI_STACK_CONFIRM_WAL=1 bash $0 enable-wal
PLAN

  if [[ "${AI_STACK_CONFIRM_WAL:-0}" != "1" ]]; then
    echo ""
    echo "Dry-run only (AI_STACK_CONFIRM_WAL != 1).  No changes made."
    return 0
  fi

  echo ""
  echo "AI_STACK_CONFIRM_WAL=1 — proceeding with enable-wal."

  if [[ -z "$SQLITE3" ]]; then
    _log "ERROR: sqlite3 not found — cannot switch journal mode"
    return 2
  fi
  if [[ -z "$BREW" ]]; then
    _log "ERROR: brew not found — cannot stop/start openshell service"
    return 2
  fi
  if [[ ! -f "$GW_DB" ]]; then
    _log "ERROR: gateway DB not found at $GW_DB"
    return 2
  fi

  # Step 1: backup first — abort if it fails.
  _log "enable-wal: step 1/4 — backing up identity plane before any change"
  cmd_backup || { _log "enable-wal: backup FAILED — aborting (DB unchanged)"; return 2; }

  # Step 2: stop gateway.
  _log "enable-wal: step 2/4 — stopping openshell service (quiesce before mode switch)"
  "$BREW" services stop openshell

  # Step 3: switch to WAL.
  _log "enable-wal: step 3/4 — PRAGMA journal_mode=WAL"
  local result
  result="$("$SQLITE3" "$GW_DB" 'PRAGMA journal_mode=WAL;' 2>&1 || echo "FAILED")"
  if [[ "$result" != "wal" ]]; then
    _log "ERROR: journal_mode switch returned '$result' (expected 'wal') — restarting gateway and aborting"
    "$BREW" services start openshell || true
    _event "enable_wal_failed" "identity-backup" "result=$result"
    return 2
  fi
  _log "enable-wal: journal_mode=WAL confirmed"

  # Step 4: restart gateway.
  _log "enable-wal: step 4/4 — starting openshell service"
  "$BREW" services start openshell

  _log "enable-wal: complete — journal_mode is now WAL"
  _event "enable_wal_ok" "identity-backup" "db=$GW_DB"
  return 0
}

# --- subcommands: install / uninstall launchd timer --------------------------
PLIST="$HOME/Library/LaunchAgents/com.ai-stack.openshell-identity-backup.plist"
LABEL="com.ai-stack.openshell-identity-backup"
INTERVAL=86400   # daily

cmd_install() {
  mkdir -p "$HOME/Library/LaunchAgents" "$STATE"
  cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$AI_STACK/bin/openshell-identity-backup.sh</string><string>backup</string>
  </array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key><false/>
  <key>EnvironmentVariables</key><dict>
    <key>AI_STACK</key><string>$AI_STACK</string>
    <key>OPENSHELL_IDENTITY_KEEP</key><string>${KEEP}</string>
    <key>PATH</key><string>${SQLITE3:+$(dirname "$SQLITE3"):}/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>$STATE/openshell-identity-backup.launchd.log</string>
  <key>StandardErrorPath</key><string>$STATE/openshell-identity-backup.launchd.log</string>
</dict></plist>
PL
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null \
    || launchctl load "$PLIST" 2>/dev/null || true
  echo "openshell-identity-backup launchd job installed ($LABEL, every ${INTERVAL}s / daily)"
}

cmd_uninstall() {
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null \
    || launchctl unload "$PLIST" 2>/dev/null || true
  rm -f "$PLIST"
  echo "openshell-identity-backup launchd job removed"
}

# --- dispatch -----------------------------------------------------------------
case "${1:-backup}" in
  backup)      cmd_backup ;;
  list)        cmd_list ;;
  guard-regen) cmd_guard_regen ;;
  enable-wal)  cmd_enable_wal ;;
  install)     cmd_install ;;
  uninstall)   cmd_uninstall ;;
  -h|--help)
    cat >&2 <<'USAGE'
usage: openshell-identity-backup.sh [backup|list|guard-regen|enable-wal|install|uninstall]

  backup       (default) consistent snapshot of gateway DB + JWT signing material
  list         show existing identity backups
  guard-regen  exit 0 if safe to regen key; exit 1 + loud refusal otherwise
               (override: AI_STACK_ALLOW_KEY_REGEN=1)
  enable-wal   dry-run plan; run with AI_STACK_CONFIRM_WAL=1 to execute
  install      install daily launchd timer (com.ai-stack.openshell-identity-backup)
  uninstall    remove launchd timer
USAGE
    exit 2 ;;
  *)
    echo "unknown subcommand: $1  (try --help)" >&2; exit 2 ;;
esac
