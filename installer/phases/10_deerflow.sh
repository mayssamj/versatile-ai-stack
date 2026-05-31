#!/usr/bin/env bash
# Phase 10 — DeerFlow research workflows.
#
# Clones github.com/bytedance/deer-flow. DeerFlow's compose at
# deer-flow/docker/docker-compose.yaml references env vars like
# DEER_FLOW_CONFIG_PATH, DEER_FLOW_HOME, DEER_FLOW_REPO_ROOT — these are
# computed and exported by deer-flow/scripts/deploy.sh (which is what
# `make up` calls). Calling `docker compose up -d` directly produces
# `invalid spec: :/app/backend/config.yaml:ro` because the substitutions
# are empty.
#
# We invoke deploy.sh, which:
#   1. Computes DEER_FLOW_{HOME,CONFIG_PATH,REPO_ROOT} from $REPO_ROOT
#   2. Seeds config.yaml from config.example.yaml if not present
#   3. Calls `docker compose -p deer-flow -f docker/docker-compose.yaml up -d --build`
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

PHASE=10
DF_DIR="$AI_STACK/deer-flow"
DF_COMPOSE="$DF_DIR/docker/docker-compose.yaml"
DF_DEPLOY="$DF_DIR/scripts/deploy.sh"

# Are any deerflow containers currently up?
deerflow_running() {
  # Count RUNNING containers in the deer-flow compose project by LABEL. Robust
  # against compose-file-path / CWD differences: deploy.sh runs compose from
  # deer-flow/docker with its own -f, so `docker compose -p deer-flow -f
  # "$DF_COMPOSE" ps` can report zero rows even when the containers are up
  # (the false "no containers running" warning, CHANGELOG 2026-05-30).
  local count
  count="$(docker ps --filter 'label=com.docker.compose.project=deer-flow' --filter 'status=running' -q 2>/dev/null | grep -c . || true)"
  (( count > 0 ))
}

# Wait up to <timeout>s for deerflow containers to reach running (nginx waits
# on gateway+frontend, so they don't all flip to running the instant
# start-deerflow.sh returns).
deerflow_wait_running() {
  local i=0 timeout="${1:-30}"
  while (( i < timeout )); do
    deerflow_running && return 0
    sleep 2; i=$((i+2))
  done
  return 1
}

precheck() {
  [[ -d "$DF_DIR/.git" || -f "$DF_COMPOSE" ]] || return 1
  deerflow_running || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (deerflow)"
  exit 0
fi

hdr "Phase 10 — DeerFlow"

if [[ ! -d "$DF_DIR/.git" && ! -f "$DF_COMPOSE" ]]; then
  log "Cloning DeerFlow (best effort)..."
  rm -rf "${DF_DIR}.partial"
  if git clone https://github.com/bytedance/deer-flow "${DF_DIR}.partial" 2>&1 | tail -5; then
    rmdir "$DF_DIR" 2>/dev/null || true
    mv "${DF_DIR}.partial" "$DF_DIR"
    ok "cloned to $DF_DIR"
  else
    rm -rf "${DF_DIR}.partial"
    warn "DeerFlow clone failed (upstream URL may differ). Place source at $DF_DIR and re-run."
    stamp_mark "$PHASE"
    record "phase 10 complete: deerflow not-configured (clone failed)"
    ok "Phase 10 — DeerFlow — stub complete (upstream-unreachable)"
    exit 0
  fi
fi

# Seed .env files at every level the compose / deploy.sh consults.
# Root .env: SERPER_API_KEY, TAVILY_API_KEY (commented out by default — safe).
# frontend/.env: Next.js build-time env (gitignored; must exist for the
# frontend image build). Repo ships frontend/.env.example as the template.
for env_dir in "$DF_DIR" "$DF_DIR/frontend" "$DF_DIR/backend"; do
  if [[ ! -f "$env_dir/.env" && -f "$env_dir/.env.example" ]]; then
    cp "$env_dir/.env.example" "$env_dir/.env"
    ok "seeded $env_dir/.env from .env.example"
  fi
done

# ── ai-stack patch: wire DeerFlow to local LiteLLM (ports 4000) ──────────────
# Three patches needed for DeerFlow to start cleanly against local LiteLLM:
#   1) config.yaml: models: block ships as comments-only → Pydantic crash-loops
#      (4 workers × restart × LangChain re-import = ~340% CPU). Inject 2 model
#      entries pointing at host.docker.internal:4000.
#   2) docker-compose.yaml: gateway needs LITELLM_MASTER_KEY in its environment
#      block so the $LITELLM_MASTER_KEY substitution in config.yaml resolves at
#      Pydantic-validation time inside the container.
#   3) deer-flow/.env: deploy.sh's env_file pulls from this; mirror the master
#      key from the ai-stack root .env (mode 0600).
#
# All three patches are guarded by marker comments for idempotency.
# CHANGELOG entry: 2026-05-29 "DeerFlow CPU thrashing root cause".

DF_CONFIG="$DF_DIR/config.yaml"
DF_ROOT_ENV="$AI_STACK/.env"
DF_LOCAL_ENV="$DF_DIR/.env"

# Seed config.yaml from config.example.yaml if deploy.sh hasn't run yet.
if [[ ! -f "$DF_CONFIG" && -f "$DF_DIR/config.example.yaml" ]]; then
  cp "$DF_DIR/config.example.yaml" "$DF_CONFIG"
  ok "seeded $DF_CONFIG from config.example.yaml"
fi

# Patch 1: inject local-model entries under `models:` if none exist.
if [[ -f "$DF_CONFIG" ]] && ! grep -q '# ai-stack: local models via LiteLLM' "$DF_CONFIG"; then
  python3 - "$DF_CONFIG" <<'PYEOF'
import re, sys
path = sys.argv[1]
src = open(path).read()
patch = """models:
  # ai-stack: local models via LiteLLM (port 4000 on host).
  # `api_key: $LITELLM_MASTER_KEY` is resolved from env at startup;
  # the gateway container receives it via docker-compose.yaml.
  # `host.docker.internal` lets the deer-flow network reach the host's
  # LiteLLM on the ai-stack network without joining both networks.
  - name: local
    display_name: Local (Qwen3 via LiteLLM)
    use: langchain_openai:ChatOpenAI
    model: local
    api_key: $LITELLM_MASTER_KEY
    base_url: http://host.docker.internal:4000/v1
    request_timeout: 600.0
    max_retries: 2
    max_tokens: 4096
    temperature: 0.7

  - name: local-heavy
    display_name: Local heavy (Qwen3 27B via LiteLLM)
    use: langchain_openai:ChatOpenAI
    model: local-heavy
    api_key: $LITELLM_MASTER_KEY
    base_url: http://host.docker.internal:4000/v1
    request_timeout: 600.0
    max_retries: 2
    max_tokens: 8192
    temperature: 0.7

  """
# Replace the bare `models:` line with the patched block.
new = re.sub(r'^models:\s*\n', patch, src, count=1, flags=re.MULTILINE)
if new == src:
    sys.exit("WARNING: no `models:` line found in config.yaml; not patched")
open(path, "w").write(new)
PYEOF
  ok "patched $DF_CONFIG: injected local + local-heavy model entries"
else
  ok "$DF_CONFIG: local model entries already present"
fi

# Patch 2: ensure docker-compose.yaml passes LITELLM_MASTER_KEY to gateway.
if [[ -f "$DF_COMPOSE" ]] && ! grep -q 'LITELLM_MASTER_KEY=\${LITELLM_MASTER_KEY}' "$DF_COMPOSE"; then
  python3 - "$DF_COMPOSE" <<'PYEOF'
import re, sys
path = sys.argv[1]
src = open(path).read()
patch = """      # ai-stack: surface LITELLM_MASTER_KEY so config.yaml's
      # `api_key: $LITELLM_MASTER_KEY` substitutions resolve (added by
      # installer/phases/10_deerflow.sh; see CHANGELOG 2026-05-29).
      - LITELLM_MASTER_KEY=${LITELLM_MASTER_KEY}
"""
# Insert immediately before the gateway's `env_file:` line.
new = re.sub(
    r'(  gateway:.*?)(    env_file:\s*\n      - \.\./\.env)',
    lambda m: m.group(1) + patch + m.group(2),
    src,
    count=1,
    flags=re.DOTALL,
)
if new == src:
    sys.exit("WARNING: gateway env_file anchor not found; compose not patched")
open(path, "w").write(new)
PYEOF
  ok "patched $DF_COMPOSE: surface LITELLM_MASTER_KEY to gateway"
else
  ok "$DF_COMPOSE: LITELLM_MASTER_KEY already wired"
fi

# Patch 3: mirror LITELLM_MASTER_KEY into deer-flow/.env (mode 0600).
if [[ -f "$DF_ROOT_ENV" && -f "$DF_LOCAL_ENV" ]]; then
  _master_key="$(grep -E '^LITELLM_MASTER_KEY=' "$DF_ROOT_ENV" | head -1 | cut -d= -f2-)"
  if [[ -n "$_master_key" ]]; then
    if ! grep -q '^LITELLM_MASTER_KEY=' "$DF_LOCAL_ENV"; then
      printf '\n# ai-stack (Phase 10): mirrored from %s/.env\n' "$AI_STACK" >> "$DF_LOCAL_ENV"
      printf 'LITELLM_MASTER_KEY=%s\n' "$_master_key" >> "$DF_LOCAL_ENV"
      chmod 600 "$DF_LOCAL_ENV"
      ok "mirrored LITELLM_MASTER_KEY into $DF_LOCAL_ENV (mode 0600)"
    else
      ok "$DF_LOCAL_ENV: LITELLM_MASTER_KEY already present"
    fi
  else
    warn "LITELLM_MASTER_KEY not found in $DF_ROOT_ENV — Phase 01 may not have run"
  fi
fi

# Auto-start via bin/start-deerflow.sh, which exports LITELLM_MASTER_KEY
# before invoking deploy.sh — this prevents the WARN[0000] line from
# docker compose's ${VAR} substitution finding the var missing in the
# shell. (Compose looks for .env next to the compose file, not at the
# project root, so the deer-flow/.env mirror we wrote above doesn't
# satisfy the parse-time substitution.)
DF_START="$AI_STACK/bin/start-deerflow.sh"
if [[ -x "$DF_START" ]] && ! deerflow_running; then
  log "Bringing DeerFlow up via bin/start-deerflow.sh (first build can take 5-15 min)..."
  if bash "$DF_START" 2>&1 | tail -30; then
    if deerflow_wait_running 30; then
      ok "DeerFlow compose: up"
    else
      warn "start-deerflow.sh returned 0 but containers not running after 30s — check 'docker compose -p deer-flow ps' and 'docker compose -p deer-flow logs'"
    fi
  else
    warn "start-deerflow.sh exited non-zero — check 'docker compose -p deer-flow logs'"
  fi
elif [[ ! -x "$DF_START" ]]; then
  warn "bin/start-deerflow.sh missing or not executable — skipping auto-start"
fi

stamp_mark "$PHASE"
record "phase 10 complete: deerflow $(deerflow_running 2>/dev/null && echo up || echo not-up)"
ok "Phase 10 — DeerFlow — complete"
note "DeerFlow: nginx on http://localhost:2026 (when up)"
note "Stop:   bash $AI_STACK/install.sh stop deerflow      (or: stack stop deerflow)"
note "Start:  bash $AI_STACK/install.sh start deerflow     (or: stack start deerflow)"
