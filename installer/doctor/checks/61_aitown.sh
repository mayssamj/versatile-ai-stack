# AI Town (Phase 36): watchable virtual-town agent sim — a Convex DOCKER COMPOSE stack
# (project `aitown`: backend + frontend + dashboard). OPT-IN — skips clean when Phase 36
# hasn't run. PASS requires: the compose project is up (≥3 running members) + the
# frontend serves 200 on :5273 + a scoped LiteLLM key that actually lists models (a
# stale/revoked key returns 200 + empty data[], so we require a real "id"). A down
# key-store DB is reported as "heal the DB" (check 05a), NOT "re-mint".
#
# LIVENESS-ONLY (per [[feedback_doctor_no_coldstart]]): this check NEVER cold-starts or
# blocks on a slow Vite build. It only RED-bars when the phase stamp EXISTS and the stack
# is genuinely down/broken or the key is bad. Deep proof (a real model call) lives in
# smoke/36.sh + 'vz-ai-stack.sh test 36', not here.
#
# Numbered 61 per doc/specs/2026-06-23-agent-sim-platforms-install-plan.md (60 is
# reserved for ChatDev / Wave 2). doctor keys checks by NAME and the count auto-derives
# from the file set, so a numbering gap is intentional, not a missing check.
#
# CENSUS NOTE: AI Town's containers carry NEITHER the ai-stack.managed-as-docker-run
# signal NOR the ai-stack bridge (they're bridge-exempt — a self-contained Convex stack
# that dials the host). Check 53's container-liveness census therefore sees them ONLY via
# the compose-project signal — which is why services.yml declares `project: aitown` AND
# `aitown` is added to check 53's _53_STACK_PROJECTS_FALLBACK floor. (We DO also stamp the
# ai-stack.managed label in the override for belt-and-suspenders, but the project signal
# is the load-bearing one.)
CHECKS+=(aitown)
CHECK_TITLE[aitown]="AI Town compose stack up + frontend 200 on :5273 + scoped LiteLLM key (Phase 36)"

aitown_diagnose() {
  local at_dir="$AI_STACK/ai-town"
  local ip="127.0.10.19" fe_port="5273" project="aitown"
  # Prefer the live alias table if loaded (doctor sources network.sh).
  if declare -p ALIAS_IP >/dev/null 2>&1 && [[ -n "${ALIAS_IP[aitown]:-}" ]]; then
    ip="${ALIAS_IP[aitown]}"; fe_port="${ALIAS_HOST_PORT[aitown]:-5273}"
  fi

  # compgen -G (not ls) — doctor.sh runs under nullglob.
  if ! compgen -G "$AI_STACK/installer/state/phase_36*.done" >/dev/null 2>&1; then
    echo "AI Town not installed in this stack — Phase 36 (opt-in) hasn't run yet (skipping)"
    return 0
  fi

  [[ -f "$at_dir/docker-compose.yml" ]] || { echo "ai-town/docker-compose.yml missing ($at_dir) — re-run 'vz-ai-stack.sh install 36'"; return 1; }
  docker info >/dev/null 2>&1 || { echo "docker daemon not reachable — check 01 covers this"; return 1; }

  # All 3 compose members running? (liveness, not cold-start — never builds here.)
  local running
  running="$( (cd "$at_dir" && docker compose -p "$project" ps --status running -q 2>/dev/null | grep -c .) || true)"
  if [[ "${running:-0}" -lt 3 ]]; then
    echo "AI Town compose stack not fully up (only ${running:-0}/3 members running) — 'vz-ai-stack.sh start aitown' (first build is heavy; 'docker compose -p $project logs')"
    return 1
  fi

  # Frontend serves 200 (explicit ^200$ — NOT the http_ok helper; documented 000-bug).
  if ! curl -sL -o /dev/null -w '%{http_code}' --max-time 5 "http://$ip:$fe_port/" 2>/dev/null | grep -q '^200$'; then
    echo "AI Town frontend not serving 200 on http://$ip:$fe_port/ — Vite may still be building, or the stack is down ('vz-ai-stack.sh start aitown'; 'docker compose -p $project logs frontend')"
    return 1
  fi

  # Scoped key actually lists models (stale/revoked → 200 + empty data[], so require an "id").
  local key; key="$(get_env AITOWN_LITELLM_KEY '')"
  [[ -n "$key" ]] || { echo "AITOWN_LITELLM_KEY missing from .env — re-run 'vz-ai-stack.sh install 36'"; return 1; }
  # Probe 127.0.0.1 FIRST — it is always reachable from the host shell where doctor runs.
  # The container alias litellm:4000 only resolves if Phase 00n wrote /etc/hosts, so trying
  # it first would burn a guaranteed ~5s timeout on boxes without that entry. Fall back to
  # the alias only if loopback didn't answer (parity with the phase's resolve-once order).
  local models
  models="$(litellm_scoped_curl "$key" -s --max-time 5 http://127.0.0.1:4000/v1/models 2>/dev/null || true)"
  printf '%s' "$models" | grep -q '"id"' \
    || models="$(litellm_scoped_curl "$key" -s --max-time 5 http://litellm:4000/v1/models 2>/dev/null || true)"
  if ! printf '%s' "$models" | grep -q '"id"'; then
    if declare -F litellm_db_down >/dev/null 2>&1 && litellm_db_down; then
      echo "LiteLLM key-store DB is DOWN — heal it (see check 05a / 'vz-ai-stack.sh doctor keystore'); do NOT re-mint"
      return 1
    fi
    echo "AITOWN_LITELLM_KEY rejected by LiteLLM (no models) — re-mint via 'vz-ai-stack.sh install 36'"
    return 1
  fi

  # Allow-list drift assertion (shared helper — see _doctor_assert_key_allowlist in
  # common.sh): the /v1/models probe above only proves the key lists SOME model; this
  # verifies it ALLOWS the chat model AI Town is bound to (models.yml .assignments.aitown,
  # else local). The helper probes /key/info LOOPBACK-FIRST (parity with this check's
  # loopback-first /v1/models probe — the litellm:4000 alias only resolves with /etc/hosts).
  # Non-fatal on yq-absent / wildcard / empty / unparseable / LiteLLM-down; FAILs (with its
  # own message) only on a genuine stale-key miss.
  _doctor_assert_key_allowlist "$key" AITOWN_LITELLM_KEY aitown "the chat model AI Town calls" 36 || return 1
  echo "AI Town ready (3/3 containers up + frontend 200 + scoped key lists models); watch it: http://aitown:$fe_port/ — prove the wiring: vz-ai-stack.sh test 36"
  return 0
}

aitown_fix() {
  echo "vz-ai-stack.sh start aitown    # bring the compose stack up (first build is heavy)"
  echo "vz-ai-stack.sh install 36      # rebuild override + re-mint scoped key + re-wire Convex LLM env + re-push schema"
}
