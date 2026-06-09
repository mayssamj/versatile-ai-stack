#!/usr/bin/env bash
# ai-stack-changelog.sh — typed CHANGELOG fragment manager.
#
# CHANGELOG.d/ holds two kinds of files:
#   1. Per-run installer logs:  <YYYYMMDD-HHMMSS>-<PID>.md   (written by common.sh record())
#   2. Typed change fragments:  <YYYYMMDD-HHMMSS>-<type>.md  (written by THIS script's `add`)
#      where <type> in {feat,fix,docs,chore,security,incident}
#
# Subcommands:
#   add <type> <message...>  — write one typed fragment (creates CHANGELOG.d/ if absent)
#   render [version]         — prepend a new dated section to CHANGELOG.md grouped by type,
#                              then remove consumed fragments (idempotent; no fragments = no-op)
#   list                     — show pending typed fragments
#
# Integration: the `add` command reuses the $AI_STACK/CHANGELOG.d/ directory that
# common.sh and history.sh already own.  Typed fragments have a '-' followed by a known
# type word as the LAST hyphen-separated token (before .md), so they are unambiguously
# distinguishable from per-run logs (whose suffix is a numeric PID like -12345).
#
# render does NOT touch per-run installer logs — it only consumes typed fragments.
#
# Usage:
#   bash bin/ai-stack-changelog.sh add feat "add checkpoint-before-delete guard"
#   bash bin/ai-stack-changelog.sh add fix  "http_ok 000 false-healthy bug"
#   bash bin/ai-stack-changelog.sh render 2026-06-09
#   bash bin/ai-stack-changelog.sh list
set -Eeuo pipefail

AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

CHANGELOG_D="$AI_STACK/CHANGELOG.d"
CHANGELOG_MD="$AI_STACK/CHANGELOG.md"

VALID_TYPES="feat fix docs chore security incident"

_ts_file() { date '+%Y%m%d-%H%M%S'; }
_ts_human() { date '+%Y-%m-%d'; }
_iso()     { date '+%Y-%m-%dT%H:%M:%S%z'; }

# --- color (same palette as common.sh; guard on non-tty) ---------------------
if [[ -t 1 ]] && [[ "${TERM:-dumb}" != "dumb" ]]; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_RED=$'\033[31m'; C_DIM=$'\033[2m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_BOLD=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_DIM=""; C_BLUE=""
fi

ok()   { printf '%s %s\n' "${C_GREEN}✓${C_RESET}" "$*"; }
warn() { printf '%s %s\n' "${C_YELLOW}⚠${C_RESET}" "$*" >&2; }
err()  { printf '%s %s\n' "${C_RED}✗${C_RESET}" "$*" >&2; }
note() { printf '%s %s\n' "${C_BLUE}·${C_RESET}" "$*"; }

# _is_typed_fragment <filename-basename> — true if the file looks like a typed
# fragment (last dash-token before .md is one of the known types).
_is_typed_fragment() {
  local base="${1%.md}"           # strip .md
  local suffix="${base##*-}"      # last hyphen-separated token
  local t
  for t in $VALID_TYPES; do
    [[ "$suffix" == "$t" ]] && return 0
  done
  return 1
}

# _typed_fragments — print absolute paths of pending typed fragments, sorted.
_typed_fragments() {
  [[ -d "$CHANGELOG_D" ]] || return 0
  local f
  for f in "$CHANGELOG_D"/*.md; do
    [[ -e "$f" ]] || continue
    _is_typed_fragment "$(basename "$f")" && printf '%s\n' "$f"
  done | sort
}

# ---------------------------------------------------------------------------
cmd_add() {
  local type="${1:-}"
  shift || true
  local message="$*"

  # --- validate type ---
  local valid=0 t
  for t in $VALID_TYPES; do [[ "$type" == "$t" ]] && valid=1 && break; done
  if (( valid == 0 )); then
    err "Unknown type '$type'. Valid types: $VALID_TYPES"
    exit 2
  fi

  # --- validate message ---
  if [[ -z "$message" ]]; then
    err "Message must not be empty."
    err "Usage: $0 add <type> <message...>"
    exit 2
  fi

  mkdir -p "$CHANGELOG_D"

  local ts; ts="$(_ts_file)"
  local frag="$CHANGELOG_D/${ts}-${type}.md"

  # Write the fragment (simple format: front-matter line + body).
  printf '<!-- type:%s ts:%s -->\n%s\n' "$type" "$(_iso)" "$message" > "$frag"

  ok "Fragment written: $(basename "$frag")"
  note "  type: $type"
  note "  message: $message"
}

# ---------------------------------------------------------------------------
cmd_list() {
  local frags
  frags="$(_typed_fragments)"
  if [[ -z "$frags" ]]; then
    note "No pending typed fragments in $CHANGELOG_D/"
    return 0
  fi

  printf '%s%sPending fragments:%s\n' "$C_BOLD" "$C_BLUE" "$C_RESET"
  local f base type ts_raw message
  while IFS= read -r f; do
    base="$(basename "$f" .md)"
    type="${base##*-}"
    ts_raw="${base%-*}"   # everything before the last -<type>
    # read message (skip the HTML comment line)
    message="$(grep -v '^<!--' "$f" | head -1)"
    printf '  %s%-10s%s %s%s%s  %s\n' \
      "$C_YELLOW" "$type" "$C_RESET" \
      "$C_DIM" "$ts_raw" "$C_RESET" \
      "$message"
  done <<< "$frags"
}

# ---------------------------------------------------------------------------
cmd_render() {
  local version="${1:-$(_ts_human)}"

  local frags
  frags="$(_typed_fragments)"
  if [[ -z "$frags" ]]; then
    note "No pending typed fragments — nothing to render."
    return 0
  fi

  # --- group fragments by type (use an associative array) ---
  declare -A by_type
  local t; for t in $VALID_TYPES; do by_type["$t"]=""; done

  local f base type message
  while IFS= read -r f; do
    base="$(basename "$f" .md)"
    type="${base##*-}"
    message="$(grep -v '^<!--' "$f" | head -1)"
    by_type["$type"]="${by_type[$type]}"$'\n'"- $message"
  done <<< "$frags"

  # --- build the new section ---
  local section
  section="## ${version}"$'\n'

  local had_content=0
  for t in $VALID_TYPES; do
    local entries="${by_type[$t]:-}"
    [[ -z "$entries" ]] && continue
    had_content=1
    # Capitalise type label.
    local label
    case "$t" in
      feat)     label="Features" ;;
      fix)      label="Bug Fixes" ;;
      docs)     label="Documentation" ;;
      chore)    label="Chores" ;;
      security) label="Security" ;;
      incident) label="Incidents" ;;
      *)        label="$t" ;;
    esac
    section="${section}"$'\n'"### ${label}"$'\n'"${entries}"$'\n'
  done

  if (( had_content == 0 )); then
    note "No content extracted from fragments — nothing to render."
    return 0
  fi

  section="${section}"$'\n'"---"$'\n'

  # --- prepend to CHANGELOG.md (atomic) ------------------------------------
  # Strategy: write header lines up to (but not including) the first '## ' entry,
  # then inject the new section, then append the rest.  If CHANGELOG.md does not
  # exist, create it with a standard preamble.
  if [[ ! -f "$CHANGELOG_MD" ]]; then
    printf '# ai-stack-installer — change log\n\nAuto-appended by `vz-ai-stack.sh`. Newest entries at the top.\n\n---\n\n' > "$CHANGELOG_MD"
  fi

  local tmp; tmp="$(mktemp "${CHANGELOG_MD}.XXXXXX")"
  # Read the preamble (everything before the first '## ' section or the first '---' separator
  # that is followed by a '## ' section), then inject, then append the rest.
  # Simple approach that is safe for this file's known format:
  #   • Copy all lines up through the first '---' separator (the preamble divider).
  #   • Inject the new section immediately after.
  #   • Append the remainder.
  local preamble_done=0
  while IFS= read -r line; do
    printf '%s\n' "$line" >> "$tmp"
    # The preamble ends at the first standalone '---' line.
    if (( preamble_done == 0 )) && [[ "$line" == "---" ]]; then
      preamble_done=1
      printf '\n%s\n' "$section" >> "$tmp"
    fi
  done < "$CHANGELOG_MD"

  # Edge case: no '---' preamble separator found — just prepend.
  if (( preamble_done == 0 )); then
    { printf '%s\n' "$section"; cat "$CHANGELOG_MD"; } > "$tmp"
  fi

  mv -f "$tmp" "$CHANGELOG_MD"
  ok "Prepended section '$version' to $(basename "$CHANGELOG_MD")"

  # --- remove consumed fragments -------------------------------------------
  local removed=0
  while IFS= read -r f; do
    rm -f "$f"
    (( removed++ )) || true
  done <<< "$frags"
  ok "Removed $removed consumed fragment(s) from CHANGELOG.d/"
}

# ---------------------------------------------------------------------------
usage() {
  cat >&2 <<'EOF'
Usage:
  ai-stack-changelog.sh add <type> <message...>   write a typed fragment
  ai-stack-changelog.sh render [version]          prepend new section to CHANGELOG.md + remove fragments
  ai-stack-changelog.sh list                      show pending typed fragments

  Types: feat  fix  docs  chore  security  incident
EOF
  exit 2
}

case "${1:-}" in
  add)     shift; cmd_add "$@" ;;
  render)  shift; cmd_render "${1:-}" ;;
  list)    cmd_list ;;
  ""|-h|--help) usage ;;
  *) err "Unknown subcommand: $1"; usage ;;
esac
