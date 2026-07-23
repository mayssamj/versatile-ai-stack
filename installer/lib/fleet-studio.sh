#!/usr/bin/env bash
# fleet-studio.sh — `mayssam-ai-stack.sh fleet-studio [--port N] [--no-open]`
#
# Serves doc/FLEET.html on a LOOPBACK-ONLY (127.0.0.1) static server and opens
# your browser to it. Fleet Studio reviews + edits every file in agent-profiles/
# (9 personas × 3 frameworks + the shared skill pack + per-fleet docs) by reading
# and writing the REAL files via the browser's File System Access API.
#
# Why a server (vs. just opening the .html)? The File System Access API only
# grants read+WRITE in a "secure context". http://127.0.0.1 is always one; a
# file:// double-click is secure in Chrome but not guaranteed across browsers.
# Serving on localhost makes Save work reliably. NOTE: this server does NOT save
# anything itself — the browser writes files directly; the server only ships the
# static page (so there is no save-endpoint attack surface).
#
# Live read+write needs Chrome or Edge; Safari/Firefox open read-only (the page
# falls back to Download/Copy to save) and say so.
set -Eeuo pipefail
shopt -s inherit_errexit
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# common.sh gives us ok/log/warn/err; tolerate its absence so the tool is usable standalone.
if [[ -f "$AI_STACK/installer/lib/common.sh" ]]; then source "$AI_STACK/installer/lib/common.sh"; else
  ok(){ printf '✓ %s\n' "$*"; }; log(){ printf '… %s\n' "$*"; }; warn(){ printf '! %s\n' "$*" >&2; }; err(){ printf '✗ %s\n' "$*" >&2; }
fi

PORT=8975
DO_OPEN=1
HTML="$AI_STACK/doc/FLEET.html"
DOCROOT="$AI_STACK/doc"

while (( $# )); do
  case "$1" in
    --port=*)  PORT="${1#*=}" ;;
    --port)    shift; PORT="${1:-8975}" ;;
    --no-open) DO_OPEN=0 ;;
    -h|--help)
      cat <<EOF
mayssam-ai-stack.sh fleet-studio [--port N] [--no-open]
  Serve doc/FLEET.html on http://127.0.0.1:N and open it in your browser to
  review + edit every file in agent-profiles/ (writes go straight to disk via
  the browser's File System Access API — Chrome/Edge for live editing).
  --port N    loopback port (default 8975)
  --no-open   start the server but don't auto-open a browser
EOF
      exit 0 ;;
    *) err "unknown argument: $1 (try --help)"; exit 2 ;;
  esac
  shift
done

{ [[ "$PORT" =~ ^[0-9]+$ ]] && (( PORT >= 1 && PORT <= 65535 )); } || { err "invalid --port '$PORT' (expected 1-65535)"; exit 2; }
[[ -f "$HTML" ]] || { err "doc/FLEET.html not found at $HTML"; exit 1; }

URL="http://127.0.0.1:${PORT}/FLEET.html"

open_url() {  # prefer a Chromium browser (live read+write); fall back to default.
  local u="$1"
  open -a "Google Chrome" "$u" 2>/dev/null && return 0
  open -a "Microsoft Edge" "$u" 2>/dev/null && return 0
  open -a "Chromium" "$u" 2>/dev/null && return 0
  open "$u" 2>/dev/null && { warn "opened your default browser — for live editing use Chrome or Edge"; return 0; }
  warn "couldn't auto-open a browser; visit $URL manually"
}

ok "Fleet Studio → ${URL}"
log "loopback-only · serving doc/ · Ctrl-C to stop  (live read+write needs Chrome/Edge)"
if (( DO_OPEN )); then
  # Open the browser only once the server is actually listening — don't pop a dead tab
  # if the bind failed (e.g. port in use). Polls 127.0.0.1:PORT via bash /dev/tcp (~5s max).
  ( for _ in $(seq 1 50); do
      if (exec 3<>"/dev/tcp/127.0.0.1/${PORT}") 2>/dev/null; then exec 3>&- 3<&-; open_url "$URL"; exit 0; fi
      sleep 0.1
    done ) &
fi

# Loopback static server with no-store headers (so reloads are always fresh) and
# silenced request logging. directory= keeps it scoped to doc/ — nothing else on
# disk is exposed. Binds 127.0.0.1 only (never 0.0.0.0).
FS_PORT="$PORT" FS_ROOT="$DOCROOT" exec python3 - <<'PY'
import os, sys, functools, http.server
port = int(os.environ["FS_PORT"]); root = os.environ["FS_ROOT"]
class H(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cache-Control", "no-store")
        super().end_headers()
    def log_message(self, *a):  # quiet
        pass
Handler = functools.partial(H, directory=root)
try:
    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler)
except OSError as e:
    sys.stderr.write(f"✗ cannot bind 127.0.0.1:{port} ({e}); try --port <other>\n"); sys.exit(1)
try:
    httpd.serve_forever()
except KeyboardInterrupt:
    sys.stderr.write("\n")
PY
