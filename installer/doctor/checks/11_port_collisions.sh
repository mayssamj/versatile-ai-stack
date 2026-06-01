# No non-docker process is camping on our (IP, port) pairs.
# Post-refactor: services bind to 127.0.10.X:<port>, so two different services
# both listening on host port 80 (different 127.0.10.X) is FINE — we filter
# by IP+port pair, not by bare port.
CHECKS+=(port_collisions)
CHECK_TITLE[port_collisions]="No non-docker process on ai-stack (IP, port) pairs"

port_collisions_diagnose() {
  # shellcheck source=../../lib/network.sh
  source "$AI_STACK/installer/lib/network.sh"
  aliases_load || { echo "could not load aliases.tsv"; return 1; }

  local clashes=() owner ip port a hp
  # ollama lives on the host directly — not in aliases.tsv but always checked.
  local extra_pairs=("127.0.0.1:11434")
  # Build the pair list from aliases.tsv (host-side IPs).
  local pairs=()
  for a in "${ALIASES_LIST[@]}"; do
    pairs+=("${ALIAS_IP[$a]}:${ALIAS_HOST_PORT[$a]}")
  done
  pairs+=("${extra_pairs[@]}")

  local pair owner_pid owner_cmd
  for pair in "${pairs[@]}"; do
    ip="${pair%:*}"
    port="${pair##*:}"
    # lsof can filter by IP and port together: -iTCP@IP:PORT -sTCP:LISTEN.
    owner="$(lsof -nP -iTCP@"$ip":"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1}')"
    [[ -z "$owner" ]] && continue
    # Standard docker/orbstack/ollama owners — always OK.
    case "$owner" in
      OrbStack|com.docker.backend|com.docke|Docker|vpnkit|ollama) continue ;;
    esac
    # Managed host-side helpers we deliberately run as plain processes
    # (services.yml: network=host, type python-bg/node-bg). These legitimately
    # listen on their 127.0.10.x alias, so they are NOT foreign collisions.
    # Identify by the command-line tag we set in their argv:
    #   paperclip-relay      → 127.0.10.14:3100 forwarder (start-paperclip.sh)
    #   mcp_server.py        → docs_mcp on 127.0.10.4:8765 (start-docs_mcp.sh)
    #   unsloth … studio     → unsloth on 127.0.10.16:8898 (start-unsloth.sh)
    #   …/server/index.js    → claw3d on 127.0.10.17:4310 (start-claw3d.sh)
    owner_pid="$(lsof -nP -iTCP@"$ip":"$port" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $2}')"
    owner_cmd="$(ps -p "$owner_pid" -o args= 2>/dev/null)"
    case "$owner_cmd" in
      *paperclip-relay*|*mcp_server.py*|*unsloth*studio*|*unsloth*serve*|*server/index.js*) continue ;;
    esac
    clashes+=("$ip:$port held by $owner")
  done

  if (( ${#clashes[@]} > 0 )); then
    printf '  %s\n' "${clashes[@]}"
    return 1
  fi
}

port_collisions_fix() {
  err "Cannot auto-fix — kill the offending process or change service port mappings."
  return 1
}
