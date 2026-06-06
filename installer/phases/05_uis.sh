#!/usr/bin/env bash
# Phase 05 — Host UIs: Open WebUI + Hermes Workspace.
#
# Open WebUI: docker container on 3001, wired to LiteLLM on 4000.
# Hermes Workspace: cloned from upstream into ~/ai-stack/hermes-workspace,
# brought up via docker compose. Upstream is github.com/outsourc-e/hermes-workspace
# (community workspace UI for the official NousResearch/hermes-agent — the
# install guide's NousResearch/hermes-workspace URL never existed).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/validate.sh"

PHASE=05
WS_DIR="$AI_STACK/hermes-workspace"

precheck() {
  container_running openwebui || return 1
  wait_http http://openwebui:8080 5 || return 1
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (host UIs)"
  exit 0
fi

hdr "Phase 05 — Host UIs"

# --- Open WebUI ---
if container_running openwebui; then
  if container_managed openwebui; then ok "openwebui already running (managed)"
  else warn "openwebui is FOREIGN; run 'vz-ai-stack.sh adopt openwebui'"
  fi
else
  bash "$AI_STACK/bin/start-openwebui.sh"
fi
# 180s is generous for the first image-pull/boot. If a MANAGED container is still
# not serving after that, it's almost certainly broken (not still pulling) — heal
# it once via recreate rather than silently leaving a dead UI behind a warning.
if ! wait_http http://openwebui:8080 180; then
  if container_managed openwebui; then
    warn "openwebui managed but not serving after 180s — recreating once to heal it."
    bash "$AI_STACK/bin/start-openwebui.sh" --recreate
    wait_http http://openwebui:8080 180 || warn "openwebui still not up — check 'docker logs openwebui'"
  else
    warn "openwebui didn't come up in 180s — first-pull may still be running; recheck with 'docker logs openwebui'"
  fi
fi

# --- Hermes Workspace ---
# Upstream URL is a placeholder — the published repo path may differ.
# Skip cleanly if URL doesn't resolve; user can clone manually.
if [[ ! -d "$WS_DIR/.git" && ! -f "$WS_DIR/docker-compose.yml" ]]; then
  log "Cloning Hermes Workspace (best effort)..."
  rm -rf "${WS_DIR}.partial"
  if git clone https://github.com/outsourc-e/hermes-workspace "${WS_DIR}.partial" 2>&1 | tail -5; then
    rmdir "$WS_DIR" 2>/dev/null || true
    mv "${WS_DIR}.partial" "$WS_DIR"
    ok "cloned to $WS_DIR"
  else
    rm -rf "${WS_DIR}.partial"
    warn "Hermes Workspace clone failed — upstream may have moved again."
    warn "If you have the workspace source elsewhere, place it at $WS_DIR and re-run this phase."
    # Don't fail the phase — Open WebUI is the higher-priority UI.
  fi
fi

if [[ -f "$WS_DIR/docker-compose.yml" ]]; then
  # Compose has an env_file: directive expecting .env. Repo ships .env.example;
  # seed .env from it if missing.
  if [[ ! -f "$WS_DIR/.env" && -f "$WS_DIR/.env.example" ]]; then
    install -m 600 /dev/null "$WS_DIR/.env"
    cat "$WS_DIR/.env.example" > "$WS_DIR/.env"
    ok "seeded $WS_DIR/.env from .env.example"
  fi
  # ai-stack runs this localhost-only UI WITHOUT a login: the override pins the
  # workspace's in-container bind to HOST=127.0.0.1 so the published image's
  # fail-closed guard (non-loopback HOST + no password) stays inert. So we leave
  # HERMES_PASSWORD unset and neutralize any pre-existing one. (To require a
  # login: set HERMES_PASSWORD=<secret> in .env + force-recreate the workspace.)
  # API_SERVER_KEY below is unrelated — it is hermes-agent's gateway bearer token.
  for _pk in HERMES_PASSWORD CLAUDE_PASSWORD; do
    if grep -qE "^[[:space:]]*${_pk}=.+" "$WS_DIR/.env" 2>/dev/null; then
      sed -i.bak -E "s|^([[:space:]]*${_pk}=.+)|# disabled by ai-stack (localhost no-auth) — \1|" "$WS_DIR/.env" && rm -f "$WS_DIR/.env.bak"
      ok "disabled $_pk in $WS_DIR/.env (workspace runs without a login)"
    fi
  done
  if ! grep -qE '^API_SERVER_KEY=.+' "$WS_DIR/.env" 2>/dev/null; then
    echo "API_SERVER_KEY=$(openssl rand -hex 24)" >> "$WS_DIR/.env"
    ok "generated random API_SERVER_KEY in $WS_DIR/.env"
  fi
  # Compose binds 127.0.0.1:3000 by default. Rebind to the workspace alias
  # IP (127.0.10.10) and the hermes-gw alias (127.0.10.11 for hermes-agent
  # at :8642) so the /etc/hosts aliases actually reach the listeners.
  if [[ ! -f "$WS_DIR/docker-compose.override.yml" ]]; then
    # Compose lists are merged (appended) by default. Adding alias-IP bindings
    # alongside the upstream 127.0.0.1 bindings makes BOTH work, so existing
    # `http://localhost:3000` clients aren't broken and `http://workspace:3000`
    # (alias) also resolves.
    cat > "$WS_DIR/docker-compose.override.yml" <<'YML'
# ai-stack — also publish on the aliases scheme
# (127.0.10.10 = workspace, 127.0.10.11 = hermes-gw)
#
# Also pin HERMES_DASHBOARD_HOST to 127.0.0.1 (loopback INSIDE the container).
# Upstream sets it to 0.0.0.0 which triggers the dashboard's OAuth gate;
# without an auth provider plugin, hermes-agent refuses to start. The
# dashboard is only reached by the workspace via Docker DNS so loopback
# binding inside the container is sufficient. The workspace runs WITHOUT a login
# via HERMES_ALLOW_INSECURE_REMOTE=1 (bypasses the image's fail-closed guard);
# it stays localhost-only because the host publish is 127.0.0.1 + 127.0.10.10.
services:
  hermes-agent:
    environment:
      HERMES_DASHBOARD_HOST: 127.0.0.1
    ports:
      - "127.0.10.11:8642:8642"
  hermes-workspace:
    environment:
      HERMES_ALLOW_INSECURE_REMOTE: "1"
    ports:
      - "127.0.10.10:3000:3000"
YML
    ok "wrote $WS_DIR/docker-compose.override.yml (alias IP bindings)"
  fi
  # Migration/idempotency: an override.yml from a PRIOR install won't carry
  # HERMES_ALLOW_INSECURE_REMOTE (the write above is write-once), yet the password
  # is disabled above — without the bypass the image's fail-closed guard refuses to
  # start. Ensure the flag is present either way (yq set is idempotent).
  if command -v yq >/dev/null 2>&1 && [[ -f "$WS_DIR/docker-compose.override.yml" ]]; then
    yq -i '.services.hermes-workspace.environment.HERMES_ALLOW_INSECURE_REMOTE = "1"' "$WS_DIR/docker-compose.override.yml" 2>/dev/null \
      && ok "ensured HERMES_ALLOW_INSECURE_REMOTE=1 in workspace override (no-login)" \
      || warn "could not patch override with HERMES_ALLOW_INSECURE_REMOTE — set it manually if the workspace won't start"
  fi
  log "Bringing up Hermes Workspace (first-pull can take 2-5 min)..."
  (cd "$WS_DIR" && docker compose up -d 2>&1 | tail -10) || warn "compose up exited non-zero — see 'docker compose -f $WS_DIR/docker-compose.yml logs'"
  # Probe the workspace alias specifically (127.0.10.10:3000). Plain
  # `wait_port 3000` would FALSE-POSITIVE because falkordb-ui already binds
  # 127.0.10.8:3000 (different IP, same port) — lsof matches both.
  # Workspace serves a login page (200) once up.
  #
  # Fallback: if the alias isn't resolvable (Phase 00·N's plist failed),
  # don't burn 6 minutes hanging — probe 127.0.0.1:3000 instead. workspace
  # binds both 127.0.0.1 (upstream) and 127.0.10.10 (our override).
  # macOS lacks `getent`; use dscacheutil for the system DNS check, and
  # awk that uses an END-only exit (POSIX awk runs END even after a
  # mid-script `exit`, so `END{exit 1}` would override a pattern's
  # `exit 0`).
  WS_PROBE="http://workspace:3000/"
  if ! dscacheutil -q host -a name workspace 2>/dev/null | grep -q '^ip_address:' \
       && ! awk '$2=="workspace"{found=1} END{exit !found}' /etc/hosts; then
    warn "alias 'workspace' unresolved — falling back to http://127.0.0.1:3000/"
    WS_PROBE="http://127.0.0.1:3000/"
  fi
  if wait_http "$WS_PROBE" 120 200; then
    ok "hermes-workspace reachable at $WS_PROBE"
  else
    warn "hermes workspace didn't respond at $WS_PROBE in 120s — check 'docker compose -f $WS_DIR/docker-compose.yml logs hermes-agent'"
  fi
fi

stamp_mark "$PHASE"
record "phase 05 complete: openwebui up, hermes-workspace state=$([[ -f $WS_DIR/docker-compose.yml ]] && echo configured || echo not-configured)"
ok "Phase 05 — Host UIs — complete"
note "Open WebUI: http://openwebui:8080"
# Wrap conditional note so a false test doesn't propagate exit 1 under set -e.
if [[ -f "$WS_DIR/docker-compose.yml" ]]; then
  note "Hermes Workspace: http://workspace:3000"
fi
