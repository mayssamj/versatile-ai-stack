# litellm.sh — callback chain helpers.
# Sourced after common.sh + env.sh + docker.sh.
#
# Per Reviewer A #1: file-first, list-second, recreate-third, verify-fourth.
# Callback files that don't exist would crash LiteLLM at startup with
# ImportError. Always assert file exists + Python import succeeds before
# yq-mutating config.yaml.

[[ -z "${AI_STACK:-}" ]] && { echo "litellm.sh: AI_STACK unset" >&2; exit 2; }

LITELLM_CONFIG="$AI_STACK/litellm/config.yaml"

# litellm_has_callback MODULE
# Returns 0 if MODULE is in litellm_settings.callbacks list of config.yaml.
# Capture-then-grep, NEVER `yq | grep -q`: yq line-flushes its output, so
# grep -q's early exit at a mid-list match SIGPIPEs yq (rc 141) and pipefail
# poisons the pipeline — a CORRECT config read as "callback missing" ~40% of
# runs (bit doctor check 06 on a green fresh install, 2026-07-21; same class
# the fleet.sh membership tests already guard against).
litellm_has_callback() {
  local mod="$1" cbs
  cbs="$(yq -r '.litellm_settings.callbacks[]?' "$LITELLM_CONFIG" 2>/dev/null)" || return 1
  grep -qxF "$mod" <<<"$cbs"
}

# litellm_ensure_callback MODULE [FILE_RELATIVE_TO_LITELLM_DIR]
# If FILE is given, verify it exists before adding. Mutate config.yaml
# idempotently (unique list). Caller is responsible for recreating LiteLLM
# afterwards (or calling litellm_recreate_and_verify).
litellm_ensure_callback() {
  local mod="$1" file="${2:-}"
  if [[ -n "$file" ]]; then
    if [[ ! -f "$AI_STACK/litellm/$file" ]]; then
      err "litellm callback file missing: litellm/$file"
      return 1
    fi
  fi
  if litellm_has_callback "$mod"; then
    note "callback already present: $mod"
    return 0
  fi
  yq -i ".litellm_settings.callbacks |= ((. // []) + [\"$mod\"] | unique)" "$LITELLM_CONFIG"
  ok "added callback: $mod"
}

# litellm_remove_callback MODULE
litellm_remove_callback() {
  local mod="$1"
  if ! litellm_has_callback "$mod"; then
    return 0
  fi
  yq -i ".litellm_settings.callbacks |= ((. // []) - [\"$mod\"])" "$LITELLM_CONFIG"
  ok "removed callback: $mod"
}

# Wait for /v1/models to return a non-empty list (LiteLLM ready signal).
litellm_wait_ready() {
  local timeout="${1:-60}" i=0
  # Pre-flight only: a specific, actionable empty-key error (+ a return-2 sentinel)
  # before the retry loop. The value is NOT forwarded — litellm_master_curl injects
  # the key via curl --config (STDIN) below, never on the command line.
  local key; key="$(get_env LITELLM_MASTER_KEY)"
  if [[ -z "$key" ]]; then
    err "LITELLM_MASTER_KEY is empty — run 'vz-ai-stack.sh install 00' (or 'setup') to generate it before starting LiteLLM"
    return 2
  fi
  # Capture-then-grep: curl streams the (large) /v1/models body, so a direct
  # `| grep -q` can SIGPIPE it under pipefail (same class as litellm_has_callback).
  local resp
  while (( i < timeout )); do
    resp="$(litellm_master_curl -s --max-time 3 ${LITELLM_BASE_URL:-http://litellm:4000}/v1/models 2>/dev/null)" || resp=""
    if grep -q '"data"' <<<"$resp"; then
      return 0
    fi
    sleep 1
    i=$((i+1))
  done
  err "LiteLLM /v1/models did not respond within ${timeout}s"
  return 1
}

# litellm_smoke_ok KEY — return 0 if /v1/models returns a model list, trying
# several addresses so it works regardless of host networking quirks (macOS lo0
# aliases / OrbStack vs a plain Linux Docker host). The docker-published host
# port is the machine-agnostic ground truth, so we always include it.
litellm_smoke_ok() {
  # $key is a CALLER-SUPPLIED token ($1), not necessarily the master key — a generic
  # probe, so it intentionally keeps -H (NOT litellm_master_curl). A master-key-in-argv
  # sweep should LEAVE the -H below: the key here is a parameter, not LITELLM_MASTER_KEY.
  local key="$1" url
  [[ -n "$key" ]] || return 2   # empty key → fast-fail; caller reports + diagnoses
  local -a urls=(
    "${LITELLM_BASE_URL:-http://litellm:4000}"
    "http://127.0.0.1:4000"
    "http://127.0.10.1:4000"
  )
  # Also try whatever host port the container actually publishes for 4000 (a busy
  # host may remap it). `docker port` → e.g. "0.0.0.0:4000" / "127.0.0.1:14000";
  # take the trailing :PORT, require it to be numeric, and skip 4000 (already listed).
  local hp; hp="$(docker port litellm 4000 2>/dev/null | head -1 | sed -E 's#.*:([0-9]+)$#\1#')"
  [[ "$hp" =~ ^[0-9]+$ && "$hp" != "4000" ]] && urls+=("http://127.0.0.1:${hp}")
  # Capture-then-grep (pipefail-EPIPE class; see litellm_has_callback).
  local resp
  for url in "${urls[@]}"; do
    resp="$(curl -s --max-time 5 "${url}/v1/models" -H "Authorization: Bearer $key" 2>/dev/null)" || resp=""
    if grep -q '"data"' <<<"$resp"; then
      return 0
    fi
  done
  return 1
}

# litellm_diagnose — print an actionable, secret-free diagnostic when LiteLLM
# won't serve. Designed so a failing install on a remote/cold machine EXPLAINS
# itself instead of dying on a bare "did not return a model list".
litellm_diagnose() (
  # Subshell body ( ) + relaxed errexit: a diagnostic MUST run to completion —
  # it is invoked precisely when things fail, under the phase's `set -Eeuo
  # pipefail`. The previous {} form aborted at the first failing probe (e.g. curl
  # to a dead litellm) — right before the logs, the most useful part. Never again.
  set +e +o pipefail
  local key; key="$(get_env LITELLM_MASTER_KEY "")"
  warn "──── LiteLLM diagnostics ────────────────────────────────────────"
  if container_running litellm 2>/dev/null; then
    warn "container   : running ($(docker ps --filter 'name=^litellm$' --format '{{.Status}}' 2>/dev/null))"
  else
    warn "container   : NOT running — start it: bash $AI_STACK/bin/start-litellm.sh"
  fi
  warn "published   : $(docker port litellm 2>/dev/null | tr '\n' ' ')"
  if (echo > /dev/tcp/127.0.0.1/5432) 2>/dev/null; then
    warn "postgres    : :5432 reachable (server up)"
  else
    warn "postgres    : :5432 NOT reachable — start Honcho: bash $AI_STACK/vz-ai-stack.sh install 03"
  fi
  # Server-reachable != database-present. A MISSING 'litellm' DB (Honcho's pg only
  # creates 'postgres') makes Prisma block uvicorn startup → /v1/models times out.
  local pgc; pgc="$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 -iE 'honcho.*(database|postgres|db)')"
  [[ -z "$pgc" ]] && pgc="honcho-database-1"
  if docker exec "$pgc" psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='litellm'" 2>/dev/null | grep -q 1; then
    warn "litellm DB  : present"
  else
    warn "litellm DB  : MISSING — this blocks Prisma/uvicorn startup (the usual cold-machine cause)."
    warn "              Fix: docker exec $pgc psql -U postgres -c 'CREATE DATABASE litellm'  then  bash $AI_STACK/bin/start-litellm.sh --recreate"
  fi
  local cenv; cenv="$(docker exec litellm printenv LITELLM_MASTER_KEY 2>/dev/null)"
  if [[ -n "$cenv" && -n "$key" && "$cenv" == "$key" ]]; then
    warn "master key  : container matches .env"
  elif [[ -n "$cenv" ]]; then
    warn "master key  : MISMATCH — recreate: bash $AI_STACK/bin/start-litellm.sh --recreate"
  fi
  # Truncate with parameter expansion (NOT `head -c`, which SIGPIPEs upstream).
  local raw; raw="$(litellm_master_curl -s --max-time 5 "${LITELLM_BASE_URL:-http://litellm:4000}/v1/models" 2>&1 | tr -d '\r')"
  if [[ -n "$raw" ]]; then warn "GET /v1/models -> ${raw:0:220}"; else warn "GET /v1/models -> <empty or timeout>"; fi
  warn "recent litellm logs (tail 20):"
  # Redact any sk-… token (LiteLLM logs its master key on first boot) BEFORE it
  # reaches the terminal/stderr — a tee'd install log would otherwise persist it.
  docker logs litellm --tail 20 2>&1 | sed -E 's/sk-[A-Za-z0-9_-]+/[REDACTED]/g; s/^/    /'
  warn "─────────────────────────────────────────────────────────────────"
  warn "Most common fix: bash $AI_STACK/bin/start-litellm.sh --recreate   then re-run: bash $AI_STACK/vz-ai-stack.sh install 01"
  return 0
)

# Assert a callback was loaded by inspecting docker logs.
litellm_assert_callback_loaded() {
  local mod="$1" since="${2:-1m}" n
  # grep -c consumes ALL input (no early exit → no SIGPIPE on the streaming
  # `docker logs`), unlike -q which raced under pipefail.
  n="$(docker logs --since "$since" litellm 2>&1 \
       | grep -ciE "${mod}|$(echo "$mod" | tr '.' '_')|arize_phoenix")" || n=0
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  if (( n > 0 )); then
    return 0
  fi
  warn "callback '$mod' not seen in recent litellm logs (may still be working — verify smoke test)"
  return 1
}
