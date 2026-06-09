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

# NOTE (2026-06-06): an earlier `openshell_relay_ok` (a backgrounded `sandbox
# exec` probe reaped with _osh_kill) was REMOVED. It was both unreliable and
# HARMFUL: killing the openshell CLI mid-relay-open left dangling gateway
# channels and could push a healthy sandbox into `phase: Unspecified`; and a
# CLI/gateway VERSION SKEW (a PATH `openshell` newer than the running gateway)
# made the probe read `Unspecified`/time-out on a sandbox that was actually fine.
# Detect the real failure (expired token) via the LOG signature below instead —
# it is reliable and NON-INVASIVE — and always drive sandbox exec through
# osh_bin/resolve_openshell so the CLI matches the gateway it created.

# openshell_token_storm <name> — true (0) iff the sandbox container shows the
# expired-token signature in its recent logs: the in-sandbox agent's
# RefreshSandboxToken returns Unauthenticated / `invalid token: ExpiredSignature`.
# The token CANNOT self-refresh ("static token sources cannot rebootstrap
# automatically", verified upstream) — only RECREATING the sandbox mints a fresh
# one. Mirrors bin/openshell-watchdog.sh::_is_storming, but matches ONLY the LOG
# signature (never CPU): a low-CPU manifestation exists where the agent retries on
# a ~5s cadence (0.2% CPU) rather than a no-backoff storm — the relay is just as
# dead, so a CPU threshold would miss it. Returns 1 if docker / container /
# signature is absent (caller treats that as "unknown cause", still recreates).
openshell_token_storm() {
  local name="$1" docker_bin cid logs to=""
  docker_bin="$(command -v docker 2>/dev/null || true)"
  [[ -n "$docker_bin" ]] || return 1
  cid="$("$docker_bin" ps -q --filter "name=openshell-${name}-" 2>/dev/null | head -1)"
  [[ -n "$cid" ]] || return 1
  # Bound the log read: a wedged docker daemon must not hang the installer.
  # Prefer coreutils timeout/gtimeout; killing a `docker logs` reader is harmless
  # (unlike killing an openshell exec, which degrades the gateway). Fall back to
  # plain if neither is present (the watchdog has run this unbounded in prod).
  if   command -v timeout  >/dev/null 2>&1; then to="timeout 10"
  elif command -v gtimeout >/dev/null 2>&1; then to="gtimeout 10"; fi
  logs="$($to "$docker_bin" logs "$cid" --since 3m --tail 200 2>&1 || true)"
  grep -q 'ExpiredSignature' <<<"$logs" && return 0
  grep -q 'RefreshSandboxToken.*Unauthenticated' <<<"$logs" && return 0
  return 1
}

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

# _osh_harden_container <name> — H5: pin RestartPolicy=no on the freshly-created
# sandbox container so a host reboot / self-exit does NOT auto-restart it straight
# back into an expired-token storm (incident 2026-06-08; the gateway sets
# unless-stopped by default, which RESURRECTED the storm post-reboot). A
# credential-bound container must be (re)started only after a valid token is
# confirmed — recovery becomes a conscious refresh/recreate. Best-effort + NON-fatal:
# a sandbox that is up + Ready must never be failed by this hardening step.
_osh_harden_container() {
  local name="$1" docker_bin cid
  docker_bin="$(command -v docker 2>/dev/null || true)"
  [[ -n "$docker_bin" ]] || return 0
  cid="$("$docker_bin" ps -q --filter "name=openshell-${name}-" 2>/dev/null | head -1)"
  [[ -n "$cid" ]] || return 0
  "$docker_bin" update --restart=no "$cid" >/dev/null 2>&1 \
    && log "  hardened '$name': RestartPolicy=no (won't self-resurrect a storm on reboot)" \
    || warn "  could not set RestartPolicy=no on '$name' (non-fatal)"
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
  # H1 — native, gateway-honored resource caps + prune-safe labels at create time.
  # Caps BOUND a token-expiry storm so it can never starve the host again (incident
  # 2026-06-08: two uncapped sandboxes pegged the host into a hard reboot). Labels
  # bring the container under ai-stack tooling and make it survive `docker container
  # prune`. Set OPENSHELL_SANDBOX_CPU=0 / OPENSHELL_SANDBOX_MEM=0 to omit a cap. These
  # are TOP-LEVEL `sandbox create` flags and MUST precede "${extra[@]}" (post-`--`
  # args, e.g. Phase 15's `--policy <file> -- /bin/true`).
  local cap_args=( --label ai-stack.managed=true --label ai-stack.keep=true )
  local _cpu="${OPENSHELL_SANDBOX_CPU:-1.5}" _mem="${OPENSHELL_SANDBOX_MEM:-3Gi}"
  [[ "$_cpu" != "0" ]] && cap_args+=( --cpu "$_cpu" )
  [[ "$_mem" != "0" ]] && cap_args+=( --memory "$_mem" )
  log "Creating sandbox '$name' (--from $from; caps cpu=${_cpu} mem=${_mem}; ${extra[*]:-}); watchdog polls Phase=Ready (<= ${timeout_s}s, log: $(basename "$logf"))..."
  "$osh" sandbox create --name "$name" --from "$from" "${cap_args[@]}" "${extra[@]}" >"$logf" 2>&1 &
  local cpid=$! waited=0 phase=""
  while (( waited < timeout_s )); do
    # CLI returned on its own? Stop polling and trust the final phase read.
    if ! kill -0 "$cpid" 2>/dev/null; then wait "$cpid" 2>/dev/null || true; break; fi
    phase="$(openshell_sandbox_phase "$osh" "$name")"
    case "$phase" in
      Ready)        _osh_kill "$cpid"; ok "sandbox '$name' reached Ready (freed hung create CLI)"; _osh_harden_container "$name"; return 0 ;;
      Error|Failed) _osh_kill "$cpid"; warn "sandbox '$name' entered Phase=$phase (see $logf)"; return 1 ;;
    esac
    sleep 3; waited=$((waited+3))
  done
  phase="$(openshell_sandbox_phase "$osh" "$name")"
  _osh_kill "$cpid"
  case "$phase" in
    Ready)        ok "sandbox '$name' Ready"; _osh_harden_container "$name"; return 0 ;;
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
  if [[ "$phase" == "Ready" ]]; then
    # Phase=Ready is CONTROL-PLANE only: a sandbox whose short-lived gateway token
    # EXPIRED still reports Ready while its exec relay is dead (every exec times
    # out "relay open timed out"). Detect that via the in-container LOG signature
    # (reliable + NON-INVASIVE) — NOT an exec probe, which is fragile under
    # CLI/gateway version skew + contention and can degrade the gateway. The token
    # can't self-refresh, so recreate to mint a fresh one (re-running the phase
    # reconstitutes in-sandbox state). On a clean Ready, trust it.
    if openshell_token_storm "$name"; then
      # H3/H6 — the 1h token can't self-refresh via the CLI; recreate mints a fresh
      # one. The delete discards in-sandbox state, so CHECKPOINT FIRST and FAIL-CLOSED:
      # if the snapshot can't be taken+verified, REFUSE to delete (a lingering sandbox
      # is recoverable; a deleted-without-backup one is not). Restore later via
      # bin/openshell-state-restore.sh. (Reframed from the old 'discards state — by design'.)
      warn "sandbox '$name' reports Ready but its gateway token EXPIRED — checkpointing state, then recreating to mint a fresh token"
      local _ck_rc=0
      bash "$AI_STACK/bin/openshell-checkpoint.sh" "$name" storm >/dev/null || _ck_rc=$?
      if (( _ck_rc == 2 )); then
        err "REFUSING to recreate '$name': pre-delete checkpoint FAILED (would lose in-sandbox state). Free disk / fix docker, then re-run. Manual reclaim: docker cp openshell-${name}-*:/sandbox ./reclaimed/"
        return 1
      fi
      openshell_sandbox_delete "$osh" "$name"
    else
      ok "sandbox '$name' already Ready"; return 0
    fi
  elif [[ -n "$phase" ]]; then
    # H3 — a pre-existing non-Ready sandbox may still hold real state; checkpoint
    # best-effort before deleting (don't hard-block recovery of an already-broken
    # sandbox, but capture whatever is there).
    warn "sandbox '$name' present in Phase=$phase; checkpointing (best-effort) then deleting before recreate"
    bash "$AI_STACK/bin/openshell-checkpoint.sh" "$name" recreate-nonready >/dev/null || true
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
