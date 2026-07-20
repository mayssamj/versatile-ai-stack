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
# Shared, side-effect-free token-storm detector (StartedAt-gated; the ONE source of
# truth shared with bin/openshell-watchdog.sh + doctor check 39 so the signatures can
# never drift). Functions-only, safe to source unconditionally.
source "$AI_STACK/installer/lib/storm-detect.sh"

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

# openshell_token_storm <name> — true (0) iff sandbox <name>'s container shows the
# expired-token storm signature in logs emitted AFTER its last restart. Thin wrapper
# over the shared, StartedAt-gated detector in installer/lib/storm-detect.sh (one
# source of truth with bin/openshell-watchdog.sh::_is_storming + doctor check 39).
#
# The legacy inline `docker logs --since 3m` grep counted PRE-restart signatures too:
# docker retains logs across `docker restart`, so for ~3 min after a heal (re-mint +
# restart) it returned a FALSE storm on an already-healed sandbox (a co-cause of the
# 2026-06-30 install-04f failure). storm_detect clamps the window to
# max(StartedAt, now-180s) so that can't happen, and matches all three signatures
# (ExpiredSignature | RefreshSandboxToken…Unauthenticated | >=8 reconnect lines).
#
# Returns 1 when docker / the container is absent. NOTE: storm_detect rc 2 (UNKNOWN:
# a wedged-docker log-read timeout) is mapped to 1 here to preserve the boolean
# contract of existing callers; threading UNKNOWN→defer through ensure/precheck is the
# tracked G9 follow-up. NB: the in-place host re-mint (_osh_revive) is the
# NON-destructive cure — recreation is NOT required to clear a storm.
openshell_token_storm() {
  local name="$1" docker_bin cid rc=0
  docker_bin="$(command -v docker 2>/dev/null || true)"
  [[ -n "$docker_bin" ]] || return 1
  cid="$("$docker_bin" ps -q --filter "name=openshell-${name}-" 2>/dev/null | head -1)"
  [[ -n "$cid" ]] || return 1
  # storm_confirmed (NOT raw storm_detect): corroborates an ambiguous reconnect-flood against
  # real token expiry, so a Nessus/CrowdStrike scan flap on a VALID token can't fake a storm here
  # (CR-4). Falls back to storm_detect if the corroborating layer isn't sourced.
  if declare -F storm_confirmed >/dev/null 2>&1; then storm_confirmed "$docker_bin" "$cid" || rc=$?
  else storm_detect "$docker_bin" "$cid" || rc=$?; fi
  # Explicit return (NOT a bare `(( rc == 0 ))` whose set -e side-effect is the result) so a
  # future non-conditional caller can't be killed by set -e. rc 2 (UNKNOWN) maps to 1.
  [[ $rc -eq 0 ]] && return 0 || return 1
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
  # H1 — native, gateway-honored resource caps + labels at create time. Caps BOUND a
  # token-expiry storm so it can never starve the host again (incident 2026-06-08: two
  # UNCAPPED sandboxes pegged the host into a hard reboot). Verified live: the gateway
  # honors --cpu/--memory on the container (NanoCpus/Memory set). NOTE: it does NOT
  # propagate --label to the docker CONTAINER (only openshell.ai/* labels land there),
  # so container-level `docker container prune` is guarded instead by H5 restart=no +
  # the doctor stopped-sandbox warning; the keep label DOES protect checkpoint/forensic
  # IMAGES (set via docker commit -c). Set OPENSHELL_SANDBOX_CPU=0 / _MEM=0 to omit a cap.
  # These are TOP-LEVEL `sandbox create` flags and MUST precede "${extra[@]}" (post-`--`
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

# --- non-destructive REVIVE ("fix it, don't recreate it") ---------------------
# _osh_find <path...> — first executable candidate (else "").
_osh_find() { local p; for p in "$@"; do [[ -x "$p" ]] && { printf '%s' "$p"; return 0; }; done; command -v "$(basename "${1:-x}")" 2>/dev/null || true; }

# _osh_bounded <secs> <cmd...> — run cmd with a hard time budget (macOS has no `timeout`).
# Returns the cmd's rc, or 124 on timeout. Used to probe a daemon that may HANG under host
# memory pressure (NEVER `docker stats` — it hangs hardest exactly then).
_osh_bounded() {
  local secs="$1" p w=0; shift
  "$@" & p=$!
  while (( w < secs*2 )); do kill -0 "$p" 2>/dev/null || { wait "$p" 2>/dev/null; return $?; }; sleep 0.5; w=$((w+1)); done
  _osh_kill "$p"; return 124
}

# _osh_token_path <name> — echo the sandbox.jwt path of the EXISTING container (rc 1 if none).
_osh_token_path() {
  local name="$1" docker_bin cid uuid base m found=()
  docker_bin="$(command -v docker 2>/dev/null || true)"; [[ -n "$docker_bin" ]] || return 1
  cid="$("$docker_bin" ps -aq --filter "name=openshell-${name}-" 2>/dev/null | head -1)"
  [[ -n "$cid" ]] || return 1
  uuid="$("$docker_bin" inspect "$cid" --format '{{.Name}}' 2>/dev/null | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  [[ -n "$uuid" ]] || return 1
  # G5: locate by UUID (unique across gateways), NOT the hardcoded /default/ slug. Phase 04
  # adopts a gateway of ANY name; pinning /default/ made the token unfindable under a
  # non-default gateway, so re-mint silently no-op'd and the "heal" degraded to a
  # restart-only that can't refresh an expired token. Match exactly one; >1 (impossible for
  # a unique UUID) -> fail-explicit rather than pick one silently.
  base="$HOME/.local/state/openshell/docker-sandbox-tokens"
  for m in "$base"/*/"$uuid"/sandbox.jwt; do [[ -f "$m" ]] && found+=("$m"); done
  (( ${#found[@]} == 1 )) || return 1
  printf '%s' "${found[0]}"
}

# _osh_relaunch_gateway <name> <cid> — G4: a `docker restart` in _osh_revive kills the
# in-sandbox `hermes gateway run` process, so an install-path revive otherwise leaves the
# bot DARK until the watchdog's next W2 cycle. Restore it directly via `docker exec -d`
# (NOT the openshell relay, which hangs under the very thrash a storm coincides with).
# Name-scoped to the gateway-bearing sandbox (pi-v1 has none); `--replace` keeps it
# idempotent (converges with Phase 20 / the watchdog). Bounded + best-effort + NON-fatal:
# a relaunch hiccup must never fail an otherwise-successful revive (W2 retries next cycle).
_osh_relaunch_gateway() {
  local name="$1" cid="$2" docker_bin
  [[ "$name" == "hermes-fleet-v1" ]] || return 0
  docker_bin="$(command -v docker 2>/dev/null || true)"
  [[ -n "$docker_bin" && -n "$cid" ]] || return 0
  if _osh_bounded 15 "$docker_bin" exec -d "$cid" sh -c \
       'export HOME=/sandbox; cd /sandbox; nohup /sandbox/.venv/bin/hermes gateway run --replace >/sandbox/.hermes-gateway.log 2>&1'; then
    log "  revive '$name': requested hermes gateway relaunch (exec -d accepted; W2 supervises real liveness next cycle)"
  else
    warn "  revive '$name': gateway relaunch returned non-zero (watchdog W2 retries next cycle)"
  fi
  return 0
}

# _osh_revive <OSH> <name> — NON-DESTRUCTIVE recovery of an EXISTING sandbox container:
# re-mint the expired gateway token IN PLACE + docker start/restart the SAME container +
# poll for Phase=Ready. NEVER deletes, NEVER recreates — /sandbox + the running agents are
# preserved. Returns 0 iff Ready afterward. (The watchdog's proven 2026-06-19 heal, wired
# into install/ensure so the install path stops being destructive.)
_osh_revive() {
  local osh="$1" name="$2" docker_bin cid status mint py ossl tok i
  docker_bin="$(command -v docker 2>/dev/null || true)"
  [[ -n "$docker_bin" ]] || { err "revive '$name': docker not found"; return 1; }
  cid="$("$docker_bin" ps -aq --filter "name=openshell-${name}-" 2>/dev/null | head -1)"
  [[ -n "$cid" ]] || return 1   # no container -> caller decides (create / fail-explicit)
  # F5 daemon-health gate: bounded probe. If the daemon is wedged under memory pressure,
  # don't hang — let the caller fail-explicit.
  if ! _osh_bounded 8 "$docker_bin" version >/dev/null 2>&1; then
    warn "revive '$name': Docker daemon not responding within 8s (host memory pressure?)"; return 1
  fi
  # Re-mint the token in place (proven non-destructive cure for the expired-token storm).
  mint="$AI_STACK/bin/openshell-jwt-mint.py"
  py="$(command -v python3 2>/dev/null || true)"
  ossl="$(_osh_find /opt/homebrew/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl /usr/bin/openssl)"
  # OpenSSL 3.x is REQUIRED to sign the gateway's PKCS#8-v2 Ed25519 key; macOS LibreSSL cannot.
  # If only LibreSSL resolves, re-mint can't work — say so LOUDLY (don't fail silently into a
  # guaranteed revive failure with a misleading message) and skip the mint.
  if [[ -n "$ossl" ]] && "$ossl" version 2>/dev/null | grep -qi 'libressl'; then
    warn "revive '$name': resolved OpenSSL is LibreSSL ('$ossl') — it CANNOT sign the gateway key; token re-mint SKIPPED. Install OpenSSL 3.x:  brew install openssl@3"
    ossl=""
  fi
  tok="$(_osh_token_path "$name" 2>/dev/null || true)"
  local minted=0
  if [[ -n "$tok" && -f "$mint" && -n "$py" && -n "$ossl" ]]; then
    if OPENSSL_BIN="$ossl" "$py" "$mint" --token "$tok" --write >/dev/null 2>&1; then
      minted=1; log "  revive '$name': re-minted gateway token in place (original + .bak intact)"
    else
      warn "  revive '$name': token re-mint FAILED"
    fi
  else
    log "  revive '$name': minter/openssl/token unavailable — cannot re-mint"
  fi
  # G6: if NO fresh token was written AND the existing token is CONFIRMED expired, a docker
  # restart would just re-read the SAME expired token and immediately re-storm — so refuse to
  # restart and fail-explicit (caller leaves the container as-is for diagnosis). Block ONLY on
  # a confirmed expiry (--exp-only DECODES the token, no openssl, so it works on a LibreSSL
  # host); an INDETERMINATE check (no python3 / decode fails) falls through to restart-anyway
  # (today's behavior — never a NEW hard block).
  if (( minted == 0 )) && [[ -n "$tok" && -f "$mint" && -n "$py" ]]; then
    local _left
    _left="$("$py" "$mint" --token "$tok" --exp-only 2>/dev/null || echo)"
    if [[ "$_left" =~ ^-?[0-9]+$ ]] && (( _left <= 0 )); then
      err "  revive '$name': token EXPIRED (${_left}s) and could NOT be re-minted — refusing to restart"
      err "  (a restart would re-read the expired token and immediately re-storm). Fix: brew install openssl@3"
      return 1
    fi
  fi
  status="$("$docker_bin" inspect "$cid" --format '{{.State.Status}}' 2>/dev/null || echo)"
  if [[ "$status" == "running" ]]; then
    "$docker_bin" restart "$cid" >/dev/null 2>&1 || { err "revive '$name': docker restart failed"; return 1; }
  else
    "$docker_bin" start "$cid" >/dev/null 2>&1 || { err "revive '$name': docker start failed"; return 1; }
  fi
  # Poll for Ready, but BOUND each `sandbox get` — the relay CLI can HANG under memory pressure
  # (the pathology openshell_sandbox_create_watchdog already guards against).
  for i in 1 2 3 4 5 6 7 8; do
    if [[ "$(_osh_bounded 12 "$osh" sandbox get "$name" 2>/dev/null | _osh_strip_ansi | awk '/^[[:space:]]*Phase:[[:space:]]*/{print $2; exit}')" == "Ready" ]]; then
      _osh_relaunch_gateway "$name" "$cid"   # G4: the docker restart above killed the in-sandbox gateway PROCESS
      return 0
    fi
    sleep 4
  done
  return 1
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

  local force_recreate="${OPENSHELL_FORCE_RECREATE:-0}"
  local failmark="$AI_STACK/installer/state/openshell-watchdog.alert"   # surfaced by doctor check 43
  local docker_bin cid
  docker_bin="$(command -v docker 2>/dev/null || true)"
  cid=""; [[ -n "$docker_bin" ]] && cid="$("$docker_bin" ps -aq --filter "name=openshell-${name}-" 2>/dev/null | head -1)" || true
  phase="$(openshell_sandbox_phase "$osh" "$name")"

  # ===== CONTRACT: install/ensure is IDEMPOTENT + NON-DESTRUCTIVE. =====
  # A sandbox that EXISTS is NEVER deleted+recreated automatically — recreation destroys the
  # running agents; /sandbox lives in the container's WRITABLE LAYER (no volume — it survives
  # stop/start of the SAME container, and delete only via a checkpoint image). We REVIVE the
  # same container; if it
  # can't be revived we FAIL EXPLICITLY and LEAVE IT AS-IS for diagnosis. Destructive recreate
  # is opt-in ONLY (OPENSHELL_FORCE_RECREATE=1). Create happens ONLY when no container exists.

  # ---- A sandbox CONTAINER exists -> REVIVE, or FAIL EXPLICITLY ---------------
  if [[ -n "$cid" ]]; then
    if [[ "$force_recreate" == "1" ]]; then
      warn "OPENSHELL_FORCE_RECREATE=1 — EXPLICIT destructive recreate of '$name' (checkpoint-first, fail-closed)"
      local _ck=0; bash "$AI_STACK/bin/openshell-checkpoint.sh" "$name" force-recreate >/dev/null || _ck=$?
      if (( _ck == 2 )); then
        err "REFUSING to recreate '$name': pre-delete checkpoint FAILED (would lose /sandbox). Free disk / fix docker, then retry."
        return 1
      fi
      openshell_sandbox_delete "$osh" "$name"
      # fall through to CREATE below
    else
      # Already healthy? Ready + token valid is the codebase's non-invasive signal (an EXPIRED
      # token reports Ready but is relay-dead, so token_storm gates that into the revive path).
      if [[ "$phase" == "Ready" ]] && ! openshell_token_storm "$name"; then
        ok "sandbox '$name' already Ready"; return 0
      fi
      # Down / Error / storming / stopped -> REVIVE the SAME container. NEVER recreate.
      warn "sandbox '$name' exists but is not healthy (Phase=${phase:-down}) — reviving in place (re-mint + start/restart; NO recreate)"
      if _osh_revive "$osh" "$name"; then
        ok "sandbox '$name' REVIVED — same container, /sandbox + agents preserved (not recreated)"
        rm -f "$failmark" 2>/dev/null || true
        return 0
      fi
      # Revive failed -> FAIL EXPLICITLY and PRESERVE the container untouched for diagnosis.
      err "sandbox '$name' is present (Phase=${phase:-down}) but could NOT be revived — LEAVING IT AS-IS so its state/status is preserved for diagnosis (NOT deleting/recreating)."
      err "  Diagnose:  docker logs --tail 80 openshell-${name}-*  ;  $osh sandbox get $name"
      err "  After diagnosis, an EXPLICIT destructive recreate (checkpoint-first) is: OPENSHELL_FORCE_RECREATE=1 vz-ai-stack.sh install <phase>"
      printf '%s revive FAILED at %s — left intact for diagnosis (NOT recreated). Force a clean recreate: OPENSHELL_FORCE_RECREATE=1 install <phase>\n' \
        "$name" "$(date '+%F %T')" > "$failmark" 2>/dev/null || true
      return 1
    fi
  elif [[ -n "$phase" ]]; then
    # Registry record but NO container (pruned/lost) -> nothing to revive; /sandbox already gone.
    # Recreate is the only option and it's destructive -> opt-in only.
    if [[ "$force_recreate" != "1" ]]; then
      err "sandbox '$name' has a registry record (Phase=$phase) but its CONTAINER is GONE — cannot revive (its /sandbox is already lost)."
      err "  Recreate is destructive and opt-in: OPENSHELL_FORCE_RECREATE=1 vz-ai-stack.sh install <phase>"
      return 1
    fi
    warn "OPENSHELL_FORCE_RECREATE=1 — clearing the stale registry record for '$name' before create"
    openshell_sandbox_delete "$osh" "$name"
  fi

  # ---- No sandbox container -> first-time CREATE (the ONLY auto-create path) --
  openshell_sandbox_create_watchdog "$osh" "$name" "$from" "$create_timeout" -- "${extra[@]}"; rc=$?
  [[ $rc -eq 0 ]] && return 0
  # A failed create can leave a partial gateway REGISTRY RECORD (+ a stopped container) that
  # makes the retry's `create --name <same>` fail "already exists". Clear OUR OWN failed-create
  # artifact before retrying — safe: this arm is reached ONLY when no container/record pre-existed
  # (an existing sandbox went down the non-destructive revive path, never here).
  warn "create of '$name' failed (rc=$rc) — clearing the failed-create artifact + retrying once"
  openshell_sandbox_delete "$osh" "$name"
  openshell_sandbox_create_watchdog "$osh" "$name" "$from" "$create_timeout" -- "${extra[@]}"; rc=$?
  [[ $rc -eq 0 ]] && return 0

  # Escalate to a gateway restart ONLY if it won't harm another healthy sandbox (H10).
  if [[ "$allow_restart" == "1" ]] && command -v brew >/dev/null 2>&1; then
    local _others
    _others="$("$osh" sandbox list 2>/dev/null | _osh_strip_ansi | awk -v n="$name" 'NR>1 && $1!=n && $NF=="Ready"{print $1}' | tr '\n' ' ')"
    if [[ -n "${_others// }" && "${OPENSHELL_FORCE_GATEWAY_RESTART:-0}" != "1" ]]; then
      warn "Tier-3 gateway restart SKIPPED: other healthy sandbox(es) present [${_others% }] — a restart errors them ALL. Set OPENSHELL_FORCE_GATEWAY_RESTART=1 to override."
    else
      [[ -x "$AI_STACK/bin/openshell-identity-backup.sh" ]] && bash "$AI_STACK/bin/openshell-identity-backup.sh" backup >/dev/null 2>&1 || true
      warn "escalating: 'brew services restart openshell' then create"
      brew services restart openshell >/dev/null 2>&1 || true
      local i=0; while (( i < 60 )); do port_listening 17670 && break; sleep 1; i=$((i+1)); done
      openshell_sandbox_delete "$osh" "$name"
      openshell_sandbox_create_watchdog "$osh" "$name" "$from" "$create_timeout" -- "${extra[@]}"; rc=$?
      [[ $rc -eq 0 ]] && return 0
    fi
  fi

  err "sandbox '$name' could not be created"
  return 1
}
