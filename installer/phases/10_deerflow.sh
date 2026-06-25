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

# Patch 1: populate DeerFlow's `models:` block = the model picker. The picker is
# 100% DATA-DRIVEN (config.yaml `models:` → GET /api/models → the frontend's
# models.map()), so each entry here = one selectable option. We expose the two
# stable tiers FIRST — `local` (basic) + `local-heavy` (reasoning), which DeerFlow
# uses as models[0] default and references by name — THEN one entry per assignable
# chat model from installer/models.yml that LiteLLM actually serves, so the user
# can pick any model on their box (not just the two tiers).
# Resolve DeerFlow's two-tier models from installer/models.yml. Platform policy
# (2026-06-20): both tiers default to claude-opus-sub-xhigh — the "basic"
# entry (name: local) tracks `.primary` and the "reasoning" entry (name:
# local-heavy) tracks the deerflow assignment. lmstudio assignments still gate
# DOWN to `.default` (local-gemma4, the offline net) when their runtime is down /
# the slug isn't in config.yaml, so DeerFlow never gets a model_name LiteLLM
# can't serve. We map BOTH tiers, never silently rewrite only one. DeerFlow uses
# the MASTER key, so there is NO scoped-key allowlist to widen.
DF_BASIC_MODEL="claude-opus-sub-xhigh"
DF_REASON_MODEL="claude-opus-sub-xhigh"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  DF_BASIC_MODEL="$(yq -r '.primary' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  _dfa="$(yq -r '.assignments.deerflow // ""' "$AI_STACK/installer/models.yml" 2>/dev/null)"
  _dfrt="$(yq -r ".models.\"$_dfa\".runtime" "$AI_STACK/installer/models.yml" 2>/dev/null)"
  if [[ -n "$_dfa" && "$_dfa" != "null" ]]; then
    if [[ "$_dfrt" == "lmstudio" ]] \
       && ! { curl -s -o /dev/null --max-time 3 http://127.0.0.1:1234/v1/models 2>/dev/null \
              && grep -qE "model_name: ${_dfa}\$" "$AI_STACK/litellm/config.yaml" 2>/dev/null; }; then  # end-anchored so openai-gpt != openai-gpt-pro
      DF_REASON_MODEL="$DF_BASIC_MODEL"   # gated fallback
    else
      DF_REASON_MODEL="$_dfa"
    fi
  fi
fi

# Build the picker entry list: the two stable tiers (local/local-heavy) FIRST
# (DeerFlow's factory uses models[0] as the default and references both by name),
# then ONE entry per assignable chat model from installer/models.yml that LiteLLM
# actually serves (its model_name is in litellm/config.yaml) — so every option is
# routable with DeerFlow's MASTER key (no scoped allowlist to widen). TSV columns:
# name<TAB>display<TAB>model<TAB>max_tokens. model: is the LiteLLM model_name (alias).
DF_MODELS_TSV="$(printf 'local\tBasic (ai-stack default via LiteLLM)\t%s\t4096\nlocal-heavy\tReasoning (ai-stack deerflow assignment via LiteLLM)\t%s\t8192\n' "$DF_BASIC_MODEL" "$DF_REASON_MODEL")"
if [[ -f "$AI_STACK/installer/models.yml" ]] && command -v yq >/dev/null 2>&1; then
  # exact whole-line membership against LiteLLM's served model_names (avoids the
  # prefix false-positive of a substring grep, e.g. openai-gpt vs openai-gpt-pro).
  _df_served="$(yq -r '.model_list[].model_name' "$AI_STACK/litellm/config.yaml" 2>/dev/null)"
  # prettify an alias into a picker label so display_name isn't identical to the
  # model: subtitle (e.g. claude-opus-sub-xhigh -> "Claude Opus Sub Xhigh").
  _df_pretty() { printf '%s' "$1" | sed -E 's/-/ /g' | awk '{for(i=1;i<=NF;i++)$i=toupper(substr($i,1,1)) substr($i,2)}1'; }
  while IFS= read -r _alias; do
    [[ -z "$_alias" || "$_alias" == "null" ]] && continue
    printf '%s\n' "$_df_served" | grep -qxF "$_alias" || continue   # only if LiteLLM serves it
    DF_MODELS_TSV+=$'\n'"$(printf '%s\t%s\t%s\t8192' "$_alias" "$(_df_pretty "$_alias")" "$_alias")"
  done < <(yq -r '.models | to_entries | .[] | .key' "$AI_STACK/installer/models.yml" 2>/dev/null)
fi

# Inject (first run) or regenerate (subsequent) the ai-stack `models:` block.
# Delimited by BEGIN/END markers and rewritten WHOLESALE each run so it converges
# on add/remove/rename of models; upstream's commented example models (after END)
# are left untouched. Also MIGRATES the pre-marker two-entry block (older phase).
if [[ -f "$DF_CONFIG" ]]; then
  DF_MODELS_TSV="$DF_MODELS_TSV" python3 - "$DF_CONFIG" <<'PYEOF'
import os, re, sys
path = sys.argv[1]
tsv = os.environ.get("DF_MODELS_TSV", "")
BEGIN = "  # >>> ai-stack: local models via LiteLLM — BEGIN (data-driven picker; regenerated when phase 10 re-runs / on `model sync` — edit installer/models.yml + litellm, NOT here)"
END   = "  # <<< ai-stack: local models via LiteLLM — END"
def render(tsv):
    out = [BEGIN]
    for line in tsv.splitlines():
        if not line.strip():
            continue
        name, display, model, max_tokens = line.split("\t")
        out.append(
            "  - name: %s\n"
            "    display_name: %s\n"
            "    use: langchain_openai:ChatOpenAI\n"
            "    model: %s\n"
            "    api_key: $LITELLM_MASTER_KEY\n"
            "    base_url: http://host.docker.internal:4000/v1\n"
            "    request_timeout: 600.0\n"
            "    max_retries: 2\n"
            "    max_tokens: %s\n"
            "    temperature: 0.7\n" % (name, display, model, max_tokens))
    out.append(END)
    return "\n".join(out) + "\n"
block = render(tsv)
orig = open(path).read()
src = orig
# MIGRATION: strip the OLD pre-marker block (comment header through the local-heavy
# entry) so a re-run with this phase does not double-inject `name: local`.
if BEGIN not in src:
    src = re.sub(
        r'  # ai-stack: local models via LiteLLM \(port 4000.*?\n  - name: local-heavy\n(?:    [^\n]*\n)+?    temperature:[^\n]*\n',
        '', src, count=1, flags=re.DOTALL)
if BEGIN in src and END in src:
    new = re.sub(re.escape(BEGIN) + r".*?" + re.escape(END) + r"\n?", block, src, count=1, flags=re.DOTALL)
else:
    new = re.sub(r'^models:[ \t]*\n', "models:\n" + block, src, count=1, flags=re.MULTILINE)
    if new == src:
        sys.exit("WARNING: no `models:` line found in config.yaml; not patched")
if new != orig:
    open(path, "w").write(new)
PYEOF
  _df_n="$(printf '%s\n' "$DF_MODELS_TSV" | grep -c .)"
  ok "patched $DF_CONFIG: $_df_n models in the picker (local, local-heavy + served models.yml chat models)"
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
note "DeerFlow: nginx on http://localhost:2026 or http://deerflow:2026 (loopback-only; run prepare-sudo, then 'ingress up' for the port-free http://deerflow/)"
note "Stop:   bash $AI_STACK/vz-ai-stack.sh stop deerflow      (or: stack stop deerflow)"
note "Start:  bash $AI_STACK/vz-ai-stack.sh start deerflow     (or: stack start deerflow)"
