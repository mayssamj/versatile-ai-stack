#!/usr/bin/env bash
# openshell.sh — OpenShell sandbox lifecycle helpers with a hang-resilient
# create path. Sourced by Phase 04 (hermes-fleet-v1) and Phase 15 (pi-v1).
#
# WHY THIS EXISTS
# ---------------
# On M-series macOS, `openshell sandbox create` frequently does NOT return even
# after the sandbox reaches Phase=Ready — the gateway relay stream stays open
# and the CLI blocks indefinitely (HANDOFF §2.2). The sandbox itself is fully
# created and usable; only the client command is stuck. Observed live
# 2026-05-30: hermes-fleet-v1 reached Ready in ~90s, container Up, yet the
# create CLI was still blocked 6+ minutes later. Both sandbox-creating phases
# previously had an UNBOUNDED `if openshell sandbox create ...; then` and would
# hang the whole installer here.
#
# RECOVERY TIERS (cheapest first; this is the "automated recovery dance" the
# operator asked to be reproducible):
#   1. Watchdog: run create in the background, poll `sandbox get` for Phase.
#      The instant Phase=Ready, kill the (hung) CLI and report success. This
#      resolves the common post-Ready hang deterministically.
#   2. On Phase=Error / never-Ready within the timeout: delete the sandbox and
#      recreate once (clears a half-created / errored record).
#   3. Last resort: `brew services restart openshell` + delete + recreate. This
#      restart errors EVERY existing sandbox (upstream limitation), so it is
#      gated behind OPENSHELL_ALLOW_GATEWAY_RESTART (default 1) and logs loudly.
#      Other sandboxes recover on their own phase's next run (which now uses
#      this same idempotent ensure path).
#
# Tunables (env): OPENSHELL_CREATE_TIMEOUT (default 240s),
#                 OPENSHELL_ALLOW_GATEWAY_RESTART (default 1).
#
# Depends on: common.sh (log/ok/warn/err, $AI_STACK) and validate.sh
# (port_listening). Both are sourced defensively below if not already present.

[[ -n "${AI_STACK:-}" ]] || { echo "openshell.sh: AI_STACK unset (source common.sh first)" >&2; return 1 2>/dev/null || exit 1; }
declare -F log >/dev/null 2>&1            || source "$AI_STACK/installer/lib/common.sh"
declare -F port_listening >/dev/null 2>&1 || source "$AI_STACK/installer/lib/validate.sh"

_osh_strip_ansi() { sed $'s/\x1b\\[[0-9;]*m//g'; }

# openshell_sandbox_phase <OSH> <name>
# Echoes the sandbox Phase (Ready|Error|Creating|Pending|...) or "" if the
# sandbox does not exist. ALWAYS returns 0 so callers using `set -e` +
# command-substitution don't trip errexit when the sandbox is absent.
openshell_sandbox_phase() {
  local osh="$1" name="$2"
  "$osh" sandbox get "$name" 2>/dev/null | _osh_strip_ansi \
    | awk '/^[[:space:]]*Phase:[[:space:]]*/ {print $2; exit}' || true
}

# openshell_sandbox_delete <OSH> <name> — best-effort, never blocks the caller.
# delete can itself hang on the relay; cap it with a background+kill watchdog.
openshell_sandbox_delete() {
  local osh="$1" name="$2"
  "$osh" sandbox delete "$name" >/dev/null 2>&1 &
  local dpid=$! waited=0
  while (( waited < 30 )); do
    kill -0 "$dpid" 2>/dev/null || { wait "$dpid" 2>/dev/null || true; return 0; }
    # Gone from the registry? Consider delete done.
    [[ -z "$(openshell_sandbox_phase "$osh" "$name")" ]] && { _osh_kill "$dpid"; return 0; }
    sleep 2; waited=$((waited+2))
  done
  _osh_kill "$dpid"
  return 0
}

# _osh_kill <pid> — TERM, brief grace, then KILL, then reap. Guarded for set -e.
_osh_kill() {
  local pid="${1:-}"
  [[ -n "$pid" ]] || return 0
  kill -TERM "$pid" 2>/dev/null || true
  sleep 0.5
  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

# openshell_sandbox_create_watchdog <OSH> <name> <from> <timeout_s> [-- EXTRA_CREATE_ARGS...]
# Runs create in the background and polls Phase. Any args after a literal `--`
# are appended to the create command verbatim (e.g. `--policy <file> -- /bin/true`
# for Phase 15's create-with-policy). Returns:
#   0 -> Ready    1 -> Error/Failed    2 -> timed out / stuck (no Ready)
openshell_sandbox_create_watchdog() {
  local osh="$1" name="$2" from="$3" timeout_s="${4:-${OPENSHELL_CREATE_TIMEOUT:-240}}"
  shift 4 2>/dev/null || true
  [[ "${1:-}" == "--" ]] && shift
  local extra=( "$@" )
  local logf="$AI_STACK/installer/state/openshell-create-${name}.log"
  : > "$logf" 2>/dev/null || true
  log "Creating sandbox '$name' (--from $from ${extra[*]:-}); watchdog polls Phase=Ready (<= ${timeout_s}s, log: $(basename "$logf"))..."
  "$osh" sandbox create --name "$name" --from "$from" "${extra[@]}" >"$logf" 2>&1 &
  local cpid=$! waited=0 phase=""
  while (( waited < timeout_s )); do
    # CLI returned on its own? Stop polling and trust the final phase read.
    if ! kill -0 "$cpid" 2>/dev/null; then wait "$cpid" 2>/dev/null || true; break; fi
    phase="$(openshell_sandbox_phase "$osh" "$name")"
    case "$phase" in
      Ready)        _osh_kill "$cpid"; ok "sandbox '$name' reached Ready (freed hung create CLI)"; return 0 ;;
      Error|Failed) _osh_kill "$cpid"; warn "sandbox '$name' entered Phase=$phase (see $logf)"; return 1 ;;
    esac
    sleep 3; waited=$((waited+3))
  done
  phase="$(openshell_sandbox_phase "$osh" "$name")"
  _osh_kill "$cpid"
  case "$phase" in
    Ready)        ok "sandbox '$name' Ready"; return 0 ;;
    Error|Failed) warn "sandbox '$name' Phase=$phase after ${timeout_s}s (see $logf)"; return 1 ;;
    *)            warn "sandbox '$name' not Ready after ${timeout_s}s (phase='${phase:-none}', see $logf)"; return 2 ;;
  esac
}

# openshell_sandbox_ensure <OSH> <name> [from] [-- EXTRA_CREATE_ARGS...]
# Idempotent, hang-resilient. Returns 0 iff the sandbox ends in Phase=Ready.
# Safe to call when the sandbox already exists (no-op if already Ready).
# Extra args after `--` are forwarded to `sandbox create` (e.g. Phase 15 passes
# `-- --policy <file> -- /bin/true` to create with its tight policy from birth).
openshell_sandbox_ensure() {
  local osh="$1" name="$2" from="${3:-base}"
  shift 3 2>/dev/null || true
  [[ "${1:-}" == "--" ]] && shift
  local extra=( "$@" )
  local create_timeout="${OPENSHELL_CREATE_TIMEOUT:-240}"
  local allow_restart="${OPENSHELL_ALLOW_GATEWAY_RESTART:-1}"
  local phase rc

  # OpenShell attaches every sandbox to the `openshell-docker` network; the
  # gateway does NOT auto-create it. Missing -> create fails HTTP 404.
  if ! docker network ls --format '{{.Name}}' | grep -qx openshell-docker; then
    docker network create openshell-docker >/dev/null 2>&1 \
      && ok "created docker network: openshell-docker" \
      || warn "could not create openshell-docker network — create may fail"
  fi

  phase="$(openshell_sandbox_phase "$osh" "$name")"
  if [[ "$phase" == "Ready" ]]; then ok "sandbox '$name' already Ready"; return 0; fi
  if [[ -n "$phase" ]]; then
    warn "sandbox '$name' present in Phase=$phase; deleting before recreate"
    openshell_sandbox_delete "$osh" "$name"
  fi

  # Tier 1.
  openshell_sandbox_create_watchdog "$osh" "$name" "$from" "$create_timeout" -- "${extra[@]}"; rc=$?
  [[ $rc -eq 0 ]] && return 0

  # Tier 2: delete + one retry.
  warn "create attempt 1 failed (rc=$rc) — deleting + retrying once"
  openshell_sandbox_delete "$osh" "$name"
  openshell_sandbox_create_watchdog "$osh" "$name" "$from" "$create_timeout" -- "${extra[@]}"; rc=$?
  [[ $rc -eq 0 ]] && return 0

  # Tier 3: gateway restart (heavy — errors all sandboxes).
  if [[ "$allow_restart" == "1" ]] && command -v brew >/dev/null 2>&1; then
    warn "escalating recovery: 'brew services restart openshell' (this errors ALL sandboxes; each recovers on its phase's next run)"
    brew services restart openshell >/dev/null 2>&1 || true
    local i=0; while (( i < 60 )); do port_listening 17670 && break; sleep 1; i=$((i+1)); done
    openshell_sandbox_delete "$osh" "$name"
    openshell_sandbox_create_watchdog "$osh" "$name" "$from" "$create_timeout" -- "${extra[@]}"; rc=$?
    [[ $rc -eq 0 ]] && return 0
  fi

  warn "sandbox '$name' could not reach Ready after all recovery tiers"
  return 1
}
