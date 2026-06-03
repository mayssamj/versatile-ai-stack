# For every managed container on the ai-stack network, spawn a transient
# alpine probe and confirm bare-name DNS resolution works. Apps talk to
# each other by bare name (e.g. LiteLLM → http://phoenix-otlp:4317); a
# silent failure here means inference traces vanish without an error.
CHECKS+=(container_dns_in_network)
CHECK_TITLE[container_dns_in_network]="Containers on 'ai-stack' resolve each other by bare name"

container_dns_in_network_diagnose() {
  # shellcheck source=../../lib/verify.sh
  source "$AI_STACK/installer/lib/verify.sh"

  docker info >/dev/null 2>&1 || { echo "docker daemon not reachable"; return 1; }
  # Pre-install state: ai-stack network legitimately doesn't exist yet
  # (Phase 00·N hasn't run). Pass; check 14 covers the network-must-exist
  # invariant post-install.
  docker network inspect ai-stack >/dev/null 2>&1 || return 0

  # Enumerate containers on the ai-stack network.
  local names
  names="$(docker network inspect ai-stack \
    --format '{{range $k,$v := .Containers}}{{$v.Name}}{{"\n"}}{{end}}' 2>/dev/null \
    | sed 's|^/||' \
    | grep -v '^$' || true)"
  [[ -z "$names" ]] && return 0   # nothing to check

  local offenders=() name
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    # Try the most likely service port for a TCP-connect probe. We don't
    # actually need a port here for a DNS lookup; alpine `getent hosts NAME`
    # is enough. Use getent (busybox supports it).
    local probe_name="ai-stack-doc21-$$-$RANDOM" out rc=0
    out="$(_verify_with_timeout 10 \
      docker run --rm --name "$probe_name" \
      --network ai-stack \
      "$VERIFY_PROBE_IMAGE" \
      sh -c "getent hosts $name" 2>&1)" || rc=$?
    docker rm -f "$probe_name" >/dev/null 2>&1 || true
    if [[ -z "$out" || "$rc" -ne 0 ]]; then
      offenders+=("$name (probe: getent hosts $name = $rc, '$out')")
    fi
  done <<<"$names"

  if (( ${#offenders[@]} > 0 )); then
    echo "containers on ai-stack network that fail DNS resolution from a probe:"
    printf '  - %s\n' "${offenders[@]}"
    return 1
  fi
}

container_dns_in_network_fix() {
  warn "Cannot auto-fix in-network DNS — Docker manages its own resolver."
  warn "Steps to try (in order):"
  warn "  1. Check Docker daemon: docker info | grep -i dns"
  warn "  2. Restart OrbStack: orb restart"
  warn "  3. Remove + recreate ai-stack network:"
  warn "     bash vz-ai-stack.sh reset --confirm hard (preserves data)"
  return 1
}
