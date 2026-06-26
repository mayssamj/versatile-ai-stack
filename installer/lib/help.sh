#!/usr/bin/env bash
# help.sh — per-service `help` for the AI-stack CLI.
#
#   vz-ai-stack.sh help                      overview + pointer to `help services`
#   vz-ai-stack.sh help services             list services that have help prose
#   vz-ai-stack.sh help <service|alias>      WHAT · HOW IT'S CONFIGURED · HOW TO USE
#   vz-ai-stack.sh help regen [<svc>] [--apply] [--check] [--model <m>] [--force]
#
# Design (see doc/specs/2026-06-03-service-help-design.md):
#   - PROSE (what/why/usage/config_notes) is authored in services.yml `help:` blocks.
#   - The "HOW IT'S CONFIGURED" section is COMPUTED live from services.yml + aliases
#     (never stored) so it can't drift. The render path makes NO network call and
#     reads NO secrets — it works with the stack down.
#   - `regen` refreshes the PROSE by asking the stack's own LiteLLM gateway to draft
#     it from each service's real code/docs. It sends code/docs context ONLY, never
#     any .env value. Drafts go to a staging file + diff; --apply writes them back.
#
# House style mirrors installer/lib/models.sh. Shell-safety: every command-sub that
# may return non-zero is guarded; yq output is captured before grep (no SIGPIPE);
# python drains stdin; functions never end on a bare `cond && {…}`; yq mutations use
# env-var injection (strenv); writes are atomic.
set -Eeuo pipefail
shopt -s inherit_errexit 2>/dev/null || true

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/services_accessors.sh"
source "$AI_STACK/installer/lib/network.sh"

SERVICES_YML="$AI_STACK/services.yml"
EXPLORE_HTML="$AI_STACK/doc/EXPLORE.html"
LITELLM="${LITELLM_BASE_URL:-http://litellm:4000}"
HELP_MODEL_DEFAULT="${HELP_REGEN_MODEL:-claude-opus-sub-max}"

my_q() { yq -r "$1" "$SERVICES_YML" 2>/dev/null; }

# ---------------------------------------------------------------------------
# Resolution: token -> canonical services.yml key
# ---------------------------------------------------------------------------
service_exists() { yq -e ".services.\"$1\"" "$SERVICES_YML" >/dev/null 2>&1; }

# A few user-facing shorthands that aren't network aliases (parity with what
# users already type at `install`/`phases`).
declare -A _HELP_ALIASES=(
  [unsloth-studio]=unsloth [telegram]=hermes_telegram [workspace]=hermes_workspace
  [hermes-fleet]=hermes_fleet [docs-mcp]=docs_mcp [llm-guard]=llm_guard
  [falkordb-ui]=falkordb [hermes-gw]=hermes_fleet [bridge]=claw3d_bridge
)

# resolve_service_key <token> — echo the canonical key, or empty + return 1.
resolve_service_key() {
  local sel="$1" hit
  service_exists "$sel" && { printf '%s' "$sel"; return 0; }
  # network aliases (aliases.tsv -> ALIAS_SERVICE_KEY)
  aliases_load 2>/dev/null || true
  hit="${ALIAS_SERVICE_KEY[$sel]:-}"
  [[ -n "$hit" ]] && service_exists "$hit" && { printf '%s' "$hit"; return 0; }
  # explicit shorthands
  hit="${_HELP_ALIASES[$sel]:-}"
  [[ -n "$hit" ]] && service_exists "$hit" && { printf '%s' "$hit"; return 0; }
  # dash/underscore tolerance
  local us="${sel//-/_}"
  service_exists "$us" && { printf '%s' "$us"; return 0; }
  return 1
}

# fuzzy_suggest <token> — print up to 5 service keys containing the token.
fuzzy_suggest() {
  local sel="${1//-/_}" out
  out="$(my_q '.services | keys | .[]')"
  grep -iF "$sel" <<<"$out" 2>/dev/null | head -5 || true
}

all_keys() { my_q '.services | keys | .[]'; }
has_help_block() { yq -e ".services.\"$1\".help" "$SERVICES_YML" >/dev/null 2>&1; }
help_field() { my_q ".services.\"$1\".help.$2 // \"\""; }   # scalar help.* field

# ---------------------------------------------------------------------------
# Render
# ---------------------------------------------------------------------------
# _row <label> <value> — aligned row, suppressed when value is empty/"-"/null.
_row() {
  local label="$1" val="$2"
  [[ -z "$val" || "$val" == "-" || "$val" == "null" ]] && return 0
  printf '  %-14s %s\n' "$label" "$val"
}

# _join — join stdin lines into "a, b, c". (NOT `paste -sd', '`, which cycles the
# delimiter list comma/space and mangles >2 items.) Single-char join, then space.
_join() { paste -sd, - | sed 's/,/, /g'; }

# _endpoints <key> — one line per network alias (svc -> alias:host → :container),
# falling back to services.yml ports for loopback-only services. Never errors.
_endpoints() {
  local key="$1" a out=""
  aliases_load 2>/dev/null || true
  if [[ -n "${ALIASES_LIST:-}" ]]; then
    for a in "${ALIASES_LIST[@]}"; do
      [[ "${ALIAS_SERVICE_KEY[$a]:-}" == "$key" ]] || continue
      local proto="${ALIAS_PROTOCOL[$a]:-http}" hp="${ALIAS_HOST_PORT[$a]:-}" cp="${ALIAS_CONTAINER_PORT[$a]:-}"
      out+="    ${proto}://${a}:${hp}  (→ container :${cp})"$'\n'
    done
  fi
  if [[ -z "$out" ]]; then
    # loopback-only / no alias: read ports straight from services.yml
    local port; port="$(my_q ".services.\"$key\".host_port // .services.\"$key\".port // (.services.\"$key\".ports[0]? ) // \"\"")"
    [[ -n "$port" && "$port" != "null" ]] && out="    localhost:${port}"$'\n'
  fi
  printf '%s' "$out"
}

cmd_help_show() {
  local sel="${1:-}" key
  [[ -n "$sel" ]] || { cmd_help_usage; return 0; }
  if ! key="$(resolve_service_key "$sel")"; then
    err "unknown service '$sel'"
    local sug; sug="$(fuzzy_suggest "$sel")"
    [[ -n "$sug" ]] && { echo "Did you mean:" >&2; sed 's/^/  /' <<<"$sug" >&2; }
    echo "Run 'vz-ai-stack.sh help services' for the full list." >&2
    return 1
  fi

  printf '\n%s%s%s  —  %s\n' "$C_BOLD" "$key" "$C_RESET" "$(svc_desc "$key")"

  # --- WHAT ---
  hdr "WHAT"
  local what; what="$(help_field "$key" what)"
  [[ -z "$what" ]] && what="$(svc_desc "$key")"
  printf '  %s\n' "$what"

  # --- HOW IT'S CONFIGURED (computed) ---
  hdr "HOW IT'S CONFIGURED"
  _row "Installed by" "Phase $(svc_phase "$key")  (type: $(svc_type "$key"), network: $(svc_network "$key"))"
  local envk; envk="$(svc_consumes_env "$key" | _join 2>/dev/null || true)"
  [[ -n "$envk" ]] && _row "Env keys" "$envk        (values in $AI_STACK/.env)"
  # authored config files (services.yml help.config_files), if any. The shared
  # .env is already named on the Env-keys row above.
  local cf; cf="$(my_q ".services.\"$key\".help.config_files[]?" | _join 2>/dev/null || true)"
  _row "Config files" "$cf"
  local eps; eps="$(_endpoints "$key")"
  [[ -n "$eps" ]] && { printf '  Endpoint\n'; printf '%s\n' "$eps"; }
  _row "Health" "$(svc_health "$key")"
  _row "Sandbox" "$(svc_sandbox "$key")"
  _row "Code dir" "$(svc_path "$key")"
  _row "Image" "$(svc_image "$key")"
  local notes; notes="$(help_field "$key" config_notes)"
  [[ -n "$notes" ]] && printf '  %s%s%s\n' "$C_DIM" "$notes" "$C_RESET"

  # --- HOW TO USE / WHY --- (only when there's authored prose; else a hint)
  local why usage see
  why="$(help_field "$key" why)"
  usage="$(my_q ".services.\"$key\".help.usage[]?")"
  see="$(my_q ".services.\"$key\".help.see_also[]?" | _join 2>/dev/null || true)"
  if [[ -n "$why" || -n "$usage" ]]; then
    hdr "HOW TO USE"
    [[ -n "$why" ]] && printf '  %s\n' "$why"
    if [[ -n "$usage" ]]; then
      printf '\n'
      while IFS= read -r u; do [[ -n "$u" ]] && printf '    $ %s\n' "$u"; done <<<"$usage"
    fi
    [[ -n "$see" ]] && { printf '\n'; note "See also: $see"; }
  fi
  if ! has_help_block "$key"; then
    printf '\n'; note "(no authored help yet — run: vz-ai-stack.sh help regen $key --apply)"
  fi
  printf '\n'
  return 0
}

cmd_help_list() {
  hdr "Services with help (vz-ai-stack.sh help <service>)"
  local k cur_phase="" ph
  # Sort by phase then key for a stable, grouped listing.
  while IFS=$'\t' read -r ph k; do
    [[ -z "$k" ]] && continue
    if [[ "$ph" != "$cur_phase" ]]; then printf '\n  %sPhase %s%s\n' "$C_DIM" "$ph" "$C_RESET"; cur_phase="$ph"; fi
    local one; one="$(help_field "$k" what)"; [[ -z "$one" ]] && one="$(svc_desc "$k")"
    one="${one//$'\n'/ }"                       # flatten any newlines
    (( ${#one} > 92 )) && one="${one:0:91}…"    # hard cap (sentence-split mangles "e.g.")
    if has_help_block "$k"; then printf '    %-26s %s\n' "$k" "$one"
    else printf '    %-26s %s%s%s\n' "$k" "$C_YELLOW" "(no help yet) " "$C_RESET"; fi
  done < <(all_keys | while IFS= read -r k; do [[ -n "$k" ]] && printf '%s\t%s\n' "$(svc_phase "$k")" "$k"; done | LC_ALL=C sort)
  printf '\n'
  note "Detail:  vz-ai-stack.sh help <service>     ·   Refresh prose:  vz-ai-stack.sh help regen [<svc>] --apply"
  return 0
}

cmd_help_usage() {
  cat <<EOF

vz-ai-stack.sh help — per-service help

  vz-ai-stack.sh help services            list services that have help
  vz-ai-stack.sh help <service|alias>     what it is · how it's configured · how to use
  vz-ai-stack.sh help regen [<svc>]       refresh help prose from the live codebase
       [--apply] [--check] [--model <m>] [--force]

Examples:
  vz-ai-stack.sh help claw3d
  vz-ai-stack.sh help pi
  vz-ai-stack.sh help unsloth-studio
EOF
  return 0
}

# ---------------------------------------------------------------------------
# Regen — draft prose from the live codebase via the stack's LiteLLM
# ---------------------------------------------------------------------------
# _service_context <key> — code/docs context for the LLM. NEVER includes secret
# VALUES: only desc, phase, env KEY NAMES, comment headers, and a dir listing.
_service_context() {
  local key="$1" ph; ph="$(svc_phase "$key")"
  printf 'SERVICE KEY: %s\n' "$key"
  printf 'ONE-LINER (desc): %s\n' "$(svc_desc "$key")"
  printf 'INSTALL PHASE: %s   TYPE: %s   NETWORK: %s\n' "$ph" "$(svc_type "$key")" "$(svc_network "$key")"
  local envk; envk="$(svc_consumes_env "$key" | _join 2>/dev/null || true)"
  [[ -n "$envk" ]] && printf 'ENV KEYS IT READS (names only): %s\n' "$envk"
  local ss="$AI_STACK/bin/start-${key}.sh"
  [[ -f "$ss" ]] && { printf '\n--- bin/start-%s.sh (header) ---\n' "$key"; sed -n '1,30p' "$ss" | grep -E '^#' || true; }
  local pf; pf="$(find "$AI_STACK/installer/phases" -maxdepth 1 -name "${ph}_*.sh" 2>/dev/null | head -1)"
  [[ -n "$pf" && -f "$pf" ]] && { printf '\n--- phase %s (header) ---\n' "$ph"; sed -n '1,25p' "$pf" | grep -E '^#' || true; }
  local path; path="$(svc_path "$key")"
  [[ -n "$path" && "$path" != "-" && -d "$path" ]] && { printf '\n--- code dir listing (%s) ---\n' "$path"; ls -1 "$path" 2>/dev/null | head -25 || true; }
  return 0
}

# _llm_draft <model> — stdin=context; stdout=JSON {what,why,usage[],config_notes}.
# Non-zero on transport/parse failure (caller WARNs, non-fatal).
_llm_draft() {
  local model="$1" key; key="$(get_env LITELLM_MASTER_KEY '')"
  [[ -n "$key" ]] || { err "LITELLM_MASTER_KEY missing (run phase 00)"; return 1; }
  local ctx; ctx="$(cat)"
  local sys='You document infrastructure services for a CLI help command. Given a service'"'"'s code/docs context, return STRICT JSON with keys: what (1-3 sentences on what it is), why (purpose / when to reach for it), usage (array of 2-5 concrete shell or URL lines — read-only/inspection commands only, NEVER destructive), config_notes (one short gotcha beyond the obvious, or ""). Output ONLY the JSON object.'
  local body
  body="$(SYS="$sys" MODEL="$model" CTX="$ctx" python3 -c 'import json,os
print(json.dumps({"model":os.environ["MODEL"],
"messages":[{"role":"system","content":os.environ["SYS"]},{"role":"user","content":os.environ["CTX"]}],
"temperature":0.2,"max_tokens":700,"response_format":{"type":"json_object"}}))')" || { err "could not build request"; return 1; }
  local resp
  resp="$(litellm_master_curl -s --max-time 120 "$LITELLM/v1/chat/completions" \
    -H "Content-Type: application/json" -d "$body")" || { err "LiteLLM request failed"; return 1; }
  printf '%s' "$resp" | python3 -c 'import sys,json,re
try: d=json.load(sys.stdin)
except Exception: sys.exit(3)
try: c=d["choices"][0]["message"]["content"]
except Exception: sys.exit(3)
m=re.search(r"\{.*\}", c, re.S)
if not m: sys.exit(4)
try: o=json.loads(m.group(0))
except Exception: sys.exit(4)
out={k:(o.get(k) or "") for k in ("what","why","config_notes")}
u=o.get("usage",[]); out["usage"]=[str(x) for x in u] if isinstance(u,list) else ([str(u)] if u else [])
if not out["what"] or not out["why"]: sys.exit(5)
print(json.dumps(out))'
}

# _stage_write <key> <json> <model> — write a staged help: overlay; echo its path.
_stage_write() {
  local key="$1" js="$2" model="$3" at; at="$(date -u +%FT%TZ)"
  mkdir -p "$STATE_DIR"
  local stage="$STATE_DIR/help-staged-${key}.yaml"
  ( umask 077
    SVC="$key" JS="$js" AT="$at" MODEL="$model" yq -n '
      .services[strenv(SVC)].help = (strenv(JS) | fromjson) |
      .services[strenv(SVC)].help._gen = {"at":strenv(AT),"model":strenv(MODEL),"reviewed":false}
    ' > "$stage.tmp" ) || { err "staging write failed for $key"; rm -f "$stage.tmp"; return 1; }
  mv -f "$stage.tmp" "$stage" || { err "staging mv failed for $key"; rm -f "$stage.tmp"; return 1; }
  printf '%s' "$stage"
}

# _help_diff <key> <stage> — unified diff of current vs staged help block.
_help_diff() {
  local key="$1" stage="$2" cur new
  cur="$(SVC="$key" yq -r '.services[strenv(SVC)].help // {}' "$SERVICES_YML" 2>/dev/null || echo '{}')"
  new="$(SVC="$key" yq -r '.services[strenv(SVC)].help' "$stage" 2>/dev/null || echo '{}')"
  diff -u <(printf '%s\n' "$cur") <(printf '%s\n' "$new") || true
}

# _help_apply <key> <stage> — merge staged help into services.yml (atomic via yq -i).
# Refuses to clobber a human-reviewed block unless HELP_FORCE=1.
_help_apply() {
  local key="$1" stage="$2" reviewed
  reviewed="$(SVC="$key" yq -r '.services[strenv(SVC)].help._gen.reviewed // "false"' "$SERVICES_YML" 2>/dev/null || echo false)"
  if [[ "$reviewed" == "true" && "${HELP_FORCE:-0}" != "1" ]]; then
    warn "$key: help is human-reviewed (reviewed:true) — skipping (use --force to overwrite)"; return 0
  fi
  local blk; blk="$(SVC="$key" yq -o=json '.services[strenv(SVC)].help' "$stage" 2>/dev/null)"
  [[ -n "$blk" && "$blk" != "null" ]] || { err "$key: staged block empty"; return 1; }
  SVC="$key" BLK="$blk" yq -i '.services[strenv(SVC)].help = (strenv(BLK) | fromjson)' "$SERVICES_YML" \
    || { err "yq -i apply failed for $key"; return 1; }
  ok "$key: help applied (reviewed:false)"
  return 0
}

# regen_one <key> <model> <apply>
regen_one() {
  local key="$1" model="$2" apply="$3" js stage
  log "regen $key (model=$model)..."
  if ! js="$(_service_context "$key" | _llm_draft "$model")"; then
    warn "$key: draft failed (LiteLLM down or model returned no usable JSON) — skipped"; return 0
  fi
  stage="$(_stage_write "$key" "$js" "$model")" || return 0
  printf '\n'; _help_diff "$key" "$stage"; printf '\n'
  if [[ "$apply" == "1" ]]; then _help_apply "$key" "$stage"
  else note "$key: staged at $stage (dry-run; pass --apply to write into services.yml)"; fi
  return 0
}

# ---------------------------------------------------------------------------
# --check — staleness/missing report (read-only; CI/doctor hook)
# ---------------------------------------------------------------------------
_code_mtime_epoch() {
  local key="$1" m=0 f e ph; ph="$(svc_phase "$key")"
  local files=("$AI_STACK/bin/start-${key}.sh")
  while IFS= read -r f; do [[ -n "$f" ]] && files+=("$f"); done < <(find "$AI_STACK/installer/phases" -maxdepth 1 -name "${ph}_*.sh" 2>/dev/null || true)
  for f in "${files[@]}"; do
    [[ -f "$f" ]] || continue
    e="$(stat -f %m "$f" 2>/dev/null || echo 0)"; [[ "$e" =~ ^[0-9]+$ ]] || e=0
    (( e > m )) && m="$e"
  done
  printf '%s' "$m"
}
_gen_epoch() {  # epoch of help._gen.at (ISO8601 UTC), or 0
  local key="$1" at; at="$(help_field "$key" _gen.at 2>/dev/null || true)"
  [[ -z "$at" ]] && { printf '0'; return 0; }
  AT="$at" python3 -c 'import os,datetime,sys
try: print(int(datetime.datetime.strptime(os.environ["AT"],"%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=datetime.timezone.utc).timestamp()))
except Exception: print(0)' 2>/dev/null || printf '0'
}
cmd_help_check() {
  local only="${1:-}" k problems=0
  local keys; if [[ -n "$only" ]]; then keys="$(resolve_service_key "$only" || true)"; [[ -n "$keys" ]] || { err "unknown service '$only'"; return 2; }
  else keys="$(all_keys)"; fi
  while IFS= read -r k; do
    [[ -z "$k" ]] && continue
    if ! has_help_block "$k" || [[ -z "$(help_field "$k" what)" || -z "$(help_field "$k" why)" ]]; then
      echo "MISSING  $k"; problems=$((problems+1)); continue
    fi
    local ge ce; ge="$(_gen_epoch "$k")"; ce="$(_code_mtime_epoch "$k")"
    if (( ge > 0 && ce > ge )); then echo "STALE    $k (code newer than help _gen.at)"; problems=$((problems+1)); fi
  done <<<"$keys"
  if (( problems == 0 )); then ok "help: all checked services present + fresh"; return 0; fi
  warn "help: $problems service(s) missing/stale (run: vz-ai-stack.sh help regen [<svc>] --apply)"
  return 1
}

cmd_help_regen() {
  local only="" apply=0 check=0 model="$HELP_MODEL_DEFAULT" expect_model=0 a
  for a in "$@"; do
    if (( expect_model )); then
      [[ "$a" == -* ]] && { err "regen: --model needs a value"; return 2; }
      model="$a"; expect_model=0; continue
    fi
    case "$a" in
      --apply)   apply=1 ;;
      --check)   check=1 ;;
      --force)   export HELP_FORCE=1 ;;
      --model)   expect_model=1 ;;
      --model=*) model="${a#--model=}" ;;
      -*) err "regen: unknown flag '$a'"; return 2 ;;
      *) [[ -z "$only" ]] && only="$a" ;;
    esac
  done
  (( expect_model )) && { err "regen: --model needs a value"; return 2; }
  if (( check )); then cmd_help_check "$only"; return $?; fi

  command -v yq >/dev/null 2>&1 || { err "yq not on PATH"; return 1; }
  if [[ -n "$only" ]]; then
    local key; key="$(resolve_service_key "$only")" || { err "unknown service '$only'"; return 2; }
    regen_one "$key" "$model" "$apply"
  else
    local k
    while IFS= read -r k; do [[ -n "$k" ]] && regen_one "$k" "$model" "$apply"; done < <(all_keys)
  fi
  (( apply )) || note "dry-run complete — nothing written (pass --apply to commit drafts)"
  return 0
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
main() {
  local sub="${1:-}"; shift || true
  case "$sub" in
    ""|-h|--help)      cmd_help_usage ;;
    services|list)     cmd_help_list ;;
    regen)             cmd_help_regen "$@" ;;
    *)                 cmd_help_show "$sub" ;;
  esac
}
main "$@"
