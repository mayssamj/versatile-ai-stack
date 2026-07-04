#!/usr/bin/env bash
# test_hermes_workspace_v18_netns.sh — locks in the §24-reviewed v0.18.0 loopback+netns
# cutover so a future edit can't silently revert it. STATIC assertions grep the phase
# (pure-offline); a DYNAMIC section (docker+yq present) replays the exact heredoc + yq
# migration and asserts the daemon-critical merge (F1 !override → workspace has NO ports,
# agent keeps :8642). Mirrors the empirical harness that validated the implementation.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
P05="$ROOT/installer/phases/05_uis.sh"
CHK="$ROOT/installer/doctor/checks/73_hermes_workspace_pair.sh"
PASS=0; FAIL=0
ok(){ PASS=$((PASS+1)); echo "  ok   $1"; }
bad(){ FAIL=$((FAIL+1)); echo "  FAIL $1"; }

# ---- STATIC (always) ---------------------------------------------------------
# 1. DEFAULT is v0.18.0 (v2026.7.1) — the loopback+netns-compatible release.
grep -qE '^HERMES_AGENT_DEFAULT="nousresearch/hermes-agent:v2026\.7\.1@sha256:' "$P05" \
  && ok "HERMES_AGENT_DEFAULT pinned to v0.18.0 (v2026.7.1)" || bad "DEFAULT not v2026.7.1"

# 2. Dashboard bound to LOOPBACK in BOTH the heredoc AND the yq migration (v0.18.0 keeps
#    loopback un-gated; a 0.0.0.0 bind fail-closes). And INSECURE is GONE (inert no-op).
[[ "$(grep -cE 'HERMES_DASHBOARD_HOST:? *=? *"?127\.0\.0\.1' "$P05")" -ge 2 ]] \
  && ok "dashboard bound to 127.0.0.1 in heredoc + yq migration" || bad "dashboard not loopback in both paths"
# INSECURE must never be SET (heredoc `: "1"` or yq `= "1"`) — but it IS still referenced to
# DETECT (precheck) + DELETE (yq del) the old signature, which is correct, so grep for the SET form.
! grep -qE 'HERMES_DASHBOARD_INSECURE: "1"|HERMES_DASHBOARD_INSECURE = "1"' "$P05" \
  && grep -q 'del(.services.hermes-agent.environment.HERMES_DASHBOARD_INSECURE)' "$P05" \
  && ok "HERMES_DASHBOARD_INSECURE never set + actively del()'d on migration (inert no-op on v0.18.0)" \
  || bad "HERMES_DASHBOARD_INSECURE is still SET, or not deleted on migration"

# 3. Workspace shares the agent netns (network_mode) in BOTH paths.
[[ "$(grep -cE 'network_mode:? *=? *"?service:hermes-agent' "$P05")" -ge 2 ]] \
  && ok "workspace network_mode: service:hermes-agent in heredoc + migration" || bad "network_mode missing in a path"

# 4. F1: workspace ports force-REPLACED via !override (a netns child can't own ports; compose
#    merges lists by append, so omission leaves the base :3000 → daemon 'conflicting options').
grep -qE 'ports: !override \[\]' "$P05" \
  && ok "heredoc drops workspace ports via !override []" || bad "heredoc missing !override on workspace ports"
grep -qE '\.services\.hermes-workspace\.ports tag= "!override"' "$P05" \
  && ok "yq migration force-replaces workspace ports via !override tag" || bad "yq migration missing !override"

# 5. F4: the UI :3000 is published on the AGENT (both 127.0.0.1 + 127.0.10.10) since the
#    workspace can't; and the hermes-gw :8642 host-publish is PRESERVED (ingress depends on it).
grep -qE '127\.0\.0\.1:3000:3000' "$P05" && grep -qE '127\.0\.10\.10:3000:3000' "$P05" \
  && ok "UI :3000 published on both 127.0.0.1 + 127.0.10.10 (bookmark-safe)" || bad "a :3000 publish missing"
grep -qE '127\.0\.10\.11:8642:8642' "$P05" \
  && ok "hermes-gw :8642 host-publish preserved (Caddy ingress depends on it)" || bad "hermes-gw :8642 publish dropped (ingress regression!)"

# 6. F2: dashboard token generated in .env + referenced as an ESCAPED compose placeholder in the
#    unquoted heredoc (\${...} → literal → compose interpolates; NOT bash-expanded to blank).
grep -qE 'HERMES_DASHBOARD_TOKEN=\$\(openssl rand -hex 32\)' "$P05" \
  && ok "HERMES_DASHBOARD_TOKEN generated in .env (idempotent)" || bad "token not generated"
grep -qE 'HERMES_DASHBOARD_SESSION_TOKEN: \\\$\{HERMES_DASHBOARD_TOKEN\}' "$P05" \
  && ok "heredoc escapes \${HERMES_DASHBOARD_TOKEN} (compose interpolates, no bash-blank)" || bad "token placeholder not escaped in heredoc"

# 7. F5: precheck() up-to-date signature is the NEW one (127.0.0.1 + network_mode + NOT insecure).
grep -qE "grep -qE '\^\[\[:space:\]\]\*HERMES_DASHBOARD_HOST:\[\[:space:\]\]\*127" "$P05" \
  && ok "precheck() staleness gate keys on the NEW 127.0.0.1 signature" || bad "precheck() still keys on the old signature"

# 8. F3: auto-rollback snapshots the WHOLE prior override + restores it on compat-fail.
grep -qE '_ovr_prev=.*docker-compose\.override\.yml\.prev|cp -f "\$WS_DIR/docker-compose.override.yml" "\$_ovr_prev"' "$P05" \
  && ok "compat-fail path snapshots the prior override (F3)" || bad "no pre-change override snapshot"
grep -qE 'AUTO-ROLLBACK: restored the prior working override' "$P05" \
  && ok "compat-fail restores the WHOLE override + recreates (not just the image line)" || bad "auto-rollback restore missing"

# 9. R2 self-heal check exists + is an AUTOHEAL check for the netns split.
[[ -f "$CHK" ]] && grep -q 'CHECKS+=(hermes_workspace_pair)' "$CHK" && grep -q 'AUTOHEAL\[hermes_workspace_pair\]=1' "$CHK" \
  && ok "check 73 hermes_workspace_pair exists + AUTOHEAL=1" || bad "R2 self-heal check missing/unregistered"

# ---- DYNAMIC (docker + yq present): the daemon-critical merge ----------------
if command -v yq >/dev/null 2>&1 && command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  T="$(mktemp -d)"; cp "$ROOT/hermes-workspace/docker-compose.yml" "$T/docker-compose.yml" 2>/dev/null
  if [[ -f "$T/docker-compose.yml" ]]; then
    printf 'API_SERVER_KEY=%s\nHERMES_DASHBOARD_TOKEN=%s\n' "$(openssl rand -hex 24)" "$(openssl rand -hex 32)" > "$T/.env"
    # minimal override in the NEW shape, then the migration's !override (mirrors the phase)
    cat > "$T/docker-compose.override.yml" <<'YML'
services:
  hermes-agent:
    image: nousresearch/hermes-agent:v2026.7.1@sha256:b6c019227889e6675424a2b6223b2cafdd36bf7d1048d1ddd8e043b880d6cc0f
    environment: {HERMES_DASHBOARD_HOST: 127.0.0.1}
    ports: ["127.0.10.11:8642:8642","127.0.0.1:3000:3000","127.0.10.10:3000:3000"]
  hermes-workspace:
    image: hermes-workspace:aistack-hardened
    network_mode: "service:hermes-agent"
YML
    yq -i '.services.hermes-workspace.ports = [] | .services.hermes-workspace.ports tag= "!override"' "$T/docker-compose.override.yml" 2>/dev/null
    yq -i '.services.hermes-workspace.ports = [] | .services.hermes-workspace.ports tag= "!override"' "$T/docker-compose.override.yml" 2>/dev/null  # idempotent re-read
    wsp="$( (cd "$T" && docker compose config 2>/dev/null | yq '.services.hermes-workspace.ports') )"
    agp="$( (cd "$T" && docker compose config 2>/dev/null | yq '.services.hermes-agent.ports | length') )"
    if (cd "$T" && docker compose config >/dev/null 2>&1) && [[ "$wsp" == "null" ]]; then
      ok "merged config valid + workspace has NO ports (F1 !override survives base merge + yq re-read)"
    else
      bad "merged config invalid or workspace still has ports (wsp='$wsp')"
    fi
    [[ "${agp:-0}" -ge 3 ]] && ok "agent keeps its published ports incl :8642 (agp=$agp)" || bad "agent lost ports (agp='$agp')"
  else
    echo "  (skip dynamic: no hermes-workspace/docker-compose.yml)"
  fi
  rm -rf "$T"
else
  echo "  (skip dynamic merge test: docker/yq unavailable)"
fi

echo; echo "RESULT: $PASS passed, $FAIL failed"; (( FAIL == 0 ))
