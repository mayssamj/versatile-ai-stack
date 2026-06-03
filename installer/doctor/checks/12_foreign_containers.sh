# Containers we expect to manage are running but either unlabeled (foreign)
# or labeled-but-not-on-ai-stack (post-refactor mismatch).
#
# A container is foreign if EITHER:
#   - it lacks ai-stack.managed=true (classic foreign), OR
#   - it has the label but lacks `ai-stack` in its docker network list
#     (label-but-not-on-network — e.g., ran via an older start script).
CHECKS+=(foreign_containers)
CHECK_TITLE[foreign_containers]="No foreign ai-stack containers (run 'vz-ai-stack.sh adopt <svc>')"

foreign_containers_diagnose() {
  local foreigns=() svc reasons=()
  for svc in litellm phoenix falkordb qdrant openwebui llm_guard honcho; do
    container_exists "$svc" || continue
    if ! container_managed "$svc"; then
      foreigns+=("$svc")
      reasons+=("$svc: no ai-stack.managed label")
      continue
    fi
    # Container is labeled-managed — but is it on the ai-stack network?
    local nets
    nets="$(docker inspect "$svc" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || true)"
    if ! grep -qw "ai-stack" <<<"$nets"; then
      foreigns+=("$svc")
      reasons+=("$svc: labeled-managed but not on ai-stack network (current: ${nets:-<none>})")
    fi
  done
  if (( ${#foreigns[@]} > 0 )); then
    printf '  foreign containers: %s\n' "${foreigns[*]}"
    printf '    %s\n' "${reasons[@]}"
    return 1
  fi
}

foreign_containers_fix() {
  warn "Run 'vz-ai-stack.sh adopt <svc>' per foreign container — adoption is interactive"
  warn "and will offer to back up data before recreating with managed config."
  warn "Adopted containers will be (re)attached to the 'ai-stack' network."
  return 1
}
