#!/usr/bin/env bash
# v1_to_v2.sh — migrate services.yml schema v1 → v2 (D6 revised).
#
# Algorithm:
#   - if services.yml has no `version:` key → assume v1, run full migration
#   - if version == 2 → no-op (touch marker if absent)
#   - if version == 1:
#       - read aliases.tsv into associative arrays (service_key → row)
#       - for each service in services.yml:
#           - if a matching row exists, ADD alias/host_ip/host_port/
#             container_port/network/add_host fields via `yq -i`
#           - leave legacy fields (bind, port, ports, health) intact
#           - if no match, leave as-is (cli-only / agent-pattern services)
#       - bump version: 2
#       - write marker installer/state/migrated_to_v2.done
#   - partial recovery: if marker exists but version is still 1, re-run
#     (idempotent — yq won't duplicate keys)
#
# Not invoked automatically yet; the orchestrator wires it into mayssam-ai-stack.sh
# elsewhere. Safe to run standalone:
#     bash installer/migrations/v1_to_v2.sh
set -Eeuo pipefail
shopt -s inherit_errexit nullglob

# Capture overridable SERVICES_YML BEFORE sourcing common.sh, since
# common.sh sets it unconditionally to "$AI_STACK/services.yml".
_SERVICES_YML_OVERRIDE="${SERVICES_YML:-}"

AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/network.sh"

SERVICES_YML="${_SERVICES_YML_OVERRIDE:-$AI_STACK/services.yml}"
MARKER="$STATE_DIR/migrated_to_v2.done"

if [[ ! -f "$SERVICES_YML" ]]; then
  err "services.yml not found at $SERVICES_YML"
  exit 1
fi

if ! command -v yq >/dev/null 2>&1; then
  err "yq is required for the v1→v2 migration. Install via 'brew install yq'."
  exit 1
fi

# Read current version. yq prints 'null' for missing keys; normalize.
current_version="$(yq -r '.version // "null"' "$SERVICES_YML" 2>/dev/null)"
case "$current_version" in
  2)
    ok "services.yml is already version 2 — nothing to migrate"
    [[ -f "$MARKER" ]] || touch "$MARKER"
    exit 0
    ;;
  1|null|"")
    log "services.yml at version '${current_version:-<unset>}' — migrating to v2..."
    ;;
  *)
    err "Unknown services.yml schema version: $current_version"
    err "Refusing to migrate. Inspect the file manually."
    exit 1
    ;;
esac

# Backup the file before mutation.
BACKUP="$SERVICES_YML.bak-${RUN_ID:-$(date +%Y%m%d-%H%M%S)-$$}"
cp -p "$SERVICES_YML" "$BACKUP"
note "Backed up $SERVICES_YML → $BACKUP"

# Load the alias table.
aliases_load || { err "could not load aliases.tsv"; exit 1; }

# Build a service_key → primary alias map and a service_key → extra aliases list.
declare -A PRIMARY_ALIAS=()
declare -A EXTRA_ALIASES_FOR=()
for a in "${ALIASES_LIST[@]}"; do
  sk="${ALIAS_SERVICE_KEY[$a]}"
  [[ -z "$sk" ]] && continue
  if [[ -z "${PRIMARY_ALIAS[$sk]:-}" ]]; then
    PRIMARY_ALIAS[$sk]="$a"
  else
    # Already have a primary → this is an extra alias.
    EXTRA_ALIASES_FOR[$sk]="${EXTRA_ALIASES_FOR[$sk]:-} $a"
  fi
done

# Iterate every service in services.yml in declaration order.
mapfile -t SERVICES < <(yq -r '.services | keys | .[]' "$SERVICES_YML")
log "Found ${#SERVICES[@]} services in services.yml"

migrated=0
skipped=0
for svc in "${SERVICES[@]}"; do
  primary="${PRIMARY_ALIAS[$svc]:-}"
  if [[ -z "$primary" ]]; then
    # No matching alias row → not a network-exposed service (cli-only, pattern, etc.)
    skipped=$((skipped+1))
    continue
  fi

  ip="${ALIAS_IP[$primary]}"
  proto="${ALIAS_PROTOCOL[$primary]}"
  host_port="${ALIAS_HOST_PORT[$primary]}"
  ctr_port="${ALIAS_CONTAINER_PORT[$primary]}"

  # Decide the network field. cli-only / agent-pattern services already skipped
  # (no alias row). Compose services with their own network join ai-stack as
  # `ai-stack`; host-process services join `host`. For now we'll mark anything
  # with a docker-ish type as ai-stack; the file-shape preserves freedom for
  # other implementers to refine.
  svc_type="$(yq -r ".services.\"$svc\".type // \"\"" "$SERVICES_YML")"
  case "$svc_type" in
    docker|compose|docker-compose|helicone-compose)
      network_value="ai-stack"
      ;;
    python-bg|node-bg|brew-service)
      network_value="host"
      ;;
    openshell|hermes-profiles)
      network_value="openshell"
      ;;
    *)
      network_value="none"
      ;;
  esac

  # Use yq -i to add the new fields. yq overwrites existing keys with the same
  # name (idempotent on re-run; legacy fields are left intact because we don't
  # touch them).
  yq -i ".services.\"$svc\".alias = \"$primary\"" "$SERVICES_YML"
  yq -i ".services.\"$svc\".host_ip = \"$ip\"" "$SERVICES_YML"
  yq -i ".services.\"$svc\".host_port = $host_port" "$SERVICES_YML"
  yq -i ".services.\"$svc\".container_port = $ctr_port" "$SERVICES_YML"
  yq -i ".services.\"$svc\".protocol = \"$proto\"" "$SERVICES_YML"
  yq -i ".services.\"$svc\".network = \"$network_value\"" "$SERVICES_YML"
  yq -i ".services.\"$svc\".add_host = [\"ollama:host-gateway\"]" "$SERVICES_YML"

  # extra_aliases for multi-endpoint services (e.g. phoenix has phoenix-otlp).
  extras="${EXTRA_ALIASES_FOR[$svc]:-}"
  if [[ -n "$extras" ]]; then
    # Build a yq-friendly list literal.
    yq -i ".services.\"$svc\".extra_aliases = []" "$SERVICES_YML"
    for ea in $extras; do
      e_ip="${ALIAS_IP[$ea]}"
      e_proto="${ALIAS_PROTOCOL[$ea]}"
      e_hp="${ALIAS_HOST_PORT[$ea]}"
      e_cp="${ALIAS_CONTAINER_PORT[$ea]}"
      yq -i ".services.\"$svc\".extra_aliases += [{\"alias\": \"$ea\", \"host_ip\": \"$e_ip\", \"host_port\": $e_hp, \"container_port\": $e_cp, \"protocol\": \"$e_proto\"}]" "$SERVICES_YML"
    done
  fi

  migrated=$((migrated+1))
done

# Bump or set version: 2 at top of file.
yq -i '.version = 2' "$SERVICES_YML"

# Validate that yq's final output still parses cleanly.
if ! yq -e '.services' "$SERVICES_YML" >/dev/null 2>&1; then
  err "services.yml no longer parses after migration. Restoring from $BACKUP."
  cp -p "$BACKUP" "$SERVICES_YML"
  exit 1
fi

touch "$MARKER"
record "migrated services.yml v1 → v2 ($migrated services updated, $skipped skipped)"
ok "Migrated services.yml v1 → v2 ($migrated updated, $skipped skipped). Backup: $BACKUP"
