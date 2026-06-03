#!/usr/bin/env python3
"""claw3d ↔ ai-stack agents bridge.

Implements claw3d's "custom HTTP runtime" contract so ONE upstream surfaces ALL
of the stack's isolated/independent agents in a single 3D office:

  GET  /health              -> {"ok": true, "status": "..."}
  GET  /state               -> {profileName, active:{<agent_id>:[models]}, identity, runtime}
  GET  /registry            -> {"models": {<model_id>: {...}}}
  POST /v1/chat/completions -> {choices:[{message:{role,content}}]}   (routes to the real agent)

Authentic routing (per agent KIND):
  - kind="chat":          a message is sent to the REAL backend and the reply returned.
      backend "hermes":   openshell sandbox exec -n hermes-fleet-v1 -- hermes --profile <p> --yolo -z "<msg>"
      backend "pi":       openshell sandbox exec -n pi-v1 -- pi -p ... "<msg>"   (LiteLLM-routed extension)
      backend "deerflow": POST http://localhost:2026/api/langgraph/threads/{id}/runs/wait  (LangGraph)
  - kind="task-launcher": NOT implemented in v1 — reserved for AutoFyn (a control that starts a
      long autonomous run rather than a chat turn). The registry/dispatch already carry the field
      so it's an additive change, not a rewrite.

Design notes:
  - Runs on the HOST (it shells out to `openshell` and calls host-reachable HTTP). No secrets are
    logged. The OpenShell relay must be UP for the hermes/pi backends; if it's idle-timed-out the
    bridge returns a graceful "agent unavailable" instead of hanging.
  - Stdlib only (http.server) so it needs no venv/deps and starts instantly.
"""
from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import urllib.request
import urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

AI_STACK = os.path.expanduser("~/ai-stack")
# Allowlist of LiteLLM model_names the bridge will forward. Includes the 3
# canonical model<->agent slugs (installer/models.yml) alongside the legacy IDs —
# otherwise _safe_model() would strip a forwarded canonical model back to the
# default and the agent's bound model would be silently ignored.
LITELLM_MODELS = [
    "local", "local-heavy", "local-lfm2",
    "local-gemma4", "local-qwen3.6", "local-qwen3-coder",
]
# LM Studio MLX slugs among the above (used for best-effort pre-warm).
LMSTUDIO_MODELS = {"local-qwen3.6": "qwen/qwen3.6-27b",
                   "local-qwen3-coder": "qwen3-coder-30b-a3b-instruct-mlx"}
HERMES_SANDBOX = "hermes-fleet-v1"
PI_SANDBOX = "pi-v1"
DEERFLOW_URL = os.environ.get("DEERFLOW_URL", "http://localhost:2026")
DEERFLOW_AUTH = os.environ.get("DEER_FLOW_INTERNAL_AUTH_TOKEN", "")
HERMES_TIMEOUT = int(os.environ.get("CLAW3D_HERMES_TIMEOUT", "120"))
# Pi on a big MLX coder model (local-qwen3-coder) is much slower than gemma4;
# raised 180 -> 600 so a real coder turn doesn't get cut off.
PI_TIMEOUT = int(os.environ.get("CLAW3D_PI_TIMEOUT", "600"))
DEERFLOW_TIMEOUT = int(os.environ.get("CLAW3D_DEERFLOW_TIMEOUT", "600"))
DEFAULT_MODEL = os.environ.get("CLAW3D_DEFAULT_MODEL", "local")

# --- Agent registry: ONE place to add/remove agents shown in the office. ------
# kind: "chat" (v1) | "task-launcher" (reserved, e.g. AutoFyn). backend selects the adapter.
AGENTS = [
    # The 9-role engineering team (replaced the legacy 7 profiles 2026-06-02).
    {"id": "hermes_manager", "name": "Manager", "role": "orchestrator", "emoji": "🧭",
     "kind": "chat", "backend": "hermes", "profile": "hermes_manager"},
    {"id": "hermes_techlead", "name": "Tech Lead", "role": "architect", "emoji": "🏛️",
     "kind": "chat", "backend": "hermes", "profile": "hermes_techlead"},
    {"id": "hermes_frontend_engineer", "name": "Frontend Engineer", "role": "frontend", "emoji": "🎨",
     "kind": "chat", "backend": "hermes", "profile": "hermes_frontend_engineer"},
    {"id": "hermes_backend_engineer", "name": "Backend Engineer", "role": "backend", "emoji": "🛠️",
     "kind": "chat", "backend": "hermes", "profile": "hermes_backend_engineer"},
    {"id": "hermes_ml_engineer", "name": "ML Engineer", "role": "ml", "emoji": "🧠",
     "kind": "chat", "backend": "hermes", "profile": "hermes_ml_engineer"},
    {"id": "hermes_qa_test_engineer", "name": "QA / Test Engineer", "role": "qa", "emoji": "🧪",
     "kind": "chat", "backend": "hermes", "profile": "hermes_qa_test_engineer"},
    {"id": "hermes_reviewing_engineer", "name": "Reviewing Engineer", "role": "reviewer", "emoji": "🔎",
     "kind": "chat", "backend": "hermes", "profile": "hermes_reviewing_engineer"},
    {"id": "hermes_sre_engineer", "name": "SRE", "role": "sre", "emoji": "⚙️",
     "kind": "chat", "backend": "hermes", "profile": "hermes_sre_engineer"},
    {"id": "hermes_incident_manager", "name": "Incident Manager", "role": "incident", "emoji": "🚨",
     "kind": "chat", "backend": "hermes", "profile": "hermes_incident_manager"},
    {"id": "pi", "name": "Pi", "role": "coding-agent", "emoji": "🥧",
     "kind": "chat", "backend": "pi"},
    {"id": "deerflow", "name": "DeerFlow", "role": "researcher", "emoji": "🦌",
     "kind": "chat", "backend": "deerflow"},
    # Future (kind="task-launcher", excluded from v1 — see module docstring):
    # {"id": "autofyn", "name": "AutoFyn", "role": "code-automation", "emoji": "🤖",
    #  "kind": "task-launcher", "backend": "autofyn"},
]
AGENTS_BY_ID = {a["id"]: a for a in AGENTS}

ANSI = re.compile(r"\x1b\[[0-9;]*m")


def _strip(s: str) -> str:
    return ANSI.sub("", s or "")


def _openshell() -> str:
    for c in ("/opt/homebrew/bin/openshell", shutil.which("openshell") or ""):
        if c and os.path.exists(c):
            return c
    return "openshell"


def _get_env(key: str) -> str:
    """Read a value from ~/ai-stack/.env without exposing it in logs."""
    p = os.path.join(AI_STACK, ".env")
    try:
        for line in open(p):
            if line.startswith(key + "="):
                return line.split("=", 1)[1].strip()
    except OSError:
        pass
    return ""


def _last_user_message(messages: list) -> str:
    for m in reversed(messages or []):
        if m.get("role") == "user":
            c = m.get("content", "")
            return c if isinstance(c, str) else json.dumps(c)
    return ""


def _sandbox_ready(name: str) -> bool:
    """Fast (<=5s) check that the OpenShell relay is alive + the sandbox is Ready.
    Lets chat calls fail fast with 'unavailable' instead of blocking on a long
    exec when the relay is idle-timed-out (HANDOFF §2.1)."""
    try:
        out = subprocess.run([_openshell(), "sandbox", "get", name],
                             capture_output=True, text=True, timeout=6)
    except subprocess.TimeoutExpired:
        return False
    return "Ready" in _strip(out.stdout) and "relay open timed out" not in _strip(out.stderr)


def _safe_model(model: str) -> str:
    """Allowlist the model name (CWE-88: a value starting with '-' could be parsed
    as a CLI flag). Only the known LiteLLM model aliases are permitted; anything
    else falls back to the default."""
    return model if model in LITELLM_MODELS else DEFAULT_MODEL


# --- Backend adapters: each returns assistant text or raises RuntimeError -----
def run_hermes(profile: str, prompt: str, model: str) -> str:
    if not _sandbox_ready(HERMES_SANDBOX):
        raise RuntimeError("hermes-fleet-v1 not reachable (OpenShell relay down? `brew services restart openshell`)")
    model = _safe_model(model)
    # prompt is the VALUE of -z (hermes' arg parser consumes the next token as the
    # prompt; a leading-'-' prompt errors rather than injecting). model is
    # allowlisted above. No '--' here — that only applies to positional args.
    cmd = [_openshell(), "sandbox", "exec", "-n", HERMES_SANDBOX, "--no-tty",
           "--timeout", str(HERMES_TIMEOUT), "--",
           "hermes", "--profile", profile, "--yolo", "-m", model, "-z", prompt]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=HERMES_TIMEOUT + 15)
    text = _strip(out.stdout).strip()
    if "relay open timed out" in (out.stderr or "") or "DeadlineExceeded" in (out.stderr or ""):
        raise RuntimeError("OpenShell relay timed out — sandbox unavailable (restart openshell)")
    if not text and out.returncode != 0:
        raise RuntimeError(_strip(out.stderr)[:300] or "hermes returned no output")
    return text


def _lms_cli() -> str:
    for c in (os.path.expanduser("~/.lmstudio/bin/lms"),
              "/Applications/LM Studio.app/Contents/Resources/app/.webpack/lms"):
        if os.path.exists(c):
            return c
    return ""


def _prewarm_lmstudio(model: str) -> None:
    """Best-effort: if `model` is an LM Studio MLX slug, `lms load` its served id
    before the Pi turn so the first request doesn't time out on a cold load.
    Never raises — a missing CLI / down server just means no pre-warm."""
    served = LMSTUDIO_MODELS.get(model)
    if not served:
        return
    lms = _lms_cli()
    if not lms:
        return
    try:
        subprocess.run([lms, "load", served, "--identifier", served, "--ttl", "1800", "-y"],
                       capture_output=True, text=True, timeout=120)
    except Exception:  # noqa: BLE001 — pre-warm is best-effort
        pass


def run_pi(prompt: str, model: str) -> str:
    if not _sandbox_ready(PI_SANDBOX):
        raise RuntimeError("pi-v1 not reachable (OpenShell relay down? `brew services restart openshell`)")
    pi_key = _get_env("PI_LITELLM_KEY")
    # Use the PASSED-THROUGH model (allowlisted via _safe_model), NOT a hardcoded
    # 'local'. This is what lets Pi run on its bound model (local-qwen3-coder when
    # LM Studio is up). _safe_model already strips anything not in LITELLM_MODELS
    # back to DEFAULT_MODEL (CWE-88: no leading '-' reaching argv).
    model = _safe_model(model)
    # Best-effort pre-warm: load the MLX coder model before the turn so a cold
    # ~17GB load doesn't eat the whole PI_TIMEOUT on the first request.
    _prewarm_lmstudio(model)
    # `--thinking off` is REQUIRED: Pi's default sends reasoning_effort as a
    # dict, which crashes LiteLLM's Ollama transform (TypeError: unhashable type).
    # SECURITY: (CWE-78) prompt/model/key are separate argv via `env` (no shell);
    # (CWE-88) the trailing `--` keeps a leading-'-' prompt positional.
    # The inference-local extension auto-loads from HOME=/sandbox/.pi/extensions, so
    # no --extension; no --no-tools (broke the run). pi has NO `--` end-of-options
    # separator (it errors "Unknown option: --"), so to keep a flag-like prompt from
    # being parsed as an option (CWE-88), prepend a space — pi then treats it as the
    # positional prompt (content preserved). The "Model ... not found" line is a
    # benign warning; pi proceeds with it as a custom model id via the extension.
    if prompt[:1] == "-":
        prompt = " " + prompt
    cmd = [_openshell(), "sandbox", "exec", "-n", PI_SANDBOX, "--no-tty",
           "--timeout", str(PI_TIMEOUT), "--",
           "env", f"PI_LITELLM_KEY={pi_key}", "HOME=/sandbox",
           "/sandbox/node_modules/.bin/pi",
           "--provider", "openai", "--model", model, "--thinking", "off",
           "-p", prompt]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=PI_TIMEOUT + 15)
    if "relay open timed out" in (out.stderr or "") or "DeadlineExceeded" in (out.stderr or ""):
        raise RuntimeError("OpenShell relay timed out — sandbox unavailable (restart openshell)")
    # Pi prints Node/UNDICI warnings before the answer — drop them.
    lines = [ln for ln in _strip(out.stdout).splitlines()
             if ln.strip() and not any(w in ln for w in ("UNDICI", "Warning:", "experimental", "trace-warnings"))]
    text = "\n".join(lines).strip()
    if not text and out.returncode != 0:
        raise RuntimeError(_strip(out.stderr)[:300] or "pi returned no output")
    return text


def _deerflow_token() -> str:
    t = os.environ.get("DEER_FLOW_INTERNAL_AUTH_TOKEN", "")
    if t:
        return t
    try:  # deploy.sh persists it here
        return open(os.path.join(AI_STACK, "deer-flow", "backend", ".deer-flow", ".internal-auth-token")).read().strip()
    except OSError:
        return ""


_DF_CSRF = "claw3d-bridge"  # any value; X-CSRF-Token header + csrf_token cookie must match


def _df_request(path: str, token: str, payload) -> dict:
    body = json.dumps(payload).encode()
    req = urllib.request.Request(f"{DEERFLOW_URL}{path}", data=body, method="POST", headers={
        "Content-Type": "application/json",
        "X-DeerFlow-Internal-Token": token,   # internal-auth bypass (no login cookie)
        "X-CSRF-Token": _DF_CSRF,
        "Cookie": f"csrf_token={_DF_CSRF}",
    })
    with urllib.request.urlopen(req, timeout=DEERFLOW_TIMEOUT) as r:
        raw = r.read().decode()
    return json.loads(raw) if raw.strip() else {}


def run_deerflow(prompt: str, model: str) -> str:
    token = _deerflow_token()
    if not token:
        raise RuntimeError("DeerFlow internal-auth token not found (set DEER_FLOW_INTERNAL_AUTH_TOKEN or run Phase 10)")
    model = _safe_model(model)
    tid = "claw3d-bridge"
    try:
        # Ensure the thread exists (idempotent), then block on a run.
        try:
            _df_request("/api/threads", token, {"thread_id": tid, "if_exists": "do_nothing"})
        except urllib.error.HTTPError:
            pass  # already exists / not required
        data = _df_request(f"/api/threads/{tid}/runs/wait", token, {
            "input": {"messages": [{"role": "user", "content": prompt}]},
            "config": {"configurable": {"thread_id": tid, "model_name": model}},
            "context": {"model_name": model},
        })
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"deerflow HTTP {e.code}: {e.read()[:200]!r}")
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(f"deerflow unreachable: {e}")
    msgs = (data or {}).get("messages") or (data.get("values", {}) or {}).get("messages", [])
    for m in reversed(msgs):
        if m.get("type") in ("ai", "assistant") or m.get("role") == "assistant":
            c = m.get("content", "")
            return c if isinstance(c, str) else json.dumps(c)
    return (json.dumps(data)[:1500]) if data else "[DeerFlow returned no message]"


def dispatch(agent: dict, prompt: str, model: str) -> str:
    if agent.get("kind") != "chat":
        raise RuntimeError(f"agent '{agent['id']}' is kind={agent.get('kind')} (not chat) — not supported in v1")
    b = agent["backend"]
    if b == "hermes":
        return run_hermes(agent["profile"], prompt, model)
    if b == "pi":
        return run_pi(prompt, model)
    if b == "deerflow":
        return run_deerflow(prompt, model)
    raise RuntimeError(f"unknown backend '{b}'")


def state_payload() -> dict:
    # claw3d derives one agent per key in `active`. Map each agent -> its models.
    active = {a["id"]: LITELLM_MODELS for a in AGENTS if a.get("kind") == "chat"}
    return {
        "profileName": "ai-stack",
        "active": active,
        "agents": [{"id": a["id"], "name": a["name"], "role": a["role"],
                    "identity": {"name": a["name"], "emoji": a["emoji"]}}
                   for a in AGENTS if a.get("kind") == "chat"],
        "identity": {"name": "ai-stack", "role": "orchestrator", "lane": "local"},
        "runtime": {"name": "ai-stack-bridge", "version": "1", "vendor": "ai-stack",
                    "status": "ready", "active_model": DEFAULT_MODEL},
    }


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):  # quieter; never logs bodies (avoid leaking prompts)
        return

    def _send(self, code: int, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path.rstrip("/") in ("/health", ""):
            return self._send(200, {"ok": True, "status": "ready"})
        if self.path.rstrip("/") == "/state":
            return self._send(200, state_payload())
        if self.path.rstrip("/") == "/registry":
            return self._send(200, {"models": {m: {"id": m, "provider": "litellm"} for m in LITELLM_MODELS}})
        return self._send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.rstrip("/") != "/v1/chat/completions":
            return self._send(404, {"error": "not found"})
        try:
            n = int(self.headers.get("Content-Length", "0"))
            req = json.loads(self.rfile.read(n) or b"{}")
        except Exception:  # noqa: BLE001
            return self._send(400, {"error": "bad json"})
        agent_id = req.get("role") or req.get("model") or req.get("agent") or "hermes_manager"
        agent = AGENTS_BY_ID.get(agent_id) or AGENTS_BY_ID.get("hermes_manager")
        # Honor each agent's BOUND model (installer/models.yml, rendered into .env
        # by `model sync`). Pi reads PI_DEFAULT_MODEL (already availability-gated:
        # local-qwen3-coder when LM Studio is up, else `local`). Other backends keep
        # the bridge default. _safe_model() (in the adapters) re-allowlists it.
        model = DEFAULT_MODEL
        if agent.get("backend") == "pi":
            model = _get_env("PI_DEFAULT_MODEL") or DEFAULT_MODEL
        prompt = _last_user_message(req.get("messages"))
        if not prompt:
            return self._send(400, {"error": "no user message"})
        try:
            text = dispatch(agent, prompt, model)
        except Exception as e:  # noqa: BLE001 — surface as a chat message, don't 500 the office
            text = f"[{agent['name']} unavailable] {e}"
        return self._send(200, {
            "id": "claw3d-bridge", "object": "chat.completion", "model": agent["id"],
            "choices": [{"index": 0, "message": {"role": "assistant", "content": text},
                         "finish_reason": "stop"}],
        })


def main():
    host = os.environ.get("CLAW3D_BRIDGE_HOST", "127.0.0.1")
    port = int(os.environ.get("CLAW3D_BRIDGE_PORT", "7780"))
    srv = ThreadingHTTPServer((host, port), Handler)
    print(f"claw3d-bridge listening on http://{host}:{port} "
          f"({sum(1 for a in AGENTS if a.get('kind') == 'chat')} chat agents)")
    srv.serve_forever()


if __name__ == "__main__":
    main()
