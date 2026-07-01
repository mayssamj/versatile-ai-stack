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
  TUT_LAUNCH      "1" enables POST /api/launch (idempotently start a watchable
                  web-UI service so the page can open it). Any other value / unset
                  disables it AND the route is not handled at all (transport-layer
                  404). Set only by `tutorial-serve --launch-enabled` (default OFF).
  TUT_PHOENIX     phoenix UI base URL (e.g. http://phoenix:6006). Empty -> the
                  read-only GET /api/traces demo degrades to {available:false}.
  TUT_PHOENIX_KEY optional Phoenix API key (auth is OFF in this build; passed
                  server-side only if set — the browser never sees it).
"""
import json, os, posixpath, socket, subprocess, sys, threading
import urllib.parse, urllib.request, urllib.error
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
MODELS   = [m for m in os.environ.get("TUT_MODELS", "local").split(",") if m]
EMBED    = os.environ.get("TUT_EMBED", "")   # embedding model id for the /api/embed demo (echoed by /api/health)
# Two READ-ONLY 'Try it live' upstreams beyond LiteLLM (empty -> that demo is disabled and
# its route degrades to {available:false}). Set by tutorial-serve.sh from .env. The proxy only
# ever GET/POSTs FIXED paths on these (see the literals below); the browser never supplies a
# workspace / collection / host, so neither is an SSRF or namespace-traversal sink.
HONCHO   = os.environ.get("TUT_HONCHO", "").rstrip("/")   # honcho-api base for the memory demo
QDRANT   = os.environ.get("TUT_QDRANT", "").rstrip("/")   # qdrant base for the docs-search demo
PHOENIX  = os.environ.get("TUT_PHOENIX", "").rstrip("/")  # phoenix UI base for the read-only traces demo
# Phoenix auth is OFF in this build (loopback-only, PHOENIX_ENABLE_AUTH=false). If a key IS set we
# pass it through server-side so an auth-on box still works; the browser never sees it.
PHOENIX_KEY = os.environ.get("TUT_PHOENIX_KEY", "")

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
    ".woff2": "font/woff2", ".woff": "font/woff",   # self-hosted design-system fonts
}

# Route allowlist: (method, path) -> upstream LiteLLM path. DENY everything else.
# Read-only + chat only; no /key/*, no admin, no destructive verbs.
ROUTES = {
    ("GET",  "/api/models"): "/v1/models",
    ("POST", "/api/chat"):   "/v1/chat/completions",
    ("POST", "/api/embed"):  "/v1/embeddings",
}
MAX_BODY = 64 * 1024  # cap request bodies (the demo only needs small prompts)

# --- read-only memory + docs-search demos (FIXED server-side literals) ----------
# Honcho memory demo reads ONE pre-existing, non-sensitive demo session. EVERY honcho
# identifier below is a hardcoded literal; the request body is ignored, so no caller input
# reaches a honcho URL — the 'default' workspace (real fleet agent-memory) is never named,
# enumerated, or reachable through this route.
HONCHO_WS, HONCHO_SID, HONCHO_PEER = "tutorial", "session-1", "mayssam"
# Docs/RAG search reads a FIXED qdrant collection. The browser's query is ONLY ever an
# embedding input + the resulting search vector — never a collection name, URL segment, or
# qdrant filter (no injection surface). Upstream errors are normalized to a clean hint (a raw
# qdrant body is never surfaced, which would leak internal schema/shard topology).
DOCS_COLL, DOCS_TOP_K = "ai-stack-docs", 5
DOCS_INGEST_CMD = "vz-ai-stack.sh install docs_ingestor"

# --- read-only Phoenix traces demo (FIXED server-side literals) -----------------
# The traces demo GETs Phoenix's documented read-only spans API at a FIXED path:
#   GET {PHOENIX}/v1/spans?project=<PHOENIX_PROJECT>&start=<now-1h ISO8601>
# (services.yml documents exactly this query.) The browser supplies NOTHING — project,
# window, and limit are all server-side literals, so there is no SSRF / filter-injection
# sink. Phoenix shapes vary across versions, so the handler tries the documented path and
# degrades to {available:false} on any non-200 / unreachable / unparseable response —
# never a 500 and never a raw upstream body (which could leak span/schema internals).
PHOENIX_PROJECT, PHOENIX_WINDOW_S, PHOENIX_TOP_N = "ai-stack", 3600, 12

# --- soft, in-process rate limits (per-process sliding window) -------------------
# Loopback-bound + ephemeral-key already bound the blast radius; these add a cheap
# anti-runaway-loop guard for the budget-consuming / backend-reaching POST routes.
# Per-route deque of recent request monotonic timestamps; on exceed -> HTTP 429.
import collections, time as _time
RATE_LIMITS = {            # route path -> (max requests, window seconds)
    "/api/embed":        (10, 60),
    "/api/honcho/demo":  (2, 60),
    "/api/docs/search":  (3, 60),
}
_rate_hits = {p: collections.deque() for p in RATE_LIMITS}
_rate_lock = threading.Lock()


def _rate_ok(path):
    """True if a request to `path` is within its sliding-window budget (and records it).
    Routes without a configured limit are always allowed. Per-process, best-effort."""
    lim = RATE_LIMITS.get(path)
    if not lim:
        return True
    maxn, window = lim
    now = _time.monotonic()
    with _rate_lock:
        dq = _rate_hits[path]
        while dq and dq[0] <= now - window:
            dq.popleft()
        if len(dq) >= maxn:
            return False
        dq.append(now)
        return True

# --- /api/launch (opt-in, hardened) -------------------------------------------
# The ONLY route that runs a subprocess: a browser button that idempotently starts
# a watchable web-UI service so a learner can open it. Hardening (see _launch):
#   * off unless TUT_LAUNCH=1 (set only by `tutorial-serve --launch-enabled`); _launch()
#     returns 404 when disabled — same effect as no route (LAUNCH_ENABLED computed once).
#   * `svc` from the request is only a KEY into LAUNCH_SERVICES; the argv uses fixed
#     literals + that validated key, never the raw caller string; no shell=True.
#   * the child env is SCRUBBED of every TUT_* var (TUT_KEY_FILE is the live key path).
#   * one launch at a time (lock for the whole subprocess); 30s timeout + kill.
# `url` is the host-reachable address the page opens (bare hostname via /etc/hosts,
# exactly as the tutorial documents); `probe` = (host, port) for the liveness check.
LAUNCH_SERVICES = {
    "openwebui": {"url": "http://openwebui:8080", "probe": ("openwebui", 8080)},
    "phoenix":   {"url": "http://phoenix:6006",   "probe": ("phoenix", 6006)},
    "autofyn":   {"url": "http://autofyn:3400",   "probe": ("autofyn", 3400)},
    "claw3d":    {"url": "http://localhost:4310", "probe": ("localhost", 4310)},
    "chatdev":   {"url": "http://chatdev:5274",   "probe": ("chatdev", 5274)},
    "aitown":    {"url": "http://aitown:5273",    "probe": ("aitown", 5273)},
}
LAUNCH_ENV_STRIP = {"TUT_KEY", "TUT_KEY_FILE", "TUT_LITELLM", "TUT_ROOT",
                    "TUT_PORT", "TUT_MODELS", "TUT_HTML", "TUT_LAUNCH", "TUT_EMBED"}
VZ = os.path.join(ROOT, "vz-ai-stack.sh") if ROOT else ""
# Enabled ONLY if explicitly opted in AND the entrypoint really exists (validated
# once at startup; never construct the path at request time, never trust PATH).
LAUNCH_ENABLED = (os.environ.get("TUT_LAUNCH") == "1" and bool(ROOT) and os.path.isfile(VZ))
_launch_lock = threading.Lock()
LAUNCH_TIMEOUT = 30


def _cors(h):
    h.send_header("Access-Control-Allow-Origin", "*")  # loopback-bound; localhost only
    h.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
    h.send_header("Access-Control-Allow-Headers", "Content-Type")


def _probe(host, port, timeout=2.0):
    """True iff a TCP connection to (host, port) opens — a read-only liveness check.
    `host` resolves through the system resolver (/etc/hosts) exactly like the browser,
    so a bare hostname (chatdev) maps to its 127.0.10.x alias just as the page link does."""
    try:
        with socket.create_connection((host, int(port)), timeout=timeout):
            return True
    except OSError:
        return False


def _backend_json(method, url, payload=None, timeout=10):
    """GET/POST an INTERNAL backend (honcho/qdrant) at a FIXED url; return
    (status_code, parsed_json | None). Never reaches LiteLLM (that's _proxy / _litellm_json,
    which carry the key). On transport failure the urllib error propagates for the caller to
    map to a clean degrade message — a raw upstream body is NEVER surfaced to the browser."""
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method,
                                 headers={"Content-Type": "application/json", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        # Discard the upstream error body AT THE SOURCE — the "raw upstream body is never surfaced"
        # guarantee is enforced here, not left to every caller to remember to drop it.
        return e.code, None


def _litellm_json(upstream_path, payload, timeout=60):
    """POST to LiteLLM WITH the server-side key; return (code, parsed_json | None). Used by the
    docs-search demo to embed the query IN-PROCESS — the key and the raw vector stay server-side;
    only ranked snippets reach the browser."""
    req = urllib.request.Request(LITELLM + upstream_path, data=json.dumps(payload).encode(), method="POST",
        headers={"Authorization": "Bearer %s" % KEY, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        raw = r.read()
        return r.status, (json.loads(raw) if raw else None)


class H(BaseHTTPRequestHandler):
    server_version = "tutorial-proxy/1.0"

    def log_message(self, *a):  # quiet
        pass

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); _cors(self)
        self.send_header("Content-Type", "application/json")
        # Defensive response headers: API responses are never cached and never
        # content-sniffed/framed (the page is same-origin loopback, but cheap to harden).
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("X-Frame-Options", "DENY")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)

    def do_OPTIONS(self):
        self.send_response(204); _cors(self); self.end_headers()

    def do_GET(self):
        path = urllib.parse.unquote(self.path.split("?", 1)[0])
        if path == "/api/health":
            return self._json(200, {"ok": True, "models": MODELS, "embed_model": EMBED,
                                    "honcho": bool(HONCHO), "docs_search": bool(QDRANT and EMBED)})
        if path == "/api/status":
            return self._status()
        if path == "/api/traces":
            return self._traces()
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
        # Host-pin every POST (chat/embed/launch/honcho/docs) to loopback — closes DNS-rebinding
        # for the budget-consuming + backend-reaching routes (GET /api/status is host-pinned too).
        if not self._host_ok():
            return self._json(403, {"error": "forbidden host"})
        # Soft per-process rate limit on the budget-consuming / backend-reaching routes.
        if not _rate_ok(path):
            return self._json(429, {"error": "rate limit exceeded — slow down and retry shortly"})
        if path == "/api/launch":
            return self._launch()
        if path == "/api/honcho/demo":
            return self._honcho_demo()
        if path == "/api/docs/search":
            return self._docs_search()
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

    def _host_ok(self):
        """Reject a non-loopback Host header. The server binds 127.0.0.1, but a
        DNS-rebinding page could resolve an attacker hostname to 127.0.0.1 and POST
        here; pinning Host to loopback closes that on the sensitive routes."""
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]")
        return host in ("127.0.0.1", "localhost", "::1")

    def _status(self):
        """Read-only liveness of the launchable web UIs. Returns ONLY {name, healthy}
        (never internal container IPs/ports) plus launch_enabled, so the page can
        enable the launch grid + degrade gracefully when a sim is down."""
        if not self._host_ok():
            return self._json(403, {"error": "forbidden host"})
        services = [{"name": n, "healthy": _probe(*meta["probe"])}
                    for n, meta in LAUNCH_SERVICES.items()]
        self._json(200, {"launch_enabled": LAUNCH_ENABLED, "services": services})

    def _traces(self):
        """READ-ONLY view of the most recent Phoenix spans for project ai-stack (Act II —
        observability). GETs Phoenix's documented spans API at a FIXED path with server-side
        literals only (project + last ~1h window + cap); the browser supplies NOTHING, so there
        is no SSRF / filter-injection surface. Returns ONLY {name, model, latency_ms, status} per
        span — never a raw upstream body (which could leak span attributes / internal schema).
        Degrades to {available:false} on any non-200 / unreachable / unparseable response — the
        handler NEVER 500s, so a missing/older Phoenix just disables the demo gracefully."""
        # (Host is pinned to loopback by do_POST for POSTs; this GET reaches a backend, so pin here too.)
        if not self._host_ok():
            return self._json(403, {"error": "forbidden host"})
        if not PHOENIX:
            return self._json(200, {"available": False,
                                    "hint": "Phoenix isn't wired into this tutorial-serve session"})
        import datetime
        start = (datetime.datetime.now(datetime.timezone.utc)
                 - datetime.timedelta(seconds=PHOENIX_WINDOW_S)).strftime("%Y-%m-%dT%H:%M:%SZ")
        # FIXED query — every value is a server-side literal (no caller input reaches the URL).
        url = "%s/v1/spans?project=%s&start=%s" % (
            PHOENIX, urllib.parse.quote(PHOENIX_PROJECT), urllib.parse.quote(start))
        hdrs = {"Accept": "application/json"}
        if PHOENIX_KEY:
            hdrs["Authorization"] = "Bearer %s" % PHOENIX_KEY
        req = urllib.request.Request(url, method="GET", headers=hdrs)
        try:
            with urllib.request.urlopen(req, timeout=8) as r:
                if r.status != 200:
                    return self._json(200, {"available": False,
                                            "hint": "Phoenix returned no spans for this window"})
                raw = r.read()
            body = json.loads(raw) if raw else None
        except Exception:
            # Unreachable / non-200 / unparseable — degrade, never 500, never leak a raw body.
            return self._json(200, {"available": False,
                                    "hint": "Phoenix is unreachable or returned no spans right now"})
        # Phoenix span shapes vary by version: the documented /v1/spans returns a JSON ARRAY, but
        # some builds wrap it as {"data": [...]}. Accept either; treat anything else as empty.
        if isinstance(body, dict):
            spans = body.get("data") or body.get("spans") or []
        elif isinstance(body, list):
            spans = body
        else:
            spans = []
        out = []
        for s in spans[:PHOENIX_TOP_N]:
            if not isinstance(s, dict):
                continue
            attrs = s.get("attributes") if isinstance(s.get("attributes"), dict) else {}
            name = s.get("name") or s.get("span_name") or "?"
            model = (attrs.get("llm.model_name") or attrs.get("model")
                     or s.get("model") or "")
            status = s.get("status_code") or s.get("status") or ""
            lat = s.get("latency_ms")
            if lat is None and s.get("start_time") and s.get("end_time"):
                lat = ""   # don't attempt clock math across versions; leave blank
            out.append({"name": str(name)[:120], "model": str(model)[:80],
                        "status": str(status)[:24],
                        "latency_ms": (round(float(lat), 1) if isinstance(lat, (int, float)) else "")})
        return self._json(200, {"available": True, "project": PHOENIX_PROJECT,
                                "window_s": PHOENIX_WINDOW_S, "spans": out})

    def _launch(self):
        """Start ONE allowlisted web-UI service (opt-in, hardened — see LAUNCH_* above).
        Not handled at all unless LAUNCH_ENABLED (computed once at startup)."""
        if not LAUNCH_ENABLED:
            return self._json(404, {"error": "launch not enabled — restart with: "
                                             "vz-ai-stack.sh tutorial-serve --launch-enabled"})
        # (Host is already pinned to loopback in do_POST for every POST route.)
        try:
            n = int(self.headers.get("Content-Length", 0) or 0)
        except (ValueError, TypeError):
            return self._json(400, {"error": "invalid Content-Length"})
        if n < 0 or n > MAX_BODY:
            return self._json(413, {"error": "request too large"})
        try:
            body = json.loads(self.rfile.read(n) if n else b"{}")
        except (ValueError, TypeError):
            return self._json(400, {"error": "invalid JSON body"})
        # `svc` is used ONLY as a lookup key; the argv below uses fixed literals + the key.
        svc = body.get("svc") if isinstance(body, dict) else None
        if not isinstance(svc, str) or svc not in LAUNCH_SERVICES:
            return self._json(404, {"error": "unknown service (not in the launch allowlist)"})
        meta = LAUNCH_SERVICES[svc]
        if _probe(*meta["probe"]):                       # already up → idempotent, no spawn
            return self._json(200, {"ok": True, "svc": svc, "url": meta["url"], "already_running": True})
        if not _launch_lock.acquire(blocking=False):     # one launch at a time
            return self._json(409, {"ok": False, "svc": svc,
                                    "error": "another launch is in progress — try again in a moment"})
        try:
            # SCRUB every proxy-internal var from the child env so the launched service can
            # never read the ephemeral key. Strip the WHOLE TUT_* namespace (covers TUT_KEY /
            # TUT_KEY_FILE — the live key + its path — and any TUT_ var added in future),
            # plus the explicit LAUNCH_ENV_STRIP set (belt-and-suspenders for non-TUT_ vars).
            env = {k: v for k, v in os.environ.items()
                   if not k.startswith("TUT_") and k not in LAUNCH_ENV_STRIP}
            # argv list, no shell=True; --no-open suppresses vz's own browser-open (the
            # page opens the URL on the user's click). svc is the validated allowlist key.
            # subprocess.run kills+reaps the child internally on timeout before re-raising.
            proc = subprocess.run([VZ, "start", svc, "--no-open"], env=env, cwd=ROOT,
                                  capture_output=True, timeout=LAUNCH_TIMEOUT)
        except subprocess.TimeoutExpired:
            return self._json(504, {"ok": False, "svc": svc,
                                    "error": f"start timed out after {LAUNCH_TIMEOUT}s"})
        except Exception:
            # Never surface the raw exception text — it can carry absolute paths / URLs.
            return self._json(500, {"ok": False, "svc": svc, "error": "could not start the service"})
        finally:
            _launch_lock.release()                       # released right after the subprocess returns
        up = _probe(*meta["probe"], timeout=3.0)         # confirm it actually came up
        if up or proc.returncode == 0:
            return self._json(200, {"ok": True, "svc": svc, "url": meta["url"],
                                    "already_running": False, "running": up})
        # Do NOT echo raw subprocess stderr/stdout — it can leak host paths / internal URLs.
        # Surface only a generic message + the safe exit status (an int, not text).
        return self._json(502, {"ok": False, "svc": svc, "returncode": proc.returncode,
                                "error": "start ran but the service is not responding — "
                                         "check the server logs on the host"})

    def _honcho_demo(self):
        """READ-ONLY view of ONE fixed, non-sensitive honcho demo session (Act III — memory).
        Shows the raw messages ('what was said') + the derived peer representation ('what Honcho
        knows', which the deriver computes asynchronously and may legitimately be empty). Every
        honcho identifier is a server-side literal and the request body is IGNORED, so no caller
        input can reach a honcho URL or the 'default' fleet-memory workspace. Response carries
        only peer+content+representation text — never raw item blobs or internal addresses."""
        # Drain any request body (the page sends "{}") so a keep-alive connection can't be mis-parsed.
        # The body is intentionally IGNORED — no caller input is ever used (fixed-literal namespace).
        try:
            _n = int(self.headers.get("Content-Length", 0) or 0)
            if 0 < _n <= MAX_BODY:
                self.rfile.read(_n)
        except (ValueError, TypeError):
            pass
        if not HONCHO:
            return self._json(200, {"available": False,
                                    "hint": "honcho isn't wired into this tutorial-serve session"})
        base = "%s/v3/workspaces/%s" % (HONCHO, HONCHO_WS)
        try:
            mcode, mbody = _backend_json("POST", "%s/sessions/%s/messages/list" % (base, HONCHO_SID), {})
        except Exception:
            return self._json(503, {"available": False, "hint": "honcho is unreachable right now"})
        if mcode != 200 or not isinstance(mbody, dict):
            return self._json(200, {"available": False,
                                    "hint": "the demo memory session isn't present on this box"})
        msgs = [{"peer": str(m.get("peer_id", "?")), "content": str(m.get("content", ""))[:400]}
                for m in (mbody.get("items") or []) if isinstance(m, dict)][:8]
        derived = ""
        try:
            rcode, rbody = _backend_json("POST", "%s/peers/%s/representation" % (base, HONCHO_PEER), {})
            if rcode == 200 and isinstance(rbody, dict):
                derived = (rbody.get("representation") or "").strip()[:1200]
        except Exception:
            derived = ""
        return self._json(200, {"available": True, "workspace": HONCHO_WS, "peer": HONCHO_PEER,
                                "messages": msgs, "derived": derived})

    def _docs_search(self):
        """READ-ONLY RAG search: embed the query via LiteLLM (server-side key) then vector-search
        a FIXED qdrant collection. The query is ONLY ever an embedding input + the resulting search
        vector — never a collection name, URL segment, or qdrant filter. If the collection isn't
        built yet we degrade to the exact populate command (a lesson, not a raw 404)."""
        if not QDRANT:
            return self._json(200, {"available": False,
                                    "hint": "docs search isn't wired into this tutorial-serve session"})
        try:
            n = int(self.headers.get("Content-Length", 0) or 0)
        except (ValueError, TypeError):
            return self._json(400, {"error": "invalid Content-Length"})
        if n < 0 or n > MAX_BODY:
            return self._json(413, {"error": "request too large"})
        try:
            body = json.loads(self.rfile.read(n) if n else b"{}")
        except (ValueError, TypeError):
            return self._json(400, {"error": "invalid JSON body"})
        q = body.get("q") if isinstance(body, dict) else None
        if not isinstance(q, str) or not q.strip():
            return self._json(400, {"error": "missing query 'q'"})
        q = q.strip()[:2000]
        if not EMBED:   # no embedder wired -> search is impossible; short-circuit before any network call
            return self._json(200, {"available": False, "hint": "no local embedding model is wired for search"})
        # 1) collection-exists check FIRST (cheap metadata GET) -> degrade-as-lesson if absent,
        #    BEFORE any search call, so a raw qdrant 404 never reaches the browser.
        try:
            ccode, _ = _backend_json("GET", "%s/collections/%s" % (QDRANT, DOCS_COLL), None, timeout=8)
        except Exception:
            return self._json(503, {"available": False, "hint": "the vector store is unreachable right now"})
        if ccode != 200:
            return self._json(200, {"available": False, "indexed": False,
                                    "hint": "the docs index isn't built yet — run  %s  then search" % DOCS_INGEST_CMD})
        # 2) embed q via LiteLLM (server-side key). q is ONLY ever this embed input.
        try:
            ecode, ebody = _litellm_json("/v1/embeddings", {"model": EMBED, "input": q})
            vec = ebody["data"][0]["embedding"] if (ecode == 200 and isinstance(ebody, dict)) else None
        except Exception:
            vec = None
        if not isinstance(vec, list) or not vec:
            return self._json(502, {"available": False, "hint": "the embedding step failed"})
        # 3) qdrant vector search — body built via json.dumps (never string-concat); q never here.
        try:
            scode, sbody = _backend_json("POST", "%s/collections/%s/points/search" % (QDRANT, DOCS_COLL),
                                         {"vector": vec, "limit": DOCS_TOP_K, "with_payload": True}, timeout=15)
        except Exception:
            return self._json(502, {"available": False, "hint": "the vector search failed"})
        if scode != 200 or not isinstance(sbody, dict):
            return self._json(200, {"available": False, "indexed": True,
                                    "hint": "the vector search returned nothing"})
        results = []
        for h in (sbody.get("result") or [])[:DOCS_TOP_K]:
            if not isinstance(h, dict):
                continue
            payload = h.get("payload") or {}
            text = payload.get("text") or payload.get("_node_content") or ""
            # llama_index stores the chunk JSON under _node_content; pull its .text if so.
            if isinstance(text, str) and text.startswith("{") and '"text"' in text:
                try:
                    text = json.loads(text).get("text", text)
                except ValueError:
                    pass
            src = payload.get("file_name") or payload.get("source") or payload.get("doc_id") or ""
            results.append({"score": round(float(h.get("score", 0) or 0), 3),
                            "snippet": str(text or "")[:280], "source": str(src or "")[:120]})
        return self._json(200, {"available": True, "indexed": True, "query": q[:120], "results": results})

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
