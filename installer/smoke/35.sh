#!/usr/bin/env bash
# smoke/35.sh — Phase 35 (ChatDev) E2E gate. Proves a REAL ChatDev agent ran through
# LiteLLM on the scoped key — not just an HTTP 200 from the web app.
#
# It runs a headless 1-agent ChatDev workflow INSIDE the backend container (which has
# the ChatDev SDK + the .env wiring: BASE_URL=http://litellm:4000/v1, API_KEY=the
# scoped key). The workflow uses the SDK `runtime.sdk.run_workflow` (verified path,
# 2026-06-23) with the upstream gotchas baked in: NO `protocol: chat` in node params
# (upstream TypeError) and max_tokens>=512 (the reasoning model returns empty content
# at small budgets — the demo's 16 is too low).
#
# The embedded sim self-bounds with signal.alarm (macOS/containers: no `timeout`) and
# uses distinct exit codes: 0=agent produced non-empty output, 3=agent failed (401 key,
# empty content, or no output), 4=ChatDev SDK import drift, 5=run_workflow API drift.
# A non-empty agent reply is the routing proof (a placeholder/401 key yields nothing),
# stronger than a spend delta (default local bills $0).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/network.sh"
aliases_load

hdr "Smoke 35 — ChatDev (headless 1-agent workflow -> LiteLLM)"

NAME=chatdev
BE_NAME=chatdev-backend
FE_IP="${ALIAS_IP[chatdev]:-127.0.10.18}"
FE_HOST_PORT="${ALIAS_HOST_PORT[chatdev]:-5274}"
BE_PORT="${CHATDEV_BACKEND_PORT:-6400}"
# The model is NOT read here: the workflow runs INSIDE the backend container, which
# reads MODEL from its own .env (via --env-file) — the value the phase resolved from
# models.yml. A host-side `get_env CHATDEV_MODEL` would read $AI_STACK/.env (a key the
# phase never writes there) and silently return the default, hiding the binding path.

# 1. Both containers exist + the backend is the one we run the workflow in.
container_running "$BE_NAME" || { err "$BE_NAME not running — run: vz-ai-stack.sh start chatdev"; exit 1; }
ok "$BE_NAME container running"

# 2. Frontend serves 200 (the web app is up).
code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 6 "http://$FE_IP:$FE_HOST_PORT/" 2>/dev/null || true)"
[[ "$code" == "200" ]] && ok "frontend serves HTTP 200 on http://$FE_IP:$FE_HOST_PORT" \
  || { err "frontend not serving 200 on :$FE_HOST_PORT (got $code) — 'vz-ai-stack.sh start chatdev'; logs: docker logs $NAME"; exit 1; }

# 3. The scoped key lists models through LiteLLM (a stale/revoked key returns 200 +
#    empty data[], so require a real "id"). Probed from the HOST against the loopback.
KEY="$(get_env CHATDEV_LITELLM_KEY '')"
[[ -n "$KEY" ]] || { err "CHATDEV_LITELLM_KEY absent from .env"; exit 1; }
printf '%s' "$(litellm_scoped_curl "$KEY" -s --max-time 5 http://127.0.0.1:4000/v1/models 2>/dev/null)" | grep -q '"id"' \
  && ok "scoped key lists models via LiteLLM" || { err "CHATDEV_LITELLM_KEY lists no models (stale/rejected)"; exit 1; }

# 4. Run the headless 1-agent workflow INSIDE the backend container (the real agent
#    path: ChatDev SDK → LiteLLM on the scoped key, container-to-container Docker DNS).
log "Running a headless 1-agent ChatDev workflow inside $BE_NAME (real swarm step; bounded by the sim's 180s alarm)…"
read -r -d '' PYSIM <<'PYEOF' || true
"""ChatDev smoke: prove the ChatDev SDK drives ONE role agent through LiteLLM.
Reads BASE_URL/API_KEY/MODEL from env (the container's .env). Prints
'CHATDEV_SMOKE_OK output_chars=N' and exits 0 only when the agent produced non-empty
output. Exit codes: 0=ok, 3=empty/failed call, 4=SDK import drift, 5=workflow API drift.
Gotchas honored: NO `protocol: chat` node param (upstream TypeError); max_tokens=512
(the reasoning model returns empty content at tiny budgets)."""
import os, sys, signal, tempfile, textwrap
signal.alarm(180)

BASE  = os.environ.get("BASE_URL", "http://litellm:4000/v1")
KEY   = os.environ.get("API_KEY", "")
MODEL = os.environ.get("MODEL", "local")

# Resolve the ChatDev SDK entrypoint. ChatDev 2.0 exposes a runtime with an SDK that
# runs a workflow YAML; the exact module path is probed defensively so a minor
# reorg fails as "API drift" (5), distinct from an auth/routing failure (3).
run_workflow = None
try:
    try:
        from runtime.sdk import run_workflow as _rw       # VERIFIED path (project=DevAll, top-level module `runtime`; backend WORKDIR=/app)
        run_workflow = _rw
    except Exception:
        from chatdev.runtime import sdk as _sdk           # fallback (older/alt namespaced layout)
        run_workflow = _sdk.run_workflow
except Exception as e:
    print(f"CHATDEV_SMOKE_IMPORT_FAIL: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(4)

# A minimal 1-agent workflow YAML. The single node points at ${BASE_URL}/${API_KEY}
# (env-substituted by ChatDev) and its `name:` is the LiteLLM model id. NO `protocol`
# key (upstream TypeError). max_tokens 512 so a reasoning model emits real content.
WF = textwrap.dedent(f"""
    version: 0.0.0
    vars: {{}}
    graph:
      id: ai-stack-smoke
      description: minimal 1-agent LiteLLM routing smoke
      is_majority_voting: false
      start:
        - writer
      nodes:
        - id: writer
          type: agent
          config:
            name: {MODEL}
            provider: openai
            role: "You are a Python developer. Reply with ONLY a one-line Python function, no prose."
            base_url: ${{BASE_URL}}
            api_key: ${{API_KEY}}
            params:
              max_tokens: 512
              temperature: 0.7
      edges: []
""").strip()

os.environ.setdefault("BASE_URL", BASE)
os.environ.setdefault("API_KEY", KEY)

with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
    f.write(WF); wf_path = f.name

try:
    # VERIFIED signature: run_workflow(yaml_file, *, task_prompt, variables=..., ...).
    # task_prompt is keyword-only + REQUIRED; variables injects ${BASE_URL}/${API_KEY}
    # (the scoped key) into the node config so the agent routes through LiteLLM.
    result = run_workflow(
        wf_path,
        task_prompt="Write a one-line Python function that returns the string 'hello'.",
        variables={"BASE_URL": BASE, "API_KEY": KEY},
    )
except TypeError as e:  # signature drift (e.g. task_prompt renamed) — distinct from a routing failure
    print(f"CHATDEV_SMOKE_API_FAIL: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(5)
except Exception as e:  # the agent ran but failed (401/empty/model error)
    print(f"CHATDEV_SMOKE_RUN_FAIL: {type(e).__name__}: {str(e)[:200]}", file=sys.stderr)
    sys.exit(3)

text = ("" if result is None else str(result)).strip()
print(f"  [writer] {text[:120]}")
print(f"CHATDEV_SMOKE_OK output_chars={len(text)}")
sys.exit(0 if text else 3)
PYEOF

out="$(docker exec -i "$BE_NAME" python -c "$PYSIM" 2>&1)" && rc=0 || rc=$?
printf '%s\n' "$out" | sed 's/^/    /'

case "$rc" in
  0) : ;;  # agent produced output — fall through to the sentinel assertion
  4) err "ChatDev SDK import drift (sim exit 4) — the runtime/SDK module path changed; re-verify the import in installer/smoke/35.sh against the cloned version"; exit 1 ;;
  5) err "ChatDev run_workflow API drift (sim exit 5) — the SDK signature changed; fix the workflow call in installer/smoke/35.sh"; exit 1 ;;
  *) err "the ChatDev workflow did not pass (exit $rc) — the agent produced no output through LiteLLM (placeholder/401 key, empty model content, or a workflow error?)"; exit 1 ;;
esac

# Belt-and-suspenders: parse the sentinel and confirm non-zero output.
_line="$(printf '%s' "$out" | grep -oE 'CHATDEV_SMOKE_OK output_chars=[0-9]+' | tail -1)"
_chars="${_line##*output_chars=}"
[[ -n "$_chars" && "$_chars" -gt 0 ]] \
  || { err "sim exited 0 but the sentinel parse is inconsistent (output_chars=${_chars:-?})"; exit 1; }
ok "ChatDev agent produced $_chars chars through LiteLLM on the scoped key (real workflow step) — traced in Phoenix (http://phoenix:6006)"

ok "Smoke 35 PASS — ChatDev headless workflow runs through LiteLLM on the scoped key"
