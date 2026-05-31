# host.docker.internal resolves from inside containers.
CHECKS+=(host_docker_internal)
CHECK_TITLE[host_docker_internal]="host.docker.internal resolves inside containers"

host_docker_internal_diagnose() {
  docker run --rm alpine getent hosts host.docker.internal >/dev/null 2>&1 \
    || { echo "host.docker.internal does not resolve"; return 1; }
}

host_docker_internal_fix() {
  err "Cannot auto-fix this — OrbStack networking configuration issue."
  err "Check OrbStack Settings → Network → enable host networking."
  return 1
}
