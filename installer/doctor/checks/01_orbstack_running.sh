# OrbStack / Docker daemon reachable.
CHECKS+=(orbstack_running)
CHECK_TITLE[orbstack_running]="OrbStack / Docker daemon reachable"

orbstack_running_diagnose() {
  docker info >/dev/null 2>&1 || { echo "docker info failed; daemon not running"; return 1; }
}

orbstack_running_fix() {
  warn "Launching OrbStack..."
  open -a OrbStack
  local i=0
  until docker info >/dev/null 2>&1; do
    sleep 1
    (( ++i > 60 )) && { err "OrbStack did not start within 60s"; return 1; }
  done
  ok "OrbStack up"
}
