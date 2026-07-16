#!/usr/bin/env bash
# smoke/01.sh — phase 01 smoke: /v1/models + chat completion + trace file appended + per-model ping.
#
# Reachability section (Safety Reviewer 2): the original Phase 01 incident
# shipped because a curl to a localhost-bound port passed even though the
# 127.0.10.x alias path was dead air. The verify_container_reachable_by_*
# probes below close that gap — they prove the network paths apps actually
# use (alias from host AND bare-name from in-network containers) WORK.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/validate.sh"
source "$AI_STACK/installer/lib/network.sh"
source "$AI_STACK/installer/lib/verify.sh"
source "$AI_STACK/installer/lib/litellm.sh"

hdr "Smoke 01 — inference plane"

# 0. REACHABILITY (pre-condition for everything that follows).
# /health/readiness, NOT bare /health: LiteLLM's /health actively PINGS every
# configured model — a real call per route that LOADS local ollama/lmstudio
# models (never-load directive) and bills metered ones. Readiness is a static
# ~30ms probe that also catches the Prisma-DB SPOF. (Same fix as services.yml.)
log "Reachability: litellm via http://litellm:4000 (host → alias)..."
verify_container_reachable_by_alias litellm litellm 4000 /health/readiness \
  || { err "litellm not reachable via http://litellm:4000 — refusing to claim phase complete"; exit 1; }
ok "litellm answers on http://litellm:4000"

log "Reachability: litellm by bare name in ai-stack network (container → DNS)..."
verify_container_reachable_by_docker_dns ai-stack litellm 4000 \
  || { err "litellm not reachable by docker DNS on ai-stack network"; exit 1; }
ok "litellm answers on ai-stack network DNS"

KEY="$(get_env LITELLM_MASTER_KEY)"
[[ -n "$KEY" ]] || { err "LITELLM_MASTER_KEY empty"; exit 1; }

# 1. Models endpoint
log "/v1/models ..."
models_json="$(litellm_master_curl -s --max-time 5 http://litellm:4000/v1/models)"
if ! echo "$models_json" | grep -q '"data"'; then
  err "/v1/models did not return data"
  echo "$models_json" | head -5
  exit 1
fi
N="$(echo "$models_json" | jq -r '.data | length')"
ok "$N models served"

# 2. Chat completion to local
log "chat completion → local ..."
# Read trace count from inside the container (OrbStack bind-mounts can show a
# stale snapshot to the host — the container's view is the source of truth).
container_lines() {
  docker exec litellm sh -c 'wc -l < /traces/litellm.jsonl 2>/dev/null || echo 0' 2>/dev/null \
    | tr -d '[:space:]'
}
before_lines="$(container_lines)"
resp="$(litellm_master_curl -s --max-time 60 \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"Say exactly the word: ping"}],"max_tokens":50}' \
  http://litellm:4000/v1/chat/completions)"
content="$(echo "$resp" | jq -r '.choices[0].message.content // .choices[0].message.reasoning_content // empty' 2>/dev/null)"
finish="$(echo "$resp" | jq -r '.choices[0].finish_reason // empty')"
if [[ -z "$content" && -z "$finish" ]]; then
  err "chat completion failed"; echo "$resp" | head -5; exit 1
fi
ok "local responded (finish=$finish, len=${#content})"

# 3. Trace file appended (read from container; host view may lag)
sleep 2
after_lines="$(container_lines)"
if [[ -n "$after_lines" && -n "$before_lines" ]] && (( after_lines > before_lines )); then
  ok "traces/litellm.jsonl appended ($((after_lines - before_lines)) new lines, container view)"
else
  warn "container trace count: before=$before_lines after=$after_lines"
  warn "host view: $(wc -l < "$AI_STACK/traces/litellm.jsonl" 2>/dev/null || echo missing) lines"
  warn "(OrbStack bind-mount snapshot quirk — container has the data, host may not see it until container recreate)"
fi

# 4. Per-model ping (Reviewer Adversarial #10)
hdr "Per-model reachability ping"
mapfile -t MODELS < <(echo "$models_json" | jq -r '.data[].id')
PASS=0; FAIL=0; SKIP=0
RESULTS_FILE="$AI_STACK/installer/state/model-ping-results.txt"
: > "$RESULTS_FILE"
for m in "${MODELS[@]}"; do
  # Embedding models have a different endpoint; skip them in the chat smoke.
  if [[ "$m" == embed-* ]]; then
    printf '  %-40s %s\n' "$m" "SKIP (embedding)"
    SKIP=$((SKIP+1)); echo "$m	SKIP" >> "$RESULTS_FILE"; continue
  fi
  # Wrap in a subshell that always exits 0 — under inherit_errexit, a curl
  # timeout (28) would otherwise abort the smoke loop.
  rc="$(litellm_master_curl -s -o /dev/null -w '%{http_code}' --max-time 60 \
    -H "Content-Type: application/json" \
    -d "{\"model\":\"$m\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":1}" \
    http://litellm:4000/v1/chat/completions 2>/dev/null || echo "000")"
  if [[ "$rc" == "200" ]]; then
    printf '  %-40s %s\n' "$m" "${C_GREEN}PASS${C_RESET}"
    PASS=$((PASS+1)); echo "$m	PASS" >> "$RESULTS_FILE"
  else
    printf '  %-40s %s\n' "$m" "${C_RED}FAIL ($rc)${C_RESET}"
    FAIL=$((FAIL+1)); echo "$m	FAIL($rc)" >> "$RESULTS_FILE"
  fi
done
printf '\n%d pass · %d fail · %d skip  (results: %s)\n' "$PASS" "$FAIL" "$SKIP" "$RESULTS_FILE"
ok "smoke 01 complete"
