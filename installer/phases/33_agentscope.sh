#!/usr/bin/env bash
# Phase 33 — AgentScope (agentscope-ai/agentscope, Apache-2.0) — OPT-IN multi-agent sim lib.
#
# AgentScope is a developer framework for BUILDING and SCALING your own multi-agent
# applications/simulations (agents that converse, observe each other, and act). Wave 2
# of the agent-swarm-simulation set (doc/specs/2026-06-23-agent-sim-platforms-install-plan.md).
#
# ARCHETYPE = HOST VENV lib (mirrors Phase 06 / Phase 26 / Phase 32 / Phase 34):
#   * uv venv pinned to Python 3.11 (host python3 is 3.14 — too new for the dep tree),
#   * bin/agentscope wrapper injects the scoped LiteLLM key from .env at RUNTIME and
#     points AgentScope's OpenAI-compatible model at LiteLLM,
#   * NO container/port/hostname. Run sims via: bin/agentscope agentscope/sims/<file>.py
#
# The OPTIONAL Studio web GUI (examples/web_ui, host :5275, alias 127.0.0.1 — binds 0.0.0.0,
# see SECURITY note) is opt-in via AGENTSCOPE_STUDIO=1; the lib-only install skips it.
#
# Constitution honored: OPT-IN (not in install_all_phase_order); scoped key
# (AGENTSCOPE_LITELLM_KEY), never master; default model local; calls traced in
# Phoenix. Reversible: rm -rf agentscope/.venv + unstamp; agentscope/sims is DATA.
#
# VERIFIED LIVE (2026-06-23, agentscope 2.0.2) before this phase was written — the API is
# a v2 rewrite, NOT the spec's assumed base_url-on-the-model config:
#   * model: OpenAIChatModel(credential=OpenAICredential(api_key=, base_url=), model=,
#            stream=False, formatter=OpenAIChatFormatter(), parameters=Parameters(max_tokens=))
#   * agents + model calls are ASYNC (asyncio.run; await agent.reply/observe)
#   * Msg.content is a LIST of TextBlocks; read replies with Msg.get_text_content()
#   * local is a REASONING model → its reply carries a ThinkingBlock alongside the
#     TextBlock, and observe() REJECTS thinking blocks across agent boundaries → the sim
#     reconstructs a clean text-only Msg before handing one agent's reply to the next.
#
# Standalone: bash vz-ai-stack.sh install 33   (alias: agentscope)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/worktree.sh"

PHASE=33
AS_DIR="$AI_STACK/agentscope"
AS_VENV="$AS_DIR/.venv"
AS_PY="$AS_VENV/bin/python"
AS_WRAPPER="$AI_STACK/bin/agentscope"
AS_SIMS="$AS_DIR/sims"
AS_MODEL_DEFAULT="claude-opus-sub-xhigh"   # platform default; cheap on-box override: AS_MODEL=local
# Host-venv tools route to 127.0.0.1:4000 (always reachable from the host shell);
# the container DNS name litellm:4000 also works once core Phase 00n writes the
# /etc/hosts alias, so install-time probes try litellm first then fall back.
AS_LLM_HOST="http://litellm:4000"
AS_LLM_FALLBACK="http://127.0.0.1:4000"

# --- OPT-IN Studio GUI (host launchd daemon, NOT docker; gated on AGENTSCOPE_STUDIO=1) ---
# Studio is the npm `@agentscope/studio` app (binary `as_studio`) — a web GUI that
# RECEIVES the OpenTelemetry spans the sims emit and visualizes a swarm run. It is
# NOT part of the pip agentscope package. Pinned for reproducibility.
AS_STUDIO_ENABLED=0
[[ "$(get_env AGENTSCOPE_STUDIO "${AGENTSCOPE_STUDIO:-}")" == "1" ]] && AS_STUDIO_ENABLED=1
AS_STUDIO_NPM_PKG="@agentscope/studio@1.0.9"
AS_STUDIO_PORT=5275          # the UI port the daemon pins (PORT=); matches aliases.tsv
AS_STUDIO_OTLP_GRPC=4318     # the OTLP gRPC receiver the sims export to. 4318 (NOT 4317):
                             # phoenix-otlp already owns :4317 (Phase 01h, aliases.tsv:25)
                             # and as_studio binds 0.0.0.0, so :4317 would collide with /
                             # hijack Phoenix's OTLP intake. 4318 is unclaimed (the
                             # phoenix-otlp-http alias on 4318 is commented-out, not live).
AS_STUDIO_LAUNCHER="$AI_STACK/bin/start-agentscope-studio.sh"
# The gRPC endpoint the sim's OTLP exporter targets when Studio is on (see the wrapper).
AS_OTLP_ENDPOINT="http://127.0.0.1:${AS_STUDIO_OTLP_GRPC}"
# Make the OTLP transport EXPLICIT (grpc) rather than letting the sim infer it from the
# URL shape — removes the ambiguity the §24 council flagged (an http:// URL with a
# /v1/traces path would otherwise pick the HTTP exporter against this gRPC receiver).
AS_OTLP_PROTOCOL="grpc"

precheck() {
  [[ -x "$AS_PY" ]] || return 1
  [[ -x "$AS_WRAPPER" ]] || return 1
  "$AS_PY" -c "import agentscope" >/dev/null 2>&1 || return 1
  local key; key="$(get_env AGENTSCOPE_LITELLM_KEY '')"
  [[ -n "$key" ]] || return 1
  litellm_scoped_curl "$key" -sf --max-time 5 "$AS_LLM_HOST/v1/models" >/dev/null 2>&1 \
    || litellm_scoped_curl "$key" -sf --max-time 5 "$AS_LLM_FALLBACK/v1/models" >/dev/null 2>&1 \
    || return 1
  # When Studio is enabled, a passing precheck ALSO requires the launchd plist to
  # exist AND the UI to answer 200 on :5275 — otherwise re-run so the daemon is
  # (re)installed. Lib-only (flag unset) skips this entirely and is UNCHANGED.
  if [[ "$AS_STUDIO_ENABLED" == "1" ]]; then
    [[ -f "$HOME/Library/LaunchAgents/com.ai-stack.agentscope-studio.plist" ]] || return 1
    curl -s -m 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:${AS_STUDIO_PORT}/" 2>/dev/null \
      | grep -q '^200$' || return 1
  fi
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 33 — AgentScope — already installed (precheck passed + stamped; nothing to do)"
  exit 0
fi

worktree_guard "install agentscope"

hdr "Phase 33 — AgentScope (multi-agent simulation framework)"

# --- Preconditions ---
command -v uv >/dev/null 2>&1 || { err "uv not on PATH (Phase 14 installs it): bash $AI_STACK/vz-ai-stack.sh install 14"; exit 1; }
[[ -f "$AI_STACK/.env" ]] || { err ".env missing — run Phase 00 first."; exit 1; }
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY '')"
[[ -n "$LITELLM_MASTER_KEY" ]] || { err "LITELLM_MASTER_KEY missing — Phase 01 must run first."; exit 1; }
# Reachability: resolve the LiteLLM base URL ONCE — prefer the container alias
# (litellm:4000, present after core Phase 00n writes /etc/hosts) but fall back to
# 127.0.0.1:4000 (always reachable from the host shell, even before 00n). Reusing the
# RESOLVED base for the mint + smoke calls below removes the /etc/hosts ordering
# dependency the §24 council flagged (2026-06-23) — without it, install 33 before 00n
# would abort on a litellm: NXDOMAIN even though 127.0.0.1:4000 is alive.
AS_LLM_BASE=""
if   curl -sf --max-time 4 "$AS_LLM_HOST/health/liveliness" >/dev/null 2>&1; then AS_LLM_BASE="$AS_LLM_HOST"
elif curl -sf --max-time 4 "$AS_LLM_FALLBACK/health/liveliness" >/dev/null 2>&1; then AS_LLM_BASE="$AS_LLM_FALLBACK"
elif litellm_master_curl -sf --max-time 4 "$AS_LLM_FALLBACK/v1/models" >/dev/null 2>&1; then AS_LLM_BASE="$AS_LLM_FALLBACK"
fi
[[ -n "$AS_LLM_BASE" ]] || { err "LiteLLM not reachable at $AS_LLM_HOST or $AS_LLM_FALLBACK — run 'vz-ai-stack.sh start litellm' (from MAIN)."; exit 1; }
ok "LiteLLM reachable at $AS_LLM_BASE"

# --- 1. Venv (Python 3.11) + install agentscope ---
mkdir -p "$AS_SIMS"
if [[ ! -x "$AS_PY" ]]; then
  log "Creating agentscope venv (uv, Python 3.11)…"
  uv venv --python 3.11 "$AS_VENV" 2>&1 | tail -3 || { err "uv venv failed (uv fetches CPython 3.11 on first use — check network)"; exit 1; }
fi
log "Installing agentscope into the venv (a few minutes; large dep tree)…"
uv pip install --python "$AS_PY" --upgrade agentscope 2>&1 | tail -6 || { err "uv pip install agentscope failed"; exit 1; }
"$AS_PY" -c "import agentscope" 2>/dev/null || { err "import agentscope failed (dependency/arch problem) — see install log above"; exit 1; }
# arm64 sanity — a silent amd64/Rosetta venv is slow + may break; the spec (§1.8)
# requires asserting native arm64 BEFORE stamping, so this is a hard fail (not a warn).
_arch="$("$AS_PY" -c 'import platform;print(platform.machine())' 2>/dev/null || echo '?')"
_asver="$("$AS_PY" -c 'import agentscope;print(agentscope.__version__)' 2>/dev/null || echo '?')"
if [[ "$_arch" == "arm64" ]]; then
  ok "agentscope $_asver installed (venv python $_arch)"
elif [[ "$_arch" == "?" ]]; then
  warn "could not detect the agentscope venv python arch — continuing (verify it is native arm64)"
else
  err "agentscope venv python is '$_arch', not arm64 — refusing to stamp an emulated install (spec §1.8). Rebuild: rm -rf '$AS_VENV' && uv python install 3.11"; exit 1
fi

# --- 2. Mint scoped LiteLLM key (stale-aware; mirrors Phase 26/32/34) ---
AS_KEY_CURRENT="$(get_env AGENTSCOPE_LITELLM_KEY '')"
# Only probe with the existing key when there IS one (an empty 'Bearer ' just logs a
# spurious 401 in LiteLLM's audit trail).
_as_models=""
[[ -n "$AS_KEY_CURRENT" ]] && _as_models="$(litellm_scoped_curl "$AS_KEY_CURRENT" -s --max-time 5 "$AS_LLM_BASE/v1/models" 2>/dev/null)"
if [[ -z "$AS_KEY_CURRENT" ]] || ! printf '%s' "$_as_models" | grep -q '"id"'; then
  log "Minting scoped LiteLLM key for AgentScope (local + *-sub fallbacks)…"
  # Parse the key with the venv python ($AS_PY, built + import-verified above) rather
  # than assuming a host python3 (§24 council nit, 2026-06-23).
  AS_KEY_NEW="$(litellm_master_curl -s --max-time 15 \
    -H 'Content-Type: application/json' -X POST "$AS_LLM_BASE/key/generate" \
    -d '{"models":["local","claude-opus-sub-xhigh","claude-sonnet-sub-high"],"key_alias":"agentscope","metadata":{"owner":"agentscope","purpose":"phase33"}}' \
    | "$AS_PY" -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$AS_KEY_NEW" ]] || { err "Failed to mint AGENTSCOPE_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"; exit 1; }
  set_env AGENTSCOPE_LITELLM_KEY "$AS_KEY_NEW"
  ok "AGENTSCOPE_LITELLM_KEY minted + saved to .env (mode 0600)"
else
  ok "AGENTSCOPE_LITELLM_KEY already present + valid"
fi

# --- 3. Resolve bound model (default local) ---
AS_MODEL="$AS_MODEL_DEFAULT"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _am="$(yq -r '.assignments.agentscope // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  [[ -n "$_am" && "$_am" != "null" ]] && AS_MODEL="$_am"
fi
ok "AgentScope model = $AS_MODEL (routed via LiteLLM → Phoenix project ai-stack)"
# Self-heal the key's allow-list against the model the app ACTUALLY calls ($AS_MODEL,
# which an operator may have re-assigned) PLUS the mint fallbacks. The mint only re-mints
# when the key is fully dead, so a rename/re-assign leaves a stale key SILENT-403ing the
# bound model (`model sync` never touches this key). See litellm_reconcile_key (common.sh).
litellm_reconcile_key AGENTSCOPE_LITELLM_KEY "$AS_MODEL" local claude-opus-sub-xhigh claude-sonnet-sub-high

# --- 4. bin/agentscope wrapper (injects key from .env at RUNTIME) ---
# The wrapper points at 127.0.0.1:4000 — the host-shell route that always resolves
# (the container DNS name litellm:4000 only resolves after Phase 00n writes /etc/hosts).
# When Studio is enabled, bake an OTEL endpoint + explicit transport export into the
# wrapper so every sim the wrapper runs emits its trace spans to the Studio OTLP gRPC
# receiver (:4318). When Studio is OFF this is the EMPTY string → the seeded sim's OTLP
# setup is itself a no-op when this env is absent (so lib-only behavior is unchanged).
AS_OTEL_EXPORT_LINE=""
if [[ "$AS_STUDIO_ENABLED" == "1" ]]; then
  AS_OTEL_EXPORT_LINE="export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=\"$AS_OTLP_ENDPOINT\"
export OTEL_EXPORTER_OTLP_PROTOCOL=\"$AS_OTLP_PROTOCOL\""
fi
cat > "$AS_WRAPPER" <<WRAPEOF
#!/usr/bin/env bash
# bin/agentscope — stack wrapper around the agentscope venv (Phase 33). Regenerate: install 33.
# Runs a sim script in the venv with the scoped LiteLLM key + OpenAI-compat env.
# Default model ($AS_MODEL) is baked at install time; override at runtime with AGENTSCOPE_MODEL.
# Usage: bin/agentscope agentscope/sims/smoke_sim.py
set -Eeuo pipefail
AI_STACK="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")/.." && pwd)"
# last-wins on duplicate .env keys (matches installer/lib/env.sh get_env semantics)
_as_get_env() { grep -E "^\$1=" "\$AI_STACK/.env" 2>/dev/null | tail -1 | cut -d= -f2-; }
PY="\$AI_STACK/agentscope/.venv/bin/python"
[[ -x "\$PY" ]] || { echo "agentscope venv missing — run 'bash vz-ai-stack.sh install 33'" >&2; exit 1; }
_key="\$(_as_get_env AGENTSCOPE_LITELLM_KEY)"
[[ -n "\$_key" ]] || { echo "AGENTSCOPE_LITELLM_KEY absent from .env — run 'bash vz-ai-stack.sh install 33'" >&2; exit 1; }
export AGENTSCOPE_LITELLM_KEY="\$_key"
export OPENAI_API_KEY="\$_key"
export OPENAI_BASE_URL="http://127.0.0.1:4000/v1"
export AGENTSCOPE_MODEL="\${AGENTSCOPE_MODEL:-$AS_MODEL}"
$AS_OTEL_EXPORT_LINE
cd "\$AI_STACK"
exec "\$PY" "\$@"
WRAPEOF
chmod +x "$AS_WRAPPER"
ok "wrote $AS_WRAPPER"

# --- 5. Seed a tiny AgentScope→LiteLLM multi-agent sim (the routing proof; smoke runs it) ---
# Verified against agentscope 2.0.2 (2026-06-23). The model/agent API is async; the
# OpenAI-compatible base_url lives on OpenAICredential; local reasons before it
# answers (max_tokens=512) and emits a ThinkingBlock that observe() rejects across
# agents → reconstruct a clean text-only Msg between turns.
cat > "$AS_SIMS/smoke_sim.py" <<'PY'
"""AgentScope smoke: prove agentscope is installed AND a real 2-agent exchange routes
through LiteLLM. Reads OPENAI_BASE_URL / OPENAI_API_KEY / AGENTSCOPE_MODEL from env
(injected by bin/agentscope). Prints 'AGENTSCOPE_SMOKE_OK agents=2 replies=N' and
exits 0 only when BOTH agents replied with visible text.

Verified against agentscope 2.0.2 (2026-06-23). Distinct exit codes let the caller tell
an API drift (4/5) from an auth/routing failure (3): 0=both replied, 3=an agent did not
reply (placeholder/401 key, or empty model output), 4=import drift, 5=AgentScope model/
agent API drift. local reasons before it answers, hence max_tokens=512; its reply
carries a ThinkingBlock that observe() rejects, so we hand the next agent a clean
text-only Msg built from get_text_content()."""
import asyncio, os, signal, sys

# Hard wall-clock guard so a hung/queued model can't block `test 33` forever
# (macOS has no `timeout`; signal.alarm is portable + dependency-free).
signal.alarm(180)

try:
    import agentscope  # noqa: F401  — prove the package under test imports
    from agentscope.agent import Agent
    from agentscope.model import OpenAIChatModel
    from agentscope.formatter import OpenAIChatFormatter
    from agentscope.credential import OpenAICredential
    from agentscope.message import Msg, TextBlock
except Exception as e:  # import/API drift — NOT an auth problem
    print(f"AGENTSCOPE_SMOKE_IMPORT_FAIL: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(4)

# --- OPT-IN: stream traces to AgentScope Studio when bin/agentscope set the endpoint.
# When OTEL_EXPORTER_OTLP_TRACES_ENDPOINT is UNSET (lib-only / no Studio), this is a
# pure no-op and the sim behaves exactly as the shipped version. All imports are
# guarded so a missing/changed OTel API can NEVER break the core 2-agent smoke.
_OTLP_ENDPOINT = os.environ.get("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "").strip()
# Explicit transport (OTel-spec env): "grpc" | "http/protobuf" | "http". bin/agentscope
# bakes "grpc" when Studio is on. We prefer this over inferring the transport from the
# URL shape (the §24 council flagged that heuristic as ambiguous — an http:// URL that
# carries a /v1/traces path would mis-route to the HTTP exporter against a gRPC receiver).
_OTLP_PROTOCOL = os.environ.get("OTEL_EXPORTER_OTLP_PROTOCOL", "").strip().lower()


def _setup_tracing():
    """Wire an OTLP exporter + global SDK TracerProvider so TracingMiddleware emits
    spans to Studio. Returns a TracingMiddleware instance to attach to agents, or
    None when Studio isn't configured / the OTel stack isn't importable."""
    if not _OTLP_ENDPOINT:
        return None  # no Studio → lib-only behavior, no tracing overhead
    try:
        from opentelemetry import trace as _otel_trace
        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor
        from agentscope.middleware import TracingMiddleware
        # Transport selection: prefer the EXPLICIT OTEL_EXPORTER_OTLP_PROTOCOL env
        # (OTel-spec). Only when it is unset do we fall back to the URL-shape heuristic
        # (an HTTP /v1/traces path → HTTP exporter; anything else → gRPC), and we WARN
        # when that fallback fires so an ambiguous endpoint can't silently mis-route.
        if _OTLP_PROTOCOL in ("http", "http/protobuf"):
            _use_grpc = False
        elif _OTLP_PROTOCOL == "grpc":
            _use_grpc = True
        else:
            _path_is_http = _OTLP_ENDPOINT.rstrip("/").endswith("/v1/traces")
            _use_grpc = not _path_is_http
            print(
                "  [studio] OTEL_EXPORTER_OTLP_PROTOCOL unset — inferring "
                f"{'gRPC' if _use_grpc else 'HTTP'} from endpoint shape "
                f"({_OTLP_ENDPOINT}); set OTEL_EXPORTER_OTLP_PROTOCOL=grpc|http/protobuf "
                "to make this explicit"
            )
        if not _use_grpc:
            from opentelemetry.exporter.otlp.proto.http.trace_exporter import (
                OTLPSpanExporter,
            )
            exporter = OTLPSpanExporter(endpoint=_OTLP_ENDPOINT)
        else:
            from opentelemetry.exporter.otlp.proto.grpc.trace_exporter import (
                OTLPSpanExporter,
            )
            # insecure=True: Studio's gRPC receiver is plaintext on loopback.
            exporter = OTLPSpanExporter(endpoint=_OTLP_ENDPOINT, insecure=True)
        provider = TracerProvider(
            resource=Resource.create({"service.name": "agentscope-sim"}),
        )
        provider.add_span_processor(BatchSpanProcessor(exporter))
        _otel_trace.set_tracer_provider(provider)
        print(f"  [studio] tracing -> {_OTLP_ENDPOINT}")
        return TracingMiddleware()
    except Exception as e:  # missing OTel / API drift — Studio is optional, NEVER fatal
        print(f"  [studio] tracing disabled ({type(e).__name__}: {e})")
        return None


_TRACE_MW = _setup_tracing()

BASE  = os.environ.get("OPENAI_BASE_URL", "http://127.0.0.1:4000/v1")
KEY   = os.environ.get("OPENAI_API_KEY", "")
MODEL = os.environ.get("AGENTSCOPE_MODEL", "claude-opus-sub-xhigh")


def _make_model():
    # base_url is a Credential field (NOT a model kwarg) in agentscope 2.x; the model
    # needs a Formatter; max_tokens lives in Parameters. stream=False = one ChatResponse.
    return OpenAIChatModel(
        credential=OpenAICredential(api_key=KEY, base_url=BASE),
        model=MODEL, stream=False, formatter=OpenAIChatFormatter(),
        parameters=OpenAIChatModel.Parameters(max_tokens=512, temperature=0.7),
    )


def _clean_text_msg(name, text):
    # Reasoning models reply with a ThinkingBlock + TextBlock; observe() rejects thinking
    # blocks across agent boundaries, so rebuild a text-only Msg before the handoff.
    return Msg(name=name, role="assistant", content=[TextBlock(type="text", text=text)])


try:
    _mw = [_TRACE_MW] if _TRACE_MW is not None else []
    alice = Agent(name="Alice", system_prompt="You are Alice, an optimist. Reply in ONE short sentence.", model=_make_model(), middlewares=_mw)
    bob   = Agent(name="Bob",   system_prompt="You are Bob, a skeptic. Reply in ONE short sentence.",   model=_make_model(), middlewares=_mw)
except Exception as e:  # construction rejected = AgentScope API drift, not a key problem
    print(f"AGENTSCOPE_SMOKE_MODEL_FAIL: {type(e).__name__}: {e}", file=sys.stderr)
    sys.exit(5)


async def _run():
    replies = 0
    seed = Msg(name="user", role="user",
               content=[TextBlock(type="text", text="What do you think about swarms of AI agents living in a simulated world?")])
    try:
        a_txt = ((await alice.reply(seed)).get_text_content() or "").strip()
        print(f"  [Alice] {a_txt[:90]}")
        if a_txt:
            replies += 1
        await bob.observe(_clean_text_msg("Alice", a_txt or "(no reply)"))
        b_txt = ((await bob.reply(Msg(name="user", role="user",
                  content=[TextBlock(type="text", text="Do you agree with Alice?")]))).get_text_content() or "").strip()
        print(f"  [Bob] {b_txt[:90]}")
        if b_txt:
            replies += 1
    except Exception as e:  # a per-call failure (401, network, model)
        print(f"  AGENT_FAIL: {type(e).__name__}: {str(e)[:140]}")
    if _TRACE_MW is not None:
        try:
            from opentelemetry import trace as _otel_trace
            _otel_trace.get_tracer_provider().force_flush()  # ship batched spans to Studio now
        except Exception:
            pass  # best-effort; never let a flush error change the sim's exit code
    return replies


replies = asyncio.run(_run())
print(f"AGENTSCOPE_SMOKE_OK agents=2 replies={replies}")
sys.exit(0 if replies == 2 else 3)
PY
ok "seeded $AS_SIMS/smoke_sim.py"

# --- 6. Keep sims as DATA; .venv is regenerable (the agentscope/ tree itself is
# git-ignored at the repo root so install output is not untracked noise in main). ---
[[ -f "$AS_SIMS/.gitkeep" ]] || : > "$AS_SIMS/.gitkeep"
cat > "$AS_DIR/.gitignore" <<'GI'
# AgentScope venv is regenerable (uv); agentscope/sims is DATA (your sim scripts + output) — keep it.
.venv/
GI

# --- 6b. OPT-IN: AgentScope Studio GUI (npm @agentscope/studio + launchd daemon) ---
# Gated on AGENTSCOPE_STUDIO=1. Studio is a standalone Node app (NOT pip agentscope):
# a web GUI on host :5275 that RECEIVES the OTLP trace spans the sims emit and
# visualizes the swarm. Fail-SOFT: Studio is optional, so a failed global npm install
# (it has native modules — better-sqlite3 / grpc) WARNS and continues; the core lib
# stays installed + stamped. Mirrors the aionui daemon (Phase 28 / bin/start-aionui.sh).
if [[ "$AS_STUDIO_ENABLED" == "1" ]]; then
  hdr "Phase 33 — AgentScope Studio GUI (opt-in: AGENTSCOPE_STUDIO=1)"
  # SECURITY — print UNCONDITIONALLY when Studio is opted in, regardless of whether the
  # daemon ends up healthy. as_studio binds 0.0.0.0 (its host:'localhost' config is inert
  # and there is NO flag to force a loopback bind) → the UI (:5275) and the OTLP gRPC
  # receiver (:${AS_STUDIO_OTLP_GRPC}) are reachable on EVERY interface with no auth. The
  # loopback posture relies ENTIRELY on not exposing this box.
  warn "Studio binds 0.0.0.0 (no loopback-only flag exists) — UI :${AS_STUDIO_PORT} + OTLP gRPC :${AS_STUDIO_OTLP_GRPC} are unauthenticated on ALL interfaces. Keep this box off untrusted networks / behind a firewall."
  # Pre-install port guard: as_studio SILENTLY auto-bumps a busy UI port, which would make
  # the hardcoded :5275 health/doctor probe point at the wrong port. Abort with a clear
  # message if something already owns :5275 (lsof exits 1 when the port is free → guard set -e).
  if lsof -nP -iTCP:"$AS_STUDIO_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    err "port :${AS_STUDIO_PORT} is already in use (Studio would silently auto-bump to another port, breaking the :${AS_STUDIO_PORT} health/doctor probe). Free it: lsof -nP -iTCP:${AS_STUDIO_PORT} -sTCP:LISTEN ; then re-run 'AGENTSCOPE_STUDIO=1 vz-ai-stack.sh install 33'"
    exit 1
  fi
  command -v node >/dev/null 2>&1 || warn "node not on PATH — Studio needs Node>=20 (host has 22); skipping Studio"
  command -v npm  >/dev/null 2>&1 || warn "npm not on PATH — Studio needs npm>=10; skipping Studio"
  if command -v node >/dev/null 2>&1 && command -v npm >/dev/null 2>&1; then
    # Idempotent: skip the (slow, native-module) global install if as_studio is already
    # resolvable. `npm prefix -g`/bin is the canonical global bin (brew node → /opt/homebrew/bin).
    _npm_bin="$(npm prefix -g 2>/dev/null)/bin"
    if [[ -x "$_npm_bin/as_studio" ]] || command -v as_studio >/dev/null 2>&1; then
      ok "as_studio already installed (skipping npm install -g $AS_STUDIO_NPM_PKG)"
    else
      log "Installing AgentScope Studio (npm install -g $AS_STUDIO_NPM_PKG; native modules — a minute or two)…"
      if npm install -g "$AS_STUDIO_NPM_PKG" 2>&1 | tail -6; then
        ok "installed $AS_STUDIO_NPM_PKG"
      else
        warn "npm install -g $AS_STUDIO_NPM_PKG FAILED (native better-sqlite3/grpc build?) — Studio is OPTIONAL; the core lib is fine. Retry: npm install -g $AS_STUDIO_NPM_PKG, then: bash $AS_STUDIO_LAUNCHER install"
      fi
    fi
    # Install/refresh the launchd daemon ONLY if the binary actually resolved.
    if [[ -x "$_npm_bin/as_studio" ]] || command -v as_studio >/dev/null 2>&1; then
      if PORT="$AS_STUDIO_PORT" OTEL_GRPC_PORT="$AS_STUDIO_OTLP_GRPC" bash "$AS_STUDIO_LAUNCHER" install; then
        ok "AgentScope Studio daemon up — open http://127.0.0.1:${AS_STUDIO_PORT}"
        # (security 0.0.0.0 caveat already printed UNCONDITIONALLY as a warn above)
      else
        warn "start-agentscope-studio.sh install did not report healthy — check installer/state/agentscope-studio.launchd.log"
      fi
    fi
  fi
fi

# --- 7. Smoke gate: prove the REAL AgentScope path BEFORE stamping, so a broken wiring
# fails the INSTALL (not just a later `test 33`). A fast key-reachability curl first gives
# a clear error if the KEY is the problem; then the seeded 2-agent exchange (bounded by
# its own signal.alarm). ---
log "Smoke: scoped key → LiteLLM chat completion…"
_as_key="$(get_env AGENTSCOPE_LITELLM_KEY '')"
_sc="$(litellm_scoped_curl "$_as_key" -s -o /dev/null -w '%{http_code}' --max-time 30 \
  -H 'Content-Type: application/json' \
  -X POST "$AS_LLM_BASE/v1/chat/completions" \
  -d "{\"model\":\"$AS_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":4}" 2>/dev/null || echo 000)"
[[ "$_sc" == "200" ]] || { err "scoped key chat completion returned HTTP $_sc (model $AS_MODEL via LiteLLM) — not stamping"; exit 1; }
ok "scoped key reaches $AS_MODEL through LiteLLM (HTTP 200)"

log "Smoke: real AgentScope 2-agent exchange via the seeded sim (verifies the wiring before stamping; ~30-60s on a cold model)…"
_simout="$(OPENAI_BASE_URL="$AS_LLM_FALLBACK/v1" OPENAI_API_KEY="$_as_key" AGENTSCOPE_MODEL="$AS_MODEL" "$AS_PY" "$AS_SIMS/smoke_sim.py" 2>&1)" && _simrc=0 || _simrc=$?
printf '%s\n' "$_simout" | sed 's/^/    /'
[[ $_simrc -eq 0 ]] || { err "the seeded AgentScope sim did not pass (rc=$_simrc) — wiring unverified, not stamping"; exit 1; }
ok "AgentScope 2 agents replied through LiteLLM on the scoped key — wiring verified"

stamp_mark "$PHASE"
record "phase 33 complete: AgentScope venv (py3.11) + scoped key + bin/agentscope + 2-agent-verified smoke sim"
ok "Phase 33 — AgentScope — complete"
note "Prove the swarm:  vz-ai-stack.sh test 33     # 2 AgentScope agents converse via LiteLLM"
note "Run the demo:     bin/agentscope agentscope/sims/smoke_sim.py"
note "Watch it:         Phoenix → http://phoenix:6006 (project ai-stack)"
note "Write your own:   agentscope/sims/<your_sim>.py  then  bin/agentscope agentscope/sims/<your_sim>.py"
note "Reversible:       rm -rf $AS_VENV && rm -f $AI_STACK/installer/state/phase_33.done"
if [[ "$AS_STUDIO_ENABLED" == "1" ]]; then
  note "Studio GUI:    http://127.0.0.1:${AS_STUDIO_PORT}   (watch the swarm — opt-in via AGENTSCOPE_STUDIO=1)"
  note "Studio status: bash $AS_STUDIO_LAUNCHER status"
  note "Studio off:    bash $AS_STUDIO_LAUNCHER uninstall   # removes the launchd daemon (npm pkg stays)"
fi
