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
LITELLM_MODELS = ["local", "local-heavy", "local-lfm2"]
HERMES_SANDBOX = "hermes-fleet-v1"
PI_SANDBOX = "pi-v1"
DEERFLOW_URL = os.environ.get("DEERFLOW_URL", "http://localhost:2026")
DEERFLOW_AUTH = os.environ.get("DEER_FLOW_INTERNAL_AUTH_TOKEN", "")
HERMES_TIMEOUT = int(os.environ.get("CLAW3D_HERMES_TIMEOUT", "120"))
PI_TIMEOUT = int(os.environ.get("CLAW3D_PI_TIMEOUT", "120"))
DEERFLOW_TIMEOUT = int(os.environ.get("CLAW3D_DEERFLOW_TIMEOUT", "600"))
DEFAULT_MODEL = os.environ.get("CLAW3D_DEFAULT_MODEL", "local")

# --- Agent registry: ONE place to add/remove agents shown in the office. ------
# kind: "chat" (v1) | "task-launcher" (reserved, e.g. AutoFyn). backend selects the adapter.
AGENTS = [
    {"id": "hermes_cos", "name": "Chief of Staff", "role": "orchestrator", "emoji": "🧭",
     "kind": "chat", "backend": "hermes", "profile": "hermes_cos"},
    {"id": "hermes_software_engineer", "name": "Software Engineer", "role": "engineer", "emoji": "🛠️",
     "kind": "chat", "backend": "hermes", "profile": "hermes_software_engineer"},
    {"id": "hermes_researcher", "name": "Researcher", "role": "researcher", "emoji": "🔬",
     "kind": "chat", "backend": "hermes", "profile": "hermes_researcher"},
    {"id": "hermes_creator", "name": "Creator", "role": "writer", "emoji": "✍️",
     "kind": "chat", "backend": "hermes", "profile": "hermes_creator"},
    {"id": "hermes_reviewer", "name": "Reviewer", "role": "reviewer", "emoji": "🔎",
     "kind": "chat", "backend": "hermes", "profile": "hermes_reviewer"},
    {"id": "hermes_data_analyst", "name": "Data Analyst", "role": "analyst", "emoji": "📊",
     "kind": "chat", "backend": "hermes", "profile": "hermes_data_analyst"},
    {"id": "hermes_ops", "name": "Ops Engineer", "role": "ops", "emoji": "⚙️",
     "kind": "chat", "backend": "hermes", "profile": "hermes_ops"},
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


# --- Backend adapters: each returns assistant text or raises RuntimeError -----
def run_hermes(profile: str, prompt: str, model: str) -> str:
    if not _sandbox_ready(HERMES_SANDBOX):
        raise RuntimeError("hermes-fleet-v1 not reachable (OpenShell relay down? `brew services restart openshell`)")
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


def run_pi(prompt: str, model: str) -> str:
    if not _sandbox_ready(PI_SANDBOX):
        raise RuntimeError("pi-v1 not reachable (OpenShell relay down? `brew services restart openshell`)")
    pi_key = _get_env("PI_LITELLM_KEY")
    inner = (f'PI_LITELLM_KEY={pi_key} HOME=/sandbox '
             f'/sandbox/node_modules/.bin/pi -p '
             f'--extension /sandbox/.pi/extensions/inference-local.ts '
             f'--provider openai --model {model} --no-tools {json.dumps(prompt)}')
    cmd = [_openshell(), "sandbox", "exec", "-n", PI_SANDBOX, "--no-tty",
           "--timeout", str(PI_TIMEOUT), "--", "/bin/sh", "-c", inner]
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=PI_TIMEOUT + 15)
    if "relay open timed out" in (out.stderr or "") or "DeadlineExceeded" in (out.stderr or ""):
        raise RuntimeError("OpenShell relay timed out — sandbox unavailable (restart openshell)")
    text = _strip(out.stdout).strip()
    if not text and out.returncode != 0:
        raise RuntimeError(_strip(out.stderr)[:300] or "pi returned no output")
    return text


def run_deerflow(prompt: str, model: str) -> str:
    body = json.dumps({
        "input": {"messages": [{"type": "human", "content": prompt}]},
        "config": {"configurable": {"thread_id": "claw3d-bridge"}},
        "context": {"model_name": model},
    }).encode()
    url = f"{DEERFLOW_URL}/api/langgraph/threads/claw3d-bridge/runs/wait"
    req = urllib.request.Request(url, data=body, method="POST",
                                 headers={"Content-Type": "application/json"})
    if DEERFLOW_AUTH:
        req.add_header("X-Internal-Auth", DEERFLOW_AUTH)
        req.add_header("Authorization", f"Bearer {DEERFLOW_AUTH}")
    try:
        with urllib.request.urlopen(req, timeout=DEERFLOW_TIMEOUT) as r:
            data = json.loads(r.read().decode())
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"deerflow HTTP {e.code}: {e.read()[:200]!r}")
    except Exception as e:  # noqa: BLE001
        raise RuntimeError(f"deerflow unreachable: {e}")
    # LangGraph /runs/wait returns the final state; pull the last AI message.
    msgs = (data or {}).get("messages") or (data.get("values", {}) or {}).get("messages", [])
    for m in reversed(msgs):
        if m.get("type") in ("ai", "assistant") or m.get("role") == "assistant":
            c = m.get("content", "")
            return c if isinstance(c, str) else json.dumps(c)
    return json.dumps(data)[:2000]


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
        agent_id = req.get("role") or req.get("model") or req.get("agent") or "hermes_cos"
        agent = AGENTS_BY_ID.get(agent_id) or AGENTS_BY_ID.get("hermes_cos")
        model = DEFAULT_MODEL
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
