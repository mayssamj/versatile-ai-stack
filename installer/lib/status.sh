#!/usr/bin/env bash
# status.sh — print declared vs actual state, like kubectl get pods.
# Invoked via install.sh status.
set -Eeuo pipefail
shopt -s inherit_errexit nullglob

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"

ROW_FMT='%-30s %-10s %-10s %-12s %s\n'

print_header() {
  printf "$ROW_FMT" NAME DECLARED ACTUAL OWNERSHIP NOTES
  printf "$ROW_FMT" "------------------------------" "--------" "--------" "----------" "-----"
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

svc_type() { yq -r ".services.$1.type // \"unknown\"" "$SERVICES_YML"; }
svc_enabled() { yq -r ".services.$1.enabled // false" "$SERVICES_YML"; }

# Compose-project name can differ from the service-key (e.g. `deerflow` →
# project `deer-flow` because compose normalizes underscores to dashes when
# generating container names from a directory). Override per-service via
# `services.<name>.project:` in services.yml; default = service name.
svc_project() {
  local p
  p="$(yq -r ".services.$1.project // \"\"" "$SERVICES_YML")"
  [[ -z "$p" || "$p" == "null" ]] && echo "$1" || echo "$p"
}

# python-bg/node-bg services: `pgrep -f $name` works only when the service
# key string appears in the actual process command line. That's false for
# docs_mcp (cmdline is `…/mcp_server.py`). Allow per-service override via
# `services.<name>.process_pattern:` in services.yml; default = service name.
svc_process_pattern() {
  local p
  p="$(yq -r ".services.$1.process_pattern // \"\"" "$SERVICES_YML")"
  [[ -z "$p" || "$p" == "null" ]] && echo "$1" || echo "$p"
}

# Many python-bg/node-bg services drop a PID file under installer/state/. Prefer
# checking that PID first (more precise than pgrep on shared-name binaries).
svc_pidfile_alive() {
  local pf="$AI_STACK/installer/state/$1.pid"
  [[ -f "$pf" ]] || return 1
  local pid
  pid="$(cat "$pf" 2>/dev/null)"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

print_header

# Use yq to iterate services in declared order.
while IFS= read -r name; do
  [[ -z "$name" ]] && continue
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
    cli-only|clone-only|pip-package|npm-global|litellm-feature|agent-pattern|paperclip-plugin|openshell|hermes-profiles)
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
  [[ "$own" == "foreign" ]] && notes="${notes}foreign (run 'install.sh adopt $name'); "

  printf "$ROW_FMT" "$name" "$declared" "$actual" "$own" "$notes"
done < <(yq -r '.services | keys | .[]' "$SERVICES_YML")
