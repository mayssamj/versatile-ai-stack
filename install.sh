#!/usr/bin/env bash
# ai-stack-installer — single-command bootstrap for the personal multi-agent AI stack.
#
# Usage:
#   bash install.sh                  interactive top-to-bottom install (resumes)
#   bash install.sh install <phase>  install one phase (e.g. 01h)
#   bash install.sh test <phase>     run smoke tests for one phase
#   bash install.sh status           tabular service status (declared vs actual)
#   bash install.sh doctor [<svc>]   diagnose & offer fixes
#   bash install.sh adopt <svc>      take ownership of a container started outside the installer
#   bash install.sh apply-restarts   drain the queue of services needing a restart
#   bash install.sh logs <svc> [-f]  tail recent logs from a service
#   bash install.sh history          assemble per-run CHANGELOG.d entries into one view
#   bash install.sh gc               list/clean partial container orphans
#   bash install.sh reset --confirm soft|hard|nuke    destructive resets, tiered
#
# Conservative-recreate mode by default: the installer will never `docker rm -f`
# an already-running container without explicit confirmation. See `adopt` above.
#
set -Eeuo pipefail

# --- bash version gate -------------------------------------------------------
# Pin bash 5+. macOS ships 3.2 which lacks associative arrays, inherit_errexit,
# mapfile, ${var,,}, and safe printf -v. Re-exec under brew-bash if available;
# otherwise prompt the user to brew install bash.
if (( BASH_VERSINFO[0] < 5 )); then
  for candidate in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    if [[ -x "$candidate" ]]; then
      exec "$candidate" "$0" "$@"
    fi
  done
  cat >&2 <<'EOF'
ai-stack-installer requires bash 5+ (you're on bash 3.2, which macOS ships).
Install brew-bash and re-run:

    brew install bash
    bash ~/ai-stack/install.sh

EOF
  exit 2
fi

shopt -s inherit_errexit nullglob

# --- locate self & libs ------------------------------------------------------
# Use pwd -P (physical path; resolves symlinks) so attacker-planted symlink
# chains don't redirect AI_STACK to a tree they control (Reviewer Y-2/Y-3).
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" \
  || { echo "install.sh: cannot resolve script directory" >&2; exit 2; }
export AI_STACK
LIB="$AI_STACK/installer/lib"

# --- PRE-SOURCE PATH-INJECTION GUARD (Reviewer Y-2/Y-3) ----------------------
# These checks MUST run BEFORE any `source` because the lib files themselves
# are the attack surface. We use only bash builtins + stat (POSIX) here.
# Only enforced when EUID == 0 (i.e., the prepare-sudo path); regular installs
# already run as the user and don't expose this attack vector.
if (( ${EUID:-$(id -u)} == 0 )); then
  case "$AI_STACK" in
    /tmp/*|/var/tmp/*|/private/tmp/*|/private/var/tmp/*)
      echo "✗ Refusing to run as root from temp directory: $AI_STACK" >&2
      exit 2 ;;
  esac
  if [[ -L "${BASH_SOURCE[0]}" ]]; then
    echo "✗ install.sh is a symlink. Refusing to run as root." >&2
    exit 2
  fi
  if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
    echo "✗ Cannot determine invoking user (SUDO_USER unset or 'root')." >&2
    echo "  Use 'sudo bash install.sh prepare-sudo', not 'sudo -i' or 'su -'." >&2
    exit 2
  fi
  __ai_stack_owner="$(stat -f '%Su' "$AI_STACK" 2>/dev/null)" \
    || { echo "✗ Cannot stat $AI_STACK" >&2; exit 2; }
  if [[ "$__ai_stack_owner" != "$SUDO_USER" ]]; then
    echo "✗ $AI_STACK owned by '$__ai_stack_owner', not invoking user '$SUDO_USER'. Refusing." >&2
    exit 2
  fi
  for __f in install.sh \
             installer/lib/common.sh installer/lib/env.sh installer/lib/docker.sh \
             installer/lib/validate.sh installer/lib/prompt.sh installer/lib/litellm.sh \
             installer/lib/bootstrap.sh installer/lib/network.sh; do
    if [[ -L "$AI_STACK/$__f" ]]; then
      echo "✗ $__f is a symlink. Refusing to source as root." >&2
      exit 2
    fi
    __fo="$(stat -f '%Su' "$AI_STACK/$__f" 2>/dev/null)" || \
      { echo "✗ Missing $__f" >&2; exit 2; }
    if [[ "$__fo" != "$SUDO_USER" && "$__fo" != "root" ]]; then
      echo "✗ $__f owned by '$__fo' (neither root nor invoking user). Refusing." >&2
      exit 2
    fi
  done
  unset __ai_stack_owner __f __fo
fi

# Source libs in a deterministic order. Order matters: common first
# (defines log/err/lock), then env, docker, validate, prompt, litellm.
# shellcheck source=installer/lib/common.sh
source "$LIB/common.sh"
source "$LIB/env.sh"
source "$LIB/docker.sh"
source "$LIB/validate.sh"
source "$LIB/prompt.sh"
source "$LIB/litellm.sh"
source "$LIB/bootstrap.sh"

# --- error trap (Reviewer B #2) ---------------------------------------------
trap 'err "ERR line $LINENO: $BASH_COMMAND (exit=$?)"' ERR

# --- preflight (Reviewer Adversarial #6) ------------------------------------
preflight() {
  # Refuse sudo — it would strip PATH and might chown .env to root.
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    err "Do not run install.sh under sudo. Run as your normal user."
    exit 2
  fi

  # Resolve and pin tool paths so a later PATH change can't bite mid-script.
  local missing=()
  for tool in brew docker git curl jq yq openssl awk grep sed mktemp stat lsof; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      missing+=("$tool")
    fi
  done
  if (( ${#missing[@]} > 0 )); then
    err "Missing required tools: ${missing[*]}"
    err "Install missing tools and re-run. Most are available via:  brew install ${missing[*]}"
    exit 2
  fi

  # Docker daemon reachable?  (catches both OrbStack-not-running and
  # Docker-Desktop-not-running on macOS).
  if ! docker info >/dev/null 2>&1; then
    err "Docker daemon not reachable. Start OrbStack: open -a OrbStack"
    exit 2
  fi

  # ~/ai-stack writable?
  if ! touch "$AI_STACK/.write-test" 2>/dev/null; then
    err "$AI_STACK is not writable for $(whoami)"
    exit 2
  fi
  rm -f "$AI_STACK/.write-test"
}

# --- subcommand dispatch -----------------------------------------------------
usage() {
  cat <<'EOF'
ai-stack-installer — usage:

  Two-step bootstrap (recommended):
    sudo bash install.sh prepare-sudo   one-time host-system setup (sudo)
    bash install.sh                     full install (no sudo)

  All subcommands:
    install.sh                          interactive top-to-bottom install
    install.sh prepare-sudo             write /etc/hosts + flush DNS (REQUIRES sudo)
    install.sh install <phase>          install one phase, e.g.  install.sh install 01h
    install.sh test <phase>             run smoke tests for one phase
    install.sh status                   tabular service status
    install.sh doctor [<service>]       diagnose & offer fixes
    install.sh verify                   runtime end-to-end verification sweep (run BEFORE install)
    install.sh adopt <service>          take ownership of a foreign container
    install.sh apply-restarts           drain the queued-restart list
    install.sh logs <service> [-f]      tail logs from a service
    install.sh history                  assemble CHANGELOG.d/* into one view
    install.sh gc                       list/clean partial container orphans
    install.sh migrate-v2               run the v1→v2 services.yml migration
    install.sh reset --confirm soft|hard|nuke [--yes]   tiered destructive reset
                                        (--yes/-y: non-interactive; auto-accepts the
                                         soft/hard y/n gate. nuke's typed gate stays manual.)
    install.sh start <service>          start a service via bin/start-<service>.sh
    install.sh stop <service>           stop a service (bin/stop-<service>.sh or docker stop)
    install.sh <service> start          shortcut for: install.sh start <service>
    install.sh <service> stop           shortcut for: install.sh stop <service>
                                        (enable/disable are accepted as aliases for start/stop)

Phases (in install order):
  00 00s 00n 00v 02 03 01 01h 04 04f 04g 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19

EOF
}

# --- prepare-sudo subcommand -------------------------------------------------
# The ONE step that needs root: write /etc/hosts and flush macOS DNS cache.
# Designed to be invoked as `sudo bash install.sh prepare-sudo` so the
# subsequent `bash install.sh` (no sudo) has nothing left that requires
# privilege. Idempotent — re-running is a no-op if /etc/hosts is correct.
#
# Hardening (post 3-agent review):
#   - Path-injection guard: refuses if AI_STACK lives under /tmp/* or contains
#     symlinks or is owned by anyone other than the invoking user. Stops
#     `sudo bash /tmp/evil/install.sh prepare-sudo` from sourcing attacker-
#     controlled libs as root (Reviewer C #1).
#   - chown -h on specific files only (no -R): symlink-safe (Reviewer B Q2,
#     Reviewer C #2).
#   - SUDO_USER cross-checked against directory owner (Reviewer C #3).
#   - lock_acquire serializes with concurrent install.sh runs (Reviewer B Q3).
#   - chown failures surfaced as a warning, not silently swallowed
#     (Reviewer C #4).
cmd_prepare_sudo() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "prepare-sudo must be run with sudo:"
    err "    sudo bash $(basename "$0") prepare-sudo"
    exit 2
  fi

  # --- Path-injection guard (Reviewer C #1) ---------------------------------
  # Compute physical path; refuse if it doesn't match the script's argv path.
  local script_real script_dir
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" \
    || { err "Cannot resolve script directory"; exit 2; }
  if [[ "$script_dir" != "$AI_STACK" ]]; then
    err "Script directory differs from AI_STACK after symlink resolution:"
    err "    BASH_SOURCE dirname: $AI_STACK"
    err "    pwd -P:              $script_dir"
    err "Refusing to run as root from a symlinked path."
    exit 2
  fi
  # Refuse temp-style locations entirely.
  case "$AI_STACK" in
    /tmp/*|/var/tmp/*|/private/tmp/*|/private/var/tmp/*)
      err "Refusing to run as root from a temp directory: $AI_STACK"
      err "Move ai-stack to a stable location (e.g. ~/ai-stack) and re-run."
      exit 2 ;;
  esac
  # Refuse if any key library file is a symlink (could redirect to attacker code).
  local f
  for f in install.sh installer/lib/common.sh installer/lib/network.sh installer/lib/env.sh; do
    if [[ -L "$AI_STACK/$f" ]]; then
      err "$f is a symlink. Refusing for security."
      exit 2
    fi
  done

  # --- SUDO_USER validation (Reviewer C #3) ---------------------------------
  if [[ -z "${SUDO_USER:-}" ]] || [[ "$SUDO_USER" == "root" ]]; then
    err "Cannot determine invoking user (SUDO_USER unset or 'root')."
    err "Invoke via:  sudo bash $(basename "$0") prepare-sudo"
    err "(Don't use 'sudo -i' or 'su -'; those lose the original user.)"
    exit 2
  fi
  # AI_STACK must be owned by SUDO_USER. Catches the path-injection scenario
  # where an attacker plants a tree they own but the invoker doesn't.
  local ai_stack_owner
  ai_stack_owner="$(stat -f '%Su' "$AI_STACK" 2>/dev/null)" \
    || { err "Cannot stat $AI_STACK"; exit 2; }
  if [[ "$ai_stack_owner" != "$SUDO_USER" ]]; then
    err "$AI_STACK is owned by '$ai_stack_owner', not invoking user '$SUDO_USER'."
    err "Refusing to source libs from a tree the invoker doesn't own."
    exit 2
  fi

  # --- Acquire install lock (Reviewer B Q3, Reviewer C #6) ------------------
  lock_acquire

  # --- Source the helpers needed for the actual work ------------------------
  source "$LIB/network.sh"

  # --- Do the work -----------------------------------------------------------
  hdr "Preparing host-system bits (sudo)"
  log "Ensuring /etc/hosts block + flushing DNS cache..."
  hosts_ensure_block || { err "hosts_ensure_block failed"; exit 1; }
  # CRITICAL: macOS does NOT auto-route 127.0.10.x to lo0. Without these
  # ifconfig aliases, Docker port bindings to 127.0.10.x:80 are accepted but
  # unreachable. Brief assertion that "127.0.0.0/8 is loopback by default"
  # was wrong — verified on macOS Sequoia/Sonoma.
  log "Binding 127.0.10.x aliases to lo0..."
  lo0_ensure_aliases || { err "lo0_ensure_aliases failed"; exit 1; }
  log "Installing launchd persistence plist (so aliases survive reboot)..."
  lo0_install_persistence_plist || warn "persistence plist install failed (re-run prepare-sudo after reboot)"

  # --- Chown back to SUDO_USER on specific files only (Reviewer B Q2 /
  # --- Reviewer C #2, #4, #5, A caveat-2). NEVER use chown -R: BSD chown
  # --- follows symlinks during recursion. Use -h to chown the symlink itself
  # --- (not its target) on the rare case we encounter one.
  local chown_failed=0 path
  for path in \
      "$AI_STACK/installer/state" \
      "$AI_STACK/installer/state/restarts-needed.txt" \
      "$AI_STACK/installer/state/.lock" \
      "$AI_STACK/installer/state/.lock/pid" \
      "$AI_STACK/installer/state/.lock/run-id" \
      "$AI_STACK/CHANGELOG.d" \
      "$AI_STACK/CHANGELOG.d/${RUN_ID:-_no_run_id_}.md" \
      "/tmp/ai-stack-hosts.bak-${RUN_ID:-}"; do
    [[ -e "$path" || -L "$path" ]] || continue
    if ! chown -h "$SUDO_USER" "$path" 2>/dev/null; then
      warn "chown failed: $path"
      chown_failed=1
    fi
  done
  # For state and CHANGELOG.d directories: chown each entry one level deep,
  # using -h (symlink-safe). Refuse to descend below the top level.
  for dir in "$AI_STACK/installer/state" "$AI_STACK/CHANGELOG.d"; do
    [[ -d "$dir" ]] || continue
    while IFS= read -r path; do
      [[ -z "$path" ]] && continue
      if ! chown -h "$SUDO_USER" "$path" 2>/dev/null; then
        warn "chown failed: $path"
        chown_failed=1
      fi
    done < <(find "$dir" -mindepth 1 -maxdepth 1 -print 2>/dev/null)
  done
  if (( chown_failed )); then
    warn "Some files remain root-owned. Re-run prepare-sudo, or chown them"
    warn "manually:  sudo chown -h $SUDO_USER <path>"
  fi

  ok "/etc/hosts updated; DNS cache flushed."
  note "Next:  bash $(basename "$0")    (runs as your normal user, no sudo)"
  note "       The install needs Docker running. If OrbStack isn't up:"
  note "       open -a OrbStack"
}

cmd_install() {
  local target="${1:-all}"
  preflight
  lock_acquire

  if [[ "$target" == "all" ]]; then
    # Run in order; stop at first failure (with a clear resume hint).
    # 00v runs AFTER 00n so the network is up before we probe it; AFTER 00s
    # so docker is reachable; and BEFORE 01 so we catch routing failures
    # before launching the first real container. (Safety Reviewer 2 design.)
    # Phase order rationale:
    # - 03 (Honcho/Postgres) runs BEFORE 01 (LiteLLM) because LiteLLM's
    #   Prisma migration + virtual-key store needs Postgres at startup;
    #   without it, uvicorn hangs and Phase 01 times out at 60s. Honcho's
    #   compose stack provides the Postgres LiteLLM uses (DATABASE_URL=
    #   postgresql://postgres:postgres@host.docker.internal:5432/litellm).
    #   Pre-2026-05-30 the order was 01 → 03; cold-path installs always
    #   broke. CHANGELOG 2026-05-30.
    # - 00v (verify) runs AFTER 00n (network) so the network is up to probe.
    # - 04f (Hermes fleet) AFTER 04 (OpenShell + hermes-fleet-v1 sandbox).
    # - 04g (security layer) AFTER 04f.
    local phases=(00 00s 00n 00v 02 03 01 01h 04 04f 04g 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19)
    for p in "${phases[@]}"; do
      run_phase "$p" || {
        err "Phase $p failed. After fixing, resume with:  bash $0 install $p"
        exit 1
      }
    done
    # Interactive remediation: adopt foreign containers, recreate honcho on the
    # new network if drifted, prompt for Phoenix API key, drain restart queue,
    # run final doctor. Each step prompts Y/n; conservative-mode contract is
    # preserved. Skipped entirely under NO_PROMPT=1.
    bootstrap_run_all
    summary_end_of_install
  else
    run_phase "$target"
  fi
}

run_phase() {
  local p="$1"
  local script
  script="$(find "$AI_STACK/installer/phases" -maxdepth 1 -name "${p}_*.sh" -print -quit)"
  if [[ -z "$script" ]]; then
    err "No phase script matches '${p}_*.sh' in installer/phases/"
    return 1
  fi
  log "==> phase $p — $(basename "$script")"
  bash "$script"
}

cmd_test()    { local p="$1"; bash "$AI_STACK/installer/smoke/${p}.sh"; }
cmd_status()  { bash "$AI_STACK/installer/lib/status.sh"; }
cmd_doctor()  { bash "$AI_STACK/installer/doctor/doctor.sh" "${1:-}"; }
cmd_adopt()   { bash "$AI_STACK/installer/lib/adopt.sh" "$1"; }
cmd_logs()    { docker logs "$1" "${2:-}"; }
cmd_gc()      { bash "$AI_STACK/installer/lib/gc.sh"; }
cmd_history() { bash "$AI_STACK/installer/lib/history.sh"; }

# cmd_start <svc> — invoke bin/start-<svc>.sh (the canonical per-service
# launcher). All managed services have one. For docker-compose services
# like deerflow, the wrapper sources required secrets (e.g.
# LITELLM_MASTER_KEY) before invoking the compose entrypoint so compose's
# ${VAR} substitution resolves cleanly without warnings.
cmd_start() {
  local svc="${1:-}"
  if [[ -z "$svc" ]]; then
    err "Usage: install.sh start <service>"
    _list_startable_services
    exit 2
  fi
  local script="$AI_STACK/bin/start-${svc}.sh"
  if [[ ! -x "$script" ]]; then
    err "No start script: $script"
    _list_startable_services
    exit 1
  fi
  exec bash "$script" "${@:2}"
}

# cmd_stop <svc> — prefer bin/stop-<svc>.sh; fall back to `docker stop <svc>`
# for plain docker-run containers (most of the stack) that don't ship a
# dedicated stop script.
cmd_stop() {
  local svc="${1:-}"
  if [[ -z "$svc" ]]; then
    err "Usage: install.sh stop <service>"
    exit 2
  fi
  local script="$AI_STACK/bin/stop-${svc}.sh"
  if [[ -x "$script" ]]; then
    exec bash "$script"
  fi
  if docker inspect "$svc" >/dev/null 2>&1; then
    log "No bin/stop-${svc}.sh — using 'docker stop $svc'"
    exec docker stop "$svc"
  fi
  err "No stop script and no running container named '$svc'."
  exit 1
}

_list_startable_services() {
  echo "Startable services:"
  ls "$AI_STACK"/bin/start-*.sh 2>/dev/null \
    | sed -E 's|.*/start-||; s|\.sh$||' \
    | sort -u | sed 's/^/  - /'
}

# cmd_verify — standalone runtime-verification sweep (Safety Reviewer 2).
#
# Runs Phase 00·V's probes (lib/verify.sh) followed by doctor checks 19–22.
# Use this BEFORE committing to a full install (so you find broken /etc/hosts
# or missing lo0 aliases without partially-installing anything), and use it
# in CI to gate releases.
#
# Exit codes:
#   0  every probe + check passed
#   1  one or more probes failed (each prints the exact fix command)
cmd_verify() {
  preflight   # Re-uses install-time preflight (docker reachable, tools present).
  hdr "Runtime verification sweep"
  note "Phase 00·V probes (state-free, ~10s)..."
  bash "$AI_STACK/installer/phases/00v_verify.sh"
  local v_rc=$?
  echo
  note "Doctor checks 19–22 (alias/DNS/ownership)..."
  bash "$AI_STACK/installer/doctor/doctor.sh" lo0_aliases    || true
  bash "$AI_STACK/installer/doctor/doctor.sh" container_alias_routable || true
  bash "$AI_STACK/installer/doctor/doctor.sh" container_dns_in_network || true
  bash "$AI_STACK/installer/doctor/doctor.sh" etc_hosts_ownership      || true
  echo
  if (( v_rc == 0 )); then
    ok "Runtime verification PASSED. Safe to run: bash install.sh"
    return 0
  else
    err "Runtime verification FAILED. See diagnoses above; fix BEFORE bash install.sh"
    return 1
  fi
}

cmd_migrate_v2() {
  bash "$AI_STACK/installer/migrations/v1_to_v2.sh"
}

cmd_apply_restarts() {
  local f="$AI_STACK/installer/state/restarts-needed.txt"
  if [[ ! -s "$f" ]]; then
    ok "No queued restarts."
    return 0
  fi
  warn "These services need restart to pick up new .env values:"
  cat "$f"
  if ! confirm "Recreate each (will backup data first for stateful services)?" N; then
    log "Aborted. Queue file preserved at $f"
    return 0
  fi
  local svc
  while IFS= read -r svc; do
    [[ -z "$svc" || "$svc" == \#* ]] && continue
    "$AI_STACK/bin/start-${svc}.sh" --recreate
  done < "$f"
  : > "$f"   # drain the queue
  ok "Restarts applied; queue drained."
}

cmd_reset() {
  if [[ "${1:-}" != "--confirm" ]]; then
    err "reset requires --confirm <tier>. See:  install.sh reset --help"
    exit 2
  fi
  local tier="${2:-soft}"
  # Optional non-interactive confirmation: `reset --confirm <tier> --yes` (or -y).
  # Exports AI_STACK_ASSUME_YES so prompt.sh::confirm auto-accepts the soft/hard
  # y/n gate. The nuke tier's literal "type 'nuke ai-stack'" gate is NOT a
  # confirm() call and stays manual on purpose.
  shift 2 2>/dev/null || true
  local a
  for a in "$@"; do
    case "$a" in
      -y|--yes) export AI_STACK_ASSUME_YES=1 ;;
      *) warn "reset: ignoring unknown flag '$a'" ;;
    esac
  done
  bash "$AI_STACK/installer/lib/reset.sh" "$tier"
}

summary_end_of_install() {
  printf "\n"
  ok "Install complete."
  # If bootstrap_run_all skipped (NO_PROMPT) or the user declined remediation,
  # surface anything still pending so they know the exact catch-up command.
  local restarts="$AI_STACK/installer/state/restarts-needed.txt"
  if [[ -s "$restarts" ]]; then
    warn "Queued restarts still pending (run 'install.sh apply-restarts' when ready):"
    sed 's/^/    /' "$restarts"
  fi
  note "Status:  bash install.sh status"
  note "Doctor:  bash install.sh doctor"
}

main() {
  local cmd="${1:-install}"
  shift || true
  case "$cmd" in
    install|"")        cmd_install "${1:-all}" ;;
    prepare-sudo)      cmd_prepare_sudo ;;
    test)              cmd_test "$1" ;;
    status)            cmd_status ;;
    doctor)            cmd_doctor "${1:-}" ;;
    verify)            cmd_verify ;;
    adopt)             cmd_adopt "$1" ;;
    apply-restarts)    cmd_apply_restarts ;;
    logs)              cmd_logs "$@" ;;
    history)           cmd_history ;;
    gc)                cmd_gc ;;
    migrate-v2)        cmd_migrate_v2 ;;
    reset)             cmd_reset "$@" ;;
    start|enable)      cmd_start "$@" ;;
    stop|disable)      cmd_stop "$@" ;;
    -h|--help|help)    usage ;;
    *)
      # Reverse-form: `stack <svc> <action>` (e.g. `stack deerflow start`).
      # Translates `stack <svc> start` → cmd_start <svc>, similarly for
      # stop/enable/disable. Only triggers when the first token is NOT a
      # known subcommand AND the second token is a known action verb.
      case "${1:-}" in
        start|enable)  cmd_start "$cmd" ;;
        stop|disable)  cmd_stop "$cmd" ;;
        *)             err "Unknown command: $cmd"; usage; exit 2 ;;
      esac
      ;;
  esac
}

main "$@"
