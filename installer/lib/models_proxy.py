#!/usr/bin/env python3
"""models_proxy.py — backend for the Model & Agent Console (doc/MODELS.html).

Serves the console page AND a tiny, ROUTE-ALLOWLISTED API that WRAPS the `model`
CLI (installer/lib/models.sh) to view / stage / apply changes to models.yml +
litellm/config.yaml. It NEVER reimplements model logic in Python — every mutation
is the real CLI, so the single source of truth and all its invariants are preserved.

Design (council-locked, see project_model_console memory):
  * GET  /api/state  — `model list --json` + `embedding list --json` + parsed
                       config.yaml fallbacks/openrouter routes + key_env PRESENCE
                       (names only) + pending. Read-only.
  * POST /api/stage  — copy {models.yml, config.yaml} to an isolated SANDBOX, run the
                       real `model <op> --no-sync` against the copies (MODELS_YML/CONFIG
                       env override), and return a TRUE unified diff of both files plus
                       the sync registration plan + a needs_recreate verdict. Touches no
                       live file and makes no docker call or network MUTATION (a
                       read-only LM Studio liveness probe may occur via sync --dry-run).
                       CLI exit 2
                       (validation/usage) -> 400 JSON; the proxy never crashes.
  * POST /api/apply  — run the real op (with sync), after timestamped backups of
                       models.yml/config.yaml/.env, under a single-flight lock. A
                       container RECREATE (new vendor key) is gated behind an explicit
                       confirm_recreate flag + a downtime warning.
  * POST /api/test   — optional: one budget-capped smoke call to a model via the
                       server-side ephemeral key (catches "added but 404s at call time").

Security mirrors tutorial_proxy.py: loopback bind, Host-pin every POST, narrow static
allowlist (no .js/.json/.env/.sh/.yml/dotfiles), key only from a 0600 file injected
server-side, subprocess via argv-list (never shell) with a scrubbed env + timeouts.
Vendor API keys NEVER cross the HTTP layer — only key VAR NAMES + presence booleans.
"""
import json, os, posixpath, shutil, subprocess, sys, tempfile, threading, time
import urllib.parse, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT       = int(os.environ.get("MC_PORT", "8898"))
LITELLM    = os.environ.get("MC_LITELLM", "http://127.0.0.1:4000").rstrip("/")
HTML       = os.environ.get("MC_HTML", "")
ROOT       = os.path.realpath(os.environ.get("MC_ROOT", "")) if os.environ.get("MC_ROOT") else ""
MODELS_SH  = os.environ.get("MC_MODELS_SH", "")
EMBED_SH   = os.environ.get("MC_EMBED_SH", "")
START_LL   = os.environ.get("MC_START_LITELLM", "")
DOCKER     = os.environ.get("MC_DOCKER", "docker")   # binary used to restart litellm on restore; overridable so a test can stub it (never the real daemon)
RESTART_WAIT = int(os.environ.get("MC_RESTART_WAIT", "30"))   # seconds to wait for LiteLLM readiness after a restore restart (0 = don't wait; tests set 0)
MODELS_YML = os.environ.get("MC_MODELS_YML", "")
CONFIG     = os.environ.get("MC_CONFIG", "")
ENV_FILE   = os.environ.get("MC_ENV_FILE", "")
READONLY   = os.environ.get("MC_READONLY", "0") == "1"

# Ephemeral test key (best-effort; absent -> POST /api/test degrades to 503).
KEY = ""
_KEY_FILE = os.environ.get("MC_KEY_FILE", "")
if _KEY_FILE and os.path.isfile(_KEY_FILE):
    try:
        with open(_KEY_FILE, "r", encoding="utf-8") as _kf:
            KEY = _kf.read().strip()
    except OSError:
        pass

# Keys passed into the LiteLLM container by bin/start-litellm.sh's FIXED -e set
# (mirror of _mc_fixed there). A NEW openai-compat key_env outside this set needs a
# container RECREATE (start-litellm.sh re-injects declared key_env on recreate, not on
# a plain `docker restart`); one already in the set just needs the normal restart that
# `model sync` already performs.
FIXED_KEY_ENVS = {
    "ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY", "GOOGLE_API_KEY",
    "SAKANA_API_KEY", "LITELLM_MASTER_KEY", "PHOENIX_API_KEY",
}

PAGE_ROUTE = "/"
if ROOT and HTML:
    _rel = os.path.relpath(os.path.realpath(HTML), ROOT)
    if not _rel.startswith(".."):
        PAGE_ROUTE = "/" + _rel.replace(os.sep, "/")

STATIC_TYPES = {
    ".html": "text/html; charset=utf-8", ".htm": "text/html; charset=utf-8",
    ".md": "text/markdown; charset=utf-8", ".txt": "text/plain; charset=utf-8",
    ".css": "text/css; charset=utf-8", ".svg": "image/svg+xml", ".png": "image/png",
    ".jpg": "image/jpeg", ".jpeg": "image/jpeg", ".gif": "image/gif",
    ".ico": "image/x-icon", ".webp": "image/webp",
}

MAX_BODY = 64 * 1024
SUBPROC_TIMEOUT = 360          # sync/apply can take a few minutes (key widening, restart)
STAGE_TIMEOUT   = 90
_apply_lock = threading.Lock()  # single-flight: serialize writes OUTER to models.sh's own lock
_stage_sem = threading.BoundedSemaphore(4)  # cap concurrent stage subprocess fan-out (each stage forks bash+yq)

# --- op -> CLI argv allowlist --------------------------------------------------
# Every op maps the validated request to a FIXED argv built from literals + checked
# fields. The raw request string is NEVER passed to a shell; subprocess uses argv lists.
EDIT_FIELDS = {"rpm", "tpm", "ttl", "big", "effort", "note"}
ADD_RUNTIMES = {"ollama", "lmstudio", "openai-compat", "openrouter"}
ENVNAME_OK = lambda s: isinstance(s, str) and s.isascii() and bool(s) and (s[0].isalpha() or s[0] == "_") and all(c.isalnum() or c == "_" for c in s) and s.upper() == s


def _str(d, k):
    v = d.get(k)
    return v if isinstance(v, str) and v.strip() else None


def _posarg(d, k):
    """A positional string arg destined for the CLI argv: non-empty AND not a leading-dash
    flag. Rejecting leading '-' closes argv-smuggling — a name/agent/value like '--dry-run'
    would otherwise be parsed by the CLI as a FLAG, not a positional (the proxy uses argv
    lists so there is no shell injection, but flag-smuggling can still flip CLI behavior)."""
    v = _str(d, k)
    if v is not None and v.lstrip().startswith("-"):
        raise StageError(f"'{k}' must not start with '-'")
    return v


class StageError(Exception):
    """Raised with a clean message when an op's request is malformed (-> 400)."""


_NAME_CHARS = set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_./@-")


def _charset_ok(s):
    """Reject a model/target name outside the safe charset BEFORE it reaches the bash
    subprocess (adversarial B3). _posarg already blocks leading-dash flag-smuggling; this
    bounds the rest so a name can never carry shell/yq metacharacters."""
    if not s or any(c not in _NAME_CHARS for c in s):
        raise StageError(f"name '{s}' is outside the safe charset [A-Za-z0-9_./@-]")


def build_argv(op, args, *, sync):
    """Return the `model` subcommand argv for (op, args). Appends --no-sync when
    sync is False (staging). Raises StageError on malformed input (-> 400, never 500)."""
    if not isinstance(args, dict):
        raise StageError("args must be an object")
    tail = [] if sync else ["--no-sync"]
    if op == "assign":
        a, m = _posarg(args, "agent"), _posarg(args, "model")
        if not a or not m:
            raise StageError("assign requires 'agent' and 'model'")
        return ["assign", a, m] + tail
    if op in ("park", "unpark"):
        a = _posarg(args, "agent")
        if not a:
            raise StageError(f"{op} requires 'agent'")
        return [op, a] + tail
    if op == "edit":
        name, field, value = _posarg(args, "name"), _str(args, "field"), args.get("value")
        if not name or field not in EDIT_FIELDS:
            raise StageError(f"edit requires 'name' and 'field' in {sorted(EDIT_FIELDS)}")
        if not isinstance(value, str) or value == "":
            value = "" if value is None else str(value)
        if value == "":
            raise StageError("edit requires a non-empty 'value'")
        if value.lstrip().startswith("-"):   # else the CLI parses the value as a flag
            raise StageError("edit 'value' must not start with '-'")
        return ["edit", name, field, value] + tail
    if op == "remove":
        name = _posarg(args, "name")
        if not name:
            raise StageError("remove requires 'name'")
        return ["remove", name] + tail
    if op == "add":
        rt = _str(args, "runtime")
        if rt not in ADD_RUNTIMES:
            raise StageError(f"add requires 'runtime' in {sorted(ADD_RUNTIMES)}")
        if rt == "lmstudio":
            slug = _posarg(args, "slug")
            if not slug:
                raise StageError("lmstudio add requires 'slug'")
            argv = ["add", slug]
            name = _posarg(args, "name")
            if name:
                argv += ["as", name]
            return argv + tail
        argv = ["add", "--runtime", rt]
        served = _posarg(args, "served")
        if not served:
            raise StageError(f"{rt} add requires 'served'")
        argv += ["--served", served]
        if rt == "ollama":
            big = args.get("big")
            argv += ["--big", "true" if big in (True, "true") else "false"]
        if rt == "openai-compat":
            ab, ke = _str(args, "api_base"), _str(args, "key_env")
            if not ab or not ke:
                raise StageError("openai-compat add requires 'api_base' and 'key_env'")
            if not ENVNAME_OK(ke):
                raise StageError("'key_env' must be an ENV-style name (UPPER_SNAKE)")
            argv += ["--api-base", ab, "--key-env", ke]
            for opt in ("rpm", "tpm"):
                v = args.get(opt)
                if v not in (None, ""):
                    if not str(v).isdigit():
                        raise StageError(f"'{opt}' must be a positive integer")
                    argv += [f"--{opt}", str(v)]
        name = _posarg(args, "name")
        if name:
            argv += ["as", name]
        elif rt in ("openai-compat",):
            raise StageError("openai-compat add requires an alias 'name'")
        return argv + tail
    if op == "fallback":
        fb = _str(args, "fb_op")
        if fb not in ("set", "remove"):
            raise StageError("fallback requires 'fb_op' in {set, remove}")
        model = _posarg(args, "model")
        if not model:
            raise StageError("fallback requires 'model'")
        _charset_ok(model)
        argv = ["fallback", fb, model]
        if fb == "set":
            targets = args.get("targets")
            if not isinstance(targets, list) or not targets:
                raise StageError("fallback set requires a non-empty 'targets' list")
            for t in targets:
                if not isinstance(t, str) or not t:
                    raise StageError("each fallback target must be a non-empty string")
                if t.lstrip().startswith("-"):
                    raise StageError("fallback target must not start with '-'")
                _charset_ok(t)
                argv.append(t)
            if args.get("allow_non_local"):
                argv.append("--allow-non-local")
        return argv
    raise StageError(f"unknown op '{op}'")


def needs_recreate(op, args):
    """(needs_recreate: bool, reason: str). True only when activating the change needs
    a LiteLLM container RECREATE (a NEW vendor key_env that start-litellm.sh must inject)
    — everything else is handled by the restart `model sync`/`remove`/openrouter-add
    already perform internally."""
    if op == "add" and isinstance(args, dict) and _str(args, "runtime") == "openai-compat":
        ke = _str(args, "key_env")
        if ke and ke not in FIXED_KEY_ENVS:
            return True, (f"adds a new vendor key '{ke}' — the LiteLLM container must be "
                          f"RECREATED (bin/start-litellm.sh) so the key is passed through; "
                          f"this briefly drops the endpoint the whole fleet routes through.")
    return False, ""


def run_model(argv, *, env_override=None, timeout=SUBPROC_TIMEOUT, cwd=None):
    """Run `bash models.sh <argv...>` with a scrubbed env. Returns (rc, stdout, stderr).
    env_override points MODELS_YML/CONFIG at a sandbox for staging. Never shell=True."""
    env = {k: v for k, v in os.environ.items() if not k.startswith("MC_")}
    if env_override:
        env.update(env_override)
    try:
        p = subprocess.run(["bash", MODELS_SH] + argv, env=env, cwd=(cwd or ROOT),
                           capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired:
        return 124, "", f"timed out after {timeout}s"


def yq_json(expr, path):
    try:
        p = subprocess.run(["yq", "-o=json", expr, path], capture_output=True, text=True, timeout=15)
        if p.returncode == 0 and p.stdout.strip():
            return json.loads(p.stdout)
    except Exception:
        pass
    return None


def env_key_presence():
    """Names of env vars set to a NON-EMPTY value in .env. Returns a {name: True} map —
    only NAMES + booleans ever leave the server, never the secret VALUES."""
    present = {}
    if not ENV_FILE or not os.path.isfile(ENV_FILE):
        return present
    try:
        with open(ENV_FILE, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                k = k.strip()
                # strip surrounding quotes (either kind) THEN whitespace, so a value like
                # '' / "" / ' ' counts as ABSENT (not a spuriously-"present" empty key).
                if k and v.strip().strip('"').strip("'").strip():
                    present[k] = True
    except OSError:
        pass
    return present


def _diff(a, b, label):
    """Unified diff of two files via the system `diff -u`. Empty string if identical."""
    try:
        p = subprocess.run(["diff", "-u", a, b], capture_output=True, text=True, timeout=20)
        return p.stdout if p.returncode != 0 else ""
    except Exception:
        return f"(could not diff {label})"


def _loopback_origin_ok(headers):
    """False for a browser CROSS-SITE / cross-origin request. We emit NO CORS headers
    (the console page and /api are SAME-ORIGIN, so same-origin fetches need none), which
    means a cross-origin page's JSON POST — a CORS-preflighted request — is already
    BLOCKED by the browser; this is the server-side belt-and-suspenders that ALSO rejects
    the request if it somehow arrives. Closes the localhost CSRF vector against the
    state-changing routes (/api/apply, /api/stage). Same-origin and non-browser callers
    (curl, no Origin / no Sec-Fetch-Site) pass."""
    if (headers.get("Sec-Fetch-Site") or "").lower() in ("cross-site", "cross-origin"):
        return False
    origin = headers.get("Origin")
    if origin:
        try:
            host = urllib.parse.urlparse(origin).hostname
        except Exception:
            return False
        if host not in ("127.0.0.1", "localhost", "::1"):
            return False
    return True


class H(BaseHTTPRequestHandler):
    server_version = "models-console/1.0"

    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)   # NO CORS headers: same-origin needs none; omitting them blocks cross-origin POSTs
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)

    def _host_ok(self):
        host = (self.headers.get("Host") or "").rsplit(":", 1)[0].strip("[]")
        return host in ("127.0.0.1", "localhost", "::1")

    def _read_body(self):
        try:
            n = int(self.headers.get("Content-Length", 0) or 0)
        except (ValueError, TypeError):
            return None, (400, "invalid Content-Length")
        if n < 0 or n > MAX_BODY:
            return None, (413, "request too large")
        raw = self.rfile.read(n) if n else b"{}"
        try:
            return json.loads(raw or b"{}"), None
        except (ValueError, TypeError):
            return None, (400, "invalid JSON body")

    def do_OPTIONS(self):
        # Reply with NO Access-Control-Allow-* headers -> a cross-origin preflight fails
        # closed in the browser, so the cross-origin POST that would follow never fires.
        self.send_response(204); self.end_headers()

    # ----------------------------------------------------------------- GET
    def do_GET(self):
        path = urllib.parse.unquote(self.path.split("?", 1)[0])
        if path == "/api/health":
            return self._json(200, {"ok": True, "read_only": READONLY, "test_enabled": bool(KEY)})
        if path == "/api/state":
            if not self._host_ok():
                return self._json(403, {"error": "forbidden host"})
            if not _loopback_origin_ok(self.headers):
                return self._json(403, {"error": "forbidden origin (cross-site request blocked)"})
            return self._state()
        if path == "/api/backups":
            if not self._host_ok():
                return self._json(403, {"error": "forbidden host"})
            if not _loopback_origin_ok(self.headers):
                return self._json(403, {"error": "forbidden origin (cross-site request blocked)"})
            return self._json(200, {"backups": _list_backups(), "read_only": READONLY})
        if path in ("/", "/index.html", "/models", "/MODELS.html"):
            if PAGE_ROUTE != "/":
                return self._redirect(PAGE_ROUTE)
            return self._serve_html()
        if self._serve_static(path):
            return
        self._json(404, {"error": "not found (console serves the page, doc/image/css, and the /api allowlist)"})

    # ----------------------------------------------------------------- POST
    def do_POST(self):
        path = self.path.split("?", 1)[0]
        if not self._host_ok():
            return self._json(403, {"error": "forbidden host"})
        if not _loopback_origin_ok(self.headers):
            return self._json(403, {"error": "forbidden origin (cross-site request blocked)"})
        if path == "/api/stage":
            return self._stage()
        if path == "/api/apply":
            return self._apply()
        if path == "/api/restore":
            return self._restore()
        if path == "/api/fallback":
            return self._fallback()
        if path == "/api/test":
            return self._test()
        self._json(404, {"error": f"route not allowed: POST {path}"})

    # ----------------------------------------------------------------- state
    def _state(self):
        rc, out, errs = run_model(["list", "--json"], timeout=30)
        if rc != 0:
            return self._json(500, {"error": "model list --json failed", "detail": errs[-800:]})
        try:
            state = json.loads(out)
        except ValueError:
            return self._json(500, {"error": "could not parse model list --json"})
        # Embeddings registry (best-effort; absent -> {}).
        emb = {}
        if EMBED_SH and os.path.isfile(EMBED_SH):
            try:
                p = subprocess.run(["bash", EMBED_SH, "list", "--json"], capture_output=True, text=True, timeout=20,
                                   env={k: v for k, v in os.environ.items() if not k.startswith("MC_")})
                if p.returncode == 0 and p.stdout.strip():
                    emb = json.loads(p.stdout)
            except Exception:
                emb = {}
        # config.yaml: hand-curated fallbacks + openrouter routes (config-only, not in models.yml).
        fallbacks = yq_json(".litellm_settings.fallbacks // []", CONFIG) or [] if CONFIG and os.path.isfile(CONFIG) else []
        openrouter = []
        ml = yq_json(".model_list // []", CONFIG) or [] if CONFIG and os.path.isfile(CONFIG) else []
        declared = set(state.get("models", {}).keys())
        for entry in ml:
            if not isinstance(entry, dict):
                continue
            nm = entry.get("model_name")
            mdl = (entry.get("litellm_params") or {}).get("model", "")
            if isinstance(mdl, str) and mdl.startswith("openrouter/") and nm not in declared:
                openrouter.append({"name": nm, "served": mdl})
        # key_env presence (names only) for every declared key_env + the fixed vendor set.
        presence = env_key_presence()
        wanted = set(FIXED_KEY_ENVS)
        for m in state.get("models", {}).values():
            ke = (m or {}).get("key_env")
            if isinstance(ke, str) and ke:
                wanted.add(ke)
        key_env_present = {k: bool(presence.get(k)) for k in sorted(wanted)}
        state.update({
            "fallbacks": fallbacks, "openrouter_routes": openrouter,
            "embeddings": emb.get("embeddings", {}) if isinstance(emb, dict) else {},
            "embedding_assignments": emb.get("embedding_assignments", {}) if isinstance(emb, dict) else {},
            "key_env_present": key_env_present, "read_only": READONLY, "test_enabled": bool(KEY),
            "fixed_key_envs": sorted(FIXED_KEY_ENVS),
        })
        self._json(200, state)

    # ----------------------------------------------------------------- stage
    def _stage(self):
        body, err = self._read_body()
        if err:
            return self._json(err[0], {"error": err[1]})
        op = body.get("op") if isinstance(body, dict) else None
        args = body.get("args") if isinstance(body, dict) else {}
        try:
            argv = build_argv(op, args or {}, sync=False)
        except StageError as e:
            return self._json(400, {"ok": False, "error": str(e)})
        if not (MODELS_YML and CONFIG and os.path.isfile(MODELS_YML) and os.path.isfile(CONFIG)):
            return self._json(500, {"ok": False, "error": "models.yml/config.yaml not found server-side"})
        if not _stage_sem.acquire(blocking=False):   # cap concurrent stage fan-out (DoS backstop)
            return self._json(429, {"ok": False, "error": "too many concurrent stage requests — retry shortly"})
        # mkdtemp() goes INSIDE the try so the finally (and thus _stage_sem.release()) always
        # runs once we hold the slot — otherwise a mkdtemp failure (disk full) would leak the slot.
        sb = None
        try:
            sb = tempfile.mkdtemp(prefix="mc-stage-")
            sm, sc = os.path.join(sb, "models.yml"), os.path.join(sb, "config.yaml")
            shutil.copy2(MODELS_YML, sm); shutil.copy2(CONFIG, sc)
            om, oc = sm + ".orig", sc + ".orig"
            shutil.copy2(sm, om); shutil.copy2(sc, oc)
            env_override = {"MODELS_YML": sm, "CONFIG": sc}
            rc, out, errs = run_model(argv, env_override=env_override, timeout=STAGE_TIMEOUT)
            if rc == 2:    # validation/usage refusal -> a clean 400 (NOT a crash)
                msg = (errs.strip() or out.strip() or "the change was refused").splitlines()
                return self._json(400, {"ok": False, "error": "\n".join(msg[-6:])})
            if rc != 0:
                return self._json(500, {"ok": False, "error": (errs or out)[-800:]})
            models_diff = _diff(om, sm, "models.yml")
            # config.yaml effect: direct edits (remove/openrouter) show via file diff;
            # add/edit register on sync, so capture sync --dry-run's registration plan.
            config_diff = _diff(oc, sc, "config.yaml")
            sync_plan = ""
            if not config_diff:
                drc, dout, _ = run_model(["sync", "--dry-run"], env_override=env_override, timeout=STAGE_TIMEOUT)
                if drc == 0:
                    sync_plan = _extract_plan(dout)
            nr, reason = needs_recreate(op, args or {})
            self._json(200, {
                "ok": True, "op": op,
                "models_diff": models_diff,
                "config_diff": config_diff or sync_plan,
                "config_is_render_plan": bool(not config_diff and sync_plan),
                "needs_recreate": nr, "recreate_reason": reason,
                "cli_output": out.strip()[-1200:],
            })
        finally:
            if sb is not None:
                shutil.rmtree(sb, ignore_errors=True)
            _stage_sem.release()

    # ----------------------------------------------------------------- apply
    def _apply(self):
        if READONLY:
            return self._json(403, {"ok": False, "error": "read-only mode: applies are disabled (restart without --read-only)"})
        body, err = self._read_body()
        if err:
            return self._json(err[0], {"error": err[1]})
        op = body.get("op") if isinstance(body, dict) else None
        args = body.get("args") if isinstance(body, dict) else {}
        confirm_recreate = bool(body.get("confirm_recreate")) if isinstance(body, dict) else False
        try:
            argv = build_argv(op, args or {}, sync=True)
        except StageError as e:
            return self._json(400, {"ok": False, "error": str(e)})
        nr, reason = needs_recreate(op, args or {})
        if nr and not confirm_recreate:
            return self._json(409, {"ok": False, "needs_confirm": True, "needs_recreate": True,
                                    "reason": reason})
        if not _apply_lock.acquire(blocking=False):
            return self._json(409, {"ok": False, "error": "another apply is in progress — try again in a moment"})
        try:
            backups = _backup_sources()
            rc, out, errs = run_model(argv, timeout=SUBPROC_TIMEOUT)
            if rc == 2:
                return self._json(400, {"ok": False, "error": (errs or out)[-800:], "backups": backups})
            if rc != 0:
                return self._json(500, {"ok": False, "error": (errs or out)[-1200:], "backups": backups})
            recreate_done = False
            recreate_log = ""
            # NOTE (accepted v1 tradeoff): for a new-vendor-key openai-compat add, the op
            # above ran `model add` -> `model sync` which docker-restarts LiteLLM to load
            # the registered route; that restart does NOT re-inject the new -e key, so this
            # start-litellm.sh recreate is the one that actually activates it. Net = two
            # restarts for this rare op. Optimizing to a single recreate is a follow-up.
            if nr and confirm_recreate and START_LL and os.path.isfile(START_LL):
                try:
                    env = {k: v for k, v in os.environ.items() if not k.startswith("MC_")}
                    p = subprocess.run(["bash", START_LL], env=env, cwd=ROOT,
                                       capture_output=True, text=True, timeout=SUBPROC_TIMEOUT)
                    recreate_done = (p.returncode == 0)
                    recreate_log = ((p.stderr or "") + (p.stdout or ""))[-800:]
                except subprocess.TimeoutExpired:
                    recreate_log = "start-litellm.sh timed out"
            return self._json(200, {"ok": True, "op": op, "output": out.strip()[-2000:],
                                    "recreate_done": recreate_done, "recreate_log": recreate_log,
                                    "backups": backups})
        finally:
            _apply_lock.release()

    # ----------------------------------------------------------------- test
    def _test(self):
        if not KEY:
            return self._json(503, {"ok": False, "error": "no test key (LiteLLM was down at launch) — restart models-serve with LiteLLM up"})
        body, err = self._read_body()
        if err:
            return self._json(err[0], {"error": err[1]})
        model = _str(body, "model") if isinstance(body, dict) else None
        if not model:
            return self._json(400, {"ok": False, "error": "test requires 'model'"})
        prompt = (_str(body, "prompt") if isinstance(body, dict) else None) or "Reply with the single word: ok"
        payload = {"model": model, "messages": [{"role": "user", "content": prompt[:500]}], "max_tokens": 16}
        req = urllib.request.Request(LITELLM + "/v1/chat/completions",
                                     data=json.dumps(payload).encode(), method="POST",
                                     headers={"Authorization": "Bearer %s" % KEY, "Content-Type": "application/json"})
        t0 = time.monotonic()
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                raw = r.read()
            dt = round((time.monotonic() - t0) * 1000)
            data = json.loads(raw) if raw else {}
            text = ((data.get("choices") or [{}])[0].get("message") or {}).get("content", "")
            return self._json(200, {"ok": True, "model": model, "latency_ms": dt, "reply": str(text)[:300]})
        except urllib.error.HTTPError as e:
            detail = (e.read() or b"")[:300].decode("utf-8", "replace")
            return self._json(200, {"ok": False, "model": model, "status": e.code,
                                    "error": f"upstream {e.code}", "detail": detail})
        except Exception as e:
            return self._json(200, {"ok": False, "model": model, "error": str(e)[:300]})

    # ----------------------------------------------------------------- restore (one-click rollback)
    def _restore(self):
        """Roll back models.yml + config.yaml to a prior apply's timestamped backup, then
        RESTART LiteLLM to load it. The CURRENT state is backed up first, so a restore is
        itself reversible. .env is intentionally NOT restored (the console never edits it;
        rolling it back could clobber vendor keys added since). Read-only refuses; the
        LiteLLM restart is gated behind confirm_restart (fleet downtime), mirroring apply."""
        if READONLY:
            return self._json(403, {"ok": False, "error": "read-only mode: restore is disabled (restart without --read-only)"})
        body, err = self._read_body()
        if err:
            return self._json(err[0], {"error": err[1]})
        ts = _str(body, "ts") if isinstance(body, dict) else None
        confirm_restart = bool(body.get("confirm_restart")) if isinstance(body, dict) else False
        if not (ts and _is_backup_ts(ts)):
            return self._json(400, {"ok": False, "error": "restore requires a valid backup 'ts' (YYYYMMDD-HHMMSS)"})
        if not BACKUP_DIR:
            return self._json(500, {"ok": False, "error": "no backup dir configured"})
        src_models = os.path.join(BACKUP_DIR, f"models.yml.{ts}")
        src_config = os.path.join(BACKUP_DIR, f"config.yaml.{ts}")
        # containment: BOTH sources must be real files INSIDE BACKUP_DIR, and NEITHER may be a
        # symlink. _is_backup_ts already forbids path separators in `ts`, but a symlink planted in
        # BACKUP_DIR (e.g. config.yaml.<valid-ts> -> /etc/...) would otherwise be followed by
        # shutil.copy2 and overwrite the live file — so reject symlinks + re-check containment.
        rbd = os.path.realpath(BACKUP_DIR)
        # Checked unconditionally for BOTH sources even when config is absent (a models-only
        # restore point) — islink on a missing path is False and realpath stays inside BACKUP_DIR,
        # so it's a harmless no-op there; the absent-config case is gated later by os.path.isfile.
        # NOTE: islink-then-copy is not atomic (a residual local-only TOCTOU); accepted because
        # writing to BACKUP_DIR already requires owning this account, and shutil.copy2 has no
        # O_NOFOLLOW. Revisit if BACKUP_DIR ever becomes writable by a broader set of users.
        for src_check in (src_models, src_config):
            if os.path.islink(src_check):
                return self._json(400, {"ok": False, "error": "invalid backup (symlink not allowed)"})
            if os.path.commonpath([rbd, os.path.realpath(src_check)]) != rbd:
                return self._json(400, {"ok": False, "error": "invalid backup path"})
        if not os.path.isfile(src_models):
            return self._json(404, {"ok": False, "error": f"no models.yml backup for {ts}"})
        if not confirm_restart:
            return self._json(409, {"ok": False, "needs_confirm": True, "ts": ts,
                "reason": f"restoring {ts} overwrites models.yml" + (" + config.yaml" if os.path.isfile(src_config) else "")
                          + " (the current state is backed up first) and RESTARTS LiteLLM to load it — a brief drop for the whole fleet."})
        if not _apply_lock.acquire(blocking=False):
            return self._json(409, {"ok": False, "error": "another apply/restore is in progress — try again in a moment"})
        try:
            pre = _backup_sources()   # snapshot CURRENT state first -> the restore is itself reversible
            pre_models = next((p for p in pre if os.path.basename(p).startswith("models.yml.")), None)
            restored = []
            try:
                shutil.copy2(src_models, MODELS_YML); restored.append("models.yml")
                if os.path.isfile(src_config):
                    shutil.copy2(src_config, CONFIG); restored.append("config.yaml")
            except OSError as e:
                # AUTO-REVERT any partial write so disk is never left a mismatched pair: if models.yml
                # was already overwritten but config.yaml failed, copy models.yml back from the pre-backup.
                reverted = []
                if "models.yml" in restored and pre_models:
                    try:
                        shutil.copy2(pre_models, MODELS_YML); reverted.append("models.yml")
                    except OSError:
                        pass
                return self._json(500, {"ok": False, "error": f"restore copy failed: {e}",
                                        "reverted": reverted, "pre_restore_backup": pre})
            # Load the restored config into the running router — a docker restart (reloads the
            # mounted config.yaml), NOT a recreate (no new -e keys are involved in a rollback).
            restart_ok = False; restart_log = ""
            try:
                env = {k: v for k, v in os.environ.items() if not k.startswith("MC_")}
                p = subprocess.run([DOCKER, "restart", "litellm"], env=env, capture_output=True, text=True, timeout=120)
                restart_ok = (p.returncode == 0)
                restart_log = ((p.stderr or "") + (p.stdout or ""))[-400:]
            except Exception as e:
                restart_log = str(e)[:300]
            # Don't report success before the router is actually serving (mirrors cmd_sync's
            # litellm_wait_ready). ready=None means we didn't wait (restart failed or MC_RESTART_WAIT=0).
            ready = _litellm_ready(RESTART_WAIT) if (restart_ok and RESTART_WAIT > 0) else None
            # A restored config referencing a vendor key OUTSIDE the base -e set won't be re-injected by
            # a plain `docker restart` (start-litellm.sh injects those only on a recreate) -> surface it.
            recreate_hint = _nonfixed_keyenv_hint()
            return self._json(200, {"ok": True, "ts": ts, "restored": restored,
                                    "pre_restore_backup": pre, "restart_ok": restart_ok,
                                    "ready": ready, "restart_log": restart_log, "recreate_hint": recreate_hint})
        finally:
            _apply_lock.release()

    # ----------------------------------------------------------------- fallback editor
    def _fallback(self):
        """Edit one hand-curated LiteLLM failover chain (litellm_settings.fallbacks) via the
        `model fallback` CLI, then RESTART LiteLLM to load it. Mirrors _restore: validate via
        a --dry-run first (so a bad request is 400, not a half-applied edit), gate the restart
        behind confirm_restart, snapshot current state first (reversible), AUTO-REVERT if the
        router fails to come ready, and CHAIN_VERIFY the edit is actually live (bind-mount race)."""
        if READONLY:
            return self._json(403, {"ok": False, "error": "read-only mode: fallback edits are disabled (restart without --read-only)"})
        body, err = self._read_body()
        if err:
            return self._json(err[0], {"error": err[1]})
        args = body if isinstance(body, dict) else {}
        confirm_restart = bool(args.get("confirm_restart"))
        try:
            argv = build_argv("fallback", args, sync=True)
        except StageError as e:
            return self._json(400, {"ok": False, "error": str(e)})
        fb_op = _str(args, "fb_op"); model = _str(args, "model")
        over = {"CONFIG": CONFIG, "MODELS_YML": MODELS_YML}
        # --dry-run runs the SAME guards (existence, self-ref, metered/local-tier) without writing.
        rc, out, errs = run_model(argv + ["--dry-run"], env_override=over)
        if rc == 2:
            return self._json(400, {"ok": False, "error": (errs or out)[-800:]})
        if rc != 0:
            return self._json(500, {"ok": False, "error": (errs or out)[-1200:]})
        if not confirm_restart:
            return self._json(409, {"ok": False, "needs_confirm": True, "op": fb_op, "model": model,
                "preview": (errs or out)[-2000:],
                "reason": f"fallback {fb_op} '{model}' edits config.yaml and RESTARTS LiteLLM to load it — a brief drop for the whole fleet."})
        if not _apply_lock.acquire(blocking=False):
            return self._json(409, {"ok": False, "error": "another apply/restore is in progress — try again in a moment"})
        try:
            pre = _backup_sources()   # snapshot current state first -> the edit is reversible
            pre_config = next((p for p in pre if os.path.basename(p).startswith("config.yaml.")), None)
            rc, out, errs = run_model(argv, env_override=over)
            if rc == 2:
                return self._json(400, {"ok": False, "error": (errs or out)[-800:], "backups": pre})
            if rc != 0:
                return self._json(500, {"ok": False, "error": (errs or out)[-1200:], "backups": pre})
            # restart (NOT recreate — a fallback edit changes config content only, no new -e key).
            restart_ok = False; restart_log = ""
            try:
                env = {k: v for k, v in os.environ.items() if not k.startswith("MC_")}
                p = subprocess.run([DOCKER, "restart", "litellm"], env=env, capture_output=True, text=True, timeout=120)
                restart_ok = (p.returncode == 0)
                restart_log = ((p.stderr or "") + (p.stdout or ""))[-400:]
            except Exception as e:
                restart_log = str(e)[:300]
            ready = _litellm_ready(RESTART_WAIT) if (restart_ok and RESTART_WAIT > 0) else None
            reverted = False
            # AUTO-REVERT: if the router did NOT come ready, roll config.yaml back to the pre-edit
            # snapshot and restart again — never leave the fleet on a chain that won't load.
            if ready is False and pre_config and os.path.isfile(pre_config):
                try:
                    shutil.copy2(pre_config, CONFIG)
                    env = {k: v for k, v in os.environ.items() if not k.startswith("MC_")}
                    subprocess.run([DOCKER, "restart", "litellm"], env=env, capture_output=True, text=True, timeout=120)
                    reverted = True
                except Exception:
                    pass
            # CHAIN_VERIFY: re-read config.yaml and confirm the edit is actually live (restart_ok +
            # ready alone can be a false positive in the bind-mount cache window). None if we didn't wait.
            chain_verified = None
            if ready and not reverted:
                fbs = yq_json(".litellm_settings.fallbacks // []", CONFIG) or []
                present = any(isinstance(e, dict) and model in e for e in fbs)
                chain_verified = present if fb_op == "set" else (not present)
            return self._json(200, {"ok": True, "op": fb_op, "model": model,
                "output": out.strip()[-2000:], "restart_ok": restart_ok, "ready": ready,
                "reverted": reverted, "chain_verified": chain_verified, "restart_log": restart_log,
                "backups": pre})
        finally:
            _apply_lock.release()

    # ----------------------------------------------------------------- static / html
    def _serve_html(self):
        if not HTML or not os.path.isfile(HTML):
            return self._json(503, {"error": "MODELS.html not found; build it first"})
        with open(HTML, "rb") as f:
            data = f.read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers(); self.wfile.write(data)

    def _redirect(self, location):
        self.send_response(302)
        self.send_header("Location", location)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _serve_static(self, path):
        if not ROOT or "\x00" in path:
            return False
        rel = posixpath.normpath(path.lstrip("/"))
        if not rel or rel == "." or rel.startswith("..") or os.path.isabs(rel):
            return False
        parts = rel.split("/")
        if any(p.startswith(".") for p in parts):
            return False
        ext = os.path.splitext(rel)[1].lower()
        ctype = STATIC_TYPES.get(ext)
        if not ctype:
            return False
        full = os.path.realpath(os.path.join(ROOT, rel))
        if os.path.commonpath([ROOT, full]) != ROOT or not os.path.isfile(full):
            return False
        try:
            with open(full, "rb") as f:
                data = f.read()
        except OSError:
            return False
        self.send_response(200)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-cache")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers(); self.wfile.write(data)
        return True


def _extract_plan(dry_out):
    """Pull the indented config.yaml registration diff block from `model sync --dry-run`
    stdout (the lines between 'registration plan' and the next 'P3'/'P4' marker)."""
    lines = dry_out.splitlines()
    out, capturing = [], False
    for ln in lines:
        if "registration plan" in ln:
            capturing = True
            continue
        if capturing:
            if ln.lstrip().startswith(("P3", "P4", "·")) and ("widening plan" in ln or "render plan" in ln):
                break
            if "(config.yaml already current" in ln:
                return ""
            out.append(ln)
    return "\n".join(l for l in out if l.strip()).strip()


BACKUP_DIR = os.path.join(ROOT, "installer", "state", "model-console-backups") if ROOT else ""
BACKUP_KEEP = 10   # retain the last N timestamped copies per source (prune the rest)


def _backup_sources():
    """Timestamped copies of models.yml/config.yaml/.env so apply is reversible (council
    change 7). Written to installer/state/model-console-backups/ (a gitignored state dir)
    — NOT beside the originals (which are git-tracked, so backups there became `git status`
    noise + unbounded growth). Pruned to the last BACKUP_KEEP per source. A failed copy is
    surfaced (stderr), never silently swallowed, so a missing backup can't masquerade as a
    successful one. Returns the list of backup paths."""
    if not BACKUP_DIR:
        return []
    try:
        os.makedirs(BACKUP_DIR, exist_ok=True)
    except OSError as e:
        print(f"models_proxy: WARNING could not create backup dir {BACKUP_DIR}: {e}", file=sys.stderr)
        return []
    ts = time.strftime("%Y%m%d-%H%M%S")
    made = []
    for src in (MODELS_YML, CONFIG, ENV_FILE):
        if not (src and os.path.isfile(src)):
            continue
        base = os.path.basename(src)
        dst = os.path.join(BACKUP_DIR, f"{base}.{ts}")
        try:
            shutil.copy2(src, dst); made.append(dst)
        except OSError as e:
            print(f"models_proxy: WARNING backup of {src} failed: {e}", file=sys.stderr)
            continue
        # prune: keep the most-recent BACKUP_KEEP for THIS source basename. Safe because the
        # three sources (models.yml, config.yaml, .env) have DISTINCT basenames, so the
        # startswith(base+".") filter never matches another source's backups.
        try:
            old = sorted(g for g in os.listdir(BACKUP_DIR) if g.startswith(base + "."))
            for g in old[:-BACKUP_KEEP]:
                os.remove(os.path.join(BACKUP_DIR, g))
        except OSError:
            pass
    return made


def _is_backup_ts(s):
    """A backup timestamp is exactly YYYYMMDD-HHMMSS (the strftime format _backup_sources
    writes). Validating this also forbids path-traversal in the restore 'ts' (no '/', '.')."""
    return isinstance(s, str) and len(s) == 15 and s[8] == "-" and s[:8].isdigit() and s[9:].isdigit()


def _litellm_ready(timeout):
    """Poll LiteLLM /health/readiness up to `timeout`s; True once it 200s, else False. Used so a
    restore doesn't report success before the restarted router is actually serving."""
    end = time.monotonic() + timeout
    url = LITELLM + "/health/readiness"
    while time.monotonic() < end:
        try:
            with urllib.request.urlopen(url, timeout=3) as r:
                if r.status == 200:
                    return True
        except Exception:
            pass
        time.sleep(1)
    return False


def _nonfixed_keyenv_hint():
    """If the (restored) config.yaml routes reference a vendor key_env OUTSIDE the base -e set,
    a plain `docker restart` won't inject it (start-litellm.sh does that only on a recreate).
    Return a one-line operator hint naming those keys, or '' if none."""
    if not (CONFIG and os.path.isfile(CONFIG)):
        return ""
    ml = yq_json(".model_list // []", CONFIG) or []
    nonfixed = set()
    for entry in ml:
        if not isinstance(entry, dict):
            continue
        ak = (entry.get("litellm_params") or {}).get("api_key", "")
        if isinstance(ak, str) and ak.startswith("os.environ/"):
            ke = ak.split("/", 1)[1]
            if ke and ke not in FIXED_KEY_ENVS:
                nonfixed.add(ke)
    if not nonfixed:
        return ""
    return ("restored config references vendor key(s) %s outside the base set; if a route 401s, "
            "recreate LiteLLM: bash bin/start-litellm.sh" % ", ".join(sorted(nonfixed)))


def _list_backups():
    """Group BACKUP_DIR files (<basename>.<ts>) into restore sets, newest first. Returns
    [{ts, models, config, env}] booleans — which of the three sources exist for each ts.
    Read-only; surfaces nothing but timestamps + presence flags."""
    if not BACKUP_DIR or not os.path.isdir(BACKUP_DIR):
        return []
    KNOWN = {"models.yml": "models", "config.yaml": "config", ".env": "env"}
    try:
        names = os.listdir(BACKUP_DIR)
    except OSError:
        return []
    sets = {}
    for fn in names:
        base, _, ts = fn.rpartition(".")
        if base not in KNOWN or not _is_backup_ts(ts):
            continue
        e = sets.setdefault(ts, {"ts": ts, "models": False, "config": False, "env": False})
        e[KNOWN[base]] = True
    return sorted(sets.values(), key=lambda x: x["ts"], reverse=True)


def main():
    for need, label in ((MODELS_SH, "MC_MODELS_SH"), (ROOT, "MC_ROOT")):
        if not need:
            print(f"models_proxy: {label} not set (the launcher sets it)", file=sys.stderr); sys.exit(2)
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), H)
    mode = "READ-ONLY (no applies)" if READONLY else "read/write"
    print(f"models-serve: http://127.0.0.1:{PORT}  ({mode}; Ctrl-C to stop)")
    print(f"  wraps the `model` CLI — stage shows a both-file diff, apply backs up + is recreate-gated")
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        srv.server_close()


if __name__ == "__main__":
    main()
