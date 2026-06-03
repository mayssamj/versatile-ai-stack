#!/usr/bin/env python3
"""tutorial_proxy.py — the safe 'Try it live' backend for doc/TUTORIAL.html.

Serves the tutorial page AND a tiny, ROUTE-ALLOWLISTED reverse proxy to LiteLLM
that injects an ephemeral, local-only, short-TTL virtual key SERVER-SIDE. The
browser never sees a key. Bound to loopback only. Launched by
installer/lib/tutorial-serve.sh (which mints the key + sets the env below).

Env:
  TUT_PORT        loopback port to bind (default 8899)
  TUT_LITELLM     LiteLLM base URL (default http://127.0.0.1:4000)
  TUT_KEY         the ephemeral virtual key (Bearer) — injected, never exposed
  TUT_HTML        absolute path to doc/TUTORIAL.html
  TUT_MODELS      comma-separated allowlist echoed to the page (display only;
                  LiteLLM enforces the real allowlist server-side via the key)
"""
import json, os, sys, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT     = int(os.environ.get("TUT_PORT", "8899"))
LITELLM  = os.environ.get("TUT_LITELLM", "http://127.0.0.1:4000").rstrip("/")
KEY      = os.environ.get("TUT_KEY", "")
HTML     = os.environ.get("TUT_HTML", "")
MODELS   = [m for m in os.environ.get("TUT_MODELS", "local-gemma4").split(",") if m]

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
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html", "/tutorial", "/TUTORIAL.html"):
            return self._serve_html()
        if path == "/api/health":
            return self._json(200, {"ok": True, "models": MODELS})
        if ("GET", path) in ROUTES:
            return self._proxy("GET", ROUTES[("GET", path)], None)
        self._json(404, {"error": "not found (tutorial proxy only serves / and an /api allowlist)"})

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if ("POST", path) not in ROUTES:
            return self._json(404, {"error": f"route not allowed: POST {path}"})
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n > MAX_BODY:
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
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)

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
    print(f"  live demos use local models only: {', '.join(MODELS)}")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
