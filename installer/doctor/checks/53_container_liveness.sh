# Census-level liveness guard: every stack container that EXISTS must be running
# and healthy. This is the ONE check that fails when a container exists but is
# broken (crash-looping / dead / unhealthy) — the structural gap that let
# autofyn-agent crash-loop and llm_guard die for hours while doctor reported "all
# green" (52/53). It is a distinct axis from check 12 (ownership: foreign/adopt)
# and check 16 (connectivity: on the ai-stack network) — do not merge them.
#
# WHY this is needed even though every feature ships its own check:
#   Per-feature checks are a curated allowlist, not a census. A service nobody
#   wrote a check for (or one whose check probes config, not liveness) dies
#   invisibly. This check enumerates REALITY (every owned container) and asserts
#   the negative invariant (none broken), so new services are covered for free.
#
# CENSUS (which containers count as "ours") — union of signals, because no single
# signal covers the fleet (the ai-stack.managed label alone is only the docker-type
# services, ~7/22):
#   1. label ai-stack.managed=true        (docker-type: litellm, phoenix, ...)
#   2. attached to the 'ai-stack' network (honcho-api/deriver, ...)
#   3. com.docker.compose.project in the stack set (compose members that carry
#      NEITHER the label NOR the network — e.g. autofyn-agent, and notably
#      honcho-database-1/redis-1 which ONLY signal 3 catches).
# The compose-project set is DERIVED from services.yml at runtime (type: compose /
# docker-compose -> project: or basename of path:) UNIONED with a hardcoded
# known-good fallback, so a new compose stack is covered automatically and a
# services.yml parse error can only ADD-nothing, never shrink the census.
# openshell-* sandboxes are EXCLUDED: their lifecycle is owned by checks 24/39/43
# and an intentional watchdog HALT is data-safe, not a failure (fleet durability).
#
# SCOPE / known limit (stated, not silently capped): this catches containers that
# EXIST but are broken. It does NOT yet assert a full expected-set (a service that
# was never started at all, so it has no `docker ps -a` row). That needs a
# per-service installed-state model and is a follow-up. Today's failure class was
# "exists but broken", which this closes.

# Hardcoded known-good compose projects (fallback floor; union'd with the
# services.yml-derived set below). Namespaced to avoid collisions with other checks.
_53_STACK_PROJECTS_FALLBACK="honcho autofyn deer-flow hermes-workspace aitown"

CHECKS+=(container_liveness)
CHECK_TITLE[container_liveness]="Every stack container that EXISTS is running & healthy (no crash-loop / dead / unhealthy)"

# Derive the stack compose-project set: services.yml (single source of truth) ∪
# the hardcoded floor. Union means a bad/empty derivation never drops a known stack.
#
# F16: when the yq derivation fails or returns nothing, emit a diagnostic WARN
# (to stderr, so it surfaces in the check output) rather than silently falling
# back to the hardcoded floor. The floor is still the safety net (the check
# never hard-fails due to a missing yq), but the operator learns the derivation
# is broken so they can fix it — previously this was silent.
_53_stack_projects() {
  local derived="" _yq_ok=1
  if command -v yq >/dev/null 2>&1 && [[ -f "${AI_STACK:-}/services.yml" ]]; then
    derived="$(yq -r '
      .services | to_entries[]
      | select(.value.type == "compose" or .value.type == "docker-compose")
      | (.value.project // (.value.path | split("/") | .[-1]))
    ' "$AI_STACK/services.yml" 2>/dev/null | tr "\n" " ")" || _yq_ok=0
    if [[ "$_yq_ok" == "0" || -z "${derived// }" ]]; then
      # Emit to stderr so it appears in the check's diagnose output block.
      echo "  (advisory) check 53: could not derive compose-project set from services.yml (yq error or empty result) — census uses hardcoded fallback floor only; add new compose stacks to _53_STACK_PROJECTS_FALLBACK if they are not in services.yml" >&2
    fi
  elif ! command -v yq >/dev/null 2>&1; then
    echo "  (advisory) check 53: yq not on PATH — compose-project census uses hardcoded fallback floor only" >&2
  elif [[ ! -f "${AI_STACK:-}/services.yml" ]]; then
    echo "  (advisory) check 53: services.yml not found at $AI_STACK/services.yml — compose-project census uses hardcoded fallback floor only" >&2
  fi
  # Dedup the union into a single space-separated list.
  printf '%s\n' $_53_STACK_PROJECTS_FALLBACK $derived | awk 'NF && !seen[$0]++' | tr "\n" " "
}

container_liveness_diagnose() {
  # Bail early if docker isn't up — check 01 fires its own dedicated error.
  docker info >/dev/null 2>&1 || { echo "docker daemon not reachable"; return 1; }

  local projects; projects="$(_53_stack_projects)"
  local broken=() name owned nets proj p
  local status restarting exitcode health
  while IFS= read -r name; do
    [[ -z "$name" ]] && continue
    case "$name" in openshell-*) continue ;; esac   # owned by checks 24/39/43

    # --- stack-owned? (err toward inclusion: a false negative here = the orig bug) ---
    owned=no
    [[ "$(docker inspect "$name" --format '{{index .Config.Labels "ai-stack.managed"}}' 2>/dev/null || true)" == "true" ]] && owned=yes
    if [[ "$owned" == no ]]; then
      nets="$(docker inspect "$name" --format '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}' 2>/dev/null || true)"
      grep -qw "ai-stack" <<<"$nets" && owned=yes
    fi
    if [[ "$owned" == no ]]; then
      proj="$(docker inspect "$name" --format '{{index .Config.Labels "com.docker.compose.project"}}' 2>/dev/null || true)"
      if [[ -n "$proj" ]]; then
        for p in $projects; do [[ "$p" == "$proj" ]] && { owned=yes; break; }; done
      fi
    fi
    [[ "$owned" == no ]] && continue

    # --- broken? read state in one inspect. Guard the read: if the container
    # vanished between the `docker ps -a` enumeration and now (TOCTOU during a
    # recreate), inspect yields nothing, read hits EOF -> non-zero. Under doctor's
    # inherit_errexit that would ABORT the check (a false RED). `|| true` + empty
    # sentinels make a vanished container fall through as "gone, not broken".
    status=""; restarting=""; exitcode=""; health=""
    read -r status restarting exitcode health < <(docker inspect "$name" \
      --format '{{.State.Status}} {{.State.Restarting}} {{.State.ExitCode}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' 2>/dev/null) || true
    if [[ "$restarting" == "true" || "$status" == "restarting" ]]; then
      broken+=("$name: crash-looping (status=restarting)")
    elif [[ "$status" == "exited" || "$status" == "dead" ]]; then
      broken+=("$name: $status (exit=$exitcode)")
    elif [[ "$health" == "unhealthy" ]]; then
      broken+=("$name: unhealthy (healthcheck failing)")
    fi
  done < <(docker ps -a --format '{{.Names}}')

  if (( ${#broken[@]} > 0 )); then
    echo "stack containers not running cleanly:"
    printf '    %s\n' "${broken[@]}"
    echo "  (covers containers that EXIST but are broken — the gap that let"
    echo "   autofyn-agent crash-loop and llm_guard die while doctor stayed green)"
    return 1
  fi
}

container_liveness_fix() {
  # Conservative: do NOT auto-restart. A crash-loop almost always needs a real
  # fix (today: a bind-mounted source drifted behind its image) — auto-restarting
  # would just mask it and re-hide the failure, which is the whole problem.
  warn "Per broken container (use 'docker ps -a' — an OOM-killed container EXITS"
  warn "and disappears from plain 'docker ps', which is how this hid for hours):"
  warn "  docker logs <name> --tail 50        # see why it died"
  warn "  docker restart <name>               # if it was a transient/OOM kill"
  warn "If a bind-mounted source drifted from its image (e.g. autofyn /workspace),"
  warn "bring that checkout up to date to match the image, then restart."
  return 1
}
