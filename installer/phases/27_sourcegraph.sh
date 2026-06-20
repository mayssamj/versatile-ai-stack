#!/usr/bin/env bash
# Phase 27 — Sourcegraph (OPT-IN; code search + MCP for the Hermes fleet).
#
# NOT in `install all` — a ~4GB amd64-emulated single-container is a deliberate
# opt-in (run: `vz-ai-stack.sh install sourcegraph`). Once installed it is fully
# managed: deploy (--restart unless-stopped → auto-starts on reboot via the
# engine daemon) + idempotent bootstrap (site-init / token mint / repo index) +
# live network-policy backstop + auto-wire of an EXISTING Hermes fleet. Zero
# follow-up steps. A fleet installed LATER is wired by Phase 04f (which calls the
# same lib/mcp.sh function, gated on the token), so ordering is irrelevant.
#
# Design + empirical validation: CHANGELOG 2026-06-20 and memory
# project_sourcegraph_mcp_fleet_plan / project_sourcegraph_local. §24 council
# (4 reviewers, ACCEPT_WITH_CHANGES) approved opt-in + this shape.
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/docker-engine.sh"
source "$AI_STACK/installer/lib/docker.sh"
source "$AI_STACK/installer/lib/mcp.sh"        # configure_hermes_mcp_sourcegraph
source "$AI_STACK/installer/lib/openshell.sh"  # resolve_openshell / openshell_token_storm

PHASE=27
NAME=sourcegraph
SG_URL="http://localhost:7080"
SG_DIR="$HOME/.sourcegraph-local"
TOKEN_FILE="$SG_DIR/sg-token"
SANDBOX=hermes-fleet-v1
POLICY="$AI_STACK/openshell/policies/${SANDBOX}.yaml"
# Repo(s) to index (space-separated owner/name). Public clone via the OTHER code
# host (no GitHub token needed for public repos).
SG_INDEX_REPOS="$(get_env SOURCEGRAPH_INDEX_REPOS 'mayssamj/versatile-ai-stack')"
SG_EXTSVC_NAME="ai-stack (local)"

# Resolve the gateway-matching openshell binary (prefer brew; matches Phase 04/04f).
# A bare `openshell` on PATH may be a uv-tool install that shadows + version-skews
# the brew binary the gateway expects. lib/openshell.sh does NOT export this.
resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""; fi
}
OSH="$(resolve_openshell)"

# --- tiny HTTP/GraphQL helpers ----------------------------------------------
_sg_http_code() { curl -s -o /dev/null -w '%{http_code}' --max-time 6 "$1" 2>/dev/null || echo 000; }
# _sg_gql <token> <query-json>  — POST a GraphQL request; prints raw JSON.
_sg_gql() {
  curl -s --max-time 15 -X POST "$SG_URL/.api/graphql" \
    -H "Authorization: token $1" -H 'Content-Type: application/json' -d "$2" 2>/dev/null
}
_json_get() { python3 -c 'import sys,json;
d=json.load(sys.stdin)
ks=sys.argv[1].split(".")
for k in ks:
    d=d.get(k) if isinstance(d,dict) else None
    if d is None: break
print(d if d is not None else "")' "$1" 2>/dev/null; }

# --- precheck: container running + token valid + stamp → already done --------
precheck() {
  container_running "$NAME" || return 1
  [[ -s "$TOKEN_FILE" ]] || return 1
  local u; u="$(_sg_gql "$(cat "$TOKEN_FILE")" '{"query":"{ currentUser { username } }"}' | _json_get data.currentUser.username)"
  [[ -n "$u" ]] || return 1
  return 0
}
if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete (sourcegraph up, token valid)"
  exit 0
fi

hdr "Phase 27 — Sourcegraph (opt-in code search + fleet MCP)"

# --- 1. Deploy / ensure the container ---------------------------------------
if container_running "$NAME"; then
  ok "container '$NAME' already running"
elif container_exists "$NAME"; then
  log "starting existing (stopped) '$NAME' container…"
  docker start "$NAME" >/dev/null
  ok "started '$NAME'"
else
  bash "$AI_STACK/bin/start-sourcegraph.sh" || { err "start-sourcegraph.sh failed"; exit 1; }
fi

# --- 2. Wait for SG to serve HTTP (amd64/Rosetta first boot is SLOW: up to ~300s) ---
log "waiting for Sourcegraph to serve HTTP (up to 300s; first amd64 boot is slow)…"
deadline=$(( SECONDS + 300 )); code=000
while (( SECONDS < deadline )); do
  code="$(_sg_http_code "$SG_URL/")"
  [[ "$code" != "000" ]] && break
  sleep 5
done
if [[ "$code" == "000" ]]; then
  err "Sourcegraph did not serve HTTP within 300s. Check: docker logs $NAME --tail 50"
  exit 1
fi
ok "Sourcegraph responding (HTTP $code)"

# --- 3. Idempotent bootstrap (3 states) -------------------------------------
# (i) fresh (needsSiteInit:true): site-init admin + mint token
# (ii) initialized + token valid: reuse
# (iii) initialized + token absent/invalid + admin creds in .env: sign-in + mint
#       (NEVER re-call site-init on an initialized instance — it fails)
TOKEN=""
# Detect fresh-vs-initialized from GET / : a FRESH instance serves a 2xx body
# containing "needsSiteInit":true (verified on 6.12.5040); an INITIALIZED one 302s
# (no such marker). Validate the fetch succeeded so a transient/non-2xx response
# isn't silently mis-classified as "initialized" and then mis-routed to sign-in.
_root_resp="$(curl -s --max-time 8 -w '\n__C_%{http_code}' "$SG_URL/" 2>/dev/null || echo '__C_000')"
_root_code="$(awk -F'__C_' 'NF>1{print $2}' <<<"$_root_resp" | tail -1)"
if [[ "${_root_code:-000}" == "000" ]]; then
  err "Sourcegraph unreachable at $SG_URL during bootstrap (HTTP 000) — it may still be initializing. Check: docker logs $NAME --tail 50, then re-run."
  exit 1
fi
needs_init="$(grep -o '"needsSiteInit":true' <<<"$_root_resp" | head -1 || true)"

_mint_token_with_cookie() {  # <cookiejar> → prints a user:all token (uses session cookie)
  local jar="$1" uid body
  uid="$(curl -s --max-time 10 -b "$jar" -X POST "$SG_URL/.api/graphql" -H 'Content-Type: application/json' \
        -H 'X-Requested-With: Sourcegraph' -d '{"query":"{ currentUser { id } }"}' | _json_get data.currentUser.id)"
  [[ -n "$uid" ]] || return 1
  # Build the mutation JSON via python (SOUL Rule 10 — no fragile nested-quote escaping).
  body="$(python3 -c 'import json,sys; print(json.dumps({"query":"mutation($u:ID!){createAccessToken(user:$u,scopes:[\"user:all\"],note:\"ai-stack-fleet\"){token}}","variables":{"u":sys.argv[1]}}))' "$uid")"
  curl -s --max-time 10 -b "$jar" -X POST "$SG_URL/.api/graphql" -H 'Content-Type: application/json' \
    -H 'X-Requested-With: Sourcegraph' -d "$body" \
    | _json_get data.createAccessToken.token
}

if [[ -n "$needs_init" ]]; then
  log "fresh Sourcegraph — running first-admin site-init…"
  SG_ADMIN_EMAIL="$(get_env SOURCEGRAPH_ADMIN_EMAIL 'admin@ai-stack.local')"
  SG_ADMIN_USER="$(get_env SOURCEGRAPH_ADMIN_USER 'admin')"
  SG_ADMIN_PASS="$(get_env SOURCEGRAPH_ADMIN_PASSWORD '')"
  [[ -n "$SG_ADMIN_PASS" ]] || SG_ADMIN_PASS="sg-$(openssl rand -hex 16)"
  # Persist creds via set_env (0600, never logged) so state (iii) can recover later.
  set_env SOURCEGRAPH_ADMIN_EMAIL "$SG_ADMIN_EMAIL"
  set_env SOURCEGRAPH_ADMIN_USER  "$SG_ADMIN_USER"
  set_env SOURCEGRAPH_ADMIN_PASSWORD "$SG_ADMIN_PASS"
  jar="$(mktemp)"; trap "rm -f '$jar'" EXIT  # path captured at set-time (credential temp file)
  # X-Requested-With is Sourcegraph's CSRF mechanism (no token-in-form). Returns a session cookie.
  _si_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -c "$jar" -X POST "$SG_URL/-/site-init" -H 'X-Requested-With: Sourcegraph' \
    --data-urlencode "email=$SG_ADMIN_EMAIL" --data-urlencode "username=$SG_ADMIN_USER" \
    --data-urlencode "password=$SG_ADMIN_PASS")"
  [[ "$_si_code" =~ ^2 ]] || warn "site-init POST returned HTTP $_si_code (expected 2xx) — token mint may fail; check $SG_URL"
  TOKEN="$(_mint_token_with_cookie "$jar")"
  [[ -n "$TOKEN" ]] || { err "site-init succeeded but token mint failed. Check $SG_URL credentials in .env."; exit 1; }
  ok "site-init complete; admin token minted (admin creds saved to .env, 0600)"
elif [[ -s "$TOKEN_FILE" ]] \
     && [[ -n "$(_sg_gql "$(cat "$TOKEN_FILE")" '{"query":"{ currentUser { username } }"}' | _json_get data.currentUser.username)" ]]; then
  TOKEN="$(cat "$TOKEN_FILE")"
  ok "existing Sourcegraph token is valid — reusing"
else
  # Initialized but no usable token — recover via admin sign-in (do NOT site-init).
  SG_ADMIN_USER="$(get_env SOURCEGRAPH_ADMIN_USER 'admin')"
  SG_ADMIN_PASS="$(get_env SOURCEGRAPH_ADMIN_PASSWORD '')"
  if [[ -n "$SG_ADMIN_PASS" ]]; then
    log "initialized but token missing/invalid — signing in to re-mint…"
    jar="$(mktemp)"; trap "rm -f '$jar'" EXIT  # path captured at set-time (credential temp file)
    curl -s --max-time 15 -c "$jar" -X POST "$SG_URL/-/sign-in" -H 'X-Requested-With: Sourcegraph' \
      --data-urlencode "username=$SG_ADMIN_USER" --data-urlencode "password=$SG_ADMIN_PASS" >/dev/null
    TOKEN="$(_mint_token_with_cookie "$jar")"
  fi
  [[ -n "$TOKEN" ]] || { err "Sourcegraph is initialized but no valid token/admin creds. Manual recovery: sign in at $SG_URL and create a user:all token into $TOKEN_FILE. (If this is a FRESH machine, SG may still be initializing — wait, then re-run 'vz-ai-stack.sh install sourcegraph'.)"; exit 1; }
  ok "re-minted token via admin sign-in"
fi

# Persist the token (0600) in a 0700 dir (set perms BEFORE creating — don't leave
# ~/.sourcegraph-local world-listable on a multi-user box even though the token is 0600).
umask 077; mkdir -p "$SG_DIR"; chmod 700 "$SG_DIR" 2>/dev/null || true
printf '%s' "$TOKEN" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
ok "token persisted to $TOKEN_FILE (0600)"

# --- 4. Index the repo via the OTHER code host (idempotent: dedup by name) ---
existing="$(_sg_gql "$TOKEN" '{"query":"{ externalServices { nodes { displayName } } }"}')"
if grep -qF "$SG_EXTSVC_NAME" <<<"$existing"; then
  ok "code host '$SG_EXTSVC_NAME' already present — repos: $SG_INDEX_REPOS"
else
  log "registering OTHER code host '$SG_EXTSVC_NAME' (repos: $SG_INDEX_REPOS)…"
  repos_json="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1].split()))' "$SG_INDEX_REPOS")"
  cfg="$(python3 -c 'import json,sys; print(json.dumps({"url":"https://github.com/","repos":json.loads(sys.argv[1])}))' "$repos_json")"
  add_q="$(python3 -c 'import json,sys
cfg=sys.argv[1]; name=sys.argv[2]
print(json.dumps({"query":"mutation($n:String!,$c:String!){addExternalService(input:{kind:OTHER,displayName:$n,config:$c}){id}}","variables":{"n":name,"c":cfg}}))' "$cfg" "$SG_EXTSVC_NAME")"
  sid="$(_sg_gql "$TOKEN" "$add_q" | _json_get data.addExternalService.id)"
  [[ -n "$sid" ]] && ok "registered code host (id $sid) — clone+index proceeds in background" \
                   || warn "addExternalService returned no id — index it manually in the SG UI ($SG_URL/site-admin/external-services)"
fi

# --- 5. Live network-policy backstop (so a fresh SG is reachable NOW) --------
# The durable source is the 04_openshell.sh heredoc (regenerates the committed
# YAML, which now carries sourcegraph_mcp). But a live `policy set` here makes the
# sandbox reach SG immediately without waiting for the next `install 04`.
if [[ -n "$OSH" ]] && "$OSH" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | awk -v n="$SANDBOX" 'NR>1 && $1==n{f=1} END{exit !f}'; then
  if [[ -f "$POLICY" ]]; then
    if "$OSH" policy set "$SANDBOX" --policy "$POLICY" --wait --timeout 60 </dev/null >/dev/null 2>&1; then
      ok "applied sourcegraph_mcp network policy to live sandbox $SANDBOX"
    else
      warn "live policy set returned non-zero — re-run 'vz-ai-stack.sh install 04' to apply the sourcegraph_mcp stanza"
    fi
  fi
else
  note "sandbox $SANDBOX not present — skipping live policy apply (Phase 04 will apply it when the fleet exists)"
fi

# --- 6. Wire an EXISTING Hermes fleet (gated; non-fatal) --------------------
if [[ -n "$OSH" ]] && "$OSH" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | awk -v n="$SANDBOX" 'NR>1 && $1==n{f=1} END{exit !f}'; then
  configure_hermes_mcp_sourcegraph "$OSH" "$SANDBOX" || warn "fleet MCP wiring incomplete (re-run 'vz-ai-stack.sh install 04f')"
else
  note "No Hermes fleet sandbox yet — it will auto-wire when you run 'vz-ai-stack.sh install agent_fleet'."
fi

stamp_mark "$PHASE"
record "phase 27 complete: sourcegraph up + bootstrapped + fleet wired (if present)"
ok "Phase 27 — Sourcegraph — complete"
note "Auto-start: the container runs --restart unless-stopped; it returns whenever the Docker engine"
note "  daemon starts (OrbStack/Docker Desktop auto-start at login → survives reboot). On Colima/Podman"
note "  the engine daemon does NOT auto-start by default — start it (or the container) after a reboot."
note "Opt-in: Sourcegraph is a ~4GB amd64-emulated container and is NOT in 'install all' by design."
note "Search UI: $SG_URL   ·   Fleet profiles now have the 'sourcegraph' MCP server (12 code-search tools)."
