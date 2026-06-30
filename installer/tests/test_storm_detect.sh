#!/usr/bin/env bash
# test_storm_detect.sh — offline unit test for installer/lib/storm-detect.sh.
# The fake `docker` models REAL `docker logs --since` TIME-FILTERING (a storm line emitted at
# $FAKE_STORM_AT is shown only when it is at/after the resolved --since cutoff), so the test can
# compose StartedAt + storm-timing the way production does — including the skew cases. NO docker,
# NO sandbox, NO model. Run: bash installer/tests/test_storm_detect.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../lib/storm-detect.sh"
# shellcheck disable=SC1090
source "$LIB"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAKE="$TMP/docker"
# Fake docker: `inspect` echoes $FAKE_STARTEDAT; `logs --since <X>` resolves X to an epoch cutoff
# (a bare integer is absolute; "3m" => now-180) and, in `storm` mode, shows the ExpiredSignature
# line ONLY when $FAKE_STORM_AT >= cutoff — exactly how the real daemon filters by timestamp.
cat > "$FAKE" <<'FAKE_DOCKER'
#!/usr/bin/env bash
sub="$1"; shift
case "$sub" in
  inspect) printf '%s\n' "${FAKE_STARTEDAT:-}";;
  logs)
    since=""; while (( $# )); do [[ "$1" == "--since" ]] && since="$2"; shift; done
    now=$(date -u +%s)
    if [[ "$since" =~ ^[0-9]+$ ]]; then cut="$since"; else cut=$(( now - 180 )); fi
    case "${FAKE_LOG_MODE:-clean}" in
      storm)      at="${FAKE_STORM_AT:-$now}"; (( at >= cut )) && echo "invalid token: ExpiredSignature" || echo "ok: serving";;
      refresh)    echo "RefreshSandboxToken returned Unauthenticated";;
      reconnect8) for _ in 1 2 3 4 5 6 7 8 9; do echo "log push stream lost, reconnecting"; done;;
      reconnect3) for _ in 1 2 3; do echo "log push stream lost, reconnecting"; done;;
      clean|*)    echo "ok: serving";;
    esac;;
esac
FAKE_DOCKER
chmod +x "$FAKE"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL+1)); printf '  FAIL %s\n' "$1"; }
iso_at() { local off="$1" e; e=$(( $(date -u +%s) + off )); date -u -r "$e" '+%Y-%m-%dT%H:%M:%S.0Z' 2>/dev/null || date -u -d "@$e" '+%Y-%m-%dT%H:%M:%S.0Z' 2>/dev/null; }
NOW() { date -u +%s; }

echo "== _storm_since_arg (absolute, skew-proof --since) =="
export FAKE_STARTEDAT="$(iso_at -17)"; a="$(_storm_since_arg "$FAKE" cid)"; n="$(NOW)"
{ [[ "$a" =~ ^[0-9]+$ ]] && (( a >= n-30 && a <= n )); } && ok "started 17s ago -> StartedAt epoch (~now-17, got now$((a-n)))" || bad "started 17s -> ~now-17 (got $a, now $n)"
export FAKE_STARTEDAT="$(iso_at -3600)"; a="$(_storm_since_arg "$FAKE" cid)"; n="$(NOW)"
{ [[ "$a" =~ ^[0-9]+$ ]] && (( a >= n-185 && a <= n-175 )); } && ok "started 1h ago -> floored to ~now-180 (got now$((a-n)))" || bad "started 1h -> ~now-180 (got $a, now $n)"
export FAKE_STARTEDAT="$(iso_at 50)"; a="$(_storm_since_arg "$FAKE" cid)"; n="$(NOW)"
{ [[ "$a" =~ ^[0-9]+$ ]] && (( a > n )); } && ok "FUTURE StartedAt (skew) -> future epoch (got now+$((a-n)))" || bad "future StartedAt -> future epoch (got $a, now $n)"
export FAKE_STARTEDAT="not-a-timestamp"; a="$(_storm_since_arg "$FAKE" cid)"
[[ "$a" == "3m" ]] && ok "unparseable StartedAt -> legacy 3m fallback" || bad "unparseable -> 3m (got $a)"

echo "== storm_detect: StartedAt gate excludes PRE-restart stale logs (G2) =="
export FAKE_LOG_MODE=storm
export FAKE_STARTEDAT="$(iso_at -17)" FAKE_STORM_AT="$(( $(NOW) - 50 ))"   # storm was BEFORE the restart
storm_detect "$FAKE" cid; (( $? == 1 )) && ok "just-restarted + only PRE-restart stale storm -> HEALTHY" || bad "stale-pre-restart wrongly flagged"

echo "== storm_detect: future-StartedAt skew does NOT false-positive on stale (the R4 must-fix) =="
export FAKE_STARTEDAT="$(iso_at 50)" FAKE_STORM_AT="$(( $(NOW) - 50 ))"     # VM ahead + pre-restart stale
storm_detect "$FAKE" cid; (( $? == 1 )) && ok "future StartedAt + pre-restart stale -> HEALTHY (no false HALT)" || bad "future-StartedAt skew FALSE-POSITIVE (architect must-fix regressed)"

echo "== storm_detect: genuine storms are still caught (no false-negative) =="
export FAKE_STARTEDAT="$(iso_at -17)" FAKE_STORM_AT="$(( $(NOW) - 5 ))"     # storm AFTER the restart
storm_detect "$FAKE" cid; (( $? == 0 )) && ok "fresh restart + POST-restart storm -> STORM" || bad "post-restart storm missed"
export FAKE_STARTEDAT="$(iso_at -3600)" FAKE_STORM_AT="$(( $(NOW) - 10 ))"  # long-running + recent storm
storm_detect "$FAKE" cid; (( $? == 0 )) && ok "long-running + in-window storm -> STORM" || bad "long-running storm missed"

echo "== storm_detect: a long-healed OLD storm is NOT replayed (bounded floor) =="
export FAKE_STARTEDAT="$(iso_at -3600)" FAKE_STORM_AT="$(( $(NOW) - 300 ))" # storm 5min ago, before the 180s floor
storm_detect "$FAKE" cid; (( $? == 1 )) && ok "old (>180s) healed storm on a long-running container -> HEALTHY" || bad "old storm replayed (window not bounded)"
unset FAKE_STORM_AT

echo "== storm_detect: signature coverage (G3 — all three, one detector) =="
export FAKE_STARTEDAT="$(iso_at -3600)"
export FAKE_LOG_MODE=refresh;    storm_detect "$FAKE" cid; (( $? == 0 )) && ok "RefreshSandboxToken Unauthenticated -> STORM (confirmed)" || bad "RefreshSandboxToken not detected"
export FAKE_LOG_MODE=reconnect8; storm_detect "$FAKE" cid; (( $? == 3 )) && ok ">=8 reconnect lines -> SUSPECTED (rc3, needs corroboration)" || bad ">=8 reconnect not rc3"
export FAKE_LOG_MODE=reconnect3; storm_detect "$FAKE" cid; (( $? == 1 )) && ok "<8 reconnect lines -> healthy" || bad "3 reconnect wrongly flagged"
export FAKE_LOG_MODE=clean;      storm_detect "$FAKE" cid; (( $? == 1 )) && ok "clean logs -> healthy" || bad "clean logs wrongly flagged"

echo "== storm_confirmed: CR-4 — a reconnect-flood is a storm ONLY if the token is really expiring =="
export FAKE_LOG_MODE=reconnect8 FAKE_STARTEDAT="$(iso_at -3600)"
_storm_token_secs_left(){ echo 1800; }   # token VALID -> the flood is an external scan flap
storm_confirmed "$FAKE" cid; (( $? == 1 )) && ok "reconnect-flood + VALID token -> healthy (external flap, NO heal churn)" || bad "valid-token flood wrongly flagged a storm"
_storm_token_secs_left(){ echo 30; }      # token near expiry -> a real storm whose sig scrolled past --tail
storm_confirmed "$FAKE" cid; (( $? == 0 )) && ok "reconnect-flood + NEAR-EXPIRY token -> STORM" || bad "near-expiry flood missed"
_storm_token_secs_left(){ echo -10; }     # already expired
storm_confirmed "$FAKE" cid; (( $? == 0 )) && ok "reconnect-flood + EXPIRED token -> STORM" || bad "expired flood missed"
_storm_token_secs_left(){ return 1; }     # indeterminate (no minter/python3/token)
storm_confirmed "$FAKE" cid; (( $? == 1 )) && ok "reconnect-flood + INDETERMINATE expiry -> healthy (no churn)" || bad "indeterminate flood churned a heal"
unset -f _storm_token_secs_left
export FAKE_LOG_MODE=storm FAKE_STARTEDAT="$(iso_at -17)" FAKE_STORM_AT="$(( $(NOW) - 5 ))"
storm_confirmed "$FAKE" cid; (( $? == 0 )) && ok "confirmed ExpiredSignature -> STORM (pass-through)" || bad "confirmed-storm pass-through failed"
unset FAKE_STORM_AT
export FAKE_LOG_MODE=clean FAKE_STARTEDAT="$(iso_at -3600)"
storm_confirmed "$FAKE" cid; (( $? == 1 )) && ok "clean -> healthy (pass-through)" || bad "clean pass-through failed"

echo "== storm_detect / _storm_bounded: UNKNOWN tri-state on a wedged read (G9) =="
_storm_bounded 1 sleep 5; rc=$?
(( rc == 124 )) && ok "_storm_bounded times out a hung cmd -> 124" || bad "expected 124 on timeout, got $rc"

echo "== storm_detect: no spurious ERR trap on the healthy path under inherited set -E (prod) =="
export FAKE_LOG_MODE=clean FAKE_STARTEDAT="$(iso_at -3600)"
export ERRMARK="$TMP/errfire"; : > "$ERRMARK"
( set -Eeuo pipefail; trap 'echo x >>"$ERRMARK"' ERR; storm_detect "$FAKE" cid || true ) >/dev/null 2>&1 || true
[[ ! -s "$ERRMARK" ]] && ok "healthy path fires NO ERR trap (grep -c exit-1 neutralized)" || bad "ERR trap fired $(wc -l <"$ERRMARK" | tr -d ' ')x"

echo
echo "RESULT: $PASS passed, $FAIL failed"
(( FAIL == 0 ))
