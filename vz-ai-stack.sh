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
source "$LIB/worktree.sh"
source "$LIB/env.sh"
source "$LIB/docker-engine.sh"

# Global --engine <id> → AI_STACK_ENGINE_FLAG (single argv→env translation site).
# Honored by install/deps/phase-00/04 through the one engine_select path. Strips
# the flag from "$@" so the subcommand dispatch below is unaffected. Placed BEFORE
# the central export so the flag is set when the export's engine resolution runs.
_vz_args=(); while (( $# )); do
  case "$1" in
    --engine)
      if (( $# < 2 )); then
        echo "vz-ai-stack.sh: --engine requires an <id> (orbstack|docker-desktop|colima|podman)" >&2
        exit 2
      fi
      shift; export AI_STACK_ENGINE_FLAG="$1";;
    --engine=*)
      export AI_STACK_ENGINE_FLAG="${1#--engine=}"
      [[ -n "$AI_STACK_ENGINE_FLAG" ]] || { echo "vz-ai-stack.sh: --engine= requires a value" >&2; exit 2; }
      ;;
    *) _vz_args+=("$1");;
  esac
  shift
done
set -- "${_vz_args[@]:-}"

# Central DOCKER_HOST export: derive the one socket the WHOLE stack uses from the
# single source of truth — a global --engine flag first (AI_STACK_ENGINE_FLAG),
# else AI_STACK_DOCKER_ENGINE in .env. No-op when both unset (a local-only user
# who never selected an engine keeps the ambient docker context).
_ai_stack_engine="${AI_STACK_ENGINE_FLAG:-$(get_env AI_STACK_DOCKER_ENGINE "" || true)}"
if [[ -n "$_ai_stack_engine" ]] && _engine_valid "$_ai_stack_engine" 2>/dev/null; then
  _ai_stack_sock="$(engine_socket "$_ai_stack_engine" 2>/dev/null || true)"
  [[ -n "$_ai_stack_sock" ]] && export DOCKER_HOST="$_ai_stack_sock"
fi
unset _ai_stack_engine _ai_stack_sock
source "$LIB/docker.sh"
source "$LIB/validate.sh"
source "$LIB/prompt.sh"
source "$LIB/litellm.sh"
source "$LIB/bootstrap.sh"
source "$LIB/deps.sh"
source "$LIB/setup.sh"

# --- error trap (Reviewer B #2) ---------------------------------------------
trap 'err "ERR line $LINENO: $BASH_COMMAND (exit=$?)"' ERR

# --- preflight (Reviewer Adversarial #6) ------------------------------------
preflight() {
  # Refuse sudo — it would strip PATH and might chown .env to root.
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    err "Do not run vz-ai-stack.sh under sudo. Run as your normal user."
    exit 2
  fi

  # ~/ai-stack writable? (check before installing anything — we write .env, state, etc.)
  if ! touch "$AI_STACK/.write-test" 2>/dev/null; then
    err "$AI_STACK is not writable for $(whoami)"
    exit 2
  fi
  rm -f "$AI_STACK/.write-test"

  # VERIFIED ACTIONS, NO ASSUMPTIONS: instead of asserting yq/jq/docker/etc. are
  # present and aborting (which made the install phase that INSTALLS them
  # unreachable on a clean Mac), ensure them now — install what's missing, start
  # OrbStack, and verify each before proceeding. Idempotent: a no-op when the host
  # is already prepared. Ollama is ensured by Phase 01 (alongside its model pulls).
  # See installer/lib/deps.sh + doc/PREREQUISITES.md.
  bootstrap_host_deps || {
    err "Host dependencies could not be ensured. Fix the error(s) above and re-run."
    exit 2
  }

  # Fail-fast config guardrail: a malformed services.yml / models.yml (e.g. a YAML
  # typo) must abort HERE with a clear, actionable error — NOT hard-fail mid-phase
  # under `set -e` (the 2026-06-21 models.yml-typo-hung-install class). Read-only.
  config_validate || {
    err "Config validation failed — fix the file(s) above and re-run. Nothing was installed."
    exit 2
  }
}

# --- subcommand dispatch -----------------------------------------------------
usage() {
  cat <<'EOF'
ai-stack-installer — usage:

  First-run bootstrap (recommended):
    sudo bash vz-ai-stack.sh prepare-sudo   one-time host-system setup (sudo)
    bash vz-ai-stack.sh setup               (optional) enter API keys — all skippable; local + Claude-sub need none
    bash vz-ai-stack.sh                     full install (no sudo; offers setup on first run)

  All subcommands:
    vz-ai-stack.sh                          interactive top-to-bottom install
    vz-ai-stack.sh prepare-sudo             write /etc/hosts + flush DNS (REQUIRES sudo)
    vz-ai-stack.sh install <phase>          install one phase BY ID or NAME, e.g.
                                          vz-ai-stack.sh install 01h
                                          vz-ai-stack.sh install phoenix
                                          vz-ai-stack.sh install hermes_telegram  (alias: telegram)
                                          vz-ai-stack.sh install docs_ingestor    (a 'status' service name → its phase)
    vz-ai-stack.sh install [all] --dry-run  preview ONLY: host-deps status + the ordered
                                          phases (done vs would-run). Changes nothing. (alias --plan)
    vz-ai-stack.sh install all --include-optionals
                                          ALSO install every opt-in phase (all phases minus core)
                                          after the core run — best-effort: a failing optional
                                          warns + continues. (alias --with-optionals)
    vz-ai-stack.sh phases                   list every phase as `id  name` (also: steps, list)
    vz-ai-stack.sh test <phase|service>     run smoke tests for one phase (id, name, or a
                                          service name → its owning phase's smoke)
    vz-ai-stack.sh deps [--check]           show the host dependency map; install/start
                                          what's missing (--check = read-only, CI exit code)
    vz-ai-stack.sh setup                    interactive .env / API-key bootstrap (alias: keys);
                                          all keys optional + skippable; local + Claude-sub need none
    vz-ai-stack.sh status                   tabular service status
    vz-ai-stack.sh help <service>           what it is · how it's configured · how to use
    vz-ai-stack.sh help services            list services that have help prose
    vz-ai-stack.sh help regen [<svc>]       refresh help prose from the live codebase
                                        ([--apply] writes; [--check] CI staleness; [--model <m>])
    vz-ai-stack.sh model list [--json]      show the model<->agent binding matrix (models.yml)
    vz-ai-stack.sh model assign <a> <m>     re-point agent <a> to model <m> (then sync that agent)
    vz-ai-stack.sh model assign all <m>     blanket-assign EVERY agent to <m> (before→after + models.yml.bak), then sync
    vz-ai-stack.sh model sync [<a>]         render every agent + LiteLLM model_list from models.yml
                                        (opt-in; NOT run by 'install all'. --dry-run / --no-restart)
    vz-ai-stack.sh embedding list [--json]  list embedding models (registry) + per-service assignments
    vz-ai-stack.sh embedding show [<svc>]   current assignment(s) + consistency status
    vz-ai-stack.sh embedding assign <svc> <m>   assign an embedder to a service (docs|openwebui|lumen|
                                        mempalace|honcho); [--dry-run] [--force]. Refuses changing `docs`
                                        to a different vector dim (Qdrant collection is dim-pinned) w/o
                                        --force; warns on code/text kind mismatch.
    vz-ai-stack.sh embedding global <m>     set the general-text embedder for docs+openwebui; [--dry-run]
                                        [--force]. Refuses code-tuned (lumen) / on-device (mempalace).
                                        (assignments live in models.yml .embeddings/.embedding_assignments;
                                        re-run the owning service phase to apply.)
    vz-ai-stack.sh hermes <role> ["prompt"] run ONE Hermes agent (manager techlead frontend backend ml qa
                                        reviewing sre incident) — interactive TUI, or one-shot with a "prompt".
                                        e.g. vz-ai-stack.sh hermes techlead   |   hermes backend "design POST /tokens"
    vz-ai-stack.sh fleet list [--json]      list Hermes fleet profiles (models.yml + sandbox presence)
    vz-ai-stack.sh fleet add <name> --role "<d>" [--model <m>]   add a profile to hermes-fleet-v1
    vz-ai-stack.sh fleet remove <name>      remove a fleet profile (reverses add)
    vz-ai-stack.sh fleet new <name> [--profiles a,b,c]   create a SEPARATE isolated fleet sandbox <name>-v1
    vz-ai-stack.sh fleet destroy <name>     tear down a fleet created by `fleet new`
                                        NOTE: `vz-ai-stack.sh install fleet|hermes` runs the PHASE (04f
                                        re-render); `vz-ai-stack.sh fleet <add|remove|list|new|destroy>`
                                        is the fleet MANAGER. (add/remove default new profiles to the
                                        gemma4 default; nothing loads a model.)
    vz-ai-stack.sh docker-engine status     show the selected Docker engine + resolved socket
                                        + CLI/gateway consistency
    vz-ai-stack.sh docker-engine select [--engine <id>]   (re-)select + ensure + pin the engine
                                        (orbstack|docker-desktop|colima|podman); idempotent
    vz-ai-stack.sh docker-engine set <id>   pin the engine explicitly to <id> (ensure + pin)
    vz-ai-stack.sh docker-engine context [status|switch|keep]   global docker-context policy
                                        (switch=auto-point at ai-stack-<engine>, default; keep=never touch).
                                        Also set non-interactively via 'setup'.
    vz-ai-stack.sh ingress <up|down|reload|status|trust|untrust>   bare-hostname host ingress
                                        (OPT-IN; gives the Mac browser port-free http(s)://litellm/ etc.
                                        'up' needs sudo to bind :80/:443; 'trust' = local CA for https://).
    vz-ai-stack.sh doctor [<service>]       diagnose & offer fixes
    vz-ai-stack.sh verify                   runtime end-to-end verification sweep (run BEFORE install)
    vz-ai-stack.sh adopt <service>          take ownership of a foreign container
    vz-ai-stack.sh apply-restarts           drain the queued-restart list
    vz-ai-stack.sh logs <service> [-f]      tail logs from a service
    vz-ai-stack.sh history                  assemble CHANGELOG.d/* into one view
    vz-ai-stack.sh gc                       list/clean partial container orphans
    vz-ai-stack.sh cleanup [--yes]          reclaim disk: remove REGENERABLE artifacts
                                        (node_modules, .venv, build caches). DRY-RUN by
                                        default — previews sizes; --yes deletes. Scope with
                                        --node/--venv/--caches; --docker also prunes dangling
                                        docker layers; --all = everything. (gc = orphan
                                        containers; cleanup = disk artifacts.)
    vz-ai-stack.sh migrate-v2               run the v1→v2 services.yml migration
    vz-ai-stack.sh upgrade <service|all> [--dry-run]   Pull/rebuild + recreate a service
                                        (or all enabled), type-dispatched
    vz-ai-stack.sh tutorial-serve [--port N] [--ttl 30m] [--revoke]   serve doc/TUTORIAL.html
                                        + safe 'Try it live' proxy (ephemeral local-only key)
    vz-ai-stack.sh models-serve [--port N] [--read-only] [--revoke]   serve doc/MODELS.html
                                        (Model & Agent Console) — view/stage/apply model +
                                        agent-binding changes via UI; wraps the `model` CLI
    vz-ai-stack.sh fleet-studio [--port N] [--no-open]   review+edit agent-profiles/ in a
                                        browser (live read+write via File System Access API)
    vz-ai-stack.sh understand-dashboard [path] [--no-open] [--port N]   interactive
                                        knowledge-graph dashboard (Phase 30; default path = stack repo)
    vz-ai-stack.sh reset --confirm soft|hard|nuke [--yes]   tiered destructive reset
                                        (--yes/-y: non-interactive; auto-accepts the
                                         soft/hard y/n gate. nuke's typed gate stays manual.)
    vz-ai-stack.sh start <service>          start a service; prints URL + Stop line; opens browser for UI
                                        services (gated: interactive TTY, not NO_BROWSER/CI).
                                        Special: `start lmstudio` — guards macOS + /Applications/LM Studio.app;
                                        `start claw3d` — health-gated composite (bridge + UI).
                                        Flags: --no-open (suppress browser), --open (force browser past CI gate).
                                        Non-daemon types (cli-only, agent-pattern, etc.) print usage + exit 0.
    vz-ai-stack.sh run <service>            alias for start
    vz-ai-stack.sh stop <service>           stop a service (bin/stop-<service>.sh, docker stop, else brew services for ollama/openshell)
    vz-ai-stack.sh <service> start          shortcut for: vz-ai-stack.sh start <service>
    vz-ai-stack.sh <service> run            shortcut for: vz-ai-stack.sh start <service>
    vz-ai-stack.sh <service> stop           shortcut for: vz-ai-stack.sh stop <service>
                                        (enable/disable are accepted as aliases for start/stop)

Phases (in install order) — pass the id OR the name (run `vz-ai-stack.sh phases` for the table):
  00 00s 00n 00v 02 03 01 01h 04 04f 04g 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 04h 26
  opt-in extras (not in `install all` — add them all with `install all --include-optionals`): 21 portless · 22 cmux · 23 skillspector · 24 openagents · 25 lmstudio · 27 sourcegraph · 28 aionui · 29 openwork · 30 understand · 31 ingress · 32 metagpt · 33 agentscope · 34 oasis · 35 chatdev · 36 aitown

Per-command help:  vz-ai-stack.sh <command> --help   OR   vz-ai-stack.sh help <command>
  e.g.  vz-ai-stack.sh install --help   ·   vz-ai-stack.sh help model   ·   vz-ai-stack.sh help embedding
Per-SERVICE help:  vz-ai-stack.sh help <service>   (what it is · config · usage; `help services` lists them)
EOF
}

# usage_for TOKEN — focused, per-subcommand help: the usage line(s) for TOKEN
# plus their indented continuation lines. Reuses usage() as the single source of
# truth (no duplicated help text). Falls back to the full usage if TOKEN is not a
# documented subcommand.
usage_for() {
  local t="$1" out
  out="$(usage | awk -v t="$t" '
    /^    vz-ai-stack\.sh /{ show = ($0 ~ "^    vz-ai-stack\\.sh "t"([ ]|$)") }
    show { print }
  ')"
  if [[ -z "$out" ]]; then
    echo "No per-command help for '$t'. Full command list:"; echo
    usage
    return 0
  fi
  printf 'vz-ai-stack.sh %s — usage:\n\n%s\n\nFull command list:  vz-ai-stack.sh --help\n' "$t" "$out"
}

# is_subcommand TOKEN — true if TOKEN is a known top-level verb (for routing
# `help <verb>` to usage_for vs. the per-service help path).
is_subcommand() {
  case "$1" in
    install|prepare-sudo|test|phases|steps|list|status|model|fleet|doctor|deps|\
    setup|keys|verify|adopt|apply-restarts|logs|history|gc|cleanup|migrate-v2|upgrade|\
    tutorial-serve|models-serve|fleet-studio|understand-dashboard|reset|start|run|enable|stop|disable|docker-engine|ingress|help) return 0 ;;
    *) return 1 ;;
  esac
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

# Canonical phase order for `install all`. Single source for both the real
# install loop and the --dry-run plan, so they can never drift.
install_all_phase_order() {
  echo "00 00s 00n 00v 02 03 01 01h 04 04f 04g 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 04h 26"
}

# install_all_optional_phase_order — the OPT-IN phases, computed dynamically as
# (every phase file) MINUS (install_all_phase_order). Drift-proof: a new phase file
# is automatically opt-in until it's added to the core order above, and this never
# goes stale the way a hardcoded list does (the old enumerations even disagreed —
# one listed `23 skillspector` but dropped `31 ingress`). Emitted in phase-id order
# (the *.sh glob is already lexically sorted, which equals numeric order for the
# 21-36 opt-in range). Run only by `install all --include-optionals`. This function is the
# runtime SOURCE OF TRUTH; the at-a-glance opt-in id list in cmd_help's usage heredoc is a
# hand-maintained convenience copy — keep it in sync when adding a phase (or rely on the
# dynamic `vz-ai-stack.sh phases`).
install_all_optional_phase_order() {
  local core=" $(install_all_phase_order) " out="" f id
  for f in "$AI_STACK"/installer/phases/*.sh; do
    id="$(basename "$f" .sh)"; id="${id%%_*}"
    [[ "$core" == *" $id "* ]] || out+="$id "
  done
  echo "${out% }"
}

cmd_install() {
  local dry=0 opt=0 target="" a
  for a in "$@"; do
    case "$a" in
      --dry-run|--plan|-n) dry=1 ;;
      --include-optionals|--with-optionals) opt=1 ;;
      --) ;;
      -*) err "unknown install flag: $a (try --dry-run / --include-optionals)"; exit 2 ;;
      *) if [[ -z "$target" ]]; then target="$a"; else err "unexpected extra argument: $a"; exit 2; fi ;;
    esac
  done
  target="${target:-all}"

  # --include-optionals only EXTENDS `install all` (it appends the opt-in phases after
  # the core run). On a single-phase target it's meaningless — reject it with a clear
  # pointer rather than silently ignoring the flag.
  if (( opt )) && [[ "$target" != "all" ]]; then
    err "--include-optionals only EXTENDS 'install all' (it appends every opt-in phase after the core run) — it has no meaning with a single target ('$target'). To install just this opt-in phase:  bash $0 install $target .  To run the core stack + all opt-ins:  bash $0 install all --include-optionals"
    exit 2
  fi

  # --dry-run / --plan: preview ONLY — makes no changes, installs nothing, never
  # calls preflight (which would bootstrap deps) or takes the lock.
  if (( dry )); then
    install_plan "$target" "$opt"
    return $?
  fi

  # Refuse to operate the LIVE stack from a git worktree. Incident 2026-06-20:
  # containers bind-mount paths under $AI_STACK (honcho Postgres data, autofyn
  # workspace, …); installing from a worktree binds them to the worktree, and
  # removing it later breaks the running stack. --dry-run above is exempt (no-op).
  worktree_guard install

  preflight
  lock_acquire

  # FIRST STEP of ANY install (`install all` OR `install <phase>`): make `.env`
  # install-ready, then — first-run, interactively — offer to populate optional
  # API keys BEFORE any phase runs, so a phase that registers cloud models sees
  # them. env_ensure_baseline is idempotent + prompt-free (also called by Phase
  # 00; generates LITELLM_MASTER_KEY/PHOENIX_SECRET once, leaves cloud keys empty
  # — a local-only / Claude-subscription user needs nothing more). setup_maybe_offer
  # is TTY-only + stamp-gated (offered once; no-op under NO_PROMPT/--yes/non-TTY or
  # once a cloud key is set). This guarantees `.env` is populated even for a
  # standalone `install <phase>` that never runs Phase 00.
  note "Preparing .env baseline (first step of every install)…"
  env_ensure_baseline
  setup_maybe_offer

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
    # - 04h (agent fleet across claude-code/pi/hermes) runs after its deps: it
    #   uploads into pi-v1 (Phase 15) and widens PI_LITELLM_KEY (minted by 15) +
    #   HERMES key.
    # - 26 (mempalace) is appended LAST: a zero-dependency leaf (needs only .env/00,
    #   LiteLLM/01, uv/14 — all earlier; nothing in the installer consumes it), so
    #   placing it last fail-isolates it — a PyPI/network hiccup in this niche
    #   memory tool can't block any core phase. It's a CLI tool (no daemon, no
    #   container) that installs ZERO live side effects: the Claude Code Stop/
    #   PreCompact capture hooks stay an explicit opt-in (bin/mempalace-hooks).
    local phases=( $(install_all_phase_order) )
    for p in "${phases[@]}"; do
      run_phase "$p" || {
        err "Phase $p failed. After fixing, resume with:  bash $0 install $p"
        exit 1
      }
    done
    # --include-optionals: after EVERY core phase succeeds, install the opt-in extras
    # too. BEST-EFFORT — a failing optional (a missing host dep like the LM Studio app,
    # a heavy sim build, etc.) WARNs and continues instead of aborting, so one optional
    # can't undo a green core install or block the others. Runs BEFORE bootstrap_run_all
    # so the final doctor covers them. Each opt-in is idempotent (run_phase re-checks its
    # stamp). NOT gated on NO_PROMPT — the opt-ins are part of the requested install.
    if (( opt )); then
      local -a optphases=() optfail=()
      local optp
      optphases=( $(install_all_optional_phase_order) )
      hdr "Opt-in extras (--include-optionals) — best-effort"
      # Set expectations BEFORE the loop: this is many phases and some are heavy. Not a Y/n
      # gate — the user explicitly asked for it ("force") — just a clear signal + a Ctrl-C
      # window + the --dry-run pointer, so an --include-optionals run is never a surprise.
      warn "Installing ${#optphases[@]} OPT-IN phase(s) after the core stack — some are HEAVY (the 5 agent-sims 32-36 build venvs/containers; 36 aitown is a Convex/Node image build of ~GBs + minutes; 27 sourcegraph is a large Docker pull)."
      warn "Host-dep caveats: 25 lmstudio needs the LM Studio app; 31 ingress needs 'sudo $0 prepare-sudo' (lo0 alias). A failing optional just warns + continues — the core install is already complete."
      warn "Ctrl-C now to abort, or preview first:  $0 install all --include-optionals --dry-run"
      note "Opt-in phases: ${optphases[*]}"
      for optp in "${optphases[@]}"; do
        run_phase "$optp" || { warn "opt-in phase $optp did not complete — continuing (retry alone: bash $0 install $optp)"; optfail+=("$optp"); }
      done
      if (( ${#optfail[@]} )); then
        warn "opt-in phases that did NOT complete: ${optfail[*]} (the core install is unaffected; install each directly once its host deps are ready)"
      else
        ok "all ${#optphases[@]} opt-in phase(s) installed"
      fi
    fi
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

# phase_name_for <id> — the human name suffix of phase file <id>_*.sh (or empty).
phase_name_for() {
  local id="$1" f b
  for f in "$AI_STACK"/installer/phases/"$id"_*.sh; do
    [[ -e "$f" ]] || return 0
    b="$(basename "$f" .sh)"; echo "${b#*_}"; return 0
  done
}

# install_plan <target> — read-only preview of `install <target>`: the host-deps
# status + each phase's done/pending state (from its stamp file). Changes NOTHING,
# installs nothing, starts nothing. This is the `--dry-run` / `--plan` path.
install_plan() {
  local target="$1" opt="${2:-0}" lbl
  lbl="$target"; (( opt )) && lbl="$target --include-optionals"
  hdr "install $lbl — DRY RUN (preview only; nothing is installed, started, or changed)"

  note "Host dependencies (read-only check):"
  deps_report --check || true   # informational; a missing dep does NOT abort a plan
  echo

  local -a phases optphases=()
  local optids=""
  if [[ "$target" == "all" ]]; then
    phases=( $(install_all_phase_order) )
    optids="$(install_all_optional_phase_order)"   # computed ONCE; reused by the preview + the footer note
    (( opt )) && optphases=( $optids )
  else
    local script b
    script="$(resolve_phase_script "$target")" || { err "no phase matches '$target'"; return 2; }
    b="$(basename "$script" .sh)"; phases=( "${b%%_*}" )
  fi

  note "Phases that 'install $lbl' would run, in order (✓ already complete · • would run):"
  # __install_plan_row prints one ✓/• row and bumps the caller's done/todo (bash dynamic scope).
  local p done=0 todo=0
  __install_plan_row() {
    if stamp_check "$1" 2>/dev/null; then
      printf '  ✓ %-4s %s\n' "$1" "$(phase_name_for "$1")"; done=$((done+1))
    else
      printf '  • %-4s %s\n' "$1" "$(phase_name_for "$1")"; todo=$((todo+1))
    fi
  }
  for p in "${phases[@]}"; do __install_plan_row "$p"; done
  if (( ${#optphases[@]} )); then
    note "  — then opt-in extras (--include-optionals; best-effort, a failure warns + continues) —"
    for p in "${optphases[@]}"; do __install_plan_row "$p"; done
  fi
  unset -f __install_plan_row
  echo
  if (( opt )); then
    ok "plan: ${todo} phase(s) would run (core + opt-in), ${done} already complete — no changes made"
  else
    [[ "$target" == "all" ]] && note "(Opt-in extras are NOT in 'install all': ${optids}. Run '$0 phases' for their names. Add them all with 'install all --include-optionals', or install one by name.)"
    ok "plan: ${todo} phase(s) would run, ${done} already complete — no changes made"
  fi
  return 0
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

  # 4. service-name -> its owning phase. `status` lists SERVICES (services.yml);
  #    many are sub-components installed BY a phase whose name differs
  #    (docs_ingestor -> 06_documents, litellm_guardrails_* -> 04g_security,
  #    lumen_mcp -> 16_lumen). If the selector is such a service, resolve to its
  #    declared `phase:` so the name shown in `status` is directly installable.
  #    Reached ONLY after every phase id/name/alias match above fails, so those
  #    always win and existing behavior is unchanged — this purely rescues names
  #    that would otherwise bail with "no phase matches".
  local phase_id base name
  phase_id="$(SVC="$sel" yq -r '.services[strenv(SVC)].phase // ""' "${SERVICES_YML:-$AI_STACK/services.yml}" 2>/dev/null || true)"
  # Guard the glob below: a phase id is digits + an optional lowercase suffix (00,
  # 01h, 04g). Rejecting anything else stops a malformed services.yml `phase:` (e.g.
  # a stray `*`) from glob-matching an arbitrary phase via the find -name pattern.
  if [[ "$phase_id" =~ ^[0-9][0-9a-z]*$ ]]; then
    script="$(find "$dir" -maxdepth 1 -name "${phase_id}_*.sh" -print -quit 2>/dev/null)"
    if [[ -n "$script" ]]; then
      base="$(basename "$script" .sh)"; name="${base#*_}"
      printf "→ '%s' is installed by phase %s (%s) — resolving there\n" "$sel" "$phase_id" "$name" >&2
      printf '%s' "$script"; return 0
    fi
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
  echo "A service name shown in 'status' also works — it resolves to the phase that installs it."
  echo "Aliases: litellm=inference, telegram=hermes_telegram, hermes=hermes_fleet, sandbox=openshell, unsloth=unsloth_studio, halo=halo_autoreason, ui=uis, docs=documents, memory=alt_memory"
}

cmd_test()    { local p="$1" script id="$1"; if script="$(resolve_phase_script "$p" 2>/dev/null)"; then id="$(basename "$script" .sh)"; id="${id%%_*}"; fi; bash "$AI_STACK/installer/smoke/${id}.sh"; }
cmd_status()  { bash "$AI_STACK/installer/lib/status.sh" "$@"; }
cmd_model()   { bash "$AI_STACK/installer/lib/models.sh" "$@"; }
cmd_embedding() { bash "$AI_STACK/installer/lib/embeddings.sh" "$@" || return $?; }
cmd_fleet()   { bash "$AI_STACK/installer/lib/fleet.sh" "$@"; }
cmd_hermes()  { bash "$AI_STACK/installer/lib/fleet.sh" run "$@"; }   # run ONE agent: vz-ai-stack.sh hermes <role> ["prompt"]
cmd_docker_engine() { bash "$AI_STACK/installer/lib/docker-engine.sh" "$@"; }
cmd_ingress() { bash "$AI_STACK/installer/lib/ingress.sh" "$@"; }
cmd_help() {
  # bare `help` → the full command list (same as --help; "what can I do?").
  if [[ -z "${1:-}" ]]; then usage; return 0; fi
  # `help <subcommand>` (install, model, fleet, …) → that command's usage.
  # `help <service>` / `help services` / `help regen` → per-service help (help.sh).
  if is_subcommand "$1"; then usage_for "$1"; return 0; fi
  # `|| true`: help.sh exits non-zero on an unknown service — keep the friendly
  # message it prints, but don't let it trip the ERR trap into the user's output.
  bash "$AI_STACK/installer/lib/help.sh" "$@" || true
}
cmd_doctor()  { bash "$AI_STACK/installer/doctor/doctor.sh" "${1:-}" || return $?; }
cmd_adopt()   { worktree_guard adopt; bash "$AI_STACK/installer/lib/adopt.sh" "$1"; }
cmd_logs()    { docker logs "$1" "${2:-}"; }
cmd_gc()      { worktree_guard gc; bash "$AI_STACK/installer/lib/gc.sh"; }
cmd_cleanup() { bash "$AI_STACK/installer/lib/cleanup.sh" "$@"; }   # reclaim disk: regenerable artifacts (node_modules/.venv/caches), dry-run by default
cmd_history() { bash "$AI_STACK/installer/lib/history.sh"; }
# Runs in a separate process so it owns its own lock (and trap) — see upgrade.sh.
cmd_upgrade() { worktree_guard upgrade; bash "$AI_STACK/installer/lib/upgrade.sh" "$@"; }  # docker pull + --recreate — never from a worktree
# Serves doc/TUTORIAL.html + a loopback proxy with an ephemeral local-only key.
cmd_tutorial_serve() { bash "$AI_STACK/installer/lib/tutorial-serve.sh" "$@"; }
# Serves doc/MODELS.html (the Model & Agent Console) + a loopback proxy that wraps the
# `model` CLI to view/stage/apply model + agent-binding changes. Apply may restart the
# live LiteLLM — run from MAIN (warns if a worktree); --read-only is safe anywhere.
cmd_models_serve() { bash "$AI_STACK/installer/lib/models-serve.sh" "$@"; }
# Serves doc/FLEET.html on loopback to review+edit agent-profiles/ in a browser.
cmd_fleet_studio() { bash "$AI_STACK/installer/lib/fleet-studio.sh" "$@"; }
# Serves the Understand-Anything knowledge-graph dashboard (Phase 30) for a repo.
cmd_understand_dashboard() { bash "$AI_STACK/installer/lib/understand-dashboard.sh" "$@"; }

# cmd_start <svc> — invoke bin/start-<svc>.sh (the canonical per-service
# launcher). All managed services have one. For docker-compose services
# like deerflow, the wrapper sources required secrets (e.g.
# LITELLM_MASTER_KEY) before invoking the compose entrypoint so compose's
# ${VAR} substitution resolves cleanly without warnings.
# _is_brew_service <name> — true if <name> is one of the stack's brew-managed
# services (ollama, openshell) AND it's actually registered with brew. Restricted
# to a known allowlist so `start/stop` never becomes a generic `brew services`
# wrapper (e.g. netdata/podman). ANSI codes are stripped — Homebrew colorizes the
# service-name column on a TTY, which would break a raw `$1==s` match.
_is_brew_service() {
  case "$1" in ollama|openshell) ;; *) return 1 ;; esac
  command -v brew >/dev/null 2>&1 || return 1
  brew services list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk -v s="$1" 'NR>1 && $1==s {f=1} END{exit !f}'
}

# _report_started <svc> — print the authoritative reach line (URL or Endpoint)
# plus the Stop command. Reads open_url / alias / host_port from services.yml.
_report_started() {
  local svc="$1"
  local open_url alias_val host_port
  open_url="$(SVC="$svc" yq -r '.services[strenv(SVC)].open_url // ""' "$SERVICES_YML" 2>/dev/null || true)"
  alias_val="$(SVC="$svc" yq -r '.services[strenv(SVC)].alias // ""'  "$SERVICES_YML" 2>/dev/null || true)"
  host_port="$(SVC="$svc" yq -r '.services[strenv(SVC)].host_port // ""' "$SERVICES_YML" 2>/dev/null || true)"
  if [[ -n "$open_url" ]]; then
    ok "URL: $open_url"
  elif [[ -n "$alias_val" && -n "$host_port" ]]; then
    ok "Endpoint: http://${alias_val}:${host_port}"
  elif [[ -n "$host_port" ]]; then
    ok "Endpoint: http://localhost:${host_port}"
  fi
  note "Stop:  vz-ai-stack.sh stop $svc"
}

# _browser_open <svc> <url> — best-effort browser open, gated on TTY/CI/flags.
# Always prints the URL even when it cannot open a browser. Never fails the command.
# Caller must set _START_FRESH=1 (fresh start) or 0 (idempotent / already running)
# and _NO_OPEN / _FORCE_OPEN (parsed from --no-open / --open flags) before calling.
_browser_open() {
  local svc="$1" url="$2"
  [[ -z "$url" ]] && return 0
  # Suppress if explicitly disabled
  [[ "${_NO_OPEN:-0}" == "1" ]] && return 0
  # Only browser-open on a FRESH start (not "already running")
  [[ "${_START_FRESH:-1}" == "0" ]] && return 0
  # Determine launcher
  local launcher=""
  if [[ "$(uname)" == Darwin ]] && command -v open >/dev/null 2>&1; then
    launcher="open"
  elif command -v xdg-open >/dev/null 2>&1; then
    launcher="xdg-open"
  fi
  # Gate: interactive TTY AND not NO_BROWSER/CI — unless --open forces it
  local can_open=0
  if [[ "${_FORCE_OPEN:-0}" == "1" && -n "$launcher" ]]; then
    can_open=1
  elif [[ -n "$launcher" ]] && [[ -t 1 ]] && [[ -z "${NO_BROWSER:-}" && -z "${CI:-}" ]]; then
    can_open=1
  fi
  if (( can_open )); then
    # If the URL host is a friendly name not yet in /etc/hosts (prepare-sudo not run
    # for a newly added alias), fall back to 127.0.0.1 — loopback host services bind
    # there, so the open still works; the friendly hostname kicks in after prepare-sudo.
    local _host="${url#*://}"; _host="${_host%%[:/]*}"
    if [[ -n "$_host" && ! "$_host" =~ ^[0-9.]+$ && "$_host" != localhost ]] \
       && ! awk -v h="$_host" '$1!~/^#/{for(i=2;i<=NF;i++) if($i==h) f=1} END{exit !f}' /etc/hosts 2>/dev/null; then
      local _old="//$_host" _new="//127.0.0.1"
      url="${url/$_old/$_new}"
      note "(hostname '$_host' not in /etc/hosts yet — opening 127.0.0.1; run 'sudo vz-ai-stack.sh prepare-sudo' for the friendly name)"
    fi
    # Token-gated UIs (services.yml `open_url_token_env`, e.g. openwork): open the
    # PRE-TOKENED url via a 0600 temp redirect so the token never lands in argv/ps/
    # logs. The UI persists it to localStorage, so later bare-url opens connect too.
    local tok_env tok
    tok_env="$(SVC="$svc" yq -r '.services[strenv(SVC)].open_url_token_env // ""' "$SERVICES_YML" 2>/dev/null || true)"
    [[ -n "$tok_env" && "$tok_env" != "null" ]] && tok="$(get_env "$tok_env" '' 2>/dev/null || true)"
    if [[ -n "${tok:-}" ]]; then
      local _td _f
      if _td="$(mktemp -d -t aistack-open 2>/dev/null)"; then
        _f="$_td/open.html"
        ( umask 077; printf '<!doctype html><meta http-equiv="refresh" content="0;url=%s#token=%s"><body>opening %s…</body>\n' "$url" "$tok" "$svc" > "$_f" )
        chmod 600 "$_f" 2>/dev/null || true
        "$launcher" "$_f" >/dev/null 2>&1 || true
        ( sleep 8; [[ -n "$_td" ]] && rm -rf "$_td" ) >/dev/null 2>&1 &   # cleanup once the browser has read it
        return 0
      fi
    fi
    "$launcher" "$url" 2>/dev/null || true
  else
    note "(no browser opened — headless/CI; open it yourself: $url)"
  fi
}

# _ensure_setup <svc> — enumerated pre-flight check for services that need a
# one-time setup step before they can start (claw3d, lmstudio). If the prereq
# path exists, returns 0 immediately. Otherwise: interactive TTY (and not
# NO_PROMPT/CI) → prompt to install now; non-interactive → print the command
# and exit non-zero.
_ensure_setup() {
  local svc="$1"
  local prereq=""
  local phase=""
  case "$svc" in
    claw3d)   prereq="$AI_STACK/claw3d/node_modules"; phase="19" ;;
    lmstudio) prereq="/Applications/LM Studio.app";   phase="25" ;;
    *)        return 0 ;;  # not enumerated — no prereq check
  esac
  [[ -e "$prereq" ]] && return 0
  # Prereq missing — decide whether to prompt or bail
  if [[ -t 0 && -z "${NO_PROMPT:-}" && -z "${CI:-}" ]]; then
    local answer
    # -t 30: a live-but-unattended TTY must not block forever; timeout/EOF → "n".
    read -r -t 30 -p "$svc isn't set up yet — set it up now? (~2 min) [y/N] " answer || answer="n"
    case "${answer,,}" in
      y|yes)
        # Continue to start ONLY if setup succeeded — a partial install must not
        # fall through to a confusing "node_modules missing" start error.
        if ! cmd_install "$svc"; then
          err "$svc setup failed — fix the above, then: vz-ai-stack.sh install $svc"
          exit 1
        fi
        return 0
        ;;
    esac
  fi
  err "$svc isn't set up — run: vz-ai-stack.sh install $svc"
  exit 1
}

cmd_start() {
  local svc=""
  # Parse --no-open / --open flags and strip them before svc resolution.
  # These are stored in variables that _browser_open reads.
  _NO_OPEN=0
  _FORCE_OPEN=0
  _START_FRESH=0   # default: suppress browser-open; flip to 1 only on a confirmed fresh start
  local -a passthrough=()
  for arg in "$@"; do
    case "$arg" in
      --no-open) _NO_OPEN=1 ;;
      --open)    _FORCE_OPEN=1 ;;
      *)         passthrough+=("$arg") ;;
    esac
  done
  set -- "${passthrough[@]+"${passthrough[@]}"}"
  svc="${1:-}"
  if [[ -z "$svc" ]]; then
    err "Usage: vz-ai-stack.sh start <service>"
    _list_startable_services
    exit 2
  fi

  # Refuse starting the LIVE stack from a git worktree (see the cmd_install note):
  # start scripts (re)create containers that bind-mount paths under $AI_STACK.
  worktree_guard "start $svc"

  # Step 1: enumerated pre-flight setup check (claw3d, lmstudio).
  _ensure_setup "$svc"

  # Read the declared type once (drives the non-daemon dispatch in Step 4).
  local svc_type
  svc_type="$(SVC="$svc" yq -r '.services[strenv(SVC)].type // ""' "$SERVICES_YML" 2>/dev/null || true)"

  local script="$AI_STACK/bin/start-${svc}.sh"
  # Gate on -f (exists), not -x: we invoke via `bash "$script"`, so the +x bit is
  # irrelevant — and gating on -x silently mis-routes a present-but-non-executable
  # script (e.g. a perms slip in an edit) to the "no start script" error path.
  if [[ -f "$script" ]]; then
    # Step 2: ALWAYS run the start script (no exec, no docker pre-skip). Running it
    # every time is REQUIRED for correctness: docker start scripts perform pre-flight
    # side-effects BEFORE their recreate_guard — e.g. start-litellm.sh's Postgres
    # reachability check + the P1010 ownership/grant-probe self-heal. An earlier
    # "container already running → short-circuit" optimization skipped those and was
    # a regression. Instead we run the script and (below) map its benign
    # "already exists + running" non-zero exit to an idempotent success.
    #
    # `... | tee "$tmp_out" || rc=$?` : tee streams combined stdout+stderr to OUR
    # stdout (visible interactively AND capturable via `start x >log`) and to the temp
    # file. The 2>&1 merge is REQUIRED so recreate_guard's stderr warnings land in
    # $captured for the mapping below. pipefail ⇒ rc is the script's true exit code,
    # not tee's. Verified: a script that exits 7 yields rc=7 and does NOT abort here.
    local rc=0 tmp_out captured
    tmp_out="$(mktemp)"
    bash "$script" "${@:2}" 2>&1 | tee "$tmp_out" || rc=$?
    captured="$(cat "$tmp_out")"
    rm -f "$tmp_out"
    if (( rc != 0 )); then
      # Benign idempotent case: the script ran its side-effects, then recreate_guard
      # refused to clobber an already-existing + RUNNING container ("Container 'x'
      # already exists." / "Status: running.") and returned non-zero. The start
      # contract says "already running = success" → report + return 0 (no re-open).
      # Confirmed against the authoritative docker state so a real failure still
      # propagates.
      if printf '%s' "$captured" | grep -qi "already exists" \
         && [[ "$(docker inspect -f '{{.State.Running}}' "$svc" 2>/dev/null)" == "true" ]]; then
        _START_FRESH=0
        _report_started "$svc"
        return 0
      fi
      return "$rc"
    fi
    # rc==0: the script started fresh OR reconciled in place (recreate_guard's
    # idempotent paths print "already running" or "was stopped — restarted"). Flip to
    # fresh (browser-open eligible) ONLY on a genuine fresh create — a reconciled or
    # already-up container must NOT pop a browser tab (matters when `start`/install
    # recovers a whole stopped stack: dozens of tabs otherwise).
    if printf '%s' "$captured" | grep -qiE "already running|was stopped"; then
      _START_FRESH=0
    else
      _START_FRESH=1
    fi
    _report_started "$svc"
    local open_url
    open_url="$(SVC="$svc" yq -r '.services[strenv(SVC)].open_url // ""' "$SERVICES_YML" 2>/dev/null || true)"
    _browser_open "$svc" "$open_url"
    return 0
  fi

  # Step 3: brew-managed service (ollama/openshell)?
  if _is_brew_service "$svc"; then
    [[ "$svc" == openshell ]] && warn "Note: this starts only the OpenShell GATEWAY daemon. Sandboxes (hermes-fleet-v1/pi-v1) are separate — recreate them with 'vz-ai-stack.sh install 04 04f 15' if needed."
    log "No bin/start-${svc}.sh — '$svc' is a brew service; using 'brew services start $svc'"
    brew services start "$svc"
    _report_started "$svc"
    return 0
  fi

  # Step 4: non-daemon type? Print honest categorical message + help.usage, exit 0.
  # Non-daemon types never have a start script and should not get the generic error.
  # ($svc_type was read once above.) `openshell` covers sandbox-resident agents like
  # `pi` (invoked via bin/pi / bin/pi-as), which must get a categorical message —
  # NOT the misleading "no start script" error. (The brew SERVICE `openshell` itself
  # hits the brew branch above first, so it never reaches here.)
  case "$svc_type" in
    cli-only|clone-only|pip-package|npm-global|agent-pattern|\
    litellm-feature|litellm-virtual-key|paperclip-plugin|\
    hermes-profiles|sandbox-daemon|openshell)
      local usage_prose
      usage_prose="$(SVC="$svc" yq -r '.services[strenv(SVC)].help.usage // ""' "$SERVICES_YML" 2>/dev/null || true)"
      note "$svc is a ${svc_type//-/ }; it doesn't run as a daemon. To use it:"
      if [[ -n "$usage_prose" ]]; then
        printf '%s\n' "$usage_prose"
      else
        note "  (no usage prose in services.yml — run: vz-ai-stack.sh help $svc)"
      fi
      return 0
      ;;
  esac

  # Step 5: nothing matched — existing error path.
  err "No start script: $script"
  _list_startable_services
  return 1
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
  worktree_guard stop

  local script="$AI_STACK/bin/stop-${svc}.sh"
  if [[ -f "$script" ]]; then   # -f not -x: invoked via `bash`, +x is irrelevant
    exec bash "$script"
  fi
  if docker inspect "$svc" >/dev/null 2>&1; then
    log "No bin/stop-${svc}.sh — using 'docker stop $svc'"
    exec docker stop "$svc"
  fi
  # Host-process (PID-file) service? The node-bg / python-bg start scripts
  # (claw3d, claw3d-bridge, paperclip, docs_mcp, unsloth, …) daemonize a host
  # process and record its pid at $STATE_DIR/<svc>.pid. Stop it gracefully
  # (TERM → wait → KILL). Idempotent: a stale/dead pidfile is cleaned, missing
  # is "already stopped". This backs the `Stop:` line cmd_start advertises.
  local pidfile="$STATE_DIR/${svc}.pid"
  if [[ -f "$pidfile" ]]; then
    local pid; pid="$(cat "$pidfile" 2>/dev/null || echo "")"
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then
      # OWNERSHIP CHECK (fail-safe): kill -0 proves the pid is alive, NOT that it
      # is still OUR process — a crashed service's pid can be recycled by the OS to
      # an unrelated process. Refuse to kill unless `ps args` identifies it as ours
      # (the svc name in either hyphen/underscore form, or a path under $AI_STACK).
      # The 2026-06-03 watchdog incident was exactly an unguarded kill — never again.
      local pargs svc_h svc_u
      pargs="$(ps -p "$pid" -o args= 2>/dev/null || echo "")"
      svc_h="${svc//_/-}"; svc_u="${svc//-/_}"
      if [[ "$pargs" != *"$svc"* && "$pargs" != *"$svc_h"* && "$pargs" != *"$svc_u"* && "$pargs" != *"$AI_STACK"* ]]; then
        warn "pid $pid (from $pidfile) doesn't look like '$svc' (args: ${pargs:-<none>}) — NOT killing it."
        warn "Treating the pidfile as stale and removing it."
        rm -f "$pidfile"
        return 0
      fi
      log "No bin/stop-${svc}.sh — stopping host process pid $pid (from $pidfile)"
      kill "$pid" 2>/dev/null || true
      local _w=0
      while (( _w < 10 )) && kill -0 "$pid" 2>/dev/null; do sleep 0.5; _w=$(( _w + 1 )); done
      kill -0 "$pid" 2>/dev/null && { warn "pid $pid still alive after TERM — sending KILL"; kill -9 "$pid" 2>/dev/null || true; }
      rm -f "$pidfile"
      ok "Stopped $svc (pid $pid)."
      return 0
    fi
    rm -f "$pidfile"
    note "$svc not running (cleaned stale pidfile)."
    return 0
  fi
  # Brew-managed service (ollama/openshell)? Stop it via brew services.
  if _is_brew_service "$svc"; then
    if [[ "$svc" == ollama ]]; then
      warn "Ollama is the DEFAULT local inference + every agent's availability-gating fallback (local-gemma4)."
      warn "Stopping it breaks any agent on the fallback. Note: 'vz-ai-stack.sh deps' and an interactive 'doctor' fix may restart it."
    elif [[ "$svc" == openshell ]]; then
      warn "Note: this stops only the OpenShell GATEWAY daemon; sandbox containers keep running but lose their gateway (orphaned). The watchdog/relay expect the gateway up."
    fi
    log "No bin/stop-${svc}.sh — '$svc' is a brew service; using 'brew services stop $svc'"
    exec brew services stop "$svc"
  fi
  err "No stop script, no running container, and no brew service named '$svc'."
  exit 1
}

_list_startable_services() {
  echo "Startable services:"
  ls "$AI_STACK"/bin/start-*.sh 2>/dev/null \
    | sed -E 's|.*/start-||; s|\.sh$||' \
    | sort -u | sed 's/^/  - /'
}

# cmd_setup — interactive .env / API-key bootstrap. Ensures the non-interactive
# baseline (so local-only / Claude-subscription works with no keys), then offers
# each optional external secret (cloud LLM keys, GitHub, Blaxel, Telegram) — all
# skippable, written 0600, never echoed. Logic lives in installer/lib/setup.sh.
# Non-interactive (NO_PROMPT / no TTY) ensures the baseline and skips prompts.
cmd_setup() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    err "Do not run 'vz-ai-stack.sh setup' under sudo. Run as your normal user."
    exit 2
  fi
  setup_run "$@"
}

# cmd_deps — show the host dependency map with live status, and (by default)
# install/start anything missing. `--check` is read-only (CI-friendly; non-zero
# exit if anything is missing/down). Logic lives in installer/lib/deps.sh.
cmd_deps() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    err "Do not run 'vz-ai-stack.sh deps' under sudo. Run as your normal user."
    exit 2
  fi
  deps_report "${1:-}"
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
  worktree_guard apply-restarts   # recreates containers (bin/start-*.sh --recreate) — never from a worktree
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
  worktree_guard reset   # tears down / re-binds data paths under $AI_STACK — never from a worktree
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
  # Per-command help: `vz-ai-stack.sh <command> --help|-h` → focused usage for
  # that command (instead of the command rejecting the flag). `help`/`-h`/`--help`
  # as the command itself fall through to the case below.
  if [[ "$cmd" != "help" && "$cmd" != "-h" && "$cmd" != "--help" ]]; then
    case "${1:-}" in
      -h|--help) usage_for "$cmd"; return 0 ;;
    esac
  fi
  case "$cmd" in
    install|"")        cmd_install "$@" ;;   # forward ALL args (target + flags like --dry-run)
    prepare-sudo)      cmd_prepare_sudo ;;
    test)              cmd_test "$1" ;;
    phases|steps|list) cmd_phases ;;
    status)            cmd_status "$@" ;;
    model)             cmd_model "$@" ;;
    embedding|embeddings) cmd_embedding "$@" ;;
    fleet)             cmd_fleet "$@" ;;
    hermes)            cmd_hermes "$@" ;;
    docker-engine)     cmd_docker_engine "$@" ;;
    ingress)           cmd_ingress "$@" ;;
    doctor)            cmd_doctor "${1:-}" ;;
    deps)              cmd_deps "$@" ;;
    setup|keys)        cmd_setup "$@" ;;
    verify)            cmd_verify ;;
    adopt)             cmd_adopt "$1" ;;
    apply-restarts)    cmd_apply_restarts ;;
    logs)              cmd_logs "$@" ;;
    history)           cmd_history ;;
    gc)                cmd_gc ;;
    cleanup)           cmd_cleanup "$@" ;;
    migrate-v2)        cmd_migrate_v2 ;;
    upgrade)           cmd_upgrade "$@" ;;
    tutorial-serve)    cmd_tutorial_serve "$@" ;;
    models-serve)      cmd_models_serve "$@" ;;
    fleet-studio)      cmd_fleet_studio "$@" ;;
    understand-dashboard) cmd_understand_dashboard "$@" ;;
    reset)             cmd_reset "$@" ;;
    run|start|enable)  cmd_start "$@" ;;
    stop|disable)      cmd_stop "$@" ;;
    __print-docker-host) printf '%s\n' "DOCKER_HOST=${DOCKER_HOST:-<unset>}"; exit 0 ;;
    -h|--help)         usage ;;
    help)              cmd_help "$@" ;;   # help · help services · help <svc> · help regen
    *)
      # Reverse-form: `stack <svc> <action>` (e.g. `stack deerflow start`).
      # Translates `stack <svc> start` → cmd_start <svc>, similarly for
      # stop/enable/disable. Only triggers when the first token is NOT a
      # known subcommand AND the second token is a known action verb.
      case "${1:-}" in
        run|start|enable)  cmd_start "$cmd" ;;
        stop|disable)      cmd_stop "$cmd" ;;
        *)             err "Unknown command: $cmd"; usage; exit 2 ;;
      esac
      ;;
  esac
}

main "$@"
