#!/usr/bin/env bash
# test_storm_detect.sh — offline unit test for installer/lib/storm-detect.sh.
# NO docker, NO sandbox, NO model: a fake `docker` script feeds storm_detect
# controlled StartedAt + logs so we can prove the StartedAt window gate (G2),
# the signature coverage (G3), and the UNKNOWN tri-state (G9) without any live
# state. Run: bash installer/tests/test_storm_detect.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/storm-detect.sh"
# shellcheck disable=SC1090
source "$LIB"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/docker"
# Fake docker: honors `inspect -f … <cid>` (echo $FAKE_STARTEDAT) and
# `logs <cid> --since <W>s --tail N` (output keyed by $FAKE_LOG_MODE + window W).
cat > "$FAKE" <<'FAKE_DOCKER'
#!/usr/bin/env bash
sub="$1"; shift
case "$sub" in
  inspect) printf '%s\n' "${FAKE_STARTEDAT:-}";;
  logs)
    win=180
    while (( $# )); do [[ "$1" == "--since" ]] && { win="${2%s}"; }; shift; done
    case "${FAKE_LOG_MODE:-clean}" in
      stale)      (( win >= 30 )) && echo "invalid token: ExpiredSignature" || echo "ok: log push reconnected";;
      active)     echo "invalid token: ExpiredSignature";;
      refresh)    echo "RefreshSandboxToken returned Unauthenticated";;
      reconnect8) for _ in 1 2 3 4 5 6 7 8 9; do echo "log push stream lost, reconnecting"; done;;
      reconnect3) for _ in 1 2 3; do echo "log push stream lost, reconnecting"; done;;
      clean|*)    echo "ok: serving";;
    esac;;
  *) : ;;
esac
FAKE_DOCKER
chmod +x "$FAKE"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
iso_ago() { local s="$1"; date -u -r "$(( $(date -u +%s) - s ))" '+%Y-%m-%dT%H:%M:%S.000000000Z' 2>/dev/null \
            || date -u -d "@$(( $(date -u +%s) - s ))" '+%Y-%m-%dT%H:%M:%S.000000000Z' 2>/dev/null; }

echo "== _storm_window_secs (G2 clamp) =="
export FAKE_STARTEDAT="$(iso_ago 17)"
w="$(_storm_window_secs "$FAKE" cid)"
{ [[ "$w" =~ ^[0-9]+$ ]] && (( w >= 10 && w <= 40 )); } && ok "started 17s ago -> window ~17 (got $w)" || bad "started 17s ago -> window ~17 (got $w)"
export FAKE_STARTEDAT="$(iso_ago 3600)"
w="$(_storm_window_secs "$FAKE" cid)"
(( w == 180 )) && ok "started 1h ago -> window clamped to 180 (got $w)" || bad "started 1h ago -> window clamped to 180 (got $w)"
export FAKE_STARTEDAT="not-a-timestamp"
w="$(_storm_window_secs "$FAKE" cid)"
(( w == 180 )) && ok "unparseable StartedAt -> legacy 180 fallback (got $w)" || bad "unparseable StartedAt -> legacy 180 (got $w)"

echo "== storm_detect: StartedAt gate flips a STALE post-heal verdict (G2, the BLOCKER) =="
export FAKE_LOG_MODE=stale
export FAKE_STARTEDAT="$(iso_ago 17)"     # just-restarted: stale ExpiredSignature is PRE-restart
storm_detect "$FAKE" cid; rc=$?
(( rc == 1 )) && ok "fresh restart + only stale pre-restart signature -> HEALTHY (rc1)" || bad "expected healthy(1) on stale-only post-heal, got $rc"
export FAKE_STARTEDAT="$(iso_ago 3600)"   # long-running: same stale lines are now in-window
storm_detect "$FAKE" cid; rc=$?
(( rc == 0 )) && ok "long-running + in-window signature -> STORM (rc0)" || bad "expected storm(0) for in-window signature, got $rc"

echo "== storm_detect: a genuine POST-restart storm is still caught (no false-negative) =="
export FAKE_LOG_MODE=active
export FAKE_STARTEDAT="$(iso_ago 17)"
storm_detect "$FAKE" cid; rc=$?
(( rc == 0 )) && ok "fresh restart + ongoing signature -> STORM (rc0)" || bad "expected storm(0) for post-restart storm, got $rc"

echo "== storm_detect: signature coverage (G3 — all three, in one detector) =="
export FAKE_STARTEDAT="$(iso_ago 3600)"
export FAKE_LOG_MODE=refresh;    storm_detect "$FAKE" cid; (( $? == 0 )) && ok "RefreshSandboxToken Unauthenticated -> STORM" || bad "RefreshSandboxToken not detected"
export FAKE_LOG_MODE=reconnect8; storm_detect "$FAKE" cid; (( $? == 0 )) && ok ">=8 reconnect lines -> STORM" || bad ">=8 reconnect not detected"
export FAKE_LOG_MODE=reconnect3; storm_detect "$FAKE" cid; (( $? == 1 )) && ok "<8 reconnect lines -> healthy (no false positive)" || bad "3 reconnect wrongly flagged"
export FAKE_LOG_MODE=clean;      storm_detect "$FAKE" cid; (( $? == 1 )) && ok "clean logs -> healthy" || bad "clean logs wrongly flagged"

echo "== storm_detect / _storm_bounded: UNKNOWN tri-state on a wedged read (G9) =="
_storm_bounded 1 sleep 5; rc=$?
(( rc == 124 )) && ok "_storm_bounded times out a hung cmd -> 124" || bad "expected 124 on timeout, got $rc"

echo "== storm_detect: no spurious ERR trap on the healthy path under inherited set -E (prod) =="
# vz-ai-stack.sh installs `trap … ERR`; set -E inherits it into storm_detect. `grep -c` exits
# 1 on a zero count, and inside `(( $(grep -c …) ))` that benign zero used to FIRE the trap on
# every healthy install. Regression-guard: run under the same trap shape, assert it never fires.
export FAKE_LOG_MODE=clean FAKE_STARTEDAT="$(iso_ago 3600)"
export ERRMARK="$TMP/errfire"; : > "$ERRMARK"
( set -Eeuo pipefail; trap 'echo x >>"$ERRMARK"' ERR; storm_detect "$FAKE" cid || true ) >/dev/null 2>&1 || true
[[ ! -s "$ERRMARK" ]] && ok "healthy path fires NO ERR trap (grep -c exit-1 neutralized)" || bad "ERR trap fired $(wc -l <"$ERRMARK" | tr -d ' ')x on healthy path"

echo
echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
