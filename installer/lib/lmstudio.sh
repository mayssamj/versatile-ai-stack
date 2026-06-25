# lmstudio.sh — shared LM Studio (MLX) helpers used by Phase 25 + the model
# binding feature (lib/models.sh).
#
# Factored out of installer/phases/25_lmstudio.sh so the served-id discovery,
# the config.yaml yq-upsert, and the "load ONE big MLX model" RAM policy live in
# exactly one place. NO behaviour change for the LFM2.5 path — Phase 25 keeps its
# own slug/repo constants and just calls these.
#
# Source order: common.sh (log/ok/warn/err) must already be sourced. We source
# it defensively here so the lib is usable standalone.
[[ -z "${AI_STACK:-}" ]] && { echo "lmstudio.sh: AI_STACK unset" >&2; exit 2; }
[[ -n "${C_RESET+x}" ]] || source "$AI_STACK/installer/lib/common.sh"

LMS_PORT="${LMS_PORT:-1234}"
LMS_URL="${LMS_URL:-http://127.0.0.1:${LMS_PORT}}"
LMS_CONFIG="${LMS_CONFIG:-$AI_STACK/litellm/config.yaml}"

# RAM-budget preflight knobs (see lms_ram_preflight). Sized for a 24GB box.
LMS_RAM_HEADROOM_BYTES="${LMS_RAM_HEADROOM_BYTES:-5368709120}"   # 5 GiB reserved for macOS + apps
LMS_BIG_FALLBACK_BYTES="${LMS_BIG_FALLBACK_BYTES:-19327352832}"  # 18 GiB assumed when model size is unknown
LMS_MODEL_PAD_PCT="${LMS_MODEL_PAD_PCT:-15}"                     # +% on disk size for resident overhead (KV/framework)

# Resolve the lms CLI (bootstrapped at ~/.lmstudio/bin/lms, else in the app
# bundle). Echoes the path, or empty + returns 1.
lms_cli() {
  if [[ -x "$HOME/.lmstudio/bin/lms" ]]; then echo "$HOME/.lmstudio/bin/lms"; return 0; fi
  local appcli="/Applications/LM Studio.app/Contents/Resources/app/.webpack/lms"
  [[ -x "$appcli" ]] && { echo "$appcli"; return 0; }
  echo ""; return 1
}

# lms_server_up — is the OpenAI-compatible server answering on :1234?
lms_server_up() {
  curl -s -o /dev/null --max-time 4 "$LMS_URL/v1/models" 2>/dev/null
}

# lms_served_ids — print every non-embedding model id LM Studio is serving,
# one per line (empty if none / server down).
lms_served_ids() {
  curl -s --max-time 5 "$LMS_URL/v1/models" 2>/dev/null \
    | python3 -c 'import sys,json
try:
    d=json.load(sys.stdin)
except Exception:
    sys.exit(0)
for m in d.get("data",[]):
    i=m.get("id","")
    if i and "embed" not in i.lower():
        print(i)' 2>/dev/null
}

# ── READ-ONLY library catalog helpers (never load a model) ──────────────────
# These read the on-disk LM Studio model catalog (`lms ls --json`), which works
# with the server DOWN. They NEVER call `lms load` — declaration/discovery only.

# lms_library_json — READ-ONLY library catalog — never loads a model.
# Echo the raw `lms ls --json` array (on-disk catalog). Empty + return 1 if the
# CLI is missing or the catalog is empty/unreadable.
lms_library_json() {
  local lms; lms="$(lms_cli)" || { echo ''; return 1; }
  local out; out="$("$lms" ls --json 2>/dev/null || echo '')"
  [[ -n "$out" ]] || { echo ''; return 1; }
  echo "$out"
}

# lms_lib_has_slug <slug> — READ-ONLY library catalog — never loads a model.
# Return 0 iff some catalog entry has .modelKey == slug AND .type == 'llm'
# (EXACT string equality; no prefix/fuzzy). Return 1 if CLI/library unavailable.
lms_lib_has_slug() {
  local slug="$1"
  [[ -n "$slug" ]] || return 1
  local lib; lib="$(lms_library_json)" || return 1
  printf '%s' "$lib" | SLUG="$slug" python3 -c 'import sys,os,json
want=os.environ.get("SLUG","")
try: d=json.loads(sys.stdin.read())
except Exception: sys.exit(1)
for m in (d if isinstance(d,list) else []):
    if isinstance(m,dict) and m.get("modelKey")==want and m.get("type")=="llm":
        sys.exit(0)
sys.exit(1)' 2>/dev/null
}

# lms_lib_size_bytes <slug> — READ-ONLY library catalog — never loads a model.
# Echo the integer sizeBytes for the entry whose .modelKey == slug AND
# .type == 'llm'; echo nothing if not found or null.
lms_lib_size_bytes() {
  local slug="$1"
  [[ -n "$slug" ]] || { echo ''; return 0; }
  local lib; lib="$(lms_library_json)" || { echo ''; return 0; }
  printf '%s' "$lib" | SLUG="$slug" python3 -c 'import sys,os,json
want=os.environ.get("SLUG","")
try: d=json.loads(sys.stdin.read())
except Exception: sys.exit(0)
for m in (d if isinstance(d,list) else []):
    if isinstance(m,dict) and m.get("modelKey")==want and m.get("type")=="llm":
        sz=m.get("sizeBytes")
        if isinstance(sz,int): print(sz)
        break' 2>/dev/null || echo ''
}

# lms_served_first — the first served LLM id (Phase 25 compatibility helper).
lms_served_first() { lms_served_ids | head -1; }

# lms_is_served <served> — is exactly this served id currently served?
lms_is_served() {
  local want="$1"
  [[ -n "$want" ]] || return 1
  lms_served_ids | grep -qxF "$want"
}

# lms_register_model <model_name> <served> <runtime> [effort] [api_base] [key_env] [rpm] [tpm]
# yq-UPSERT one entry into litellm/config.yaml's model_list, keyed on
# model_name (replace litellm_params in place if it exists, else append).
# Atomic temp+mv. Returns 0 + prints CHANGED to stdout if the file's bytes
# changed, 0 + prints UNCHANGED otherwise; non-zero on hard failure.
#   ollama   => model: ollama_chat/<served>, api_base: http://ollama:11434
#   lmstudio => model: openai/<served>,      api_base: http://host.docker.internal:<LMS_PORT>/v1, api_key: lm-studio
#   meridian => model: openai/<served>,      api_base: http://host.docker.internal:<MERIDIAN_PORT>/v1,
#               api_key: meridian, extra_body: {effort: <effort>}  (Claude subscription, no API key)
#   openai   => model: openai/<served>,      api_key: os.environ/OPENAI_API_KEY [+ reasoning_effort: <effort>]
#               (metered GPT; api_key is a LITERAL env-ref sentinel, never shell-expanded)
#   codex-bridge => model: openai/<served>,  api_base: http://host.docker.internal:<CODEX_BRIDGE_PORT>/v1,
#               api_key: codex-bridge, rpm/tpm (int) [+ reasoning_effort: <effort>]  (ChatGPT subscription)
#   openai-compat => model: openai/<served>, api_base: <api_base from models.yml>,
#               api_key: os.environ/<KEY_ENV> [+ rpm/tpm int]  (generic metered cloud
#               route, e.g. Sakana Fugu; the ONLY runtime whose endpoint+key are DATA,
#               not hardcoded — so any OpenAI-compatible vendor is declarable)
lms_register_model() {
  local model_name="$1" served="$2" runtime="$3" effort="${4:-}" api_base="${5:-}" key_env="${6:-}" rpm="${7:-}" tpm="${8:-}"
  command -v yq >/dev/null 2>&1 || { err "yq not on PATH (Phase 00 installs it)"; return 1; }
  [[ -f "$LMS_CONFIG" ]] || { err "litellm config not found: $LMS_CONFIG"; return 1; }

  # Build the desired litellm_params as a yq expression input via env strenv.
  local tmp before after
  tmp="$(mktemp "${LMS_CONFIG}.XXXXXX")" || return 1
  cp "$LMS_CONFIG" "$tmp"
  before="$(shasum -a 256 "$LMS_CONFIG" | awk '{print $1}')"

  # Step A: append a bare {model_name: <MN>} entry IFF it is not already there
  # (add-only; legacy entries are never touched). any_c() with a single
  # condition matches each list element directly. The select-guard makes the
  # `with(...)` a no-op when the entry already exists, so this is idempotent.
  if ! MN="$model_name" yq -i 'with(select(.model_list | any_c(.model_name == strenv(MN)) | not); .model_list += [{"model_name": strenv(MN)}])' "$tmp"; then
    rm -f "$tmp"; err "yq append failed for $model_name"; return 1
  fi
  # Step B: set litellm_params IN PLACE on the matching entry (replace whatever
  # was there — this is how we converge a changed served id without restarting
  # on every run).
  if [[ "$runtime" == "ollama" ]]; then
    MN="$model_name" SV="$served" yq -i '(.model_list[] | select(.model_name == strenv(MN)) | .litellm_params) = {"model": "ollama_chat/" + strenv(SV), "api_base": "http://ollama:11434"}' "$tmp" \
      || { rm -f "$tmp"; err "yq set-params failed for $model_name"; return 1; }
  elif [[ "$runtime" == "meridian" ]]; then
    # Claude subscription via the Meridian host daemon. effort -> extra_body.effort
    # (LiteLLM merges it into the request body -> Meridian reads body.effort ->
    # Agent SDK query({effort}); verified on the wire). Dummy api_key (Meridian
    # holds the real OAuth). Default effort to the model id default if unset.
    MN="$model_name" SV="$served" MP="${MERIDIAN_PORT:-3456}" EF="${effort:-high}" yq -i '(.model_list[] | select(.model_name == strenv(MN)) | .litellm_params) = {"model": "openai/" + strenv(SV), "api_base": "http://host.docker.internal:" + strenv(MP) + "/v1", "api_key": "meridian", "extra_body": {"effort": strenv(EF)}}' "$tmp" \
      || { rm -f "$tmp"; err "yq set-params failed for $model_name"; return 1; }
  elif [[ "$runtime" == "openai" ]]; then
    # Metered OpenAI API. api_key MUST stay the literal env-ref sentinel
    # "os.environ/OPENAI_API_KEY" (LiteLLM resolves it at load) — NEVER a shell
    # expansion of the real key. Optional effort -> reasoning_effort (a recognized
    # OpenAI param; drop_params:true drops it where unsupported).
    MN="$model_name" SV="$served" yq -i '(.model_list[] | select(.model_name == strenv(MN)) | .litellm_params) = {"model": "openai/" + strenv(SV), "api_key": "os.environ/OPENAI_API_KEY"}' "$tmp" \
      || { rm -f "$tmp"; err "yq set-params failed for $model_name"; return 1; }
    if [[ -n "$effort" ]]; then
      MN="$model_name" EF="$effort" yq -i '(.model_list[] | select(.model_name == strenv(MN)) | .litellm_params.reasoning_effort) = strenv(EF)' "$tmp" \
        || { rm -f "$tmp"; err "yq set reasoning_effort failed for $model_name"; return 1; }
    fi
  elif [[ "$runtime" == "codex-bridge" ]]; then
    # GPT on the ChatGPT subscription via the codex-bridge host daemon
    # (bin/start-codex-bridge.sh). Dummy api_key (the bridge holds the OAuth).
    # rpm/tpm are INTEGER literals (a strenv string would churn the SHA -> false
    # CHANGED -> needless LiteLLM restart every sync). Optional effort ->
    # reasoning_effort, but its passthrough to the Codex backend is UNVERIFIED
    # (see the models.yml note) — the metered `openai` runtime is the verified one.
    MN="$model_name" SV="$served" CP="${CODEX_BRIDGE_PORT:-3457}" yq -i '(.model_list[] | select(.model_name == strenv(MN)) | .litellm_params) = {"model": "openai/" + strenv(SV), "api_base": "http://host.docker.internal:" + strenv(CP) + "/v1", "api_key": "codex-bridge"}' "$tmp" \
      || { rm -f "$tmp"; err "yq set-params failed for $model_name"; return 1; }
    if [[ -n "$rpm" ]]; then
      MN="$model_name" RP="$rpm" yq -i '(.model_list[] | select(.model_name == strenv(MN)) | .litellm_params.rpm) = (strenv(RP) | tonumber)' "$tmp" \
        || { rm -f "$tmp"; err "yq set rpm failed for $model_name"; return 1; }
    fi
    if [[ -n "$tpm" ]]; then
      MN="$model_name" TP="$tpm" yq -i '(.model_list[] | select(.model_name == strenv(MN)) | .litellm_params.tpm) = (strenv(TP) | tonumber)' "$tmp" \
        || { rm -f "$tmp"; err "yq set tpm failed for $model_name"; return 1; }
    fi
    if [[ -n "$effort" ]]; then
      MN="$model_name" EF="$effort" yq -i '(.model_list[] | select(.model_name == strenv(MN)) | .litellm_params.reasoning_effort) = strenv(EF)' "$tmp" \
        || { rm -f "$tmp"; err "yq set reasoning_effort failed for $model_name"; return 1; }
    fi
  elif [[ "$runtime" == "openai-compat" ]]; then
    # Generic OpenAI-compatible cloud route (e.g. Sakana Fugu). UNLIKE every other
    # runtime the endpoint is NOT hardcoded — api_base + key_env are DATA from
    # models.yml. api_key stays the LITERAL "os.environ/<KEY_ENV>" sentinel (LiteLLM
    # resolves it at load) — NEVER a shell expansion of the real secret. The key MUST
    # also be in bin/start-litellm.sh's -e allowlist (env is injected at container
    # CREATE — a NEW key needs `start-litellm.sh --recreate`, not `docker restart`).
    [[ -n "$api_base" ]] || { rm -f "$tmp"; err "openai-compat $model_name: missing api_base"; return 1; }
    [[ -n "$key_env"  ]] || { rm -f "$tmp"; err "openai-compat $model_name: missing key_env"; return 1; }
    MN="$model_name" SV="$served" AB="$api_base" KE="$key_env" yq -i '(.model_list[] | select(.model_name == strenv(MN)) | .litellm_params) = {"model": "openai/" + strenv(SV), "api_base": strenv(AB), "api_key": "os.environ/" + strenv(KE)}' "$tmp" \
      || { rm -f "$tmp"; err "yq set-params failed for $model_name"; return 1; }
    # Optional rpm/tpm runaway-cost backstop for a METERED route — INTEGER literals
    # (a string churns the SHA -> false CHANGED -> needless restart). Rendered only
    # when declared in models.yml; tune to your plan (not a per-usage quota).
    if [[ -n "$rpm" ]]; then
      MN="$model_name" RP="$rpm" yq -i '(.model_list[] | select(.model_name == strenv(MN)) | .litellm_params.rpm) = (strenv(RP) | tonumber)' "$tmp" \
        || { rm -f "$tmp"; err "yq set rpm failed for $model_name"; return 1; }
    fi
    if [[ -n "$tpm" ]]; then
      MN="$model_name" TP="$tpm" yq -i '(.model_list[] | select(.model_name == strenv(MN)) | .litellm_params.tpm) = (strenv(TP) | tonumber)' "$tmp" \
        || { rm -f "$tmp"; err "yq set tpm failed for $model_name"; return 1; }
    fi
  else
    MN="$model_name" SV="$served" PRT="$LMS_PORT" yq -i '(.model_list[] | select(.model_name == strenv(MN)) | .litellm_params) = {"model": "openai/" + strenv(SV), "api_base": "http://host.docker.internal:" + strenv(PRT) + "/v1", "api_key": "lm-studio"}' "$tmp" \
      || { rm -f "$tmp"; err "yq set-params failed for $model_name"; return 1; }
  fi

  after="$(shasum -a 256 "$tmp" | awk '{print $1}')"
  if [[ "$before" == "$after" ]]; then
    rm -f "$tmp"
    echo "UNCHANGED"
    return 0
  fi
  mv -f "$tmp" "$LMS_CONFIG"
  echo "CHANGED"
  return 0
}

# ── RAM-budget preflight ─────────────────────────────────────────────────────
# Prevents the OrbStack-cap + big-MLX over-commit that swap-thrash-LOCKED the Mac
# (2026-06-01). All arithmetic is errexit/pipefail safe (both callers run
# `set -Eeuo pipefail`; lib/models.sh adds inherit_errexit): comparisons live ONLY
# inside `if (( ))`, every pipeline ends in `|| echo 0`, and the python readers
# drain stdin fully before exiting (no SIGPIPE abort).
_ram_total_bytes() {
  local t; t="$(sysctl -n hw.memsize 2>/dev/null || echo 0)"
  [[ "$t" =~ ^[0-9]+$ ]] || t=0
  echo "$t"
}
# OrbStack's reserved VM memory (a hard floor we must subtract). Falls back to a
# SAFE estimate (larger of 8GiB or half of RAM) when the config can't be read.
_orbstack_cap_bytes() {
  local f="$HOME/.orbstack/vmconfig.json" mib="" total
  if [[ -f "$f" ]]; then
    mib="$(python3 -c 'import json,sys
try: print(int(json.load(open(sys.argv[1])).get("memory_mib",0)))
except Exception: pass' "$f" 2>/dev/null || echo "")"
  fi
  if [[ "$mib" =~ ^[0-9]+$ ]] && (( mib > 0 )); then echo $(( mib * 1048576 )); return 0; fi
  total="$(_ram_total_bytes)"
  if (( total > 0 )) && (( total / 2 > 8589934592 )); then echo $(( total / 2 )); else echo 8589934592; fi
}
# On-disk size of a served model id, from the LM Studio catalog (works server-DOWN).
# EXACT modelKey/indexedModelIdentifier match (the disk list holds both `qwen/qwen3.6-27b`
# and a separate `qwen3.6-27b-mlx`, so substring matching would mis-resolve).
lms_model_size_bytes() {
  local served="$1" lms sz
  lms="$(lms_cli)"; [[ -n "$lms" ]] || { echo 0; return 0; }
  sz="$("$lms" ls --json 2>/dev/null | SERVED="$served" python3 -c 'import sys,os,json
want=os.environ.get("SERVED","")
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print(0); sys.exit(0)
out=0
for m in (d if isinstance(d,list) else []):
    if isinstance(m,dict) and (m.get("modelKey")==want or m.get("indexedModelIdentifier")==want):
        try: out=int(m.get("sizeBytes") or 0)
        except Exception: out=0
        break
print(out)' 2>/dev/null || echo 0)"
  [[ "$sz" =~ ^[0-9]+$ ]] || sz=0
  echo "$sz"
}
# lms_ram_preflight <served> — return 1 (refuse) if loading would over-commit RAM.
# Degrades OPEN (returns 0) on any measurement failure. Bypass: LMS_SKIP_RAM_PREFLIGHT=1.
lms_ram_preflight() {
  local served="$1" total cap size head padded
  [[ -n "${LMS_SKIP_RAM_PREFLIGHT:-}" ]] && { note "RAM preflight bypassed (LMS_SKIP_RAM_PREFLIGHT) for $served"; return 0; }
  total="$(_ram_total_bytes)"
  if (( total <= 0 )); then note "RAM preflight: cannot read hw.memsize; skipping for $served"; return 0; fi
  cap="$(_orbstack_cap_bytes)";       [[ "$cap"  =~ ^[0-9]+$ ]] || cap=0
  size="$(lms_model_size_bytes "$served")"; [[ "$size" =~ ^[0-9]+$ ]] || size=0
  if (( size <= 0 )); then size="$LMS_BIG_FALLBACK_BYTES"; fi
  padded=$(( size + size * LMS_MODEL_PAD_PCT / 100 ))
  head="$LMS_RAM_HEADROOM_BYTES"
  local _g; _g() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1073741824}'; }
  if (( cap + padded + head > total )); then
    warn "RAM preflight: refusing to load $served — OrbStack cap $(_g "$cap")GiB + model $(_g "$padded")GiB (padded) + headroom $(_g "$head")GiB exceeds total $(_g "$total")GiB RAM."
    warn "Lower OrbStack's memory cap (~/.orbstack/vmconfig.json) or pick a smaller model; the agent falls back to the ollama default (local-gemma4). Override: LMS_SKIP_RAM_PREFLIGHT=1."
    return 1
  fi
  note "RAM preflight OK for $served (cap+model+headroom within $(_g "$total")GiB)."
  return 0
}

# lms_load_big <served> <ttl>
# Env: LMS_RAM_HEADROOM_BYTES, LMS_BIG_FALLBACK_BYTES, LMS_MODEL_PAD_PCT, LMS_SKIP_RAM_PREFLIGHT.
# Enforce the one-big-MLX-at-a-time RAM policy on a 24GB box:
#   1. If <served> is already served, return 0 (idempotent).
#   2. Unload any OTHER currently-loaded model (lms ps -> lms unload) so the two
#      ~17GB MLX models never coexist.
#   3. lms load <served> --identifier <served> --ttl <ttl> -y
#   4. Verify <served> now shows in /v1/models (returns non-zero if not).
# Best-effort, non-fatal: returns non-zero so the caller can availability-gate.
lms_load_big() {
  local served="$1" ttl="${2:-1800}"
  local lms; lms="$(lms_cli)"
  [[ -n "$lms" ]] || { warn "lms CLI not found — cannot load $served"; return 1; }
  lms_server_up || { warn "LM Studio server not up on $LMS_URL — cannot load $served"; return 1; }

  if lms_is_served "$served"; then
    note "LM Studio already serving $served"
    return 0
  fi

  # RAM-budget gate: refuse a load that would over-commit RAM (caller falls back
  # to the ollama default). Runs AFTER the already-served check so a resident
  # model is never spuriously blocked, and BEFORE we unload anything.
  if ! lms_ram_preflight "$served"; then return 1; fi

  # Unload OTHER loaded models so only one big MLX model is resident.
  local other
  while IFS= read -r other; do
    [[ -z "$other" ]] && continue
    [[ "$other" == "$served" ]] && continue
    log "Unloading other LM Studio model '$other' (one-big-MLX RAM policy)..."
    "$lms" unload "$other" >/dev/null 2>&1 || "$lms" unload --all >/dev/null 2>&1 || true
  done < <(lms_served_ids)

  log "Loading $served into LM Studio (ttl=${ttl}s)..."
  "$lms" load "$served" --identifier "$served" --ttl "$ttl" -y >/dev/null 2>&1 \
    || "$lms" load "$served" --ttl "$ttl" -y >/dev/null 2>&1 \
    || { warn "lms load $served returned non-zero"; }
  sleep 2

  if lms_is_served "$served"; then
    ok "LM Studio serving $served"
    return 0
  fi
  warn "LM Studio did not surface '$served' in /v1/models after load (still loading? wrong id?)"
  return 1
}

# print_inference_hint — end-of-install/status/doctor reminder of the inference
# runtimes + how to activate them. errexit/pipefail safe (probes in if-guards;
# always returns 0). Local models route through LiteLLM (http://litellm:4000).
print_inference_hint() {
  local ol="down" lm="down" cli
  if curl -s -o /dev/null --max-time 2 "http://127.0.0.1:11434/api/version" 2>/dev/null; then ol="up"; fi
  if lms_server_up; then lm="up"; fi
  cli="$(lms_cli 2>/dev/null || true)"; [[ -n "$cli" ]] || cli="$HOME/.lmstudio/bin/lms"
  printf '\nInference runtimes (activate at least one — local models route through LiteLLM :4000):\n'
  printf '  Ollama    [%s]  default = local-gemma4.  start: brew services start ollama\n' "$ol"
  printf '  LM Studio [%s]  opt-in MLX = local-qwen-heavy-fast / local-gemma4-12b.  start: vz-ai-stack.sh start lmstudio\n' "$lm"
  if [[ "$lm" == "down" ]]; then
    printf '            (LM Studio-bound agents fall back to the ollama default until it is up)\n'
  fi
  return 0
}
