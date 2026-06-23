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

# --- Pinned image pair (no :latest drift) + the thin "hardened" workspace ---
# Upstream ships hermes-agent and hermes-workspace as a PAIR but both float on
# :latest and drift independently — that drift ({data} vs {items} sessions
# shape) is what broke the sidebar. Pin both to verified-working digests.
#   AGENT  = the STABLE release tag's MULTI-ARCH INDEX digest (portable across
#            arm64/amd64). NOT :latest (re-pushed several times a day) and NOT
#            `docker image inspect .Id` (the non-portable per-image config
#            digest that 'manifest unknown's on amd64 / fresh pulls). = v0.17.0.
#   WS_BASE= the index digest of hermes-workspace :latest at v2.2.0 (no semver
#            image tag is published for it; :latest/:main share this digest).
# Bump EITHER via:  docker buildx imagetools inspect <ref>  → the 'Digest:' line
# (NOT docker image inspect). Re-verify the hardening sed target on a WS bump.
HERMES_AGENT_IMAGE="nousresearch/hermes-agent:v2026.6.19@sha256:9f367c7756ef087661a361536a89f438d57a122b958dc23d82d456b1433e6e9e"
HERMES_WS_BASE="ghcr.io/outsourc-e/hermes-workspace@sha256:2d2ba9aa5b1230766267322817e8e51113541780a5797802a582a47cc34a3df3"
HERMES_WS_IMAGE="hermes-workspace:aistack-hardened"

precheck() {
  container_running openwebui || return 1
  wait_http http://openwebui:8080 5 || return 1
  # Force a phase re-run if a PRIOR install left the Hermes dashboard pinned to
  # loopback. HERMES_DASHBOARD_HOST=127.0.0.1 (or a missing HERMES_DASHBOARD_
  # INSECURE) binds the dashboard to the agent container's OWN loopback, which
  # the workspace container cannot reach — that forces the broken gateway
  # sessions fallback and crashes the sidebar ("...reading 'map'"). The phase
  # body's yq migration rebinds it; but the heredoc is write-once and the body
  # sits behind this stamp gate, so without this check an existing broken
  # install would never self-heal on a normal `install all`. Returning 1 here
  # (stale override) keeps the stamp gate from early-exiting so the body runs.
  # Also re-run when a prior install left the images on :latest (no @sha256:
  # digest pin) or without the hardened workspace image — so existing installs
  # self-heal onto the pinned + hardened pair on a normal `install all`.
  local _ovr="$WS_DIR/docker-compose.override.yml"
  if [[ -f "$_ovr" ]]; then
    grep -qE '^[[:space:]]*HERMES_DASHBOARD_HOST:[[:space:]]*0\.0\.0\.0[[:space:]]*$' "$_ovr" \
      && grep -qE '^[[:space:]]*HERMES_DASHBOARD_INSECURE:[[:space:]]' "$_ovr" \
      && grep -q '@sha256:' "$_ovr" \
      && grep -q 'aistack-hardened' "$_ovr" \
      || return 1
  fi
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
  # Write the thin "hardened" derived-image build context (regenerated each run;
  # the clone — and this .aistack-build/ dir — is wiped on re-clone). The image
  # is FROM the digest-pinned base + ONE FAIL-LOUD sed that guards the gateway
  # sessions `.map` so a dashboard OUTAGE degrades the sidebar to an EMPTY list
  # instead of a 500 "...reading 'map'" (the healthy dashboard path still lists
  # sessions; the gateway fallback is outage-only). `node --check` rejects
  # malformed JS. The base digest arrives via the WS_BASE build arg so it lives
  # in ONE place ($HERMES_WS_BASE). DROP this derived image + revert to a plain
  # `image:` pin once upstream ships PR #577 in a TAGGED release.
  mkdir -p "$WS_DIR/.aistack-build"
  cat > "$WS_DIR/.aistack-build/Dockerfile" <<'DOCKER'
# Generated by ai-stack Phase 05 (installer/phases/05_uis.sh). Do not edit.
ARG WS_BASE
FROM ${WS_BASE}
USER root
RUN set -eu; \
    set -- /app/dist/server/assets/router-*.js; \
    [ "$#" -eq 1 ] || { echo "[aistack] expected exactly 1 router-*.js, found $#: $*" >&2; exit 1; }; \
    f="$1"; \
    grep -q 'sessions2.map(toSessionSummary)' "$f"; \
    sed -i 's/sessions2\.map(toSessionSummary)/(sessions2||[]).map(toSessionSummary)/g' "$f"; \
    grep -q '(sessions2||\[\]).map(toSessionSummary)' "$f"; \
    node --check "$f"; \
    echo "[aistack] hardened sessions .map guard applied + JS validated"
USER workspace
DOCKER
  printf '*\n!Dockerfile\n' > "$WS_DIR/.aistack-build/.dockerignore"

  if [[ ! -f "$WS_DIR/docker-compose.override.yml" ]]; then
    # Compose lists are merged (appended) by default. Adding alias-IP bindings
    # alongside the upstream 127.0.0.1 bindings makes BOTH work, so existing
    # `http://localhost:3000` clients aren't broken and `http://workspace:3000`
    # (alias) also resolves. Unquoted heredoc: the ${HERMES_*} vars expand (the
    # body has no other $ or backticks).
    cat > "$WS_DIR/docker-compose.override.yml" <<YML
# ai-stack — also publish on the aliases scheme
# (127.0.10.10 = workspace, 127.0.10.11 = hermes-gw)
#
# Images are PINNED by digest (no :latest drift). The agent is the stable
# release index digest; the workspace is a thin "hardened" derived image (built
# from .aistack-build/Dockerfile FROM the pinned base) that guards the gateway
# sessions .map so a dashboard OUTAGE shows an EMPTY sidebar instead of a 500.
# Do NOT stack docker-compose.dev.yml with this override — its build: REPLACES
# this one (compose build: is replace-not-merge) and rebuilds the unpatched
# source clone. Drop the derived image once upstream ships PR #577 in a tag.
#
# Bind the dashboard (:9119) to 0.0.0.0 INSIDE the container so the workspace
# container can reach it via Docker DNS (hermes-agent:9119). A 127.0.0.1 bind
# only listens on the agent's OWN loopback, so cross-container requests (which
# arrive on the bridge IP) are refused — that left dashboard.available=false,
# forced the workspace onto the gateway sessions fallback ({data} vs {items}),
# and crashed the sidebar with "Cannot read properties of undefined (reading
# 'map')". A non-loopback bind fails closed unless --insecure is opted in, so
# set HERMES_DASHBOARD_INSECURE=1 (the dashboard analogue of the workspace's
# HERMES_ALLOW_INSECURE_REMOTE=1). The prior 127.0.0.1 pin was a misdiagnosis
# from an older agent version — do NOT restore it.
# Trust boundary: :9119 is NEVER published to the host (only :8642 is, on
# loopback) — it is reachable only on the hermes-workspace_default bridge, whose
# only members are the agent + the workspace it serves. Sensitive dashboard
# /api/* routes require the ephemeral session token, but GET / and /api/status
# are unauthenticated and the token is embedded in the root HTML, so any peer
# ADDED to that bridge would get full agent-config access. NEVER publish :9119.
services:
  hermes-agent:
    image: ${HERMES_AGENT_IMAGE}
    environment:
      HERMES_DASHBOARD_HOST: 0.0.0.0
      HERMES_DASHBOARD_INSECURE: "1"
    ports:
      - "127.0.10.11:8642:8642"
  hermes-workspace:
    build:
      context: ./.aistack-build
      dockerfile: Dockerfile
      args:
        WS_BASE: ${HERMES_WS_BASE}
    image: ${HERMES_WS_IMAGE}
    environment:
      HERMES_ALLOW_INSECURE_REMOTE: "1"
    ports:
      - "127.0.10.10:3000:3000"
YML
    ok "wrote $WS_DIR/docker-compose.override.yml (pinned + hardened)"
  fi
  # Migration/idempotency: the heredoc above is write-once, so patch EXISTING
  # overrides from prior installs onto the same dashboard + pin + hardened config
  # (yq set is idempotent; yq is a guaranteed core dep via deps.sh).
  if command -v yq >/dev/null 2>&1 && [[ -f "$WS_DIR/docker-compose.override.yml" ]]; then
    yq -i '.services.hermes-workspace.environment.HERMES_ALLOW_INSECURE_REMOTE = "1"
           | .services.hermes-agent.environment.HERMES_DASHBOARD_HOST = "0.0.0.0"
           | .services.hermes-agent.environment.HERMES_DASHBOARD_INSECURE = "1"' \
      "$WS_DIR/docker-compose.override.yml" 2>/dev/null \
      && ok "ensured dashboard 0.0.0.0+insecure + workspace no-login in override" \
      || warn "could not patch override dashboard/login settings — set them manually"
    # Pin images (no :latest) + wire the hardened workspace build for EXISTING
    # overrides: the agent digest pin, the workspace derived-image build (context
    # + WS_BASE arg) and its image tag.
    yq -i ".services.hermes-agent.image = \"$HERMES_AGENT_IMAGE\"
           | .services.hermes-workspace.image = \"$HERMES_WS_IMAGE\"
           | .services.hermes-workspace.build.context = \"./.aistack-build\"
           | .services.hermes-workspace.build.dockerfile = \"Dockerfile\"
           | .services.hermes-workspace.build.args.WS_BASE = \"$HERMES_WS_BASE\"" \
      "$WS_DIR/docker-compose.override.yml" 2>/dev/null \
      && ok "pinned agent + hardened workspace image in override (no :latest)" \
      || warn "could not pin images in override — set them manually"
  fi
  # Build the hardened workspace image up front (separate from compose up, so a
  # build failure is distinguishable from a transient agent-image pull and we can
  # degrade gracefully). The build is FROM a pinned digest + a fail-loud sed, so
  # it only fails if a future WS digest bump moved the sed target.
  _wsbuildlog="$(mktemp)"
  if docker build -t "$HERMES_WS_IMAGE" --build-arg "WS_BASE=$HERMES_WS_BASE" \
       -f "$WS_DIR/.aistack-build/Dockerfile" "$WS_DIR/.aistack-build" >"$_wsbuildlog" 2>&1; then
    ok "built hardened workspace image ($HERMES_WS_IMAGE)"
  else
    tail -15 "$_wsbuildlog"
    # Degrade gracefully: drop the build + run the UNPATCHED pinned base so the
    # UI still works (the sidebar will 500 on a dashboard outage until the build
    # is fixed). Best-effort, matching this phase's optional-UI posture — never
    # hard-abort. The precheck staleness gate (missing 'aistack-hardened') re-runs
    # the body next install, so it self-heals once the sed target is re-verified.
    warn "hardened workspace build FAILED — falling back to the unpatched pinned base (re-verify the sed target after a WS digest bump)"
    # { } || true: a yq error on a malformed override must NOT abort the phase
    # under `set -e` (yq present + `yq -i` non-zero is the last cmd of the &&
    # list → set -e would fire). The fallback drops 'aistack-hardened' from the
    # override, so precheck() re-enters this body on the next `install all` and
    # the hardened build self-heals once the sed target is re-verified.
    { command -v yq >/dev/null 2>&1 && yq -i "del(.services.hermes-workspace.build) | .services.hermes-workspace.image = \"$HERMES_WS_BASE\"" "$WS_DIR/docker-compose.override.yml" 2>/dev/null; } || true
    record "phase 05: hermes-workspace on UNPATCHED pinned base (hardened build failed)"
  fi
  rm -f "$_wsbuildlog"
  log "Bringing up Hermes Workspace (first pull can take 2-5 min)..."
  (cd "$WS_DIR" && docker compose up -d 2>&1 | tail -10) || warn "compose up exited non-zero — check 'docker compose -f $WS_DIR/docker-compose.yml logs' (agent image pull?)"
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
