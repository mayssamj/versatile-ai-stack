# DeerFlow (Phase 10): config.yaml has at least one uncommented model entry
# AND docker-compose.yaml surfaces LITELLM_MASTER_KEY to the gateway.
#
# Failure mode (2026-05-29): when DeerFlow is seeded from the upstream
# config.example.yaml without injection, the `models:` block contains only
# commented examples → Pydantic's `list[ModelConfig]` validator crash-loops
# 4 uvicorn workers on every restart, burning ~340% CPU continuously even
# while idle. This check catches the misconfig at-rest so the operator
# notices before starting the service.
#
# Conditional: only meaningful when deer-flow/ exists (Phase 10 was selected).
CHECKS+=(deerflow_config)
CHECK_TITLE[deerflow_config]="DeerFlow config.yaml has model entries + compose passes LITELLM_MASTER_KEY (Phase 10)"

deerflow_config_diagnose() {
  local df_dir="$AI_STACK/deer-flow"
  local df_config="$df_dir/config.yaml"
  local df_compose="$df_dir/docker/docker-compose.yaml"

  # Skip cleanly if Phase 10 wasn't installed.
  if [[ ! -d "$df_dir" ]]; then
    echo "deer-flow/ not present — Phase 10 not installed (skipping)"
    return 0
  fi

  if [[ ! -f "$df_config" ]]; then
    echo "missing $df_config — Phase 10 did not seed config.yaml"
    return 1
  fi

  # The `models:` block must contain at least one uncommented `- name: …`
  # entry between `^models:$` and the next top-level key.
  if ! awk '
    /^models:[[:space:]]*$/ { in_models=1; next }
    in_models && /^[^[:space:]#]/ { in_models=0 }
    in_models && /^[[:space:]]*-[[:space:]]*name:[[:space:]]/ { found=1; exit }
    END { exit found ? 0 : 1 }
  ' "$df_config"; then
    echo "config.yaml has no uncommented model entries — 4 workers will crash-loop on Pydantic validation (~340% CPU)"
    return 1
  fi

  if [[ ! -f "$df_compose" ]]; then
    echo "missing $df_compose"
    return 1
  fi
  if ! grep -q 'LITELLM_MASTER_KEY=\${LITELLM_MASTER_KEY}' "$df_compose"; then
    echo "docker-compose.yaml does not surface LITELLM_MASTER_KEY to gateway — \$LITELLM_MASTER_KEY in config.yaml will not resolve"
    return 1
  fi
}

deerflow_config_fix() {
  warn "Re-run Phase 10 (idempotent — patches config.yaml + compose + .env):"
  warn "    bash $AI_STACK/vz-ai-stack.sh install 10"
  return 1
}
