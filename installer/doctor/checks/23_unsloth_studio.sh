# Unsloth Studio is installed and serving on :8898.
#
# Unsloth Studio is the local fine-tuning + training UI (Phase 14). It runs as
# a background python daemon under bin/start-unsloth.sh with a PID file at
# $STATE_DIR/unsloth.pid. This check verifies CLI presence, PID liveness,
# port binding, and HTTP /api/health responsiveness.
CHECKS+=(unsloth_studio)
CHECK_TITLE[unsloth_studio]="Unsloth Studio CLI installed + daemon serving :8898"

_unsloth_resolve_cli() {
  if command -v unsloth >/dev/null 2>&1; then command -v unsloth
  elif [[ -x "$HOME/.local/bin/unsloth" ]]; then echo "$HOME/.local/bin/unsloth"
  else echo ""
  fi
}

unsloth_studio_diagnose() {
  local bin pid pid_file health
  pid_file="$STATE_DIR/unsloth.pid"

  bin="$(_unsloth_resolve_cli)"
  if [[ -z "$bin" ]]; then
    echo "unsloth CLI not found (looked for: \$PATH, ~/.local/bin/unsloth)"
    return 1
  fi

  if [[ ! -f "$pid_file" ]]; then
    echo "no PID file at $pid_file (daemon not started)"
    return 1
  fi
  pid="$(cat "$pid_file" 2>/dev/null || echo "")"
  if [[ ! "$pid" =~ ^[0-9]+$ ]] || ! kill -0 "$pid" 2>/dev/null; then
    echo "PID file points at pid $pid which is not running"
    return 1
  fi

  if ! port_listening 8898; then
    echo "pid $pid alive but :8898 not bound"
    return 1
  fi

  health="$(curl -s --max-time 3 http://127.0.0.1:8898/api/health 2>/dev/null || echo "")"
  if [[ -z "$health" ]]; then
    echo ":8898 bound but /api/health returned no body"
    return 1
  fi
  if ! grep -q '"status":"healthy"' <<<"$health"; then
    echo "/api/health body did not include status=healthy: ${health:0:200}"
    return 1
  fi
}

unsloth_studio_fix() {
  if [[ -z "$(_unsloth_resolve_cli)" ]]; then
    warn "unsloth CLI missing. Re-run phase 14 to install:"
    warn "    bash $AI_STACK/install.sh install 14"
    return 1
  fi
  if [[ -x "$AI_STACK/bin/start-unsloth.sh" ]]; then
    log "Starting unsloth studio via bin/start-unsloth.sh..."
    bash "$AI_STACK/bin/start-unsloth.sh"
  else
    err "bin/start-unsloth.sh missing"
    return 1
  fi
}
