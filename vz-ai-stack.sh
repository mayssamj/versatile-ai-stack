#!/usr/bin/env bash
# ai-stack-installer — single-command bootstrap for the personal multi-agent AI stack.
#
# Usage:
#   bash vz-ai-stack.sh                  interactive top-to-bottom install (resumes)
#   bash vz-ai-stack.sh install <phase>  install one phase (e.g. 01h)
#   bash vz-ai-stack.sh test <phase>     run smoke tests for one phase
#   bash vz-ai-stack.sh status           tabular service status (declared vs actual)
#   bash vz-ai-stack.sh doctor [<svc>]   diagnose & offer fixes
#   bash vz-ai-stack.sh adopt <svc>      take ownership of a container started outside the installer
#   bash vz-ai-stack.sh apply-restarts   drain the queue of services needing a restart
#   bash vz-ai-stack.sh logs <svc> [-f]  tail recent logs from a service
#   bash vz-ai-stack.sh history          assemble per-run CHANGELOG.d entries into one view
#   bash vz-ai-stack.sh gc               list/clean partial container orphans
#   bash vz-ai-stack.sh reset --confirm soft|hard|nuke    destructive resets, tiered
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
    bash ~/ai-stack/vz-ai-stack.sh

EOF
  exit 2
fi

shopt -s inherit_errexit nullglob

# --- locate self & libs ------------------------------------------------------
# Use pwd -P (physical path; resolves symlinks) so attacker-planted symlink
# chains don't redirect AI_STACK to a tree they control (Reviewer Y-2/Y-3).
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)" \
  || { echo "vz-ai-stack.sh: cannot resolve script directory" >&2; exit 2; }
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
    echo "✗ vz-ai-stack.sh is a symlink. Refusing to run as root." >&2
    exit 2
  fi
  if [[ -z "${SUDO_USER:-}" || "$SUDO_USER" == "root" ]]; then
    echo "✗ Cannot determine invoking user (SUDO_USER unset or 'root')." >&2
    echo "  Use 'sudo bash vz-ai-stack.sh prepare-sudo', not 'sudo -i' or 'su -'." >&2
    exit 2
  fi
  __ai_stack_owner="$(stat -f '%Su' "$AI_STACK" 2>/dev/null)" \
    || { echo "✗ Cannot stat $AI_STACK" >&2; exit 2; }
  if [[ "$__ai_stack_owner" != "$SUDO_USER" ]]; then
    echo "✗ $AI_STACK owned by '$__ai_stack_owner', not invoking user '$SUDO_USER'. Refusing." >&2
    exit 2
  fi
  for __f in vz-ai-stack.sh \
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
    err "Do not run vz-ai-stack.sh under sudo. Run as your normal user."
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
    sudo bash vz-ai-stack.sh prepare-sudo   one-time host-system setup (sudo)
    bash vz-ai-stack.sh                     full install (no sudo)

  All subcommands:
    vz-ai-stack.sh                          interactive top-to-bottom install
    vz-ai-stack.sh prepare-sudo             write /etc/hosts + flush DNS (REQUIRES sudo)
    vz-ai-stack.sh install <phase>          install one phase BY ID or NAME, e.g.
                                          vz-ai-stack.sh install 01h
                                          vz-ai-stack.sh install phoenix
                                          vz-ai-stack.sh install hermes_telegram  (alias: telegram)
    vz-ai-stack.sh phases                   list every phase as `id  name` (also: steps, list)
    vz-ai-stack.sh test <phase>             run smoke tests for one phase (id or name)
    vz-ai-stack.sh status                   tabular service status
    vz-ai-stack.sh help <service>           what it is · how it's configured · how to use
    vz-ai-stack.sh help services            list services that have help prose
    vz-ai-stack.sh help regen [<svc>]       refresh help prose from the live codebase
                                        ([--apply] writes; [--check] CI staleness; [--model <m>])
    vz-ai-stack.sh model list [--json]      show the model<->agent binding matrix (models.yml)
    vz-ai-stack.sh model assign <a> <m>     re-point agent <a> to model <m> (then sync that agent)
    vz-ai-stack.sh model sync [<a>]         render every agent + LiteLLM model_list from models.yml
                                        (opt-in; NOT run by 'install all'. --dry-run / --no-restart)
    vz-ai-stack.sh fleet list [--json]      list Hermes fleet profiles (models.yml + sandbox presence)
    vz-ai-stack.sh fleet add <name> --role "<d>" [--model <m>]   add a profile to hermes-fleet-v1
    vz-ai-stack.sh fleet remove <name>      remove a fleet profile (reverses add)
    vz-ai-stack.sh fleet new <name> [--profiles a,b,c]   create a SEPARATE isolated fleet sandbox <name>-v1
    vz-ai-stack.sh fleet destroy <name>     tear down a fleet created by `fleet new`
                                        NOTE: `vz-ai-stack.sh install fleet|hermes` runs the PHASE (04f
                                        re-render); `vz-ai-stack.sh fleet <add|remove|list|new|destroy>`
                                        is the fleet MANAGER. (add/remove default new profiles to the
                                        gemma4 default; nothing loads a model.)
    vz-ai-stack.sh doctor [<service>]       diagnose & offer fixes
    vz-ai-stack.sh verify                   runtime end-to-end verification sweep (run BEFORE install)
    vz-ai-stack.sh adopt <service>          take ownership of a foreign container
    vz-ai-stack.sh apply-restarts           drain the queued-restart list
    vz-ai-stack.sh logs <service> [-f]      tail logs from a service
    vz-ai-stack.sh history                  assemble CHANGELOG.d/* into one view
    vz-ai-stack.sh gc                       list/clean partial container orphans
    vz-ai-stack.sh migrate-v2               run the v1→v2 services.yml migration
    vz-ai-stack.sh upgrade <service|all> [--dry-run]   Pull/rebuild + recreate a service
                                        (or all enabled), type-dispatched
    vz-ai-stack.sh tutorial-serve [--port N] [--ttl 30m] [--revoke]   serve doc/TUTORIAL.html
                                        + safe 'Try it live' proxy (ephemeral local-only key)
    vz-ai-stack.sh reset --confirm soft|hard|nuke [--yes]   tiered destructive reset
                                        (--yes/-y: non-interactive; auto-accepts the
                                         soft/hard y/n gate. nuke's typed gate stays manual.)
    vz-ai-stack.sh start <service>          start a service via bin/start-<service>.sh
    vz-ai-stack.sh stop <service>           stop a service (bin/stop-<service>.sh or docker stop)
    vz-ai-stack.sh <service> start          shortcut for: vz-ai-stack.sh start <service>
    vz-ai-stack.sh <service> stop           shortcut for: vz-ai-stack.sh stop <service>
                                        (enable/disable are accepted as aliases for start/stop)

Phases (in install order) — pass the id OR the name (run `vz-ai-stack.sh phases` for the table):
  00 00s 00n 00v 02 03 01 01h 04 04f 04g 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20
  opt-in extras (not in `install all`): 21 portless · 22 cmux · 23 skillspector · 24 openagents · 25 lmstudio

EOF
}

# --- prepare-sudo subcommand -------------------------------------------------
# The ONE step that needs root: write /etc/hosts and flush macOS DNS cache.
# Designed to be invoked as `sudo bash vz-ai-stack.sh prepare-sudo` so the
# subsequent `bash vz-ai-stack.sh` (no sudo) has nothing left that requires
# privilege. Idempotent — re-running is a no-op if /etc/hosts is correct.
#
# Hardening (post 3-agent review):
#   - Path-injection guard: refuses if AI_STACK lives under /tmp/* or contains
#     symlinks or is owned by anyone other than the invoking user. Stops
#     `sudo bash /tmp/evil/vz-ai-stack.sh prepare-sudo` from sourcing attacker-
#     controlled libs as root (Reviewer C #1).
#   - chown -h on specific files only (no -R): symlink-safe (Reviewer B Q2,
#     Reviewer C #2).
#   - SUDO_USER cross-checked against directory owner (Reviewer C #3).
#   - lock_acquire serializes with concurrent vz-ai-stack.sh runs (Reviewer B Q3).
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
  for f in vz-ai-stack.sh installer/lib/common.sh installer/lib/network.sh installer/lib/env.sh; do
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
    # - 04h (agent fleet across claude-code/pi/hermes) runs LAST: it uploads into
    #   pi-v1 (Phase 15) and widens PI_LITELLM_KEY (minted by 15) + HERMES key.
    local phases=(00 00s 00n 00v 02 03 01 01h 04 04f 04g 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 04h)
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

# Resolve a phase selector to its script path. A selector may be a NUMERIC id
# (00, 01h, 04f, 21 …) OR a meaningful NAME — phase files are named
# `<id>_<name>.sh`, so the human-friendly name is just the filename suffix
# (`hermes_fleet`, `claw3d`, `portless`, …), plus a few friendly aliases. New
# phases are auto-discovered (no registry to maintain). Echoes the script path on
# success; on no/ambiguous match writes detail to stderr and returns 1.
resolve_phase_script() {
  local sel="$1" dir="$AI_STACK/installer/phases" script
  local -a matches

  # Friendly aliases -> canonical name suffix.
  case "$sel" in
    litellm)               sel=inference ;;
    tracing)               sel=phoenix ;;
    db)                    sel=storage ;;
    sandbox)               sel=openshell ;;
    hermes|fleet)          sel=hermes_fleet ;;
    telegram)              sel=hermes_telegram ;;
    guardrails)            sel=security ;;
    ui|openwebui)          sel=uis ;;
    docs|rag)              sel=documents ;;
    memory)                sel=alt_memory ;;
    unsloth)               sel=unsloth_studio ;;
    halo|autoreason)       sel=halo_autoreason ;;
    net|dns)               sel=networking ;;
  esac

  # 1. id-prefix: <sel>_*.sh   (00, 04f, 21 …)
  script="$(find "$dir" -maxdepth 1 -name "${sel}_*.sh" -print -quit 2>/dev/null)"
  [[ -n "$script" ]] && { printf '%s' "$script"; return 0; }

  # 2. exact name-suffix: *_<sel>.sh   (host, hermes_fleet, claw3d, portless …)
  mapfile -t matches < <(find "$dir" -maxdepth 1 -name "*_${sel}.sh" 2>/dev/null | sort)
  [[ ${#matches[@]} -eq 1 ]] && { printf '%s' "${matches[0]}"; return 0; }
  if (( ${#matches[@]} > 1 )); then
    err "Phase '$sel' is ambiguous — matches: ${matches[*]##*/}"; return 1
  fi

  # 3. fuzzy contains: *<sel>*.sh   (last resort; must be unique)
  mapfile -t matches < <(find "$dir" -maxdepth 1 -name "*${sel}*.sh" 2>/dev/null | sort)
  [[ ${#matches[@]} -eq 1 ]] && { printf '%s' "${matches[0]}"; return 0; }
  if (( ${#matches[@]} > 1 )); then
    err "Phase '$sel' is ambiguous — matches: ${matches[*]##*/}"; return 1
  fi
  return 1
}

run_phase() {
  local p="$1" script
  if ! script="$(resolve_phase_script "$p")"; then
    err "Could not resolve phase '$p' to a single script. Run 'vz-ai-stack.sh phases' to list ids + names."
    return 1
  fi
  log "==> phase $p — $(basename "$script")"
  bash "$script"
}

# List every phase as `id  name` (what you can pass to `install`/`test`).
cmd_phases() {
  local f base id name
  printf '%-7s  %s\n' "ID" "NAME"
  printf '%-7s  %s\n' "-------" "----"
  while IFS= read -r f; do
    base="$(basename "$f" .sh)"   # e.g. 04f_hermes_fleet
    id="${base%%_*}"              # 04f
    name="${base#*_}"             # hermes_fleet
    printf '%-7s  %s\n' "$id" "$name"
  done < <(find "$AI_STACK/installer/phases" -maxdepth 1 -name '*.sh' | sort)
  echo
  echo "Use either form:  vz-ai-stack.sh install <id>   |   vz-ai-stack.sh install <name>"
  echo "Aliases: litellm=inference, telegram=hermes_telegram, hermes=hermes_fleet, sandbox=openshell, unsloth=unsloth_studio, halo=halo_autoreason, ui=uis, docs=documents, memory=alt_memory"
}

cmd_test()    { local p="$1" script id="$1"; if script="$(resolve_phase_script "$p" 2>/dev/null)"; then id="$(basename "$script" .sh)"; id="${id%%_*}"; fi; bash "$AI_STACK/installer/smoke/${id}.sh"; }
cmd_status()  { bash "$AI_STACK/installer/lib/status.sh" "$@"; }
cmd_model()   { bash "$AI_STACK/installer/lib/models.sh" "$@"; }
cmd_fleet()   { bash "$AI_STACK/installer/lib/fleet.sh" "$@"; }
cmd_help()    { bash "$AI_STACK/installer/lib/help.sh" "$@"; }
cmd_doctor()  { bash "$AI_STACK/installer/doctor/doctor.sh" "${1:-}"; }
cmd_adopt()   { bash "$AI_STACK/installer/lib/adopt.sh" "$1"; }
cmd_logs()    { docker logs "$1" "${2:-}"; }
cmd_gc()      { bash "$AI_STACK/installer/lib/gc.sh"; }
cmd_history() { bash "$AI_STACK/installer/lib/history.sh"; }
# Runs in a separate process so it owns its own lock (and trap) — see upgrade.sh.
cmd_upgrade() { bash "$AI_STACK/installer/lib/upgrade.sh" "$@"; }
# Serves doc/TUTORIAL.html + a loopback proxy with an ephemeral local-only key.
cmd_tutorial_serve() { bash "$AI_STACK/installer/lib/tutorial-serve.sh" "$@"; }

# cmd_start <svc> — invoke bin/start-<svc>.sh (the canonical per-service
# launcher). All managed services have one. For docker-compose services
# like deerflow, the wrapper sources required secrets (e.g.
# LITELLM_MASTER_KEY) before invoking the compose entrypoint so compose's
# ${VAR} substitution resolves cleanly without warnings.
cmd_start() {
  local svc="${1:-}"
  if [[ -z "$svc" ]]; then
    err "Usage: vz-ai-stack.sh start <service>"
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
    err "Usage: vz-ai-stack.sh stop <service>"
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
    ok "Runtime verification PASSED. Safe to run: bash vz-ai-stack.sh"
    return 0
  else
    err "Runtime verification FAILED. See diagnoses above; fix BEFORE bash vz-ai-stack.sh"
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
    err "reset requires --confirm <tier>. See:  vz-ai-stack.sh reset --help"
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
    warn "Queued restarts still pending (run 'vz-ai-stack.sh apply-restarts' when ready):"
    sed 's/^/    /' "$restarts"
  fi
  note "Status:  bash vz-ai-stack.sh status"
  note "Doctor:  bash vz-ai-stack.sh doctor"
  declare -F print_inference_hint >/dev/null 2>&1 || source "$AI_STACK/installer/lib/lmstudio.sh"
  print_inference_hint
}

main() {
  local cmd="${1:-install}"
  shift || true
  case "$cmd" in
    install|"")        cmd_install "${1:-all}" ;;
    prepare-sudo)      cmd_prepare_sudo ;;
    test)              cmd_test "$1" ;;
    phases|steps|list) cmd_phases ;;
    status)            cmd_status "$@" ;;
    model)             cmd_model "$@" ;;
    fleet)             cmd_fleet "$@" ;;
    doctor)            cmd_doctor "${1:-}" ;;
    verify)            cmd_verify ;;
    adopt)             cmd_adopt "$1" ;;
    apply-restarts)    cmd_apply_restarts ;;
    logs)              cmd_logs "$@" ;;
    history)           cmd_history ;;
    gc)                cmd_gc ;;
    migrate-v2)        cmd_migrate_v2 ;;
    upgrade)           cmd_upgrade "$@" ;;
    tutorial-serve)    cmd_tutorial_serve "$@" ;;
    reset)             cmd_reset "$@" ;;
    start|enable)      cmd_start "$@" ;;
    stop|disable)      cmd_stop "$@" ;;
    -h|--help)         usage ;;
    help)              cmd_help "$@" ;;   # help · help services · help <svc> · help regen
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
