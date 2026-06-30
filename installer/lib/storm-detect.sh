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

# storm_detect <docker_bin> <cid> — the canonical detector.
#   rc 0 = STORMING   (expired-token signature emitted AFTER the last restart)
#   rc 1 = healthy    (no in-window storm signature, OR inputs absent)
#   rc 2 = UNKNOWN    (the bounded docker-logs read timed out — daemon wedged)
# Matches any of: ExpiredSignature | RefreshSandboxToken … Unauthenticated |
# >=8 reconnect lines (a no-backoff storm, not a one-off blip).
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
  # >=8 reconnect lines = a no-backoff storm. CAPTURE-then-compare (NOT `(( $(grep -c …) ))`):
  # `grep -c` EXITS 1 on a zero count (while printing "0"), and inside a command substitution
  # that exit-1 is NOT AND-OR-exempt — under the inherited `set -E` ERR trap that vz-ai-stack.sh
  # installs, a benign zero-count would fire a spurious "ERR line …" on every healthy install.
  # `|| true` + numeric-validate neutralizes it.
  local _reconnects=0
  _reconnects="$(grep -cE 'log push (stream lost, reconnecting|reconnected \(attempt)' <<<"$logs" 2>/dev/null)" || true
  [[ "$_reconnects" =~ ^[0-9]+$ ]] || _reconnects=0
  (( _reconnects >= 8 )) && return 0
  return 1
}
