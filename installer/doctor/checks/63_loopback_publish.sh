# No container publishes a port on 0.0.0.0 / [::] (all-interfaces LAN exposure).
#
# The routine-doctor version of bin/audit.sh check 1: stack policy is loopback-only
# publishes (127.0.0.1 or a 127.0.10.x alias). A container that publishes 0.0.0.0:PORT
# is reachable from the LAN. This catches upstream-compose drift (e.g. a re-cloned
# gitignored compose that re-publishes 0.0.0.0) AFTER the fact, on every doctor run —
# audit.sh only runs on demand. Splits each container's port list on "," so a 0.0.0.0
# mapping co-located with a 127.x one on the same line can't hide. Skip-clean when the
# docker engine isn't reachable. Loopback-only; makes no external calls.
CHECKS+=(loopback_publish)
CHECK_TITLE[loopback_publish]="containers publish loopback-only (no 0.0.0.0/[::]/host-IP)"

loopback_publish_diagnose() {
  docker info >/dev/null 2>&1 || { echo "docker engine not reachable — cannot census published ports. [skip]"; return 0; }
  local bad
  bad="$(docker ps --format "{{.Names}} {{.Ports}}" \
    | tr "," "\n" \
    | grep -E "[0-9]+->" \
    | grep -vE "127\.[0-9]|::1\]" \
    | grep ":" || true)"
  if [[ -n "$bad" ]]; then
    printf "container(s) publishing on a non-loopback interface — any non-127.x/::1 bind (0.0.0.0/[::]/host-IP) is LAN-reachable:\n%s\n" "$bad"
    return 1
  fi
  echo "  (all published container ports bind 127.0.0.1 / 127.0.10.x — no 0.0.0.0 exposure)"
  return 0
}

loopback_publish_fix() {
  warn "A container publishes on a non-loopback interface (0.0.0.0/[::]/host-IP — LAN-exposed). Bind it loopback-only —"
  warn "  127.0.0.1 + its 127.0.10.x alias (the litellm/deerflow/autofyn dual-bind pattern) —"
  warn "  by patching its start script / compose, then recreate the container."
  return 1
}
