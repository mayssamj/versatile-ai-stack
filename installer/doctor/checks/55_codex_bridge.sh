# Codex bridge — OpenAI GPT-5.x on your ChatGPT SUBSCRIPTION behind LiteLLM
# (bin/start-codex-bridge.sh). The OpenAI analog of check 41 (Meridian).
#
# Opt-in + ToS-GRAY. Lets Open WebUI (and anything behind LiteLLM) chat on your
# `codex login` OAuth with NO metered key:
#   Open WebUI → LiteLLM → codex-bridge (host 127.0.0.1:3457) → ChatGPT backend.
#
# Philosophy (mirrors the Meridian/LM Studio checks): GREEN unless something the
# user clearly opted into is genuinely broken. Specifically:
#   • bridge not installed (no launchd plist, port closed) → advisory green (opt-in)
#   • plist present but daemon not enabled                  → advisory green
#   • launchd job LOADED but endpoint unhealthy             → RED  (KeepAlive should hold it)
#   • endpoint healthy but 'openai-gpt-5.*-sub' not served  → RED  (LiteLLM wiring gap)
# Never prints a token. Liveness uses the free /v1/models surface (no ChatGPT
# quota). A real-completion auth probe is OPT-IN only (CODEX_BRIDGE_DEEP_CHECK=1)
# so a routine `doctor` never spends your rate-limited subscription window.
# NOTE: unlike Meridian (Anthropic's OFFICIAL SDK), this wraps the ChatGPT
# product backend — unofficial use; see bin/start-codex-bridge.sh for the risks.
CHECKS+=(codex_bridge)
CHECK_TITLE[codex_bridge]="Codex bridge: GPT-5.x on your ChatGPT subscription (bin/start-codex-bridge.sh)"

_cb_label() { echo "com.ai-stack.codex-bridge"; }
_cb_port()  { echo "${CODEX_BRIDGE_PORT:-3457}"; }
_cb_plist() { echo "$HOME/Library/LaunchAgents/$(_cb_label).plist"; }
_cb_auth()  { echo "${CODEX_AUTH_FILE:-$HOME/.codex/auth.json}"; }
# Named seams (so the smoke can stub each branch). _cb_installed = daemon plist
# present (the opted-in signal); _cb_loaded = launchd job loaded; _cb_healthy =
# endpoint answering; _cb_wired = LiteLLM config has the model; _cb_served_count
# = how many gpt-5 `-sub` ids LiteLLM serves ("down" if LiteLLM is uncheckable).
_cb_installed() { [[ -f "$(_cb_plist)" ]]; }
_cb_loaded()    { launchctl print "gui/$(id -u)/$(_cb_label)" >/dev/null 2>&1; }
_cb_healthy()   {
  curl -s -m 5 -o /dev/null -w '%{http_code}' \
    "http://127.0.0.1:$(_cb_port)/v1/models" -H "Authorization: Bearer x" 2>/dev/null | grep -q '^200$'
}
_cb_wired()     { grep -q 'model_name: openai-gpt-sub\b' "${1:-$AI_STACK/litellm/config.yaml}" 2>/dev/null; }
_cb_served_count() {
  local master served
  master="$(get_env LITELLM_MASTER_KEY '' 2>/dev/null || echo '')"
  if [[ -z "$master" ]] || ! curl -sf --max-time 3 http://litellm:4000/health/readiness >/dev/null 2>&1; then
    echo "down"; return 0
  fi
  served="$(curl -s --max-time 6 http://litellm:4000/v1/models -H "Authorization: Bearer $master" 2>/dev/null \
    | python3 -c 'import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(0)
print(sum(1 for m in d.get("data",[]) if "-sub" in str(m.get("id","")) and "gpt-5" in str(m.get("id",""))))' 2>/dev/null || echo 0)"
  echo "${served:-0}"
}

codex_bridge_diagnose() {
  local cfg="${CODEX_BRIDGE_CFG:-$AI_STACK/litellm/config.yaml}" port auth
  port="$(_cb_port)"; auth="$(_cb_auth)"

  # Not opted in at all (no daemon plist + nothing listening) → advisory green.
  if ! _cb_installed && ! _cb_healthy; then
    echo "  (codex-bridge not installed — opt-in + ToS-gray; to run GPT-5.x on your ChatGPT subscription:"
    echo "     npx --yes @openai/codex login && bash $AI_STACK/bin/start-codex-bridge.sh install"
    echo "   the metered openai-gpt/5.4 (OPENAI_API_KEY) is the supported default and needs none of this.)"
    return 0
  fi

  # Plist present but daemon not up/loaded (installed, not enabled, or stopped) → advisory green.
  if ! _cb_loaded && ! _cb_healthy; then
    echo "  (codex-bridge installed but daemon not enabled — opt-in; run: bash $AI_STACK/bin/start-codex-bridge.sh install)"
    return 0
  fi

  # From here the user opted into the daemon — a down endpoint IS a fault.
  if ! _cb_healthy; then
    echo "codex-bridge launchd job loaded but http://127.0.0.1:$port not healthy"
    echo "  inspect: bash $AI_STACK/bin/start-codex-bridge.sh status   (log: installer/state/codex-bridge.launchd.log)"
    if [[ ! -s "$auth" ]]; then
      echo "  cause: ChatGPT auth missing ($auth) — run: npx --yes @openai/codex login, then 'start-codex-bridge.sh restart'"
    else
      echo "  common cause: ChatGPT OAuth expired/invalid — re-run 'npx --yes @openai/codex login', then 'start-codex-bridge.sh restart'"
    fi
    return 1
  fi

  # Endpoint up — but is LiteLLM wired to serve the subscription GPT model(s)?
  if ! _cb_wired "$cfg"; then
    echo "codex-bridge healthy on :$port but 'openai-gpt-sub' is NOT wired into litellm/config.yaml"
    echo "  add the openai-gpt-5.*-sub model_list entries (see the ChatGPT-subscription block) and: bash $AI_STACK/bin/start-litellm.sh --recreate"
    return 1
  fi

  # Verify LiteLLM actually serves them (the whole point — Open WebUI lists
  # LiteLLM's models). Free probe (no chat, no ChatGPT quota).
  local served; served="$(_cb_served_count)"
  if [[ "$served" == "down" ]]; then
    echo "  (codex-bridge healthy on :$port; LiteLLM down/uncheckable — see check 11 + Phase 01. Wiring present in config.yaml.)"
    return 0
  fi
  if [[ "${served:-0}" -lt 1 ]]; then
    echo "codex-bridge healthy on :$port but LiteLLM is not serving the 'openai-gpt-5.*-sub' models — recreate LiteLLM to reload config:"
    echo "  bash $AI_STACK/bin/start-litellm.sh --recreate"
    return 1
  fi

  # Opt-in deep probe: confirm the OAuth still authenticates (costs 1 token of
  # your ChatGPT quota). Off by default so routine doctor runs stay free.
  if [[ "${CODEX_BRIDGE_DEEP_CHECK:-0}" == "1" ]]; then
    local code
    code="$(curl -s -m 20 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/v1/chat/completions" \
      -H "Authorization: Bearer x" -H 'Content-Type: application/json' \
      -d '{"model":"gpt-5.4","messages":[{"role":"user","content":"hi"}],"max_tokens":1}' 2>/dev/null || echo 000)"
    if [[ "$code" == "401" || "$code" == "403" ]]; then
      echo "codex-bridge endpoint up but a live completion returned HTTP $code — ChatGPT OAuth likely expired:"
      echo "  re-run: npx --yes @openai/codex login, then bash $AI_STACK/bin/start-codex-bridge.sh restart"
      return 1
    fi
  fi
  echo "  (codex-bridge healthy on :$port; LiteLLM serves $served subscription GPT model(s) — pick 'openai-gpt-sub' / 'openai-gpt-sub' in Open WebUI. Rate-limited by your ChatGPT plan; deep auth probe: CODEX_BRIDGE_DEEP_CHECK=1.)"
  return 0
}

codex_bridge_fix() {
  warn "Ensure the codex-bridge daemon is installed + running (reuses your 'codex login' ChatGPT OAuth):"
  warn "    npx --yes @openai/codex login        # ChatGPT 'Sign in', writes ~/.codex/auth.json"
  warn "    bash $AI_STACK/bin/start-codex-bridge.sh install"
  warn "If the endpoint is up but Open WebUI lacks the model, reload LiteLLM's config:"
  warn "    bash $AI_STACK/bin/start-litellm.sh --recreate"
  warn "Reminder: ToS-gray, single personal account only — see bin/start-codex-bridge.sh."
  return 1
}
