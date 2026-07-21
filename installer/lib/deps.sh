#!/usr/bin/env bash
# deps.sh — the authoritative HOST DEPENDENCY MAP + idempotent ensure routines.
#
# WHY: on a clean Mac the installer used to ASSUME yq/jq/node/OrbStack/Ollama were
# present and hard-exit telling the user to install them — preflight even gated on
# tools that Phase 00 is supposed to install, so the install phase was unreachable.
# This module replaces "assume + abort" with "verify + install + start + re-verify".
# Every routine is idempotent: a no-op on an already-prepared host.
#
# Tiers (see doc/PREREQUISITES.md for the full table):
#   0  bootstrap   — Homebrew, bash 5+, Xcode CLT (git/curl). Can't be brew-installed normally.
#   1  core CLI    — brew formulae the framework + many phases need (yq, jq, node@22, …).
#   2  services    — install AND start AND verify (OrbStack/docker, Ollama).
#   3  opt-in      — each owned by its own phase (lms, openshell, blaxel, …); NOT here.
#
# Sourced by vz-ai-stack.sh (after common.sh) and by Phase 00/01. Also runnable as
# `vz-ai-stack.sh deps [--check]`. Safe to source twice.

# --- the manifest (single source of truth; doc/PREREQUISITES.md mirrors this) ----
# Core brew formulae. `<formula>` may carry a version (node@22); the short name is
# used for `brew list`/`command -v`. Order is install order.
DEPS_FORMULAE=(bash yq jq node@22 pnpm uv git tesseract openssl@3)

# macOS built-ins we REQUIRE but never install — verify only, fail loud if absent
# (a broken PATH or a stripped base system). python3 is verified separately so we
# can offer to install it (it isn't always present until Xcode CLT / brew).
DEPS_BUILTINS=(awk grep sed stat mktemp lsof perl plutil launchctl open sysctl curl)

# Map a formula token to the command it provides (for post-install verification).
_dep_cmd_for() {
  case "$1" in
    node@22) echo node ;;
    openssl@3) echo openssl ;;
    *) echo "$1" ;;
  esac
}

# Fallbacks if sourced without common.sh (keeps deps.sh runnable standalone).
command -v log  >/dev/null 2>&1 || log()  { printf '  %s\n' "$*"; }
command -v ok   >/dev/null 2>&1 || ok()   { printf '✓ %s\n' "$*"; }
command -v warn >/dev/null 2>&1 || warn() { printf '⚠ %s\n' "$*" >&2; }
command -v err  >/dev/null 2>&1 || err()  { printf '✗ %s\n' "$*" >&2; }
command -v note >/dev/null 2>&1 || note() { printf '  %s\n' "$*"; }
command -v hdr  >/dev/null 2>&1 || hdr()  { printf '\n=== %s ===\n' "$*"; }

# The Docker-engine registry (engine_select/engine_ensure/engine_pin/engine_socket/
# engine_display/_engine_valid). vz-ai-stack.sh already sources it before deps.sh, but
# the standalone `deps`/phase entrypoints don't — source it here (idempotent, guarded
# by docker-engine.sh's own load-once flag) so ensure_docker_engine + deps_report's
# engine status block resolve their helpers. Needs AI_STACK (set by the caller).
[[ -n "${AI_STACK:-}" && -f "$AI_STACK/installer/lib/docker-engine.sh" ]] \
  && source "$AI_STACK/installer/lib/docker-engine.sh"

# --- small verified-wait helper (no coreutils dependency) --------------------
# _dep_wait <timeout_s> <description> <cmd...> : poll until <cmd> succeeds.
_dep_wait() {
  local timeout="$1" desc="$2"; shift 2
  local i=0
  until "$@" >/dev/null 2>&1; do
    sleep 1
    if (( ++i >= timeout )); then
      err "timed out after ${timeout}s waiting for: $desc"
      return 1
    fi
  done
  return 0
}

dep_have() { command -v "$1" >/dev/null 2>&1; }

# ===========================================================================
# TIER 0 — bootstrap
# ===========================================================================

# ensure_homebrew — install Homebrew if absent (it's the package manager every
# other dependency rides on). Confirms first unless NO_PROMPT=1 (then NONINTERACTIVE).
ensure_homebrew() {
  if dep_have brew; then return 0; fi
  # Maybe installed but not on PATH yet (fresh shell after install).
  local b
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$b" ]]; then eval "$("$b" shellenv)"; dep_have brew && { ok "Homebrew found at $b"; return 0; }; fi
  done
  warn "Homebrew is not installed — it's required to install everything else."
  if [[ "${NO_PROMPT:-0}" != "1" ]]; then
    printf '  Install Homebrew now via the official script? [Y/n] ' >&2
    local ans; read -r ans || true
    case "${ans:-Y}" in [Nn]*) err "Homebrew required. Install from https://brew.sh and re-run."; return 1 ;; esac
  fi
  log "Installing Homebrew (https://brew.sh)..."
  NONINTERACTIVE="${NO_PROMPT:+1}" /bin/bash -c \
    "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
    || { err "Homebrew install failed — install manually from https://brew.sh and re-run."; return 1; }
  for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    [[ -x "$b" ]] && eval "$("$b" shellenv)"
  done
  dep_have brew || { err "Homebrew installed but 'brew' still not on PATH — open a new shell and re-run."; return 1; }
  ok "Homebrew ready"
}

# ===========================================================================
# TIER 1 — core CLI tools
# ===========================================================================

# ensure_builtins — verify (never install) the macOS base tools we depend on.
# python3 is treated as installable (not always present on a bare system).
ensure_builtins() {
  local missing=()
  local t
  for t in "${DEPS_BUILTINS[@]}"; do dep_have "$t" || missing+=("$t"); done
  if (( ${#missing[@]} )); then
    err "Missing base system tool(s): ${missing[*]}"
    err "These ship with macOS — a missing one means a broken PATH or base system."
    err "Try: install the Xcode Command Line Tools ('xcode-select --install') and re-run."
    return 1
  fi
  if ! dep_have python3; then
    log "python3 not found — installing (brew python3)..."
    brew install python3 2>&1 | tail -3 || warn "brew install python3 exited non-zero; continuing"
    dep_have python3 || { err "python3 still missing — run 'xcode-select --install' or 'brew install python3' and re-run."; return 1; }
  fi
  return 0
}

# ensure_core_tools — install the core brew formulae that are missing, then verify.
# Per-formula (graceful on pre-existing symlink conflicts, e.g. a global npm pnpm).
ensure_core_tools() {
  ensure_homebrew || return 1
  ensure_builtins || return 1
  log "Verifying core CLI tools (brew formulae)..."
  local f short installed_any=0
  for f in "${DEPS_FORMULAE[@]}"; do
    short="${f%@*}"
    if brew list "$short" >/dev/null 2>&1 || brew list "$f" >/dev/null 2>&1; then
      continue
    fi
    log "Installing: $f"
    installed_any=1
    if ! brew install "$f" 2>&1 | tail -5; then
      # brew often exits non-zero on a symlink conflict while the binary IS in the
      # cellar and reachable. Verify by command before treating it as fatal.
      warn "brew install $f exited non-zero (likely a symlink conflict). Verifying..."
    fi
  done
  # node@22 is keg-only; relink so `node`/`npm` are on PATH.
  brew link --overwrite node@22 >/dev/null 2>&1 || true

  # Re-verify every formula actually provides its command now. No assumptions.
  local cmd missing=()
  for f in "${DEPS_FORMULAE[@]}"; do
    cmd="$(_dep_cmd_for "$f")"
    dep_have "$cmd" || missing+=("$f ($cmd)")
  done
  (( BASH_VERSINFO[0] >= 5 )) || missing+=("bash 5+ (you're on ${BASH_VERSINFO[0]}.x — open a new shell so brew-bash is on PATH)")
  if (( ${#missing[@]} )); then
    err "Core tools still missing after install: ${missing[*]}"
    err "Install them manually ('brew install <name>') and re-run."
    return 1
  fi
  (( installed_any )) && ok "core CLI tools installed" || ok "core CLI tools present"
  return 0
}

# ===========================================================================
# TIER 2 — runtime services (install AND start AND verify)
# ===========================================================================

# ensure_docker_engine — select + ensure the intentional Docker engine.
# Selection precedence handled by engine_select (flag/env/running/prompt/priority);
# engine_ensure installs (consent/NO_PROMPT) + starts + bounded-waits on the socket;
# engine_pin persists AI_STACK_DOCKER_ENGINE + exports DOCKER_HOST + rewrites gateway.env.
ensure_docker_engine() {
  ensure_homebrew || return 1
  local sel; sel="$(engine_select)" || return 1
  engine_ensure "$sel" || return 1
  engine_pin "$sel" || return 1
  return 0
}

# ensure_orbstack — retained name for back-compat with existing callers
# (phases 00/01, etc.). Now a thin wrapper that honors the selected engine.
ensure_orbstack() { ensure_docker_engine "$@"; }

# _dep_orbstack_caps — pin the OrbStack VM resource caps on a RAM-constrained box
# (defaults tuned for M4/24GB). The OrbStack VM cap is the real RAM lever (see the
# _dep_ollama_patch_env note). These caps DRIFT back toward host-max across OrbStack
# updates; on 24GB an oversized VM causes host swap thrash + the orbstack-helper
# page-fault CPU storm (the recurring "OrbStack 200% CPU"). Re-pin only if a value
# has drifted ABOVE the ceiling (idempotent no-op otherwise). We deliberately do NOT
# auto-restart OrbStack here — that would stop running containers mid-install; the
# new cap applies on the next OrbStack restart, and we say so.
AI_STACK_ORB_CPU_MAX="${AI_STACK_ORB_CPU_MAX:-8}"
AI_STACK_ORB_MEM_MIB_MAX="${AI_STACK_ORB_MEM_MIB_MAX:-6144}"
_dep_orbstack_caps() {
  command -v orb >/dev/null 2>&1 || return 0
  # get_env (env.sh) may not be loaded if deps.sh is sourced standalone — guard it.
  local eng
  if declare -F get_env >/dev/null 2>&1; then
    eng="$(get_env AI_STACK_DOCKER_ENGINE orbstack 2>/dev/null || echo orbstack)"
  else
    eng="${AI_STACK_DOCKER_ENGINE:-orbstack}"
  fi
  [[ "$eng" == "orbstack" ]] || return 0
  local cur_cpu cur_mem changed=0 cfg
  cfg="$(orb config show 2>/dev/null)" || return 0
  cur_cpu="$(awk -F': ' '/^cpu:/{print $2; exit}' <<<"$cfg")"
  cur_mem="$(awk -F': ' '/^memory_mib:/{print $2; exit}' <<<"$cfg")"
  if [[ "$cur_cpu" =~ ^[0-9]+$ ]] && (( cur_cpu > AI_STACK_ORB_CPU_MAX )); then
    orb config set cpu "$AI_STACK_ORB_CPU_MAX" >/dev/null 2>&1 && changed=1
  fi
  if [[ "$cur_mem" =~ ^[0-9]+$ ]] && (( cur_mem > AI_STACK_ORB_MEM_MIB_MAX )); then
    orb config set memory_mib "$AI_STACK_ORB_MEM_MIB_MAX" >/dev/null 2>&1 && changed=1
  fi
  if (( changed )); then
    warn "OrbStack VM caps drifted above the ceiling on a constrained box — re-pinned to cpu=${AI_STACK_ORB_CPU_MAX}, memory_mib=${AI_STACK_ORB_MEM_MIB_MAX}MiB (raise via AI_STACK_ORB_CPU_MAX / AI_STACK_ORB_MEM_MIB_MAX on a bigger box)."
    warn "Caps apply on the NEXT OrbStack restart — for the current session run 'orb stop' (OrbStack auto-restarts on next docker use). Prevents the swap-thrash / 200% CPU storm."
  fi
  return 0
}

# ensure_ollama — install Ollama, configure it for cross-container access + lazy
# memory, start it, and verify it responds. Centralized here so the env-patch
# ALWAYS runs right after install (it used to be in Phase 00, gated on ollama
# already existing — so a cold install, which installs ollama in Phase 01, never
# got patched and LiteLLM->ollama 403'd). See doc/PREREQUISITES.md.
ensure_ollama() {
  ensure_homebrew || return 1
  if ! dep_have ollama; then
    log "Installing Ollama..."
    brew install ollama 2>&1 | tail -5 || { err "brew install ollama failed."; return 1; }
    dep_have ollama || { err "ollama still not on PATH after install."; return 1; }
  fi
  # Start the service first so brew writes the launchd plist we then patch.
  # awk judges in END (consumes ALL input) — a trailing `| grep -q` SIGPIPEs
  # brew under pipefail → flaky "not started" → a spurious `brew services start`
  # (which can wipe the OLLAMA_HOST patch). Pipefail-EPIPE class, 2026-07-21.
  if ! brew services list 2>/dev/null | awk '$1=="ollama"{s=$2} END{exit (s=="started")?0:1}'; then
    log "Starting Ollama brew service..."
    brew services start ollama 2>&1 | tail -2 || warn "brew services start ollama returned non-zero"
  fi
  _dep_ollama_patch_env
  if ! _dep_wait 30 "Ollama API (:11434/api/tags)" curl -sf --max-time 3 http://127.0.0.1:11434/api/tags; then
    err "Ollama did not respond on :11434. Check 'brew services info ollama'."
    return 1
  fi
  ok "Ollama running (:11434, cross-container env applied)"
}

# Patch the brew ollama launchd plist so in-stack containers can reach it
# (OLLAMA_HOST=0.0.0.0 + OLLAMA_ORIGINS=*) and keep the default model warm during a
# work session (OLLAMA_KEEP_ALIVE=30m). KEEP_ALIVE=0 was previously used to avoid
# pinning RAM on a 24GB box, but it forced a ~17s cold-load on EVERY call — and the
# default model (nemotron-3-nano:4b) is only ~2.8GB resident, so a 30m idle window is cheap.
# The real RAM lever on a constrained box is the OrbStack VM cap, not this.
# Re-patches only if a key is MISSING *or set to a stale value* (e.g. a prior
# install's KEEP_ALIVE=0) — a presence-only check would silently leave an old
# value in place and never upgrade it.
_dep_ollama_patch_env() {
  local plist="$HOME/Library/LaunchAgents/homebrew.mxcl.ollama.plist"
  [[ -f "$plist" ]] || return 0   # not service-managed (rare) — nothing to patch
  # Enforce the DESIRED values, not mere presence (review finding 2026-06-19):
  # missing key OR wrong value → re-patch; all three already correct → no-op reload.
  local needs=0
  [[ "$(plutil -extract "EnvironmentVariables.OLLAMA_HOST"       raw "$plist" 2>/dev/null)" == "0.0.0.0" ]] || needs=1
  [[ "$(plutil -extract "EnvironmentVariables.OLLAMA_ORIGINS"    raw "$plist" 2>/dev/null)" == "*"       ]] || needs=1
  [[ "$(plutil -extract "EnvironmentVariables.OLLAMA_KEEP_ALIVE" raw "$plist" 2>/dev/null)" == "30m"     ]] || needs=1
  (( needs )) || return 0
  log "Patching Ollama for cross-container access (OLLAMA_HOST=0.0.0.0, ORIGINS=*, KEEP_ALIVE=30m)..."
  local pb=/usr/libexec/PlistBuddy
  "$pb" -c "Add :EnvironmentVariables:OLLAMA_HOST string 0.0.0.0" "$plist" 2>/dev/null || "$pb" -c "Set :EnvironmentVariables:OLLAMA_HOST 0.0.0.0" "$plist"
  "$pb" -c "Add :EnvironmentVariables:OLLAMA_ORIGINS string *" "$plist" 2>/dev/null || "$pb" -c "Set :EnvironmentVariables:OLLAMA_ORIGINS *" "$plist"
  "$pb" -c "Add :EnvironmentVariables:OLLAMA_KEEP_ALIVE string 30m" "$plist" 2>/dev/null || "$pb" -c "Set :EnvironmentVariables:OLLAMA_KEEP_ALIVE 30m" "$plist"
  launchctl setenv OLLAMA_HOST 0.0.0.0 2>/dev/null || true
  launchctl setenv OLLAMA_ORIGINS "*" 2>/dev/null || true
  launchctl setenv OLLAMA_KEEP_ALIVE 30m 2>/dev/null || true
  # Reload by booting the EDITED plist directly — NOT `brew services restart`, which
  # on modern Homebrew REGENERATES the plist from the formula and wipes the keys we
  # just added (the formula only declares FLASH_ATTENTION/KV_CACHE_TYPE). Verified:
  # after a brew regen the ollama process had no OLLAMA_HOST and bound 127.0.0.1, so
  # in-stack containers (LiteLLM) could not reach it. bootout+bootstrap loads the
  # on-disk plist as-is; `brew services list` still reports it started. Fallback to
  # brew restart only if the launchctl path is unavailable.
  local _uid; _uid="$(id -u)"
  # bootout may legitimately fail (service not currently loaded) — tolerate it so the
  # branch is decided ONLY by bootstrap (loading the edited plist), not by bootout.
  launchctl bootout "gui/${_uid}/homebrew.mxcl.ollama" 2>/dev/null || true
  sleep 1
  if ! launchctl bootstrap "gui/${_uid}" "$plist" 2>/dev/null; then
    # Last resort. WARNING: `brew services restart` REGENERATES the plist from the
    # formula and RE-WIPES the env we just set (the exact regression this function
    # exists to prevent) — a container call may still hit 127.0.0.1. Surface it loudly
    # so it isn't a silent re-break (review finding).
    warn "ollama: launchctl bootstrap failed — falling back to 'brew services restart', which may RE-WIPE OLLAMA_HOST. Verify 'lsof -nP -iTCP:11434' shows *:11434; re-run 'vz-ai-stack.sh doctor ollama_models' if local models 500."
    brew services restart ollama 2>&1 | tail -2 || warn "ollama reload failed"
  fi
}

# ===========================================================================
# Orchestration + reporting
# ===========================================================================

# bootstrap_host_deps — Tier 0 + 1 + the Docker service (Tier 2). Idempotent.
# Ollama (also Tier 2) is ensured by Phase 01 via ensure_ollama right before it
# pulls models, so its install+config+start+model-pull stay one coherent step.
bootstrap_host_deps() {
  ensure_core_tools || return 1
  ensure_orbstack   || return 1
  _dep_orbstack_caps || true   # pin VM caps on a constrained box (idempotent; non-fatal)
  return 0
}

# deps_report [--check] — print the dependency map with live status. With --check,
# exit non-zero if anything is missing/down (read-only; never installs). Without a
# flag, install/start what's missing (verified actions), then report.
deps_report() {
  local check_only=0
  [[ "${1:-}" == "--check" ]] && check_only=1
  hdr "Host dependency map (macOS Apple Silicon)"

  local rc=0 f cmd
  # _drow <label> <tier> <status> — print a status row. Status + rc are computed
  # in the PARENT shell (NOT inside $()) so a MISSING actually bumps rc.
  _drow() { printf '  %-22s %-10s %s\n' "$1" "$3" "$2"; }
  printf '  %-22s %-10s %s\n' "DEPENDENCY" "STATUS" "TIER"

  if dep_have brew;                then _drow "brew" "0 bootstrap" present; else _drow "brew" "0 bootstrap" MISSING; rc=1; fi
  if (( BASH_VERSINFO[0] >= 5 ));   then _drow "bash 5+" "0 bootstrap" present; else _drow "bash 5+" "0 bootstrap" OLD; rc=1; fi
  for f in "${DEPS_FORMULAE[@]}"; do
    [[ "$f" == bash ]] && continue
    cmd="$(_dep_cmd_for "$f")"
    if dep_have "$cmd";             then _drow "$f" "1 core" present; else _drow "$f" "1 core" MISSING; rc=1; fi
  done
  if dep_have python3;              then _drow "python3" "1 core" present; else _drow "python3" "1 core" MISSING; rc=1; fi
  # Timeout-bound the probe (a wedged daemon must never hang deps_report) + name the
  # SELECTED engine when one is pinned (else a generic label). _engine_docker_timeout
  # is in scope (deps.sh sources docker-engine.sh).
  local _dr_eng _dr_label="docker engine (2 service)"
  _dr_eng="$(get_env AI_STACK_DOCKER_ENGINE "" 2>/dev/null || true)"
  [[ -n "$_dr_eng" ]] && _engine_valid "$_dr_eng" 2>/dev/null && _dr_label="$(engine_display "$_dr_eng" 2>/dev/null || echo "$_dr_eng")"
  if _engine_docker_timeout 6 docker info >/dev/null 2>&1; then _drow "$_dr_label" "2 service" running; else _drow "$_dr_label" "2 service" DOWN; rc=1; fi
  if curl -sf --max-time 3 http://127.0.0.1:11434/api/tags >/dev/null 2>&1; then
    _drow "Ollama (:11434)" "2 service" running; else _drow "Ollama (:11434)" "2 service" DOWN; rc=1; fi

  # --- Docker engine selection ---------------------------------------------
  # READ-ONLY status (runs on BOTH the --check and the install paths, so it never
  # depends on the install side-effects below). Reads only: get_env, engine_socket,
  # `docker context inspect`, and a grep of gateway.env. No engine_pin, no install.
  local _sel _sock _gw_host _ctx_host
  _sel="$(get_env AI_STACK_DOCKER_ENGINE "" 2>/dev/null || true)"
  if [[ -n "$_sel" ]] && _engine_valid "$_sel"; then
    _sock="$(engine_socket "$_sel" 2>/dev/null || echo '?')"
    # Resolve the context NAME first (timeout-bound), THEN inspect it — avoids the
    # racy nested-$() (an inner timeout firing leaves the outer with an empty name)
    # and the empty-context edge (no name → `inspect ""` would error). Both calls are
    # bounded so a wedged daemon can never hang deps_report. `|| echo '?'` keeps the fallback.
    local _ctx_name; _ctx_name="$(_engine_docker_timeout 5 docker context show 2>/dev/null || true)"
    _ctx_host="?"
    if [[ -n "$_ctx_name" ]]; then
      _ctx_host="$(_engine_docker_timeout 5 docker context inspect "$_ctx_name" \
                     --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || echo '?')"
    fi
    _gw_host="$(grep -E '^DOCKER_HOST=' "$HOME/.config/openshell/gateway.env" 2>/dev/null | tail -1 | cut -d= -f2- || echo '?')"
    note "Docker engine: $_sel ($(engine_display "$_sel"))   socket: $_sock"
    [[ "$_ctx_host" == "$_sock" ]] && ok "  CLI context socket == selected" || warn "  CLI context socket ($_ctx_host) != selected ($_sock)"
    [[ "$_gw_host"  == "$_sock" ]] && ok "  gateway.env socket == selected" || warn "  gateway.env socket != selected ($_gw_host vs $_sock) — run: vz-ai-stack.sh doctor (docker-engine-consistency check)"
  else
    # ADVISORY ONLY — deliberately does NOT bump rc. Engine selection is materialized
    # during install / Phase 00, so a pre-install box must not hard-fail
    # `deps_report --check` merely because no engine is pinned yet.
    warn "Docker engine: not selected — run: vz-ai-stack.sh docker-engine select"
  fi

  if (( check_only )); then
    echo
    (( rc == 0 )) && ok "all host dependencies present + services running" \
                  || err "one or more host dependencies missing/down (run 'vz-ai-stack.sh deps' to install)"
    return $rc
  fi
  if (( rc )); then
    echo
    log "Installing/starting missing dependencies (verified actions)..."
    bootstrap_host_deps || return 1
    ensure_ollama || return 1
    ok "host dependencies ensured"
  else
    ok "all host dependencies already present + running"
  fi
  return 0
}
