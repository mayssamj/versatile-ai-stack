#!/usr/bin/env bash
# Phase 36 — AI Town (a16z-infra/ai-town, MIT) — OPT-IN watchable virtual-town agent sim.
#
# AI Town is a deployable, persistent virtual world where a cast of AI characters
# live, move, and chat in real time — the most *watchable* of the agent-sim set
# (doc/specs/2026-06-23-agent-sim-platforms-install-plan.md). You open it in a
# browser and watch the town tick.
#
# ARCHETYPE = DOCKER COMPOSE STACK (UNLIKE the host-venv OASIS Ph34 / MetaGPT Ph32).
# Three containers under a stable compose project `aitown`:
#   * frontend  — Vite dev server (:5173), built from the cloned repo's Dockerfile
#                 (HEAVY first build: Ubuntu 22.04 + Node 18 + a full npm build).
#   * backend   — ghcr.io/get-convex/convex-backend  (:3210 API / :3211 site-proxy);
#                 STATEFUL — the whole town world is a SQLite DB. We BIND-MOUNT it to
#                 data/aitown/convex (NOT a named volume) so an accidental `down -v`
#                 cannot wipe it.
#   * dashboard — ghcr.io/get-convex/convex-dashboard (:6791); optional admin UI.
#
# LLM WIRING is NOT compose env / NOT a .env file — it lives in CONVEX env vars set
# against the RUNNING backend (`npx convex env set`). With LLM_API_URL set, AI Town's
# provider=custom routes BOTH chat (/v1/chat/completions) and embeddings (/v1/embeddings)
# through LiteLLM at http://host.docker.internal:4000 (the Convex container dials the
# host; it does NOT join the ai-stack bridge — hence the documented bridge-exempt labels
# in the override).
#
# MANDATORY pre-push patch: convex/util/llm.ts has `EMBEDDING_DIMENSION = 1024` — a
# COMPILE-TIME constant baked into the Convex vector index at schema-push. embed-local
# (Ollama nomic-embed-text) emits 768 dims, so this phase patches it to 768 BEFORE the
# first `convex dev`/predev push, else every vector write fails. (Default 1024 matches
# mxbai-embed-large, which is NOT pulled on this box.)
#
# Constitution honored:
#   * OPT-IN: not in install_all_phase_order() — install by name/id.
#   * Scoped LiteLLM key (AITOWN_LITELLM_KEY), never the master; default model
#     local-gemma4 (+ *-sub fallbacks). Calls show in Phoenix (ai-stack) for free.
#   * Reversible + data-safe: teardown default is `down` (PRESERVES the SQLite world);
#     only `--nuke` does `down -v` + removes the data dir (backup-first checkpoint).
#   * Caps on EVERY container (deploy.resources.limits in the override + a post-up
#     `docker update` enforce/verify pass in bin/start-aitown.sh).
#
# THROUGHPUT REALITY (M4/24GB): local inference is the limiter. We pin
# NUM_MEMORIES_TO_SEARCH=1 (convex/constants.ts, default 3) and the town runs a small
# cast on local-gemma4. Route to a cloud model (metered) for a bigger/livelier town.
#
# Standalone: bash vz-ai-stack.sh install 36   (alias: aitown)
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/network.sh"
source "$AI_STACK/installer/lib/worktree.sh"
aliases_load

PHASE=36
AT_DIR="$AI_STACK/ai-town"
AT_DATA="$AI_STACK/data/aitown"
AT_REPO="https://github.com/a16z-infra/ai-town"
AT_PROJECT="aitown"                  # stable compose project (check 53 census signal)
AT_FE_HOST_PORT="5273"               # host  (alias 'aitown' → 5273 → container 5173)
AT_FE_CTR_PORT="5173"
AT_BE_PORT="3210"
AT_DASH_PORT="6791"
AT_IP="${ALIAS_IP[aitown]:-127.0.10.19}"
AT_MODEL_DEFAULT="local-gemma4"
AT_EMBED_MODEL="embed-local"
# Host-shell route always resolves (127.0.0.1); the container alias litellm:4000 only
# resolves after core Phase 00n writes /etc/hosts, so probe litellm first then fall back.
AT_LLM_HOST="http://litellm:4000"
AT_LLM_FALLBACK="http://127.0.0.1:4000"
# The URL the CONVEX CONTAINER uses to dial LiteLLM on the host (NO trailing slash, NO
# /v1). The feasibility pre-check VERIFIED against upstream convex/util/llm.ts that the
# code appends the suffix itself — LLM_API_URL is the bare base and the client builds
# `${LLM_API_URL}/v1/chat/completions` and `${LLM_API_URL}/v1/embeddings`. Do NOT add /v1
# here (that would double it → 404). If upstream changes the URL construction, re-verify
# this constant against convex/util/llm.ts before relying on the wiring.
AT_CONVEX_LLM_URL="http://host.docker.internal:4000"

# --- precheck: stack up + frontend 200 + scoped key valid → already done -------
precheck() {
  [[ -f "$AT_DIR/docker-compose.yml" ]] || return 1
  command -v docker >/dev/null 2>&1 || return 1
  # All 3 compose members up?  (docker compose ps --status running -q → 3 ids)
  local _running
  _running="$( (cd "$AT_DIR" && docker compose -p "$AT_PROJECT" ps --status running -q 2>/dev/null | grep -c . ) || true)"
  [[ "${_running:-0}" -ge 3 ]] || return 1
  # Frontend serves 200 (explicit ^200$ — never the http_ok helper; documented 000-bug).
  curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$AT_IP:$AT_FE_HOST_PORT/" 2>/dev/null | grep -q '^200$' || return 1
  local key; key="$(get_env AITOWN_LITELLM_KEY '')"
  [[ -n "$key" ]] || return 1
  curl -sf --max-time 5 -H "Authorization: Bearer $key" "$AT_LLM_HOST/v1/models" >/dev/null 2>&1 \
    || curl -sf --max-time 5 -H "Authorization: Bearer $key" "$AT_LLM_FALLBACK/v1/models" >/dev/null 2>&1 \
    || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 36 — AI Town — already installed (precheck passed + stamped; nothing to do)"
  exit 0
fi

# Refuse to install from a linked worktree: the clone + bind-mounted data + compose
# containers bind paths under $AI_STACK that vanish on 'git worktree remove' (run the
# live stack from MAIN only — see [[feedback_worktree_breaks_live_stack]]).
worktree_guard "install aitown"

hdr "Phase 36 — AI Town (watchable virtual-town agent sim; Convex compose stack)"

# --- Preconditions -----------------------------------------------------------
command -v docker >/dev/null 2>&1 || { err "docker not on PATH — install OrbStack/Docker (see doc/PREREQUISITES.md)"; exit 1; }
docker info >/dev/null 2>&1        || { err "docker daemon not reachable — start your engine (OrbStack), then re-run"; exit 1; }
command -v git >/dev/null 2>&1     || { err "git not on PATH (deps.sh tier-1): bash $AI_STACK/vz-ai-stack.sh deps"; exit 1; }
# convex CLI runs on the HOST via npx (node@22 is a deps.sh tier-1 core formula; npm/npx
# are relinked onto PATH). The schema push + `convex env set` happen host-side.
command -v npx >/dev/null 2>&1     || { err "npx not on PATH — node@22 is a core dep: bash $AI_STACK/vz-ai-stack.sh deps"; exit 1; }
[[ -f "$AI_STACK/.env" ]] || { err ".env missing — run Phase 00 first."; exit 1; }
LITELLM_MASTER_KEY="$(get_env LITELLM_MASTER_KEY '')"
[[ -n "$LITELLM_MASTER_KEY" ]] || { err "LITELLM_MASTER_KEY missing — Phase 01 must run first."; exit 1; }
network_ensure_ai_stack || { err "ai-stack docker network missing. Run: bash $AI_STACK/vz-ai-stack.sh install 00n"; exit 1; }

# Reachability: resolve the LiteLLM base URL ONCE — prefer the container alias
# (litellm:4000, present after Phase 00n) but fall back to 127.0.0.1:4000 (always
# reachable from the host shell). Reusing the resolved base for the mint + smoke removes
# the /etc/hosts ordering dependency (same §24 fix as Ph32/34).
AT_LLM_BASE=""
if   curl -sf --max-time 4 "$AT_LLM_HOST/health/liveliness" >/dev/null 2>&1; then AT_LLM_BASE="$AT_LLM_HOST"
elif curl -sf --max-time 4 "$AT_LLM_FALLBACK/health/liveliness" >/dev/null 2>&1; then AT_LLM_BASE="$AT_LLM_FALLBACK"
elif curl -sf --max-time 4 -H "Authorization: Bearer $LITELLM_MASTER_KEY" "$AT_LLM_FALLBACK/v1/models" >/dev/null 2>&1; then AT_LLM_BASE="$AT_LLM_FALLBACK"
fi
[[ -n "$AT_LLM_BASE" ]] || { err "LiteLLM not reachable at $AT_LLM_HOST or $AT_LLM_FALLBACK — run 'vz-ai-stack.sh start litellm' (from MAIN)."; exit 1; }
ok "LiteLLM reachable at $AT_LLM_BASE"

# host.docker.internal must resolve from inside containers — AI Town's Convex backend
# dials it for every LLM/embedding call. probe_host_docker_internal lives in docker.sh.
if declare -F probe_host_docker_internal >/dev/null 2>&1; then
  probe_host_docker_internal || { err "host.docker.internal unresolved from containers — the Convex backend can't reach LiteLLM. See the docker.sh hint above."; exit 1; }
else
  source "$AI_STACK/installer/lib/docker.sh" 2>/dev/null || true
  declare -F probe_host_docker_internal >/dev/null 2>&1 && { probe_host_docker_internal || { err "host.docker.internal unresolved from containers"; exit 1; }; }
fi

# embed-local must exist as a LiteLLM model (Ollama nomic-embed-text, 768-dim). A warn,
# not a hard fail — the town's CHAT works without embeddings; only agent *memory recall*
# needs them, and the 768 patch below assumes nomic-embed-text. Surfaced so a user who
# wants memory pulls it.
if ! curl -sf --max-time 5 -H "Authorization: Bearer $LITELLM_MASTER_KEY" "$AT_LLM_BASE/v1/models" 2>/dev/null | grep -q "\"$AT_EMBED_MODEL\""; then
  warn "LiteLLM has no '$AT_EMBED_MODEL' model — agent MEMORY recall (embeddings) won't work until you add it (Ollama nomic-embed-text, 768-dim). Chat still works."
fi

# --- 1. Clone AI Town (best-effort; idempotent) ------------------------------
if [[ ! -d "$AT_DIR/.git" && ! -f "$AT_DIR/docker-compose.yml" ]]; then
  log "Cloning AI Town (a16z-infra/ai-town)…"
  rm -rf "${AT_DIR}.partial"
  if git clone --depth 1 "$AT_REPO" "${AT_DIR}.partial" 2>&1 | tail -5; then
    rmdir "$AT_DIR" 2>/dev/null || true
    mv "${AT_DIR}.partial" "$AT_DIR"
    ok "cloned to $AT_DIR"
  else
    rm -rf "${AT_DIR}.partial"
    err "AI Town clone failed (network/upstream). Place the source at $AT_DIR and re-run 'install 36'."
    exit 1
  fi
else
  ok "AI Town source already present at $AT_DIR"
fi
[[ -f "$AT_DIR/docker-compose.yml" ]] || { err "$AT_DIR has no docker-compose.yml — upstream layout changed; cannot proceed"; exit 1; }

# --- 2. MANDATORY patches BEFORE any schema-push (idempotent, grep-guarded) --
# 2a. Force the vector-index dimension to 768 to match embed-local (nomic-embed-text).
# UPSTREAM SHAPE (verified live against the real clone, 2026-06-24): convex/util/llm.ts
# declares NAMED constants and assigns EMBEDDING_DIMENSION from one of them:
#     const OPENAI_EMBEDDING_DIMENSION   = 1536;
#     const TOGETHER_EMBEDDING_DIMENSION = 768;
#     const OLLAMA_EMBEDDING_DIMENSION   = 1024;
#     export const EMBEDDING_DIMENSION: number = OLLAMA_EMBEDDING_DIMENSION;   // <- the real knob
# A naive `…=1024 → 768` regex is doubly wrong here: the "already-patched?" guard FALSE-MATCHES
# the `…=768` TOGETHER *constant* (so it skips and leaves the index at 1024), and the sed would
# rewrite the OLLAMA constant, not the export. We instead patch the ACTUAL assignment line
# (anchored ^export const EMBEDDING_DIMENSION) to a literal 768 — the named consts stay intact.
# SECOND, NON-OBVIOUS BUG (also verified live): convex/init.ts — which `predev` runs via
# `convex dev --run init` — calls detectMismatchedLLMProvider() UNCONDITIONALLY, whose switch
# treats 768 as "Together.ai" and throws unless TOGETHER_API_KEY is set. We drive a CUSTOM
# provider via LLM_API_URL, so we short-circuit that guard when LLM_API_URL is set
# (getLLMConfig's custom branch already returns without any dimension check — the guard simply
# doesn't apply to a custom gateway). Both edits keep a .orig and are idempotent.
_LLM_TS="$AT_DIR/convex/util/llm.ts"
[[ -f "$_LLM_TS" ]] || { err "expected $_LLM_TS not found — upstream moved EMBEDDING_DIMENSION; re-locate it before pushing (a 1024-dim index breaks embed-local writes)"; exit 1; }
grep -Eq '^export const EMBEDDING_DIMENSION: number = ' "$_LLM_TS" \
  || { err "convex/util/llm.ts has no 'export const EMBEDDING_DIMENSION: number =' line — upstream refactored the vector-index dim knob; re-locate it (must be 768 for embed-local) before pushing."; exit 1; }
_dim_ok=0; _guard_ok=0
grep -Eq '^export const EMBEDDING_DIMENSION: number = 768' "$_LLM_TS" && _dim_ok=1
grep -Fq 'if (process.env.LLM_API_URL) return;' "$_LLM_TS" && _guard_ok=1
if (( _dim_ok && _guard_ok )); then
  ok "convex/util/llm.ts already patched (EMBEDDING_DIMENSION=768 + custom-provider guard)"
else
  cp -p "$_LLM_TS" "${_LLM_TS}.orig" 2>/dev/null || true   # reversible: keep the upstream original
  # (1) the ACTUAL EMBEDDING_DIMENSION assignment → literal 768 (anchored; never the const defs)
  perl -i -pe 's{^export const EMBEDDING_DIMENSION: number = .*$}{export const EMBEDDING_DIMENSION: number = 768; // ai-stack Phase 36: embed-local (nomic-embed-text) is 768-dim}' "$_LLM_TS"
  # (2) custom provider (LLM_API_URL) bypasses the built-in dim<->provider guard. The negative
  #     lookahead makes a re-run a no-op (idempotent — never double-inserts the guard line).
  perl -i -0pe 's{(export function detectMismatchedLLMProvider\(\) \{\n)(?!  if \(process\.env\.LLM_API_URL\))}{$1  if (process.env.LLM_API_URL) return; // ai-stack Phase 36: custom provider bypasses built-in dimension guards\n}' "$_LLM_TS"
  grep -Eq '^export const EMBEDDING_DIMENSION: number = 768' "$_LLM_TS" && grep -Fq 'if (process.env.LLM_API_URL) return;' "$_LLM_TS" \
    || { err "llm.ts patch verify failed (need EMBEDDING_DIMENSION=768 AND the LLM_API_URL guard). Restore: mv ${_LLM_TS}.orig $_LLM_TS"; exit 1; }
  ok "patched convex/util/llm.ts → EMBEDDING_DIMENSION=768 + custom-provider guard (orig kept at ${_LLM_TS##*/}.orig)"
fi
# 2b. NUM_MEMORIES_TO_SEARCH 3 → 1 (throughput; convex/constants.ts). Best-effort.
_CONST_TS="$AT_DIR/convex/constants.ts"
if [[ -f "$_CONST_TS" ]] && grep -Eq 'NUM_MEMORIES_TO_SEARCH[[:space:]]*=[[:space:]]*3' "$_CONST_TS"; then
  sed -i.bak -E 's/(NUM_MEMORIES_TO_SEARCH[[:space:]]*=[[:space:]]*)3/\11/' "$_CONST_TS" && rm -f "${_CONST_TS}.bak"
  grep -Eq 'NUM_MEMORIES_TO_SEARCH[[:space:]]*=[[:space:]]*1' "$_CONST_TS" \
    && ok "patched convex/constants.ts → NUM_MEMORIES_TO_SEARCH=1 (M4/24GB throughput)" \
    || warn "NUM_MEMORIES_TO_SEARCH patch did not verify — left as-is (non-fatal; performance only)"
else
  note "NUM_MEMORIES_TO_SEARCH already tuned or absent — skipping (non-fatal)"
fi

# --- 3. Mint scoped LiteLLM key (stale-aware; mirrors Ph32/34) ---------------
AT_KEY_CURRENT="$(get_env AITOWN_LITELLM_KEY '')"
_at_models=""
[[ -n "$AT_KEY_CURRENT" ]] && _at_models="$(curl -s --max-time 5 -H "Authorization: Bearer $AT_KEY_CURRENT" "$AT_LLM_BASE/v1/models" 2>/dev/null)"
if [[ -z "$AT_KEY_CURRENT" ]] || ! printf '%s' "$_at_models" | grep -q '"id"'; then
  log "Minting scoped LiteLLM key for AI Town (chat + embeddings; local-gemma4 + *-sub fallbacks)…"
  # Scope to the town's chat models AND embed-local (the town needs BOTH /v1/chat and
  # /v1/embeddings; a chat-only key would 401 every memory write).
  _gen_body="$(python3 -c 'import json; print(json.dumps({"models":["local-gemma4","embed-local","claude-opus-sub-xhigh","claude-sonnet-sub-high"],"key_alias":"aitown","metadata":{"owner":"aitown","purpose":"phase36"}}))')"
  AT_KEY_NEW="$(curl -s --max-time 15 -H "Authorization: Bearer $LITELLM_MASTER_KEY" \
    -H 'Content-Type: application/json' -X POST "$AT_LLM_BASE/key/generate" -d "$_gen_body" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$AT_KEY_NEW" ]] || { err "Failed to mint AITOWN_LITELLM_KEY — is LiteLLM up with DATABASE_URL set?"; exit 1; }
  set_env AITOWN_LITELLM_KEY "$AT_KEY_NEW"
  ok "AITOWN_LITELLM_KEY minted + saved to .env (mode 0600)"
else
  ok "AITOWN_LITELLM_KEY already present + valid"
fi
AT_KEY="$(get_env AITOWN_LITELLM_KEY '')"

# --- 4. Resolve bound model (default local-gemma4) ---------------------------
AT_MODEL="$AT_MODEL_DEFAULT"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  _am="$(yq -r '.assignments.aitown // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  [[ -n "$_am" && "$_am" != "null" ]] && AT_MODEL="$_am"
fi
ok "AI Town model = $AT_MODEL (chat via LiteLLM → Phoenix project ai-stack); embeddings = $AT_EMBED_MODEL"

# --- 5. Dedicated bind-mounted data dir + the docker-compose.override.yml -----
# DATA SAFETY: a BIND mount (not a named volume) means an accidental `down -v` cannot
# wipe the town world — the SQLite DB lives on the host at $AT_DATA and survives any
# compose teardown. (--nuke removes it explicitly, backup-first.)
mkdir -p "$AT_DATA/convex"
# The override is the ONLY thing this phase writes into the clone besides the 2 patches:
#   * top-level name: aitown          → stable compose project (check 53 census signal)
#   * loopback publish on $AT_IP      → host-only; never 0.0.0.0
#   * deploy.resources.limits         → caps on EVERY container (compose v2 honors these;
#                                        bin/start-aitown.sh ALSO post-applies docker update
#                                        + verifies, so the cap holds even on an odd engine)
#   * restart: "no"                   → data-safety: never auto-respawn after a `down`
#   * extra_hosts host.docker.internal→ Colima/Podman need it; Docker Desktop/OrbStack
#                                        auto-inject (harmless to set there)
#   * bind-mount the backend's /convex/data → $AT_DATA/convex (the durable world)
#   * bridge-exempt labels            → documented: the Convex stack is self-contained on
#                                        its own ai-town-network and dials the HOST
#                                        (host.docker.internal) for LiteLLM; it never uses
#                                        the ai-stack bridge, so check 16 must not flag it.
# NOTE: service KEYS (frontend/backend/dashboard) must match the upstream compose file's
# service names. a16z-infra/ai-town names them exactly that; if upstream renames, update
# here (the phase fails loudly at `compose config` below if a key is unknown).
cat > "$AT_DIR/docker-compose.override.yml" <<OVR
# Managed by ai-stack Phase 36 (installer/phases/36_aitown.sh). Regenerate: install 36.
# Loopback-only publish + per-container caps + data-safe restart + host.docker.internal.
name: ${AT_PROJECT}
services:
  backend:
    restart: "no"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    # ports: !override — REPLACES upstream's list (compose v2 list-merges plain
    # 'ports:' by APPENDING, so without !override upstream's 0.0.0.0:3210/:3211
    # binds would survive alongside these loopback entries and leak off-box).
    ports: !override
      - "${AT_IP}:${AT_BE_PORT}:${AT_BE_PORT}"
      - "${AT_IP}:3211:3211"
    volumes:
      - "${AT_DATA}/convex:/convex/data"
    labels:
      ai-stack.managed: "true"
      ai-stack.phase: "${PHASE}"
      ai-stack.bridge-exempt: "true"   # self-contained Convex stack; dials host, not the ai-stack bridge
    deploy:
      resources:
        limits:
          cpus: "2.0"
          memory: 3g
  frontend:
    restart: "no"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports: !override   # REPLACE upstream's 0.0.0.0 bind (see backend note)
      - "${AT_IP}:${AT_FE_HOST_PORT}:${AT_FE_CTR_PORT}"
    labels:
      ai-stack.managed: "true"
      ai-stack.phase: "${PHASE}"
      ai-stack.bridge-exempt: "true"
    deploy:
      resources:
        limits:
          cpus: "2.0"
          memory: 2g
  dashboard:
    restart: "no"
    extra_hosts:
      - "host.docker.internal:host-gateway"
    ports: !override   # REPLACE upstream's 0.0.0.0 bind (see backend note)
      - "${AT_IP}:${AT_DASH_PORT}:${AT_DASH_PORT}"
    labels:
      ai-stack.managed: "true"
      ai-stack.phase: "${PHASE}"
      ai-stack.bridge-exempt: "true"
    deploy:
      resources:
        limits:
          cpus: "1.0"
          memory: 1g
OVR
ok "wrote $AT_DIR/docker-compose.override.yml (project=$AT_PROJECT, loopback $AT_IP, caps, restart:no, data→$AT_DATA/convex)"

# Validate the merged compose BEFORE building (catches a service-key rename / bad YAML
# without a multi-minute build first). Uses BOTH files exactly as start/stop will.
_merged_cfg="$( ( cd "$AT_DIR" && docker compose -p "$AT_PROJECT" -f docker-compose.yml -f docker-compose.override.yml config 2>/dev/null ) )" \
  || { err "merged compose is invalid — likely an upstream service-name change vs the override (expected: backend/frontend/dashboard). Fix the override keys, then re-run."; exit 1; }
ok "compose config valid (backend/frontend/dashboard keys match upstream)"
# Assert the `ports: !override` REALLY replaced upstream's binds: no published port may
# bind 0.0.0.0 in the merged config (every entry must be on the loopback alias $AT_IP).
# This catches the silent additive-merge regression the !override fix prevents.
if printf '%s' "$_merged_cfg" | grep -Eq 'published:[[:space:]]*"?0\.0\.0\.0|host_ip:[[:space:]]*0\.0\.0\.0|0\.0\.0\.0:[0-9]'; then
  err "merged compose still publishes a 0.0.0.0 port bind — the override's 'ports: !override' did NOT replace upstream's binds (off-box leak). Inspect: (cd $AT_DIR && docker compose -p $AT_PROJECT config | grep -A2 published)"
  exit 1
fi
ok "no 0.0.0.0 port binds in the merged config (loopback-only publish on $AT_IP verified)"

# --- 6. Bring the stack up (HEAVY first build — minutes) via bin/start-aitown.sh
# The start script owns: compose up --build, loopback publish, the post-up caps
# enforce/verify pass, and the health-poll. Running it here keeps a single funnel
# (so `start aitown` and `install 36` do the IDENTICAL thing).
warn "First build is HEAVY: the frontend image is Ubuntu 22.04 + Node 18 + a full npm build (several minutes, ~2-4GB RAM). On a RAM-saturated box, free memory first (close Chrome; 'vz-ai-stack.sh stop' idle services)."
bash "$AI_STACK/bin/start-aitown.sh" install || { err "bin/start-aitown.sh install failed — see its output (and 'docker compose -p $AT_PROJECT logs')"; exit 1; }

# --- 7. Generate the Convex admin key (against the now-running backend) -------
# The backend ships generate_admin_key.sh; it prints the key. We persist the admin key
# + the self-hosted URL to .env.local IN THE CLONE (Convex CLI reads it from there).
# A `down -v` invalidates this key (see uninstall --nuke) — we never store it in shared
# memory; it lives only in the clone's .env.local (0600) + .env's AITOWN_ADMIN_KEY mirror.
log "Generating the Convex admin key (docker compose exec backend ./generate_admin_key.sh)…"
# RACE GUARD: start-aitown health-gates the FRONTEND (200 on :5273), not the backend —
# the Convex backend may still be migrating its internal schema when we ask for the admin
# key. Retry a few times (bounded) so a still-booting backend is tolerated, not fatal.
AT_ADMIN_KEY=""
for _akt in 1 2 3 4 5; do
  AT_ADMIN_KEY="$( (cd "$AT_DIR" && docker compose -p "$AT_PROJECT" exec -T backend ./generate_admin_key.sh 2>/dev/null) | tr -d '\r' | grep -E '.' | tail -1 )"
  [[ -n "$AT_ADMIN_KEY" ]] && break
  log "  backend not ready for admin-key generation yet (attempt $_akt/5) — waiting 5s…"
  sleep 5
done
[[ -n "$AT_ADMIN_KEY" ]] || { err "could not generate the Convex admin key after 5 tries — the backend may still be booting ('docker compose -p $AT_PROJECT ps' / 'logs backend'). Re-run 'install 36'."; exit 1; }
# Write the admin credential ATOMICALLY: atomic_write creates a 0600 tmpfile, fills it,
# then mv -f into place — the .env.local never exists in a world-readable / partial state.
atomic_write "$AT_DIR/.env.local" <<ENVLOCAL
# Managed by ai-stack Phase 36. Convex self-hosted admin credentials (0600).
# Regenerated by 'install 36'; INVALIDATED by a 'down -v' (uninstall --nuke).
CONVEX_SELF_HOSTED_URL=http://127.0.0.1:${AT_BE_PORT}
CONVEX_SELF_HOSTED_ADMIN_KEY=${AT_ADMIN_KEY}
ENVLOCAL
set_env AITOWN_ADMIN_KEY "$AT_ADMIN_KEY"
ok "Convex admin key generated → $AT_DIR/.env.local (0600, atomic) + mirrored to .env (AITOWN_ADMIN_KEY)"

# --- 8. Set the Convex LLM env vars against the running backend ---------------
# THE wiring step: with LLM_API_URL set, provider=custom → both chat and embeddings go
# through LiteLLM on the scoped key. NO trailing slash, NO /v1 (the code appends them).
# `convex env set` runs on the HOST via npx, reading .env.local for the backend URL+key.
log "Wiring LLM env into Convex (npx convex env set; routes the town through LiteLLM)…"
# Capture stderr to a tmpfile and SURFACE it on failure — a silenced 2>&1 would hide the
# real cause (version mismatch / auth / connection-refused while the backend is booting).
_cvx_err="$(mktemp)"
trap 'rm -f "${_cvx_err:-}"' EXIT
_cvx_env_set() {  # name value  → on failure, the diagnostic is in $_cvx_err
  ( cd "$AT_DIR" && env \
      CONVEX_SELF_HOSTED_URL="http://127.0.0.1:${AT_BE_PORT}" \
      CONVEX_SELF_HOSTED_ADMIN_KEY="$AT_ADMIN_KEY" \
      npx --yes convex env set "$1" "$2" >/dev/null 2>"$_cvx_err" )
}
_cvx_diag() { [[ -s "$_cvx_err" ]] && tail -8 "$_cvx_err" | sed 's/^/    convex: /' >&2; }
_cvx_env_set LLM_API_URL         "$AT_CONVEX_LLM_URL"  || { _cvx_diag; err "convex env set LLM_API_URL failed (npx/convex CLI or backend URL?) — wiring incomplete, not stamping"; exit 1; }
_cvx_env_set LLM_API_KEY         "$AT_KEY"             || { _cvx_diag; err "convex env set LLM_API_KEY failed — not stamping"; exit 1; }
_cvx_env_set LLM_MODEL           "$AT_MODEL"           || { _cvx_diag; err "convex env set LLM_MODEL failed — not stamping"; exit 1; }
_cvx_env_set LLM_EMBEDDING_MODEL "$AT_EMBED_MODEL"     || { _cvx_diag; warn "convex env set LLM_EMBEDDING_MODEL failed — chat works; agent memory recall won't until set. Retry: (cd $AT_DIR && npx convex env set LLM_EMBEDDING_MODEL $AT_EMBED_MODEL)"; }
rm -f "$_cvx_err"; trap - EXIT
ok "Convex LLM env set: LLM_API_URL=$AT_CONVEX_LLM_URL  LLM_MODEL=$AT_MODEL  LLM_EMBEDDING_MODEL=$AT_EMBED_MODEL  (key scoped, not shown)"

# --- 9. Push the Convex code/schema (predev: convex dev --run init --until-success)
# This is what bakes the 768-dim vector index (the patch from step 2). The backend is
# self-hosted, so predev pushes to OUR backend. Bounded so a hung push can't block forever.

# 9a. HOST-side node deps: `npm run predev` runs the LOCAL node_modules/.bin/convex CLI,
# which a `git clone --depth 1` does NOT ship. Install it (idempotent: skip if the local
# convex CLI is already present, so re-runs are fast), then ASSERT the CLI exists before
# pushing — without it predev dies with a misleading 'convex: not found'.
if [[ -x "$AT_DIR/node_modules/.bin/convex" ]]; then
  ok "host node_modules present (node_modules/.bin/convex found) — skipping npm ci"
else
  log "Installing AI Town's host node deps (npm ci → the LOCAL convex CLI predev needs; first run is slow)…"
  _npmci_log="$(mktemp)"
  trap 'rm -f "${_npmci_log:-}"' EXIT
  if ( cd "$AT_DIR" && npm ci ) >"$_npmci_log" 2>&1 || ( cd "$AT_DIR" && npm install ) >>"$_npmci_log" 2>&1; then
    ok "host node deps installed (npm ci/install)"
  else
    tail -20 "$_npmci_log" | sed 's/^/    /'
    rm -f "$_npmci_log"; trap - EXIT
    err "npm ci/install failed in $AT_DIR — predev cannot run without the local convex CLI. Fix node/npm (deps.sh tier-1), then re-run 'install 36'. NOT stamping."
    exit 1
  fi
  rm -f "$_npmci_log"; trap - EXIT
fi
[[ -x "$AT_DIR/node_modules/.bin/convex" ]] \
  || { err "local convex CLI still missing at $AT_DIR/node_modules/.bin/convex after npm install — upstream may have dropped the dep. Cannot push the schema. NOT stamping."; exit 1; }

log "Pushing Convex schema/functions (npm run predev → init the world; bakes the 768-dim index)…"
# Bounded so a hung push (model OOM / backend stall on the RAM-saturated box) can't block
# the install forever. macOS has no `timeout`; use a backgrounded PID + a watcher that
# SIGTERMs (then SIGKILLs) after AT_PREDEV_TIMEOUT seconds (perl-alarm convention, matching
# installer/lib/verify.sh::_verify_with_timeout but inline to avoid sourcing it here).
_predev_log="$(mktemp)"
trap 'rm -f "${_predev_log:-}"' EXIT   # reversible: clean the log even on Ctrl-C/SIGTERM
AT_PREDEV_TIMEOUT="${AT_PREDEV_TIMEOUT:-300}"
_predev_rc=0
perl -e '
  my $secs = shift;
  my $pid  = fork;
  die "fork failed: $!" unless defined $pid;
  if ($pid == 0) { exec @ARGV; die "exec failed: $!"; }
  local $SIG{ALRM} = sub { kill "TERM", $pid; sleep 2; kill "KILL", $pid; exit 124; };
  alarm $secs;
  waitpid($pid, 0);
  exit($? >> 8);
' "$AT_PREDEV_TIMEOUT" \
  bash -c 'cd "$1" && env CONVEX_SELF_HOSTED_URL="http://127.0.0.1:'"${AT_BE_PORT}"'" CONVEX_SELF_HOSTED_ADMIN_KEY="$2" npm run predev' \
  _ "$AT_DIR" "$AT_ADMIN_KEY" >"$_predev_log" 2>&1 || _predev_rc=$?
if [[ "$_predev_rc" -eq 0 ]]; then
  ok "Convex predev push succeeded (world initialized; 768-dim vector index live)"
elif [[ "$_predev_rc" -eq 124 ]]; then
  tail -20 "$_predev_log" | sed 's/^/    /'
  rm -f "$_predev_log"; trap - EXIT
  err "npm run predev TIMED OUT after ${AT_PREDEV_TIMEOUT}s (schema push did NOT complete). Likely a model OOM/stall on the RAM-saturated box, or the backend never finished booting. Free RAM, then re-run 'install 36' (raise AT_PREDEV_TIMEOUT to extend). NOT stamping."
  exit 1
else
  tail -20 "$_predev_log" | sed 's/^/    /'
  rm -f "$_predev_log"; trap - EXIT
  err "npm run predev failed (rc=$_predev_rc) — schema/functions did not push. Common causes: backend still booting, a 1024-vs-768 dim mismatch (verify step-2 patch), or a node/dep gap. Fix, then re-run 'install 36'. NOT stamping."
  exit 1
fi
rm -f "$_predev_log"; trap - EXIT

# --- 10. .gitignore the clone + bind-mounted data (regenerable/data; not repo noise)
[[ -f "$AT_DATA/.gitkeep" ]] || : > "$AT_DATA/.gitkeep"
cat > "$AT_DIR/.gitignore" <<'GI'
# AI Town is a CLONE (regenerable via 'install 36'); these are install/runtime artifacts.
.env.local
docker-compose.override.yml
convex/util/llm.ts.orig
GI

# --- 11. Smoke gate: prove the REAL wiring BEFORE stamping -------------------
# (a) the scoped key reaches the bound model THROUGH LiteLLM (the exact chat path AI
#     Town's characters use), and (b) the backend container actually carries the LLM env
#     we set (so the town will route — not a silent default). A bare frontend-200 is NOT
#     proof; this is.
log "Smoke: scoped key → LiteLLM chat completion (the town's character path)…"
_sc="$(curl -s -o /dev/null -w '%{http_code}' --max-time 30 \
  -H "Authorization: Bearer $AT_KEY" -H 'Content-Type: application/json' \
  -X POST "$AT_LLM_BASE/v1/chat/completions" \
  -d "{\"model\":\"$AT_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":4}" 2>/dev/null || echo 000)"
[[ "$_sc" == "200" ]] || { err "scoped key chat completion returned HTTP $_sc (model $AT_MODEL via LiteLLM) — not stamping"; exit 1; }
ok "scoped key reaches $AT_MODEL through LiteLLM (HTTP 200)"

log "Smoke: the backend container carries LLM_API_URL (the town is actually wired)…"
_be_env="$( (cd "$AT_DIR" && docker compose -p "$AT_PROJECT" exec -T backend printenv LLM_API_URL 2>/dev/null) | tr -d '\r' )"
# Convex env vars set via `convex env set` are stored in the DB and surfaced to functions,
# NOT necessarily as container env — so accept EITHER the container env OR a successful
# `convex env get` as proof the wiring landed.
if [[ "$_be_env" == "$AT_CONVEX_LLM_URL" ]]; then
  ok "backend container env LLM_API_URL=$AT_CONVEX_LLM_URL"
else
  _cvx_get="$( (cd "$AT_DIR" && env CONVEX_SELF_HOSTED_URL="http://127.0.0.1:${AT_BE_PORT}" CONVEX_SELF_HOSTED_ADMIN_KEY="$AT_ADMIN_KEY" npx --yes convex env get LLM_API_URL 2>/dev/null) | tr -d '\r' )"
  [[ "$_cvx_get" == "$AT_CONVEX_LLM_URL" ]] \
    && ok "Convex env LLM_API_URL=$AT_CONVEX_LLM_URL (via convex env get)" \
    || { err "neither container env nor 'convex env get' shows LLM_API_URL=$AT_CONVEX_LLM_URL — the town is NOT wired to LiteLLM. Re-run step 8. NOT stamping."; exit 1; }
fi

log "Smoke: frontend serves 200 on http://$AT_IP:$AT_FE_HOST_PORT/ …"
_fe_up=0
for _ in $(seq 1 30); do
  curl -s -o /dev/null -w '%{http_code}' --max-time 4 "http://$AT_IP:$AT_FE_HOST_PORT/" 2>/dev/null | grep -q '^200$' && { _fe_up=1; break; }
  sleep 2
done
(( _fe_up )) || { err "frontend not serving 200 on http://$AT_IP:$AT_FE_HOST_PORT/ after ~60s — the Vite build may still be running; check 'docker compose -p $AT_PROJECT logs frontend'. NOT stamping."; exit 1; }
ok "frontend healthy on http://$AT_IP:$AT_FE_HOST_PORT/ (alias: http://aitown:$AT_FE_HOST_PORT/)"

stamp_mark "$PHASE"
record "phase 36 complete: AI Town compose stack (project=$AT_PROJECT) + 768-dim patch + scoped key + Convex LLM env wired + predev pushed"
ok "Phase 36 — AI Town — complete"
note "Watch the town: open http://aitown:$AT_FE_HOST_PORT/   (or http://$AT_IP:$AT_FE_HOST_PORT/)"
note "Convex dashboard (admin): http://$AT_IP:$AT_DASH_PORT/   (loopback-only)"
note "Trace every character's LLM call: Phoenix → http://phoenix:6006 (project ai-stack)"
note "Bigger/livelier town (metered): (cd $AT_DIR && npx convex env set LLM_MODEL claude-opus-sub-xhigh) then restart"
note "Manage:    vz-ai-stack.sh start aitown | stop aitown | status | doctor aitown | test 36"
note "Data:      the town world is SQLite at $AT_DATA/convex (bind-mount; survives 'down')"
note "Teardown:  bash $AI_STACK/bin/start-aitown.sh uninstall          # 'down' — PRESERVES the world"
note "Wipe ALL:  bash $AI_STACK/bin/start-aitown.sh uninstall --nuke   # 'down -v' + rm data (backup-first; invalidates the admin key)"
note "Reversible: rm -rf $AT_DIR (regenerable via 'install 36') + rm -f $AI_STACK/installer/state/phase_36.done"
