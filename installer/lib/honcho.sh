# installer/lib/honcho.sh — Honcho v3 helpers shared by Phase 03, Phase 15,
# and doctor checks. Honcho's REST API lives at /v3/workspaces/{ws}/peers/...
#
# Usage:
#   source "$AI_STACK/installer/lib/honcho.sh"
#   honcho_peer_exists "pi"             # 0=exists, 1=missing, 2=Honcho down
#   honcho_peer_ensure "pi"             # idempotent create
#   honcho_workspace_id                  # echoes the workspace id used by phases
#
# Soft-isolation note: Honcho v3 has no API-key-scoped peer-access enforcement
# at the time of writing — a peer ID is a namespace boundary for writes, not a
# hard read boundary. Pi's policy relies on the prompt + extension-config not
# querying foreign peer IDs. Doctor check 25 reflects this honestly.

HONCHO_BASE_URL="${HONCHO_BASE_URL:-http://honcho:8000}"
HONCHO_WORKSPACE="${HONCHO_WORKSPACE_ID:-default}"

honcho_workspace_id() { echo "$HONCHO_WORKSPACE"; }

honcho_is_up() {
  curl -sf --max-time 3 "$HONCHO_BASE_URL/health" >/dev/null 2>&1
}

honcho_peer_exists() {
  local peer="$1"
  honcho_is_up || return 2
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    "$HONCHO_BASE_URL/v3/workspaces/$HONCHO_WORKSPACE/peers/$peer" 2>/dev/null || true)
  case "$code" in
    2??) return 0 ;;
    404) return 1 ;;
    *)   return 2 ;;
  esac
}

honcho_peer_ensure() {
  local peer="$1"
  honcho_is_up || return 2
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
    -X POST "$HONCHO_BASE_URL/v3/workspaces/$HONCHO_WORKSPACE/peers" \
    -H 'Content-Type: application/json' \
    -d "{\"id\":\"$peer\"}" 2>/dev/null || true)
  case "$code" in
    2??|409) return 0 ;;
    *) return 1 ;;
  esac
}
