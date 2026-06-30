#!/usr/bin/env bash
# storm-detect.sh — the SINGLE, SIDE-EFFECT-FREE OpenShell token-storm detector.
#
# WHY THIS FILE EXISTS
# -------------------
# The expired-token "storm" signature was historically re-implemented in THREE
# places that DRIFTED apart (§24 cartography 2026-06-30):
#   • installer/lib/openshell.sh::openshell_token_storm  — matched ExpiredSignature
#     OR `RefreshSandboxToken … Unauthenticated`, but NOT the reconnect-count storm.
#   • bin/openshell-watchdog.sh::_is_storming            — matched ExpiredSignature
#     OR reconnect-count>=8, but NOT `RefreshSandboxToken Unauthenticated`.
#   • installer/doctor/checks/39_openshell_storm.sh      — same as the watchdog.
# A storm that emits ONLY `RefreshSandboxToken Unauthenticated` (the documented
# low-CPU ~5s-cadence manifestation) made the installer fail while the watchdog +
# doctor reported healthy and never auto-healed. This file is the one source of
# truth all three now call, so the signatures can never diverge again (G3).
#
# Two correctness guards baked in:
#   • G2 — START-GATE: only count signatures emitted AFTER the container's last
#     restart. `docker logs --since 3m` retains PRE-restart lines across a
#     `docker restart`, so for ~3 min after a heal (re-mint + restart) the legacy
#     detector returned a FALSE storm on an ALREADY-HEALED sandbox — a co-cause of
#     the 2026-06-30 `install 04f` failure. The window is clamped to
#     max(StartedAt, now-180s) so a long-running container never replays hours of
#     logs (the adversarial-review hazard: an unclamped `--since $StartedAt` is a
#     WORSE false positive than the bug it fixes).
#   • G9 — UNKNOWN tri-state: a docker-logs read that TIMES OUT under host-memory
#     thrash (the exact condition a storm coincides with) must NOT be reported as
#     "healthy". storm_detect returns 2 = UNKNOWN so callers can DEFER rather than
#     proceed into a hung exec.
#
# CONTRACT: define functions ONLY. No top-level side effects, no $AI_STACK
# requirement, no sourcing of common.sh — so doctor checks / the watchdog / the
# installer can all source it from any context without surprises. bash 3.2-safe.

# Guard against double-sourcing (re-defining the pure functions is harmless, but
# this keeps `source` cheap when several libs pull it in).
[[ -n "${_STORM_DETECT_SH:-}" ]] && return 0 2>/dev/null || true
_STORM_DETECT_SH=1

# _storm_bounded <secs> <cmd...> — run cmd with a hard wall-clock budget. Echoes
# cmd stdout; returns the cmd's rc, or 124 on timeout. macOS launchd has no
# `timeout`/`gtimeout` on PATH, so this mirrors the proven background+poll+kill
# pattern from openshell.sh::_osh_bounded / watchdog::_wd_bounded. Killing a
# `docker logs` reader is harmless (unlike killing an openshell exec).
_storm_bounded() {
  local s="$1" p w=0; shift
  "$@" & p=$!
  while (( w < s*2 )); do
    kill -0 "$p" 2>/dev/null || { wait "$p" 2>/dev/null; return $?; }
    sleep 0.5; w=$((w+1))
  done
  kill -TERM "$p" 2>/dev/null || true; sleep 1; kill -KILL "$p" 2>/dev/null || true
  wait "$p" 2>/dev/null || true
  return 124
}

# _storm_since_arg <docker_bin> <cid> — echo the `docker logs --since` argument as an ABSOLUTE
# Unix epoch (or the literal "3m" fallback). This is SKEW-PROOF, which a relative duration is NOT:
# `docker logs --since <duration>` is computed on the CLIENT (host) clock, while the log lines are
# stamped in the DAEMON clock — so under a host↔VM clock skew a relative window mis-selects lines
# (the R4 regression: a future StartedAt made `now_host - StartedAt_daemon < 0`). An ABSOLUTE
# timestamp is compared directly against the daemon's own log clock, so StartedAt (also daemon
# clock) lines up exactly. Window = max(StartedAt, now-180s):
#   • just-restarted  -> StartedAt  : post-restart lines ONLY (excludes pre-restart stale = G2),
#     and skew-proof because StartedAt and the log timestamps share the daemon clock;
#   • long-running    -> now-180    : bounded ~180s, never replays hours of a quiet container;
#   • future StartedAt (host behind daemon, the sleep/wake skew) -> StartedAt (in the future) ->
#     `--since <future>` shows NOTHING -> healthy. CORRECT: a container restarted seconds ago has
#     no post-restart storm yet, and a GENUINE storm has a PAST StartedAt -> positive window ->
#     detected. (Resolves both R4-blinding and the architect's R4 false-positive-on-stale.)
# Falls back to the literal "3m" (relative) only when StartedAt/now can't be parsed.
_storm_since_arg() {
  local docker_bin="$1" cid="$2" started s started_epoch now_epoch floor since
  started="$("$docker_bin" inspect -f '{{.State.StartedAt}}' "$cid" 2>/dev/null || true)"
  # StartedAt e.g. 2026-06-30T13:32:28.566596845Z (UTC). Strip trailing Z + fractional.
  s="${started%Z}"; s="${s%%.*}"
  # BSD/macOS date first (this stack is darwin-only); GNU date as a fallback.
  started_epoch="$(date -u -j -f '%Y-%m-%dT%H:%M:%S' "$s" '+%s' 2>/dev/null \
                  || date -u -d "$s" '+%s' 2>/dev/null || echo 0)"
  now_epoch="$(date -u '+%s' 2>/dev/null || echo 0)"
  if ! [[ "$started_epoch" =~ ^[0-9]+$ ]] || (( started_epoch <= 0 )) \
     || ! [[ "$now_epoch" =~ ^[0-9]+$ ]] || (( now_epoch <= 0 )); then
    printf '3m'; return 0   # StartedAt/now unparseable -> legacy relative 3m window (degrade safe)
  fi
  floor=$(( now_epoch - 180 ))
  since=$(( started_epoch > floor ? started_epoch : floor ))
  printf '%s' "$since"
}

# storm_detect <docker_bin> <cid> — the canonical LOG-signature detector.
#   rc 0 = STORMING    (an UNAMBIGUOUS token-rejection signature: ExpiredSignature /
#                       RefreshSandboxToken…Unauthenticated — the gateway rejected the token)
#   rc 1 = healthy     (no in-window storm signature, OR inputs absent)
#   rc 2 = UNKNOWN     (the bounded docker-logs read timed out — daemon wedged)
#   rc 3 = SUSPECTED   (>=8 reconnect lines but NO token-rejection signature — AMBIGUOUS: a real
#                       storm whose ExpiredSignature scrolled past --tail, OR a relay flap from
#                       EXTERNAL host CPU/IO thrash, e.g. a Nessus/CrowdStrike scan, on a VALID
#                       token). MUST be corroborated against real token expiry before acting —
#                       see storm_confirmed (CR-4: an external scan must NOT fake a token storm
#                       and trigger a destructive re-mint/restart heal during the very scan).
storm_detect() {
  local docker_bin="$1" cid="$2" since logs rc=0
  [[ -n "$docker_bin" && -n "$cid" ]] || return 1
  since="$(_storm_since_arg "$docker_bin" "$cid")"
  logs="$(_storm_bounded 10 "$docker_bin" logs "$cid" --since "$since" --tail 200 2>&1)"; rc=$?
  (( rc == 124 )) && return 2   # wedged read -> UNKNOWN, NOT "healthy" (G9)
  # The `grep -q … && return 0` form is exempt from set -e / the ERR trap (non-final command
  # of an AND-OR list), so a no-match here is safe.
  grep -q 'ExpiredSignature' <<<"$logs" && return 0
  grep -q 'RefreshSandboxToken.*Unauthenticated' <<<"$logs" && return 0
  # >=8 reconnect lines WITHOUT a token-rejection line = SUSPECTED, not confirmed. CAPTURE-then-
  # compare (NOT `(( $(grep -c …) ))`): `grep -c` EXITS 1 on a zero count, and inside a command
  # substitution that exit-1 is NOT AND-OR-exempt — under the inherited `set -E` ERR trap
  # vz-ai-stack.sh installs, a benign zero-count would fire a spurious "ERR line …". `|| true` +
  # numeric-validate neutralizes it.
  local _reconnects=0
  _reconnects="$(grep -cE 'log push (stream lost, reconnecting|reconnected \(attempt)' <<<"$logs" 2>/dev/null)" || true
  [[ "$_reconnects" =~ ^[0-9]+$ ]] || _reconnects=0
  (( _reconnects >= 8 )) && return 3   # SUSPECTED — corroborate via storm_confirmed (CR-4)
  return 1
}

# _storm_token_secs_left <docker_bin> <cid> — echo the sandbox gateway token's seconds-to-expiry
# (negative = already expired), or nothing + rc1 if it can't be determined. Decode-only via the
# minter's --exp-only (no openssl needed). Used to CORROBORATE an ambiguous reconnect-flood
# against ACTUAL expiry. Overridable in tests.
_storm_token_secs_left() {
  local docker_bin="$1" cid="$2" uuid base m tok py mint found=()
  py="$(command -v python3 2>/dev/null || true)"; [[ -n "$py" ]] || return 1
  mint="${AI_STACK:-$HOME/ai-stack}/bin/openshell-jwt-mint.py"; [[ -f "$mint" ]] || return 1
  # BOUNDED (§24 must-fix): both external calls run in the watchdog HOT PATH on an EDR-managed
  # Mac where a docker-API intercept (CrowdStrike) or a hung python can block FOREVER — a hang
  # would never reach storm_confirmed's INDETERMINATE->healthy return and would stall the cycle.
  # _storm_bounded caps each (on timeout -> empty output -> indeterminate -> defer, no stall).
  # Budgets are env-overridable so tests can exercise the bound quickly.
  uuid="$(_storm_bounded "${_STORM_INSPECT_BUDGET:-5}" "$docker_bin" inspect "$cid" --format '{{.Name}}' 2>/dev/null | grep -oE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' | head -1)"
  [[ -n "$uuid" ]] || return 1
  # STRICT match (mirror the G5 siblings _osh_token_path / watchdog _token_path): require EXACTLY
  # one token; on >1 (near-impossible — uuid is unique per sandbox) FAIL rather than silently read
  # a stale token under an ambiguous glob.
  base="$HOME/.local/state/openshell/docker-sandbox-tokens"
  for m in "$base"/*/"$uuid"/sandbox.jwt; do [[ -f "$m" ]] && found+=("$m"); done
  (( ${#found[@]} == 1 )) || return 1
  tok="${found[0]}"
  _storm_bounded "${_STORM_EXP_BUDGET:-8}" "$py" "$mint" --token "$tok" --exp-only 2>/dev/null
}

# storm_confirmed <docker_bin> <cid> — storm_detect + CR-4 corroboration of the ambiguous
# reconnect-flood (rc 3). Returns 0 STORM / 1 healthy / 2 UNKNOWN. This is what the watchdog +
# installer + doctor call (NOT storm_detect) so an external CPU/IO scan flap on a VALID token
# can never trigger a destructive heal. A reconnect-flood is a storm ONLY when the token is
# actually at/near expiry; a valid token under a flood = external pressure -> healthy (defer).
storm_confirmed() {
  local docker_bin="$1" cid="$2" rc=0 left
  storm_detect "$docker_bin" "$cid" || rc=$?
  case "$rc" in
    0|1|2) return "$rc" ;;   # confirmed token-rejection / healthy / unknown — pass through
    3)
      left="$(_storm_token_secs_left "$docker_bin" "$cid" 2>/dev/null || true)"
      # Threshold 120s (not 0): the gateway starts REJECTING a token slightly before its exact exp
      # (and a reconnect-flood is storm ONSET), so <=120s-to-expiry under a flood is a real storm;
      # a token with minutes left under a flood is external pressure (scan), not expiry. A valid
      # token at 119s under a benign flap costs at most one non-destructive re-mint+restart — far
      # cheaper than mis-healing every scan or missing a real onset.
      if [[ "$left" =~ ^-?[0-9]+$ ]]; then
        (( left <= 120 )) && return 0 || return 1   # near/expired => real storm ; valid => external flap
      fi
      return 1   # INDETERMINATE (no python3/minter/token, OR a bounded read timed out) -> do NOT churn a heal on a maybe-flap
      ;;
  esac
  return 1
}
