#!/usr/bin/env bash
# openshell-watchdog.sh — auto-heal the OpenShell sandbox "expired-token storm".
#
# THE FAILURE (seen twice): an OpenShell sandbox's short-lived gateway token
# expires (~1h uptime — NOT ~8h; corrected 2026-06-19). The in-sandbox agent then
# retries its log-push / inference-route gRPC with NO backoff — hundreds of
# reconnects/second ("invalid token: ExpiredSignature", "log push stream lost,
# reconnecting") — pegging ~36% CPU per sandbox, and the container restart-loops.
# A gateway restart does NOT refresh the token. RECREATING mints a fresh one but
# DESTROYS /sandbox; the NON-destructive cure is an in-place host RE-MINT — the host
# holds the gateway Ed25519 key and the gateway validates statelessly (no jti),
# verified 2026-06-19. See the REMINT path (bin/openshell-jwt-mint.py) below.
#
# THIS WATCHDOG (run every few minutes by launchd):
#   1. For each OpenShell sandbox, detect the storm by its UNAMBIGUOUS signature
#      (ExpiredSignature / reconnect-storm in recent logs, or a climbing
#      RestartCount). That signature means the sandbox is already DEAD, so acting
#      on it loses nothing — it won't false-fire on a legitimately busy sandbox.
#   2. On detection (DEFAULT = WARN-ONLY, data-safe): log + desktop-notify + write
#      a RED marker (surfaced by doctor check 43). It does NOT delete the sandbox —
#      deletion is destructive (loses in-sandbox runtime state), so recreation is a
#      deliberate human action: `vz-ai-stack.sh install <phases>`.
#   3. GENERIC net: any MANAGED container pegged >CPU_WARN over two samples gets
#      logged as a runaway (surfaced for `doctor`).
#
# WHY warn-only (2026-06-03): the previous version auto-deleted then rebuilt, but the
# rebuild ran under launchd's PATH (no OrbStack docker) and ALWAYS failed — destroying
# BOTH sandboxes and logging a false "done". Now destruction never happens on its own.
#
# Opt-in AI_STACK_WATCHDOG_RECREATE=1: auto-recreate, but only after verifying the
# rebuild can run (docker+openshell reachable); recreates, verifies Ready, and fails
# LOUD (RED marker + notify) — never a silent destroy-without-rebuild.
# Opt-in AI_STACK_WATCHDOG_HALT=1: `docker stop` the storming container (non-destructive,
# sandbox record preserved) to cut the CPU burn while you decide.
#
# SLEEP-COVERAGE CAVEAT (G14): launchd `StartInterval` timers are SUSPENDED while the Mac
# sleeps, and `RunAtLoad` fires only at boot/login (NOT on wake). So the PROACTIVE re-mint
# (last REMINT_THRESHOLD secs of the 1h TTL) can be slept straight through, and on wake the
# token may already be expired with a window before the first post-wake cycle re-mints. That
# residual window is covered by (a) the install paths now self-healing in place
# (installer/lib/openshell.sh::openshell_sandbox_ensure, called by Phase 04/04f/15) and
# (b) the daemon-health-gated reactive heal below. An opt-in wake-observer LaunchAgent that
# fires one cycle on wake is a possible future hardening (needs operator sign-off — it adds a
# resident agent).
set -Eeuo pipefail

AI_STACK="${AI_STACK:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# Shared, side-effect-free token-storm detector — one source of truth with the
# installer (installer/lib/openshell.sh) + doctor check 39, so _is_storming below can
# never drift from the installer's detector again (the divergence that let a low-CPU
# RefreshSandboxToken storm fail every install while the watchdog reported healthy).
# Functions-only; safe to source before the tool-resolution below.
[[ -f "$AI_STACK/installer/lib/storm-detect.sh" ]] && source "$AI_STACK/installer/lib/storm-detect.sh"
STATE="$AI_STACK/installer/state"
LOG="$STATE/openshell-watchdog.log"
LOCK="$STATE/openshell-watchdog.lock"
INSTALL_LOCK="$STATE/.lock"               # vz-ai-stack.sh's lock dir
THROTTLE_FILE="$STATE/openshell-watchdog.last"
THROTTLE_SECS="${AI_STACK_WATCHDOG_THROTTLE:-1800}"   # don't recreate the same thing more than once / 30min
CPU_WARN="${AI_STACK_WATCHDOG_CPU_WARN:-85}"          # generic runaway threshold (%)
# SAFETY (2026-06-03 + 2026-06-08 incidents):
#  • NEVER auto-DELETE by default — deletion is destructive (loses in-sandbox state).
#    Auto-recreate (delete+rebuild, capability-checked, Ready-verified, CHECKPOINT-FIRST,
#    fails LOUD) stays OPT-IN via AI_STACK_WATCHDOG_RECREATE=1.
#  • HALT-BY-DEFAULT (2026-06-08): a detected storm is on an already-DEAD sandbox, so a
#    cgroup cap + `docker stop` loses NOTHING and is reversible (docker start) — whereas
#    a host hang requiring a hard reboot is NOT. When warn-only, the overnight storm
#    pegged the host into a forced reboot. So on a storm we now CAP cpu/mem then stop the
#    container to kill the CPU burn immediately. Set AI_STACK_WATCHDOG_HALT=0 to revert.
# STICKY auto-heal mode (regression fix 2026-06-27): a prior `install` persists the
# operator's chosen modes to installer/state/watchdog.conf. A BARE `install` (Phase 04's
# call, or the manual heal `install <phase>`) MUST NOT silently reset REMINT/PERSIST to the
# committed defaults — that reset is exactly what disabled auto-heal and caused the recurring
# "sandboxes down + stay down". So inherit any sticky mode whose env var is NOT explicitly
# set (an explicit env var still wins). The `install` subcommand writes the effective modes back.
CONF="$STATE/watchdog.conf"
if [[ -f "$CONF" ]]; then
  # `|| true` + trailing `return 0`: a key ABSENT from watchdog.conf makes grep exit 1 →
  # under `set -Eeuo pipefail` the `v=$(...)` assignment would fail and KILL the cycle before
  # any logging (silent exit 1). That bites every NEW key on an older conf (e.g. REVIVE_EXITED/
  # CRASHLOOP_BREAK on a conf written before they existed). Absent key = inherit nothing, return ok.
  _wd_inherit() { local n="$1" v; [[ -n "${!n+x}" ]] && return 0; v="$(grep -E "^$n=" "$CONF" 2>/dev/null | tail -1 | cut -d= -f2- || true)"; [[ -n "$v" ]] && export "$n=$v"; return 0; }
  _wd_inherit AI_STACK_WATCHDOG_REMINT
  _wd_inherit AI_STACK_SANDBOX_PERSIST
  _wd_inherit AI_STACK_WATCHDOG_RECREATE
  _wd_inherit AI_STACK_WATCHDOG_HALT
  _wd_inherit AI_STACK_WATCHDOG_GATEWAY_SUPERVISE
  _wd_inherit AI_STACK_WATCHDOG_REVIVE_EXITED
  _wd_inherit AI_STACK_WATCHDOG_CRASHLOOP_BREAK
  _wd_inherit AI_STACK_WATCHDOG_CONFIG_HEAL
fi
RECREATE="${AI_STACK_WATCHDOG_RECREATE:-0}"
HALT="${AI_STACK_WATCHDOG_HALT:-1}"
FAILMARK="$STATE/openshell-watchdog.alert"            # RED marker → doctor check 43
# Managed sandbox set; override via AI_STACK_WATCHDOG_SANDBOXES="a b c" (testing / extra sandboxes).
read -ra SANDBOXES <<< "${AI_STACK_WATCHDOG_SANDBOXES:-hermes-fleet-v1 pi-v1}"

# --- Persistence via in-place token RE-MINT (opt-in; added 2026-06-19) --------
# The expired-token storm's only non-destructive cure is a fresh token. Recreate
# mints one but DESTROYS /sandbox; verified 2026-06-19 that the gateway validates
# statelessly (no jti) so a host-minted token mirroring the claims with a fresh exp
# is ACCEPTED — letting us refresh the SAME sandbox in place (bin/openshell-jwt-mint.py).
#   REMINT=1   → heal a storm by re-minting (+restart) instead of halt/recreate, AND
#                proactively re-mint BEFORE expiry so the storm never starts.
#   PERSIST=1  → managed sandboxes are long-lived: restart=unless-stopped (survive a
#                docker/system restart — safe now: capped + the watchdog re-mints any
#                post-restart storm within one cycle) + the timer runs at boot (RunAtLoad).
# Both default OFF (shared-repo safety); `install` bakes the chosen values into the plist.
REMINT="${AI_STACK_WATCHDOG_REMINT:-0}"
PERSIST="${AI_STACK_SANDBOX_PERSIST:-0}"
REMINT_THRESHOLD="${AI_STACK_WATCHDOG_REMINT_THRESHOLD:-900}"   # proactively re-mint when < N s to expiry
# NOTE: the two re-mint paths differ BY DESIGN — proactive (pre-expiry) rewrites the
# token file with NO restart (best-effort, zero-blip); reactive (storm detected) always
# re-mints + docker restart (the PROVEN heal). There is intentionally no restart toggle.
MINT="$AI_STACK/bin/openshell-jwt-mint.py"
TOKDIR="$HOME/.local/state/openshell/docker-sandbox-tokens/default"

mkdir -p "$STATE"
# Resolve tools (launchd has a minimal PATH).
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
OPENSHELL="$(_find /opt/homebrew/bin/openshell /usr/local/bin/openshell)"
BREW="$(_find /opt/homebrew/bin/brew /usr/local/bin/brew)"
# For in-place re-mint: python3 (stdlib only — the minter shells to openssl) + an
# OpenSSL 3.x that can sign the PKCS#8-v2 Ed25519 key (macOS LibreSSL may not).
PYTHON3="$(_find /usr/bin/python3 /opt/homebrew/bin/python3)"
OPENSSL="$(_find /opt/homebrew/opt/openssl@3/bin/openssl /opt/homebrew/bin/openssl /usr/bin/openssl)"
# This script uses bash 4+ (associative arrays). macOS system /bin/bash is 3.2, so the
# launchd plist must invoke a bash 4+ (brew). Fall back to /bin/bash only if none found
# (the generic-net is then version-guarded so it still won't crash).
BASH4="$(_find /opt/homebrew/bin/bash /usr/local/bin/bash)"

log() { printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"; }
notify() { /usr/bin/osascript -e "display notification \"$1\" with title \"ai-stack watchdog\"" >/dev/null 2>&1 || true; }

# --- W3 thrash-hardening: bounded exec (macOS has NO `timeout`/`gtimeout` here) --
# Run a command with a hard wall-clock budget; return its rc, or 124 on timeout.
# Mirrors installer/lib/openshell.sh::_osh_bounded so the watchdog never WEDGES on a
# `docker logs`/`exec` that hangs under host memory pressure (the exact condition the
# heal path must survive). The 600s stale-lock reclaim is the only other backstop, so
# every per-cycle docker call that can hang under thrash MUST go through this.
_wd_bounded() {
  local s="$1" p w=0; shift
  "$@" & p=$!
  while (( w < s*2 )); do kill -0 "$p" 2>/dev/null || { wait "$p" 2>/dev/null; return $?; }; sleep 0.5; w=$((w+1)); done
  kill -TERM "$p" 2>/dev/null; sleep 1; kill -KILL "$p" 2>/dev/null || true; wait "$p" 2>/dev/null || true; return 124
}

# --- W2 gateway-liveness supervision (default ON; AI_STACK_WATCHDOG_GATEWAY_SUPERVISE=0 off) ---
# The hermes gateway is a PROCESS inside the hermes-fleet-v1 sandbox. A container
# restart (reboot / docker restart) or a process crash leaves it DOWN, and today
# the ONLY relaunch path is the token-storm heal (handle_storm -> phase 20) — so a
# clean reboot with no storm revives the CONTAINER (restart=unless-stopped) but the
# bot stays dark. W2 makes liveness DETERMINISTIC + idempotent regardless of any
# ad-hoc path: each cycle, if the sandbox is up but `hermes gateway run` is absent,
# relaunch it. Relaunch goes through `docker exec` (NOT the openshell relay, which
# HANGS under the very thrash this must survive), detached (`exec -d`), idempotent
# (`--replace` ends with exactly one). Rate-limited by the 180s launchd cycle (no tight
# loop), and SKIPPED when a heal already relaunched it this cycle (gated on storming==0 —
# avoids racing handle_storm's relaunch, where two concurrent `--replace` cycle-kill).
W2_SUPERVISE="${AI_STACK_WATCHDOG_GATEWAY_SUPERVISE:-1}"
HERMES_GW_LOG_IN="/sandbox/.hermes-gateway.log"   # in-sandbox gateway log (matches installer/lib/hermes.sh)
_gateway_alive() {  # _gateway_alive <cid> -> 0 iff `hermes gateway run` is running in the sandbox
  local cid="$1"
  _wd_bounded 12 "$DOCKER" exec "$cid" sh -c "ps -eo args 2>/dev/null | grep -q '[h]ermes gateway run'"
}
_gateway_relaunch() {  # _gateway_relaunch <cid> <name> -> relaunch the gateway detached (idempotent)
  local cid="$1" name="$2"
  # exec -d returns immediately (no '& disown' foreground-hang); hermes reads its config
  # from /sandbox/.hermes on start, so a bare relaunch is sufficient (no full phase re-run).
  # BOUNDED (review B1): even `exec -d` blocks until the daemon DISPATCHES it, which can hang
  # under the very thrash this heals — never let a relaunch wedge the cycle (the only other
  # backstop is the 600s stale-lock reclaim = the watchdog dark for 10 min).
  if _wd_bounded 15 "$DOCKER" exec -d "$cid" sh -c "export HOME=/sandbox; cd /sandbox; nohup /sandbox/.venv/bin/hermes gateway run --replace >$HERMES_GW_LOG_IN 2>&1" >>"$LOG" 2>&1; then
    log "  W2: relaunched hermes gateway in $name (docker exec -d, --replace)"; return 0
  fi
  # Persistent relaunch failure (broken binary / corrupt config / wedged daemon): make it
  # OPERATOR-VISIBLE, not just a log line (review N2) — desktop notify each failure.
  log "  W2: gateway relaunch in $name returned non-zero (timeout/error) — re-checked next cycle"
  notify "hermes gateway relaunch FAILED in $name — check: $AI_STACK/installer/state/openshell-watchdog.log"
  return 1
}

# --- W5: gateway-CONFIG durability (default ON; AI_STACK_WATCHDOG_CONFIG_HEAL=0 off) ----------
# The COMPLETE gateway config (model/provider/fallback + Slack allowlist/home-channel) lives in the
# sandbox's EPHEMERAL /sandbox/.hermes/config.yaml. A sandbox recreate, or a relay-hang during
# Phase 04f's `hermes config set`, can GUT it (seen 2026-06-29: a 2-line config — no model/provider
# → the bot can't infer AND Slack auth breaks at once; Telegram survived only because its line did).
# Self-maintain a HOST snapshot: a PROMOTABLE (healthy CLOUD) live config → refresh the snapshot; a
# GUTTED (truncated) live config → restore from the snapshot + relaunch. The promote/restore gates
# differ on purpose (see _config_* below): never snapshot a local-gated config (a later restore would
# load a local model + OOM the box) and never clobber a large schema-restructure. Non-destructive (the
# snapshot is a copy). Uses docker, NOT the openshell relay (which HANGS under the very thrash that guts).
CONFIG_HEAL="${AI_STACK_WATCHDOG_CONFIG_HEAL:-1}"
GW_CONFIG_SNAP="$STATE/hermes-gateway-config.snapshot.yaml"
GW_CONFIG_IN="/sandbox/.hermes/config.yaml"
# Restore-TRIGGER vs snapshot-PROMOTE use DIFFERENT gates (council B2/W4). KEEP byte-identical with
# installer/lib/hermes.sh::hermes_gw_config_{complete,gutted,promotable}.
#   complete   = has top-level model+provider (the inference keys a gut loses).
#   gutted     = NOT complete AND tiny (<=7 lines) — a TRUE truncation (the 2-line 19:32 gut), NOT a
#                large schema-restructure (clobbering that would roll back a healthy Hermes upgrade).
#   promotable = complete AND default model is CLOUD (not local-*) — snapshotting a local-gated config
#                would later RESTORE it -> load a local model -> OOM the box (the no-local directive).
_config_complete()   { grep -qE '^model:' <<<"${1:-}" && grep -qE '^providers:' <<<"${1:-}"; }
_config_gutted()     { [[ -n "${1:-}" ]] && ! _config_complete "${1:-}" && (( $(grep -c '' <<<"${1:-}") <= 7 )); }
_config_promotable() { _config_complete "${1:-}" && ! grep -qE '^[[:space:]]*default:[[:space:]]*local(-[a-z0-9]+)?[[:space:]]*$' <<<"${1:-}"; }
_gateway_config_heal() {  # <cid> <name> -> rc 0 ONLY if it RESTORED a gutted config + relaunched
  local cid="$1" name="$2" live
  live="$(_wd_bounded 10 "$DOCKER" exec "$cid" sh -c "cat $GW_CONFIG_IN 2>/dev/null" || true)"
  # PROMOTE: refresh the host snapshot ONLY from a healthy CLOUD config (0600 — it holds the scoped key).
  if _config_promotable "$live"; then
    # CA-4 (Netwrix DLP): this 0600 snapshot holds the scoped cloud key — a DLP agent can quarantine
    # the write. Don't swallow it: a silently-failed snapshot means the W5 RESTORE safety net is GONE,
    # so a later config-gut goes UN-healed despite W5 being "on". Surface the block.
    if { printf '%s' "$live" > "$GW_CONFIG_SNAP.tmp" && chmod 600 "$GW_CONFIG_SNAP.tmp" && mv -f "$GW_CONFIG_SNAP.tmp" "$GW_CONFIG_SNAP"; } 2>>"$LOG"; then
      :
    else
      rm -f "$GW_CONFIG_SNAP.tmp" 2>/dev/null || true
      log "W5: $name gateway-config snapshot WRITE FAILED (DLP/Netwrix may have blocked the 0600 secret write) — the W5 restore safety net is UNAVAILABLE until this succeeds."
      notify "$name gateway-config snapshot blocked (DLP?) — W5 restore unavailable"
    fi
    return 1   # healthy live config — nothing to heal (snapshot refresh attempted)
  fi
  # RESTORE only a TRUE gut; leave a complete-but-local config OR a large restructure alone.
  _config_gutted "$live" || return 1
  if [[ ! -s "$GW_CONFIG_SNAP" ]] || ! _config_promotable "$(cat "$GW_CONFIG_SNAP" 2>/dev/null || true)"; then
    log "W5: $name gateway config is GUTTED (no model/provider) and no healthy (cloud) snapshot — heal: vz-ai-stack.sh install 04f"
    notify "$name gateway config gutted — no snapshot to restore (run install 04f)"
    return 1
  fi
  if _wd_bounded 15 "$DOCKER" cp "$GW_CONFIG_SNAP" "$cid:$GW_CONFIG_IN" >>"$LOG" 2>&1; then
    log "W5: $name gateway config was GUTTED — RESTORED from host snapshot, relaunching gateway"
    notify "$name gateway config restored from snapshot ✓"
    _gateway_relaunch "$cid" "$name" || log "W5: $name config restored but gateway relaunch FAILED — W2 retries next cycle"
    return 0
  fi
  log "W5: $name gateway config restore (docker cp) FAILED"
  return 1
}

# --- W4 revive-exited + W1 crash-loop breaker (both default ON; sticky via watchdog.conf) ---
W4_REVIVE="${AI_STACK_WATCHDOG_REVIVE_EXITED:-1}"          # docker-start a sandbox that died uncleanly (reboot/crash) and wasn't auto-restarted
CRASHLOOP_BREAK="${AI_STACK_WATCHDOG_CRASHLOOP_BREAK:-1}"  # restart=no + stop a NON-sandbox MANAGED container stuck restarting
CRASHLOOP_N="${AI_STACK_WATCHDOG_CRASHLOOP_N:-2}"          # >= this many restarts since last cycle (DELTA) = still actively looping. LOW BY DESIGN:
# Docker's exponential restart-backoff throttles a long-running looper to only a FEW restarts per 180s window (it reaches
# multi-second delays quickly), so a high N would MISS a steady-state loop — exactly the case W1 exists for (autofyn-agent
# crept to RestartCount=41 this way). The `status==restarting` gate below — not N — is the real false-positive guard.
CRASHCOUNT_FILE="$STATE/watchdog-restart-counts"          # per-cycle RestartCount snapshot for the W1 delta

# Per-name FAILMARK helpers — ALL writers (W1/W4 AND handle_storm) go through these so the
# alert file stays coherent: one line per container, no writer wipes another's alert. (Before,
# handle_storm's `>`/`rm -f` wiped W1/W4 lines — §24 review.) Literal prefix match via awk
# `index` (not ERE) so a container name containing a regex metachar (`.`) can't mis-filter.
_failmark_set() {  # replace <name>'s line (keep all others), append <line>
  local name="$1" line="$2"
  { awk -v n="$name " 'index($0,n)!=1' "$FAILMARK" 2>/dev/null || true; printf '%s\n' "$line"; } > "$FAILMARK.tmp" \
    && mv -f "$FAILMARK.tmp" "$FAILMARK" 2>/dev/null || true
}
_failmark_clear() {  # remove ONLY <name>'s line; delete the file if nothing else remains
  local name="$1"
  [[ -f "$FAILMARK" ]] || return 0
  awk -v n="$name " 'index($0,n)!=1' "$FAILMARK" 2>/dev/null > "$FAILMARK.tmp" || true
  if [[ -s "$FAILMARK.tmp" ]]; then mv -f "$FAILMARK.tmp" "$FAILMARK" 2>/dev/null || true
  else rm -f "$FAILMARK.tmp" "$FAILMARK" 2>/dev/null || true; fi
}

# --- W4: revive an EXITED managed sandbox ------------------------------------
# The loop SKIPS a sandbox with no RUNNING container, so one that died on reboot/crash and
# was NOT auto-restarted (PERSIST off, or Docker didn't restart it) stays DOWN forever. W4
# revives it — but only when it died UNCLEANLY, and never when the operator stopped it or a
# watchdog alert already halted it. `docker start` is NON-destructive (writable layer kept);
# a deleted-container sandbox is NOT auto-recreated (that destructive path stays a deliberate
# `install`). A revive that immediately re-fails is bounded by the throttle (and surfaced).
_w4_revive_exited() {
  local name="$1"
  [[ "$W4_REVIVE" == "1" ]] || return 0
  local cid; cid="$(_wd_bounded 10 "$DOCKER" ps -aq --filter "name=openshell-${name}-" 2>/dev/null | head -1 || true)"
  [[ -n "$cid" ]] || return 0      # no container at all = deleted sandbox; recreate is a deliberate `install`
  # ONE bounded inspect for everything (status|exitcode|oom|restart-policy) — never let an
  # unbounded inspect wedge the cycle under the very post-crash/reboot thrash W4 runs after (§24 SRE).
  local info st ec oom rp
  info="$(_wd_bounded 15 "$DOCKER" inspect -f '{{.State.Status}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.HostConfig.RestartPolicy.Name}}' "$cid" 2>/dev/null || true)"
  [[ -n "$info" ]] || return 0     # timeout / gone — re-checked next cycle
  IFS='|' read -r st ec oom rp <<< "$info"
  # KNOWN GAP (deliberate, §24 architect): a sandbox stuck "restarting" for a NON-token reason
  # (corrupt /sandbox, bad mount, repeated OOM under unless-stopped) is healed by NO path — storm
  # needs the token signature, W1 excludes openshell-*, and auto-breaking a sandbox restart-loop
  # risks a false positive on a legit transient. Healing is intentionally left to Docker's policy.
  # (Follow-up: a surface-only delta+notify like W1's, to make it visible for pi-v1 which has no gateway.)
  [[ "$st" == "exited" ]] || return 0   # restarting=Docker handling it; created/paused/dead not our revive case
  # Guard 1: a watchdog ALERT names it (storm-halt / W1) — deliberately contained; reviving would
  # just re-fail. The operator heals it explicitly.
  if [[ -f "$FAILMARK" ]] && awk -v n="$name " 'index($0,n)==1{f=1} END{exit !f}' "$FAILMARK" 2>/dev/null; then
    log "W4: $name exited but a watchdog ALERT names it (contained) — NOT auto-reviving"; return 0
  fi
  # Guard 2: distinguish a deliberate STOP from a DEATH. The exit code ALONE can't — `docker stop`
  # exits 137/143, identical to a reboot SIGKILL (§24 adversarial caught this). Disambiguate by intent:
  #   • OOMKilled=true → the system killed it → revive (unambiguous death).
  #   • exit 0 → a clean finish → leave it.
  #   • restart=unless-stopped/always + exited → Docker would auto-restart a CRASH, so an exited one
  #     means Docker honored an operator `docker stop` → operator intent → leave it.
  #   • restart=no + exited (nonzero, not OOM) → Docker won't bring it back; reviving a dead
  #     non-persistent sandbox is the durability intent → revive.
  if [[ "$oom" != "true" ]]; then
    [[ "$ec" == "0" ]] && return 0
    case "$rp" in
      unless-stopped|always) log "W4: $name exited under restart=$rp (Docker honors a manual stop) — operator intent, not reviving"; return 0 ;;
    esac
  fi
  if _throttled "revive:$name"; then
    log "W4: $name exited (code $ec, oom $oom, policy $rp) — revive throttled (<${THROTTLE_SECS}s), skipping"; return 0
  fi
  _mark "revive:$name"
  log "W4: $name container EXITED (code $ec, oom $oom, policy $rp) — reviving via docker start (non-destructive)"
  # Fresh token at boot: if REMINT is on and a token file exists, re-mint it FIRST (container
  # stopped) so the relay reads a valid token on start instead of immediately storming. BOUNDED (§24).
  if [[ "$REMINT" == "1" ]]; then
    local tok; tok="$(_wd_bounded 5 _token_path "$cid" 2>/dev/null || true)"
    [[ -n "$tok" ]] && { _remint_file "$name" "$tok" && log "  W4: re-minted $name token before start" || true; }
  fi
  if _wd_bounded 30 "$DOCKER" start "$cid" >>"$LOG" 2>&1; then
    log "  W4: docker start $name OK (cid ${cid:0:12}); storm/gateway handled by the normal path next cycle"
    notify "$name was down — auto-revived ✓"; acted=1
  else
    log "  W4: docker start $name FAILED (rc/timeout) — marking for the operator"
    _failmark_set "$name" "$name was EXITED and auto-revive (docker start) FAILED at $(date '+%F %T') — manual: vz-ai-stack.sh install"
    notify "⚠ $name down — auto-revive FAILED; needs manual repair"
  fi
}

# --- W1: crash-loop breaker --------------------------------------------------
# A NON-sandbox MANAGED container stuck restarting (bad image/config — e.g. autofyn-agent's
# `ImportError: cannot import name 'SANDBOX_KIND_DOCKER'`) burns CPU forever, never serves,
# and compounds host thrash. Detect by the DELTA in RestartCount across cycles (the ABSOLUTE
# count is stale — autofyn-agent sat at 41 long after it stopped looping), SEED-and-skip the
# first observation, require it be actively failing, and break a confirmed loop with
# restart=no + stop (NON-destructive: writable layer kept; `docker start` to retry) + a RED
# FAILMARK. Sandboxes are EXCLUDED (their token-storm heal + W4 own them); only OUR containers
# are touched (never a foreign one). Needs bash 4+ (assoc array) — the plist prefers brew bash.
_w1_is_managed() {  # 0 iff container $1 is ours (our label, or a compose working_dir under $AI_STACK)
  local id="$1" out lbl wd
  # ONE bounded inspect (§24 SRE) — not two unbounded inspects per candidate under thrash.
  out="$(_wd_bounded 5 "$DOCKER" inspect "$id" --format '{{ index .Config.Labels "ai-stack.managed" }}|{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null || true)"
  IFS='|' read -r lbl wd <<< "$out"
  [[ -n "$lbl" && "$lbl" != "<no value>" ]] && return 0
  [[ -n "$wd" && "$wd" != "<no value>" && "$wd" == "$AI_STACK"* ]] && return 0
  return 1
}
_w1_crashloop_scan() {
  [[ "$CRASHLOOP_BREAK" == "1" ]] || return 0
  (( BASH_VERSINFO[0] >= 4 )) || return 0
  local ids; ids="$(_wd_bounded 15 "$DOCKER" ps -aq 2>/dev/null || true)"
  [[ -n "$ids" ]] || return 0
  local inspect_out
  inspect_out="$(_wd_bounded 20 "$DOCKER" inspect $ids --format '{{.Id}}|{{.Name}}|{{.RestartCount}}|{{.State.ExitCode}}|{{.State.Status}}' 2>/dev/null || true)"
  [[ -n "$inspect_out" ]] || return 0
  declare -A prev
  if [[ -f "$CRASHCOUNT_FILE" ]]; then
    while read -r _id _c; do [[ -n "$_id" ]] && prev["$_id"]="$_c"; done < "$CRASHCOUNT_FILE"
  fi
  local now_lines="" id name rc ec st base delta
  while IFS='|' read -r id name rc ec st; do
    [[ -n "$id" ]] || continue
    now_lines+="$id $rc"$'\n'
    name="${name#/}"
    [[ "$name" == openshell-* ]] && continue                      # sandboxes self-heal (storm path + W4)
    base="${prev[$id]:-}"
    [[ -n "$base" ]] || continue                                  # SEED-and-skip: first sighting, no baseline
    delta=$(( rc - base )); if (( delta < 0 )); then delta=0; fi
    (( delta >= CRASHLOOP_N )) || continue
    # Gate on "restarting" ONLY (§24 adversarial): `ec != 0` also matches an already-EXITED
    # (no-longer-looping) container — operator-stopped, or Docker exhausted a finite retry budget —
    # and would wrongly set restart=no + a "CRASH-LOOPING" alert on it. "restarting" = Docker is
    # actively backing-off-retrying = a LIVE loop. (Caught at a brief "running" instant → next cycle.)
    [[ "$st" == "restarting" ]] || continue
    _w1_is_managed "$id" || continue                              # never touch a foreign container
    if _throttled "crashloop:$name"; then continue; fi
    _mark "crashloop:$name"
    log "W1: CRASH-LOOP '$name' (+${delta} restarts since last check, exit $ec, status $st) — restart=no + stop (non-destructive)"
    _wd_bounded 15 "$DOCKER" update --restart=no "$id" >>"$LOG" 2>&1 || log "  W1: update --restart=no $name failed"
    _wd_bounded 20 "$DOCKER" stop "$id" >>"$LOG" 2>&1 \
      && log "  W1: stopped $name (writable layer kept; fix image/config, then 'docker start $name')" \
      || log "  W1: docker stop $name failed"
    _failmark_set "$name" "$name CRASH-LOOPING — broke the loop (restart=no + stopped) at $(date '+%F %T'); fix image/config, then: docker start $name  (non-compose: also 'docker update --restart=unless-stopped' to restore boot-persistence)"
    notify "$name crash-looping — stopped it (CPU burn halted; needs a fix)"; acted=1
  done <<< "$inspect_out"
  [[ -n "$now_lines" ]] && { printf '%s' "$now_lines" > "$CRASHCOUNT_FILE.tmp" && mv -f "$CRASHCOUNT_FILE.tmp" "$CRASHCOUNT_FILE" 2>/dev/null; } || true
}

# --- subcommands: manage the launchd timer (install/uninstall/status) ---------
PLIST="$HOME/Library/LaunchAgents/com.ai-stack.openshell-watchdog.plist"
LABEL="com.ai-stack.openshell-watchdog"
INTERVAL="${AI_STACK_WATCHDOG_INTERVAL:-180}"   # check every 3 min (was 600; bounds a storm faster)
case "${1:-run}" in
  install)
    mkdir -p "$HOME/Library/LaunchAgents"
    # Persistence: run at boot/login (RunAtLoad) so sandboxes recover after a VM cycle.
    RUNATLOAD="<false/>"; [[ "$PERSIST" == "1" ]] && RUNATLOAD="<true/>"
    [[ -n "$BASH4" ]] || echo "⚠ no bash 4+ found (run: brew install bash) — plist will use /bin/bash 3.2; sandbox persistence still works, only the generic CPU-runaway net is skipped"
    cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>${BASH4:-/bin/bash}</string><string>$AI_STACK/bin/openshell-watchdog.sh</string><string>run</string>
  </array>
  <key>StartInterval</key><integer>$INTERVAL</integer>
  <key>RunAtLoad</key>$RUNATLOAD
  <key>EnvironmentVariables</key><dict>
    <key>AI_STACK</key><string>$AI_STACK</string>
    <key>AI_STACK_WATCHDOG_HALT</key><string>${HALT}</string>
    <key>AI_STACK_WATCHDOG_RECREATE</key><string>${RECREATE}</string>
    <key>AI_STACK_WATCHDOG_REMINT</key><string>${REMINT}</string>
    <key>AI_STACK_SANDBOX_PERSIST</key><string>${PERSIST}</string>
    <key>AI_STACK_WATCHDOG_REMINT_THRESHOLD</key><string>${REMINT_THRESHOLD}</string>
    <key>AI_STACK_WATCHDOG_GATEWAY_SUPERVISE</key><string>${W2_SUPERVISE}</string>
    <key>AI_STACK_WATCHDOG_REVIVE_EXITED</key><string>${W4_REVIVE}</string>
    <key>AI_STACK_WATCHDOG_CRASHLOOP_BREAK</key><string>${CRASHLOOP_BREAK}</string>
    <key>AI_STACK_WATCHDOG_CONFIG_HEAL</key><string>${CONFIG_HEAL}</string>
    <!-- The `docker` CLI is engine-AGNOSTIC: Docker Desktop / Colima / Podman all
         install it to /opt/homebrew/bin (resolved FIRST by _find, before
         ~/.orbstack/bin), so this PATH works for every engine. The ENGINE itself
         is selected by DOCKER_HOST (exported above from gateway.env / the registry),
         not by which CLI dir is on PATH. -->
    <key>PATH</key><string>${DOCKER:+$(dirname "$DOCKER"):}${OPENSHELL:+$(dirname "$OPENSHELL"):}/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>$STATE/openshell-watchdog.launchd.log</string>
  <key>StandardErrorPath</key><string>$STATE/openshell-watchdog.launchd.log</string>
</dict></plist>
PL
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null || launchctl load "$PLIST" 2>/dev/null || true
    # Fire one cycle NOW so persistence takes effect immediately (don't wait a full
    # interval). RunAtLoad covers boot; this covers install-time + shrinks the post-reboot
    # window where an auto-restarted container could briefly storm before the first cycle.
    launchctl kickstart -k "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl start "$LABEL" 2>/dev/null || true
    # Persist the EFFECTIVE modes so a later BARE `install` (Phase 04 / manual heal) inherits
    # them instead of resetting to the committed defaults (the regression vector). An explicit
    # env var on a future call still overrides + updates this file.
    # R6: ATOMIC write (tmp + mv -f) — this file exists specifically to survive the
    # 'idempotent install silently resets auto-heal to OFF' regression, so a torn/short write
    # (disk full, or a SIGKILL/reboot mid-install) that left a partial conf would re-open that
    # exact failure mode (next bare install inherits REMINT/PERSIST=OFF). mv is atomic.
    { printf 'AI_STACK_WATCHDOG_REMINT=%s\nAI_STACK_SANDBOX_PERSIST=%s\nAI_STACK_WATCHDOG_RECREATE=%s\nAI_STACK_WATCHDOG_HALT=%s\nAI_STACK_WATCHDOG_GATEWAY_SUPERVISE=%s\nAI_STACK_WATCHDOG_REVIVE_EXITED=%s\nAI_STACK_WATCHDOG_CRASHLOOP_BREAK=%s\nAI_STACK_WATCHDOG_CONFIG_HEAL=%s\n' \
        "$REMINT" "$PERSIST" "$RECREATE" "$HALT" "$W2_SUPERVISE" "$W4_REVIVE" "$CRASHLOOP_BREAK" "$CONFIG_HEAL" > "$CONF.tmp" \
        && mv -f "$CONF.tmp" "$CONF"; } 2>/dev/null || true
    echo "openshell-watchdog launchd job installed ($LABEL, every ${INTERVAL}s; RunAtLoad=$([[ "$PERSIST" == 1 ]] && echo true || echo false); modes persisted -> watchdog.conf)"; exit 0 ;;
  uninstall)
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"; echo "openshell-watchdog launchd job removed"; exit 0 ;;
  status)
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -iE 'state|pid|last exit|runs' | head \
      || echo "launchd job not loaded"
    echo "--- persistence mode (baked into installed plist) ---"
    grep -E 'AI_STACK_WATCHDOG_REMINT|AI_STACK_SANDBOX_PERSIST|AI_STACK_WATCHDOG_GATEWAY_SUPERVISE|AI_STACK_WATCHDOG_REVIVE_EXITED|AI_STACK_WATCHDOG_CRASHLOOP_BREAK|RunAtLoad' "$PLIST" 2>/dev/null \
      | sed -E 's/<key>|<\/key>|<string>|<\/string>|<|\/>/ /g; s/  +/ /g; s/^ //' \
      || echo "(plist not installed)"
    echo "--- recent watchdog log ($LOG) ---"; tail -n 15 "$LOG" 2>/dev/null || echo "(no log yet)"; exit 0 ;;
  run) : ;;   # fall through to the detection cycle below
  *) echo "usage: openshell-watchdog.sh [run|install|uninstall|status]" >&2; exit 2 ;;
esac

[[ -n "$DOCKER" ]] || { log "FATAL: docker not found"; exit 0; }

# Single-instance lock, with STALE RECLAIM: a watchdog run killed mid-cycle (e.g. by a
# reboot — observed 2026-06-19) leaves the lock dir behind, which would silently wedge
# EVERY future run (mkdir fails -> exit 0 forever -> persistence dies quietly). So if the
# lock exists but is older than the max plausible run (10 min), reclaim it and proceed.
if ! mkdir "$LOCK" 2>/dev/null; then
  _lock_age=$(( $(date +%s) - $(stat -f %m "$LOCK" 2>/dev/null || echo 0) ))
  if (( _lock_age > 600 )); then
    log "reclaiming STALE watchdog lock (age ${_lock_age}s > 600s — a prior run was killed/rebooted mid-cycle)"
    rmdir "$LOCK" 2>/dev/null || rm -rf "$LOCK" 2>/dev/null || true
    mkdir "$LOCK" 2>/dev/null || exit 0
  else
    exit 0   # a recent run is genuinely still in flight
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# Defer if an install is in progress (avoid fighting over sandboxes).
# Defer ONLY if a LIVE install holds the lock. A crashed/killed install leaves a stale lock dir,
# and with NO reclaim the watchdog would defer FOREVER — silently disabling ALL auto-heal (W1-W5
# + storm). So check the lock's pid: alive => real install (defer); dead/absent => STALE (proceed).
if [[ -d "$INSTALL_LOCK" ]]; then
  _il_pid="$(cat "$INSTALL_LOCK/pid" 2>/dev/null || echo)"
  _il_age=$(( $(date +%s) - $(stat -f %m "$INSTALL_LOCK" 2>/dev/null || echo 0) ))
  # Defer ONLY for a LIVE install. The naive `[[ -d ]] && exit` deferred FOREVER on a crashed install
  # (disabling ALL auto-heal); a bare pid-liveness check instead defers for HOURS once the dead pid is
  # RECYCLED to an unrelated process (council W1). So: pid alive AND is a vz-ai-stack process => real
  # install, defer (any duration); pid empty but lock YOUNG (<15s) => lock_acquire's mkdir-then-write
  # race (council W2) => defer; else (dead/reused pid, or old+no-pid) => STALE => proceed.
  if [[ -n "$_il_pid" ]] && kill -0 "$_il_pid" 2>/dev/null \
       && ps -p "$_il_pid" -o command= 2>/dev/null | grep -q 'vz-ai-stack'; then
    log "install in progress (pid $_il_pid) — deferring this cycle"; exit 0
  elif [[ -z "$_il_pid" ]] && (( _il_age < 15 )); then
    log "install lock too new (${_il_age}s, no pid yet) — deferring this cycle"; exit 0
  fi
  log "ignoring STALE install lock (pid '${_il_pid:-none}' not a live install, age ${_il_age}s) — proceeding with auto-heal"
fi

# G10 — daemon-health gate: a wedged docker daemon (the host-thrash condition a storm
# coincides with — cf. the 06-29 21:48 W2 timeout) would otherwise hang this cycle on the
# unbounded per-cycle docker calls until the 600s stale-lock reclaim (watchdog dark ~10 min,
# possibly missing a proactive re-mint that then expires). Probe under a hard bound; if the
# daemon isn't responsive, skip THIS cycle cleanly (the EXIT trap releases the lock) and
# re-check next interval — never wedge.
if ! _wd_bounded 8 "$DOCKER" version >/dev/null 2>&1; then
  log "docker daemon not responding within 8s (wedged under host memory pressure?) — skipping this cycle"
  exit 0
fi

_throttled() {  # _throttled <key> — true if <key> was acted on within THROTTLE_SECS
  local key="$1" now last
  now="$(date +%s)"
  last="$(grep -E "^$key " "$THROTTLE_FILE" 2>/dev/null | tail -1 | awk '{print $2}')"
  [[ -n "$last" ]] && (( now - last < THROTTLE_SECS ))
}
_mark() { local key="$1"; { grep -vE "^$key " "$THROTTLE_FILE" 2>/dev/null || true; echo "$key $(date +%s)"; } > "$THROTTLE_FILE.tmp" && mv -f "$THROTTLE_FILE.tmp" "$THROTTLE_FILE"; }

# Storm signature for a sandbox container id: expired-token retry storm. Thin wrapper
# over the shared StartedAt-gated detector (installer/lib/storm-detect.sh) — same logic
# as the installer + doctor 39, so it can't drift. storm_detect bounds its own read
# (W3-style background+poll+kill) and gates on the container's last restart, so a
# freshly re-minted+restarted sandbox is NOT flagged on its stale pre-restart logs.
# UNKNOWN (rc 2, wedged-docker read) maps to "not storming" here: the per-cycle daemon
# -health gate (G10) + W3 bounds own the wedged-daemon case at the cycle level — a lone
# UNKNOWN read must not trigger a heal. Fallback to the legacy inline grep only if
# storm-detect.sh is somehow unavailable (shared-repo safety).
_is_storming() {
  local cid="$1" rc=0
  if declare -F storm_confirmed >/dev/null 2>&1; then
    # storm_confirmed corroborates an ambiguous reconnect-flood against real token expiry so an
    # external CPU/IO scan (Nessus/CrowdStrike) flap on a VALID token can't fake a storm and
    # trigger a destructive re-mint/restart heal during the scan (CR-4). rc 2 (UNKNOWN) maps to 1.
    storm_confirmed "$DOCKER" "$cid" || rc=$?
    [[ $rc -eq 0 ]] && return 0 || return 1
  elif declare -F storm_detect >/dev/null 2>&1; then
    storm_detect "$DOCKER" "$cid" || rc=$?
    [[ $rc -eq 0 ]] && return 0 || return 1
  fi
  local logs
  logs="$(_wd_bounded 10 "$DOCKER" logs "$cid" --since 3m --tail 60 2>&1 || true)"
  grep -q 'ExpiredSignature' <<<"$logs" && return 0
  grep -q 'RefreshSandboxToken.*Unauthenticated' <<<"$logs" && return 0
  (( $(grep -cE 'log push (stream lost, reconnecting|reconnected \(attempt)' <<<"$logs") >= 8 )) && return 0
  return 1
}

# _child_path — prepend the RESOLVED tool dirs so a shelled `vz-ai-stack.sh install`
# finds docker/openshell/brew even under launchd's minimal PATH. (DEFECT-2: the
# child installer's preflight does `command -v docker`; OrbStack's docker lives at
# ~/.orbstack/bin and was NOT on the plist PATH, so every rebuild aborted.)
_child_path() {
  local d=""
  [[ -n "$DOCKER"    ]] && d="$(dirname "$DOCKER"):"
  [[ -n "$OPENSHELL" ]] && d="$d$(dirname "$OPENSHELL"):"
  [[ -n "$BREW"      ]] && d="$d$(dirname "$BREW"):"
  printf '%s%s' "$d" "$PATH"
}

# _phase_install <cpath> <phase...> — run the recreate phases with a docker-capable
# PATH; return non-zero if ANY phase fails (DEFECT-3: no more false "done").
_phase_install() {
  local cpath="$1"; shift; local p rc=0
  for p in "$@"; do
    PATH="$cpath" bash "$AI_STACK/vz-ai-stack.sh" install "$p" >>"$LOG" 2>&1 || { rc=1; log "  install $p FAILED (rc=$?)"; }
  done
  return $rc
}

# _verify_ready <name> — poll until the sandbox reports Ready (or give up).
_verify_ready() {
  local name="$1" i
  for i in 1 2 3 4 5 6; do
    "$OPENSHELL" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
      | awk -v n="$name" 'NR>1 && $1==n && $NF=="Ready"{ok=1} END{exit !ok}' && return 0
    sleep 5
  done
  return 1
}

# --- in-place token re-mint (persistence) -----------------------------------
_token_path() {  # _token_path <cid> -> echo sandbox.jwt path (rc 1 if absent)
  local cid="$1" uuid base m found=()
  uuid="$("$DOCKER" inspect "$cid" --format '{{.Name}}' 2>/dev/null \
    | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  [[ -n "$uuid" ]] || return 1
  # G5: glob by UUID (unique across gateways), NOT the hardcoded /default/ slug — under a
  # non-default gateway name the token was unfindable, so re-mint silently no-op'd and the
  # heal degraded to a restart that can't refresh an expired token. Match exactly one; >1 -> fail.
  base="${TOKDIR%/default}"
  for m in "$base"/*/"$uuid"/sandbox.jwt; do [[ -f "$m" ]] && found+=("$m"); done
  (( ${#found[@]} == 1 )) || return 1
  echo "${found[0]}"
}
_token_secs_left() {  # _token_secs_left <tokenpath> -> echo seconds-to-expiry
  [[ -n "$PYTHON3" && -f "$MINT" && -f "$1" ]] || return 1
  OPENSSL_BIN="$OPENSSL" "$PYTHON3" "$MINT" --token "$1" --exp-only 2>/dev/null
}
_remint_file() {  # _remint_file <name> <tok> -> 0 if a fresh token was written
  [[ -n "$PYTHON3" && -f "$MINT" && -n "$OPENSSL" ]] || { log "  re-mint($1): python3/minter/openssl unavailable"; return 1; }
  OPENSSL_BIN="$OPENSSL" "$PYTHON3" "$MINT" --token "$2" --write >>"$LOG" 2>&1 \
    || { log "  re-mint($1): mint FAILED (original token + .bak intact)"; return 1; }
}
# Reactive heal (PROVEN path): re-mint + docker restart (forces re-bootstrap on the
# fresh token) + relaunch in-sandbox daemons that a restart kills. State in /sandbox
# survives a docker restart, so this is NON-destructive (no delete, no recreate).
_remint_heal() {  # _remint_heal <name> <cid> -> 0 healed
  local name="$1" cid="$2" tok relaunch cpath
  tok="$(_token_path "$cid")" || { log "  re-mint($name): no token file"; return 1; }
  _remint_file "$name" "$tok" || return 1
  # BOUNDED (review): docker restart can hang indefinitely under the host-memory thrash a storm
  # coincides with — the exact condition this heal must survive — and an unbounded restart would
  # hold the watchdog lock until the 600s reclaim. _wd_bounded 30 matches _verify_ready's cadence.
  _wd_bounded 30 "$DOCKER" restart "$cid" >>"$LOG" 2>&1 || { log "  re-mint($name): docker restart timed-out/failed"; return 1; }
  # rc 2 = minted + restarted but not Ready YET. Caller must NOT fall through to the
  # destructive halt/recreate (that would discard the fresh-token state); next cycle re-checks.
  _verify_ready "$name" || { log "  re-mint($name): minted+restarted, not Ready yet — leaving it for the next cycle"; return 2; }
  # Relaunch the in-sandbox gateway a docker restart kills. /sandbox state survives the
  # restart so a bare relaunch suffices. hermes-fleet-v1 runs the gateway; pi-v1 has NO
  # persistent daemon. Use docker exec (NOT phase 20 / the openshell relay — the relay
  # HANGS under the memory thrash a storm coincides with, the exact condition this heals).
  # The loop's W2 liveness check is gated on storming==0, so it can't double-relaunch here.
  if [[ "$name" == "hermes-fleet-v1" ]]; then
    _gateway_relaunch "$cid" "$name" || log "  re-mint($name): gateway relaunch had issues"
  fi
  # R2: verify the ARTIFACT (storm STOPPED), not just the control-plane Ready signal — an
  # expired/rejected token reports Ready while the relay is dead (the very premise of the
  # storm gate). Re-check against the container's NEW post-restart StartedAt window; if it is
  # STILL storming, the fresh token was REJECTED (clock skew / kid rotation / a jti pin), so
  # this re-mint did NOT heal. Returning 3 (not 0) stops handle_storm from a false-green
  # "HEALED" that clears the alert and throttles re-detection for 1800s while CPU burns.
  # Settle before judging: a REJECTED fresh token makes the relay re-emit ExpiredSignature within
  # ~1-2s of its first post-restart gRPC call; 5s gives margin even when host thrash slows relay
  # startup, so a still-rejected token isn't missed (a false-heal would clear the alert + notify,
  # then re-storm next cycle). storm_detect's absolute --since gate means this re-check can't
  # false-POSITIVE on stale pre-restart logs (the skew case the architect flagged).
  sleep 5
  if _is_storming "$cid"; then
    log "  re-mint($name): re-minted+restarted+Ready but STILL storming — fresh token REJECTED; NOT declaring healed (rc3)"
    return 3
  fi
  return 0
}

handle_storm() {  # handle_storm <name> <cid>
  local name="$1" cid="$2" phases
  case "$name" in
    hermes-fleet-v1)
      phases="04 04f"
      grep -q '^HERMES_TELEGRAM_BOT_TOKEN=.' "$AI_STACK/.env" 2>/dev/null && phases="$phases 20" ;;
    pi-v1) phases="15" ;;
    *)     phases="" ;;
  esac

  # PERSISTENCE (REMINT=1): try the NON-DESTRUCTIVE in-place re-mint heal FIRST —
  # keeps the SAME sandbox + /sandbox state (no delete, no recreate). Only fall
  # through to the destructive halt/recreate paths if re-mint is unavailable/fails.
  if [[ "$REMINT" == "1" ]]; then
    local _rc=0; _remint_heal "$name" "$cid" || _rc=$?
    if (( _rc == 0 )); then
      log "  HEALED $name via in-place token re-mint + restart (state preserved, no recreate)"
      _failmark_clear "$name"; notify "$name token re-minted ✓ (persisted, no data loss)"
      return 0
    elif (( _rc == 2 )); then
      log "  $name re-minted + restarted, awaiting Ready — NOT halting/recreating (fresh-token state preserved; re-checked next cycle)"
      return 0
    fi
    case "$_rc" in
      3) log "  re-mint of $name did NOT clear the storm (fresh token REJECTED — clock skew / kid rotation / jti pin?) — escalating to HALT, NOT looping a no-op re-mint (R2)" ;;
      *) log "  re-mint heal FAILED for $name (mint/restart error, rc=$_rc) — falling back to the halt/recreate path" ;;
    esac
  fi

  # DEFAULT (RECREATE!=1): NEVER auto-destroy. With HALT=1 (now default) cap + stop the
  # storming container to kill the CPU burn — non-destructive (writable layer preserved;
  # docker start re-runs it), and the host hang it prevents is NOT recoverable.
  if [[ "$RECREATE" != "1" ]]; then
    log "ALERT: $name has an expired-token storm (cid ${cid:0:12}). NOT auto-deleting (state preserved)."
    log "  Heal when ready (state is checkpointed first; restore via bin/openshell-state-restore.sh):  bash $AI_STACK/vz-ai-stack.sh install $phases"
    if [[ "$HALT" == "1" ]]; then
      # Cap CPU/mem on the LIVE container first so even the detection window cannot
      # starve the host (best-effort: OrbStack may not honor a live cgroup edit — never
      # let that block the stop).
      "$DOCKER" update --cpus 0.5 --memory 2g "$cid" >>"$LOG" 2>&1 \
        && log "  capped storming container to 0.5cpu/2g (bounds the burn)" || true
      # Best-effort checkpoint before halting (halt is non-destructive; this also
      # protects the state as a keep-labeled image against a later prune). Never blocks.
      _wd_bounded 60 bash "$AI_STACK/bin/openshell-checkpoint.sh" "$name" storm-halt >>"$LOG" 2>&1 \
        && log "  checkpointed $name before halt (keep-labeled image)" \
        || log "  (pre-halt checkpoint skipped/failed/timed-out — halt is still non-destructive) (R7)"
      "$DOCKER" stop "$cid" >>"$LOG" 2>&1 \
        && log "  halted the container to stop the CPU burn (record preserved; restart/recreate to use it)" \
        || log "  (docker stop failed)"
    fi
    _failmark_set "$name" "$(printf '%s expired-token storm at %s — auto-recreate OFF (data-safe; halted+checkpointed). Heal: vz-ai-stack.sh install %s' \
      "$name" "$(date '+%F %T')" "$phases")"
    notify "$name token storm — halted+checkpointed; recreate when ready (auto-recreate OFF)"
    return 0
  fi

  # OPT-IN auto-recreate: verify we CAN rebuild BEFORE deleting (DEFECT-1), recreate,
  # VERIFY Ready, fail LOUD on any failure (DEFECT-3).
  local cpath; cpath="$(_child_path)"
  if ! PATH="$cpath" command -v docker >/dev/null 2>&1 || [[ -z "$OPENSHELL" ]]; then
    log "REFUSING to recreate $name: rebuild prerequisites missing (docker on PATH / openshell). Sandbox LEFT INTACT — never delete without a viable rebuild."
    _failmark_set "$name" "$(printf '%s storm; auto-recreate ABORTED (no docker/openshell for rebuild) — sandbox left intact %s' "$name" "$(date '+%F %T')")"
    notify "⚠ $name storm — recreate aborted (rebuild prereqs missing); left intact"
    return 0
  fi
  log "RECREATING $name (opt-in; capability-checked; CHECKPOINT-first; delete+rebuild for a fresh token)"
  notify "$name token expired — checkpointing then auto-recreating"
  # H3 — FAIL-CLOSED: checkpoint must succeed (rc 0) or report no-container (rc 1)
  # before we delete. rc 2 = commit/verify failed → REFUSE to delete (this is exactly
  # the 2026-06-03 'destroy-before-verify → rebuild fails → data lost' vector).
  local _ck_rc=0
  # R7: bound the commit — under the thrash a storm coincides with, `docker commit` of a
  # multi-GB writable layer can hang the cycle. A TIMEOUT (124) is treated as checkpoint
  # FAILURE → fail-closed REFUSE to delete (never delete without a verified backup).
  _wd_bounded 120 bash "$AI_STACK/bin/openshell-checkpoint.sh" "$name" recreate >>"$LOG" 2>&1 || _ck_rc=$?
  if (( _ck_rc == 2 || _ck_rc == 124 )); then
    log "  REFUSING to recreate $name: pre-delete checkpoint FAILED — sandbox LEFT INTACT (never delete without a verified backup)."
    _failmark_set "$name" "$(printf '%s auto-recreate ABORTED: checkpoint failed at %s — sandbox left intact, needs manual repair' "$name" "$(date '+%F %T')")"
    notify "⚠ $name recreate aborted — checkpoint failed; left intact"
    return 0
  fi
  "$OPENSHELL" sandbox delete "$name" >>"$LOG" 2>&1 || log "  (delete returned non-zero — continuing)"
  local rc=0; _phase_install "$cpath" $phases || rc=1
  if (( rc == 0 )) && _verify_ready "$name"; then
    log "  recreate of $name SUCCEEDED + verified Ready"
    _failmark_clear "$name"
    notify "$name recreated ✓"
  else
    log "  RECREATE of $name FAILED (install rc=$rc / not Ready) — sandbox is NOT healthy. Manual: bash $AI_STACK/vz-ai-stack.sh install $phases"
    _failmark_set "$name" "$(printf '%s auto-recreate FAILED (rc=%s) at %s — sandbox missing/unhealthy; manual repair needed' "$name" "$rc" "$(date '+%F %T')")"
    notify "⚠ $name recreate FAILED — needs manual repair (see doctor)"
  fi
}

# Loud guards for the silent-failure configs the review flagged (run once per cycle).
if [[ "$PERSIST" == "1" && "$REMINT" != "1" ]]; then
  log "WARNING: PERSIST=1 but REMINT!=1 — NOT applying restart=unless-stopped (unsafe without the re-mint heal). Re-install with AI_STACK_WATCHDOG_REMINT=1."
fi
if [[ "$REMINT" == "1" ]]; then
  if [[ -z "$OPENSSL" ]] || "$OPENSSL" version 2>/dev/null | grep -qi 'libressl'; then
    log "WARNING: REMINT=1 but no OpenSSL 3.x resolved (got '${OPENSSL:-none}'); macOS LibreSSL cannot sign the gateway key — re-mint WILL fail. Run: brew install openssl@3."
  fi
fi

acted=0
for name in "${SANDBOXES[@]}"; do
  cid="$("$DOCKER" ps -q --filter "name=openshell-${name}-" 2>/dev/null | head -1)"
  # W4: no RUNNING container for this managed sandbox — try to revive an EXITED one that died
  # on reboot/crash and wasn't auto-restarted (durability: sandboxes are meant to be long-lived).
  if [[ -z "$cid" ]]; then _w4_revive_exited "$name"; continue; fi

  # Persistence: keep managed containers on restart=unless-stopped so they survive a
  # docker/system restart (safe now: capped + the storm-heal below re-mints any
  # post-restart storm within one cycle — not the 2026-06-08 uncapped/no-heal vector).
  # restart=unless-stopped is ONLY safe paired with REMINT (the heal that re-mints a
  # post-restart storm). Without REMINT an auto-resurrected sandbox could storm with only
  # the destructive halt/recreate fallback — so require BOTH. (A loud warning for the
  # PERSIST=1/REMINT=0 misconfig is emitted once per cycle below the loop.)
  if [[ "$PERSIST" == "1" && "$REMINT" == "1" ]]; then
    cur_rp="$("$DOCKER" inspect "$cid" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo)"
    [[ "$cur_rp" != "unless-stopped" ]] && { "$DOCKER" update --restart=unless-stopped "$cid" >>"$LOG" 2>&1 \
      && log "persistence: $name restart-policy -> unless-stopped" || true; }
  fi

  storming=0; _is_storming "$cid" && storming=1

  # PROACTIVE re-mint: refresh the token in place BEFORE it expires so the storm never
  # starts. No restart (best-effort — relies on the relay re-reading the file; the
  # reactive storm-heal below is the PROVEN safety net if the relay cached the old token).
  if [[ "$REMINT" == "1" && "$storming" == "0" ]]; then
    tok="$(_token_path "$cid" 2>/dev/null || true)"
    if [[ -n "$tok" ]]; then
      left="$(_token_secs_left "$tok" 2>/dev/null || echo)"
      if [[ "$left" =~ ^-?[0-9]+$ ]] && (( left < REMINT_THRESHOLD )); then
        log "PROACTIVE re-mint $name (~${left}s to expiry < ${REMINT_THRESHOLD}s; in place, no restart)"
        _remint_file "$name" "$tok" && acted=1 || true
      fi
    fi
  fi

  if [[ "$storming" == "1" ]]; then
    if _throttled "$name"; then
      log "$name is storming but throttled (acted < ${THROTTLE_SECS}s ago) — skipping"
    else
      log "DETECTED expired-token storm on $name (cid ${cid:0:12})"
      _mark "$name"
      handle_storm "$name" "$cid"
      acted=1
    fi
  fi

  # W2: gateway-liveness supervision. ONLY when NOT storming — a storm-heal (handle_storm
  # -> _remint_heal) already relaunched the gateway this cycle, so gating on storming==0
  # makes W2 and the heal-relaunch mutually exclusive (no two concurrent `--replace` that
  # would cycle-kill each other). The 180s cycle is the natural throttle: a chronically
  # dead/broken gateway is relaunched at most once/cycle (idempotent --replace, never a
  # tight loop) and each relaunch is logged so a persistently-dark gateway stays visible.
  # W5: gateway-CONFIG heal/snapshot — its OWN guard, INDEPENDENT of W2 (council B1: nesting it under
  # W2 meant disabling W2 silently killed snapshotting + healing). Runs BEFORE W2; a restore relaunches
  # the gateway, so cfg_healed skips W2's relaunch this cycle (no double `--replace`).
  cfg_healed=0
  if [[ "$CONFIG_HEAL" == "1" && "$storming" == "0" && "$name" == "hermes-fleet-v1" ]]; then
    if _gateway_config_heal "$cid" "$name"; then cfg_healed=1; acted=1; fi
  fi
  if [[ "$W2_SUPERVISE" == "1" && "$storming" == "0" && "$name" == "hermes-fleet-v1" && "$cfg_healed" == "0" ]]; then
    # NB: `set -Eeuo pipefail` is in effect — capture the rc via `|| gw_rc=$?` so a non-zero (gateway
    # DOWN = rc 1) does NOT abort the whole cycle. rc 124 = liveness TIMED OUT (docker wedged under
    # thrash) — "unknown" is NOT "dead", so do NOT relaunch a possibly-healthy gateway. rc 1 = dead.
    gw_rc=0; _gateway_alive "$cid" || gw_rc=$?
    if (( gw_rc == 124 )); then
      log "W2: $name gateway liveness check TIMED OUT (docker wedged under thrash?) — NOT relaunching this cycle"
    elif (( gw_rc != 0 )); then
      log "W2: $name gateway process DOWN (sandbox up, no storm) — relaunching"
      _gateway_relaunch "$cid" "$name" && acted=1
    fi
  fi

  # W2b: Slack role-router liveness (Phase 38) — same knob + gates as W2: it is the
  # same class of in-sandbox channel process, and before this the ONLY relaunch path
  # was a human running bin/start-hermes-slack.sh (engine restart 2026-07-21 left the
  # router dark ~17h while the gateway self-healed via W2). Relaunch ONLY on a STALE
  # pid file: pid file PRESENT + process DEAD = crash/reboot took it (relaunch via the
  # phase-38 in-sandbox launcher, which persists in /sandbox and re-sources its env,
  # kills stragglers, and self-verifies). Pid file ABSENT = never configured OR
  # deliberately stopped (stop_role_router rm's it) — NEVER override operator intent.
  # rc map: 0=alive, 1=stale (relaunch), 3=not-configured/stopped (silent), 124=unknown (skip).
  if [[ "$W2_SUPERVISE" == "1" && "$storming" == "0" && "$name" == "hermes-fleet-v1" ]]; then
    sr_rc=0
    _wd_bounded 12 "$DOCKER" exec "$cid" sh -c '
      [ -s /sandbox/.hermes-slack-role-router.pid ] || exit 3
      [ -f /sandbox/fleet-boot/hermes_slack_role_router_start.sh ] || exit 3
      kill -0 "$(cat /sandbox/.hermes-slack-role-router.pid)" 2>/dev/null && exit 0
      exit 1' || sr_rc=$?
    if (( sr_rc == 1 )); then
      log "  W2b: $name slack role router STALE (pid file present, process dead) — relaunching via phase-38 launcher"
      # Launcher needs HOME=/sandbox (it sources $HOME/.hermes/.env) and takes ~5-9s
      # (straggler kill-wait + 4s self-verify); bounded well above that. docker exec,
      # NOT the openshell relay (same rationale as W2: the relay hangs under thrash).
      if _wd_bounded 30 "$DOCKER" exec "$cid" sh -c "export HOME=/sandbox; cd /sandbox; bash /sandbox/fleet-boot/hermes_slack_role_router_start.sh" >>"$LOG" 2>&1; then
        log "  W2b: slack role router relaunched in $name"; acted=1
      else
        log "  W2b: slack role router relaunch FAILED/timed out in $name — re-checked next cycle"
        notify "hermes slack role router relaunch FAILED in $name — run: bash $AI_STACK/bin/start-hermes-slack.sh"
      fi
    elif (( sr_rc == 124 )); then
      log "  W2b: $name slack router liveness check TIMED OUT — skipping this cycle"
    fi
  fi
done

# W1: crash-loop breaker — break any NON-sandbox MANAGED container stuck restarting (bad
# image/config like autofyn-agent's ImportError) so it stops burning CPU and is surfaced.
_w1_crashloop_scan || true

# Generic runaway net: any managed container pegged across two ~3s samples. Uses an
# associative array (`declare -A`), which needs bash 4+. Guard it so this script NEVER
# crashes under macOS system bash 3.2 (e.g. a plist that calls /bin/bash) — the
# sandbox persistence loop above is the critical path and is bash-3.2-safe; only this
# secondary non-sandbox CPU net is skipped on old bash. (The plist now prefers brew bash.)
if (( BASH_VERSINFO[0] >= 4 )); then
  # R1: `docker stats` is THE call documented to hang hardest under host-memory thrash
  # (openshell.sh:'NEVER docker stats'), and it was the only per-cycle docker call left
  # UNBOUNDED — under thrash it blocked the whole cycle (holding the EXIT-trap lock) until
  # the 600s stale-lock reclaim, darkening W1/W2/W4/W5 + storm heal for 10-min windows
  # exactly when a storm is active. Capture each sample through _wd_bounded; on timeout the
  # var is empty and this secondary CPU net simply SKIPS this cycle (bound-or-skip, never block).
  declare -A s1
  _stats1="$(_wd_bounded 15 "$DOCKER" stats --no-stream --format '{{.Names}}\t{{.CPUPerc}}' 2>/dev/null)" || _stats1=""
  while IFS=$'\t' read -r nm cpu; do [[ -n "$nm" ]] && s1["$nm"]="${cpu%\%}"; done <<< "$_stats1"
  sleep 3
  _stats2="$(_wd_bounded 15 "$DOCKER" stats --no-stream --format '{{.Names}}\t{{.CPUPerc}}' 2>/dev/null)" || _stats2=""
  while IFS=$'\t' read -r nm cpu; do
    [[ -n "$nm" ]] || continue
    c2="${cpu%\%}"; c1="${s1[$nm]:-0}"
    # integer compare (strip decimals)
    if (( ${c1%.*} > CPU_WARN )) && (( ${c2%.*} > CPU_WARN )); then
      # sandboxes self-heal above; here we just surface non-sandbox runaways.
      [[ "$nm" == openshell-* ]] || log "RUNAWAY: container '$nm' sustained CPU ${c1}%/${c2}% (> ${CPU_WARN}%) — investigate ('docker logs $nm')"
    fi
  done <<< "$_stats2"
else
  log "note: generic CPU-runaway net skipped (bash ${BASH_VERSINFO[0]} < 4; sandbox persistence ran above)"
fi

(( acted == 1 )) && log "watchdog cycle acted on a storm" || true
exit 0
