# Per-alias protocol-aware reachability probe (D10 revised).
# - http : curl with a healthcheck path (best-effort; uses /health or /)
# - redis: redis-cli PING (skipped if redis-cli not installed)
# - grpc : nc -z (TCP connect only)
# Foreign containers (cross-referenced via check 12) downgrade FAIL → WARN
# during the transition window (D10/D24).
CHECKS+=(alias_resolution)
CHECK_TITLE[alias_resolution]="Aliases reachable end-to-end (HTTP/redis/grpc probes)"

# Map service_key → health URL path. Most services either expose /health or
# nothing (in which case we accept any 2xx/3xx response).
_alias_health_path() {
  case "$1" in
    litellm|honcho|phoenix|qdrant|openwebui|hermes_workspace|hermes_fleet|llm_guard) echo "/health" ;;
    autofyn|paperclip|docs_mcp|falkordb) echo "/" ;;
    *) echo "/" ;;
  esac
}

# Is the owner of this alias actually up? We only want to PROBE aliases whose
# owning service is running — an optional service that's legitimately stopped
# would otherwise connection-refuse (→ 000) and false-fail (mirrors check 20,
# which `continue`s when no matching container is running).
#   - docker services: container_running <service_key> (and the common name
#     variants used elsewhere: <svc>, <svc>-1, <svc>-api, <svc>-api-1).
#   - host daemons (services.yml network: host — docs_mcp/paperclip/unsloth/
#     claw3d): no container, so fall back to "is something LISTENING on the
#     alias IP:host_port?" via lsof.
_alias_owner_up() {
  local svc_key="$1" ip="$2" host_port="$3" n
  for n in "$svc_key" "${svc_key}-1" "${svc_key}-api" "${svc_key}-api-1"; do
    if container_running "$n" 2>/dev/null; then return 0; fi
  done
  # Host-daemon fallback: a listener on the alias IP:port means the owner is up.
  if [[ -n "$ip" && -n "$host_port" ]] \
    && lsof -nP -iTCP@"$ip":"$host_port" -sTCP:LISTEN >/dev/null 2>&1; then
    return 0
  fi
  return 1
}

_alias_probe_one() {
  local alias="$1" proto="$2" host_port="$3" svc_key="$4"
  local rc=0
  case "$proto" in
    http)
      local path code
      path="$(_alias_health_path "$svc_key")"
      # host_port=80 means we dial bare http://alias/path; other host_ports
      # need the explicit port.
      local url
      if [[ "$host_port" == "80" ]]; then
        url="http://$alias$path"
      else
        url="http://$alias:$host_port$path"
      fi
      code="$(curl -s -o /dev/null --max-time 2 -w '%{http_code}' "$url" 2>/dev/null || echo "000")"
      # 2xx / 3xx / even 4xx (which means we reached an HTTP server) all count;
      # 000/5xx/connection refused does not.
      case "$code" in
        2??|3??|401|403|404) rc=0 ;;
        *) rc=1; echo "  $alias ($url): HTTP $code" ;;
      esac
      ;;
    redis)
      if ! command -v redis-cli >/dev/null 2>&1; then
        # No redis-cli — fall through to a TCP connect; if it succeeds, we
        # haven't proven PING, but we've shown the alias is wired up.
        if nc -z -w 2 "$alias" "$host_port" 2>/dev/null; then
          rc=0
        else
          rc=1
          echo "  $alias:$host_port (redis): connect failed (and redis-cli not installed)"
        fi
      else
        local pong
        pong="$(redis-cli -h "$alias" -p "$host_port" --no-raw PING 2>/dev/null || true)"
        if [[ "$pong" == *PONG* ]]; then
          rc=0
        else
          rc=1
          echo "  $alias:$host_port (redis): no PONG"
        fi
      fi
      ;;
    grpc)
      if nc -z -w 2 "$alias" "$host_port" 2>/dev/null; then
        rc=0
      else
        rc=1
        echo "  $alias:$host_port (grpc): TCP connect failed"
      fi
      ;;
    *)
      # Unknown protocol — TCP connect as a fallback.
      if nc -z -w 2 "$alias" "$host_port" 2>/dev/null; then
        rc=0
      else
        rc=1
        echo "  $alias:$host_port ($proto): TCP connect failed"
      fi
      ;;
  esac
  return $rc
}

alias_resolution_diagnose() {
  # shellcheck source=../../lib/network.sh
  source "$AI_STACK/installer/lib/network.sh"
  aliases_load || { echo "could not load aliases.tsv"; return 1; }

  # Cross-reference: do we have any foreign containers? If yes, degrade to WARN.
  # (We do NOT depend on check 12 having run; we replicate the criterion.)
  local foreigns=() svc
  for svc in litellm phoenix falkordb qdrant openwebui llm_guard honcho; do
    if container_exists "$svc" 2>/dev/null && ! container_managed "$svc" 2>/dev/null; then
      foreigns+=("$svc")
    fi
  done

  local fails=() a proto hp ip svc_key
  for a in "${ALIASES_LIST[@]}"; do
    proto="${ALIAS_PROTOCOL[$a]}"
    hp="${ALIAS_HOST_PORT[$a]}"
    ip="${ALIAS_IP[$a]}"
    svc_key="${ALIAS_SERVICE_KEY[$a]}"
    # Only probe aliases whose owning service is up — a stopped optional service
    # would connection-refuse and false-fail.
    _alias_owner_up "$svc_key" "$ip" "$hp" || continue
    if ! out="$(_alias_probe_one "$a" "$proto" "$hp" "$svc_key" 2>&1)"; then
      fails+=("$out")
    fi
  done

  if (( ${#fails[@]} > 0 )); then
    if (( ${#foreigns[@]} > 0 )); then
      # Transition WARN: some pre-existing containers are still foreign, so
      # those aliases will be connection-refused. Print as a warning but
      # return 0 so doctor counts this as PASS.
      printf '  (foreign containers detected: %s — degrading to WARN)\n' "${foreigns[*]}"
      printf '%s\n' "${fails[@]}"
      printf '  Adopt them with: install.sh adopt <svc>\n'
      return 0
    fi
    printf '%s\n' "${fails[@]}"
    return 1
  fi
}

alias_resolution_fix() {
  warn "If aliases don't resolve, check that:"
  warn "  1. /etc/hosts has the managed block (doctor check 15)"
  warn "  2. The owning container is up and joined to ai-stack (check 16)"
  warn "  3. For foreign containers, run: install.sh adopt <svc>"
  return 1
}
