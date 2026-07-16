#!/usr/bin/env bash
# start-paperclip.sh — daemonize Paperclip's `pnpm dev` on :3100.
#
# Not a docker container — Paperclip is a Node.js monorepo cloned to
# ~/ai-stack/tools/paperclip. `pnpm dev` is the canonical entrypoint
# (per upstream README); it serves the API + UI at http://localhost:3100,
# auto-provisions an embedded PostgreSQL, and watches files.
#
# This script makes it a background process with a PID file under
# installer/state/, so Phase 08 can auto-start it and a re-run is a
# no-op when the daemon is already healthy.
#
# Idempotency: refuses to start a second copy. PID-recycle-safe: confirms
# the process command line contains 'paperclip' before trusting the file.
set -Eeuo pipefail

if (( BASH_VERSINFO[0] < 5 )); then
  for b in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$b" ]] && exec "$b" "$0" "$@"
  done
  echo "bin/start-paperclip.sh: needs bash 5+" >&2; exit 2
fi

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/validate.sh"

PC_DIR="$AI_STACK/tools/paperclip"
PID_FILE="$STATE_DIR/paperclip.pid"
LOG_FILE="$STATE_DIR/paperclip.log"
PORT=3100

# Probe the upstream-documented health endpoint, not the UI root.
# Accept any non-000 code as "server is alive" — startup may transiently
# return 404 or 5xx before the route table is loaded.
HEALTH_URL="http://127.0.0.1:${PORT}/api/health"
http_ok() {
  # curl -w '%{http_code}' ALREADY emits 000 on a connection failure/timeout AND exits
  # non-zero. The old `... || echo 000` inside the substitution APPENDED a second 000 →
  # "000000", which `!= "000"` read as HEALTHY for a dead server. Put the fallback in a
  # separate assignment (`|| code=000`) so it never concatenates, and keep set -e happy.
  # (2026-07-05 takeover fix; same idiom the repo already uses in doctor check 40.)
  local code; code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$1" 2>/dev/null) || code=000
  [[ "$code" =~ ^[0-9]{3}$ && "$code" != "000" ]]
}

[[ -d "$PC_DIR" ]]               || { err "paperclip source missing at $PC_DIR — run phase 08 first."; exit 1; }
[[ -f "$PC_DIR/package.json" ]]  || { err "paperclip package.json missing — clone may be incomplete."; exit 1; }
command -v pnpm >/dev/null       || { err "pnpm not on PATH — run phase 00 first."; exit 1; }

# --- Process identity check (kill -0 isn't enough; PIDs recycle after reboot)
pid_is_ours() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # Match the `pnpm dev` parent OR any tsx/node child under our PC_DIR. Use
  # `ps -o args` (BSD ps on macOS); look for any process whose command line
  # mentions our specific paperclip path. This avoids matching other people's
  # paperclips on the same machine.
  ps -p "$pid" -o args= 2>/dev/null | grep -qF "$PC_DIR" && return 0
  # The `pnpm dev` PARENT's argv is just "pnpm dev" (it's started with cwd=PC_DIR but
  # PC_DIR isn't in argv), so we still match it — but ONLY when its working directory
  # is PC_DIR. The old bare `pnpm.*dev`/`paperclip` fallback matched ANY project's
  # `pnpm dev` (or any process merely mentioning "paperclip"), so a recycled PID
  # running an unrelated dev server was classified "ours" and the restart path SIGTERM'd
  # it. Anchoring to the cwd removes that cross-project kill. (2026-07-05 takeover fix.)
  if ps -p "$pid" -o args= 2>/dev/null | grep -qE 'pnpm.*dev'; then
    # lsof -Fn emits the cwd as a single `n<path>` line (machine format), so this is
    # space-safe even if AI_STACK is cloned under a path containing spaces — unlike a
    # column-split parse. Missing lsof / no match → empty → not ours (fail-safe: fewer
    # kills, never a wrong one). (2026-07-05 takeover fix; §24-hardened.)
    local cwd; cwd="$(lsof -a -d cwd -p "$pid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)"
    [[ -n "$cwd" && "$cwd" == "$PC_DIR" ]] && return 0
  fi
  return 1
}

# --- Alias relay: 127.0.10.14:3100 → 127.0.0.1:3100 (paperclip's actual bind)
# Paperclip binds 127.0.0.1 only in loopback mode. The /etc/hosts alias
# `paperclip → 127.0.10.14` would dead-end without this small forwarder.
# In loopback mode paperclip's hostname allowlist is NOT enforced, so
# relay-forwarded requests with `Host: paperclip:3100` pass through.
RELAY_PID_FILE="$STATE_DIR/paperclip-relay.pid"
RELAY_LOG_FILE="$STATE_DIR/paperclip-relay.log"
RELAY_BIND=127.0.10.14

relay_running() {
  local p; p=$(cat "$RELAY_PID_FILE" 2>/dev/null || echo "")
  [[ "$p" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$p" 2>/dev/null || return 1
  ps -p "$p" -o args= 2>/dev/null | grep -qF "paperclip-relay" || return 1
  return 0
}

ensure_relay() {
  if relay_running; then
    log "alias relay $RELAY_BIND:$PORT → 127.0.0.1:$PORT already running (pid $(cat "$RELAY_PID_FILE"))"
    return 0
  fi
  install -m 600 /dev/null "$RELAY_LOG_FILE"
  log "Starting alias relay $RELAY_BIND:$PORT → 127.0.0.1:$PORT..."
  # `paperclip-relay` tag in argv[1] so the PID-recycle ps-match works.
  nohup node -e '
    const net = require("net");
    const [, , listenHost, listenPort, targetHost, targetPort] = process.argv;
    const server = net.createServer((src) => {
      const dst = net.connect(Number(targetPort), targetHost);
      src.on("error", () => dst.destroy()); dst.on("error", () => src.destroy());
      src.pipe(dst); dst.pipe(src);
    });
    server.listen(Number(listenPort), listenHost, () => {
      console.log(`paperclip-relay listening ${listenHost}:${listenPort} → ${targetHost}:${targetPort}`);
    });
  ' paperclip-relay "$RELAY_BIND" "$PORT" 127.0.0.1 "$PORT" \
      >> "$RELAY_LOG_FILE" 2>&1 &
  echo $! > "$RELAY_PID_FILE"
  sleep 1
  if relay_running; then
    ok "alias relay up: http://paperclip:$PORT/ → http://127.0.0.1:$PORT/"
  else
    warn "alias relay failed to start — see $RELAY_LOG_FILE"
    rm -f "$RELAY_PID_FILE"
  fi
}

# --- --recreate / restart: stop the pidfile-owned daemon FIRST, then fall
# through to the normal idempotent start below. The upgrade funnel's verified-
# recycle contract needs a REAL recycle: without this arm the script was a
# healthy no-op exit 0 after a git-pull upgrade, so the daemon kept running
# stale code while the summary said 'upgraded' (council R2a, 2026-07-15).
# _stop_own_relay — stop OUR alias relay (via RELAY_PID_FILE, liveness-checked).
# The relay outlives the app on every crash/kill; both the recreate arm and the
# foreign-port refusal must treat it as OURS, never as a foreign owner
# (refusing our own component stranded the daemon down twice on 2026-07-16).
# ensure_relay re-establishes it after the app is up.
_stop_own_relay() {
  local rp
  [[ -f "$RELAY_PID_FILE" ]] || return 0
  rp="$(cat "$RELAY_PID_FILE" 2>/dev/null || echo "")"
  if [[ "$rp" =~ ^[0-9]+$ ]] && kill -0 "$rp" 2>/dev/null; then
    # IDENTITY before kill (PID-recycle safety, same standard as relay_running/
    # pid_is_ours): a stale pidfile whose PID was recycled to a foreign process
    # must fall through to the foreign-owner refusal, never be killed here.
    if ps -p "$rp" -o args= 2>/dev/null | grep -qF "paperclip-relay"; then
      kill "$rp" 2>/dev/null || true; sleep 1
      if kill -0 "$rp" 2>/dev/null; then kill -9 "$rp" 2>/dev/null || true; fi
    fi
  fi
  rm -f "$RELAY_PID_FILE"
  return 0
}

# _reap_dev_tree — kill SURVIVING members of paperclip's dev process tree:
# upstream's dev-runner ('paperclip-dev-watch') outlives a killed parent and
# makes the next `pnpm dev` REFUSE to start ('already running'), and it does
# NOT listen on :3100 so the port drain can't see it (live-caught twice,
# 2026-07-16). Identity anchor: node/pnpm processes whose CWD is under OUR
# clone — a foreign node can never match, though clone-cwd'd dev tooling
# (an IDE's tsserver opened on the clone) is accepted recreate collateral.
_reap_dev_tree() {
  local _wp _wcwd _survivors
  _survivors="$( { pgrep -x node; pgrep -f pnpm; } 2>/dev/null | sort -u || true )"
  for _wp in $_survivors; do
    _wcwd="$(lsof -a -d cwd -p "$_wp" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true)"
    if [[ -n "$_wcwd" && "$_wcwd" == "$PC_DIR"* ]]; then kill "$_wp" 2>/dev/null || true; fi
  done
  sleep 2
  for _wp in $_survivors; do
    kill -0 "$_wp" 2>/dev/null || continue
    _wcwd="$(lsof -a -d cwd -p "$_wp" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true)"
    if [[ -n "$_wcwd" && "$_wcwd" == "$PC_DIR"* ]]; then kill -9 "$_wp" 2>/dev/null || true; fi
  done
  return 0
}

if [[ "${1:-}" == "--recreate" || "${1:-}" == "restart" ]]; then
  if [[ -f "$PID_FILE" ]]; then
    _rpid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
    if pid_is_ours "$_rpid"; then
      log "recreate: stopping paperclip (pid $_rpid)"
      kill "$_rpid" 2>/dev/null || true
      _i=0
      while (( _i < 10 )) && kill -0 "$_rpid" 2>/dev/null; do sleep 1; _i=$((_i+1)); done
      if kill -0 "$_rpid" 2>/dev/null; then kill -9 "$_rpid" 2>/dev/null || true; sleep 1; fi
    fi
    rm -f "$PID_FILE"
  fi
  _stop_own_relay
  _reap_dev_tree
  # pnpm dev's node child can outlive its parent and keep :3100 bound — the
  # fresh start below would then refuse ("port owned by someone else"). Drain:
  # kill a lingering listener ONLY if its cwd is OUR clone (same anchor as
  # pid_is_ours — never a foreign process that happens to own the port).
  # TERM first, then KILL — a dev server that shrugs off SIGTERM (observed
  # live) must not outlast the bounded drain window.
  _i=0
  while (( _i < 8 )) && port_listening "$PORT"; do
    _lpid="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
    if [[ "$_lpid" =~ ^[0-9]+$ ]]; then
      _lcwd="$(lsof -a -d cwd -p "$_lpid" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1 || true)"
      if [[ -n "$_lcwd" && "$_lcwd" == "$PC_DIR"* ]]; then
        if (( _i < 4 )); then kill "$_lpid" 2>/dev/null || true; else kill -9 "$_lpid" 2>/dev/null || true; fi
      fi
    fi
    sleep 1; _i=$((_i+1))
  done
fi

# --- Already running + serving? Then no-op (idempotent re-entry).
if [[ -f "$PID_FILE" ]]; then
  pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
  if pid_is_ours "$pid"; then
    if port_listening "$PORT"; then
      # Also confirm HTTP serves (the pnpm dev process may be alive but
      # mid-build; treat half-up as "needs restart").
      if http_ok "$HEALTH_URL"; then
        ensure_relay
        ok "paperclip already running (pid $pid, http://paperclip:$PORT)"
        exit 0
      fi
      log "paperclip pid $pid alive + port bound but $HEALTH_URL silent — letting it settle 8s..."
      i=0
      while (( i < 8 )); do
        if http_ok "$HEALTH_URL"; then
          ensure_relay
          ok "paperclip ready after grace"
          exit 0
        fi
        sleep 1; i=$((i+1))
      done
      warn "paperclip alive but not serving after grace — killing + restarting"
      kill "$pid" 2>/dev/null || true
      sleep 2
    else
      warn "stale paperclip pid $pid alive but not bound to :$PORT — killing + restarting"
      kill "$pid" 2>/dev/null || true
      sleep 1
    fi
  else
    # PID is stale or recycled to a different process — clear and continue.
    rm -f "$PID_FILE"
  fi
fi

# --- Port owned by someone else? OUR relay is not "someone else": when the app
# dies the relay survives and holds :3100 — stop it (identity via its pidfile)
# and proceed; ensure_relay re-establishes it after the app is up. Refuse only
# genuinely-foreign owners.
if port_listening "$PORT"; then
  _lp="$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | head -1 || true)"
  _rlp="$(cat "$RELAY_PID_FILE" 2>/dev/null || echo "")"
  if [[ -n "$_lp" && "$_lp" == "$_rlp" ]]; then
    log "own alias relay holds :$PORT (app died under it) — recycling the relay"
    _stop_own_relay; sleep 1
  fi
fi
if port_listening "$PORT"; then
  err "Port :$PORT is bound by another process (not the previous paperclip)."
  err "Inspect: lsof -nP -iTCP:$PORT -sTCP:LISTEN"
  exit 1
fi

# --- Start fresh. Truncate log under 0600 so any incidentally-logged secrets
# (Paperclip's own DB password is auto-generated; we don't pass our .env in)
# aren't world-readable.
install -m 600 /dev/null "$LOG_FILE"

# Paperclip's "trusted local loopback" mode (the upstream-recommended path)
# binds 127.0.0.1:3100 only AND bypasses the auth gate for loopback
# connections — no user/company setup needed. Engaging any non-loopback
# bind (0.0.0.0, LAN, custom) flips Paperclip to authenticated mode where
# every visitor needs a company-membership user provisioned via
# `paperclipai onboard`. We pick the simpler, working path.
log "Starting paperclip via 'pnpm dev' on 127.0.0.1:$PORT (loopback, auth-bypass mode)..."
(
  cd "$PC_DIR"
  # No env flags = paperclip default (loopback). Just run pnpm dev.
  nohup pnpm dev >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
) </dev/null

ensure_relay

sleep 2
pid="$(cat "$PID_FILE" 2>/dev/null || echo "")"
if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
  err "paperclip failed to start. Last 20 log lines:"
  tail -n 20 "$LOG_FILE" >&2 || true
  exit 1
fi

# --- Wait for the port to come up (first build is 30-90s; allow 180s).
log "Waiting for paperclip to bind :$PORT (first build can take 60-120s)..."
i=0
while (( i < 180 )); do
  if port_listening "$PORT" && http_ok "$HEALTH_URL"; then
    ok "paperclip running (pid $pid, http://paperclip:$PORT/, $HEALTH_URL reachable)"
    exit 0
  fi
  sleep 1
  i=$((i+1))
done

err "paperclip pid $pid alive but :$PORT didn't bind / serve in 180s. Last log lines:"
tail -n 30 "$LOG_FILE" >&2 || true
exit 1
