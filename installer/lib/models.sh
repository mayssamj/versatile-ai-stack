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
#      renders the agent to the Ollama default (local = nemotron-3-nano:4b) + records a pending
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

# Path to the canonical sources. Both are env-overridable so a caller (e.g. the
# models-serve console's stage step) can point the CLI at an ISOLATED sandbox copy
# of {models.yml, config.yaml} and run a real `model <op> --no-sync` to produce a
# true both-file diff WITHOUT touching the live files. Normal CLI use leaves them
# unset, so the canonical repo paths are used.
MODELS_YML="${MODELS_YML:-$AI_STACK/installer/models.yml}"
CONFIG="${CONFIG:-$AI_STACK/litellm/config.yaml}"
PENDING_FILE="$STATE_DIR/models-pending.txt"
PENDING_HERMES="$STATE_DIR/models-pending-hermes.txt"
HERMES_SANDBOX="hermes-fleet-v1"
LITELLM_SANDBOX_URL="http://host.docker.internal:4000/v1"

# The scoped-key allowlist is ALWAYS the DERIVED superset (sorted-unique), so
# `assign`/`add` never need a re-mint (constraint 3). It is the union of the
# legacy names {local local-heavy} and EVERY model declared in models.yml (so a
# `model add`-ed slug is automatically covered). If models.yml is absent/unparseable
# we fall back to this legacy list. nemotron-3-nano:4b is the only local chat model,
# so `local`/`local-heavy`/`local-nemotron3-nano-4b` all resolve to it.
LEGACY_SUPERSET=(local local-heavy local-nemotron3-nano-4b)

# superset_members — print the sorted-unique union of the legacy names and every
# models.yml model key, one per line. Errexit/pipefail-safe.
superset_members() {
  local names
  names="$(my_q '.models | keys | .[]' 2>/dev/null || echo '')"
  if [[ -z "$names" ]]; then
    printf '%s\n' "${LEGACY_SUPERSET[@]}" | LC_ALL=C sort -u
    return 0
  fi
  { printf '%s\n' local local-heavy; printf '%s\n' "$names"; } \
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
  local:
    runtime: ollama
    served: nemotron-3-nano:4b
    big: false
    note: "Only local chat model (nemotron-3-nano:4b) — default for any unassigned agent."
default: local
assignments:
  hermes_cos:               local
  hermes_software_engineer: local
  hermes_researcher:        local
  hermes_creator:           local
  hermes_reviewer:          local
  hermes_data_analyst:      local
  hermes_ops:               local
  pi:                       local
  deerflow:                 local
  ace:                      local
  rlm:                      local
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

    # F09: validate model_name against a CONSERVATIVE charset BEFORE it reaches
    # yq strenv or any shell interpolation. Allowed: a-z0-9 + - . _ / @ (covers
    # all real names in models.yml: 'local', 'nvidia/nemotron-3-nano-4b',
    # 'ordis/jina-embeddings-v2-base-code', 'qwen3.6-27b-mtplx-optimized-speed',
    # 'claude-opus-4-8', 'fugu-ultra', 'sakana-fugu-ultra', etc.). Colons (:)
    # appear in ollama tags (e.g. 'nemotron-3-nano:4b') which live in `served`, not
    # the model NAME key — so the NAME charset stays colon-free. The charset was
    # verified against every .models key in installer/models.yml; widen only if a
    # real new name fails (note the failure so the charset rationale stays honest).
    if [[ ! "$m" =~ ^[a-zA-Z0-9_./@-]+$ ]]; then
      err "models.yml: model name '$m' contains characters outside the safe charset [a-zA-Z0-9_./@-] — rename it to avoid injection risk"
      return 2
    fi

    # Validate `served` similarly (the wire id sent to yq + the LiteLLM slug).
    # Served ids may include colons for ollama tags (e.g. 'nemotron-3-nano:4b').
    if [[ -n "$sv" && "$sv" != "null" && ! "$sv" =~ ^[a-zA-Z0-9_./:-]+$ ]]; then
      err "models.yml: model '$m' served id '$sv' contains characters outside the safe charset [a-zA-Z0-9_./:-]"
      return 2
    fi

    # Validate openai-compat fields (api_base / key_env) used directly in yq strenv.
    if [[ "$rt" == "openai-compat" ]]; then
      local _ocab _ocke
      _ocab="$(my_q ".models.\"$m\".api_base")"
      _ocke="$(my_q ".models.\"$m\".key_env")"
      # api_base: must be a valid http(s) URL with safe chars (no shell-injection risk).
      # Store the regex in a variable — bash's [[ =~ ]] parser can choke on & and #
      # inside a bare character class literal (bash bug / parser edge case); a variable
      # RHS is treated as an unquoted pattern and parsed correctly.
      local _url_re='^https?://[a-zA-Z0-9_./:@%?=&#-]+$'
      if [[ -n "$_ocab" && "$_ocab" != "null" ]] \
         && [[ ! "$_ocab" =~ $_url_re ]]; then
        err "models.yml: openai-compat model '$m' api_base '$_ocab' contains unsafe characters"
        return 2
      fi
      # key_env: must be a legal shell env-var name (no injection via strenv).
      if [[ -n "$_ocke" && "$_ocke" != "null" ]] \
         && [[ ! "$_ocke" =~ ^[A-Z_][A-Z0-9_]*$ ]]; then
        err "models.yml: openai-compat model '$m' key_env '$_ocke' is not a valid env-var name ([A-Z_][A-Z0-9_]*)"
        return 2
      fi
    fi

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
      openai-compat)
        # Generic OpenAI-compatible cloud route — api_base + key_env are REQUIRED
        # (the endpoint isn't hardcoded like the other runtimes); no effort knob.
        local ocab ocke
        ocab="$(my_q ".models.\"$m\".api_base")"
        ocke="$(my_q ".models.\"$m\".key_env")"
        [[ -n "$ocab" && "$ocab" != "null" ]] || { err "models.yml: openai-compat model '$m' missing .api_base"; return 2; }
        [[ -n "$ocke" && "$ocke" != "null" ]] || { err "models.yml: openai-compat model '$m' missing .key_env"; return 2; }
        [[ "$ocab" =~ ^https?:// ]] || { err "models.yml: openai-compat model '$m' api_base must be an http(s):// URL (got '$ocab')"; return 2; }
        local ocrp octp
        ocrp="$(my_q ".models.\"$m\".rpm")"; octp="$(my_q ".models.\"$m\".tpm")"
        [[ "$ocrp" == "null" || "$ocrp" =~ ^[0-9]+$ ]] || { err "models.yml: openai-compat model '$m' rpm must be a positive integer (got '$ocrp')"; return 2; }
        [[ "$octp" == "null" || "$octp" =~ ^[0-9]+$ ]] || { err "models.yml: openai-compat model '$m' tpm must be a positive integer (got '$octp')"; return 2; } ;;
      *) err "models.yml: model '$m' has invalid runtime '$rt' (want ollama|lmstudio|meridian|openai|codex-bridge|openai-compat)"; return 2 ;;
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

  # Parked agents (optional .parked map) must reference a known kind — a typo'd
  # entry would silently never take effect.
  local pk
  while IFS= read -r pk; do
    [[ -z "$pk" ]] && continue
    if ! agent_exists "$pk"; then err "models.yml: parked '$pk' has no matching kinds: entry"; return 2; fi
  done < <(my_q '.parked // {} | keys | .[]')

  # config.yaml invariant: NO duplicate model_name. With openai-compat a declared
  # model is rendered into config.yaml by register_model_list (single-owner); a
  # left-behind hand-authored entry for the same name would silently double-own it.
  # yq-authoritative — NOT grep, which counts commented-out '#- model_name:' lines
  # (the false-positive the last §24 council hit). Skipped if config.yaml is absent.
  if [[ -n "${CONFIG:-}" && -f "$CONFIG" ]]; then
    local cdups
    cdups="$(yq -r '.model_list[].model_name' "$CONFIG" 2>/dev/null | LC_ALL=C sort | uniq -d || true)"
    if [[ -n "$cdups" ]]; then
      err "config.yaml has duplicate model_name(s): $(echo "$cdups" | tr '\n' ' ')"
      err "  remove the hand-added copy — models.yml is the source of truth for declared models."
      return 2
    fi
  fi

  return 0
}

agents() { my_q '.assignments | keys | .[]'; }
agent_assigned() { my_q ".assignments.\"$1\""; }
agent_kind()     { my_q ".kinds.\"$1\".kind"; }
agent_profile()  { my_q ".kinds.\"$1\".profile"; }
agent_keyenv()   { my_q ".kinds.\"$1\".key_env"; }
# agent_parked <agent> — true if the agent is PARKED (disabled). Parked agents keep
# their .assignments entry (so unpark restores it) but render to the always-on
# `default` sentinel. State lives in a top-level `.parked` map (a scalar assignment
# can't hold a flag), kept reversible: park sets it, unpark/assign delete it.
agent_parked()   { [[ "$(my_q ".parked.\"$1\"")" == "true" ]]; }
model_runtime()  { my_q ".models.\"$1\".runtime"; }
model_served()   { my_q ".models.\"$1\".served"; }
# openai-compat route data (endpoint + the .env key that holds its secret). Empty
# string when absent (yq prints "null") so callers can test [[ -n ]] cleanly.
model_api_base() { local v; v="$(my_q ".models.\"$1\".api_base")"; [[ "$v" == "null" ]] && v=""; echo "$v"; }
model_key_env()  { local v; v="$(my_q ".models.\"$1\".key_env")";  [[ "$v" == "null" ]] && v=""; echo "$v"; }
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

# meridian_up — is the Claude-subscription host daemon answering? Delegates to
# _probe_meridian_up (common.sh) which is PROCESS-SCOPED memoized + retried (5s
# first attempt, 2 retries at 3s). All surfaces (models.sh + check40) call the
# same helper so the cold-start race is eliminated within a `model sync` run.
meridian_up() {
  _probe_meridian_up
}

# codex_bridge_up — is the ChatGPT-subscription bridge daemon answering? Delegates
# to _probe_codex_bridge_up (common.sh) — same memoize+retry discipline as
# meridian_up. Mirrors the meridian availability-gate pattern.
codex_bridge_up() {
  _probe_codex_bridge_up
}

# litellm_serves_slug <model_name> — does the master-key /v1/models list it?
litellm_serves_slug() {
  local want="$1" key
  key="$(get_env LITELLM_MASTER_KEY '')"
  [[ -n "$key" ]] || return 1
  litellm_master_curl -s --max-time 5 "${LITELLM_BASE_URL:-http://litellm:4000}/v1/models" 2>/dev/null \
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
  # PARKED (disabled) agents render the always-on sentinel ON PURPOSE — short-circuit
  # before any availability gate so it is NOT recorded as pending (it's intentional,
  # not a fallback). rendered==effective==default => no drift in list/verify/doctor.
  if agent_parked "$agent"; then _GATED=0; echo "$default"; return 0; fi
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
    openai-compat)
      # Generic metered cloud route (e.g. Sakana Fugu): render only when its key_env
      # is present in .env; else gate to the default so a keyless box never hard-fails
      # (invariant 1/2). When keyed, LiteLLM's per-route fallback covers a transient
      # upstream outage. We probe the key, not the vendor (no network hop here).
      local ockey; ockey="$(model_key_env "$declared")"
      if [[ -n "$ockey" && -n "$(get_env "$ockey" '')" ]] && config_has_slug "$declared"; then
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
  agent_parked "$1" && return 1   # parked renders the sentinel ON PURPOSE — not a gate
  # Mirror resolve_effective's declared resolution: an UNASSIGNED agent routes through
  # `primary`, so gating (and its pending/warning observability) must resolve it too.
  local declared; declared="$(agent_assigned "$1")"
  [[ -z "$declared" || "$declared" == "null" ]] && declared="$(primary_model)"
  local rt; rt="$(model_runtime "$declared")"
  [[ ( "$rt" == "lmstudio" || "$rt" == "meridian" || "$rt" == "openai" || "$rt" == "codex-bridge" || "$rt" == "openai-compat" ) && "$2" != "$declared" ]]
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
  local m rt sv ef ab ke rp tp res
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    rt="$(model_runtime "$m")"; sv="$(model_served "$m")"
    ef=""; ab=""; ke=""; rp=""; tp=""
    case "$rt" in
      meridian|openai|codex-bridge) ef="$(model_effort "$m")" ;;
      openai-compat)
        ab="$(model_api_base "$m")"; ke="$(model_key_env "$m")"
        rp="$(my_q ".models.\"$m\".rpm")"; [[ "$rp" == "null" ]] && rp=""
        tp="$(my_q ".models.\"$m\".tpm")"; [[ "$tp" == "null" ]] && tp=""
        ;;
    esac
    res="$(lms_register_model "$m" "$sv" "$rt" "$ef" "$ab" "$ke" "$rp" "$tp")" || { warn "register_model_list: $m failed"; continue; }
    [[ "$res" == "CHANGED" ]] && _CONFIG_CHANGED=1
  done < <(my_q '.models | keys | .[]')
  return 0
}

# preflight_superset_in_config — assert the canonical local IDs are present in
# config.yaml before any key mint (constraint 3). nemotron-3-nano:4b is the ONLY
# local chat model; `local`/`local-heavy` are its always-present canonical aliases.
preflight_superset_in_config() {
  local s missing=()
  for s in local local-heavy; do
    config_has_slug "$s" || missing+=("$s")
  done
  # Beyond the canonical aliases, every superset member that is a REAL models.yml
  # model (ollama/lmstudio runtime) must also be registered before we mint.
  local mem rt
  while IFS= read -r mem; do
    [[ -z "$mem" ]] && continue
    case "$mem" in local|local-heavy) continue ;; esac  # canonical aliases, hard-checked above
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
# $key is a CALLER-SUPPLIED token ($1), not the master key — a generic probe, so it
# intentionally keeps -H (a master-key-in-argv sweep should leave this: key is a param).
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
    local upd _body
    # Build the key-bearing body via python (key via env var, never argv), xtrace-
    # suppressed, then POST from a 0600 temp file via --data @file so the existing scoped
    # key never lands in curl argv (parity with litellm_reconcile_key_exact). A subshell
    # EXIT-trap removes the temp on every path, isolated from the outer lock trap.
    local _rx=''; case $- in *x*) _rx=1; set +x;; esac
    _body="$(_RK_EXK="$existing" _RK_MJ="$models_json" python3 -c 'import json,os,sys
sys.stdout.write(json.dumps({"key":os.environ["_RK_EXK"],"models":json.loads(os.environ["_RK_MJ"])}))' 2>/dev/null || true)"
    [[ -n "$_rx" ]] && set -x
    upd="$(
      case $- in *x*) set +x;; esac
      [[ -n "$_body" ]] || exit 0
      _rk_bf="$(mktemp 2>/dev/null)" || exit 0
      trap 'rm -f "$_rk_bf"' EXIT
      printf '%s' "$_body" > "$_rk_bf" || exit 0
      litellm_master_curl -s --max-time 15 -H 'Content-Type: application/json' \
        -X POST "$base/key/update" --data @"$_rk_bf" 2>/dev/null || true
    )"
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
  litellm_master_curl -s --max-time 10 -H 'Content-Type: application/json' \
    -X POST "$base/key/delete" -d "{\"key_aliases\":[\"${alias}\"]}" >/dev/null 2>&1 || true
  local newkey
  newkey="$(litellm_master_curl -s --max-time 15 -H 'Content-Type: application/json' \
    -X POST "$base/key/generate" \
    -d "{\"models\":${models_json},\"key_alias\":\"${alias}\",\"metadata\":{\"owner\":\"${owner}\",\"purpose\":\"model-sync\"}}" \
    | python3 -c 'import sys,json; print(json.load(sys.stdin).get("key",""))' 2>/dev/null)"
  [[ -n "$newkey" ]] || { err "remint_key: failed to mint $key_env (LiteLLM up + DATABASE_URL set?)"; return 1; }
  set_env "$key_env" "$newkey"          # set_env never logs the value
  ok "$key_env minted against the superset + saved to .env"
  return 0
}

# ensure_key_widened <key_env> <alias> <owner> — converge the fleet scoped key to
# EXACTLY the SUPERSET: re-mint when it's MISSING a member (would 403 a live model)
# OR carries a stale EXTRA (a slug removed from models.yml — e.g. the ca08cc1
# nemotron-only cull — that a widen-only pass can never drop). Idempotent: a no-op
# when the key already equals the superset as a set. WARN-non-fatal (opt-in services).
ensure_key_widened() {
  local key_env="$1" alias="$2" owner="$3"
  [[ -n "$key_env" && "$key_env" != "null" ]] || return 0   # e.g. deerflow uses master key
  local key; key="$(get_env "$key_env" '')"
  if [[ -n "$key" ]]; then
    # Read the key's LIVE allow-list once and compare to the superset as a SET. A
    # wildcard/unrestricted key already covers everything and is left untouched
    # (never narrowed). Unreachable gateway => empty => skip (can't judge coverage
    # when LiteLLM is down; the next sync/doctor retries). Since P1 registered every
    # models.yml model into config.yaml before this P3 runs, the superset is exactly
    # what remint_key's /key/update REPLACE writes, so an equal set means already-exact.
    local cur; cur="$(_litellm_key_allowlist "$key")"
    if [[ -z "$cur" ]] || printf '%s\n' "$cur" | grep -qxF '__wildcard__'; then
      return 0
    fi
    _sets_equal "$cur" "$(superset_members)" && return 0   # already EXACTLY the superset
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
# in deer-flow/config.yaml between the markers. Platform policy (2026-06-25):
# basic->primary (claude-opus-sub-xhigh), reasoning-><effective>. NO silent local
# fallback — the LiteLLM cloud->local chain was removed, so a Meridian outage
# surfaces a 503. Restart deerflow only if the block changed.
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
out = {"default": doc.get("default"), "primary": doc.get("primary") or doc.get("default"),
       "models": doc.get("models",{}),
       "assignments": doc.get("assignments",{}),
       "parked": doc.get("parked",{}) or {},
       "kinds": doc.get("kinds",{}) or {},
       "litellm_up": litellm_up}
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
    agent_parked "$a" && effdisp="$eff (PARKED)"

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
    yq -i 'del(.parked)' "$MODELS_YML" 2>/dev/null || true   # blanket assign re-enables everyone (unpark all)
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
  # Assigning a model re-enables a parked agent (council: assign always unparks).
  if agent_parked "$agent"; then
    AG="$agent" yq -i 'del(.parked[strenv(AG)])' "$MODELS_YML" 2>/dev/null && note "unparked '$agent' (assigning re-enables it)"
  fi
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
# cmd_add_remote — add a NON-LM-Studio model by id (council P1c). ollama +
# openai-compat are declared into models.yml (sync registers + widens keys);
# openrouter is config.yaml-ONLY (no models.yml runtime, NOT agent-assignable in
# v1) with an id-FORMAT check (openrouter ids are routinely hallucinated -> a bad
# id registers fine but 404s at call time, so we at least require provider/model).
cmd_add_remote() {
  local runtime="" served="" name="" api_base="" key_env="" rpm="" tpm="" big="" dry=0 nosync=0 a expect=""
  for a in "$@"; do
    if [[ -n "$expect" ]]; then
      case "$expect" in
        runtime) runtime="$a" ;; served) served="$a" ;; api_base) api_base="$a" ;;
        key_env) key_env="$a" ;; rpm) rpm="$a" ;; tpm) tpm="$a" ;; big) big="$a" ;; name) name="$a" ;;
      esac
      expect=""; continue
    fi
    case "$a" in
      --runtime) expect=runtime ;; --served) expect=served ;; --api-base) expect=api_base ;;
      --key-env) expect=key_env ;; --rpm) expect=rpm ;; --tpm) expect=tpm ;; --big) expect=big ;;
      as) expect=name ;;
      --dry-run) dry=1 ;; --no-sync) nosync=1 ;;
      -*) err "add: unknown flag '$a'"; exit 2 ;;
      *) [[ -z "$name" ]] && name="$a" ;;
    esac
  done
  validate || exit $?
  [[ -n "$served" ]] || { err "add --runtime $runtime: --served <id> is required"; exit 2; }

  case "$runtime" in
    ollama)
      if [[ -z "$name" ]]; then
        name="local-$(printf '%s' "$served" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9.]+/-/g; s/-+/-/g; s/^[.-]+//; s/[.-]+$//')"
      fi
      [[ "$name" =~ ^local-[a-z0-9]([a-z0-9._-]*[a-z0-9])?$ ]] || { err "ollama add: name '$name' invalid (use \`as local-<name>\`)"; exit 2; }
      case "$name" in local|local-heavy) err "name '$name' is reserved"; exit 2 ;; esac
      model_exists "$name" && { err "name '$name' already declared"; exit 2; }
      [[ -n "$big" ]] || big=false
      case "$big" in true|false) : ;; *) err "--big must be true|false (got '$big')"; exit 2 ;; esac
      if (( dry )); then note "[dry-run] would declare models.$name {runtime: ollama, served: $served, big: $big}; ollama add does NOT pull — run: ollama pull $served"; exit 0; fi
      NM="$name" SV="$served" BIG="$big" yq -i '.models[strenv(NM)] = {"runtime":"ollama","served":strenv(SV),"big":(strenv(BIG)=="true"),"note":"added via model add"}' "$MODELS_YML" || { err "yq -i add failed"; exit 1; }
      ok "declared models.$name (ollama, served=$served, big=$big)"
      note "ollama add does NOT pull the weights — run: ollama pull $served" ;;
    openai-compat)
      [[ -n "$name" ]] || { err "openai-compat add: an alias is required (\`as <name>\`)"; exit 2; }
      [[ -n "$api_base" ]] || { err "openai-compat add: --api-base <https-url> is required"; exit 2; }
      [[ "$api_base" =~ ^https?:// ]] || { err "--api-base must be an http(s):// URL (got '$api_base')"; exit 2; }
      [[ -n "$key_env" ]] || { err "openai-compat add: --key-env <ENV_VAR> is required"; exit 2; }
      [[ "$key_env" =~ ^[A-Z_][A-Z0-9_]*$ ]] || { err "--key-env must be an ENV-style name (got '$key_env')"; exit 2; }
      [[ -z "$rpm" || "$rpm" =~ ^[0-9]+$ ]] || { err "--rpm must be a positive integer (got '$rpm')"; exit 2; }
      [[ -z "$tpm" || "$tpm" =~ ^[0-9]+$ ]] || { err "--tpm must be a positive integer (got '$tpm')"; exit 2; }
      model_exists "$name" && { err "name '$name' already declared"; exit 2; }
      if (( dry )); then note "[dry-run] would declare models.$name {runtime: openai-compat, served: $served, api_base: $api_base, key_env: $key_env${rpm:+, rpm: $rpm}${tpm:+, tpm: $tpm}}"; exit 0; fi
      NM="$name" SV="$served" AB="$api_base" KE="$key_env" yq -i '.models[strenv(NM)] = {"runtime":"openai-compat","served":strenv(SV),"api_base":strenv(AB),"key_env":strenv(KE),"note":"added via model add"}' "$MODELS_YML" || { err "yq -i add failed"; exit 1; }
      [[ -n "$rpm" ]] && NM="$name" RP="$rpm" yq -i '.models[strenv(NM)].rpm = (strenv(RP)|tonumber)' "$MODELS_YML"
      [[ -n "$tpm" ]] && NM="$name" TP="$tpm" yq -i '.models[strenv(NM)].tpm = (strenv(TP)|tonumber)' "$MODELS_YML"
      ok "declared models.$name (openai-compat, served=$served, key_env=$key_env)"
      [[ -n "$(get_env "$key_env" '')" ]] || warn "key_env $key_env not in .env yet — set it, then recreate LiteLLM (bash bin/start-litellm.sh --recreate) so the route serves" ;;
    openrouter)
      [[ "$served" == */* ]] || { err "openrouter add: --served must look like 'provider/model' (e.g. anthropic/claude-3.7-sonnet); got '$served'. Verify the exact id at https://openrouter.ai/models"; exit 2; }
      if [[ -z "$name" ]]; then
        name="openrouter-$(printf '%s' "$served" | tr '[:upper:]/' '[:lower:]-' | sed -E 's/[^a-z0-9.-]+/-/g; s/-+/-/g; s/^-+//; s/-+$//')"
      fi
      [[ -f "$CONFIG" ]] || { err "litellm/config.yaml not found at $CONFIG"; exit 2; }
      if yq -e ".model_list[] | select(.model_name == \"$name\")" "$CONFIG" >/dev/null 2>&1; then err "config.yaml already has model_name '$name'"; exit 2; fi
      if (( dry )); then note "[dry-run] would add to litellm/config.yaml model_list: {model_name: $name, model: openrouter/$served, api_key: os.environ/OPENROUTER_API_KEY} — NOT agent-assignable (fallback-eligible)"; exit 0; fi
      NM="$name" MD="openrouter/$served" yq -i '.model_list += [{"model_name": strenv(NM), "litellm_params": {"model": strenv(MD), "api_key": "os.environ/OPENROUTER_API_KEY"}}]' "$CONFIG" || { err "yq -i add to config.yaml failed"; exit 1; }
      ok "added '$name' (openrouter/$served) to litellm/config.yaml model_list"
      note "NOT agent-assignable in v1 (fallback-eligible). VERIFY the id exists at https://openrouter.ai/models — a wrong id registers fine but 404s at call time."
      [[ -n "$(get_env OPENROUTER_API_KEY '')" ]] || warn "OPENROUTER_API_KEY not in .env — set it, then recreate LiteLLM."
      if (( nosync )); then
        note "--no-sync: restart LiteLLM to load the route (bash bin/start-litellm.sh)."
      else
        log "restarting LiteLLM to load the new route..."
        docker restart litellm >/dev/null 2>&1 || warn "docker restart litellm failed — restart manually (bash bin/start-litellm.sh)"
        litellm_wait_ready 60 || warn "LiteLLM did not report ready within 60s"
      fi
      return 0 ;;
    *) err "add --runtime: want ollama|lmstudio|openai-compat|openrouter (got '$runtime')"; exit 2 ;;
  esac

  # ollama + openai-compat declared into models.yml -> sync registers + widens keys.
  if (( nosync )); then
    note "declared only; run vz-ai-stack.sh model sync to register it into LiteLLM + widen scoped keys"
  else
    cmd_sync
  fi
}

cmd_add() {
  # Explicit-runtime add (ollama / openai-compat / openrouter) -> delegate. The
  # bare form (or `--runtime lmstudio`) keeps the LM Studio slug path below.
  local _ra _rprev="" _rrt=""
  for _ra in "$@"; do
    [[ "$_rprev" == "--runtime" ]] && { _rrt="$_ra"; break; }
    _rprev="$_ra"
  done
  if [[ -n "$_rrt" && "$_rrt" != "lmstudio" ]]; then cmd_add_remote "$@"; return $?; fi
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
    local|local-heavy)
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
# 6c. edit — in-place edit of SAFE model fields only
# ---------------------------------------------------------------------------
# `model edit <name> <field> <value>` edits a declared model's NON-IDENTITY
# fields. Safe (re-renderable by a normal sync, no re-mint/recreate): rpm, tpm,
# ttl, big, effort, note. Identity/endpoint fields (runtime/served/api_base/
# key_env) are REFUSED — changing them is a remove + re-add (they move the route
# and, for key_env, need a LiteLLM --recreate). Effort is validated against the
# runtime exactly like validate() does.
cmd_edit() {
  local name="" field="" value="" set_val=0 dry=0 nosync=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      --no-sync) nosync=1 ;;
      -*) err "edit: unknown flag '$a'"; exit 2 ;;
      *) if [[ -z "$name" ]]; then name="$a"
         elif [[ -z "$field" ]]; then field="$a"
         elif (( ! set_val )); then value="$a"; set_val=1
         fi ;;
    esac
  done
  validate || exit $?
  if [[ -z "$name" || -z "$field" || $set_val -eq 0 ]]; then
    err "usage: vz-ai-stack.sh model edit <name> <field> <value> [--dry-run] [--no-sync]"
    err "  editable fields: rpm | tpm | ttl | big | effort | note"
    exit 2
  fi
  if ! model_exists "$name"; then
    err "unknown model '$name'. Valid models:"; my_q '.models | keys | .[]' | sed 's/^/    /' >&2; exit 2
  fi
  local rt; rt="$(model_runtime "$name")"
  local yq_set
  case "$field" in
    rpm|tpm|ttl)
      [[ "$value" =~ ^[0-9]+$ ]] || { err "edit: $field must be a positive integer (got '$value')"; exit 2; }
      yq_set=".models[strenv(NM)].$field = (strenv(VAL)|tonumber)" ;;
    big)
      case "$value" in true|false) : ;; *) err "edit: big must be true|false (got '$value')"; exit 2 ;; esac
      yq_set=".models[strenv(NM)].big = (strenv(VAL) == \"true\")" ;;
    effort)
      case "$rt" in
        meridian)
          case "$value" in low|medium|high|xhigh|max|ultracode) : ;; *) err "edit: meridian effort want low|medium|high|xhigh|max|ultracode (got '$value')"; exit 2 ;; esac ;;
        openai|codex-bridge)
          case "$value" in none|low|medium|high|xhigh) : ;; *) err "edit: $rt effort want none|low|medium|high|xhigh (got '$value')"; exit 2 ;; esac ;;
        *) err "edit: effort does not apply to runtime '$rt' (only meridian|openai|codex-bridge)"; exit 2 ;;
      esac
      yq_set=".models[strenv(NM)].effort = strenv(VAL)" ;;
    note)
      yq_set=".models[strenv(NM)].note = strenv(VAL)" ;;
    runtime|served|api_base|key_env)
      err "edit: '$field' changes the model's identity/endpoint — use remove + re-add instead:"
      err "  vz-ai-stack.sh model remove $name   &&   vz-ai-stack.sh model add ..."
      exit 2 ;;
    *)
      err "edit: unknown/unsafe field '$field' (editable: rpm|tpm|ttl|big|effort|note)"; exit 2 ;;
  esac
  local before; before="$(my_q ".models.\"$name\".$field")"
  if (( dry )); then
    note "[dry-run] would set models.$name.$field: ${before} -> ${value} (no write)"; exit 0
  fi
  NM="$name" VAL="$value" yq -i "$yq_set" "$MODELS_YML" || { err "yq -i edit failed"; exit 1; }
  ok "models.$name.$field: ${before} -> ${value}"
  if (( nosync )); then
    note "--no-sync: not reconciling. Run 'vz-ai-stack.sh model sync' to apply."; exit 0
  fi
  cmd_sync
}

# ---------------------------------------------------------------------------
# 6d. remove — delete a declared model from models.yml AND config.yaml
# ---------------------------------------------------------------------------
# `model remove <name>` is the inverse of `add`. register_model_list is ADD-ONLY
# (it never deletes), so removal must yq-del the entry from BOTH models.yml and
# litellm/config.yaml's model_list, then restart LiteLLM to drop the live route.
# Full guard set (refuse if the model is still referenced anywhere):
#   - it is .default (the always-on fallback) or .primary
#   - any agent is still assigned to it (active OR parked — the assignment value
#     still names it; reassign first)
#   - it is a key OR a target in config.yaml litellm_settings.fallbacks (the
#     hand-curated failover policy — a dangling target silently breaks failover)
cmd_remove() {
  local name="" dry=0 nosync=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      --no-sync) nosync=1 ;;
      -*) err "remove: unknown flag '$a'"; exit 2 ;;
      *) [[ -z "$name" ]] && name="$a" ;;
    esac
  done
  validate || exit $?
  [[ -n "$name" ]] || { err "usage: vz-ai-stack.sh model remove <name> [--dry-run] [--no-sync]"; exit 2; }
  if ! model_exists "$name"; then
    err "unknown model '$name' (nothing to remove)"; exit 2
  fi

  # GUARD 1 — not the default / primary.
  [[ "$name" != "$(default_model)" ]] || { err "refuse: '$name' is .default (the always-on fallback) — repoint .default in models.yml first"; exit 2; }
  local prim; prim="$(my_q '.primary')"
  [[ "$name" != "$prim" ]] || { err "refuse: '$name' is .primary (model for unassigned agents) — repoint .primary first"; exit 2; }

  # GUARD 2 — no agent (active OR parked) still assigned.
  local users; users="$(MN="$name" yq -r '.assignments | to_entries | map(select(.value == strenv(MN))) | .[].key' "$MODELS_YML" 2>/dev/null || true)"
  if [[ -n "$users" ]]; then
    err "refuse: '$name' is still assigned to: $(echo "$users" | tr '\n' ' ')"
    err "  reassign those agents first: vz-ai-stack.sh model assign <agent> <other-model>"
    exit 2
  fi

  # GUARD 3 — not referenced in config.yaml fallbacks (as a primary key OR a target).
  if [[ -f "$CONFIG" ]]; then
    local fbrefs; fbrefs="$(yq -r '.litellm_settings.fallbacks // [] | .[] | (keys[], .[][])' "$CONFIG" 2>/dev/null | LC_ALL=C sort -u || true)"
    if [[ -n "$fbrefs" ]] && echo "$fbrefs" | grep -qxF "$name"; then
      err "refuse: '$name' is referenced in litellm/config.yaml litellm_settings.fallbacks (a failover key or target)"
      err "  edit the fallback chain first — it is hand-curated policy (metered -> local; never a silent bill)"
      exit 2
    fi
  fi

  local rt sv; rt="$(model_runtime "$name")"; sv="$(model_served "$name")"
  if (( dry )); then
    note "[dry-run] would remove models.$name (runtime=$rt served=$sv) from models.yml AND config.yaml model_list (no write)"; exit 0
  fi

  # WRITE — back up models.yml, delete from models.yml, then from config.yaml.
  cp -p "$MODELS_YML" "$MODELS_YML.bak" 2>/dev/null || true
  NM="$name" yq -i 'del(.models[strenv(NM)])' "$MODELS_YML" || { err "yq -i remove from models.yml failed (restore: cp $MODELS_YML.bak $MODELS_YML)"; exit 1; }
  ok "removed models.$name from models.yml (backup: $(basename "$MODELS_YML").bak)"
  if [[ -f "$CONFIG" ]]; then
    # HARD-FAIL, not warn: models.yml is already deleted above, so a failed config.yaml
    # delete leaves an ORPHAN route (a model_name with no models.yml backing) that NEITHER
    # doctor check 40 (models.yml->config coverage) NOR check 65 detects. Fail loudly with
    # a restore path instead of silently leaving the two files inconsistent.
    NM="$name" yq -i 'del(.model_list[] | select(.model_name == strenv(NM)))' "$CONFIG" \
      && ok "removed '$name' from config.yaml model_list" \
      || { err "FAILED to delete '$name' from config.yaml — it is now an ORPHAN route (no models.yml backing)."; \
           err "  restore models.yml: cp '$MODELS_YML.bak' '$MODELS_YML'  then remove '$name' from '$CONFIG' by hand."; exit 1; }
  fi
  if (( nosync )); then
    note "--no-sync: restart LiteLLM to drop the live route — bash bin/start-litellm.sh (or 'docker restart litellm')."; exit 0
  fi
  # A pure deletion does not set _CONFIG_CHANGED (register_model_list is add-only),
  # so restart LiteLLM directly to drop the now-removed route from the live router.
  log "restarting LiteLLM to drop the removed route..."
  docker restart litellm >/dev/null 2>&1 || warn "docker restart litellm failed — restart manually (bash bin/start-litellm.sh)"
  litellm_wait_ready 60 || warn "LiteLLM did not report ready within 60s"
  ok "model remove complete ($name)"
}

# ---------------------------------------------------------------------------
# 6e. park / unpark — disable / re-enable an agent (renders the default sentinel)
# ---------------------------------------------------------------------------
# `model park <agent>` disables an agent WITHOUT losing its assignment: it sets
# .parked[agent]=true and the agent renders the always-on `default` (local = nemotron-3-nano:4b)
# sentinel until unparked. `model unpark <agent>` clears it. (assign also auto-
# unparks.) Reversible; doctor stays green because rendered==effective==default
# for a parked agent (resolve_effective short-circuits to the sentinel).
cmd_park() {
  local agent="" dry=0 nosync=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      --no-sync) nosync=1 ;;
      -*) err "park: unknown flag '$a'"; exit 2 ;;
      *) [[ -z "$agent" ]] && agent="$a" ;;
    esac
  done
  validate || exit $?
  [[ -n "$agent" ]] || { err "usage: vz-ai-stack.sh model park <agent> [--dry-run] [--no-sync]"; exit 2; }
  if ! agent_exists "$agent"; then
    err "unknown agent '$agent'. Valid agents:"; my_q '.kinds | keys | .[]' | sed 's/^/    /' >&2; exit 2
  fi
  local def; def="$(default_model)"
  if agent_parked "$agent"; then ok "agent '$agent' already parked (renders to $def)"; exit 0; fi
  if (( dry )); then note "[dry-run] would park '$agent' -> renders to $def (assignment '$(agent_assigned "$agent")' preserved)"; exit 0; fi
  AG="$agent" yq -i '.parked[strenv(AG)] = true' "$MODELS_YML" || { err "yq -i park failed"; exit 1; }
  ok "parked '$agent' (assignment '$(agent_assigned "$agent")' preserved); renders to $def until unparked"
  if (( nosync )); then note "--no-sync: run 'vz-ai-stack.sh model sync $agent' to apply."; exit 0; fi
  cmd_sync "$agent"
}

cmd_unpark() {
  local agent="" dry=0 nosync=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      --no-sync) nosync=1 ;;
      -*) err "unpark: unknown flag '$a'"; exit 2 ;;
      *) [[ -z "$agent" ]] && agent="$a" ;;
    esac
  done
  validate || exit $?
  [[ -n "$agent" ]] || { err "usage: vz-ai-stack.sh model unpark <agent> [--dry-run] [--no-sync]"; exit 2; }
  if ! agent_exists "$agent"; then
    err "unknown agent '$agent'. Valid agents:"; my_q '.kinds | keys | .[]' | sed 's/^/    /' >&2; exit 2
  fi
  if ! agent_parked "$agent"; then ok "agent '$agent' is not parked (nothing to do)"; exit 0; fi
  if (( dry )); then note "[dry-run] would unpark '$agent' -> restores assignment '$(agent_assigned "$agent")'"; exit 0; fi
  AG="$agent" yq -i 'del(.parked[strenv(AG)])' "$MODELS_YML" || { err "yq -i unpark failed"; exit 1; }
  ok "unparked '$agent'; restored '$(agent_assigned "$agent")'"
  if (( nosync )); then note "--no-sync: run 'vz-ai-stack.sh model sync $agent' to apply."; exit 0; fi
  cmd_sync "$agent"
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

  # P3b — reconcile the OPT-IN consumer scoped keys (metagpt/agentscope/oasis/chatdev/
  # aitown/concordia/openwork). These live OUTSIDE the models.yml `kinds` fleet and are
  # minted with a hardcoded allow-list at their own phase, so the fleet loop above never
  # re-scopes them — a catalog rename/removal silently drifts them. The scoped_key_registry
  # (common.sh) is the single source of truth for their intended sets; converge each
  # EXISTING key EXACT (add missing + drop stale extras) via litellm_reconcile_key_exact.
  # A key not in .env (consumer not installed) is skipped inside the primitive. Control-
  # plane only (/key/info + /key/update) — never loads a model (OOM-safe). Skipped for a
  # single-agent `model sync <agent>` (those target a fleet kind, not an opt-in key).
  if [[ -z "$only" ]]; then
    log "P3b: reconciling opt-in consumer scoped keys (registry)..."
    local rk_env rk_alias rk_owner rk_models rk_want rk_asg
    while IFS='|' read -r rk_env rk_alias rk_owner rk_models; do
      [[ -z "$rk_env" ]] && continue
      [[ -n "$(get_env "$rk_env" '')" ]] || continue      # opt-in consumer not installed — skip
      # intended = registry list UNION any live models.yml assignment for this owner. (Today
      # these 7 opt-in owners aren't models.yml `kinds`, so `model assign` rejects them and the
      # union is a defensive no-op; it future-proofs the day they become assignable.)
      rk_want="$rk_models"
      rk_asg="$(my_q ".assignments.\"$rk_owner\"")"
      if [[ -n "$rk_asg" && "$rk_asg" != "null" ]] && model_exists "$rk_asg"; then
        rk_want="$(RK_J="$rk_models" RK_A="$rk_asg" python3 -c 'import json,os
lst=json.loads(os.environ["RK_J"]); a=os.environ["RK_A"]
if a not in lst: lst.append(a)
print(json.dumps(lst))' 2>/dev/null || echo "$rk_models")"
      fi
      litellm_reconcile_key_exact "$rk_env" "$rk_want"
    done < <(scoped_key_registry)
  fi

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
  local m rt sv ef ab ke rp tp
  ( LMS_CONFIG="$tmp/after.yaml"
    while IFS= read -r m; do
      [[ -z "$m" ]] && continue
      rt="$(model_runtime "$m")"; sv="$(model_served "$m")"
      # MUST mirror register_model_list's per-runtime arg extraction, else
      # openai-compat models fail-closed here and the dry-run shows a false "no change".
      ef=""; ab=""; ke=""; rp=""; tp=""
      case "$rt" in
        meridian|openai|codex-bridge) ef="$(model_effort "$m")" ;;
        openai-compat)
          ab="$(model_api_base "$m")"; ke="$(model_key_env "$m")"
          rp="$(my_q ".models.\"$m\".rpm")"; [[ "$rp" == "null" ]] && rp=""
          tp="$(my_q ".models.\"$m\".tpm")"; [[ "$tp" == "null" ]] && tp=""
          ;;
      esac
      lms_register_model "$m" "$sv" "$rt" "$ef" "$ab" "$ke" "$rp" "$tp" >/dev/null 2>&1 || true
    done < <(my_q '.models | keys | .[]')
  )
  if diff -u "$tmp/before.yaml" "$tmp/after.yaml" >"$tmp/diff.txt" 2>/dev/null; then
    note "  (config.yaml already current — no model_list change)"
  else
    sed 's/^/    /' "$tmp/diff.txt"
  fi
  rm -rf "$tmp"

  note "P3 allowlist widening plan: scoped keys -> [$(superset_members | paste -sd' ' - 2>/dev/null || true)]"
  note "P3b opt-in-key reconcile plan: converge each INSTALLED registry key EXACT -> [$(scoped_key_registry | cut -d'|' -f1 | paste -sd' ' - 2>/dev/null || true)]"
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
# 7b. fallback — view / edit the hand-curated LiteLLM failover chains (v1.1)
# ---------------------------------------------------------------------------
# `litellm_settings.fallbacks` (config.yaml) is hand-curated policy: every
# metered/subscription PRIMARY fails over to the always-on LOCAL (Ollama) tier so
# an outage degrades to local compute, never a silent bill. It is config.yaml-ONLY
# (model sync never writes it) and COMMENT-RICH (policy header + inter-entry notes
# + a trailing commented-out reference block). yq -i would shred those comments, so
# edits are LINE-SURGICAL inside the fallbacks block then round-trip VALIDATED
# (yq parse + structural + entry-count + duplicate-key asserts) before an atomic mv.
#
#   model fallback list [--json]
#   model fallback set <model> <target...> [--allow-non-local] [--dry-run]
#   model fallback remove <model> [--dry-run]
#
# DEFAULT GUARD: every target must be an ollama-runtime (local-tier) model — the one
# tier guaranteed up when cloud/daemon is dark. --allow-non-local opts into sub/metered
# targets (which can be unavailable in the SAME outage that triggers the fallback, and
# may incur cost). No live restart here: LiteLLM reads config.yaml at startup, so a
# `docker restart litellm` is needed for an edit to take effect — the console
# /api/fallback drives that (gated + readiness-checked); a CLI user is told to restart.

_fb_config_model_exists() {            # is $1 a model_name in config.yaml model_list?
  [[ -f "$CONFIG" ]] || return 1
  # capture-then-here-string (NOT a pipe): grep -q closes the pipe on first match,
  # which SIGPIPEs yq and trips `set -o pipefail` into a false negative.
  local names; names="$(yq -r '.model_list[].model_name' "$CONFIG" 2>/dev/null)" || return 1
  LC_ALL=C grep -qxF "$1" <<<"$names"
}
_fb_is_local() { [[ "$(model_runtime "$1")" == "ollama" ]]; }   # safe (always-on) target?
_fb_count() { yq -r '.litellm_settings.fallbacks // [] | length' "$CONFIG" 2>/dev/null || echo 0; }
_fb_targets_of() { MN="$1" yq -r '[.litellm_settings.fallbacks // [] | .[] | select(has(strenv(MN)))] | .[0][strenv(MN)] // [] | join(",")' "$CONFIG" 2>/dev/null || true; }
_fb_entry_count_for() { MN="$1" yq -r '[.litellm_settings.fallbacks // [] | .[] | select(has(strenv(MN)))] | length' "$CONFIG" 2>/dev/null || echo 0; }
_fb_list_tsv() { yq -r '.litellm_settings.fallbacks // [] | .[] | (keys[0]) as $k | $k + "\t" + (.[$k] | join(","))' "$CONFIG" 2>/dev/null || true; }

_fb_render_inner() {                   # echo  '- <model>: ["t1", "t2"]'  (no leading indent)
  local model="$1"; shift
  local out="- $model: [" first=1 t
  for t in "$@"; do (( first )) || out+=", "; first=0; out+="\"$t\""; done
  printf '%s]' "$out"
}

# line-surgical editor: stdin=config, stdout=edited, stderr="MODE <m>" or an abort token.
# exit: 0 ok, 3 abort (DUPLICATE/BLOCKSTYLE/CRLF), 4 remove-not-found.
_fb_apply_awk() {                      # $1=op  $2=model  $3=inner(set only)
  awk -v op="$1" -v model="$2" -v inner="$3" '
  function keyof(line,   s){ if(line !~ /^ *- /) return ""; s=line; sub(/^ *- /,"",s); if(s ~ /^#/) return ""; if(s !~ /:/) return ""; sub(/:.*/,"",s); sub(/^"/,"",s); sub(/"$/,"",s); return s }
  function indentof(line){ match(line,/^ */); return RLENGTH }
  function single_line(line,   v){ v=line; sub(/^[^:]*:/,"",v); gsub(/^[ \t]+|[ \t]+$/,"",v); return (v!="" && v !~ /^#/) }
  function flush(   i,found,midx,lastreal,hasreal){
    found=0; midx=0; lastreal=0; hasreal=0
    for(i=1;i<=nb;i++){ if(indentof(buf[i])==entryind && keyof(buf[i])!=""){ hasreal=1; lastreal=i; if(keyof(buf[i])==model){found++; midx=i} } }
    if(found>1){ print "DUPLICATE" > "/dev/stderr"; aborted=3; return }
    if(op=="remove"){
      if(found==0){ print "NOTFOUND" > "/dev/stderr"; aborted=4; return }
      if(!single_line(buf[midx])){ print "BLOCKSTYLE" > "/dev/stderr"; aborted=3; return }
      print "MODE remove" > "/dev/stderr"
      for(i=1;i<=nb;i++) if(i!=midx) print buf[i]
      return
    }
    if(found==1){
      if(!single_line(buf[midx])){ print "BLOCKSTYLE" > "/dev/stderr"; aborted=3; return }
      print "MODE replace" > "/dev/stderr"
      for(i=1;i<=nb;i++){ if(i==midx) print pad inner; else print buf[i] }
      return
    }
    print "MODE insert" > "/dev/stderr"
    if(hasreal){ for(i=1;i<=nb;i++){ print buf[i]; if(i==lastreal) print pad inner } }
    else { print pad inner; for(i=1;i<=nb;i++) print buf[i] }
  }
  BEGIN{ state=0; nb=0; aborted=0 }
  {
    if(aborted){ next }
    if(state==0){ print; if($0 ~ /^ +fallbacks:[ \t\r]*$/){ blkindent=indentof($0); entryind=blkindent+2; pad=""; for(j=0;j<entryind;j++) pad=pad" "; state=1 } next }
    if(state==1){
      if($0 ~ /\r/){ print "CRLF" > "/dev/stderr"; aborted=3; next }
      if($0 ~ /^[ \t]*$/){ buf[++nb]=$0; next }
      if(indentof($0) <= blkindent){ flush(); if(aborted) next; print; state=2; next }
      buf[++nb]=$0; next
    }
    print
  }
  END{ if(aborted) exit aborted; if(state==1){ flush(); if(aborted) exit aborted } }
  '
}

_fb_list() {
  local json=0 a
  for a in "$@"; do case "$a" in --json) json=1 ;; -*) err "fallback list: unknown flag '$a'"; exit 2 ;; esac; done
  [[ -f "$CONFIG" ]] || { err "config.yaml not found at $CONFIG"; exit 2; }
  if (( json )); then yq -o=json -I=0 '.litellm_settings.fallbacks // []' "$CONFIG"; return 0; fi
  local any=0 m targets
  while IFS=$'\t' read -r m targets; do [[ -z "$m" ]] && continue; any=1; printf '  %-30s -> %s\n' "$m" "$targets"; done < <(_fb_list_tsv)
  (( any )) || note "no fallback chains configured in $CONFIG"
}

_fb_set() {
  local model="" allow=0 dry=0 a; local -a targets=()
  for a in "$@"; do
    case "$a" in
      --allow-non-local) allow=1 ;;
      --dry-run) dry=1 ;;
      -*) err "fallback set: unknown flag '$a'"; exit 2 ;;
      *) if [[ -z "$model" ]]; then model="$a"; else targets+=("$a"); fi ;;
    esac
  done
  { [[ -n "$model" ]] && (( ${#targets[@]} >= 1 )); } || { err "usage: vz-ai-stack.sh model fallback set <model> <target...> [--allow-non-local] [--dry-run]"; exit 2; }
  [[ -f "$CONFIG" ]] || { err "config.yaml not found at $CONFIG"; exit 2; }
  local x
  for x in "$model" "${targets[@]}"; do
    [[ "$x" =~ ^[a-zA-Z0-9_./@-]+$ ]] || { err "fallback: name '$x' is outside the safe charset [a-zA-Z0-9_./@-]"; exit 2; }
  done
  _fb_config_model_exists "$model" || { err "fallback: '$model' is not a model_name in config.yaml model_list"; exit 2; }
  for x in "${targets[@]}"; do
    [[ "$x" != "$model" ]] || { err "fallback: target '$x' cannot be the model itself (self-reference)"; exit 2; }
    _fb_config_model_exists "$x" || { err "fallback: target '$x' is not a model_name in config.yaml model_list"; exit 2; }
    if ! _fb_is_local "$x"; then
      (( allow )) || { err "fallback: target '$x' is not a local (ollama) model — it can be unavailable during the same outage that triggers the fallback (and may incur cost)."; err "  re-run with --allow-non-local to override (the local tier is the always-on safe target — 'never a silent bill')."; exit 2; }
      warn "target '$x' is non-local (sub/metered) — allowed via --allow-non-local; may be unavailable in a correlated outage."
    fi
  done
  local inner exp; inner="$(_fb_render_inner "$model" "${targets[@]}")"; exp="$(IFS=,; echo "${targets[*]}")"
  _fb_commit set "$model" "$inner" "$dry" "$exp"
}

_fb_remove() {
  local model="" dry=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run) dry=1 ;;
      -*) err "fallback remove: unknown flag '$a'"; exit 2 ;;
      *) [[ -z "$model" ]] && model="$a" ;;
    esac
  done
  [[ -n "$model" ]] || { err "usage: vz-ai-stack.sh model fallback remove <model> [--dry-run]"; exit 2; }
  [[ -f "$CONFIG" ]] || { err "config.yaml not found at $CONFIG"; exit 2; }
  [[ "$model" =~ ^[a-zA-Z0-9_./@-]+$ ]] || { err "fallback: name '$model' is outside the safe charset"; exit 2; }
  _fb_commit remove "$model" "" "$dry" ""
}

# transactional edit: lock → awk → validate (parse + structural + count + dup) → atomic mv.
_fb_commit() {
  local op="$1" model="$2" inner="$3" dry="$4" exp="$5"
  local before after mode rc staging errf distinct got
  (( dry )) || lock_acquire            # hold across the whole read-modify-write (TOCTOU-safe vs cmd_sync)
  before="$(_fb_count)"
  staging="$CONFIG.fbtmp.$$"; errf="$(mktemp "${TMPDIR:-/tmp}/fberr.XXXXXX")" || { err "mktemp failed"; exit 1; }
  cp -p "$CONFIG" "$staging" 2>/dev/null || { err "cannot stage $CONFIG"; rm -f "$errf"; exit 1; }
  rc=0; _fb_apply_awk "$op" "$model" "$inner" < "$CONFIG" > "$staging" 2> "$errf" || rc=$?   # ||: set -e would kill before rc=$?
  if (( rc == 4 )); then note "no fallback entry for '$model' in $CONFIG (nothing to remove)"; rm -f "$staging" "$errf"; exit 0; fi
  if (( rc != 0 )); then
    case "$(grep -Eom1 'DUPLICATE|BLOCKSTYLE|CRLF' "$errf" || true)" in
      DUPLICATE)  err "fallback: '$model' appears more than once in the fallbacks list — resolve the duplicate by hand." ;;
      BLOCKSTYLE) err "fallback: '$model' is a multi-line (block-style) entry — the editor only handles inline [\"...\"] entries; edit it by hand." ;;
      CRLF)       err "fallback: the fallbacks block has CRLF line endings — normalize config.yaml to LF first." ;;
      *)          err "fallback: edit failed (awk rc=$rc)." ;;
    esac
    rm -f "$staging" "$errf"; exit 2
  fi
  mode="$(awk '/^MODE /{print $2; exit}' "$errf")"
  if [[ -z "$mode" ]]; then
    if [[ "$op" == "remove" ]]; then note "no fallback entry for '$model' (nothing to remove)"; rm -f "$staging" "$errf"; exit 0; fi
    err "fallback: no editable 'fallbacks:' block found in config.yaml (key absent or inline '[]'). Add a 'fallbacks:' block with at least one entry by hand, then use the editor."
    rm -f "$staging" "$errf"; exit 2
  fi
  if ! yq -e '.' "$staging" >/dev/null 2>&1; then err "fallback: edited config.yaml failed to parse — aborting (no changes written)."; rm -f "$staging" "$errf"; exit 1; fi
  after="$(CONFIG="$staging" _fb_count)"
  # distinct first-key count via PURE yq (no `grep -c . || true` — grep -c prints "0" AND
  # exits 1 on empty input, which is brittle under set -o pipefail / refactor).
  distinct="$(yq -r '.litellm_settings.fallbacks // [] | map(keys[0]) | unique | length' "$staging" 2>/dev/null || echo -1)"
  [[ "$after" == "$distinct" ]] || { err "fallback: post-edit validation found duplicate keys ($after entries, $distinct distinct) — aborting."; rm -f "$staging" "$errf"; exit 1; }
  case "$op:$mode" in
    set:replace)   (( after == before ))     || { err "fallback: count delta invalid (replace $before->$after) — aborting."; rm -f "$staging" "$errf"; exit 1; } ;;
    set:insert)    (( after == before + 1 )) || { err "fallback: count delta invalid (insert $before->$after) — aborting."; rm -f "$staging" "$errf"; exit 1; } ;;
    remove:remove) (( after == before - 1 )) || { err "fallback: count delta invalid (remove $before->$after) — aborting."; rm -f "$staging" "$errf"; exit 1; } ;;
    *) err "fallback: unexpected mode '$mode' for op '$op' — aborting."; rm -f "$staging" "$errf"; exit 1 ;;
  esac
  if [[ "$op" == "set" ]]; then
    got="$(CONFIG="$staging" _fb_targets_of "$model")"
    [[ "$got" == "$exp" ]] || { err "fallback: post-edit targets mismatch (want '$exp', got '$got') — aborting."; rm -f "$staging" "$errf"; exit 1; }
  else
    (( "$(CONFIG="$staging" _fb_entry_count_for "$model")" == 0 )) || { err "fallback: '$model' still present after remove — aborting."; rm -f "$staging" "$errf"; exit 1; }
  fi
  if (( dry )); then
    note "[dry-run] fallback $op '$model' ($mode) — proposed change:"
    { diff -u "$CONFIG" "$staging" || true; } | sed -n '1,40p' | sed 's/^/    /' >&2
    rm -f "$staging" "$errf"; exit 0
  fi
  cp -p "$CONFIG" "$CONFIG.bak" 2>/dev/null || true
  mv "$staging" "$CONFIG" || { err "fallback: atomic mv failed — config.yaml unchanged (backup: $CONFIG.bak)."; rm -f "$staging" "$errf"; exit 1; }
  rm -f "$errf"
  ok "fallback $op '$model' applied to config.yaml ($mode; backup: $(basename "$CONFIG").bak)"
  note "LiteLLM reads config at startup — run from MAIN: 'docker restart litellm' (or apply via the model console) to load the new chain."
}

cmd_fallback() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list)   _fb_list "$@" ;;
    set)    _fb_set "$@" ;;
    remove) _fb_remove "$@" ;;
    -h|--help|help) cat <<'EOF'
vz-ai-stack.sh model fallback — view/edit the hand-curated LiteLLM failover chains
  model fallback list [--json]                                            show the chains (config.yaml-only policy)
  model fallback set <model> <target...> [--allow-non-local] [--dry-run]  set/replace <model>'s failover chain
  model fallback remove <model> [--dry-run]                               delete <model>'s failover chain
Targets default to the local (ollama) tier — the always-on safe target ('never a silent bill').
--allow-non-local opts into sub/metered targets (may be unavailable in the same outage; may incur cost).
Edits are comment-preserving + round-trip validated; restart LiteLLM from MAIN to apply.
EOF
      ;;
    *) err "fallback: unknown subcommand '$sub' (want list|set|remove)"; exit 2 ;;
  esac
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
    edit)     cmd_edit "$@" ;;
    remove)   cmd_remove "$@" ;;
    park)     cmd_park "$@" ;;
    unpark)   cmd_unpark "$@" ;;
    sync)     cmd_sync "$@" ;;
    fallback) cmd_fallback "$@" ;;
    superset) cmd_superset "$@" ;;
    -h|--help|help)
      cat <<'EOF'
vz-ai-stack.sh model — declarative model<->agent binding (installer/models.yml)
  model list [--json]              READ-ONLY catalog + live agent matrix
  model assign <agent> <model> [--dry-run] [--no-sync]    re-point one agent
  model assign all <model> [--dry-run] [--no-sync]        re-point EVERY agent (blanket)
  model discover                   READ-ONLY LM Studio library (LLMs + embeddings); loads nothing
  model add <lms-slug> [as <name>] [--dry-run] [--no-sync]   declare an LM Studio library LLM (no load)
  model add --runtime ollama --served <tag> [as local-<name>] [--big true|false]    declare an Ollama model (does NOT pull)
  model add --runtime openai-compat --served <id> --api-base <url> --key-env <VAR> [--rpm N] [--tpm N] as <name>
  model add --runtime openrouter --served <provider/model> [as <name>]              add an OpenRouter route (config.yaml; not agent-assignable)
  model edit <name> <field> <value> [--dry-run] [--no-sync]  edit a safe field: rpm|tpm|ttl|big|effort|note
  model remove <name> [--dry-run] [--no-sync]                delete a model (guarded) from models.yml + config.yaml
  model park <agent> [--dry-run] [--no-sync]                 disable an agent (renders the default sentinel; assignment kept)
  model unpark <agent> [--dry-run] [--no-sync]               re-enable a parked agent
  model sync [<agent>] [--dry-run] [--no-restart]
  model fallback list|set|remove ...   view/edit hand-curated LiteLLM failover chains (config.yaml policy)
  model superset [--json]          print the canonical scoped-key allowlist
EOF
      ;;
    *) err "model: unknown subcommand '$sub' (want list|assign|discover|add|edit|remove|park|unpark|sync|fallback|superset)"; exit 2 ;;
  esac
}

main "$@"
