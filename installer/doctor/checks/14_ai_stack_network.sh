# ai-stack docker network exists and is bridge-driver.
CHECKS+=(ai_stack_network)
CHECK_TITLE[ai_stack_network]="Docker network 'ai-stack' exists (bridge driver)"

ai_stack_network_diagnose() {
  if ! docker network inspect ai-stack >/dev/null 2>&1; then
    echo "docker network 'ai-stack' does not exist"
    return 1
  fi
  local driver
  driver="$(docker network inspect ai-stack --format '{{.Driver}}' 2>/dev/null || true)"
  if [[ "$driver" != "bridge" ]]; then
    echo "ai-stack network exists but driver='$driver' (expected bridge)"
    return 1
  fi
}

ai_stack_network_fix() {
  # network.sh is the canonical helper; source it on demand so this check
  # works without forcing doctor.sh to source network.sh globally.
  # shellcheck source=../../lib/network.sh
  source "$AI_STACK/installer/lib/network.sh"
  network_ensure_ai_stack
}
