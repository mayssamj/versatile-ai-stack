#!/usr/bin/env bash
# openshell-checkpoint.sh — VERIFIED, non-destructive checkpoint of an OpenShell
# sandbox's writable layer (all in-sandbox agent state) to a Docker image, taken
# BEFORE any delete/recreate. This is the H3 data-safety PRIMITIVE: every sandbox
# delete call-site (installer/lib/openshell.sh storm branch, bin/openshell-watchdog.sh,
# installer/lib/reset.sh, installer/lib/fleet.sh) gates on this script succeeding.
#
# WHY (incident 2026-06-08): a sandbox's 1h gateway token expires → the relay
# storms → the platform's only documented cure was `openshell sandbox delete` +
# recreate, which DISCARDS /sandbox state (kanban.db, state.db, memories, sessions,
# profiles). The remediation WAS the data-loss event. This makes every delete
# fail-CLOSED: if the state cannot be captured, the delete is refused.
#
# Usage:
#   openshell-checkpoint.sh <sandbox-name> [reason]   # commit + verify (default)
#   openshell-checkpoint.sh list <sandbox-name>       # list existing checkpoints
#   openshell-checkpoint.sh latest <sandbox-name>     # print newest checkpoint image ref
#
#   <sandbox-name>  e.g. hermes-fleet-v1, pi-v1, or a user `fleet new` name
#   [reason]        free-text tag suffix: storm|teardown|destroy|preinstall|manual|...
#
# Output: on success prints the committed image ref (openshell-checkpoint/<name>:<ts>-<reason>)
#         to stdout and appends a lifecycle event. Captures both RUNNING and EXITED
#         containers (docker commit works on a stopped container — verified live).
# Exit:   0 verified checkpoint (or list/latest ok)
#         1 no container found for that sandbox (nothing to checkpoint)
#         2 docker missing / commit failed / verification failed (caller MUST NOT delete)
#
# Tunables (env): OPENSHELL_CHECKPOINT_KEEP (default 5 newest retained per sandbox).
# Reused, dependency-light (only `docker` + coreutils): safe to call under launchd's
# minimal PATH, so it resolves the docker binary the same way the watchdog does.
set -Eeuo pipefail

AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
KEEP="${OPENSHELL_CHECKPOINT_KEEP:-5}"
REPO_NS="openshell-checkpoint"
EVENT_LOG="$AI_STACK/installer/state/fleet-lifecycle.jsonl"

# Resolve docker even under launchd's minimal PATH (OrbStack lives under $HOME).
_find() { for p in "$@"; do [[ -x "$p" ]] && { echo "$p"; return 0; }; done; command -v "$(basename "$1")" 2>/dev/null || echo ""; }
DOCKER="$(_find /opt/homebrew/bin/docker "$HOME/.orbstack/bin/docker" /usr/local/bin/docker)"

# Engine-aware: do NOT assume OrbStack. Prefer the gateway.env DOCKER_HOST (the
# gateway's own source of truth); fall back to the registry from AI_STACK_DOCKER_ENGINE.
if [[ -z "${DOCKER_HOST:-}" ]]; then
  _gw_dh="$(grep -E '^DOCKER_HOST=' "$HOME/.config/openshell/gateway.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  if [[ -n "${_gw_dh:-}" ]]; then
    export DOCKER_HOST="$_gw_dh"
  elif [[ -n "${AI_STACK:-}" && -f "$AI_STACK/installer/lib/docker-engine.sh" ]]; then
    # shellcheck disable=SC1090
    source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
    source "$AI_STACK/installer/lib/docker-engine.sh"
    _eng="$(get_env AI_STACK_DOCKER_ENGINE "" 2>/dev/null || true)"
    if [[ -n "${_eng:-}" ]] && _engine_valid "$_eng" 2>/dev/null; then
      _dh="$(engine_socket "$_eng" 2>/dev/null || true)"; [[ -n "${_dh:-}" ]] && export DOCKER_HOST="$_dh"
    fi
  fi
  unset _gw_dh _eng _dh 2>/dev/null || true
fi

_ts()  { date '+%Y%m%d-%H%M%S'; }
_iso() { date '+%Y-%m-%dT%H:%M:%S%z'; }
# JSON-escape a value (backslash + double-quote) so a crafted sandbox name/reason can
# never break the JSONL lifecycle log or inject fields (audit 2026-06-08).
_esc() { printf '%s' "${1:-}" | sed 's/\\/\\\\/g; s/"/\\"/g'; }

# _event <event> <name> <k=v>... — append one structured JSONL lifecycle record.
# Best-effort and never fails the caller (the checkpoint itself is what matters).
_event() {
  local ev="$1" name="$2"; shift 2 || true
  local extra="" kv k v
  for kv in "$@"; do
    k="${kv%%=*}"; v="${kv#*=}"
    extra="$extra,\"$(_esc "$k")\":\"$(_esc "$v")\""
  done
  mkdir -p "$(dirname "$EVENT_LOG")" 2>/dev/null || true
  printf '{"ts":"%s","component":"checkpoint","event":"%s","sandbox":"%s"%s}\n' \
    "$(_iso)" "$(_esc "$ev")" "$(_esc "$name")" "$extra" >> "$EVENT_LOG" 2>/dev/null || true
}

_resolve_cid() {  # echo the container id (running OR exited) for a sandbox name
  local name="$1"
  "$DOCKER" ps -aq --filter "name=openshell-${name}-" 2>/dev/null | head -1
}

_sanitize() { printf '%s' "$1" | tr -c 'a-zA-Z0-9._-' '-'; }

_prune_old() {  # keep the newest $KEEP checkpoints for <name>; rmi the rest
  local name="$1" tag n=0
  # `docker images` lists newest-first; one ref per tag.
  "$DOCKER" images --filter=reference="${REPO_NS}/${name}:*" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null \
    | while IFS= read -r tag; do
        n=$((n+1))
        if (( n > KEEP )); then
          "$DOCKER" rmi "$tag" >/dev/null 2>&1 && echo "  pruned old checkpoint $tag" || true
        fi
      done
}

cmd_list() {
  local name="$1"
  [[ -n "$DOCKER" ]] || { echo "docker not found" >&2; return 2; }
  "$DOCKER" images --filter=reference="${REPO_NS}/${name}:*" \
    --format 'table {{.Repository}}:{{.Tag}}\t{{.CreatedAt}}\t{{.Size}}' 2>/dev/null
}

cmd_latest() {
  local name="$1"
  [[ -n "$DOCKER" ]] || return 2
  "$DOCKER" images --filter=reference="${REPO_NS}/${name}:*" --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | head -1
}

cmd_checkpoint() {
  local name="$1" reason; reason="$(_sanitize "${2:-manual}")"
  [[ -n "$name" ]] || { echo "usage: openshell-checkpoint.sh <sandbox-name> [reason]" >&2; return 2; }
  if [[ -z "$DOCKER" ]]; then
    echo "✗ checkpoint($name): docker binary not found — cannot snapshot, REFUSING (fail-closed)" >&2
    _event "checkpoint_failed" "$name" "reason=$reason" "cause=no-docker"
    return 2
  fi
  local cid; cid="$(_resolve_cid "$name")"
  if [[ -z "$cid" ]]; then
    # No container at all — nothing to lose. Caller treats exit 1 as "skip-ok".
    echo "· checkpoint($name): no container present (nothing to snapshot)" >&2
    _event "checkpoint_skipped" "$name" "reason=$reason" "cause=no-container"
    return 1
  fi
  local ts img; ts="$(_ts)"; img="${REPO_NS}/${name}:${ts}-${reason}"
  if ! "$DOCKER" commit \
        -c 'LABEL ai-stack.keep=true' \
        -c "LABEL ai-stack.checkpoint-of=${name}" \
        -c "LABEL ai-stack.checkpoint-reason=${reason}" \
        -c "LABEL ai-stack.checkpoint-ts=${ts}" \
        "$cid" "$img" >/dev/null 2>&1; then
    echo "✗ checkpoint($name): docker commit FAILED — REFUSING to proceed (fail-closed)" >&2
    _event "checkpoint_failed" "$name" "reason=$reason" "cause=commit-failed" "cid=${cid:0:12}"
    return 2
  fi
  # VERIFY the image actually exists before declaring success — a delete may only
  # proceed on a verified snapshot.
  if ! "$DOCKER" image inspect "$img" >/dev/null 2>&1; then
    echo "✗ checkpoint($name): commit reported ok but image $img not found on verify — REFUSING" >&2
    _event "checkpoint_failed" "$name" "reason=$reason" "cause=verify-failed"
    return 2
  fi
  echo "✓ checkpoint($name): $img (verified, label ai-stack.keep=true)" >&2
  _event "checkpoint_ok" "$name" "reason=$reason" "image=$img" "cid=${cid:0:12}"
  _prune_old "$name" >&2 || true
  printf '%s\n' "$img"   # machine-readable: the image ref on stdout
  return 0
}

case "${1:-}" in
  list)   shift; cmd_list "${1:?usage: openshell-checkpoint.sh list <name>}";;
  latest) shift; cmd_latest "${1:?usage: openshell-checkpoint.sh latest <name>}";;
  ""|-h|--help) echo "usage: openshell-checkpoint.sh <sandbox-name> [reason] | list <name> | latest <name>" >&2; exit 2;;
  *)      cmd_checkpoint "$1" "${2:-}";;
esac
