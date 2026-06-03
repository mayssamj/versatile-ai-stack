# Meridian — Claude Pro/Max SUBSCRIPTION behind LiteLLM (bin/start-meridian.sh).
#
# Opt-in. Lets Open WebUI (and anything behind LiteLLM) chat/code on your
# `claude login` OAuth with NO API key:
#   Open WebUI → LiteLLM → Meridian (host 127.0.0.1:3456) → Anthropic.
#
# Philosophy (mirrors the LM Studio check): GREEN unless something the user
# clearly opted into is genuinely broken. Specifically:
#   • meridian not installed                       → advisory green (opt-in)
#   • installed, no launchd job, port closed       → advisory green (didn't enable the daemon)
#   • launchd job LOADED but endpoint unhealthy     → RED  (KeepAlive should hold it up)
#   • endpoint healthy but '*-sub' models not served → RED  (LiteLLM wiring gap)
# Never prints a token. Uses the free /v1/models surface (no subscription quota).
CHECKS+=(meridian)
CHECK_TITLE[meridian]="Meridian: Claude subscription behind LiteLLM (bin/start-meridian.sh)"

_mer_label() { echo "com.ai-stack.meridian"; }
_mer_port()  { echo "${MERIDIAN_PORT:-3456}"; }
_mer_bin() {
  for p in "$HOME/.openagents/nodejs/bin/meridian" /opt/homebrew/bin/meridian /usr/local/bin/meridian; do
    [[ -x "$p" ]] && { echo "$p"; return; }
  done
  command -v meridian 2>/dev/null || echo ""
}
_mer_loaded()  { launchctl print "gui/$(id -u)/$(_mer_label)" >/dev/null 2>&1; }
_mer_healthy() {
  curl -s -m 5 -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$(_mer_port)/v1/models" -H "Authorization: Bearer x" 2>/dev/null | grep -q '^200$'
}
# _mer_effort_drift — echo each meridian model whose config.yaml extra_body.effort
# != its models.yml effort. Catches the regression where a register-without-effort
# flattens the subscription effort ladder (…-sub-{low,medium,high,xhigh,max}) to one
# value. Config-vs-config (no daemon needed); empty output = consistent.
_mer_effort_drift() {
  local myml="$AI_STACK/installer/models.yml" cfg="$AI_STACK/litellm/config.yaml" m want got
  [[ -f "$myml" && -f "$cfg" ]] || return 0
  command -v yq >/dev/null 2>&1 || return 0
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    [[ "$(yq -r ".models.\"$m\".runtime" "$myml" 2>/dev/null)" == "meridian" ]] || continue
    want="$(yq -r ".models.\"$m\".effort" "$myml" 2>/dev/null)"
    got="$(MN="$m" yq -r '.model_list[] | select(.model_name == strenv(MN)) | .litellm_params.extra_body.effort // ""' "$cfg" 2>/dev/null)"
    [[ -n "$got" && "$got" != "null" && "$got" != "$want" ]] && echo "$m (models.yml=$want, config.yaml=$got)"
  done < <(yq -r '.models | keys | .[]' "$myml" 2>/dev/null)
}

meridian_diagnose() {
  local cfg="$AI_STACK/litellm/config.yaml" port; port="$(_mer_port)"

  # Effort-ladder integrity (config vs models.yml) — runs regardless of daemon
  # state, because a flattened ladder is a real config regression either way.
  local drift; drift="$(_mer_effort_drift)"
  if [[ -n "$drift" ]]; then
    echo "litellm/config.yaml meridian effort does NOT match installer/models.yml (effort ladder flattened):"
    echo "$drift" | sed 's/^/    /'
    echo "  cause: a register-without-effort (e.g. Phase 01 loop) defaulted extra_body.effort to 'high'."
    echo "  fix:   bash $AI_STACK/vz-ai-stack.sh model sync   then   bash $AI_STACK/bin/start-litellm.sh --recreate"
    return 1
  fi

  if [[ -z "$(_mer_bin)" ]]; then
    echo "  (Meridian not installed — opt-in; to chat/code on your Claude subscription from Open WebUI:"
    echo "     npm install -g @rynfar/meridian && claude login && bash $AI_STACK/bin/start-meridian.sh install)"
    return 0
  fi

  if ! _mer_loaded && ! _mer_healthy; then
    echo "  (Meridian installed but daemon not enabled — opt-in; run: bash $AI_STACK/bin/start-meridian.sh install)"
    return 0
  fi

  # From here the user opted into the daemon — a down endpoint IS a fault.
  if ! _mer_healthy; then
    echo "Meridian launchd job loaded but http://127.0.0.1:$port not healthy"
    echo "  inspect: bash $AI_STACK/bin/start-meridian.sh status   (log: installer/state/meridian.launchd.log)"
    echo "  common cause: OAuth expired/invalid — re-run 'claude login', then 'start-meridian.sh restart'"
    return 1
  fi

  # Endpoint is up — verify LiteLLM actually exposes the subscription model(s),
  # which is the whole point (Open WebUI lists LiteLLM's models). The `-sub`
  # suffix marks the subscription routes. Free probe (no chat, no quota).
  if grep -q 'model_name: claude-opus-4.8-sub-max\b' "$cfg" 2>/dev/null; then
    local master served
    master="$(get_env LITELLM_MASTER_KEY '' 2>/dev/null || echo '')"
    if [[ -n "$master" ]] && curl -sf --max-time 3 http://litellm:4000/health/readiness >/dev/null 2>&1; then
      served="$(curl -s --max-time 6 http://litellm:4000/v1/models -H "Authorization: Bearer $master" 2>/dev/null \
        | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(sum(1 for m in d.get("data",[]) if "-sub-" in str(m.get("id",""))))' 2>/dev/null || echo 0)"
      if [[ "${served:-0}" -lt 1 ]]; then
        echo "Meridian healthy on :$port but LiteLLM is not serving the '*-sub-*' effort models — recreate LiteLLM to reload config:"
        echo "  bash $AI_STACK/bin/start-litellm.sh --recreate"
        return 1
      fi
      echo "  (Meridian healthy on :$port; LiteLLM serves $served subscription effort-model(s) — pick e.g. 'claude-opus-4.8-sub-max' (default) or '-low/-medium/-high/-xhigh' in Open WebUI. Effort via extra_body→body.effort→SDK; thinking on by default.)"
      return 0
    fi
    echo "  (Meridian healthy on :$port; LiteLLM down/uncheckable — see check 11 + Phase 01. Wiring present in config.yaml.)"
    return 0
  fi

  echo "Meridian healthy on :$port but 'claude-opus-4.8-sub-max' is NOT wired into litellm/config.yaml"
  echo "  add the *-sub-* effort model_list entries (see the subscription block) and: bash $AI_STACK/bin/start-litellm.sh --recreate"
  return 1
}

meridian_fix() {
  warn "Ensure the Meridian daemon is installed + running (reuses your 'claude login' OAuth):"
  warn "    npm install -g @rynfar/meridian   # if not installed"
  warn "    bash $AI_STACK/bin/start-meridian.sh install"
  warn "If the endpoint is up but Open WebUI lacks the model, reload LiteLLM's config:"
  warn "    bash $AI_STACK/bin/start-litellm.sh --recreate"
  return 1
}
