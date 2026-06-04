#!/usr/bin/env python3
"""tutorial_proxy.py — the safe 'Try it live' backend for doc/TUTORIAL.html.

Serves the tutorial page AND a tiny, ROUTE-ALLOWLISTED reverse proxy to LiteLLM
that injects an ephemeral, local-only, short-TTL virtual key SERVER-SIDE. The
browser never sees a key. Bound to loopback only. Launched by
installer/lib/tutorial-serve.sh (which mints the key + sets the env below).

Env:
  TUT_PORT        loopback port to bind (default 8899)
  TUT_LITELLM     LiteLLM base URL (default http://127.0.0.1:4000)
  TUT_KEY_FILE    path to a 0600 file holding the ephemeral virtual key (PREFERRED —
                  keeps the secret out of the process environment / `ps`)
  TUT_KEY         the ephemeral virtual key inline (deprecated fallback; avoid — it
                  leaks via `ps`. Use TUT_KEY_FILE instead). Injected, never exposed.
  TUT_HTML        absolute path to doc/TUTORIAL.html
  TUT_ROOT        repo root; doc/img/css files under it are served read-only so the
                  page's own relative links (../README.md, EXPLORE.html, …) resolve
  TUT_MODELS      comma-separated allowlist echoed to the page (display only;
                  LiteLLM enforces the real allowlist server-side via the key)
"""
import json, os, posixpath, sys, urllib.parse, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT     = int(os.environ.get("TUT_PORT", "8899"))
LITELLM  = os.environ.get("TUT_LITELLM", "http://127.0.0.1:4000").rstrip("/")
KEY      = os.environ.get("TUT_KEY", "")
# Prefer reading the key from a 0600 file (TUT_KEY_FILE) so it never appears in
# the process environment / `ps` output. The launcher passes the file path, not
# the secret. Falls back to TUT_KEY for compatibility.
_KEY_FILE = os.environ.get("TUT_KEY_FILE", "")
if _KEY_FILE and os.path.isfile(_KEY_FILE):
    try:
        with open(_KEY_FILE, "r", encoding="utf-8") as _kf:
            KEY = _kf.read().strip()
    except OSError:
        pass
HTML     = os.environ.get("TUT_HTML", "")
ROOT     = os.path.realpath(os.environ.get("TUT_ROOT", "")) if os.environ.get("TUT_ROOT") else ""
MODELS   = [m for m in os.environ.get("TUT_MODELS", "local-gemma4").split(",") if m]

# The page's canonical served path = its location under the repo root, so the
# relative links inside it (EXPLORE.html, ../README.md, …) resolve correctly.
PAGE_ROUTE = "/"
if ROOT and HTML:
    _rel = os.path.relpath(os.path.realpath(HTML), ROOT)
    if not _rel.startswith(".."):
        PAGE_ROUTE = "/" + _rel.replace(os.sep, "/")

# Static serving is intentionally NARROW: docs/images/css only. NO .env, .sh,
# .py, .yml, .json, no dotfiles, no path escaping the repo root. This server is
# loopback-bound, but we still refuse to hand out anything secret-bearing.
STATIC_TYPES = {
    ".html": "text/html; charset=utf-8", ".htm": "text/html; charset=utf-8",
    ".md": "text/markdown; charset=utf-8", ".markdown": "text/markdown; charset=utf-8",
    ".txt": "text/plain; charset=utf-8", ".css": "text/css; charset=utf-8",
    ".svg": "image/svg+xml", ".png": "image/png", ".jpg": "image/jpeg",
    ".jpeg": "image/jpeg", ".gif": "image/gif", ".ico": "image/x-icon",
    ".webp": "image/webp",
}

# Route allowlist: (method, path) -> upstream LiteLLM path. DENY everything else.
# Read-only + chat only; no /key/*, no admin, no destructive verbs.
ROUTES = {
    ("GET",  "/api/models"): "/v1/models",
    ("POST", "/api/chat"):   "/v1/chat/completions",
}
MAX_BODY = 64 * 1024  # cap request bodies (the demo only needs small prompts)


def _cors(h):
    h.send_header("Access-Control-Allow-Origin", "*")  # loopback-bound; localhost only
    h.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    h.send_header("Access-Control-Allow-Headers", "Content-Type")


class H(BaseHTTPRequestHandler):
    server_version = "tutorial-proxy/1.0"

    def log_message(self, *a):  # quiet
        pass

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); _cors(self)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)

    def do_OPTIONS(self):
        self.send_response(204); _cors(self); self.end_headers()

    def do_GET(self):
        path = urllib.parse.unquote(self.path.split("?", 1)[0])
        if path == "/api/health":
            return self._json(200, {"ok": True, "models": MODELS})
        if ("GET", path) in ROUTES:
            return self._proxy("GET", ROUTES[("GET", path)], None)
        # Root + aliases -> redirect to the page's canonical path so its relative
        # links (EXPLORE.html, ../README.md, …) resolve against /doc/.
        if path in ("/", "/index.html", "/tutorial", "/TUTORIAL.html"):
            if PAGE_ROUTE != "/":
                return self._redirect(PAGE_ROUTE)
            return self._serve_html()
        # Otherwise try to serve a doc/image/css file from the repo root (narrow).
        if self._serve_static(path):
            return
        self._json(404, {"error": "not found (tutorial proxy serves the tutorial page, "
                                  "doc/image/css files, and a tiny /api allowlist)"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if ("POST", path) not in ROUTES:
            return self._json(404, {"error": f"route not allowed: POST {path}"})
        try:
            n = int(self.headers.get("Content-Length", 0) or 0)
        except (ValueError, TypeError):
            return self._json(400, {"error": "invalid Content-Length"})
        if n < 0 or n > MAX_BODY:
            return self._json(413, {"error": "request too large"})
        body = self.rfile.read(n) if n else b""
        self._proxy("POST", ROUTES[("POST", path)], body)

    def _serve_html(self):
        if not HTML or not os.path.isfile(HTML):
            return self._json(503, {"error": "TUTORIAL.html not found; build it first"})
        with open(HTML, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")   # tutorial is regenerated; never serve stale
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)

    def _redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _serve_static(self, path):
        """Serve a doc/image/css file from the repo root, read-only. Returns True
        if handled. Refuses anything outside the root, any dotfile component, and
        any non-allowlisted extension — so secrets (.env, keys, .git) never leak."""
        if not ROOT:
            return False
        if "\x00" in path:                            # null byte -> reject (realpath would raise)
            return False
        rel = posixpath.normpath(path.lstrip("/"))
        if not rel or rel == "." or rel.startswith("..") or os.path.isabs(rel):
            return False
        parts = rel.split("/")
        if any(p.startswith(".") for p in parts):   # no dotfiles / dotdirs
            return False
        ext = os.path.splitext(rel)[1].lower()
        ctype = STATIC_TYPES.get(ext)
        if not ctype:                                # extension allowlist
            return False
        full = os.path.realpath(os.path.join(ROOT, rel))
        if os.path.commonpath([ROOT, full]) != ROOT:  # containment (blocks symlink/.. escape)
            return False
        if not os.path.isfile(full):
            return False
        try:
            with open(full, "rb") as f:
                data = f.read()
        except OSError:
            return False
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")   # docs/assets are regenerated; revalidate
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers(); self.wfile.write(data)
        return True

    def _proxy(self, method, upstream_path, body):
        req = urllib.request.Request(
            LITELLM + upstream_path, data=body, method=method,
            headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                data = r.read(); code = r.status
        except urllib.error.HTTPError as e:
            data = e.read() or json.dumps({"error": f"upstream {e.code}"}).encode(); code = e.code
        except Exception as e:
            return self._json(502, {"error": f"proxy could not reach LiteLLM: {e}"})
        self.send_response(code); _cors(self)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)


def main():
    if not KEY:
        print("tutorial_proxy: TUT_KEY not set (the launcher mints it)", file=sys.stderr); sys.exit(2)
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    print(f"tutorial-serve: http://127.0.0.1:{PORT}  (Ctrl-C to stop + auto-revoke the demo key)")
    print(f"  demo key allowlisted to {len(MODELS)} wired model(s); cloud/subscription routes are budget-capped")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
