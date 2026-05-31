#!/usr/bin/env bash
# Phase 00·S — service control plane.
# services.yml is the single source of truth (already authored in repo, not
# overwritten if user has customizations). Drops the `stack` CLI symlink into
# bin/ for daily-driver convenience. Verifies every enabled docker service
# has a corresponding bin/start-<name>.sh.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

PHASE=00s

precheck() {
  [[ -f "$AI_STACK/services.yml" ]] || return 1
  yq -e '.services | type == "!!map"' "$AI_STACK/services.yml" >/dev/null 2>&1 || return 1
  [[ -x "$AI_STACK/bin/stack" ]] || return 1
  # Every docker-typed enabled service has a start script.
  local svc; local enabled; local svc_type
  while IFS= read -r svc; do
    svc_type="$(yq -r ".services.$svc.type" "$AI_STACK/services.yml")"
    enabled="$(yq -r ".services.$svc.enabled // false" "$AI_STACK/services.yml")"
    case "$svc_type" in
      docker)
        if [[ "$enabled" == "true" && ! -x "$AI_STACK/bin/start-${svc}.sh" ]]; then
          return 1
        fi
        ;;
    esac
  done < <(yq -r '.services | keys | .[]' "$AI_STACK/services.yml")
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (service control plane)"
  exit 0
fi

hdr "Phase 00·S — service control plane"

# services.yml must already exist (we wrote the canonical one at install root).
if [[ ! -f "$AI_STACK/services.yml" ]]; then
  err "services.yml missing. The canonical file is the authoritative one we ship."
  exit 1
fi

# Validate YAML parse.
if ! yq -e '.services' "$AI_STACK/services.yml" >/dev/null 2>&1; then
  err "services.yml does not parse (or is missing top-level 'services:')"
  exit 1
fi

# Drop a `stack` symlink/dispatcher in bin/. It's a thin wrapper around
# install.sh subcommands so `stack status` and `bash install.sh status` both work.
cat > "$AI_STACK/bin/stack" <<'EOF'
#!/usr/bin/env bash
# stack — daily-driver wrapper around install.sh subcommands.
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$AI_STACK/install.sh" "$@"
EOF
chmod +x "$AI_STACK/bin/stack"
ok "wrote $AI_STACK/bin/stack"

# Verify every enabled docker service has a start script.
missing=()
while IFS= read -r svc; do
  svc_type="$(yq -r ".services.$svc.type" "$AI_STACK/services.yml")"
  enabled="$(yq -r ".services.$svc.enabled // false" "$AI_STACK/services.yml")"
  case "$svc_type" in
    docker)
      if [[ "$enabled" == "true" && ! -x "$AI_STACK/bin/start-${svc}.sh" ]]; then
        missing+=("$svc")
      fi
      ;;
  esac
done < <(yq -r '.services | keys | .[]' "$AI_STACK/services.yml")

if (( ${#missing[@]} > 0 )); then
  warn "Missing start scripts (will be created in their owning phase): ${missing[*]}"
fi

# Suggest PATH addition (don't auto-edit zshrc — too intrusive).
if ! echo ":$PATH:" | grep -q ":$AI_STACK/bin:"; then
  note "Add this to your shell rc to make 'stack' command available everywhere:"
  note "    export PATH=\"\$HOME/ai-stack/bin:\$PATH\""
fi

stamp_mark "$PHASE"
record "phase 00·S complete: services.yml validated, bin/stack created"
ok "Phase 00·S — service control plane — complete"
