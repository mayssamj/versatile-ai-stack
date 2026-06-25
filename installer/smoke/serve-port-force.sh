#!/usr/bin/env bash
# Launcher-level smoke for ensure_port_free + --force on the loopback serve launchers
# (installer/lib/models-serve.sh — same ensure_port_free logic as tutorial-serve.sh).
# Offline + hermetic: models-serve tolerates LiteLLM being down (best-effort key) and is
# forced --read-only here, so no live stack and no mutation. Pins the council-reviewed
# port-handling contract:
#   * a clean port -> the proxy binds + serves /api/health.
#   * a FOREIGN holder WITHOUT --force -> refuse (exit 1), holder left ALIVE.
#   * a FOREIGN holder WITH --force -> killed, port freed, proxy binds (200).
#   * --force on a PRIVILEGED port (<1024) -> refused (exit 2), nothing killed.
# Run: bash installer/smoke/serve-port-force.sh
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"; export AI_STACK
source "$AI_STACK/installer/lib/common.sh"

hdr "Smoke — serve --force / ensure_port_free (offline, hermetic)"
pass=0; fail=0
yes_(){ pass=$((pass+1)); printf '  ✓ %s\n' "$1"; }
no_(){ fail=$((fail+1)); printf '  ✗ %s\n' "$1"; }

SERVE="$AI_STACK/installer/lib/models-serve.sh"
[[ -f "$SERVE" ]] || { no_ "models-serve.sh present"; printf '✗ serve-port-force: launcher missing\n'; exit 1; }
command -v lsof >/dev/null 2>&1 || { echo "lsof unavailable [skip]"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "curl unavailable [skip]"; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo "python3 unavailable [skip]"; exit 0; }

PT=8894            # test port (≥1024, not the 8898 default)
FOREIGN=""; SERVE_PID=""
# free_port: kill EVERY LISTENer on $PT (the launcher runs the python proxy as a CHILD,
# not exec — so killing the bash wrapper alone orphans the proxy; we must kill by port).
free_port(){
  lsof -nP -iTCP:"$PT" -sTCP:LISTEN -t 2>/dev/null | xargs -r kill -9 2>/dev/null || true
  for _ in $(seq 1 20); do lsof -nP -iTCP:"$PT" -sTCP:LISTEN -t >/dev/null 2>&1 || return 0; sleep 0.2; done
}
stop_serve(){ [[ -n "$SERVE_PID" ]] && kill "$SERVE_PID" 2>/dev/null || true; SERVE_PID=""; free_port; }
cleanup(){ stop_serve; [[ -n "$FOREIGN" ]] && kill "$FOREIGN" 2>/dev/null || true; free_port; }
trap cleanup EXIT INT TERM

start_foreign(){ python3 -m http.server "$PT" --bind 127.0.0.1 >/dev/null 2>&1 & FOREIGN=$!; sleep 1; }

free_port   # start from a known-clean port

# 1. clean port -> proxy binds + serves.
bash "$SERVE" --port "$PT" --read-only </dev/null >/tmp/spf_clean.log 2>&1 & SERVE_PID=$!
for _ in $(seq 1 25); do curl -s -H 'Host:127.0.0.1' -o /dev/null "http://127.0.0.1:$PT/api/health" 2>/dev/null && break; sleep 0.2; done
# || true: a refused connection makes curl exit 7, which under `set -e` would abort the
# whole smoke from inside a command substitution. -w prints "000" on failure regardless.
code="$(curl -s -H 'Host:127.0.0.1' -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PT/api/health" 2>/dev/null || true)"
[[ "$code" == "200" ]] && yes_ "clean port -> proxy binds + /api/health 200" || no_ "clean-port serve failed (got $code)"
stop_serve

# 2. FOREIGN holder, NO --force -> refuse (exit 1), holder left alive.
start_foreign
rc=0; bash "$SERVE" --port "$PT" --read-only </dev/null >/tmp/spf_noforce.log 2>&1 || rc=$?
{ [[ "$rc" == "1" ]] && kill -0 "$FOREIGN" 2>/dev/null; } \
  && yes_ "foreign holder + NO --force -> refuse (exit 1), holder untouched" \
  || no_ "no-force should refuse + leave holder (rc=$rc, foreign alive=$(kill -0 "$FOREIGN" 2>/dev/null && echo y || echo n))"
grep -q -- '--force' /tmp/spf_noforce.log && yes_ "refusal message points at --force" || no_ "refusal message missing --force hint"

# 3. FOREIGN holder, WITH --force -> killed, proxy binds.
# Poll until the FOREIGN is gone AND the proxy answers 200 — do NOT break on the first
# HTTP response, because the dying foreign http.server itself answers /api/health with 404
# during the brief takeover window (that false-positive was the original harness bug).
bash "$SERVE" --port "$PT" --read-only --force </dev/null >/tmp/spf_force.log 2>&1 & SERVE_PID=$!
code=""
for _ in $(seq 1 40); do
  kill -0 "$FOREIGN" 2>/dev/null && { sleep 0.25; continue; }   # foreign still up → keep waiting
  code="$(curl -s -H 'Host:127.0.0.1' -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PT/api/health" 2>/dev/null || true)"
  [[ "$code" == "200" ]] && break
  sleep 0.25
done
{ [[ "$code" == "200" ]] && ! kill -0 "$FOREIGN" 2>/dev/null; } \
  && yes_ "foreign holder + --force -> killed + proxy binds (200)" \
  || no_ "--force should kill foreign + bind (code=$code, foreign alive=$(kill -0 "$FOREIGN" 2>/dev/null && echo y || echo n))"
stop_serve; FOREIGN=""

# 4. --force on a PRIVILEGED port (<1024) -> refused (exit 2), nothing started.
rc=0; bash "$SERVE" --port 80 --read-only --force </dev/null >/tmp/spf_priv.log 2>&1 || rc=$?
{ [[ "$rc" == "2" ]] && grep -qi 'privileged' /tmp/spf_priv.log; } \
  && yes_ "--force on privileged port 80 -> refused (exit 2)" || no_ "privileged --force should exit 2 (got $rc)"

echo
if (( fail==0 )); then printf '✓ serve-port-force: %d checks passed\n' "$pass"; exit 0
else printf '✗ serve-port-force: %d passed, %d FAILED\n' "$pass" "$fail"; exit 1; fi
