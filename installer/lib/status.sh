#!/usr/bin/env bash
# status.sh — print declared vs actual state, like kubectl get pods.
# Invoked via vz-ai-stack.sh status.
set -Eeuo pipefail
shopt -s inherit_errexit nullglob

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"

# --- flags ---------------------------------------------------------------------
# -d|--describe  add a dim one-line description sub-line under each row
# --legend       decode the columns (alone: print legend and exit, zero probes)
# Unknown flags warn (common.sh warn) but never abort; non-flag args are ignored.
# `for a in "$@"` is a no-op with zero args (the current vz-ai-stack.sh call site),
# so default behavior is unchanged under set -Eeuo pipefail.
SHOW_DESC=0; SHOW_LEGEND=0; SHOW_VERSIONS=0; LOCAL_ONLY=0
for a in "$@"; do case "$a" in
  -d|--describe)   SHOW_DESC=1 ;;
  --legend)        SHOW_LEGEND=1 ;;
  --versions|-V)   SHOW_VERSIONS=1 ;;   # focused versions view (installed + available)
  --local)         LOCAL_ONLY=1 ;;      # with --versions: installed only, skip the network
  -h|--help)       printf 'usage: vz-ai-stack.sh status [-d|--describe] [--legend] [--versions [--local]]\n'; exit 0 ;;
  -*)              warn "status: unknown flag '$a' (ignored)" ;;
  *)               : ;;
esac; done

ROW_FMT='%-30s %-10s %-10s %-12s %s\n'

print_header() {
  printf "$ROW_FMT" NAME DECLARED ACTUAL OWNERSHIP NOTES
  printf "$ROW_FMT" "------------------------------" "--------" "--------" "----------" "-----"
}

# Decode the columns. Printed under --describe/--legend (and standalone for
# `--legend` alone, which early-exits before any probe). Heading uses common.sh's
# tty-gated C_BOLD/C_DIM/C_RESET; the body is plain so it stays aligned.
print_legend() {
  printf '\n%sLegend%s\n' "$C_BOLD" "$C_RESET"
  printf '  DECLARED   enabled / disabled   your intent in services.yml (change: vz-ai-stack.sh enable|disable <svc>)\n'
  printf '  ACTUAL     running              process/container is up\n'
  printf '             stopped              should be up but is not (see NOTES)\n'
  printf '             n/a                  not a long-running daemon — CLI, config, sandbox-internal, or a minted key\n'
  printf '  OWNERSHIP  managed              container started & labeled by this installer\n'
  printf '             foreign              running but not ours (run: vz-ai-stack.sh adopt <svc>)\n'
  printf '             absent               no container exists\n'
  printf '             -                    N/A — not a container (brew/host/CLI/feature)\n'
  printf '  NOTES      drift hints + the exact command to fix it\n'
}

# Footer: a single always-on dim pointer line by default; the fuller act-on-drift
# block prints only when --describe/--legend is set (keeps the constantly-run
# default output nearly byte-identical). EXPLORE link is a click-to-open file://
# URL built from the already-absolute $AI_STACK.
print_status_footer() {
  if (( SHOW_DESC )) || (( SHOW_LEGEND )); then
    printf '\n%sWhat is each service?%s  Open the interactive explorer:  %sfile://%s/doc/EXPLORE.html%s\n' \
      "$C_BOLD" "$C_RESET" "$C_DIM" "$AI_STACK" "$C_RESET"
    printf '  Act on drift:  vz-ai-stack.sh start <svc> · adopt <svc> · doctor · model sync   (see: vz-ai-stack.sh help)\n'
  else
    printf '\n%sRun %sinstall.sh status --describe%s for one-line descriptions, %s--legend%s to decode columns, or open doc/EXPLORE.html%s\n' \
      "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET" "$C_DIM" "$C_RESET"
  fi
}

# print_host_memory (S1) — surface HOST memory pressure in `status`. READ-ONLY and
# purely informational (NEVER a fault): the 24GB box is oversubscribed by host apps
# (LM Studio, Chrome), not the stack — the OrbStack VM is ~2GB resident, so shedding
# containers frees ~nothing. The real lever is quitting those apps, so we name them.
# All probes are list-only (vm_stat/sysctl/ps) — none can load a model — and every
# pipeline is `|| true`-guarded so a SIGPIPE/odd exit can't abort `status` under
# `set -Eeuo pipefail`. The caller also wraps this in `|| true` (defense in depth):
# a host-memory readout must never break the core service table.
print_host_memory() {
  printf '\n── %s\n' "Host memory (informational — host apps dominate, not a stack fault)"
  local sw free_mb
  sw="$(sysctl -n vm.swapusage 2>/dev/null || true)"
  # Page size is 16KB on Apple Silicon, 4KB on Intel — read it from vm_stat, never assume.
  free_mb="$(vm_stat 2>/dev/null | awk '
      /page size of/   {ps=$8}
      /Pages free/     {gsub(/\./,"",$3); f=$3}
      /Pages inactive/ {gsub(/\./,"",$3); i=$3}
      END {if(ps=="")ps=16384; printf "%d", (f+i)*ps/1048576}' 2>/dev/null || true)"
  printf '  swap:          %s\n' "${sw:-unknown}"
  printf '  free+inactive: %s MB\n' "${free_mb:-?}"
  printf '  top host RSS:\n'
  # RSS is in KB; show by basename so "Google Chrome Helper", "LM Studio", "llama-server"
  # are recognizable. head closing the pipe early can SIGPIPE sort → guard the whole pipe.
  { ps -axo rss=,comm= 2>/dev/null | sort -rn | head -5 \
      | awk '{rss=$1/1024; $1=""; sub(/^[ \t]+/,""); n=$0; sub(/.*\//,"",n); if(length(n)>44)n=substr(n,1,44); printf "    %6.0f MB  %s\n", rss, n}'; } || true
  # Auto-heal posture + any active watchdog alert, so `status` shows the resilience state.
  local conf="$AI_STACK/installer/state/watchdog.conf" alert="$AI_STACK/installer/state/openshell-watchdog.alert" modes
  if [[ -f "$conf" ]]; then
    modes="$(grep -E '=1$' "$conf" 2>/dev/null | sed -E 's/=1$//; s/AI_STACK_WATCHDOG_//; s/AI_STACK_SANDBOX_//' | tr '[:upper:]' '[:lower:]' | tr '\n' ',' | sed 's/,$//' || true)"
    printf '  durability:    %s\n' "${modes:-off (defaults)}"
  fi
  if [[ -f "$alert" ]]; then
    printf '  %swatchdog ALERT:%s %s\n' "$C_BOLD" "$C_RESET" "$(head -1 "$alert" 2>/dev/null || true)"
  fi
  printf '  %slever: host apps dominate RAM — quit LM Studio / Chrome tabs to relieve pressure (the stack cannot shed what it does not own)%s\n' "$C_DIM" "$C_RESET"
}

# Returns: "managed" (we own it), "foreign" (running but not labeled by us),
# "absent" (no container).
ownership() {
  local name="$1"
  if container_exists "$name"; then
    if container_managed "$name"; then echo "managed"
    else echo "foreign"
    fi
  else
    echo "absent"
  fi
}

# ownership_compose: same idea but for compose-managed services. Compose names
# containers `<project>-<service>-N` and never sets `ai-stack.managed`. We
# treat the stack as managed if ANY container's
# `com.docker.compose.project.working_dir` label is under $AI_STACK. This was
# the bug behind the false-"absent" entries for honcho/autofyn/hermes_workspace
# /deerflow on 2026-05-29 (2-agent root cause).
ownership_compose() {
  local name="$1" project
  project="$(svc_project "$name")"
  local first
  first="$(docker ps -a --format '{{.Names}}' | grep -E "^${project}(-|$)" | head -n1 || true)"
  [[ -z "$first" ]] && { echo absent; return; }
  local wd
  wd="$(docker inspect "$first" --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' 2>/dev/null)"
  [[ "$wd" == "$AI_STACK"* ]] && echo managed || echo foreign
}

# Pure per-service yq accessors (svc_type/svc_enabled/svc_project/
# svc_process_pattern + image/path/phase/sandbox/health) live in a shared,
# side-effect-free lib so status.sh and upgrade.sh use one source of truth.
source "$AI_STACK/installer/lib/services_accessors.sh"

# Many python-bg/node-bg services drop a PID file under installer/state/. Prefer
# checking that PID first (more precise than pgrep on shared-name binaries).
svc_pidfile_alive() {
  local pf="$AI_STACK/installer/state/$1.pid"
  [[ -f "$pf" ]] || return 1
  local pid
  pid="$(cat "$pf" 2>/dev/null)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

# Render one status row for a single service. Behavior is unchanged from the
# original flat loop — extracted into a function so the grouped driver below can
# call it per logical section.
render_row() {
  local name="$1"
  local local_type local_enabled declared actual notes own
  local_type="$(svc_type "$name")"
  local_enabled="$(svc_enabled "$name")"
  declared=$([[ "$local_enabled" == "true" ]] && echo enabled || echo disabled)
  actual=stopped
  notes=""

  case "$local_type" in
    docker)
      if container_running "$name"; then actual=running; fi
      ;;
    compose|docker-compose)
      # Compose names containers <project>-<service>-N. The compose project
      # may differ from the service-key (compose normalizes underscores to
      # dashes); resolve via svc_project() (services.yml `project:` override).
      if docker ps --format '{{.Names}}' | grep -qE "^$(svc_project "$name")(-|$)"; then
        actual=running
      fi
      ;;
    brew-service)
      if brew services list 2>/dev/null | awk -v n="$name" '$1==n {print $2}' | grep -q started; then
        actual=running
      fi
      ;;
    python-bg|node-bg)
      # Prefer the recorded PID file (precise, survives shell name drift).
      # Fall back to pgrep on the configured process_pattern (defaults to
      # service name; overridable via services.yml `process_pattern:`).
      if svc_pidfile_alive "$name"; then
        actual=running
      elif pgrep -f "$(svc_process_pattern "$name")" >/dev/null 2>&1; then
        actual=running
      fi
      ;;
    cli-only|clone-only|pip-package|npm-global|litellm-feature|agent-pattern|paperclip-plugin|openshell|hermes-profiles|sandbox-daemon|litellm-virtual-key)
      # None of these are host-pollable long-running daemons: CLIs/clones/pip/npm
      # packages, in-process litellm features, the dual-LLM prompting pattern, a
      # Paperclip UI plugin, sandbox-internal agents, and litellm-virtual-key
      # (pi_gateway_litellm — a minted key, not a process). sandbox-daemon
      # (hermes_telegram) runs INSIDE the sandbox, invisible to host pgrep; doctor
      # check 33 does its real liveness probe via `hermes gateway status`. All
      # report n/a (previously litellm-virtual-key fell through to a meaningless ?).
      actual="n/a"
      ;;
    *) actual="?" ;;
  esac

  own="-"
  case "$local_type" in
    docker)
      own="$(ownership "$name")"
      ;;
    compose|docker-compose)
      # Compose containers don't carry our `ai-stack.managed` label (their
      # provenance is `com.docker.compose.project.working_dir`). Use the
      # compose-aware variant; otherwise every compose service mislabels
      # as `absent` even when running. CHANGELOG 2026-05-29 root cause.
      own="$(ownership_compose "$name")"
      ;;
  esac

  [[ "$declared" == "enabled" && "$actual" == "stopped" ]] && notes="${notes}should be running; "
  [[ "$declared" == "disabled" && "$actual" == "running" ]] && notes="${notes}should be stopped; "
  [[ "$own" == "foreign" ]] && notes="${notes}foreign (run 'vz-ai-stack.sh adopt $name'); "

  printf "$ROW_FMT" "$name" "$declared" "$actual" "$own" "$notes"

  # --describe: dim, 4-space-indented one-line description sub-line. C_DIM/C_RESET
  # come from common.sh and are empty when stdout is not a tty (or TERM=dumb), so
  # piped/redirected output carries no escape codes. Slice at 74 → 4+74 = 78 cols
  # (fits an 80-col terminal). One extra yq read per row, only on the -d path.
  if (( SHOW_DESC )); then
    local d; d="$(svc_desc "$name")"; d="${d:0:74}"; d="${d%"${d##*[![:space:]]}"}"
    printf '    %s%s%s\n' "$C_DIM" "$d" "$C_RESET"
  fi
}

# --- logical service sections for the status view -----------------------------
# Order in which sections print. `other` is a catch-all so a newly-added service
# never silently disappears from `status`.
GROUP_ORDER=(inference storage-memory observability-security agent-runtime uis agents-workflows documents tooling-extras other)

group_label() {
  case "$1" in
    inference)              echo "Inference plane" ;;
    storage-memory)         echo "Storage & memory" ;;
    observability-security) echo "Observability & security" ;;
    agent-runtime)          echo "Agent runtime & sandboxes" ;;
    uis)                    echo "User interfaces" ;;
    agents-workflows)       echo "Agents, research & workflows" ;;
    documents)              echo "Documents / RAG" ;;
    tooling-extras)         echo "Tooling & extras" ;;
    *)                      echo "Other" ;;
  esac
}

# Map a service key to its logical section. Pure bash (no yq) so it's cheap to
# call repeatedly. Keep in sync with services.yml when adding a service.
svc_group() {
  case "$1" in
    litellm|ollama|lmstudio)                                             echo inference ;;
    falkordb|qdrant|honcho|remnic_hermes|byterover_cli)                  echo storage-memory ;;
    phoenix|litellm_guardrails_builtin|litellm_guardrails_secrets|llm_guard|dual_llm_researcher|skillspector) echo observability-security ;;
    openshell|hermes_fleet|hermes_telegram|pi|pi_gateway_litellm)        echo agent-runtime ;;
    openwebui|hermes_workspace|autofyn|paperclip|paperclip_honcho_plugin|claw3d|claw3d_bridge) echo uis ;;
    deerflow|ace|rlm|halo|autoreason|blaxel_cli)                         echo agents-workflows ;;
    docs_ingestor|docs_mcp)                                              echo documents ;;
    unsloth|lumen_mcp|portless|cmux|openagents)                          echo tooling-extras ;;
    *)                                                                   echo other ;;
  esac
}

# --- `status --versions`: focused installed-vs-available view -----------------
# Reuses the SHARED oracle (installer/lib/versions.sh) so it agrees with
# `upgrade --check` exactly. INSTALLED is local/cheap; AVAILABLE is bounded,
# best-effort network (skipped with --local). status.sh CANNOT source upgrade.sh
# (it self-runs upgrade_main), which is why the oracle lives in versions.sh.
print_versions_view() {
  source "$AI_STACK/installer/lib/versions.sh"
  if (( LOCAL_ONLY )); then
    note "installed versions only (--local) — drop --local to also probe upstream."
  else
    note "probing installed + upstream latest (network; bounded — may be slow behind a proxy; --local to skip upstream)…"
  fi
  local fmt='%-26s %-15s %-24s %-22s %s\n'
  printf "$fmt" NAME TYPE INSTALLED AVAILABLE STATUS
  printf "$fmt" "--------------------------" "---------------" "------------------------" "----------------------" "------"
  local grp name type inst avail status
  for grp in "${GROUP_ORDER[@]}"; do
    local -a vmembers=()
    for name in "${ALL_NAMES[@]}"; do [[ "$(svc_group "$name")" == "$grp" ]] && vmembers+=("$name"); done
    (( ${#vmembers[@]} == 0 )) && continue
    printf '\n── %s\n' "$(group_label "$grp")"
    for name in "${vmembers[@]}"; do
      type="$(svc_type "$name")"
      inst="$(svc_installed_version "$name" 2>/dev/null || echo -)"
      if (( LOCAL_ONLY )); then
        avail="-"; status="(local)"
      else
        avail="$(svc_available_version "$name" 2>/dev/null || echo -)"
        status="$(version_status "$name" 2>/dev/null || echo -)"
      fi
      printf "$fmt" "$name" "$type" "$inst" "$avail" "$status"
    done
  done
  printf '\n'
  note "STATUS: up-to-date · update-available · pinned (fixed tag, won't auto-move) · build/rebuild (locally-built) · no-oracle · unknown (registry/proxy unreachable). Act with 'vz-ai-stack.sh upgrade <svc>'."
}

# `--legend` alone: print the legend and exit BEFORE print_header and before any
# yq/docker/brew/pgrep work — zero probes, returns instantly. (With --describe
# also set, fall through so the legend prints after the table instead.)
if (( SHOW_LEGEND )) && (( ! SHOW_DESC )); then print_legend; exit 0; fi

# Collect declared service keys (in services.yml order) once.
ALL_NAMES=()
while IFS= read -r name; do
  [[ -n "$name" ]] && ALL_NAMES+=("$name")
done < <(yq -r '.services | keys | .[]' "$SERVICES_YML")

# `--versions`: focused version view instead of the state table; exit after.
if (( SHOW_VERSIONS )); then print_versions_view; exit 0; fi

print_header

# Print section-by-section; within a section, preserve declared order.
for grp in "${GROUP_ORDER[@]}"; do
  members=()
  for name in "${ALL_NAMES[@]}"; do
    [[ "$(svc_group "$name")" == "$grp" ]] && members+=("$name")
  done
  (( ${#members[@]} == 0 )) && continue
  printf '\n── %s\n' "$(group_label "$grp")"
  for name in "${members[@]}"; do render_row "$name"; done
done

# Host-memory pressure surface (S1) — after the service table, before the footer.
# Wrapped in `|| true`: an informational readout must never break the core status.
print_host_memory || true

# Legend (when describing or asked), then the footer, then the inference hint.
if (( SHOW_DESC )) || (( SHOW_LEGEND )); then print_legend; fi
print_status_footer

declare -F print_inference_hint >/dev/null 2>&1 || source "$AI_STACK/installer/lib/lmstudio.sh"
print_inference_hint
