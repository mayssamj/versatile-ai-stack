# bootstrap.sh — one-shot remediation steps run automatically at the end of
# `bash vz-ai-stack.sh` (no args) so the user doesn't have to chain subcommands.
#
# Conservative-mode contract is preserved: every destructive action prompts
# Y/n before running. Default answers favor "do the right thing." You can
# decline any step and pick it up later via the matching subcommand.
#
# Sourced by vz-ai-stack.sh after all phases complete. Must not source anything
# else — common.sh, env.sh, docker.sh, prompt.sh, adopt are already loaded.

[[ -z "${AI_STACK:-}" ]] && { echo "bootstrap.sh: AI_STACK unset" >&2; exit 2; }

# Services the installer knows how to adopt (must have bin/start-<svc>.sh
# AND a matching adopt path in lib/adopt.sh).
ADOPTABLE_SERVICES=(litellm phoenix falkordb qdrant openwebui llm_guard)

# ──────────────────────────────────────────────────────────────────────────
# Step A — adopt any foreign containers, inline.
# ──────────────────────────────────────────────────────────────────────────
bootstrap_adopt_foreigns() {
  local foreigns=() svc
  for svc in "${ADOPTABLE_SERVICES[@]}"; do
    if container_exists "$svc" && ! container_managed "$svc"; then
      foreigns+=("$svc")
    fi
  done
  if (( ${#foreigns[@]} == 0 )); then
    return 0
  fi
  hdr "Foreign containers detected"
  echo "The following containers exist but were started outside this installer."
  echo "They still use the old 127.0.0.1 networking and won't respond on the new"
  echo "aliases (http://litellm:4000, http://phoenix:6006, etc.) until adopted."
  echo
  printf '  - %s\n' "${foreigns[@]}"
  echo
  echo "Adoption flow per container:  docker cp backup → docker rm -f → recreate"
  echo "                              on the ai-stack network."
  echo
  local svc
  for svc in "${foreigns[@]}"; do
    if confirm "Adopt '$svc' now?" Y; then
      bash "$AI_STACK/installer/lib/adopt.sh" "$svc" || warn "adopt $svc returned non-zero; continuing."
    else
      warn "Skipped: $svc remains on old networking. Run 'vz-ai-stack.sh adopt $svc' when ready."
    fi
  done
}

# ──────────────────────────────────────────────────────────────────────────
# Step B — recreate honcho on ai-stack if it's running but unmigrated.
# Honcho is compose-managed so the membership check is per-container.
# ──────────────────────────────────────────────────────────────────────────
bootstrap_recreate_honcho_if_drifted() {
  # Is the honcho api container running?
  local api_name
  api_name="$(docker ps --format '{{.Names}}' | grep -E '^honcho-api-1?$' | head -1 || true)"
  [[ -z "$api_name" ]] && return 0   # honcho not up; nothing to drift
  # Already on ai-stack?
  if docker inspect "$api_name" --format '{{json .NetworkSettings.Networks}}' 2>/dev/null \
       | grep -q '"ai-stack"'; then
    return 0   # already migrated
  fi
  hdr "Honcho compose stack needs recreation"
  echo "honcho-api is running but NOT on the ai-stack network. The override"
  echo "file was updated to attach api + deriver to ai-stack and publish on"
  echo "127.0.10.6:80 — to pick that up, honcho must be brought down + up."
  echo
  if confirm "Recreate honcho stack now (compose down/up)?" Y; then
    (cd "$AI_STACK/honcho" && docker compose down 2>&1 | tail -5)
    bash "$AI_STACK/installer/phases/03_honcho.sh" || warn "Phase 03 returned non-zero; continuing."
  else
    warn "Skipped. Run 'vz-ai-stack.sh install 03' to migrate honcho when ready."
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# Step C — Phoenix API key prompt.
# Phoenix doesn't expose API key creation over its REST API, so this is a
# human-in-the-loop step. The installer pauses, gives instructions, and
# accepts the pasted key.
# ──────────────────────────────────────────────────────────────────────────
bootstrap_phoenix_api_key() {
  container_running phoenix || return 0
  # Auth on? — /v1/projects returns 401 if yes.
  local status
  status="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://phoenix:6006/v1/projects 2>/dev/null || echo 000)"
  [[ "$status" == "401" ]] || return 0   # auth off, or alias not yet wired
  local key; key="$(get_env PHOENIX_API_KEY "")"
  [[ -n "$key" ]] && return 0   # already set

  hdr "Phoenix needs an API key for trace ingestion"
  cat <<EOF
Phoenix is running with auth ON. LiteLLM's OTLP exporter is currently being
rejected (401) on every trace push. To complete observability setup:

  1. open http://phoenix:6006
  2. log in as: admin@localhost / your-password
  3. Settings → API Keys → Create new key
  4. copy the key

Then paste the key below (input is hidden). Leave blank to defer.

EOF
  local pasted
  pasted="$(secret_input "PHOENIX_API_KEY:")"
  if [[ -z "$pasted" ]]; then
    warn "Skipped. Add PHOENIX_API_KEY=<key> to .env later, then run 'vz-ai-stack.sh apply-restarts'."
    return 0
  fi
  set_env PHOENIX_API_KEY "$pasted"
  ok "PHOENIX_API_KEY written to .env"
  queue_restart litellm   # litellm needs to pick it up
}

# ──────────────────────────────────────────────────────────────────────────
# Step D — drain restart queue.
# ──────────────────────────────────────────────────────────────────────────
bootstrap_drain_restarts() {
  local f="$AI_STACK/installer/state/restarts-needed.txt"
  [[ -s "$f" ]] || return 0
  hdr "Queued restarts pending"
  echo "Services that need recreate to pick up new env-var values:"
  sed 's/^/  - /' "$f"
  echo
  if confirm "Apply restarts now?" Y; then
    # Snapshot the queue for downstream-coupling logic below.
    local litellm_was_queued=0
    if grep -qx litellm "$f" 2>/dev/null; then litellm_was_queued=1; fi

    local svc
    while IFS= read -r svc; do
      [[ -z "$svc" || "$svc" == \#* ]] && continue
      bash "$AI_STACK/bin/start-${svc}.sh" --recreate || warn "restart $svc returned non-zero; continuing."
    done < "$f"
    : > "$f"
    ok "Restarts applied; queue drained."

    # A freshly-recreated LiteLLM needs a few seconds to bind + run its Prisma
    # migration before it answers HTTP. Without this wait, the final doctor's
    # alias-reachability probe (check 17) catches litellm mid-recreate and
    # reports a transient "HTTP 000" failure. Poll until it answers (any code,
    # incl. 401, means the server is up). CHANGELOG 2026-05-30.
    if (( litellm_was_queued )); then
      log "Waiting for LiteLLM to accept connections after recreate..."
      local _i=0
      while (( _i < 60 )); do
        [[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://litellm:4000/health 2>/dev/null)" != "000" ]] && break
        sleep 2; _i=$((_i+2))
      done
      ok "LiteLLM responding after recreate (waited ${_i}s)"
    fi

    # Reviewer Y-19: Honcho's deriver caches LITELLM_MASTER_KEY at import.
    # If we just recreated litellm with a new master key (or any env that
    # affects the LiteLLM↔deriver auth), the deriver will keep 401-ing
    # until it is also recreated. apply-restarts couples them here.
    if (( litellm_was_queued )); then
      local deriver
      deriver="$(docker ps --format '{{.Names}}' | grep -E '^honcho-deriver-1?$' | head -1 || true)"
      if [[ -n "$deriver" ]]; then
        log "litellm was recreated — also recreating $deriver (caches LITELLM_MASTER_KEY at import)..."
        (cd "$AI_STACK/honcho" && docker compose up -d --force-recreate --no-deps deriver 2>&1 | tail -3) \
          || warn "honcho deriver recreate returned non-zero; check 'docker logs $deriver'"
      fi
    fi
  else
    warn "Skipped. Run 'vz-ai-stack.sh apply-restarts' when ready."
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# Step E — final doctor.
# ──────────────────────────────────────────────────────────────────────────
bootstrap_final_doctor() {
  hdr "Final health check"
  if confirm "Run doctor now?" Y; then
    bash "$AI_STACK/installer/doctor/doctor.sh" || true
  fi
}

# ──────────────────────────────────────────────────────────────────────────
# Orchestrate. Skipped entirely under NO_PROMPT=1 (CI mode).
# ──────────────────────────────────────────────────────────────────────────
bootstrap_run_all() {
  if [[ "${NO_PROMPT:-0}" == "1" ]]; then
    note "NO_PROMPT=1 — skipping interactive remediation (run subcommands manually)."
    return 0
  fi
  bootstrap_adopt_foreigns
  bootstrap_recreate_honcho_if_drifted
  bootstrap_phoenix_api_key
  bootstrap_drain_restarts
  bootstrap_final_doctor
}
