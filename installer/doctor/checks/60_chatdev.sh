# ChatDev (Phase 35): containerized multi-agent software-company WEB app (Vue frontend
# :5274 + FastAPI backend :6400, both on the ai-stack bridge) + a scoped LiteLLM key.
# OPT-IN — skips clean when Phase 35 hasn't run. PASS requires: the derived image built,
# both containers running, the frontend serving HTTP 200, and a scoped key that actually
# lists models (a stale/revoked key returns 200 + empty data[], so we require a real
# "id"). A down key-store DB is reported as "heal the DB" (check 05a), NOT "re-mint"
# (re-minting against a dead DB just fails).
#
# Numbered 60 per doc/specs/2026-06-23-agent-sim-platforms-install-plan.md. doctor keys
# checks by NAME and the count auto-derives from the file set, so adding this file
# auto-bumps the count — only prose docs are swept.
CHECKS+=(chatdev)
CHECK_TITLE[chatdev]="ChatDev web app healthy on :5274 + scoped LiteLLM key (Phase 35)"

chatdev_diagnose() {
  # compgen -G (not ls) — doctor.sh runs under nullglob, where an unmatched glob is
  # REMOVED and `ls <glob>` would list cwd and falsely succeed.
  if ! compgen -G "$AI_STACK/installer/state/phase_35*.done" >/dev/null 2>&1; then
    echo "ChatDev not installed in this stack — Phase 35 (opt-in) hasn't run yet (skipping)"
    return 0
  fi

  # Load the alias table (doctor.sh doesn't source network.sh globally — checks that
  # need ALIAS_* load it themselves, cf. 17_alias_resolution.sh). Hardcoded fallbacks
  # keep the check working even if aliases.tsv/yq is unavailable.
  if declare -F aliases_load >/dev/null 2>&1 || source "$AI_STACK/installer/lib/network.sh" 2>/dev/null; then
    aliases_load 2>/dev/null || true
  fi
  local fe_ip="${ALIAS_IP[chatdev]:-127.0.10.18}"
  local fe_port="${ALIAS_HOST_PORT[chatdev]:-5274}"
  local be_port="${CHATDEV_BACKEND_PORT:-6400}"

  # Image + both containers present (the container web archetype's footprint).
  docker image inspect "ai-stack/chatdev:local" >/dev/null 2>&1 \
    || { echo "ChatDev image ai-stack/chatdev:local missing — re-run 'vz-ai-stack.sh install 35'"; return 1; }
  docker ps --format '{{.Names}}' | grep -qx "chatdev-backend" \
    || { echo "chatdev-backend container not running — 'vz-ai-stack.sh start chatdev'"; return 1; }
  docker ps --format '{{.Names}}' | grep -qx "chatdev" \
    || { echo "chatdev (frontend) container not running — 'vz-ai-stack.sh start chatdev'"; return 1; }

  # Health: the web app serves HTTP 200 at / when Vite is up. Explicit '^200$' grep
  # (NOT the http_ok helper — documented 000-concat false-healthy bug).
  if ! curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$fe_ip:$fe_port/" 2>/dev/null | grep -q '^200$'; then
    echo "ChatDev frontend not serving 200 on http://$fe_ip:$fe_port — 'vz-ai-stack.sh start chatdev' (or check 'docker logs chatdev')"
    return 1
  fi

  local key; key="$(get_env CHATDEV_LITELLM_KEY '')"
  [[ -n "$key" ]] || { echo "CHATDEV_LITELLM_KEY missing from .env — re-run 'vz-ai-stack.sh install 35'"; return 1; }
  # Gate the key probe on LiteLLM reachability so a down LiteLLM doesn't red-bar this.
  local models
  models="$(curl -s --max-time 5 -H "Authorization: Bearer $key" http://litellm:4000/v1/models 2>/dev/null || true)"
  printf '%s' "$models" | grep -q '"id"' \
    || models="$(curl -s --max-time 5 -H "Authorization: Bearer $key" http://127.0.0.1:4000/v1/models 2>/dev/null || true)"
  if ! printf '%s' "$models" | grep -q '"id"'; then
    if declare -F litellm_db_down >/dev/null 2>&1 && litellm_db_down; then
      echo "LiteLLM key-store DOWN (503 no_db_connection) — NOT a bad key. Heal the DB (check 05a / 'vz-ai-stack.sh doctor keystore'); do NOT re-mint."
      return 1
    fi
    if curl -sf --max-time 3 http://litellm:4000/health >/dev/null 2>&1 || curl -sf --max-time 3 http://127.0.0.1:4000/health >/dev/null 2>&1; then
      echo "CHATDEV_LITELLM_KEY rejected by LiteLLM /v1/models — re-mint via 'vz-ai-stack.sh install 35'"
      return 1
    fi
    echo "LiteLLM not reachable — start it ('vz-ai-stack.sh start litellm'), then re-check"
    return 1
  fi
  echo "ChatDev ready (image + both containers + frontend 200 + scoped key lists models); prove the swarm: vz-ai-stack.sh test 35"
  return 0
}

chatdev_fix() {
  warn "(Re)build + (re)start the ChatDev containers, or re-run the phase (both idempotent):"
  warn "    bash $AI_STACK/vz-ai-stack.sh start chatdev"
  warn "    bash $AI_STACK/vz-ai-stack.sh install 35"
  return 1
}
