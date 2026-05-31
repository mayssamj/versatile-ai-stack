# No container name appears in two different docker networks with the same
# name but different identities — would make bare-name DNS lookups ambiguous
# (D28). The classic risk is honcho-api on [default, ai-stack] colliding with
# a top-level `api` container on another network.
CHECKS+=(dns_collision_guard)
CHECK_TITLE[dns_collision_guard]="No cross-network container-name collisions"

dns_collision_guard_diagnose() {
  docker info >/dev/null 2>&1 || { echo "docker daemon not reachable"; return 1; }

  # Build a list of `network<TAB>container-name` lines across all networks.
  local tmp
  tmp="$(mktemp)" || { echo "mktemp failed"; return 1; }
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  local net
  while IFS= read -r net; do
    [[ -z "$net" ]] && continue
    # Each container in this network — we want their NAME field (the docker
    # name, which is what other containers see in bare-name DNS lookups).
    while IFS= read -r cname; do
      [[ -z "$cname" ]] && continue
      printf '%s\t%s\n' "$cname" "$net" >> "$tmp"
    done < <(docker network inspect "$net" --format '{{range $k,$v := .Containers}}{{$v.Name}}{{"\n"}}{{end}}' 2>/dev/null)
  done < <(docker network ls --format '{{.Name}}')

  # Group by container name; any name appearing on ≥2 networks is a potential
  # collision. We don't auto-flag honcho-api on [default, ai-stack] as a
  # problem — that's by design (D28). We DO flag when 2 DIFFERENT containers
  # share a name across networks (which docker shouldn't allow, but custom
  # composes can create surprises with --network-alias).
  local dupes
  dupes="$(awk -F'\t' '
    { count[$1]++; nets[$1] = nets[$1] " " $2 }
    END {
      for (n in count) if (count[n] > 1) printf "%s:%s\n", n, nets[n]
    }
  ' "$tmp")"

  if [[ -n "$dupes" ]]; then
    # Filter expected multi-network containers (today: only honcho-api). The
    # honcho compose intentionally joins both default and ai-stack.
    local real_dupes
    real_dupes="$(printf '%s\n' "$dupes" | awk -F: '
      {
        name=$1
        # Strip the leading "/" that docker prepends to container names.
        sub(/^\//, "", name)
        # Match both compose v1 (honcho-api) and v2 (honcho-api-1, honcho-api-2)
        # forms. Also tolerate the `honcho_api_1` underscore form some older
        # compose versions emit.
        if (name ~ /^honcho-(api|deriver)(-[0-9]+)?$/) next
        if (name ~ /^honcho_(api|deriver)(_[0-9]+)?$/) next
        print
      }
    ')"
    if [[ -n "$real_dupes" ]]; then
      echo "container-name collisions across networks:"
      printf '%s\n' "$real_dupes" | sed 's/^/  /'
      return 1
    fi
  fi
}

dns_collision_guard_fix() {
  warn "Cannot auto-fix DNS collisions — they require renaming a container"
  warn "or changing which networks it joins."
  warn "Identify the offender above, then either:"
  warn "  - docker rename <old> <new>      (if you own the container)"
  warn "  - edit the foreign compose to use a unique container_name"
  return 1
}
