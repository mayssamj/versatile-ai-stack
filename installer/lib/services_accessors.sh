# services_accessors.sh — pure yq accessors over services.yml.
#
# Single source of truth for the per-service field readers shared by status.sh
# (the status table) and upgrade.sh (the type-dispatched upgrade engine). NO
# top-level side effects: sourcing this file defines functions and nothing else.
#
# Requires SERVICES_YML to be set by the caller (env.sh sets it; both callers
# source env.sh first). Idempotent: guarded so repeated sourcing is a no-op.

[[ -n "${__SVC_ACCESSORS_SOURCED:-}" ]] && return 0
__SVC_ACCESSORS_SOURCED=1

# Declared service type (docker, compose, brew-service, openshell, …).
svc_type() { yq -r ".services.$1.type // \"unknown\"" "$SERVICES_YML"; }

# Declared enabled flag (true/false).
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

# Container image for docker-type services (empty default → "-").
svc_image() { yq -r ".services.$1.image // \"-\"" "$SERVICES_YML"; }

# Working directory for compose/docker-compose services, tilde-expanded.
svc_path() {
  local p
  p="$(yq -r ".services.$1.path // \"-\"" "$SERVICES_YML")"
  printf '%s' "${p/#\~/$HOME}"
}

# Installing phase id (e.g. 01, 04f, 15, 20). Default "-".
svc_phase() { yq -r ".services.$1.phase // \"-\"" "$SERVICES_YML"; }

# OpenShell sandbox name for openshell/sandbox-daemon services. Default "-".
svc_sandbox() { yq -r ".services.$1.sandbox // \"-\"" "$SERVICES_YML"; }

# Health URL if declared, else "-".
svc_health() { yq -r ".services.$1.health // \"-\"" "$SERVICES_YML"; }

# Declared network mode (host, ai-stack, none, …). Default "-".
svc_network() { yq -r ".services.$1.network // \"-\"" "$SERVICES_YML"; }

# Env KEY NAMES this service reads (services.yml `consumes_env:`), one per line.
# NAMES ONLY — never values. Empty when none declared. errexit/pipefail-safe:
# `[]?` yields nothing (not an error) when the field is absent.
svc_consumes_env() { yq -r ".services.$1.consumes_env[]?" "$SERVICES_YML" 2>/dev/null; }

# One-line human description (services.yml `desc:`). A cached short copy of
# EXPLORE.html's per-service `what` — used by `status --describe`. Falls back to
# a pointer at the explorer when a service has no desc yet. errexit-safe (ends
# in printf, returns 0).
svc_desc() {
  local d
  d="$(yq -r ".services.$1.desc // \"\"" "$SERVICES_YML")"
  [[ -z "$d" || "$d" == "null" ]] && d='(no description — see doc/EXPLORE.html)'
  printf '%s' "$d"
}
