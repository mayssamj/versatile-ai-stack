# Model<->agent binding (installer/models.yml) is valid and rendered everywhere.
#
# Asserts (WARN-skip / advisory where appropriate — never red for an opt-in
# service that is simply down):
#   1. models.yml is valid + every assignment/default resolves to a declared model.
#   2. Every models.yml model is in litellm/config.yaml AND is servable — WITHOUT
#      cold-starting a lazy local model OR billing a metered/subscription one on a
#      routine run (directive: doctor must not cold-start). ollama: PULLED
#      (`ollama list`) + configured, real ping only if already resident (`ollama
#      ps`). remote (openai/codex-bridge): presence in LiteLLM's live /v1/models
#      (a fallback-proof "wired + served" signal). meridian: presence-only (bills
#      subscription). lmstudio: advisory when :1234 is down (NOT red). A full
#      inference ping of every cold/remote model is opt-in: MODELS_BINDING_DEEP_CHECK=1.
#   3. DRIFT: rendered == declared (availability-gated) across ALL surfaces:
#      the 9 Hermes profiles (exec-grep; NO key echo), Pi (PI_DEFAULT_MODEL +
#      bin/pi), DeerFlow (config.yaml reasoning tier), ACE/RLM (.env).
#   4. ALLOWLIST COVERAGE: for each agent with key_env, GET /v1/models under that
#      key includes the assigned (effective) model. NEVER prints a key.
#
# WARN-skip (return 0) when LiteLLM is down or the hermes sandbox isn't Ready.
# Fix hint: 'bash vz-ai-stack.sh model sync'.
CHECKS+=(models_binding)
CHECK_TITLE[models_binding]="Model<->agent binding (models.yml) valid + rendered (vz-ai-stack.sh model sync)"

_mb_yml() { echo "$AI_STACK/installer/models.yml"; }
_mb_cfg() { echo "$AI_STACK/litellm/config.yaml"; }

_mb_litellm_up() { curl -sf --max-time 3 http://litellm:4000/health/readiness >/dev/null 2>&1; }
_mb_lms_up()     { curl -s -o /dev/null --max-time 3 http://127.0.0.1:1234/v1/models 2>/dev/null; }
_mb_meridian_up() { curl -sf --max-time 3 "http://127.0.0.1:${MERIDIAN_PORT:-3456}/v1/models" -H "Authorization: Bearer x" >/dev/null 2>&1; }

# One master-key chat_ping. Echoes the HTTP code (or "000" on connect/timeout).
# $1=model  $2=master-key  $3=max-time(s, default 30). max_tokens is 16 (NOT 1):
# GPT-5.x / reasoning models spend the output budget on hidden reasoning tokens, so
# max_tokens:1 → HTTP 400 "Could not finish … max_tokens reached" (verified on the
# metered openai route; ollama/codex-bridge tolerate 1, but 16 is uniformly safe —
# confirmed no regression). 16 is a liveness floor only; the response body is
# discarded. NOTE: do NOT add `|| echo 000`
# — curl's %{http_code} already emits 000 on timeout, so the old `|| echo 000`
# produced "000000" (a doubled string that no '== 200' test could ever match and
# that rendered as a confusing false failure). The `|| true` is REQUIRED: under
# doctor's set -e + inherit_errexit, a bare `code="$(curl …)"` ABORTS the check
# when curl exits non-zero (timeout/connection refused) — `|| true` makes the
# substitution exit 0 (curl's -w still printed "000"); `${code:-000}` covers the
# rare empty/binary-error case. (`|| true` not `|| echo 000` — the latter doubles.)
_mb_chat_ping() {
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time "${3:-30}" \
    http://litellm:4000/v1/chat/completions -H "Authorization: Bearer $2" \
    -H 'Content-Type: application/json' \
    -d "{\"model\":\"$1\",\"messages\":[{\"role\":\"user\",\"content\":\"ping\"}],\"max_tokens\":16}" 2>/dev/null || true)"
  printf '%s' "${code:-000}"
}

_mb_osh() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""; fi
}
_mb_hermes_ready() {
  local osh; osh="$(_mb_osh)"; [[ -n "$osh" ]] || return 1
  "$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk 'NR>1 && $1=="hermes-fleet-v1" && $NF=="Ready" {ok=1} END{exit !ok}'
}

# Effective (availability-gated) model for an agent, computed the same way
# lib/models.sh does: lmstudio slug only when :1234 up AND served, else default.
_mb_effective() {
  local agent="$1" yml; yml="$(_mb_yml)"
  local declared default rt served
  declared="$(yq -r ".assignments.\"$agent\"" "$yml" 2>/dev/null)"
  default="$(yq -r '.default' "$yml" 2>/dev/null)"
  rt="$(yq -r ".models.\"$declared\".runtime" "$yml" 2>/dev/null)"
  # meridian: availability-gate on the Meridian daemon (mirrors lib/models.sh).
  if [[ "$rt" == "meridian" ]]; then
    if _mb_meridian_up && yq -e ".model_list[] | select(.model_name == \"$declared\")" "$(_mb_cfg)" >/dev/null 2>&1; then
      echo "$declared"; return
    fi
    echo "$default"; return
  fi
  # openai-compat: availability-gate on its .env key (mirrors lib/models.sh
  # resolve_effective) — render the declared slug only when key_env is present, else
  # the default. Without this, a keyless box renders `default` (gated) while this
  # function returns `declared`, tripping a false DRIFT/RED in the check below.
  # NOTE: the metered `openai` (OPENAI_API_KEY) + `codex-bridge` (daemon) runtimes
  # similarly under-gate here (fall through to `declared`) — harmless today since none
  # is a rendered default; fix likewise if one ever becomes one.
  if [[ "$rt" == "openai-compat" ]]; then
    local kenv; kenv="$(yq -r ".models.\"$declared\".key_env" "$yml" 2>/dev/null)"
    if [[ -n "$kenv" && "$kenv" != "null" && -n "$(get_env "$kenv" '')" ]] \
       && yq -e ".model_list[] | select(.model_name == \"$declared\")" "$(_mb_cfg)" >/dev/null 2>&1; then
      echo "$declared"; return
    fi
    echo "$default"; return
  fi
  if [[ "$rt" != "lmstudio" ]]; then echo "$declared"; return; fi
  served="$(yq -r ".models.\"$declared\".served" "$yml" 2>/dev/null)"
  if _mb_lms_up && yq -e ".model_list[] | select(.model_name == \"$declared\")" "$(_mb_cfg)" >/dev/null 2>&1; then
    # confirm LiteLLM serves it under the master key
    local key; key="$(get_env LITELLM_MASTER_KEY '')"
    if [[ -n "$key" ]] && litellm_master_curl -s --max-time 5 http://litellm:4000/v1/models 2>/dev/null \
         | python3 -c 'import sys,json; w=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if any(m.get("id")==w for m in d.get("data",[])) else 1)' "$declared"; then
      echo "$declared"; return
    fi
  fi
  echo "$default"
}

# key covers model? (never prints the key)
_mb_key_covers() {
  local key="$1" want="$2"
  [[ -n "$key" ]] || return 1
  curl -s --max-time 5 http://litellm:4000/v1/models -H "Authorization: Bearer $key" 2>/dev/null \
    | python3 -c 'import sys,json; w=sys.argv[1]
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
sys.exit(0 if any(m.get("id")==w for m in d.get("data",[])) else 1)' "$want"
}

models_binding_diagnose() {
  local yml cfg; yml="$(_mb_yml)"; cfg="$(_mb_cfg)"
  command -v yq >/dev/null 2>&1 || { echo "yq not on PATH"; return 1; }
  [[ -f "$yml" ]] || { echo "  (installer/models.yml absent — feature not in use [skip])"; return 0; }

  # (1) Validate via the lib (fail-closed). Reuse lib/models.sh's validate by
  # running `model list` quietly — it exits 2 only on invalid models.yml.
  if ! bash "$AI_STACK/installer/lib/models.sh" list >/dev/null 2>&1; then
    echo "models.yml invalid or unresolvable (run: bash vz-ai-stack.sh model list)"
    return 1
  fi

  # WARN-skip when LiteLLM is down (avoid cascade).
  if ! _mb_litellm_up; then
    echo "  (LiteLLM not responding — skipping binding checks; see check 11 + Phase 01)"
    return 0
  fi

  local lms_up=0; _mb_lms_up && lms_up=1
  local master; master="$(get_env LITELLM_MASTER_KEY '' 2>/dev/null || echo '')"
  local fail=0 advisory=""

  # Snapshot ollama's PULLED (`ollama list`) + LOADED (`ollama ps`) model names
  # ONCE — both are metadata queries: no inference, no cold-start. The per-model
  # loop uses these to verify ollama servability WITHOUT loading weights
  # (directive: doctor must not cold-start models). `|| true` inside the pipe so a
  # flaky ollama can never abort the check under set -e / inherit_errexit.
  local _ollama_pulled="" _ollama_loaded="" _ollama_cli=0
  if command -v ollama >/dev/null 2>&1; then
    _ollama_cli=1
    _ollama_pulled="$( (ollama list 2>/dev/null || true) | awk 'NR>1{print $1}' )"
    _ollama_loaded="$( (ollama ps   2>/dev/null || true) | awk 'NR>1{print $1}' )"
  fi

  # The model set LiteLLM ACTUALLY serves (master key), fetched ONCE — the routine
  # "wired + live-served" signal for remote models: no inference, no cold-start, no
  # metered/subscription token burn, and (unlike a chat_ping) it CANNOT be masked by
  # a LiteLLM fallback group. A real inference ping is OPT-IN via
  # MODELS_BINDING_DEEP_CHECK=1 — consistent with check 55 (CODEX_BRIDGE_DEEP_CHECK)
  # and meridian (never pinged). `|| true` so a hiccup never aborts the check.
  local _served_models=""
  if [[ -n "$master" ]]; then
    _served_models="$( (litellm_master_curl -s --max-time 8 http://litellm:4000/v1/models 2>/dev/null || true) \
      | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print("\n".join(m.get("id","") for m in d.get("data",[])))' 2>/dev/null || true )"
  fi
  # Distinguish "couldn't read the list" (INCONCLUSIVE — advise, never silently
  # pass) from "model genuinely absent" (red). LiteLLM is UP here (checked above),
  # so an empty list means the /v1/models fetch failed or returned non-JSON (e.g. a
  # proxy 502), NOT that zero models are served. Without this, a broken /v1/models
  # would green every remote/no-cli model by default.
  local _served_ok=0; [[ -n "$_served_models" ]] && _served_ok=1
  if [[ "$_served_ok" != "1" ]]; then
    advisory="${advisory}    (advisory) could not read LiteLLM /v1/models (master key) — remote/no-cli model presence checks skipped this run (inconclusive, not failed)\n"
  fi
  local _deep="${MODELS_BINDING_DEEP_CHECK:-0}"
  local _default_model; _default_model="$(yq -r '.default' "$yml" 2>/dev/null)"

  # (2) Every models.yml model in config.yaml + servable WITHOUT cold-starting or
  #     billing on a routine run: ollama = pulled + warm-only ping; remote =
  #     live-served presence (deep ping opt-in); meridian/lmstudio-down = advisory.
  local m rt
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    rt="$(yq -r ".models.\"$m\".runtime" "$yml" 2>/dev/null)"
    if ! yq -e ".model_list[] | select(.model_name == \"$m\")" "$cfg" >/dev/null 2>&1; then
      echo "model '$m' missing from litellm/config.yaml (run: bash vz-ai-stack.sh model sync)"
      fail=1; continue
    fi
    # meridian (Claude subscription): NEVER chat_ping — it bills subscription
    # tokens and needs the daemon up. Presence in config.yaml (checked above) is
    # the green signal; liveness is covered by check 41. Advisory if down.
    if [[ "$rt" == "meridian" ]]; then
      _mb_meridian_up || advisory="${advisory}    (advisory) meridian model '$m' — Meridian daemon down; agents availability-gate to the default\n"
      continue
    fi
    # LM Studio DOWN → its models are advisory-down BY DEFINITION; do NOT ping
    # (skips ~5s/model of dead connect, and never JIT-loads an LM Studio model).
    if [[ "$rt" == "lmstudio" && "$lms_up" != "1" ]]; then
      advisory="${advisory}    (advisory) lmstudio model '$m' not servable — LM Studio :1234 down (ping skipped)\n"
      continue
    fi
    # ollama is a LAZY local runtime: a chat_ping COLD-LOADS the weights (9.6GB
    # gemma here → 20-150s/model with the old warm-retry). Directive: doctor must
    # NOT cold-start models. So routine "servable" = PULLED (`ollama list`) +
    # present in config.yaml (checked above); we chat_ping ONLY when the model is
    # already RESIDENT (`ollama ps`) — a warm ping is ~free and gives the real
    # end-to-end signal — and we NEVER `ollama stop` (the old code evicted the
    # user's warm working set every run). ORDER MATTERS: check LOADED before
    # NOT-PULLED — `ollama list`/`ollama ps` are two non-atomic snapshots and a
    # model resident in `ps` is servable by definition. The documented "pulled but
    # runner broken" (missing llama-server → HTTP 500) gotcha can't be caught
    # without a load, so we flag it as an advisory for the fleet DEFAULT model when
    # it's cold; the warm path catches it once loaded, and a full cold ping is
    # available via MODELS_BINDING_DEEP_CHECK=1. No ollama CLI to introspect → use
    # the same live-served presence signal as remote (still no cold-start).
    # ($m/served are config-controlled identifiers with no JSON-unsafe chars today;
    # if that changes, _mb_chat_ping's body would need jq-escaping.)
    if [[ "$rt" == "ollama" ]]; then
      local served wcode _oll_to=30
      served="$(yq -r ".models.\"$m\".served" "$yml" 2>/dev/null)"
      [[ "$_deep" == "1" ]] && _oll_to=120
      if [[ "$_ollama_cli" != "1" ]]; then
        # No CLI to tell warm from cold → live-served presence (no cold-start).
        if [[ "$_served_ok" == "1" ]] && ! printf '%s\n' "$_served_models" | grep -qxF "$m"; then
          echo "model '$m' in models.yml + config.yaml but NOT served by LiteLLM /v1/models (run: bash vz-ai-stack.sh model sync, then restart litellm)"
          fail=1
        fi
      elif printf '%s\n' "$_ollama_loaded" | grep -qxF "$served" || [[ "$_deep" == "1" ]]; then
        # Already RESIDENT (warm, ~free) OR deep check (opt-in, may cold-load): real ping.
        wcode="$(_mb_chat_ping "$m" "$master" "$_oll_to")"
        [[ "$wcode" == "200" ]] || { echo "ollama model '$m' chat_ping returned HTTP $wcode (expected 200)"; fail=1; }
      elif ! printf '%s\n' "$_ollama_pulled" | grep -qxF "$served" \
           && ! printf '%s\n' "$_ollama_pulled" | grep -qxF "${served}:latest"; then
        echo "ollama model '$m' (served '$served') not pulled — run: ollama pull $served"
        fail=1
      elif [[ "$m" == "$_default_model" ]]; then
        # Pulled but cold (routine): green WITHOUT cold-starting. Flag ONLY the fleet
        # DEFAULT so a broken runner on the always-on model stays visible.
        advisory="${advisory}    (advisory) ollama default '$m' pulled but not warm — runner health unverified (not cold-started per directive; MODELS_BINDING_DEEP_CHECK=1 forces a full ping)\n"
      fi
      continue
    fi
    # Remote / managed runtimes (openai, codex-bridge, lmstudio when UP). A routine
    # chat_ping bills a metered/subscription key AND — for any model with a LiteLLM
    # fallback group — silently tests the FALLBACK, not the model (a false signal:
    # e.g. gpt-5.5 / the -sub routes mask a primary 400). So routine only verifies
    # the model is WIRED + LIVE-SERVED by LiteLLM (the _served_models snapshot); a
    # real inference ping is OPT-IN via MODELS_BINDING_DEEP_CHECK=1 — the same
    # precedent as check 55 (CODEX_BRIDGE_DEEP_CHECK) and meridian (never pinged).
    if [[ "$_deep" != "1" ]]; then
      if [[ "$_served_ok" == "1" ]] && ! printf '%s\n' "$_served_models" | grep -qxF "$m"; then
        echo "model '$m' in models.yml + config.yaml but NOT served by LiteLLM /v1/models (run: bash vz-ai-stack.sh model sync, then restart litellm)"
        fail=1
      fi
      continue
    fi
    # Deep check (opt-in): real chat_ping (max_tokens 16 — reasoning models reject 1).
    # LiteLLM is UP (checked above), so a 000 is the UPSTREAM not answering within the
    # budget — a slow "pro"/max-accuracy model or a slow multi-hop fallback chain
    # (e.g. gpt-5.5-pro → … → claude, ~76s) → advisory, not red. A real wiring /
    # credential fault (bad key / bad slug) returns a definite 4xx/5xx → red.
    local code
    code="$(_mb_chat_ping "$m" "$master" 30)"
    if [[ "$code" == "200" ]]; then
      :   # servable
    elif [[ "$code" == "000" ]]; then
      advisory="${advisory}    (advisory) model '$m' (runtime $rt) wired but no response within 30s in deep check (slow/pro upstream or fallback chain)\n"
    else
      echo "model '$m' chat_ping returned HTTP $code (expected 200)"
      fail=1
    fi
  done < <(yq -r '.models | keys | .[]' "$yml")

  # (3)+(4) DRIFT + ALLOWLIST coverage across every agent surface.
  local hermes_ready=0; _mb_hermes_ready && hermes_ready=1
  local a kind keyenv eff rendered
  # Compute the derived superset ONCE (was re-forking models.sh per agent — slow
  # on a CPU-capped box). The inner drift guard reads this cached value.
  local _mb_superset; _mb_superset="$(bash "$AI_STACK/installer/lib/models.sh" superset 2>/dev/null || true)"
  while IFS= read -r a; do
    [[ -z "$a" ]] && continue
    kind="$(yq -r ".kinds.\"$a\".kind" "$yml" 2>/dev/null)"
    keyenv="$(yq -r ".kinds.\"$a\".key_env // \"\"" "$yml" 2>/dev/null)"
    eff="$(_mb_effective "$a")"

    # ALLOWLIST coverage (skip if no key_env; deerflow uses master key).
    if [[ -n "$keyenv" && "$keyenv" != "null" ]]; then
      local kv; kv="$(get_env "$keyenv" '' 2>/dev/null || echo '')"
      if [[ -z "$kv" ]]; then
        echo "agent '$a' key_env $keyenv missing from .env (run the phase or: bash vz-ai-stack.sh model sync)"
        fail=1
      else
        if ! _mb_key_covers "$kv" "$eff"; then
          echo "agent '$a' scoped key does NOT allow its effective model '$eff' (run: bash vz-ai-stack.sh model sync)"
          fail=1
        fi
        # Superset-drift guard (review #6): scoped keys are minted with the FULL
        # DERIVED superset (see 'vz-ai-stack.sh model superset'), so a phase/bridge
        # that hardcoded a stale/narrow allowlist is caught HERE rather than
        # silently 403-ing a future `model assign`/`model add`. Only assert for
        # superset members actually registered in config.yaml.
        local _cm
        while IFS= read -r _cm; do
          [[ -z "$_cm" ]] && continue
          if yq -e ".model_list[] | select(.model_name == \"$_cm\")" "$cfg" >/dev/null 2>&1 \
             && ! _mb_key_covers "$kv" "$_cm"; then
            echo "agent '$a' scoped key $keyenv missing '$_cm' (superset drift — run: bash vz-ai-stack.sh model sync)"
            fail=1
          fi
        done < <(printf '%s\n' "$_mb_superset")
      fi
    fi

    # DRIFT: rendered == effective.
    rendered=""
    case "$kind" in
      pi)  rendered="$(get_env PI_DEFAULT_MODEL '' 2>/dev/null || echo '')" ;;
      ace) rendered="$(get_env ACE_DEFAULT_MODEL '' 2>/dev/null || echo '')" ;;
      rlm) rendered="$(get_env RLM_MODEL '' 2>/dev/null || echo '')" ;;
      deerflow)
        local df="$AI_STACK/deer-flow/config.yaml"
        [[ -f "$df" ]] && rendered="$(yq -r '.models[] | select(.name == "local-heavy") | .model' "$df" 2>/dev/null | head -1)" ;;
      hermes-profile)
        if [[ "$hermes_ready" == "1" ]]; then
          local osh profile; osh="$(_mb_osh)"; profile="$(yq -r ".kinds.\"$a\".profile" "$yml" 2>/dev/null)"
          rendered="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty -- bash -c \
            "grep -E '^[[:space:]]*model:' \"\$HOME/.hermes/profiles/$profile/config.yaml\" 2>/dev/null | head -1 | awk '{print \$2}'" \
            2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
        fi ;;
    esac
    # Only flag DRIFT when we could actually read a rendered value AND the
    # surface exists. Unreadable (sandbox not ready / .env not present) => skip.
    if [[ -n "$rendered" && "$rendered" != "$eff" ]]; then
      echo "agent '$a' DRIFT: rendered='$rendered' but declared/effective='$eff' (run: bash vz-ai-stack.sh model sync)"
      fail=1
    fi
  done < <(yq -r '.assignments | keys | .[]' "$yml")

  if [[ -n "$advisory" ]]; then printf '%b' "$advisory"; fi
  (( fail == 0 )) || return 1
  echo "  (models.yml valid; every model wired + servable; no drift; scoped keys cover assignments)"
  return 0
}

models_binding_fix() {
  warn "Re-render every agent + the LiteLLM model_list from installer/models.yml:"
  warn "    bash $AI_STACK/vz-ai-stack.sh model sync"
  return 1
}
