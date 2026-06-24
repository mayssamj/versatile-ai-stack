# For every managed container that has a 127.0.10.x publish, dial its alias
# from the host and assert TCP+HTTP both succeed. Catches the Phase 01 class
# of bug at install time AND ongoing — if a launchd reboot fails to re-bind
# lo0 aliases, this check fires on the next `vz-ai-stack.sh doctor` run.
CHECKS+=(container_alias_routable)
CHECK_TITLE[container_alias_routable]="Every managed container is reachable via its 127.0.10.x alias"

container_alias_routable_diagnose() {
  # shellcheck source=../../lib/network.sh
  source "$AI_STACK/installer/lib/network.sh"
  # shellcheck source=../../lib/verify.sh
  source "$AI_STACK/installer/lib/verify.sh"
  aliases_load || { echo "could not load aliases.tsv"; return 1; }

  docker info >/dev/null 2>&1 || { echo "docker daemon not reachable"; return 1; }

  local offenders=() name alias svc_key port path
  # Iterate aliases.tsv — for each row, find a managed container whose
  # service_key matches and probe its alias. Skip aliases for services that
  # aren't currently running (those would be a different check).
  declare _a
  for _a in "${ALIASES_LIST[@]}"; do
    alias="$_a"
    svc_key="${ALIAS_SERVICE_KEY[$_a]}"
    # Probe the HOST-side published port: verify_container_reachable_by_alias dials
    # http://$alias:$port FROM THE HOST, so $port must be the host_port (the alias IP
    # listens there). For most services host_port==container_port, but where they differ
    # (chatdev 5274->5173, aitown 5273->5173) the container_port has NO host listener → a
    # false 000. (Verified live 2026-06-24: chatdev:5274->403 reached, chatdev:5173->000.)
    port="${ALIAS_HOST_PORT[$_a]}"
    # Find a running container with this service-key as its name (most
    # common case) OR as its compose service.
    name=""
    if docker ps --format '{{.Names}}' | grep -qx "$svc_key"; then
      name="$svc_key"
    elif docker ps --format '{{.Names}}' | grep -qx "${svc_key}-1"; then
      name="${svc_key}-1"
    elif docker ps --format '{{.Names}}' | grep -qx "${svc_key}-api"; then
      name="${svc_key}-api"
    elif docker ps --format '{{.Names}}' | grep -qx "${svc_key}-api-1"; then
      name="${svc_key}-api-1"
    fi
    # SCOPE LIMIT (§24 council 2026-06-24): the name-guessing above matches docker-run names
    # and a couple of compose suffixes (-1/-api/-api-1), but NOT arbitrary compose member names
    # like aitown-frontend-1. Such compose services are intentionally skipped here and covered by
    # their own phase check (e.g. aitown → check 61). Empty $name also = service-not-running.
    [[ -z "$name" ]] && continue

    # Determine a sensible probe path. Most ai-stack services support /health;
    # the rest accept "/" and return something HTTP-ish.
    case "$svc_key" in
      litellm|honcho|phoenix|qdrant|openwebui|hermes_workspace|hermes_fleet|llm_guard)
        path="/health"
        ;;
      *)
        path="/"
        ;;
    esac

    # Skip non-http protocols here; the alias_resolution check (#17) covers
    # redis + grpc cases with protocol-aware probes.
    [[ "${ALIAS_PROTOCOL[$_a]}" == "http" ]] || continue

    # A service that is still warming up right after `install all` can return
    # 5xx (e.g. 503) or transiently fail to connect. verify_container_reachable_
    # by_alias already treats 2xx/3xx/4xx as "reached an HTTP server"; give a
    # not-yet-ready container one short retry before flagging it, so a starting
    # service isn't false-red. Genuinely-unreachable (persistent 000/5xx) still
    # fails after the retry.
    if ! verify_container_reachable_by_alias "$name" "$alias" "$port" "$path" 2>/dev/null; then
      sleep 2
      if ! verify_container_reachable_by_alias "$name" "$alias" "$port" "$path" 2>/dev/null; then
        offenders+=("$alias -> $name (port $port path $path)")
      fi
    fi
  done

  if (( ${#offenders[@]} > 0 )); then
    echo "containers not reachable via their 127.0.10.x alias:"
    printf '  - %s\n' "${offenders[@]}"
    echo "(this almost always means lo0 aliases regressed; run vz-ai-stack.sh prepare-sudo)"
    return 1
  fi
}

container_alias_routable_fix() {
  warn "Most common cause: lo0 aliases not bound after reboot."
  warn "Run:  sudo bash $AI_STACK/vz-ai-stack.sh prepare-sudo"
  warn "(idempotent; re-binds 127.0.10.x and re-installs reboot persistence)"
  return 1
}
