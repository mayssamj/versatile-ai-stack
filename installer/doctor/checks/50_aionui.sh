# AionUi (Phase 28): desktop cask + aionui-web WebUI daemon (loopback :25808) +
# scoped LiteLLM virtual key. AionUi is an OPT-IN Cowork workspace (no ai-stack
# container — the desktop app is a brew cask, the WebUI is a host launchd daemon).
#
# Conditional: skips clean when Phase 28 hasn't run (the opt-in case). Gate on the
# phase stamp — the cask/binary/key footprint can survive a reset, but the stamp is
# what `reset` clears, so it's the one reliable "installed on THIS stack" signal.
CHECKS+=(aionui)
CHECK_TITLE[aionui]="AionUi WebUI healthy on :25808 + LiteLLM key valid (Phase 28)"

aionui_diagnose() {
  local aw="$HOME/.local/share/aionui-web/aionui-web"
  # NB: compgen -G (not `ls <glob>`) — doctor.sh runs under nullglob, where an
  # unmatched glob is REMOVED and `ls` would list cwd and falsely succeed.
  if ! compgen -G "$AI_STACK/installer/state/phase_28*.done" >/dev/null 2>&1; then
    echo "AionUi not installed in this stack — Phase 28 (opt-in) hasn't run yet (skipping)"
    return 0
  fi

  brew list --cask aionui >/dev/null 2>&1 || { echo "AionUi desktop cask missing — re-run 'vz-ai-stack.sh install 28'"; return 1; }
  [[ -x "$aw" ]] || { echo "aionui-web binary missing ($aw) — re-run 'vz-ai-stack.sh install 28'"; return 1; }
  # Health: the WebUI serves HTTP 200 at / when aioncore is up. Explicit '^200$'
  # grep (NOT the http_ok helper — documented 000-concat false-healthy bug).
  if ! curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:25808/ 2>/dev/null | grep -q '^200$'; then
    echo "aionui-web not serving 200 on :25808 — 'vz-ai-stack.sh start aionui' (or check installer/state/aionui-web.launchd.log)"
    return 1
  fi
  local key; key="$(get_env AIONUI_LITELLM_KEY '')"
  [[ -n "$key" ]] || { echo "AIONUI_LITELLM_KEY missing from .env — re-run 'vz-ai-stack.sh install 28'"; return 1; }
  # Gate the key probe on LiteLLM reachability so a down LiteLLM doesn't red-bar this.
  if ! litellm_scoped_curl "$key" -sf --max-time 5 http://litellm:4000/v1/models >/dev/null 2>&1; then
    if declare -F litellm_db_down >/dev/null && litellm_db_down; then
      echo "LiteLLM key-store DOWN (503 no_db_connection) — NOT a bad key. Heal the DB (check 05a / start honcho-database); do NOT re-mint."
      return 1
    fi
    if curl -sf --max-time 3 http://litellm:4000/health >/dev/null 2>&1; then
      echo "AIONUI_LITELLM_KEY rejected by LiteLLM /v1/models — re-mint via 'vz-ai-stack.sh install 28'"
      return 1
    fi
    echo "LiteLLM not reachable — start it ('vz-ai-stack.sh start litellm'), then re-check"
    return 1
  fi
  return 0
}

aionui_fix() {
  warn "(Re)start the AionUi WebUI daemon, or re-run the phase (both idempotent):"
  warn "    bash $AI_STACK/vz-ai-stack.sh start aionui"
  warn "    bash $AI_STACK/vz-ai-stack.sh install 28"
  return 1
}
