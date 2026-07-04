#!/usr/bin/env bash
# smoke/05.sh — host UIs respond.
#
# Reachability pre-check (Safety Reviewer 2): for each UI container, prove
# the alias path BEFORE relying on the HTTP response. wait_http waits up to
# 30s on a curl that may time out for routing reasons; verify_container_
# reachable_by_alias gives an immediate, specific diagnosis.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/network.sh"
source "$AI_STACK/installer/lib/verify.sh"
source "$AI_STACK/installer/lib/validate.sh"

hdr "Smoke 05 — host UIs"

# 0. REACHABILITY pre-check for openwebui.
log "Reachability: openwebui via http://openwebui..."
verify_container_reachable_by_alias openwebui openwebui 8080 / \
  || { err "openwebui not reachable via http://openwebui:8080"; exit 1; }
ok "openwebui reachable via alias"

wait_http http://openwebui:8080 30 || { err "openwebui not responding at http://openwebui:8080"; exit 1; }
ok "Open WebUI responds (200)"

# Hermes Workspace is optional — only probe if its container is running.
# Match the compose-generated name (hermes-workspace-hermes-workspace-1),
# excluding the agent (…-hermes-agent-1). A bare `grep -qx hermes-workspace`
# never matched the compose naming, so this whole block used to no-op.
ws_container="$(docker ps --format '{{.Names}}' | grep hermes-workspace | grep -v hermes-agent | head -1)"
if [[ -n "$ws_container" ]]; then
  if verify_container_reachable_by_alias "$ws_container" workspace 3000 / 2>/dev/null; then
    ok "Hermes Workspace responds at http://workspace:3000"
    # Sessions sidebar regression guard. The dashboard-backed Sessions API must
    # return a JSON list, not a 500. A loopback-pinned dashboard (the pre-fix
    # default) made the workspace fall back to the gateway path and crash with
    # "Cannot read properties of undefined (reading 'map')". The agent + workspace
    # images are now digest-pinned (the pin guard below catches drift), and the
    # workspace runs a hardened image, but assert the live result here so any
    # regression is LOUD at install time, not a dead sidebar the user only
    # discovers in the browser. (Localhost no-login UI, so the host request needs
    # no token; warn-not-fail to match the optional-UI posture.)
    sess_raw="$(curl -s -w '\nHTTPSTATUS:%{http_code}' --max-time 10 http://workspace:3000/api/sessions 2>/dev/null)"
    sess_code="$(printf '%s' "$sess_raw" | grep -o 'HTTPSTATUS:[0-9]*' | cut -d: -f2)"
    sess_body="$(printf '%s' "$sess_raw" | sed 's/HTTPSTATUS:[0-9]*$//')"
    if [[ "${sess_code:-000}" == "200" ]] && printf '%s' "$sess_body" | grep -q '"sessions"'; then
      ok "Hermes Workspace /api/sessions returns 200 with a sessions list (dashboard path live)"
    else
      warn "Hermes Workspace /api/sessions returned HTTP ${sess_code:-000} without a sessions list — the sidebar will show 'failed to load sessions'. Expect HERMES_DASHBOARD_HOST=127.0.0.1 + network_mode:service:hermes-agent (v0.18.0 loopback+netns) in hermes-workspace/docker-compose.override.yml; re-run 'vz-ai-stack.sh install 05'."
    fi
    # No-:latest pin guard (the root cause was two :latest images drifting out of
    # contract: agent {data} vs workspace {items}). Assert the EFFECTIVE compose
    # config digest-pins the agent (@sha256:) and runs the hardened workspace
    # image — fast + deterministic. Check @sha256: PRESENCE (a bare semver tag is
    # as driftable as :latest).
    ws_dir="$AI_STACK/hermes-workspace"
    if [[ -f "$ws_dir/docker-compose.yml" ]]; then
      eff="$( (cd "$ws_dir" && docker compose config 2>/dev/null) )"
      if printf '%s' "$eff" | grep -qE 'nousresearch/hermes-agent.*@sha256:'; then
        ok "hermes-agent image is digest-pinned (no :latest drift)"
      else
        warn "hermes-agent is NOT digest-pinned in the effective compose config (:latest drift risk) — re-run 'vz-ai-stack.sh install 05'"
      fi
      if printf '%s' "$eff" | grep -q 'hermes-workspace:aistack-hardened'; then
        ok "hermes-workspace runs the hardened image (gateway sessions .map guard)"
      elif printf '%s' "$eff" | grep -qE 'hermes-workspace@sha256:'; then
        warn "hermes-workspace is on the pinned base WITHOUT the hardening (a dashboard outage will 500 the sidebar) — re-run 'vz-ai-stack.sh install 05' to rebuild the hardened image"
      else
        warn "hermes-workspace image is not pinned (:latest drift risk) — re-run 'vz-ai-stack.sh install 05'"
      fi
    fi
  else
    warn "Hermes Workspace container running but http://workspace:3000 did not respond"
  fi
else
  warn "Hermes Workspace not running (skipped clone or upstream unavailable)"
fi
