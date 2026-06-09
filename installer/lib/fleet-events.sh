#!/usr/bin/env bash
# fleet-events.sh — canonical lifecycle event logger for the ai-stack fleet.
# Source this file; do NOT run it directly.
#
# Provides:
#   fleet_event <component> <event> <sandbox> [key=value ...]
#
# Appends one JSONL line to $AI_STACK/installer/state/fleet-lifecycle.jsonl.
# Schema (same as openshell-checkpoint.sh's _event):
#   {"ts":"<iso8601>","component":"<component>","event":"<event>","sandbox":"<sandbox>"[,"<k>":"<v>"...]}
#
# Contract:
#   • Best-effort: NEVER fails the caller; all errors are silently swallowed.
#   • Idempotent structure: every caller gets the same schema regardless of source.
#   • AI_STACK must already be set (or resolvable from BASH_SOURCE[0]) before sourcing.
#   • Safe to source multiple times (guard prevents double-definition).
#
# Usage example:
#   source "$AI_STACK/installer/lib/fleet-events.sh"
#   fleet_event "fleet"      "sandbox_create"  "hermes-fleet-v1" "phase=04"
#   fleet_event "watchdog"   "storm_detected"  "pi-v1"           "cid=abc123" "action=halt"
#   fleet_event "checkpoint" "checkpoint_ok"   "hermes-fleet-v1" "image=openshell-checkpoint/hermes-fleet-v1:20260608-120000-storm"

# --- guard against double-sourcing -------------------------------------------
[[ -n "${_FLEET_EVENTS_LOADED:-}" ]] && return 0
_FLEET_EVENTS_LOADED=1

# Resolve AI_STACK if not already set. When sourced from a script in bin/ the
# BASH_SOURCE path walks up one level; from installer/lib/ it walks up two.
# We try both so this file is safe to source from anywhere in the tree.
if [[ -z "${AI_STACK:-}" ]]; then
  _fe_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # installer/lib → ../.. = repo root
  if [[ -f "$_fe_dir/../../vz-ai-stack.sh" ]]; then
    AI_STACK="$(cd "$_fe_dir/../.." && pwd)"
  # bin/ → .. = repo root
  elif [[ -f "$_fe_dir/../vz-ai-stack.sh" ]]; then
    AI_STACK="$(cd "$_fe_dir/.." && pwd)"
  fi
  unset _fe_dir
fi

# ---------------------------------------------------------------------------
# fleet_event <component> <event> <sandbox> [key=value ...]
#
#   component  — subsystem emitting the event  (e.g. "fleet", "watchdog", "checkpoint")
#   event      — lifecycle verb                (e.g. "sandbox_create", "storm_detected")
#   sandbox    — sandbox name                  (e.g. "hermes-fleet-v1", "pi-v1", "")
#   key=value  — zero or more extra fields appended to the JSON object
#
# All arguments are sanitised: double-quotes and backslashes are escaped so the
# output is valid JSON even if a value contains unusual characters.
# ---------------------------------------------------------------------------
fleet_event() {
  # Silence any error from within; never propagate a non-zero exit.
  {
    local component="${1:-unknown}" event="${2:-unknown}" sandbox="${3:-}" ; shift 3 2>/dev/null || shift $# 2>/dev/null || true

    # Require AI_STACK; silently drop the event if we cannot resolve a log path.
    [[ -z "${AI_STACK:-}" ]] && return 0

    local log_file="$AI_STACK/installer/state/fleet-lifecycle.jsonl"
    mkdir -p "$(dirname "$log_file")" 2>/dev/null || return 0

    # ISO-8601 timestamp (same format as openshell-checkpoint.sh).
    local ts; ts="$(date '+%Y-%m-%dT%H:%M:%S%z')" 2>/dev/null || ts="unknown"

    # _esc — escape double-quotes and backslashes inside a JSON string value.
    _fleet_event_esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

    # Build the base JSON object.
    local json
    json="{\"ts\":\"$(_fleet_event_esc "$ts")\",\"component\":\"$(_fleet_event_esc "$component")\",\"event\":\"$(_fleet_event_esc "$event")\",\"sandbox\":\"$(_fleet_event_esc "$sandbox")\""

    # Append extra key=value pairs.
    local kv k v
    for kv in "$@"; do
      k="${kv%%=*}"
      v="${kv#*=}"
      json="$json,\"$(_fleet_event_esc "$k")\":\"$(_fleet_event_esc "$v")\""
    done
    json="$json}"

    # Append atomically with printf (single write syscall → no interleaved lines).
    printf '%s\n' "$json" >> "$log_file" 2>/dev/null || true
  } 2>/dev/null || true
  return 0
}
