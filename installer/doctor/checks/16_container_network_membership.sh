# Every ai-stack-managed container is attached to the ai-stack docker network.
CHECKS+=(container_network_membership)
CHECK_TITLE[container_network_membership]="Managed containers are joined to the 'ai-stack' network"

container_network_membership_diagnose() {
  # Bail early if docker daemon isn't up — check 01 will fire its own error.
  docker info >/dev/null 2>&1 || { echo "docker daemon not reachable"; return 1; }

  local offenders=() name nets exempt
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    # Host-port services (e.g. sourcegraph) declare `ai-stack.bridge-exempt=true`:
    # they're reached via host.docker.internal, are absent from aliases.tsv, and
    # dial no stack service, so they intentionally do NOT join the ai-stack bridge.
    # Skip them (else they false-flag this check). The label is an explicit opt-in,
    # so a genuinely-misconfigured alias service can never hide behind it.
    exempt="$(docker inspect "$name" --format '{{index .Config.Labels "ai-stack.bridge-exempt"}}' 2>/dev/null || true)"
    [[ "$exempt" == "true" ]] && continue
    nets="$(docker inspect "$name" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || true)"
    if ! grep -qw "ai-stack" <<<"$nets"; then
      offenders+=("$name (networks: ${nets:-<none>})")
    fi
  done < <(docker ps -a --filter "label=ai-stack.managed=true" --format '{{.Names}}')

  if (( ${#offenders[@]} > 0 )); then
    echo "managed containers not on ai-stack network:"
    printf '  - %s\n' "${offenders[@]}"
    return 1
  fi
}

container_network_membership_fix() {
  # Conservative: do NOT auto-recreate. Recreating a container would destroy
  # its volume bindings unless the start-*.sh script is invoked, and we don't
  # want to second-guess data backups here.
  warn "Conservative policy: not auto-recreating. To fix per container:"
  warn "  bash bin/start-<service>.sh --recreate"
  warn "The new start scripts include '--network ai-stack' by default."
  return 1
}
