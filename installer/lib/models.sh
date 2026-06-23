#!/usr/bin/env bash
# models.sh — declarative model<->agent binding.
#
#   installer/models.yml is the CANONICAL source of truth. This lib renders every
#   agent's config + the LiteLLM model_list from it.
#
#     vz-ai-stack.sh model list  [--json]            READ-ONLY catalog + live matrix
#     vz-ai-stack.sh model assign <agent> <model>    re-point one agent (yq -i + sync-one)
#     vz-ai-stack.sh model sync   [<agent>]          crash-safe 6-phase reconcile
#
# Design (per the adversarial critique — these are load-bearing):
#   1. FRESH-INSTALL SAFE — never auto-run by `install all`; phases keep their
#      legacy `local` fallback when models.yml is absent.
#   2. AVAILABILITY-GATED — an lmstudio model whose server is down / id not served
#      renders the agent to the Ollama default (local-gemma4) + records a pending
#      line. We NEVER render an MLX slug that LiteLLM can't serve.
#   3. SUPERSET-BEFORE-MINT — the 3 canonical IDs are registered in config.yaml
#      BEFORE any key is minted. Scoped keys always carry the fixed SUPERSET so
#      `assign` never re-mints.
#   4. CRASH-SAFE ORDER in sync: P0 validate, P1 register model_list, P2 restart
#      litellm ONCE if changed, P3 widen key allowlists, P4 render agents
#      (gated), P5 verify.
#   5. ATOMIC writes (lib helpers do temp+mv); key VALUES never hit stdout/argv/log.
#   6. IDEMPOTENT — restart only if config.yaml changed; rewrite an entry only if
#      its served id differs.
#
# House style mirrors lib/status.sh / lib/reset.sh: source the libs, simple
# dispatch, log/ok/warn/err from common.sh.
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/litellm.sh"
source "$AI_STACK/installer/lib/lmstudio.sh"

MODELS_YML="$AI_STACK/installer/models.yml"
CONFIG="$AI_STACK/litellm/config.yaml"
PENDING_FILE="$STATE_DIR/models-pending.txt"
PENDING_HERMES="$STATE_DIR/models-pending-hermes.txt"
HERMES_SANDBOX="hermes-fleet-v1"
LITELLM_SANDBOX_URL="http://host.docker.internal:4000/v1"

# The scoped-key allowlist is ALWAYS the DERIVED superset (sorted-unique), so
# `assign`/`add` never need a re-mint (constraint 3). It is the union of the
# legacy names {local local-heavy local-lfm2} and EVERY model declared in
# models.yml (so a `model add`-ed slug is automatically covered). If models.yml
# is absent/unparseable we fall back to the legacy 6-name list.
LEGACY_SUPERSET=(local local-gemma4 local-heavy local-lfm2 local-qwen3)

# superset_members — print the sorted-unique union of the legacy names and every
# models.yml model key, one per line. Errexit/pipefail-safe.
superset_members() {
  local names
  names="$(my_q '.models | keys | .[]' 2>/dev/null || echo '')"
  if [[ -z "$names" ]]; then
    printf '%s\n' "${LEGACY_SUPERSET[@]}" | LC_ALL=C sort -u
    return 0
  fi
  { printf '%s\n' local local-heavy local-lfm2; printf '%s\n' "$names"; } \
    | grep -v '^[[:space:]]*$' | LC_ALL=C sort -u
}

# ---------------------------------------------------------------------------
# 0. models.yml accessors (fail-closed; exit 2 if the file is missing/unparseable)
# ---------------------------------------------------------------------------
my_q() { yq -r "$1" "$MODELS_YML" 2>/dev/null; }

# Membership tests. We capture the yq output into a var FIRST, then grep the
# here-string. A direct `my_q ... | grep -qxF` would die under `set -o pipefail`:
# `grep -q` closes the pipe on first match, yq gets SIGPIPE (exit 141), and
# pipefail propagates that as a failure — making every lookup wrongly "not found".
agent_exists() { local out; out="$(my_q '.kinds | keys | .[]')"; grep -qxF "$1" <<<"$out"; }
model_exists() { local out; out="$(my_q '.models | keys | .[]')"; grep -qxF "$1" <<<"$out"; }

models_yml_present() { [[ -f "$MODELS_YML" ]]; }

# seed_if_missing — if models.yml is absent, write the guarded canonical template
# so `sync` has something to render. (We ship models.yml in-repo, so this is a
# safety net for a partial checkout, NOT the normal path.) Never overwrites.
seed_if_missing() {
  [[ -f "$MODELS_YML" ]] && return 0
  warn "installer/models.yml absent — seeding the canonical template"
  cat > "$MODELS_YML" <<'YAML'
# Seeded by vz-ai-stack.sh model (models.yml was missing). Edit + re-run `model sync`.
version: 1
models:
  local-gemma4:
    runtime: ollama
    served: gemma4:e4b
    big: false
    note: "Default for any unassigned agent."
  local-qwen3.6:
    runtime: lmstudio
    served: qwen/qwen3.6-27b
    big: true
    ttl: 1800
  local-qwen3-coder:
    runtime: lmstudio
    served: qwen3-coder-30b-a3b-instruct-mlx
    big: true
    ttl: 1800
default: local-gemma4
assignments:
  hermes_cos:               local-qwen3.6
  hermes_software_engineer: local-qwen3-coder
  hermes_researcher:        local-qwen3.6
  hermes_creator:           local-gemma4
  hermes_reviewer:          local-qwen3-coder
  hermes_data_analyst:      local-qwen3.6
  hermes_ops:               local-gemma4
  pi:                       local-qwen3-coder
  deerflow:                 local-qwen3.6
  ace:                      local-gemma4
  rlm:                      local-gemma4
kinds:
  hermes_cos:               { kind: hermes-profile, profile: hermes_cos,               key_env: HERMES_LITELLM_KEY }
  hermes_software_engineer: { kind: hermes-profile, profile: hermes_software_engineer, key_env: HERMES_LITELLM_KEY }
  hermes_researcher:        { kind: hermes-profile, profile: hermes_researcher,        key_env: HERMES_LITELLM_KEY }
  hermes_creator:           { kind: hermes-profile, profile: hermes_creator,           key_env: HERMES_LITELLM_KEY }
  hermes_reviewer:          { kind: hermes-profile, profile: hermes_reviewer,          key_env: HERMES_LITELLM_KEY }
  hermes_data_analyst:      { kind: hermes-profile, profile: hermes_data_analyst,      key_env: HERMES_LITELLM_KEY }
  hermes_ops:               { kind: hermes-profile, profile: hermes_ops,               key_env: HERMES_LITELLM_KEY }
  pi:                       { kind: pi,       phase: 15, key_env: PI_LITELLM_KEY }
  deerflow:                 { kind: deerflow, phase: 10 }
  ace:                      { kind: ace,      phase: 17, key_env: ACE_LITELLM_KEY }
  rlm:                      { kind: rlm,      phase: 18, key_env: RLM_LITELLM_KEY }
YAML
  ok "seeded $MODELS_YML"
}

# validate — fail-closed (constraint: P0). Exits 2 on any structural error.
validate() {
  if ! models_yml_present; then
    err "installer/models.yml not found at $MODELS_YML"
    return 2
  fi
  if ! yq eval '.' "$MODELS_YML" >/dev/null 2>&1; then
    err "installer/models.yml is not valid YAML"
    return 2
  fi
  local ver; ver="$(my_q '.version')"
  [[ "$ver" == "1" ]] || { err "models.yml: unsupported version '$ver' (expected 1)"; return 2; }

  local default; default="$(my_q '.default')"
  [[ -n "$default" && "$default" != "null" ]] || { err "models.yml: .default is missing"; return 2; }
  # default must resolve to a declared model
  if ! model_exists "$default"; then
    err "models.yml: default '$default' is not a declared model"; return 2
  fi
  # The default is the ALWAYS-ON availability-gating fallback — it must be an
  # Ollama model so it is servable on a fresh install with LM Studio down.
  # (Otherwise an lmstudio default would silently break invariant 1/fresh-install.)
  if [[ "$(my_q ".models.\"$default\".runtime")" != "ollama" ]]; then
    err "models.yml: default '$default' must be an ollama-runtime model (the always-on fallback)"; return 2
  fi
  # `primary` (optional) — the model an UNASSIGNED agent renders. Any runtime is
  # allowed (it availability-gates to the ollama `default` when its runtime is down).
  local primary; primary="$(my_q '.primary')"
  if [[ -n "$primary" && "$primary" != "null" ]] && ! model_exists "$primary"; then
    err "models.yml: primary '$primary' is not a declared model"; return 2
  fi

  # Every model entry must declare a runtime + served, and runtime in {ollama,lmstudio}.
  local m rt sv
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    rt="$(my_q ".models.\"$m\".runtime")"
    sv="$(my_q ".models.\"$m\".served")"
    case "$rt" in
      ollama|lmstudio) : ;;
      meridian)
        # Claude subscription via Meridian. Must declare a valid effort level.
        local ef; ef="$(my_q ".models.\"$m\".effort")"
        case "$ef" in
          low|medium|high|xhigh|max|ultracode) : ;;
          *) err "models.yml: meridian model '$m' has invalid effort '$ef' (want low|medium|high|xhigh|max|ultracode)"; return 2 ;;
        esac ;;
      openai|codex-bridge)
        # OpenAI GPT — metered API key (openai) or the ChatGPT subscription via the
        # codex-bridge daemon (codex-bridge). `effort` is OPTIONAL here and maps to
        # OpenAI's reasoning_effort; if present it must be a valid GPT-5.x level.
        local re; re="$(my_q ".models.\"$m\".effort")"
        if [[ -n "$re" && "$re" != "null" ]]; then
          case "$re" in
            none|low|medium|high|xhigh) : ;;
            *) err "models.yml: $rt model '$m' has invalid effort '$re' (want none|low|medium|high|xhigh)"; return 2 ;;
          esac
        fi ;;
      *) err "models.yml: model '$m' has invalid runtime '$rt' (want ollama|lmstudio|meridian|openai|codex-bridge)"; return 2 ;;
    esac
    [[ -n "$sv" && "$sv" != "null" ]] || { err "models.yml: model '$m' missing .served"; return 2; }
  done < <(my_q '.models | keys | .[]')

  # 'all' is a reserved keyword for `model assign all <model>` — an agent named
  # 'all' would make assign (wildcard) and sync (specific agent) disagree.
  if agent_exists all; then
    err "models.yml: 'all' is reserved (it's the blanket-assign keyword) — rename that kind"; return 2
  fi

  # Every assignment must reference a known agent (in kinds:) AND a declared model.
  local a am
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    if ! agent_exists "$a"; then
      err "models.yml: assignment for '$a' has no matching kinds: entry"; return 2
    fi
    am="$(my_q ".assignments.\"$a\"")"
    if ! model_exists "$am"; then
      err "models.yml: agent '$a' assigned undeclared model '$am'"; return 2
    fi
  done < <(my_q '.assignments | keys | .[]')

  return 0
}

agents() { my_q '.assignments | keys | .[]'; }
agent_assigned() { my_q ".assignments.\"$1\""; }
agent_kind()     { my_q ".kinds.\"$1\".kind"; }
agent_profile()  { my_q ".kinds.\"$1\".profile"; }
agent_keyenv()   { my_q ".kinds.\"$1\".key_env"; }
model_runtime()  { my_q ".models.\"$1\".runtime"; }
model_served()   { my_q ".models.\"$1\".served"; }
# model_effort <model> — the effort knob: meridian's `effort` / openai+codex-bridge's
# reasoning_effort. Normalizes a missing key (yq prints "null") to "" so an
# optional-effort model (e.g. gpt-5.5-pro) renders NO effort key, and meridian's
# ${effort:-high} default still applies (every meridian model declares one anyway).
model_effort()   { local e; e="$(my_q ".models.\"$1\".effort")"; [[ "$e" == "null" ]] && e=""; echo "$e"; }
model_ttl()      { local t; t="$(my_q ".models.\"$1\".ttl")"; [[ "$t" == "null" || -z "$t" ]] && echo 1800 || echo "$t"; }
default_model()  { my_q '.default'; }
primary_model()  { local p; p="$(my_q '.primary')"; [[ -z "$p" || "$p" == "null" ]] && p="$(my_q '.default')"; echo "$p"; }

# ---------------------------------------------------------------------------
# 1. Availability gate (constraint 2)
# ---------------------------------------------------------------------------
# config_has_slug <model_name> — is this model_name present in config.yaml?
config_has_slug() {
  yq -e ".model_list[] | select(.model_name == \"$1\")" "$CONFIG" >/dev/null 2>&1
}

# litellm_reachable — is the gateway answering? Used by render/verify guards so
# we never mis-judge key coverage when LiteLLM is simply down.
litellm_reachable() {
  curl -sf --max-time 3 "${LITELLM_BASE_URL:-http://litellm:4000}/health/readiness" >/dev/null 2>&1
}

# meridian_up — is the Claude-subscription host daemon answering? Loopback only
# (host-side; lib runs on the host). LiteLLM lists meridian models even when the
# daemon is down (model_list is static config), so we MUST probe Meridian itself
# to availability-gate — litellm_serves_slug can't detect a down upstream here.
meridian_up() {
  curl -sf --max-time 3 "http://127.0.0.1:${MERIDIAN_PORT:-3456}/v1/models" \
    -H "Authorization: Bearer x" >/dev/null 2>&1
}

# codex_bridge_up — is the ChatGPT-subscription bridge daemon answering? Loopback
# only. LiteLLM lists codex-bridge models even when the daemon is down (static
# config), so we probe the bridge itself to availability-gate. Mirrors meridian_up.
codex_bridge_up() {
  curl -sf --max-time 3 "http://127.0.0.1:${CODEX_BRIDGE_PORT:-3457}/v1/models" \
    -H "Authorization: Bearer x" >/dev/null 2>&1
}

# litellm_serves_slug <model_name> — does the master-key /v1/models list it?
litellm_serves_slug() {
  local want="$1" key
  key="$(get_env LITELLM_MASTER_KEY '')"
  [[ -n "$key" ]] || return 1
  curl -s --max-time 5 "${LITELLM_BASE_URL:-http://litellm:4000}/v1/models" \
    -H "Authorization: Bearer $key" 2>/dev/null \
    | python3 -c 'import sys,json
w=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if any(m.get("id")==w for m in d.get("data",[])) else 1)' "$want"
}

# resolve_effective <agent> — echo the model we will ACTUALLY render for <agent>.
# For an lmstudio model: render the slug only when LM Studio is up AND the served
# id is present in config.yaml AND LiteLLM lists it. Otherwise fall back to the
# Ollama default and record a pending line. Ollama models render as-is.
# Echoes the effective model name. Sets _GATED=1 (global) if it fell back.
resolve_effective() {
  local agent="$1" declared rt default
  declared="$(agent_assigned "$agent")"
  default="$(default_model)"
  # Unassigned agent -> the `primary` default model (availability-gated to `default`,
  # the always-on ollama fallback, exactly like an assigned model would be).
  [[ -z "$declared" || "$declared" == "null" ]] && declared="$(primary_model)"
  rt="$(model_runtime "$declared")"
  _GATED=0
  case "$rt" in
    lmstudio)
      # LM Studio: render the slug only when the server is up AND it's registered
      # AND LiteLLM lists it; else fall through to the default.
      if lms_server_up && config_has_slug "$declared" && litellm_serves_slug "$declared"; then
        echo "$declared"; return 0
      fi ;;
    meridian)
      # Claude subscription: render only when the Meridian daemon is up AND the
      # model is registered; else fall through to the default. (LiteLLM lists the
      # model even when Meridian is down, so we probe Meridian directly.)
      if meridian_up && config_has_slug "$declared"; then
        echo "$declared"; return 0
      fi ;;
    openai)
      # Metered OpenAI API: render only when OPENAI_API_KEY is present; else gate to
      # the default so a keyless box never hard-fails (invariant 1/2). When the key
      # is set, LiteLLM's fallback chain covers a transient API outage.
      if [[ -n "$(get_env OPENAI_API_KEY '')" ]] && config_has_slug "$declared"; then
        echo "$declared"; return 0
      fi ;;
    codex-bridge)
      # GPT on the ChatGPT subscription via the codex-bridge daemon: render only
      # when the bridge is up AND the model is registered; else gate to the default.
      # (LiteLLM lists it even when the bridge is down, so we probe the bridge.)
      if codex_bridge_up && config_has_slug "$declared"; then
        echo "$declared"; return 0
      fi ;;
    *)
      echo "$declared"; return 0 ;;
  esac
  # Availability gate fell through — render the default. Record the intent (unless
  # the caller is the READ-ONLY `list`/dry-run path, which must not mutate state).
  _GATED=1
  [[ "${_NO_PENDING:-0}" != "1" ]] && _record_pending "$agent" "$declared" "$default" "$(model_served "$declared")"
  echo "$default"; return 0
}

# is_gated <agent> <effective> — did this agent's render fall back? We re-derive
# it locally because resolve_effective sets the _GATED global INSIDE a command-
# substitution subshell ( eff="$(resolve_effective ...)" ), so that global never
# reaches the caller. Gated == the assigned model is lmstudio but we rendered
# something else (the availability fallback).
is_gated() {
  # Mirror resolve_effective's declared resolution: an UNASSIGNED agent routes through
  # `primary`, so gating (and its pending/warning observability) must resolve it too.
  local declared; declared="$(agent_assigned "$1")"
  [[ -z "$declared" || "$declared" == "null" ]] && declared="$(primary_model)"
  local rt; rt="$(model_runtime "$declared")"
  [[ ( "$rt" == "lmstudio" || "$rt" == "meridian" || "$rt" == "openai" || "$rt" == "codex-bridge" ) && "$2" != "$declared" ]]
}

_record_pending() {
  local agent="$1" declared="$2" fallback="$3" served="$4"
  mkdir -p "$STATE_DIR"
  # Replace any prior line for this agent, then append the fresh one (atomic).
  local tmp; tmp="$(mktemp "${PENDING_FILE}.XXXXXX")"
  if [[ -f "$PENDING_FILE" ]]; then grep -v "^${agent}	" "$PENDING_FILE" 2>/dev/null > "$tmp" || true; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$agent" "$declared" "$fallback" "$served" "$(ts)" >> "$tmp"
  mv -f "$tmp" "$PENDING_FILE"
}

_clear_pending() {
  local agent="$1"
  [[ -f "$PENDING_FILE" ]] || return 0
  local tmp; tmp="$(mktemp "${PENDING_FILE}.XXXXXX")"
  grep -v "^${agent}	" "$PENDING_FILE" 2>/dev/null > "$tmp" || true
  mv -f "$tmp" "$PENDING_FILE"
}

# ---------------------------------------------------------------------------
# 2. model_list registration (constraint 3, P1) — ADD-ONLY, atomic, idempotent
# ---------------------------------------------------------------------------
# register_model_list — register every models.yml entry into config.yaml.
# Returns 0 always; sets _CONFIG_CHANGED=1 (global) if config.yaml changed.
register_model_list() {
  _CONFIG_CHANGED=0
  local m rt sv ef res
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    rt="$(model_runtime "$m")"; sv="$(model_served "$m")"
    ef=""; case "$rt" in meridian|openai|codex-bridge) ef="$(model_effort "$m")" ;; esac
    res="$(lms_register_model "$m" "$sv" "$rt" "$ef")" || { warn "register_model_list: $m failed"; continue; }
    [[ "$res" == "CHANGED" ]] && _CONFIG_CHANGED=1
  done < <(my_q '.models | keys | .[]')
  return 0
}

# preflight_superset_in_config — assert every SUPERSET slug that is one of the 3
# canonical IDs is present in config.yaml before any key mint (constraint 3).
# Legacy slugs (local/local-heavy/local-lfm2) are assumed pre-existing; we only
# hard-require the canonical IDs we just registered.
preflight_superset_in_config() {
  local s missing=()
  for s in local-gemma4 local-qwen3; do
    config_has_slug "$s" || missing+=("$s")
  done
  # Beyond the 3 canonical IDs, every superset member that is a REAL models.yml
  # model (ollama/lmstudio runtime) must also be registered before we mint. The
  # legacy aliases (local/local-heavy/local-lfm2) are pre-existing config entries
  # not declared in models.yml, so they stay WARN-tolerant (never hard-fail here).
  local mem rt
  while IFS= read -r mem; do
    [[ -z "$mem" ]] && continue
    case "$mem" in local|local-heavy|local-lfm2) continue ;; esac
    case "$mem" in local-gemma4|local-qwen3) continue ;; esac  # already checked above
    model_exists "$mem" || continue
    rt="$(model_runtime "$mem")"
    case "$rt" in ollama|lmstudio) : ;; *) continue ;; esac
    config_has_slug "$mem" || missing+=("$mem")
  done < <(superset_members)
  if (( ${#missing[@]} > 0 )); then
    err "pre-flight: model_name(s) absent from config.yaml: ${missing[*]}"
    err "  (register_model_list must run before minting keys — refusing to widen allowlists)"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 3. Scoped-key allowlist widening (constraint 3, P3)
# ---------------------------------------------------------------------------
allowlist_superset_json() {
  # JSON array of the DERIVED superset.
  superset_members | python3 -c 'import sys,json; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))'
}

# key_covers <key> <model> — does GET /v1/models under <key> include <model>?
key_covers() {
  local key="$1" want="$2"
  [[ -n "$key" ]] || return 1
  curl -s --max-time 5 "${LITELLM_BASE_URL:-http://litellm:4000}/v1/models" \
    -H "Authorization: Bearer $key" 2>/dev/null \
    | python3 -c 'import sys,json
w=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if any(m.get("id")==w for m in d.get("data",[])) else 1)' "$want"
}

# remint_key <key_env> <alias> <owner> — POST /key/generate against the SUPERSET
# and set_env the result. NEVER echoes the value. Returns 0 on success.
remint_key() {
  local key_env="$1" alias="$2" owner="$3"
  local master; master="$(get_env LITELLM_MASTER_KEY '')"
  [[ -n "$master" ]] || { err "remint_key: LITELLM_MASTER_KEY missing"; return 1; }
  preflight_superset_in_config || return 1
  local models_json; models_json="$(allowlist_superset_json)"
  local base="${LITELLM_BASE_URL:-http://litellm:4000}"

  # PREFER an in-place /key/update on the EXISTING key: it widens the allowlist
  # without changing the key value (no .env churn) and — crucially — without
  # hitting LiteLLM's UNIQUE-key_alias rule. A blind /key/generate re-using the
  # same alias 400s once a key already exists ("alias already exists"), which is
  # exactly what a superset expansion triggers. Only mint fresh when none is set.
  local existing; existing="$(get_env "$key_env" '')"
  if [[ -n "$existing" ]]; then
    local upd
    upd="$(curl -s --max-time 15 -H "Authorization: Bearer $master" -H 'Content-Type: application/json' \
      -X POST "$base/key/update" -d "{\"key\":\"${existing}\",\"models\":${models_json}}")"
    if printf '%s' "$upd" | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(1 if "error" in d else 0)' 2>/dev/null; then
      ok "$key_env allowlist widened to the superset (in place)"
      return 0
    fi
    warn "$key_env in-place update failed — minting a fresh key"
  fi

  # Fresh mint. Recycle the alias first (unique-alias rule) in case a stale key
  # holds it; ignore errors (alias may not exist / endpoint may lack alias-delete).
  curl -s --max-time 10 -H "Authorization: Bearer $master" -H 'Content-Type: application/json' \
    -X POST "$base/key/delete" -d "{\"key_aliases\":[\"${alias}\"]}" >/dev/null 2>&1 || true
  local newkey
  newkey="$(curl -s --max-time 15 -H "Authorization: Bearer $master" -H 'Content-Type: application/json' \
    -X POST "$base/key/generate" \
    -d "{\"models\":${models_json},\"key_alias\":\"${alias}\",\"metadata\":{\"owner\":\"${owner}\",\"purpose\":\"model-sync\"}}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$newkey" ]] || { err "remint_key: failed to mint $key_env (LiteLLM up + DATABASE_URL set?)"; return 1; }
  set_env "$key_env" "$newkey"          # set_env never logs the value
  ok "$key_env minted against the superset + saved to .env"
  return 0
}

# ensure_key_widened <key_env> <alias> <owner> — widen the scoped key to the
# SUPERSET iff it doesn't already cover both canonical MLX slugs. Idempotent:
# only re-mints when coverage is incomplete. WARN-non-fatal (opt-in services).
ensure_key_widened() {
  local key_env="$1" alias="$2" owner="$3"
  [[ -n "$key_env" && "$key_env" != "null" ]] || return 0   # e.g. deerflow uses master key
  local key; key="$(get_env "$key_env" '')"
  if [[ -n "$key" ]]; then
    # Already widened iff the key covers EVERY superset member that is actually
    # registered in config.yaml. Members not yet in config.yaml are skipped so a
    # freshly `model add`-ed (not-yet-synced) name can't trigger a false re-mint
    # before its model_list entry exists.
    local covered=1 mem
    while IFS= read -r mem; do
      [[ -z "$mem" ]] && continue
      config_has_slug "$mem" || continue   # not registered yet — can't be covered
      if ! key_covers "$key" "$mem"; then covered=0; break; fi
    done < <(superset_members)
    if (( covered )); then return 0; fi     # already widened
  fi
  remint_key "$key_env" "$alias" "$owner" || warn "could not widen $key_env (non-fatal)"
}

# ---------------------------------------------------------------------------
# 4. Per-kind renderers (simple case dispatch — NOT a plugin framework)
# ---------------------------------------------------------------------------
osh_bin() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""; fi
}

hermes_sandbox_ready() {
  local osh; osh="$(osh_bin)"
  [[ -n "$osh" ]] || return 1
  "$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk -v s="$HERMES_SANDBOX" 'NR>1 && $1==s && $NF=="Ready" {ok=1} END{exit !ok}'
}

# render_hermes <agent> <effective_model> — set model.default + providers.litellm.model
# for the profile, via openshell exec. provider/base_url are model-independent
# (set by Phase 04f) and left alone. api_key re-piped via STDIN only if it changed
# (a fresh re-mint). SANDBOX-NOT-READY => record intent + SKIP non-fatally.
render_hermes() {
  local agent="$1" model="$2"
  local profile; profile="$(agent_profile "$agent")"
  local osh; osh="$(osh_bin)"
  if [[ -z "$osh" ]] || ! hermes_sandbox_ready; then
    mkdir -p "$STATE_DIR"
    # Dedupe-replace this agent's line (not a blind >> append) so the file can't
    # grow unbounded across repeated syncs while the sandbox is down. Recovery is
    # automatic: the next `model sync` / `install 04f` re-derives from models.yml
    # and re-renders all profiles once the sandbox is Ready.
    local tmp; tmp="$(mktemp "${PENDING_HERMES}.XXXXXX")"
    [[ -f "$PENDING_HERMES" ]] && { grep -v "^${agent}	" "$PENDING_HERMES" 2>/dev/null > "$tmp" || true; }
    printf '%s\t%s\t%s\n' "$agent" "$profile" "$model" >> "$tmp"
    mv -f "$tmp" "$PENDING_HERMES"
    warn "hermes sandbox '$HERMES_SANDBOX' not Ready — recorded intent in $(basename "$PENDING_HERMES"), skipping $agent (non-fatal)"
    return 0
  fi
  local pflag="--profile $profile"
  [[ "$profile" == "_root_" || -z "$profile" ]] && pflag=""
  "$osh" sandbox exec -n "$HERMES_SANDBOX" --no-tty -- bash -c \
    "hermes $pflag config set model.default $model >/dev/null; hermes $pflag config set providers.litellm.model $model >/dev/null" \
    >/dev/null 2>&1 || warn "render_hermes($agent): config set returned non-zero (non-fatal)"
  ok "hermes profile $profile -> $model"
}

# render_pi <effective_model> — PI_DEFAULT_MODEL in .env (availability-gated) +
# rewrite bin/pi's flag injection. bin/pi rewrite is idempotent (marker-guarded).
render_pi() {
  local model="$1"
  set_env PI_DEFAULT_MODEL "$model"
  ok "pi: PI_DEFAULT_MODEL=$model (in .env)"
  # bin/pi flag-injection is rewritten by the Phase 15 file itself; here we only
  # ensure the env var is set. (The injection logic lives in bin/pi.)
}

# render_deerflow <effective_reasoning_model> — rewrite the two-tier models: block
# in deer-flow/config.yaml between the markers. Platform policy (2026-06-20):
# basic->primary (claude-opus-4.8-sub-xhigh), reasoning-><effective>. LiteLLM
# falls back to local-gemma4 if Meridian is down. Restart deerflow only if the
# block changed.
render_deerflow() {
  local reasoning="$1" basic
  basic="$(primary_model)"
  local df_config="$AI_STACK/deer-flow/config.yaml"
  if [[ ! -f "$df_config" ]]; then
    note "deerflow: config.yaml not present (phase 10 not run) — skipping"
    return 0
  fi
  local before after
  before="$(shasum -a 256 "$df_config" 2>/dev/null | awk '{print $1}')"
  DF_BASIC="$basic" DF_REASON="$reasoning" python3 - "$df_config" <<'PYEOF' || { warn "deerflow render failed (non-fatal)"; return 0; }
import os, re, sys
path = sys.argv[1]
basic = os.environ["DF_BASIC"]
reason = os.environ["DF_REASON"]
src = open(path).read()
# Render the two-tier models: block. We rewrite the `model:` line of the entry
# named `local` (basic tier) -> basic, and `local-heavy` (reasoning tier) -> reason.
# We keep the entry NAMES stable (DeerFlow references them by name) and only
# swap which LiteLLM model_name they target.
def set_model(text, entry_name, model_name):
    # find the `- name: <entry_name>` block and replace its `model:` line.
    # group1 is ANCHORED to the single `- name:` line ([^\n]* not .*?) so it can
    # NOT cross newlines and bind to a sibling entry's model: line (the bug the
    # review caught: under re.DOTALL `.*?` swallowed the whole block and the
    # middle group's `\w[\w-]*:` matched a `model:` line, so `local` rewrote the
    # `local-heavy` entry). The middle group still consumes intervening
    # `key: value` lines up to (not including) this entry's own `model:`.
    pat = re.compile(r'(- name: %s(?![\w-])[^\n]*\n)((?:\s+\w[\w-]*:.*\n)*?)(\s*model:\s*)([^\n]*)' % re.escape(entry_name))
    new, n = pat.subn(lambda m: m.group(1) + m.group(2) + m.group(3) + model_name, text, count=1)
    return new
new = src
new = set_model(new, "local", basic)
new = set_model(new, "local-heavy", reason)
if new != src:
    open(path, "w").write(new)
PYEOF
  after="$(shasum -a 256 "$df_config" 2>/dev/null | awk '{print $1}')"
  if [[ "$before" != "$after" ]]; then
    ok "deerflow: two-tier models rewritten (basic=$basic, reasoning=$reasoning)"
    if [[ "${MODELS_NO_RESTART:-0}" != "1" && "${DRY_RUN:-0}" != "1" ]]; then
      log "restarting deerflow (config changed)..."
      bash "$AI_STACK/vz-ai-stack.sh" start deerflow >/dev/null 2>&1 || warn "deerflow restart returned non-zero (non-fatal)"
    fi
  else
    ok "deerflow: two-tier models already current (basic=$basic, reasoning=$reasoning)"
  fi
}

# render_ace <effective_model> — set_env + ace/.env (atomic, 0600).
render_ace() {
  local model="$1"
  set_env ACE_DEFAULT_MODEL "$model"
  local ace_env="$AI_STACK/ace/.env"
  if [[ -f "$ace_env" ]]; then
    _env_upsert_file "$ace_env" ACE_DEFAULT_MODEL "$model" 0600
    _env_upsert_file "$ace_env" OPENAI_MODEL "$model" 0600
    ok "ace: ACE_DEFAULT_MODEL=$model (.env, allowlist-only binding — see note)"
  else
    note "ace: ace/.env not present (phase 17 not run) — recorded ACE_DEFAULT_MODEL in root .env only"
  fi
}

# render_rlm <effective_model> — set_env + rlm/.env (atomic, umask 077).
render_rlm() {
  local model="$1"
  set_env RLM_MODEL "$model"
  local rlm_env="$AI_STACK/rlm/.env"
  if [[ -f "$rlm_env" ]]; then
    _env_upsert_file "$rlm_env" RLM_MODEL "$model" 0600
    ok "rlm: RLM_MODEL=$model (.env)"
  else
    note "rlm: rlm/.env not present (phase 18 not run) — recorded RLM_MODEL in root .env only"
  fi
}

# _env_upsert_file <file> <KEY> <VAL> <mode> — atomic KEY=VAL upsert into an
# arbitrary .env file (ace/.env, rlm/.env). temp+mv, chmod before content.
_env_upsert_file() {
  local f="$1" k="$2" v="$3" mode="${4:-0600}"
  [[ "$v" == *$'\n'* ]] && { err "_env_upsert_file: newline in value for $k"; return 2; }
  local tmp; tmp="$(mktemp "${f}.XXXXXX")" || return 1
  chmod "$mode" "$tmp"
  awk -v k="$k" -v val="$v" '
    BEGIN{found=0}
    /^[[:space:]]*#/ {print; next}
    { n=index($0,"="); if(n>0){ lk=substr($0,1,n-1); if(lk==k){ if(found==0){print k"="val; found=1} next } } print }
    END{ if(!found) print k"="val }
  ' "$f" > "$tmp" && mv -f "$tmp" "$f"
  chmod "$mode" "$f" 2>/dev/null || true
}

# render_agent <agent> — resolve effective model (availability-gated) + dispatch
# to the per-kind renderer. WARN-non-fatal for opt-in/down services.
render_agent() {
  local agent="$1" kind eff
  kind="$(agent_kind "$agent")"
  eff="$(resolve_effective "$agent")"
  if is_gated "$agent" "$eff"; then
    # resolve_effective (in its subshell) already wrote the pending line; keep it.
    local _decl _drt; _decl="$(agent_assigned "$agent")"
    [[ -z "$_decl" || "$_decl" == "null" ]] && _decl="$(primary_model)"
    _drt="$(model_runtime "$_decl")"
    warn "$agent: assigned '$_decl' ($_drt) not servable — rendering '$eff' (availability-gated)"
  else
    _clear_pending "$agent"
  fi
  case "$kind" in
    hermes-profile) render_hermes "$agent" "$eff" ;;
    pi)             render_pi "$eff" ;;
    deerflow)       render_deerflow "$eff" ;;
    ace)            render_ace "$eff" ;;
    rlm)            render_rlm "$eff" ;;
    *)              warn "render_agent: unknown kind '$kind' for $agent" ;;
  esac
}

# ---------------------------------------------------------------------------
# 5. list / matrix (READ-ONLY)
# ---------------------------------------------------------------------------
# Rendered model for an agent (what's actually wired right now), best-effort.
rendered_model() {
  local agent="$1" kind; kind="$(agent_kind "$agent")"
  case "$kind" in
    pi)   get_env PI_DEFAULT_MODEL '' ;;
    ace)  get_env ACE_DEFAULT_MODEL '' ;;
    rlm)  get_env RLM_MODEL '' ;;
    deerflow)
      local df="$AI_STACK/deer-flow/config.yaml"
      [[ -f "$df" ]] && yq -r '.models[] | select(.name == "local-heavy") | .model' "$df" 2>/dev/null | head -1 ;;
    hermes-profile)
      local osh profile; osh="$(osh_bin)"; profile="$(agent_profile "$agent")"
      if [[ -n "$osh" ]] && hermes_sandbox_ready; then
        # `</dev/null`: openshell exec drains its stdin; without this it would eat
        # the `while read < <(agents)` loop's input in cmd_list and truncate the
        # matrix to the first hermes agent. (Sync's render paths use `for`, so
        # they're unaffected — this guard is for the read-loop callers.)
        "$osh" sandbox exec -n "$HERMES_SANDBOX" --no-tty -- bash -c \
          "grep -E '^[[:space:]]*model:' \"\$HOME/.hermes/profiles/$profile/config.yaml\" 2>/dev/null | head -1 | awk '{print \$2}'" \
          </dev/null 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]'
      fi ;;
  esac
}

cmd_list() {
  local json=0
  [[ "${1:-}" == "--json" ]] && json=1
  export _NO_PENDING=1   # READ-ONLY: never mutate installer/state from `list`.
  validate || exit $?

  local lms_up=0; lms_server_up && lms_up=1
  local litellm_up=0
  curl -sf --max-time 3 "${LITELLM_BASE_URL:-http://litellm:4000}/health/readiness" >/dev/null 2>&1 && litellm_up=1

  if (( json )); then
    # Machine-readable: emit the catalog + per-agent overlay. Never include keys.
    python3 - "$MODELS_YML" "$litellm_up" "$lms_up" <<'PYEOF'
import sys, json, subprocess, os
yml = sys.argv[1]
litellm_up = sys.argv[2] == "1"
import shutil
def yq(expr):
    try:
        return subprocess.run(["yq","-r",expr,yml],capture_output=True,text=True).stdout.strip()
    except Exception:
        return ""
doc = json.loads(subprocess.run(["yq","-o=json",".",yml],capture_output=True,text=True).stdout)
out = {"default": doc.get("default"), "models": doc.get("models",{}),
       "assignments": doc.get("assignments",{}), "litellm_up": litellm_up}
print(json.dumps(out, indent=2))
PYEOF
    return 0
  fi

  hdr "Model catalog (installer/models.yml)"
  local m rt sv big
  printf '  %-30s %-10s %-34s %s\n' MODEL RUNTIME SERVED FLAGS
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    rt="$(model_runtime "$m")"; sv="$(model_served "$m")"; big="$(my_q ".models.\"$m\".big")"
    local flags=""; [[ "$big" == "true" ]] && flags="big"
    [[ "$m" == "$(default_model)" ]] && flags="${flags:+$flags,}DEFAULT"
    printf '  %-30s %-10s %-34s %s\n' "$m" "$rt" "$sv" "$flags"
  done < <(my_q '.models | keys | .[]')

  if (( ! lms_up )); then
    warn "LM Studio (:1234) is down — lmstudio models will availability-gate to $(default_model) (advisory)"
  fi
  if (( ! litellm_up )); then
    warn "LiteLLM (:4000) not responding — SERVED/KEY-OK columns will show 'down' (advisory)"
  fi

  hdr "Agent matrix"
  printf '  %-26s %-26s %-9s %-7s %-8s %-6s %s\n' AGENT ASSIGNED LITELLM SERVED KEY-OK DRIFT EFFECTIVE
  local a assigned kind keyenv eff in_cfg served_ok key_ok drift rendered
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    assigned="$(agent_assigned "$a")"
    kind="$(agent_kind "$a")"
    keyenv="$(agent_keyenv "$a")"
    eff="$(resolve_effective "$a")"

    in_cfg="no"; config_has_slug "$assigned" && in_cfg="yes"
    if (( litellm_up )); then
      served_ok="no"; litellm_serves_slug "$assigned" && served_ok="ok"
      if [[ "$(model_runtime "$assigned")" == "lmstudio" && "$served_ok" != "ok" ]]; then
        served_ok="down"   # advisory, not an error
      fi
    else
      served_ok="down"
    fi

    # KEY-OK: does the scoped key's allowlist cover the EFFECTIVE model?
    key_ok="n/a"
    if [[ -n "$keyenv" && "$keyenv" != "null" ]]; then
      if (( litellm_up )); then
        local kv; kv="$(get_env "$keyenv" '')"
        if [[ -n "$kv" ]] && key_covers "$kv" "$eff"; then key_ok="yes"; else key_ok="no"; fi
      else
        key_ok="down"
      fi
    fi

    # DRIFT: rendered == effective (declared, gated)?
    rendered="$(rendered_model "$a" 2>/dev/null || echo '')"
    if [[ -z "$rendered" ]]; then drift="?"
    elif [[ "$rendered" == "$eff" ]]; then drift="ok"
    else drift="DRIFT"; fi

    # ACE caveat (constraint: list must say allowlist-only for ACE).
    local effdisp="$eff"
    [[ "$kind" == "ace" ]] && effdisp="$eff (allowlist-only)"

    printf '  %-26s %-26s %-9s %-7s %-8s %-6s %s\n' "$a" "$assigned" "$in_cfg" "$served_ok" "$key_ok" "$drift" "$effdisp"
  done < <(agents)

  printf '\n  default: %s\n' "$(default_model)"
  if [[ -f "$PENDING_FILE" ]] && [[ -s "$PENDING_FILE" ]]; then
    warn "pending (availability-gated) — see $PENDING_FILE:"
    while IFS=$'\t' read -r pa pd pf ps pt; do
      [[ -z "$pa" ]] && continue
      printf '    %-26s wants %-26s -> rendered %s\n' "$pa" "$pd" "$pf"
    done < "$PENDING_FILE"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 6. assign
# ---------------------------------------------------------------------------
cmd_assign() {
  local agent="" model="" dry=0 nosync=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      --no-sync) nosync=1 ;;
      -*) err "assign: unknown flag '$a'"; exit 2 ;;
      *) if [[ -z "$agent" ]]; then agent="$a"; elif [[ -z "$model" ]]; then model="$a"; fi ;;
    esac
  done
  validate || exit $?
  if [[ -z "$agent" || -z "$model" ]]; then
    err "usage: vz-ai-stack.sh model assign <agent|all> <model> [--dry-run] [--no-sync]"
    exit 2
  fi
  if ! model_exists "$model"; then
    err "unknown model '$model'. Valid models:"
    my_q '.models | keys | .[]' | sed 's/^/    /' >&2
    exit 2
  fi
  # `assign all <model>` — blanket-assign EVERY agent (all .kinds) to one model,
  # then sync once. Overwrites existing per-agent assignments BY DESIGN, so we:
  #   - print a before->after table (you see exactly what's being replaced),
  #   - back up models.yml first (rollback: cp models.yml.bak models.yml),
  #   - apply ALL keys in ONE atomic `yq -i` (no half-written file on interrupt;
  #     in-place key sets preserve the YAML comments + structure).
  if [[ "$agent" == "all" ]]; then
    local _agents _a _expr="" n=0
    _agents="$(my_q '.kinds | keys | .[]')"
    note "blanket assign — every agent -> $model:"
    while IFS= read -r _a; do
      [[ -z "$_a" ]] && continue
      printf '    %-26s %s -> %s\n' "$_a" "$(agent_assigned "$_a")" "$model" >&2
      [[ -n "$_expr" ]] && _expr+=" | "
      _expr+=".assignments[\"$_a\"] = strenv(MODEL)"
      n=$((n+1))
    done <<<"$_agents"
    if (( dry )); then note "[dry-run] no write (would update $n agents)"; exit 0; fi
    cp -p "$MODELS_YML" "$MODELS_YML.bak" 2>/dev/null || true
    if ! MODEL="$model" yq -i "$_expr" "$MODELS_YML"; then
      err "blanket assign failed — models.yml unchanged (restore: cp $MODELS_YML.bak $MODELS_YML)"; exit 1
    fi
    ok "assigned all $n agents -> $model  (prior models.yml backed up to $(basename "$MODELS_YML").bak)"
    if (( nosync )); then
      note "--no-sync: not reconciling. Run 'vz-ai-stack.sh model sync' to apply."
      exit 0
    fi
    cmd_sync   # no agent arg = reconcile every agent
    exit 0
  fi
  if ! agent_exists "$agent"; then
    err "unknown agent '$agent'. Valid agents (or 'all'):"
    my_q '.kinds | keys | .[]' | sed 's/^/    /' >&2
    exit 2
  fi
  # (model existence already validated above, before the `all` branch.)
  local before; before="$(agent_assigned "$agent")"
  if (( dry )); then
    note "[dry-run] would set assignments.$agent: $before -> $model (no write)"
    exit 0
  fi
  AG="$agent" MODEL="$model" yq -i '.assignments[strenv(AG)] = strenv(MODEL)' "$MODELS_YML" \
    || { err "yq -i set assignment failed"; exit 1; }
  ok "assignments.$agent: $before -> $model"
  if (( nosync )); then
    note "--no-sync: not reconciling. Run 'vz-ai-stack.sh model sync $agent' to apply."
    exit 0
  fi
  cmd_sync "$agent"
}

# ---------------------------------------------------------------------------
# 6b. discover — READ-ONLY LM Studio library catalog (never loads a model)
# ---------------------------------------------------------------------------
# cmd_discover — list the on-disk LM Studio library (LLMs + embeddings), marking
# which LLMs are already DECLARED in models.yml (exact served-id match). Advisory:
# never fatal, never auto-starts LM Studio, writes nothing, takes no lock, and
# NEVER echoes a key.
cmd_discover() {
  local lib; lib="$(lms_library_json || true)"
  if [[ -z "$lib" ]]; then
    note "LM Studio CLI not found / library empty. Open LM Studio (or run: lms server start) then re-run: vz-ai-stack.sh model discover"
    return 0
  fi

  # Build a served-id -> models.yml-name map for declared lmstudio entries.
  local declared_json m rt sv
  declared_json="$( { local first=1; printf '{'
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      rt="$(model_runtime "$m")"
      [[ "$rt" == "lmstudio" ]] || continue
      sv="$(model_served "$m")"
      [[ -n "$sv" && "$sv" != "null" ]] || continue
      (( first )) || printf ','
      first=0
      SV="$sv" NM="$m" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps(os.environ["SV"])+":"+json.dumps(os.environ["NM"]))'
    done < <(my_q '.models | keys | .[]')
    printf '}'; } )"
  [[ -n "$declared_json" ]] || declared_json='{}'

  local up=0; lms_server_up && up=1

  printf '%s' "$lib" | DECLARED_MAP="$declared_json" python3 -c '
import sys, os, json
try:
    d = json.loads(sys.stdin.read())
except Exception:
    print("  (could not parse lms ls --json)"); sys.exit(0)
declared = {}
try:
    declared = json.loads(os.environ.get("DECLARED_MAP","{}"))
except Exception:
    declared = {}
entries = d if isinstance(d, list) else []
def human(sz):
    if not isinstance(sz, int): return "size?"
    return "%.2fGB" % (sz/1e9)
llms = [m for m in entries if isinstance(m, dict) and m.get("type")=="llm"]
embs = [m for m in entries if isinstance(m, dict) and m.get("type")=="embedding"]
print("LM Studio library — LLMs (chat):")
print("  %-44s %-10s %-9s %s" % ("MODELKEY","PARAMS","SIZE","DECLARED"))
for m in sorted(llms, key=lambda x: x.get("modelKey","")):
    mk = m.get("modelKey","")
    params = m.get("paramsString") or "-"
    sz = human(m.get("sizeBytes"))
    dec = declared.get(mk, "-")
    print("  %-44s %-10s %-9s %s" % (mk, params, sz, dec))
print("")
print("LM Studio library — EMBEDDINGS:")
print("  %-44s %-10s %-9s %s" % ("MODELKEY","PARAMS","SIZE","DECLARED"))
for m in sorted(embs, key=lambda x: x.get("modelKey","")):
    mk = m.get("modelKey","")
    params = m.get("paramsString") or "-"
    sz = human(m.get("sizeBytes"))
    print("  %-44s %-10s %-9s %s" % (mk, params, sz, "-"))
if embs:
    print("  note: `model add` declares chat LLMs only (embeddings shown for reference).")
' 2>/dev/null || { note "could not render LM Studio library"; return 0; }

  if (( up )); then
    note "server up: listed slugs are loadable now."
  else
    note "server down: reads the on-disk library; nothing is loaded."
  fi
  note "DECLARED matches by exact served-id string only (near-duplicates like qwen3.6-27b-mlx vs qwen/qwen3.6-27b are distinct)."
  return 0
}

# ---------------------------------------------------------------------------
# 6c. add — declare an LM Studio library slug as a models.yml model (no load)
# ---------------------------------------------------------------------------
# cmd_add <lms-slug> [as <name>] [--dry-run] [--no-sync] — declare an existing
# LM Studio library LLM into models.yml + (unless --no-sync) register it via
# cmd_sync. NEVER loads a model. Does NOT take its own lock (cmd_sync takes it).
cmd_add() {
  local slug="" name="" dry=0 nosync=0 expect_name=0 a
  for a in "$@"; do
    if (( expect_name )); then name="$a"; expect_name=0; continue; fi
    case "$a" in
      as)        expect_name=1 ;;
      --dry-run) dry=1 ;;
      --no-sync) nosync=1 ;;
      -*) err "add: unknown flag '$a'"; exit 2 ;;
      *) if [[ -z "$slug" ]]; then slug="$a"; elif [[ -z "$name" ]]; then name="$a"; fi ;;
    esac
  done

  validate || exit $?

  if [[ -z "$slug" ]]; then
    err "usage: vz-ai-stack.sh model add <lms-slug> [as <name>] [--dry-run] [--no-sync]"
    exit 2
  fi

  # Library + slug check FIRST (no auto-start, no blind add).
  local lib; lib="$(lms_library_json || true)"
  if [[ -z "$lib" ]]; then
    err "LM Studio CLI not found / library empty. Open LM Studio (or run: lms server start) then re-run: vz-ai-stack.sh model add"
    exit 2
  fi
  if ! lms_lib_has_slug "$slug"; then
    # Disambiguate: is the slug present but an embedding?
    if printf '%s' "$lib" | SLUG="$slug" python3 -c 'import sys,os,json
want=os.environ.get("SLUG","")
try: d=json.loads(sys.stdin.read())
except Exception: sys.exit(1)
for m in (d if isinstance(d,list) else []):
    if isinstance(m,dict) and m.get("modelKey")==want and m.get("type")=="embedding":
        sys.exit(0)
sys.exit(1)' 2>/dev/null; then
      err "'$slug' is an embedding model; model add declares chat LLMs only"
      exit 2
    fi
    err "unknown library slug '$slug'; available LLM modelKeys:"
    printf '%s' "$lib" | python3 -c 'import sys,json
try: d=json.loads(sys.stdin.read())
except Exception: sys.exit(0)
for m in (d if isinstance(d,list) else []):
    if isinstance(m,dict) and m.get("type")=="llm":
        print("    "+str(m.get("modelKey","")))' >&2 2>/dev/null || true
    exit 2
  fi

  # Visual confirmation of the exact matched entry (vs near-duplicates).
  local matched_info
  matched_info="$(printf '%s' "$lib" | SLUG="$slug" python3 -c 'import sys,os,json
want=os.environ.get("SLUG","")
try: d=json.loads(sys.stdin.read())
except Exception: sys.exit(0)
def human(sz):
    return ("%.2fGB"%(sz/1e9)) if isinstance(sz,int) else "size?"
for m in (d if isinstance(d,list) else []):
    if isinstance(m,dict) and m.get("modelKey")==want and m.get("type")=="llm":
        print("%s  %s  %s" % (m.get("modelKey",""), human(m.get("sizeBytes")), m.get("displayName") or ""))
        break' 2>/dev/null || echo "$slug")"
  note "matched library model: ${matched_info}"

  # REVERSE idempotency: is this served id already declared by some entry?
  local existing_name
  existing_name="$(SV="$slug" yq -r '.models | to_entries | map(select(.value.runtime == "lmstudio" and .value.served == strenv(SV))) | .[0].key // ""' "$MODELS_YML" 2>/dev/null || echo "")"
  if [[ -n "$existing_name" && "$existing_name" != "null" ]]; then
    if [[ -z "$name" ]]; then
      ok "served id '$slug' already declared as '$existing_name'; nothing to do"
      exit 0
    else
      err "served id '$slug' already declared as '$existing_name'; refusing a second alias"
      exit 2
    fi
  fi

  # Derive the name if not given via `as`.
  if [[ -z "$name" ]]; then
    local base
    base="$(printf '%s' "$slug" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9.]+/-/g; s/-+/-/g; s/^[.-]+//; s/[.-]+$//')"
    name="local-${base}"
  fi

  # Validate: local-<alnum>…<alnum>, only [a-z0-9._-] between (ONE strict pattern
  # — the old dual-alternative made the strict branch dead code and let through
  # 'local-.bad' / 'local-'). Reserved legacy aliases are off-limits.
  if ! [[ "$name" =~ ^local-[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ ]]; then
    err "name '$name' invalid; use a clean \`as local-<name>\` (e.g. local-mymodel)"
    exit 2
  fi
  case "$name" in
    local|local-heavy|local-lfm2)
      err "name '$name' is a reserved alias; choose a different \`as local-<name>\`"; exit 2 ;;
  esac

  # FORWARD idempotency: name already used?
  if model_exists "$name"; then
    local ert esv
    ert="$(model_runtime "$name")"; esv="$(model_served "$name")"
    if [[ "$ert" == "lmstudio" && "$esv" == "$slug" ]]; then
      ok "models.$name already declared (served=$slug); nothing to do"
      exit 0
    fi
    err "name '$name' already used by a different served id ('$esv'); choose \`as <other>\`"
    exit 2
  fi

  # Infer big from the on-disk size (RAM-cautious default).
  local bytes thresh_gb thresh big=false
  bytes="$(lms_lib_size_bytes "$slug")"
  thresh_gb="${MODEL_BIG_GB:-8}"
  [[ "$thresh_gb" =~ ^[0-9]+$ ]] || thresh_gb=8   # guard a non-numeric MODEL_BIG_GB (set -u/errexit safe)
  thresh=$(( thresh_gb * 1000000000 ))
  if [[ -n "$bytes" ]]; then
    if (( bytes >= thresh )); then big=true; fi
  else
    big=true
    note "size unknown for '$slug' — defaulting big=true (RAM-cautious)"
  fi

  # DRY-RUN: print the planned entry; write nothing.
  if (( dry )); then
    note "[dry-run] planned models.$name:"
    printf '    runtime: lmstudio\n'
    printf '    served:  %s\n' "$slug"
    printf '    big:     %s\n' "$big"
    printf '    ttl:     1800\n'
    note "would run sync (registers into config.yaml + widens scoped keys; loads nothing)"
    exit 0
  fi

  # WRITE — single atomic yq (1800 literal so it lands as !!int).
  NM="$name" SV="$slug" BIG="$big" yq -i '.models[strenv(NM)] = {"runtime":"lmstudio","served":strenv(SV),"big":(strenv(BIG)=="true"),"ttl":1800,"note":"added via model add"}' "$MODELS_YML" \
    || { err "yq -i add model failed"; exit 1; }
  ok "declared models.$name (served=$slug, big=$big, ttl=1800)"

  # Served-id caveat for non-MLX / namespaced slugs.
  local fmt
  fmt="$(printf '%s' "$lib" | SLUG="$slug" python3 -c 'import sys,os,json
want=os.environ.get("SLUG","")
try: d=json.loads(sys.stdin.read())
except Exception: sys.exit(0)
for m in (d if isinstance(d,list) else []):
    if isinstance(m,dict) and m.get("modelKey")==want and m.get("type")=="llm":
        print(m.get("format") or ""); break' 2>/dev/null || echo "")"
  if [[ "$slug" == */* || "$slug" == *@* || "$fmt" != "mlx" ]]; then
    note "verify served: matches LM Studio /v1/models once loaded; if a request 404s, edit .served in installer/models.yml"
  fi

  # Sync unless told not to.
  if (( nosync )); then
    note "declared only; run vz-ai-stack.sh model sync to register it into LiteLLM + widen scoped keys"
  else
    cmd_sync
  fi
}

# ---------------------------------------------------------------------------
# 7. sync — the crash-safe 6-phase reconcile (constraint 4)
# ---------------------------------------------------------------------------
cmd_sync() {
  local only="" dry=0 norestart=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run)    dry=1 ;;
      --no-restart) norestart=1 ;;
      -*) err "sync: unknown flag '$a'"; exit 2 ;;
      *) only="$a" ;;
    esac
  done
  export DRY_RUN="$dry"
  export MODELS_NO_RESTART="$norestart"

  # P0 — pre-flight validation, fail-closed.
  seed_if_missing
  validate || exit $?
  if [[ -n "$only" ]] && ! agent_exists "$only"; then
    err "sync: unknown agent '$only'"; exit 2
  fi

  # Serialize with cmd_install (constraint 5). lock_acquire installs an EXIT trap
  # that releases it. dry-run does not need the lock (read-only).
  if (( ! dry )); then lock_acquire; fi

  if (( dry )); then
    _dry_run "$only"
    exit 0
  fi

  hdr "model sync${only:+ ($only)}"

  # P1 — register the model_list (ADD-ONLY, atomic).
  log "P1: registering model_list from models.yml..."
  register_model_list

  # P2 — restart LiteLLM ONCE iff config.yaml changed (constraint 6).
  if [[ "${_CONFIG_CHANGED:-0}" == "1" && "$norestart" != "1" ]]; then
    log "P2: config.yaml changed -> restarting LiteLLM once..."
    docker restart litellm >/dev/null 2>&1 || warn "docker restart litellm failed (restart manually)"
    litellm_wait_ready 60 || warn "LiteLLM did not report ready within 60s"
  else
    note "P2: config.yaml unchanged (or --no-restart) -> no LiteLLM restart"
  fi

  # P3 — widen scoped-key allowlists to the SUPERSET (only those with key_env).
  # Pre-flight guarantees the canonical IDs are in config.yaml first (constraint 3).
  log "P3: widening scoped-key allowlists to the superset..."
  if ! preflight_superset_in_config; then
    err "aborting before key widening (canonical IDs not registered) — agents left untouched"
    exit 1
  fi
  # One mint per distinct key_env (HERMES key is shared across 7 profiles).
  local seen=" "
  local ag keyenv alias owner
  for ag in $({ [[ -n "$only" ]] && echo "$only" || agents; }); do
    keyenv="$(agent_keyenv "$ag")"
    [[ -z "$keyenv" || "$keyenv" == "null" ]] && continue
    [[ "$seen" == *" $keyenv "* ]] && continue
    seen+="$keyenv "
    case "$keyenv" in
      HERMES_LITELLM_KEY) alias="hermes-fleet"; owner="hermes" ;;
      PI_LITELLM_KEY)     alias="pi-coding-agent"; owner="pi" ;;
      ACE_LITELLM_KEY)    alias="ace-context-engineering"; owner="ace" ;;
      RLM_LITELLM_KEY)    alias="rlm-recursive"; owner="rlm" ;;
      *)                  alias="$keyenv"; owner="model-sync" ;;
    esac
    ensure_key_widened "$keyenv" "$alias" "$owner"
  done

  # P4 — per-agent render (availability-gated). Per-agent failures non-fatal.
  log "P4: rendering agents (availability-gated)..."
  for ag in $({ [[ -n "$only" ]] && echo "$only" || agents; }); do
    render_agent "$ag" || warn "render $ag returned non-zero (non-fatal)"
  done

  # P5 — verify (surface real problems; advisory, never fatal).
  log "P5: verifying..."
  _verify "$only"
  ok "model sync complete${only:+ ($only)}"
  if [[ -f "$PENDING_FILE" ]] && [[ -s "$PENDING_FILE" ]]; then
    warn "some agents are availability-gated to $(default_model) (LM Studio down or slug not served)."
    note "Start LM Studio + load the model, then re-run 'vz-ai-stack.sh model sync' to promote them."
  fi
  return 0
}

# _verify <only> — surface (never hide) post-sync problems: drift + key-coverage
# gaps that would 403 at runtime. Replaces the old `cmd_list >/dev/null 2>&1`
# which could never report anything. Advisory: WARNs, never fails the sync.
_verify() {
  local only="$1" ag eff rendered keyenv kv problems=0
  export _NO_PENDING=1   # read-only: don't re-record pending during verify
  for ag in $({ [[ -n "$only" ]] && echo "$only" || agents; }); do
    eff="$(resolve_effective "$ag")"
    rendered="$(rendered_model "$ag" 2>/dev/null || echo '')"
    if [[ -n "$rendered" && "$rendered" != "$eff" ]]; then
      warn "verify: $ag rendered '$rendered' != expected '$eff' — re-run 'vz-ai-stack.sh model sync $ag'"
      problems=$((problems+1))
    fi
    keyenv="$(agent_keyenv "$ag")"
    if [[ -n "$keyenv" && "$keyenv" != "null" ]] && litellm_reachable; then
      kv="$(get_env "$keyenv" '')"
      if [[ -n "$kv" ]] && ! key_covers "$kv" "$eff"; then
        warn "verify: $ag — key $keyenv does NOT cover '$eff' (would 403 at runtime); re-run sync to widen"
        problems=$((problems+1))
      fi
    fi
  done
  unset _NO_PENDING
  (( problems == 0 )) && ok "verify: all agents consistent + key-covered" || warn "verify: $problems issue(s) above"
}

# _dry_run — print the plan + a unified diff of config.yaml, write nothing.
_dry_run() {
  local only="$1"
  export _NO_PENDING=1   # dry-run must not mutate installer/state.
  hdr "model sync --dry-run${only:+ ($only)} (NO writes)"
  local lms_up=0; lms_server_up && lms_up=1
  (( lms_up )) || warn "LM Studio (:1234) down -> lmstudio agents will gate to $(default_model)"

  note "P1 model_list registration plan (diff against $CONFIG):"
  local tmp; tmp="$(mktemp -d)"
  cp "$CONFIG" "$tmp/before.yaml"
  cp "$CONFIG" "$tmp/after.yaml"
  local m rt sv ef
  ( LMS_CONFIG="$tmp/after.yaml"
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      rt="$(model_runtime "$m")"; sv="$(model_served "$m")"
      ef=""; case "$rt" in meridian|openai|codex-bridge) ef="$(model_effort "$m")" ;; esac
      lms_register_model "$m" "$sv" "$rt" "$ef" >/dev/null 2>&1 || true
    done < <(my_q '.models | keys | .[]')
  )
  if diff -u "$tmp/before.yaml" "$tmp/after.yaml" >"$tmp/diff.txt" 2>/dev/null; then
    note "  (config.yaml already current — no model_list change)"
  else
    sed 's/^/    /' "$tmp/diff.txt"
  fi
  rm -rf "$tmp"

  note "P3 allowlist widening plan: scoped keys -> [$(superset_members | paste -sd' ' - 2>/dev/null || true)]"
  note "P4 per-agent render plan:"
  printf '    %-26s %-26s %s\n' AGENT ASSIGNED 'EFFECTIVE (gated)'
  local ag eff
  for ag in $({ [[ -n "$only" ]] && echo "$only" || agents; }); do
    eff="$(resolve_effective "$ag")"
    local tag=""; is_gated "$ag" "$eff" && tag="  (gated: assigned runtime down — rendering the fallback)"
    printf '    %-26s %-26s %s%s\n' "$ag" "$(agent_assigned "$ag")" "$eff" "$tag"
  done
  ok "dry-run complete — nothing written"
}

# cmd_superset [--json] — the CANONICAL scoped-key allowlist superset (the single
# source of truth). Phases/bridge that mint keys SHOULD read this instead of
# re-hardcoding the list; doctor check 40 turns RED if a scoped key drifts below it.
cmd_superset() {
  if [[ "${1:-}" == "--json" ]]; then allowlist_superset_json; else superset_members; fi
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
main() {
  local sub="${1:-list}"
  shift || true
  case "$sub" in
    list)     cmd_list "$@" ;;
    assign)   cmd_assign "$@" ;;
    discover) cmd_discover "$@" ;;
    add)      cmd_add "$@" ;;
    sync)     cmd_sync "$@" ;;
    superset) cmd_superset "$@" ;;
    -h|--help|help)
      cat <<'EOF'
vz-ai-stack.sh model — declarative model<->agent binding (installer/models.yml)
  model list [--json]              READ-ONLY catalog + live agent matrix
  model assign <agent> <model> [--dry-run] [--no-sync]    re-point one agent
  model assign all <model> [--dry-run] [--no-sync]        re-point EVERY agent (blanket)
  model discover                   READ-ONLY LM Studio library (LLMs + embeddings); loads nothing
  model add <lms-slug> [as <name>] [--dry-run] [--no-sync]   declare a library LLM (no load)
  model sync [<agent>] [--dry-run] [--no-restart]
  model superset [--json]          print the canonical scoped-key allowlist
EOF
      ;;
    *) err "model: unknown subcommand '$sub' (want list|assign|discover|add|sync|superset)"; exit 2 ;;
  esac
}

main "$@"
