#!/usr/bin/env bash
# Phase 35 — ChatDev (OpenBMB/ChatDev 2.0 "DevAll", Apache-2.0) — OPT-IN agent-swarm sim.
#
# A multi-agent "software company": a workflow of role agents (CEO/CTO/programmer/
# reviewer/tester) collaborate to turn a brief into software. ChatDev 2.0's default
# branch is a WEB APP — a Vue 3 + Vite frontend (container :5173 → host 5274) talking
# to a FastAPI/uvicorn backend (server_main.py, :6400) — so this is the CONTAINER WEB
# archetype of the agent-swarm-sim set (doc/specs/2026-06-23-agent-sim-platforms-install-plan.md),
# unlike MetaGPT/OASIS/AgentScope (host-venv CLI sims).
#
# ARCHETYPE = CONTAINER WEB APP (mirrors Phase 05 openwebui / Phase 02 qdrant):
#   * ONE derived image (chatdev/Dockerfile: Python 3.12 + uv + Node + frontend deps),
#   * run as TWO managed containers by bin/start-chatdev.sh:
#       - chatdev-backend  uvicorn server_main:app  (:6400)
#       - chatdev          npm run dev (Vite)        (:5173 → host 5274, the `chatdev` alias)
#   * both on the ai-stack bridge, loopback-only publish on 127.0.10.18, caps + labels.
#
# LLM ROUTING: chatdev/repo/.env carries BASE_URL=http://litellm:4000/v1 (container
# Docker DNS, native port) + API_KEY=the scoped CHATDEV_LITELLM_KEY (never master).
# Workflow YAML agent nodes default to ${BASE_URL}/${API_KEY}; model = node `name:`.
#
# VERIFIED (research, 2026-06-23): Python 3.12 hard pin (requires-python>=3.12,<3.13);
# `uv sync` installs clean on arm64 (~6s, prebuilt wheels). A 1-agent workflow routed
# through LiteLLM produced real code output (200, tracked in spend logs). GOTCHAS baked
# into the seeded smoke workflow: (a) do NOT set `protocol: chat` in a node's params
# (upstream TypeError); (b) keep max_tokens>=512 (reasoning model returns empty content
# at small budgets — the demo's 16 is too low).
#
# Constitution honored: OPT-IN (not in install_all_phase_order); scoped key, never
# master; default model local-gemma4; calls traced in Phoenix. Reversible: the start
# script's uninstall + image rmi + rm -rf chatdev/ + unstamp.
#
# Standalone: bash vz-ai-stack.sh install 35   (alias: chatdev)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/network.sh"
source "$AI_STACK/installer/lib/worktree.sh"
aliases_load

PHASE=35
NAME=chatdev
BE_NAME=chatdev-backend
IMAGE="ai-stack/chatdev:local"
CD_DIR="$AI_STACK/chatdev"
CD_REPO="$CD_DIR/repo"
CD_REPO_URL="${CHATDEV_REPO_URL:-https://github.com/OpenBMB/ChatDev.git}"
FE_IP="${ALIAS_IP[chatdev]:-127.0.10.18}"
FE_HOST_PORT="${ALIAS_HOST_PORT[chatdev]:-5274}"
FE_CTR_PORT="${ALIAS_CONTAINER_PORT[chatdev]:-5173}"
BE_PORT="${CHATDEV_BACKEND_PORT:-6400}"
CD_MODEL_DEFAULT="local-gemma4"
# Container DNS name for the LiteLLM mint/probe (install runs after core 00n writes
# /etc/hosts); fall back to host loopback if the alias isn't resolvable yet.
CD_LLM_HOST="http://litellm:4000"
CD_LLM_FALLBACK="http://127.0.0.1:4000"

precheck() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 || return 1
  container_running "$BE_NAME" || return 1
  container_running "$NAME" || return 1
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$FE_IP:$FE_HOST_PORT/" 2>/dev/null | grep -q '^200$' || return 1
  local key; key="$(get_env CHATDEV_LITELLM_KEY '')"
  [[ -n "$key" ]] || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 35 — ChatDev — already installed (image built, both containers healthy on :$FE_HOST_PORT/:$BE_PORT)"
  exit 0
fi

# Editing/cloning into chatdev/ + running the live containers must happen against the
# MAIN checkout (a bind-mount into a worktree vanishes on 'git worktree remove').
worktree_guard "install chatdev"

hdr "Phase 35 — ChatDev (multi-agent software-company web app)"

# --- Preconditions -----------------------------------------------------------
command -v docker >/dev/null 2>&1 || { err "docker not on PATH — install/start the engine first."; exit 1; }
command -v git >/dev/null 2>&1 || { err "git required to clone ChatDev."; exit 1; }
command -v node >/dev/null 2>&1 || { err "node (>=18) required on the host for the frontend deps (host npm install). Install Node, then re-run."; exit 1; }
# Enforce the >=18 the error message promises — npm itself is version-agnostic, so a
# Node 16 host would PASS `command -v` then fail at Vite runtime with cryptic ESM errors.
_node_ver="$(node -e 'process.stdout.write(process.versions.node)' 2>/dev/null || echo 0)"
_node_major="${_node_ver%%.*}"
[[ "$_node_major" =~ ^[0-9]+$ && "$_node_major" -ge 18 ]] \
  || { err "host Node $_node_ver found but ChatDev's Vite frontend needs Node >=18 — upgrade Node and re-run."; exit 1; }
[[ -f "$AI_STACK/.env" ]] || { err ".env missing — run Phase 00 first."; exit 1; }
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY '')"
[[ -n "$LITELLM_MASTER_KEY" ]] || { err "LITELLM_MASTER_KEY missing — Phase 01 must run first."; exit 1; }

network_ensure_ai_stack || { err "ai-stack docker network missing. Run: bash vz-ai-stack.sh install 00n"; exit 1; }

# Resolve a reachable LiteLLM base ONCE (container alias first, host loopback fallback)
# so the mint + smoke calls don't hard-depend on /etc/hosts ordering (§24 council, 2026-06-23).
CD_LLM_BASE=""
if   curl -sf --max-time 4 "$CD_LLM_HOST/health/liveliness" >/dev/null 2>&1; then CD_LLM_BASE="$CD_LLM_HOST"
elif curl -sf --max-time 4 "$CD_LLM_FALLBACK/health/liveliness" >/dev/null 2>&1; then CD_LLM_BASE="$CD_LLM_FALLBACK"
elif curl -sf --max-time 4 -H "Authorization: Bearer $LITELLM_MASTER_KEY" "$CD_LLM_FALLBACK/v1/models" >/dev/null 2>&1; then CD_LLM_BASE="$CD_LLM_FALLBACK"
fi
[[ -n "$CD_LLM_BASE" ]] || { err "LiteLLM not reachable at $CD_LLM_HOST or $CD_LLM_FALLBACK — run 'vz-ai-stack.sh start litellm' (from MAIN)."; exit 1; }
ok "LiteLLM reachable at $CD_LLM_BASE"

# --- 1. Clone ChatDev 2.0 (default branch = the web app) ---------------------
mkdir -p "$CD_DIR"
if [[ -d "$CD_REPO/.git" ]]; then
  ok "ChatDev source already cloned ($CD_REPO)"
else
  log "Cloning ChatDev 2.0 ($CD_REPO_URL → $CD_REPO; default branch)…"
  git clone --depth 1 "$CD_REPO_URL" "$CD_REPO" 2>&1 | tail -3 || { err "git clone failed: $CD_REPO_URL"; exit 1; }
fi
# Sanity: confirm this is the 2.0 web-app shape (frontend/ + server_main.py).
[[ -d "$CD_REPO/frontend" && -f "$CD_REPO/server_main.py" ]] \
  || { err "cloned tree is not ChatDev 2.0 'DevAll' (missing frontend/ or server_main.py) — set CHATDEV_REPO_URL/branch to the 2.0 default and re-run."; exit 1; }

# --- 1b. Vite allowedHosts: the cloned vite.config.js has `host: true` but NO allowedHosts, so
# Vite 6/7 returns 403 "host not allowed" for the ai-stack ALIAS hostname — i.e. the watchable URL
# the docs/notes advertise (http://chatdev:5274/) 403s in a browser even though the IP works. Insert
# the alias host + IP so the advertised URL renders. The frontend is published loopback-only ($FE_IP)
# so accepting the alias Host header has no off-box exposure. Patched BEFORE the build so the frontend
# container starts with it. (Verified live 2026-06-24: http://chatdev:$FE_HOST_PORT/ → 200 after this.)
_CD_VITE="$CD_REPO/frontend/vite.config.js"
if [[ -f "$_CD_VITE" ]]; then
  if grep -q 'allowedHosts' "$_CD_VITE"; then
    ok "chatdev vite.config.js already allows the alias host"
  elif grep -qE '^[[:space:]]*host:[[:space:]]*true,' "$_CD_VITE"; then
    cp -p "$_CD_VITE" "${_CD_VITE}.orig" 2>/dev/null || true   # reversible
    perl -0777 -i -pe "s/(\n[ \t]*host:[ \t]*true,)\n(?!\s*allowedHosts)/\$1\n      allowedHosts: ['chatdev', '${FE_IP}', 'localhost'],\n/" "$_CD_VITE"
    grep -q 'allowedHosts' "$_CD_VITE" \
      && ok "patched chatdev vite.config.js allowedHosts → +chatdev +$FE_IP (so http://chatdev:$FE_HOST_PORT/ renders, not a 403)" \
      || warn "chatdev vite.config.js allowedHosts patch did not verify — http://chatdev:$FE_HOST_PORT/ may 403; watch via http://$FE_IP:$FE_HOST_PORT/ instead"
  else
    note "chatdev vite.config.js has no 'host: true' anchor — config shape changed; verify http://chatdev:$FE_HOST_PORT/ renders (else add the alias to allowedHosts manually)"
  fi
fi

# Defensive shape probes (§24 council 2026-06-23). The exact upstream layout (ASGI app
# object name, .env key names) is BEST-INFERENCE — verified at live-verify, not buildable
# here. These are SOFT WARNINGS only (never a hard exit): a false hard-fail would block a
# valid install on a benign refactor (e.g. `app` imported from a submodule / a factory
# `app = create_app()` / `app: FastAPI = ...`). The smoke (installer/smoke/35.sh, exit 4/5)
# is the real runtime signal for SDK/ASGI drift.
# (a) ASGI target: start-chatdev.sh runs `uvicorn server_main:app`. A top-level `app =`
#     in server_main.py is the common FastAPI shape; warn (don't fail) if absent.
if command -v python3 >/dev/null 2>&1; then
  python3 - "$CD_REPO/server_main.py" <<'PYASGI' 2>/dev/null || warn "server_main.py: no top-level 'app' assignment found — if uvicorn server_main:app fails at start, the ASGI object may be imported/factory-named; check 'docker logs chatdev-backend'."
import ast, sys
src = open(sys.argv[1]).read()
tree = ast.parse(src)
def is_app(t): return isinstance(t, ast.Name) and t.id == "app"
found = any(
    (isinstance(n, ast.Assign)    and any(is_app(t) for t in n.targets)) or
    (isinstance(n, ast.AnnAssign) and is_app(n.target))
    for n in ast.walk(tree)
)
sys.exit(0 if found else 1)
PYASGI
fi
# (b) .env key names: we write BASE_URL/API_KEY/MODEL. If upstream's .env.example uses
#     different names (e.g. OPENAI_BASE_URL/OPENAI_API_KEY), the backend could silently
#     fall through to its own defaults (api.openai.com). Soft cross-reference if present.
if [[ -f "$CD_REPO/.env.example" ]]; then
  for _k in BASE_URL API_KEY; do
    grep -q "^${_k}=" "$CD_REPO/.env.example" 2>/dev/null \
      || warn ".env.example has no '${_k}=' — upstream key names may have changed; verify the .env write in installer/phases/35_chatdev.sh routes the backend to LiteLLM (not a default OpenAI base)."
  done
fi

# --- 2. Mint scoped LiteLLM key (stale-aware; mirrors Phase 32/34) -----------
CD_KEY_CURRENT="$(get_env CHATDEV_LITELLM_KEY '')"
_cd_models=""
[[ -n "$CD_KEY_CURRENT" ]] && _cd_models="$(curl -s --max-time 5 -H "Authorization: Bearer $CD_KEY_CURRENT" "$CD_LLM_BASE/v1/models" 2>/dev/null)"
if [[ -z "$CD_KEY_CURRENT" ]] || ! printf '%s' "$_cd_models" | grep -q '"id"'; then
  log "Minting scoped LiteLLM key for ChatDev (local-gemma4 + *-sub fallbacks)…"
  CD_KEY_NEW="$(curl -s --max-time 15 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H 'Content-Type: application/json' -X POST "$CD_LLM_BASE/key/generate" \
    -d '{"models":["local-gemma4","claude-opus-sub-xhigh","claude-sonnet-sub-high","local-qwen3"],"key_alias":"chatdev","metadata":{"owner":"chatdev","purpose":"phase35"}}' \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$CD_KEY_NEW" ]] || { err "Failed to mint CHATDEV_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"; exit 1; }
  set_env CHATDEV_LITELLM_KEY "$CD_KEY_NEW"
  ok "CHATDEV_LITELLM_KEY minted + saved to .env (mode 0600)"
else
  ok "CHATDEV_LITELLM_KEY already present + valid"
fi
CD_KEY="$(get_env CHATDEV_LITELLM_KEY '')"

# --- 3. Resolve bound model (default local-gemma4) ---------------------------
CD_MODEL="$CD_MODEL_DEFAULT"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _cm="$(yq -r '.assignments.chatdev // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  [[ -n "$_cm" && "$_cm" != "null" ]] && CD_MODEL="$_cm"
fi
ok "ChatDev model = $CD_MODEL (routed via LiteLLM → Phoenix project ai-stack)"

# --- 4. Write chatdev/repo/.env — the LiteLLM wiring the backend reads --------
# Container-to-container: litellm:4000 over Docker DNS (NATIVE port, NOT the :80 alias).
# CORS + VITE_API_BASE_URL pinned to the loopback origins (container web archetype).
# 0600: it carries the scoped key. ChatDev 2.0 copies .env.example → .env; we write
# the resolved values directly so install is non-interactive.
umask 077
# VITE_API_BASE_URL is the browser-facing backend URL Vite bakes into the JS bundle.
# Use the `chatdev` NAME (not the raw lo0 IP): the Mac browser resolves it via the
# ai-stack /etc/hosts managed block → 127.0.10.18, where the backend is published on
# :$BE_PORT — same socket as the IP, but consistent with open_url/health/CORS (all
# http://chatdev:PORT). §24 council 2026-06-23 (live-verified /etc/hosts→lo0 alias).
cat > "$CD_REPO/.env" <<ENVEOF
# ai-stack Phase 35 — ChatDev → LiteLLM wiring (managed; regenerate: install 35).
BASE_URL=http://litellm:4000/v1
API_KEY=$CD_KEY
MODEL=$CD_MODEL
CORS_ALLOW_ORIGINS=http://$FE_IP:$FE_HOST_PORT,http://chatdev:$FE_HOST_PORT,http://localhost:$FE_HOST_PORT
VITE_API_BASE_URL=http://chatdev:$BE_PORT
ENVEOF
chmod 0600 "$CD_REPO/.env" 2>/dev/null || true
ok "wrote $CD_REPO/.env (LiteLLM base + scoped key + CORS/VITE origins, 0600)"

# --- 5. Host-side frontend deps (the runtime bind mount masks any baked node_modules) -
# The Vite container mounts chatdev/repo over /app, so frontend/node_modules must exist
# in the host tree to be visible. Host Node (>=18) installs them once here.
if [[ -d "$CD_REPO/frontend/node_modules" ]]; then
  ok "frontend deps already installed ($CD_REPO/frontend/node_modules)"
else
  log "Installing ChatDev frontend deps on the host (npm install; a few minutes)…"
  ( cd "$CD_REPO/frontend" && npm install --no-audit --no-fund ) 2>&1 | tail -4 \
    || { err "npm install failed in $CD_REPO/frontend — install Node>=18 and retry"; exit 1; }
  ok "frontend deps installed"
fi

# --- 6. Write the Dockerfile (the derived image build context lives at chatdev/) ----
# Idempotent: only (re)write if absent/changed is overkill — the file is templated
# from this phase, so write it each run (cheap; keeps it in sync with the phase).
cat > "$CD_DIR/Dockerfile" <<'DOCKEREOF'
# ai-stack/chatdev:local — one derived image for ChatDev 2.0 "DevAll", run as TWO
# containers (backend uvicorn :6400 + frontend Vite :5173) by bin/start-chatdev.sh.
# Build context = chatdev/ (so repo/ is COPY-able). The source is ALSO bind-mounted
# at runtime so edits + .env are live; the slow uv/npm steps run ONCE at build time.
# VERIFIED 2026-06-23: ChatDev 2.0 hard-pins python>=3.12,<3.13; `uv sync` is clean on
# arm64 (~6s, prebuilt wheels). Frontend deps come from the HOST (Phase 35 npm install).
FROM python:3.12-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates git build-essential pkg-config libcairo2-dev \
    && curl -fsSL https://deb.nodesource.com/setup_20.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && curl -LsSf https://astral.sh/uv/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"
WORKDIR /app
COPY repo/ /app/
# Python deps into the SYSTEM interpreter (/usr/local), NOT /app/.venv — the runtime
# bind mount over /app would mask a project venv; --system survives it.
# We install the LOCKED DEPS via `uv export` (uv.lock → requirements), NOT `uv pip
# install .` — ChatDev's pyproject is an APP, not a buildable package (hatchling errors
# "no directory matches DevAll/devall"), so building the project wheel fails. `uv export
# --no-emit-project` emits the locked deps WITHOUT the project itself → reproducible +
# build-free (the DevAll source runs from the bind-mounted /app at runtime). (§24 live-
# verify fix, 2026-06-23 — was `uv pip install --system .`, which exit-1'd the build.)
RUN if [ -f /app/uv.lock ]; then \
        uv export --no-emit-project --no-hashes --format requirements-txt -o /tmp/cd-reqs.txt && \
        uv pip install --system -r /tmp/cd-reqs.txt ; \
    elif [ -f /app/requirements.txt ]; then \
        uv pip install --system -r /app/requirements.txt ; \
    fi \
    && uv pip install --system uvicorn fastapi
# Frontend deps INSIDE the image (linux-native). The HOST npm install produces
# macOS-arm64 modules (e.g. @rollup/rollup-darwin-arm64) the linux container can't
# load ("Cannot find module '@rollup/rollup-linux-arm64-gnu'"); a clean in-image
# install pulls the linux rollup optional dep. The frontend container mounts an
# ANONYMOUS volume over /app/frontend/node_modules so this linux build survives the
# source bind-mount (which would otherwise re-mask it with the host's). (§24 live-verify fix, 2026-06-23.)
RUN if [ -d /app/frontend ]; then cd /app/frontend && rm -rf node_modules && npm install ; fi
EXPOSE 6400 5173
CMD ["uvicorn", "server_main:app", "--host", "0.0.0.0", "--port", "6400"]
DOCKEREOF
ok "wrote $CD_DIR/Dockerfile"

# --- 7. Keep the repo + sim output as DATA; ignore regenerables --------------
cat > "$CD_DIR/.gitignore" <<'GI'
# ChatDev clone is regenerable (git); node_modules + venvs + run output are noise.
# NOTE: repo/.env carries the LIVE scoped CHATDEV_LITELLM_KEY — `repo/` ignoring it is
# the only thing keeping that key out of git here. Do NOT add a `!repo/.env` exception.
repo/
GI

# --- 8. Build the image + start both containers (bin/start-chatdev.sh) -------
log "Building image + starting ChatDev containers (first build is several minutes)…"
bash "$AI_STACK/bin/start-chatdev.sh" install || { err "start-chatdev.sh install failed"; exit 1; }

# --- 9. Smoke gate: prove the REAL agent path BEFORE stamping ----------------
# (a) the frontend serves 200 (the web app is up); (b) the scoped key reaches the
# model through LiteLLM (the routing the backend uses); (c) a headless 1-agent
# ChatDev workflow runs through LiteLLM (the real swarm path — smoke/35.sh). Polls
# briefly because the Vite dev server + uvicorn take a few seconds to bind.
_fe_up=0
for _ in $(seq 1 20); do
  curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://$FE_IP:$FE_HOST_PORT/" 2>/dev/null | grep -q '^200$' && { _fe_up=1; break; }; sleep 2
done
(( _fe_up )) || { err "smoke: ChatDev frontend not serving 200 on http://$FE_IP:$FE_HOST_PORT — check 'docker logs $NAME'"; exit 1; }
ok "smoke: ChatDev frontend serves 200 on http://$FE_IP:$FE_HOST_PORT"

log "Smoke: scoped key → LiteLLM chat completion…"
_sc="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
  -H "Authorization: Bearer $CD_KEY" -H 'Content-Type: application/json' \
  -X POST "$CD_LLM_BASE/v1/chat/completions" \
  -d "{\"model\":\"$CD_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":512}" 2>/dev/null || echo 000)"
[[ "$_sc" == "200" ]] || { err "scoped key chat completion returned HTTP $_sc (model $CD_MODEL via LiteLLM) — not stamping"; exit 1; }
ok "scoped key reaches $CD_MODEL through LiteLLM (HTTP 200)"

log "Smoke: headless 1-agent ChatDev workflow via the backend container (real swarm step)…"
bash "$AI_STACK/installer/smoke/35.sh" || { err "Phase 35 smoke failed (headless workflow did not run through LiteLLM) — not stamping"; exit 1; }

# Clear the partial=true label now that smoke passed (gc no longer reaps them).
mark_ready "$BE_NAME"; mark_ready "$NAME"

stamp_mark "$PHASE"
record "phase 35 complete: ChatDev image + backend(:$BE_PORT)+frontend(:$FE_HOST_PORT) containers + scoped key + workflow-verified smoke"
ok "Phase 35 — ChatDev — complete"
note "Open the web app:  open http://chatdev:$FE_HOST_PORT     (or http://$FE_IP:$FE_HOST_PORT)"
note "Backend API:       http://$FE_IP:$BE_PORT/docs"
note "Prove the swarm:   vz-ai-stack.sh test 35   # headless 1-agent workflow → LiteLLM"
note "Watch it:          Phoenix → http://phoenix:6006 (project ai-stack)"
note "Bigger swarm:      edit a workflow YAML node's name: to claude-opus-sub-xhigh (metered)"
note "Manage:            vz-ai-stack.sh start chatdev | stop chatdev | help chatdev | doctor chatdev"
note "Reversible:        bash $AI_STACK/bin/start-chatdev.sh uninstall; docker rmi $IMAGE; rm -rf $CD_DIR; rm -f $AI_STACK/installer/state/phase_${PHASE}.done"
