#!/usr/bin/env bash
# fleet-trace.sh — human-readable inspection + OTLP export of fleet lifecycle events.
#
# Subcommands:
#   tail [n]       — pretty-print the last n events (default 20) from fleet-lifecycle.jsonl
#   stats          — event/component/sandbox counts
#   export-otlp    — forward NEW events as OTLP log records to the Phoenix collector;
#                    tracks a byte-offset cursor in installer/state/fleet-trace.cursor
#                    so re-runs only send new events; no-op if endpoint is absent.
#
# Reads PHOENIX_COLLECTOR_HTTP_ENDPOINT and PHOENIX_API_KEY from $AI_STACK/.env
# (values parsed inline; never printed to stdout/stderr).
#
# Resolves docker/sqlite3/curl under launchd's minimal PATH via the same _find()
# pattern used by openshell-watchdog.sh and openshell-checkpoint.sh.
set -Eeuo pipefail

AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
EVENT_LOG="$AI_STACK/installer/state/fleet-lifecycle.jsonl"
CURSOR_FILE="$AI_STACK/installer/state/fleet-trace.cursor"

# Resolve tools even under launchd's minimal PATH.
_find() { for p in "$@"; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done; command -v "$(basename "$1")" 2>/dev/null || echo ""; }
CURL="$(_find /opt/homebrew/bin/curl /usr/bin/curl /usr/local/bin/curl)"
JQ="$(_find   /opt/homebrew/bin/jq   /usr/local/bin/jq)"

_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }

# ---------------------------------------------------------------------------
# _parse_env_key <file> <KEY>
# Extract KEY=value from a .env file without printing the value to any stream.
# Returns the value on stdout only; never errors.
# ---------------------------------------------------------------------------
_parse_env_key() {
  local file="$1" key="$2"
  # Match KEY=value or KEY="value" — strip optional surrounding quotes.
  grep -m1 "^${key}=" "$file" 2>/dev/null \
    | sed "s/^${key}=//; s/^['\"]//; s/['\"]$//" \
    || true
}

# ---------------------------------------------------------------------------
# cmd_tail [n] — pretty-print the last n events as a human-readable table.
# ---------------------------------------------------------------------------
cmd_tail() {
  local n="${1:-20}"
  if [[ ! -f "$EVENT_LOG" ]]; then
    echo "No lifecycle log found at $EVENT_LOG" >&2
    return 0
  fi

  # Column widths for a readable table.
  local sep="  "
  printf '%-26s  %-14s  %-22s  %-20s  %s\n' \
    "TIMESTAMP" "COMPONENT" "EVENT" "SANDBOX" "EXTRAS"
  printf '%s\n' "$(printf '%.0s─' {1..100})"

  tail -n "$n" "$EVENT_LOG" 2>/dev/null | while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Parse fields with jq if available; fall back to sed-based extraction.
    if [[ -n "$JQ" ]]; then
      ts="$( printf '%s' "$line" | "$JQ" -r '.ts        // ""' 2>/dev/null)"
      comp="$(printf '%s' "$line" | "$JQ" -r '.component // ""' 2>/dev/null)"
      ev="$(  printf '%s' "$line" | "$JQ" -r '.event     // ""' 2>/dev/null)"
      sb="$(  printf '%s' "$line" | "$JQ" -r '.sandbox   // ""' 2>/dev/null)"
      # Extras = all keys except the 4 base fields, formatted as k=v pairs.
      extras="$(printf '%s' "$line" | "$JQ" -r \
        'to_entries | map(select(.key | IN("ts","component","event","sandbox") | not)) | map("\(.key)=\(.value)") | join(" ")' \
        2>/dev/null)"
    else
      # Minimal sed fallback — handles the fixed schema without jq.
      ts="$(  printf '%s' "$line" | sed 's/.*"ts":"\([^"]*\)".*/\1/')"
      comp="$(printf '%s' "$line" | sed 's/.*"component":"\([^"]*\)".*/\1/')"
      ev="$(  printf '%s' "$line" | sed 's/.*"event":"\([^"]*\)".*/\1/')"
      sb="$(  printf '%s' "$line" | sed 's/.*"sandbox":"\([^"]*\)".*/\1/')"
      extras=""
    fi

    # Truncate timestamp to 26 chars (ISO-8601 without sub-seconds is 24).
    ts="${ts:0:26}"
    printf '%-26s  %-14s  %-22s  %-20s  %s\n' \
      "$ts" "${comp:0:14}" "${ev:0:22}" "${sb:0:20}" "$extras"
  done
  return 0
}

# ---------------------------------------------------------------------------
# cmd_stats — counts grouped by event, component, and sandbox.
# ---------------------------------------------------------------------------
cmd_stats() {
  if [[ ! -f "$EVENT_LOG" ]]; then
    echo "No lifecycle log found at $EVENT_LOG" >&2
    return 0
  fi

  local total; total="$(wc -l < "$EVENT_LOG" 2>/dev/null || echo 0)"
  echo "Fleet lifecycle event stats  ($EVENT_LOG)"
  echo "Total events: ${total//[[:space:]]/}"
  echo ""

  if [[ -n "$JQ" ]]; then
    echo "── By event ──────────────────────────"
    "$JQ" -r '.event' "$EVENT_LOG" 2>/dev/null \
      | sort | uniq -c | sort -rn \
      | awk '{printf "  %5d  %s\n", $1, $2}'

    echo ""
    echo "── By component ──────────────────────"
    "$JQ" -r '.component' "$EVENT_LOG" 2>/dev/null \
      | sort | uniq -c | sort -rn \
      | awk '{printf "  %5d  %s\n", $1, $2}'

    echo ""
    echo "── By sandbox ────────────────────────"
    "$JQ" -r '.sandbox // "(none)"' "$EVENT_LOG" 2>/dev/null \
      | sort | uniq -c | sort -rn \
      | awk '{printf "  %5d  %s\n", $1, $2}'
  else
    # Fallback: sed-based extraction, same groupings.
    echo "── By event ──────────────────────────"
    sed 's/.*"event":"\([^"]*\)".*/\1/' "$EVENT_LOG" 2>/dev/null \
      | sort | uniq -c | sort -rn \
      | awk '{printf "  %5d  %s\n", $1, $2}'

    echo ""
    echo "── By component ──────────────────────"
    sed 's/.*"component":"\([^"]*\)".*/\1/' "$EVENT_LOG" 2>/dev/null \
      | sort | uniq -c | sort -rn \
      | awk '{printf "  %5d  %s\n", $1, $2}'

    echo ""
    echo "── By sandbox ────────────────────────"
    sed 's/.*"sandbox":"\([^"]*\)".*/\1/' "$EVENT_LOG" 2>/dev/null \
      | sort | uniq -c | sort -rn \
      | awk '{printf "  %5d  %s\n", $1, $2}'
  fi
  return 0
}

# ---------------------------------------------------------------------------
# cmd_export_otlp — forward new lifecycle events as OTLP/HTTP log records.
#
# Cursor strategy: store the byte offset of the last byte we successfully sent
# in $CURSOR_FILE. On each run we read from that offset to EOF, send those
# records, and advance the cursor only on success. If Phoenix is unreachable we
# leave the cursor unchanged so the next run retries all unsent events.
#
# OTLP/HTTP log record schema (simplified):
#   POST <endpoint>/v1/logs
#   Content-Type: application/json
#   {"resourceLogs":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"ai-stack-fleet"}}]},
#    "scopeLogs":[{"logRecords":[...]}]}]}
# ---------------------------------------------------------------------------
cmd_export_otlp() {
  if [[ ! -f "$EVENT_LOG" ]]; then
    echo "No lifecycle log found — nothing to export." >&2
    return 0
  fi

  # --- read Phoenix config from .env (values never printed) ---
  local env_file="$AI_STACK/.env"
  local endpoint="" api_key=""
  if [[ -f "$env_file" ]]; then
    endpoint="$(_parse_env_key "$env_file" "PHOENIX_COLLECTOR_HTTP_ENDPOINT")"
    api_key="$(_parse_env_key "$env_file" "PHOENIX_API_KEY")"
  fi

  if [[ -z "$endpoint" ]]; then
    echo "export-otlp: PHOENIX_COLLECTOR_HTTP_ENDPOINT not set in $env_file — no-op." >&2
    return 0
  fi
  if [[ -z "$CURL" ]]; then
    echo "export-otlp: curl not found — cannot send OTLP records." >&2
    return 0
  fi

  # Normalise endpoint: strip trailing slash.
  endpoint="${endpoint%/}"
  local otlp_url="${endpoint}/v1/logs"

  # --- determine byte offset of last successful send ---
  local cursor=0
  if [[ -f "$CURSOR_FILE" ]]; then
    local stored; stored="$(cat "$CURSOR_FILE" 2>/dev/null || echo 0)"
    # Validate it is a non-negative integer.
    [[ "$stored" =~ ^[0-9]+$ ]] && cursor="$stored" || cursor=0
  fi

  # Total bytes in the log right now.
  local log_size; log_size="$(wc -c < "$EVENT_LOG" 2>/dev/null || echo 0)"
  log_size="${log_size//[[:space:]]/}"

  if (( cursor >= log_size )); then
    echo "export-otlp: no new events since last export (cursor=${cursor}, log_size=${log_size})."
    return 0
  fi

  # Read only the new bytes since the cursor.
  local new_events
  new_events="$(dd if="$EVENT_LOG" bs=1 skip="$cursor" 2>/dev/null)" || {
    echo "export-otlp: failed to read new events from $EVENT_LOG" >&2
    return 1
  }

  local new_end; new_end="$log_size"   # target cursor after success

  # --- build OTLP JSON payload ---
  # Each JSONL line becomes one logRecord. We build the array of records then
  # wrap it in the OTLP resourceLogs envelope.
  local records_json="["
  local first=1
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue

    # Parse fields for OTLP attributes.
    local ts_val comp_val ev_val sb_val body_val
    if [[ -n "$JQ" ]]; then
      ts_val="$(  printf '%s' "$line" | "$JQ" -r '.ts        // ""' 2>/dev/null)"
      comp_val="$(printf '%s' "$line" | "$JQ" -r '.component // ""' 2>/dev/null)"
      ev_val="$(  printf '%s' "$line" | "$JQ" -r '.event     // ""' 2>/dev/null)"
      sb_val="$(  printf '%s' "$line" | "$JQ" -r '.sandbox   // ""' 2>/dev/null)"
      body_val="$line"
    else
      ts_val="$(  printf '%s' "$line" | sed 's/.*"ts":"\([^"]*\)".*/\1/')"
      comp_val="$(printf '%s' "$line" | sed 's/.*"component":"\([^"]*\)".*/\1/')"
      ev_val="$(  printf '%s' "$line" | sed 's/.*"event":"\([^"]*\)".*/\1/')"
      sb_val="$(  printf '%s' "$line" | sed 's/.*"sandbox":"\([^"]*\)".*/\1/')"
      body_val="$line"
    fi

    # Convert ISO-8601 ts to Unix nanoseconds for OTLP timeUnixNano.
    # `date -j -f` is macOS; fall back to epoch 0 if parsing fails.
    local epoch_ns="0"
    if [[ -n "$ts_val" ]]; then
      local epoch_s
      epoch_s="$(date -j -f '%Y-%m-%dT%H:%M:%S%z' "$ts_val" '+%s' 2>/dev/null \
                 || date -d "$ts_val" '+%s' 2>/dev/null \
                 || echo 0)"
      epoch_ns="$(( epoch_s * 1000000000 ))"
    fi

    # Escape body_val for embedding in JSON string (backslash, then quote).
    local body_escaped; body_escaped="$(printf '%s' "$body_val" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    local comp_esc;     comp_esc="$(    printf '%s' "$comp_val" | sed 's/\\/\\\\/g; s/"/\\"/g')"
    local ev_esc;       ev_esc="$(      printf '%s' "$ev_val"   | sed 's/\\/\\\\/g; s/"/\\"/g')"
    local sb_esc;       sb_esc="$(      printf '%s' "$sb_val"   | sed 's/\\/\\\\/g; s/"/\\"/g')"

    local record
    record="{\"timeUnixNano\":\"${epoch_ns}\",\"severityText\":\"INFO\",\"body\":{\"stringValue\":\"${body_escaped}\"},\"attributes\":[{\"key\":\"fleet.component\",\"value\":{\"stringValue\":\"${comp_esc}\"}},{\"key\":\"fleet.event\",\"value\":{\"stringValue\":\"${ev_esc}\"}},{\"key\":\"fleet.sandbox\",\"value\":{\"stringValue\":\"${sb_esc}\"}}]}"

    if [[ "$first" == "1" ]]; then
      records_json="${records_json}${record}"
      first=0
    else
      records_json="${records_json},${record}"
    fi
  done <<< "$new_events"
  records_json="${records_json}]"

  if [[ "$records_json" == "[]" ]]; then
    echo "export-otlp: no parseable events in new bytes — advancing cursor to ${new_end}."
    printf '%s\n' "$new_end" > "$CURSOR_FILE"
    return 0
  fi

  local payload
  payload="{\"resourceLogs\":[{\"resource\":{\"attributes\":[{\"key\":\"service.name\",\"value\":{\"stringValue\":\"ai-stack-fleet\"}}]},\"scopeLogs\":[{\"scope\":{\"name\":\"fleet-trace\"},\"logRecords\":${records_json}}]}]}"

  # --- POST to Phoenix OTLP endpoint ---
  local curl_args=(-s -o /dev/null -w "%{http_code}"
    -X POST "$otlp_url"
    -H "Content-Type: application/json"
    --data-binary "$payload"
    --max-time 15)

  # Add API key header only if set (never log the value).
  if [[ -n "$api_key" ]]; then
    curl_args+=(-H "api_key: ${api_key}")
  fi

  local http_status
  http_status="$("$CURL" "${curl_args[@]}")" || http_status="000"

  if [[ "$http_status" == "000" ]]; then
    echo "export-otlp: curl failed (connection error / timeout) — cursor unchanged; will retry next run." >&2
    return 1
  fi

  # Accept 2xx as success.
  local status_class="${http_status:0:1}"
  if [[ "$status_class" == "2" ]]; then
    printf '%s\n' "$new_end" > "$CURSOR_FILE"
    local record_count; record_count="$(grep -c '^.' <<< "$new_events" 2>/dev/null || echo '?')"
    echo "export-otlp: sent ${record_count} event(s) to ${otlp_url} (HTTP ${http_status}); cursor advanced to ${new_end}."
  else
    echo "export-otlp: Phoenix returned HTTP ${http_status} — cursor unchanged; will retry next run." >&2
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------
case "${1:-}" in
  tail)
    shift
    cmd_tail "${1:-20}"
    ;;
  stats)
    cmd_stats
    ;;
  export-otlp)
    cmd_export_otlp
    ;;
  ""|-h|--help)
    cat >&2 <<'USAGE'
usage: fleet-trace.sh <subcommand> [args]

Subcommands:
  tail [n]        Pretty-print the last n lifecycle events (default: 20).
  stats           Count events grouped by event type, component, and sandbox.
  export-otlp     Forward new events to Phoenix/OTLP; tracks cursor in
                  installer/state/fleet-trace.cursor.  Reads
                  PHOENIX_COLLECTOR_HTTP_ENDPOINT + PHOENIX_API_KEY from .env.
                  No-op if endpoint is absent.
USAGE
    exit 2
    ;;
  *)
    echo "fleet-trace.sh: unknown subcommand '${1}'" >&2
    echo "  run 'fleet-trace.sh --help' for usage" >&2
    exit 2
    ;;
esac
