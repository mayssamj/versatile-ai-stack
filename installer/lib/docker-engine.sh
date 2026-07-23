# docker-engine.sh — the Docker-engine registry: single source of truth for
# per-engine probes, sockets, and host.docker.internal handling.
# Sourced after common.sh + env.sh (engine_socket/engine_select need get_env/set_env).
#
# Value space of AI_STACK_DOCKER_ENGINE (.env): orbstack | docker-desktop | colima | podman
# All `docker -H … info` probes are timeout-bounded so a wedged daemon never hangs us.

# AI_STACK is normally exported by mayssam-ai-stack.sh (the sourcing parent). When this
# file is RUN DIRECTLY as the docker-engine CLI it self-resolves AI_STACK from its
# own path (../../) — matching fleet.sh shape — so the CLI works standalone too.
if [[ -z "${AI_STACK:-}" ]]; then
  AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." 2>/dev/null && pwd -P)" \
    || { echo "docker-engine.sh: AI_STACK unset and unresolvable" >&2; exit 2; }
fi

# Idempotent: a second source (e.g. mayssam-ai-stack.sh sources us, then docker.sh re-sources) is a no-op.
# Guard the early-return on SOURCED context: on a DIRECT run a `return` is illegal
# ("return: can only return from a function or sourced script"), so only short-circuit
# when actually sourced (BASH_SOURCE[0] != $0) AND already loaded.
[[ "${BASH_SOURCE[0]}" != "${0}" && -n "${_AI_STACK_DOCKER_ENGINE_LOADED:-}" ]] && return 0
_AI_STACK_DOCKER_ENGINE_LOADED=1

# Priority order is also the NO_PROMPT tie-break order (spec §key-decisions 3).
ENGINE_IDS="orbstack docker-desktop colima podman"

# _engine_valid <id> — exit 0 if id is one of ENGINE_IDS.
_engine_valid() {
  local id="$1" e
  for e in $ENGINE_IDS; do [[ "$e" == "$id" ]] && return 0; done
  return 1
}

# engine_display <id> — human label.
engine_display() {
  case "$1" in
    orbstack)       printf '%s' "OrbStack" ;;
    docker-desktop) printf '%s' "Docker Desktop" ;;
    colima)         printf '%s' "Colima" ;;
    podman)         printf '%s' "Podman" ;;
    *) err "engine_display: unknown engine id: $1"; return 2 ;;
  esac
}

# engine_addhost_args <id> — emit the host.docker.internal flag ONLY for engines
# that do not auto-inject it (Colima, Podman). OrbStack/Docker Desktop: nothing.
engine_addhost_args() {
  case "$1" in
    orbstack|docker-desktop) : ;;   # auto-injected; emit nothing
    colima|podman)           printf '%s' "--add-host=host.docker.internal:host-gateway" ;;
    *) err "engine_addhost_args: unknown engine id: $1"; return 2 ;;
  esac
}

# _engine_docker_timeout <secs> -- <cmd...> — run a docker probe with a hard cap.
# macOS ships no coreutils `timeout`; use a background pid + kill fallback.
_engine_docker_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"; return $?
  fi
  "$@" &
  local pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
  local killer=$!
  local rc=0
  wait "$pid" 2>/dev/null || rc=$?
  kill -TERM "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  return $rc
}

# engine_socket <id> — echo the resolved DOCKER_HOST value (unix://… or tcp://…).
# Probed/derived, never blindly assumed. Returns 1 (empty) if unresolvable.
engine_socket() {
  local id="$1"
  _engine_valid "$id" || { err "engine_socket: unknown engine id: $id"; return 2; }
  case "$id" in
    orbstack)
      printf '%s' "unix://$HOME/.orbstack/run/docker.sock"
      ;;
    docker-desktop)
      # NOTE: docker-desktop socket resolution is UNVERIFIED on the build box (per the
      # support matrix — Docker Desktop is not installed here). On modern Docker Desktop
      # the LIVE socket is $HOME/.docker/run/docker.sock, while the `desktop-linux`
      # context endpoint can be STALE — so prefer the present per-user socket FIRST,
      # fall back to the context endpoint, then the legacy /var/run socket.
      if [[ -S "$HOME/.docker/run/docker.sock" ]]; then
        printf '%s' "unix://$HOME/.docker/run/docker.sock"; return 0
      fi
      # Fallback: Docker Desktop's own context endpoint. WRAPPED in the timeout so a
      # wedged docker CLI cannot hang the central export.
      local ep
      ep="$(_engine_docker_timeout 6 docker context inspect desktop-linux \
              --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || true)"
      if [[ -n "$ep" ]]; then printf '%s' "$ep"; return 0; fi
      if [[ -S /var/run/docker.sock ]]; then
        printf '%s' "unix:///var/run/docker.sock"; return 0
      fi
      return 1
      ;;
    colima)
      # `colima status` prints a `socket:` line; fall back to the conventional path.
      # WRAPPED in the timeout — a wedged colima CLI must not hang the export.
      local sock
      sock="$(_engine_docker_timeout 6 colima status 2>&1 | awk -F': *' '/[Ss]ocket:/{print $2; exit}' || true)"
      if [[ "$sock" == unix://* ]]; then printf '%s' "$sock"; return 0; fi
      # Sanitize COLIMA_PROFILE so it cannot escape $HOME/.colima/ (path traversal):
      # a profile containing a slash or leading dot is rejected back to "default".
      local _profile="${COLIMA_PROFILE:-default}"
      [[ "$_profile" == */* || "$_profile" == .* ]] && _profile="default"
      local conv="$HOME/.colima/$_profile/docker.sock"
      if [[ -S "$conv" ]]; then printf '%s' "unix://$conv"; return 0; fi
      log "engine_socket colima: socket path ASSUMED ($conv) — unverified on this host" >&2
      return 1
      ;;
    podman)
      # PodmanSocket.Path speaks the Docker API (podman 5.x). UNVERIFIED on this box.
      # WRAPPED in the timeout — podman machine inspect can hang on a wedged VM.
      local p
      p="$(_engine_docker_timeout 6 podman machine inspect \
             --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || true)"
      if [[ -n "$p" && -S "$p" ]]; then printf '%s' "unix://$p"; return 0; fi
      log "engine_socket podman: socket path ASSUMED via 'podman machine inspect' — unverified on this host" >&2
      return 1
      ;;
  esac
}

# engine_installed <id> — exit 0 if the engine's app/binary is present.
engine_installed() {
  local id="$1"
  _engine_valid "$id" || { err "engine_installed: unknown engine id: $id"; return 2; }
  case "$id" in
    orbstack)
      [[ -d /Applications/OrbStack.app ]] && return 0
      brew list --cask orbstack >/dev/null 2>&1 && return 0
      command -v orb >/dev/null 2>&1 && return 0
      return 1 ;;
    docker-desktop)
      [[ -d /Applications/Docker.app ]] && return 0
      brew list --cask docker-desktop >/dev/null 2>&1 && return 0
      brew list --cask docker >/dev/null 2>&1 && return 0   # legacy cask name
      return 1 ;;
    colima)
      command -v colima >/dev/null 2>&1 ;;
    podman)
      command -v podman >/dev/null 2>&1 ;;
  esac
}

# engine_detect_installed — echo installed engine ids, one per line, priority order.
engine_detect_installed() {
  local e
  for e in $ENGINE_IDS; do engine_installed "$e" && printf '%s\n' "$e"; done
}

# engine_running <id> — exit 0 if THAT engine's daemon answers (timeout-bounded).
engine_running() {
  local id="$1" sock
  _engine_valid "$id" || { err "engine_running: unknown engine id: $id"; return 2; }
  sock="$(engine_socket "$id" 2>/dev/null)" || return 1
  [[ -n "$sock" ]] || return 1
  _engine_docker_timeout 6 docker -H "$sock" info >/dev/null 2>&1
}

# engine_detect_running — echo running engine ids, one per line, priority order.
engine_detect_running() {
  local e
  for e in $ENGINE_IDS; do engine_running "$e" && printf '%s\n' "$e"; done
}

# engine_select — resolve the engine id by precedence and echo it to STDOUT.
#   1. --engine flag (passed as env var AI_STACK_ENGINE_FLAG by the caller)
#   2. AI_STACK_DOCKER_ENGINE in .env
#   3. the single RUNNING engine (if exactly one runs)
#   4. interactive prompt (skipped under NO_PROMPT / non-TTY)
#   5. NO_PROMPT fallback: first INSTALLED engine in ENGINE_IDS priority order,
#      else the first id in ENGINE_IDS. Logged loudly.
# Reasons go to STDERR; only the chosen id goes to STDOUT.
# Returns 1 (NOT 2) for caller-recoverable bad input (bad flag / bad .env / bad
# interactive choice) so a guarded `sel="$(engine_select)" || {…}` caller can
# recover under inherit_errexit. (2 is reserved for the _engine_valid programming
# error in the pure accessors, which callers always pre-validate.)
engine_select() {
  local flag="${AI_STACK_ENGINE_FLAG:-}"
  if [[ -n "$flag" ]]; then
    _engine_valid "$flag" || { err "engine_select: unknown --engine id '$flag' (want: $ENGINE_IDS)"; return 1; }
    log "engine: $flag (from --engine flag)" >&2
    printf '%s' "$flag"; return 0
  fi

  local pinned; pinned="$(get_env AI_STACK_DOCKER_ENGINE "")"
  if [[ -n "$pinned" ]]; then
    if ! _engine_valid "$pinned"; then
      err "engine_select: .env AI_STACK_DOCKER_ENGINE='$pinned' is invalid (want: $ENGINE_IDS)"; return 1
    fi
    log "engine: $pinned (from AI_STACK_DOCKER_ENGINE in .env)" >&2
    printf '%s' "$pinned"; return 0
  fi

  local running; running="$(engine_detect_running)"
  local n; n="$(printf '%s' "$running" | grep -c . || true)"
  if [[ "$n" == "1" ]]; then
    log "engine: $running (the single running engine)" >&2
    printf '%s' "$running"; return 0
  fi

  # Interactive prompt — skipped under NO_PROMPT or no TTY.
  if [[ "${NO_PROMPT:-0}" != "1" && -t 0 ]]; then
    local installed; installed="$(engine_detect_installed)"
    # Enter-default = first INSTALLED engine (same first-installed logic as the
    # NO_PROMPT priority path), else the priority head if none detected.
    # Slice the first line in-shell (no `| head` — SIGPIPE would trip pipefail).
    local dflt="${installed%%$'\n'*}"
    [[ -n "$dflt" ]] || dflt="${ENGINE_IDS%% *}"
    printf '  Multiple/zero engines detected. Choose a Docker engine:\n' >&2
    local e
    for e in $ENGINE_IDS; do
      local mark=""
      grep -qx "$e" <<<"$installed" && mark=" [installed]"
      grep -qx "$e" <<<"$running"   && mark="$mark [running]"
      printf '    - %s (%s)%s\n' "$e" "$(engine_display "$e")" "$mark" >&2
    done
    printf '  engine id [%s]: ' "$dflt" >&2
    local ans; read -r ans || true
    ans="${ans:-$dflt}"
    _engine_valid "$ans" || { err "engine_select: invalid choice '$ans'"; return 1; }
    log "engine: $ans (interactive choice)" >&2
    printf '%s' "$ans"; return 0
  fi

  # NO_PROMPT / non-TTY fallback: fixed priority, prefer installed.
  local e
  for e in $ENGINE_IDS; do
    if engine_installed "$e"; then
      warn "engine: $e (NO_PROMPT fixed-priority fallback — first INSTALLED of: $ENGINE_IDS)"
      printf '%s' "$e"; return 0
    fi
  done
  e="${ENGINE_IDS%% *}"
  warn "engine: $e (NO_PROMPT fixed-priority fallback — none installed; first of: $ENGINE_IDS)"
  printf '%s' "$e"
}

# engine_install <id> — the brew remediation string + (if interactive) run it.
# Echoes the exact command on the err path so NO_PROMPT callers can copy it.
engine_install_cmd() {
  case "$1" in
    orbstack)       printf '%s' "brew install --cask orbstack" ;;
    docker-desktop) printf '%s' "brew install --cask docker-desktop" ;;
    colima)         printf '%s' "brew install colima docker" ;;
    podman)         printf '%s' "brew install podman docker" ;;
    *) return 2 ;;
  esac
}

engine_install() {
  local id="$1"
  _engine_valid "$id" || { err "engine_install: unknown engine id: $id"; return 2; }
  # NO_PROMPT path is hands-off and MUST stay offline: hard-fail with the static
  # remedy (engine_install_cmd) — never call `brew info` here (no network).
  if [[ "${NO_PROMPT:-0}" == "1" ]]; then
    err "$(engine_display "$id") not installed. Install it and re-run:"
    err "    $(engine_install_cmd "$id")"
    return 1
  fi
  # Interactive only: resolve the docker-desktop cask token BEFORE the prompt so the
  # user consents to the EXACT command that runs (cask churned docker → docker-desktop).
  # The `brew info` probe is intentionally lazy — it is reached only on the consent path.
  local -a cmd
  case "$id" in
    orbstack)       cmd=(brew install --cask orbstack) ;;
    docker-desktop)
      if brew info --cask docker-desktop >/dev/null 2>&1; then cmd=(brew install --cask docker-desktop)
      else cmd=(brew install --cask docker); fi ;;
    colima)         cmd=(brew install colima docker) ;;
    podman)         cmd=(brew install podman docker) ;;
  esac
  printf '  Install %s now via: %s ? [Y/n] ' "$(engine_display "$id")" "${cmd[*]}" >&2
  local ans; read -r ans || true
  case "${ans:-Y}" in
    [Nn]*) err "declined; install manually: ${cmd[*]}"; return 1 ;;
  esac
  log "Running: ${cmd[*]}"
  # Array invocation — no eval. Pipe through tail WITHOUT losing the install rc:
  # `set -o pipefail` (in the subshell) makes the pipeline's status the brew rc,
  # not tail's (which is always 0). Without it a failed `brew install` is invisible.
  if ! ( set -o pipefail; "${cmd[@]}" 2>&1 | tail -8 ); then err "install failed: ${cmd[*]}"; return 1; fi
}

# engine_start <id> — start that engine's daemon (does not wait).
# TODO(follow-up): bound the colima/podman start (`colima start` / `podman machine
# start|init` can hang on a wedged VM) the way engine_running probes are bounded.
engine_start() {
  local id="$1"
  _engine_valid "$id" || { err "engine_start: unknown engine id: $id"; return 2; }
  case "$id" in
    orbstack)       open -a OrbStack 2>/dev/null || true ;;
    docker-desktop) open -a Docker 2>/dev/null || true ;;
    colima)         colima start 2>&1 | tail -4 || true ;;
    podman)
      # Init the machine on first run, else start it.
      if podman machine inspect >/dev/null 2>&1; then
        podman machine start 2>&1 | tail -4 || true
      else
        podman machine init --now 2>&1 | tail -6 || true
      fi
      ;;
  esac
}

# engine_ensure <id> — install-if-missing (consent/NO_PROMPT) + start + bounded wait.
engine_ensure() {
  local id="$1"
  _engine_valid "$id" || { err "engine_ensure: unknown engine id: $id"; return 2; }
  if ! engine_installed "$id"; then
    engine_install "$id" || return 1
  fi
  if engine_running "$id"; then
    ok "$(engine_display "$id") daemon ready"
    return 0
  fi
  log "Starting $(engine_display "$id")..."
  engine_start "$id"
  local i=0
  until engine_running "$id"; do
    sleep 2
    (( ++i > 45 )) && {
      err "$(engine_display "$id") did not answer on its socket within 90s."
      err "Start it manually and re-run. (socket: $(engine_socket "$id" 2>/dev/null || echo '?'))"
      return 1
    }
  done
  ok "$(engine_display "$id") daemon ready"
}

# engine_write_gateway_env <id> [gw_file] — the ONE place that authors gateway.env.
# Idempotent: returns 0 if it (re)wrote the file, 1 if it was already current.
# Honors ENGINE_GATEWAY_ENV_FILE (test override) when no explicit gw_file is given.
engine_write_gateway_env() {
  local id="$1"
  local gw="${2:-${ENGINE_GATEWAY_ENV_FILE:-$HOME/.config/openshell/gateway.env}}"
  _engine_valid "$id" || { err "engine_write_gateway_env: unknown engine id: $id"; return 2; }
  local sock; sock="$(engine_socket "$id")" || {
    err "engine_write_gateway_env: cannot resolve socket for $id"; return 2; }
  mkdir -p "$(dirname "$gw")"   # atomic_write's mktemp needs the dir to exist
  if grep -qxF "OPENSHELL_DRIVERS=docker" "$gw" 2>/dev/null \
     && grep -qxF "DOCKER_HOST=$sock" "$gw" 2>/dev/null; then
    return 1   # already current — no change
  fi
  # atomic_write (common.sh): mktemp → chmod 600 → write-from-stdin → mv -f.
  # No partial/truncated file ever visible to a concurrent gateway read.
  atomic_write "$gw" <<EOF
# Written by ai-stack docker-engine (engine: $id).
# Sourced by /opt/homebrew/opt/openshell/libexec/openshell-gateway-homebrew-service
# before the gateway binary exec'es.
OPENSHELL_DRIVERS=docker
DOCKER_HOST=$sock
EOF
  return 0   # wrote/changed
}

# engine_pin <id> — persist + propagate the selected engine everywhere.
#   - set_env AI_STACK_DOCKER_ENGINE
#   - export DOCKER_HOST (so the current process + children inherit it)
#   - rewrite gateway.env via engine_write_gateway_env (single writer)
#   - apply the global-docker-context PREFERENCE (engine_apply_context) — NEVER
#     prompts; driven by AI_STACK_DOCKER_CONTEXT (set via `setup` / `docker-engine
#     context`). This keeps install/doctor fully non-interactive.
# Returns 1 (caller-recoverable) on socket/persist failure.
engine_pin() {
  local id="$1"
  _engine_valid "$id" || { err "engine_pin: unknown engine id: $id"; return 2; }
  local sock; sock="$(engine_socket "$id")" || {
    err "engine_pin: cannot resolve socket for $id — is the daemon up?"; return 1; }

  set_env AI_STACK_DOCKER_ENGINE "$id" || return 1
  export DOCKER_HOST="$sock"
  ok "pinned AI_STACK_DOCKER_ENGINE=$id (DOCKER_HOST=$sock)"

  if engine_write_gateway_env "$id"; then
    ok "wrote gateway.env (DOCKER_HOST=$sock) — restart the gateway for it to take effect"
  fi

  engine_apply_context "$id" "$sock"
}

# engine_apply_context <id> <sock> — apply the persisted global-docker-context
# preference. NON-INTERACTIVE by design (no `read`, no TTY gate) so install /
# doctor never block. The preference lives in AI_STACK_DOCKER_CONTEXT:
#   switch (default) → silently point the global `docker context` at ai-stack-<id>.
#                      The PRIOR (non-ai-stack) context is recorded ONCE in
#                      AI_STACK_DOCKER_CONTEXT_PRIOR so the switch is reversible.
#   keep             → never touch the user's global docker context.
# Resolution: the process env var (AI_STACK_DOCKER_CONTEXT) overrides the .env
# value — a hook for tests/CI and one-off runs. Any unrecognized value is treated
# as `keep` (fail-safe: never silently mutate the user's world on a typo).
engine_apply_context() {
  local id="$1" sock="$2"
  command -v docker >/dev/null 2>&1 || return 0
  local pref; pref="${AI_STACK_DOCKER_CONTEXT:-$(get_env AI_STACK_DOCKER_CONTEXT switch)}"
  [[ "$pref" == "switch" ]] || return 0   # keep / unknown → leave global context untouched

  local ctx="ai-stack-$id" cur
  cur="$(docker context show 2>/dev/null || echo default)"
  [[ "$cur" == "$ctx" ]] && return 0       # already pointed there — idempotent no-op

  # Record the prior (non-ai-stack) context ONCE — the undo target. Guard against
  # overwriting it with one of our own ai-stack-* contexts on a later switch.
  if [[ "$cur" != ai-stack-* && -z "$(get_env AI_STACK_DOCKER_CONTEXT_PRIOR "")" ]]; then
    set_env AI_STACK_DOCKER_CONTEXT_PRIOR "$cur" || true
  fi
  docker context inspect "$ctx" >/dev/null 2>&1 \
    || docker context create "$ctx" --docker "host=$sock" --description "ai-stack $id" >/dev/null 2>&1 \
    || docker context update "$ctx" --docker "host=$sock" >/dev/null 2>&1 || true
  if docker context use "$ctx" >/dev/null 2>&1; then
    local undo; undo="$(get_env AI_STACK_DOCKER_CONTEXT_PRIOR default)" || undo="default"   # inherit_errexit-safe
    ok "docker context → $ctx (undo: docker context use $undo, or: mayssam-ai-stack.sh docker-engine context keep)"
  else
    warn "could not switch global docker context to $ctx (DOCKER_HOST still pins the stack correctly)"
  fi
}

# engine_restore_context — undo an auto-switch: point the global docker context
# back at the recorded prior (AI_STACK_DOCKER_CONTEXT_PRIOR). Used by
# `docker-engine context keep`. No-op (success) when nothing to restore.
engine_restore_context() {
  command -v docker >/dev/null 2>&1 || return 0
  local cur prior
  cur="$(docker context show 2>/dev/null || echo default)"
  [[ "$cur" == ai-stack-* ]] || return 0   # not on an ai-stack context → nothing to undo
  prior="$(get_env AI_STACK_DOCKER_CONTEXT_PRIOR "")" || prior=""   # guard: inherit_errexit-safe
  [[ -n "$prior" ]] || prior="default"
  if docker context use "$prior" >/dev/null 2>&1; then
    ok "docker context restored → $prior"
  else
    warn "could not restore docker context to '$prior' (try: docker context use default)"
  fi
}

# --- CLI entrypoint: docker-engine [status|select|set <id>] -----------------
_engine_usage() {
  cat >&2 <<'EOF'
docker-engine — intentional Docker engine selection (orbstack|docker-desktop|colima|podman)
  mayssam-ai-stack.sh docker-engine status            show selected engine, resolved socket, CLI/gateway consistency
  mayssam-ai-stack.sh docker-engine select [--engine <id>]   (re-)select + ensure + pin the engine
  mayssam-ai-stack.sh docker-engine set <id>          set the engine to <id> explicitly (ensure + pin)
  mayssam-ai-stack.sh docker-engine context [status|switch|keep]   global docker-context policy
                                                 switch = auto-point global context at ai-stack-<engine> (default)
                                                 keep   = never touch it (restores the prior context now)
EOF
}

_engine_status() {
  local sel; sel="$(get_env AI_STACK_DOCKER_ENGINE "")"
  if [[ -z "$sel" ]]; then
    warn "no engine selected (AI_STACK_DOCKER_ENGINE unset). Run: mayssam-ai-stack.sh docker-engine select"
    return 1
  fi
  _engine_valid "$sel" || { err "AI_STACK_DOCKER_ENGINE='$sel' is invalid (want: $ENGINE_IDS)"; return 1; }
  local sock; sock="$(engine_socket "$sel" 2>/dev/null || echo '?')"
  note "engine:      $sel ($(engine_display "$sel"))"
  note "DOCKER_HOST: $sock"
  engine_running "$sel" && ok "daemon:      reachable" || warn "daemon:      NOT reachable (run: mayssam-ai-stack.sh docker-engine select)"
  local gw; gw="$(grep -E '^DOCKER_HOST=' "${ENGINE_GATEWAY_ENV_FILE:-$HOME/.config/openshell/gateway.env}" 2>/dev/null | tail -1 | cut -d= -f2- || echo '?')"
  [[ "$gw" == "$sock" ]] && ok "gateway.env: == selected" || warn "gateway.env: $gw (!= $sock)"
  local pref; pref="$(get_env AI_STACK_DOCKER_CONTEXT switch)" || pref="switch"   # inherit_errexit-safe
  note "context:     $pref (global docker-context policy — change: docker-engine context <switch|keep>)"
  return 0
}

# Only run the CLI dispatch when executed directly (bash docker-engine.sh ...),
# NOT when sourced by mayssam-ai-stack.sh.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # Run-directly path: this file is normally SOURCED after common.sh+env.sh (which
  # define note/warn/ok/err and get_env). When invoked as a standalone CLI we must
  # source those deps ourselves, in the canonical order (common first). Guarded so
  # a re-source is a no-op.
  declare -F note    >/dev/null 2>&1 || source "$AI_STACK/installer/lib/common.sh"
  declare -F get_env >/dev/null 2>&1 || source "$AI_STACK/installer/lib/env.sh"
  _de_main() {
    local sub="${1:-}"; shift || true
    case "$sub" in
      status) _engine_status ;;
      select)
        # Accept BOTH `--engine <id>` (space) and `--engine=<id>`, plus a bare
        # positional <id>. Implement the shift-latch for the space form.
        local flag="" expect_engine=0
        for a in "$@"; do
          if (( expect_engine )); then flag="$a"; expect_engine=0; continue; fi
          case "$a" in
            --engine)   expect_engine=1 ;;             # next token is the value
            --engine=*) flag="${a#--engine=}" ;;
            -*) err "docker-engine select: unknown flag: $a"; exit 2 ;;
            *) [[ -z "$flag" ]] && flag="$a" || { err "docker-engine select: too many args"; exit 2; } ;;
          esac
        done
        (( expect_engine )) && { err "docker-engine select: --engine needs an <id>"; exit 2; }
        local sel; sel="$(AI_STACK_ENGINE_FLAG="$flag" engine_select)" || exit $?
        engine_ensure "$sel" || exit $?
        engine_pin "$sel" || exit $?
        ;;
      context)
        # Manage the global docker-context POLICY (persisted in AI_STACK_DOCKER_CONTEXT).
        local act="${1:-status}"
        case "$act" in
          status)
            local pref; pref="$(get_env AI_STACK_DOCKER_CONTEXT switch)" || pref="switch"
            local cur="?"; command -v docker >/dev/null 2>&1 && cur="$(docker context show 2>/dev/null || echo '?')"
            note "policy:      $pref (switch=auto-point global context at ai-stack-<engine>; keep=never touch)"
            note "current ctx: $cur"
            note "prior ctx:   $(get_env AI_STACK_DOCKER_CONTEXT_PRIOR '(none recorded)')"
            ;;
          switch)
            set_env AI_STACK_DOCKER_CONTEXT switch || exit 1
            ok "docker-context policy → switch"
            local sel; sel="$(get_env AI_STACK_DOCKER_ENGINE "")" || sel=""
            if [[ -n "$sel" ]] && _engine_valid "$sel"; then
              local sock; sock="$(engine_socket "$sel" 2>/dev/null || true)"
              [[ -n "$sock" ]] && engine_apply_context "$sel" "$sock"
            fi
            ;;
          keep)
            set_env AI_STACK_DOCKER_CONTEXT keep || exit 1
            ok "docker-context policy → keep"
            engine_restore_context
            ;;
          *) err "docker-engine context: unknown action '$act' (want status|switch|keep)"; exit 2 ;;
        esac
        ;;
      set)
        local id="${1:-}"
        [[ -n "$id" ]] || { err "docker-engine set: missing <id> (want: $ENGINE_IDS)"; exit 2; }
        _engine_valid "$id" || { err "docker-engine set: invalid id '$id' (want: $ENGINE_IDS)"; exit 2; }
        engine_ensure "$id" || exit $?
        engine_pin "$id" || exit $?
        ;;
      ""|-h|--help|help) _engine_usage ;;
      *) err "docker-engine: unknown subcommand '$sub' (want status|select|set|context)"; exit 2 ;;
    esac
  }
  _de_main "$@"
fi
