#!/usr/bin/env bash
# Phase 41 — FalkorDB graph-memory MCP (OPT-IN).
#
# Makes FalkorDB graph memory usable by claude-cli + the Hermes fleet via a host-side
# token-gated MCP shim (falkordb-mcp/, served on 127.0.0.1:7083). Minimal primitive (operator
# decision D2: NO auto-extraction) — remember_fact / recall_related / graph_query / graph_write
# over one shared graph (fleet-memory).
#
# NOT in `install all`. Install by name: `mayssam-ai-stack.sh install falkordb_mcp`.
# Unlike the honcho slice this is PURELY ADDITIVE — FalkorDB was never fleet-reachable (raw
# :6379 always denied to sandboxes), so there is NO egress to retire and NO security-posture
# flag gate; a plain opt-in phase suffices. The shim + token are the only sandbox path.
#
# Idempotent: token minted ONLY if absent; shim start is _alive+_health-gated; `claude mcp add`
# (remove-then-add) + `hermes config set` + `openshell policy set` all re-assert cleanly.
#
# Rollback: claude mcp remove -s user falkordb ; mayssam-ai-stack.sh stop falkordb_mcp ;
#   rm installer/state/phase_41.done ; (un-wire fleet: hermes config unset mcp_servers.falkordb).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/worktree.sh"
source "$AI_STACK/installer/lib/memory_mcp.sh"
source "$AI_STACK/installer/lib/mcp.sh"

PHASE=41
NAME=falkordb_mcp
PORT="$(get_env FALKORDB_MCP_PORT '7083')"
SHIM_DIR="$AI_STACK/falkordb-mcp"
SANDBOX=hermes-fleet-v1
FLEET_POLICY="$AI_STACK/openshell/policies/hermes-fleet-v1.yaml"

precheck() {
  [[ -d "$SHIM_DIR/node_modules/@modelcontextprotocol/sdk" ]] || return 1
  [[ -n "$(get_env FALKORDB_MCP_TOKEN '')" ]] || return 1
  if command -v claude >/dev/null 2>&1; then
    claude mcp list 2>/dev/null | grep -q '^falkordb[: ]' || return 1
  fi
  # ALSO require hermes-fleet falkordb wiring IF a fleet sandbox is Ready. Without this the
  # precheck was blind to the ONE thing doctor check 76 asserts, so with phase_41.done present
  # `install falkordb_mcp` self-skipped FOREVER on an unwired fleet — doctor told the operator
  # to run a command that could not possibly fix it. Mirrors Phase 39's precheck (39:62), which
  # already got this right. (Returns ok when no fleet sandbox is Ready — nothing to wire yet.)
  _mem_hermes_falkordb_wired "$(_mem_resolve_openshell)" "$PORT"
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 41 (falkordb_mcp) already installed — skipping. (Re-run 'reset' first to rebuild.)"
  exit 0
fi

worktree_guard "install falkordb_mcp"
command -v node >/dev/null 2>&1 || { err "node not found on PATH. Run 'mayssam-ai-stack.sh deps'."; exit 1; }

# 1. shim deps ----------------------------------------------------------------------
log "Installing falkordb-mcp shim deps…"
( cd "$SHIM_DIR" && npm install --no-audit --no-fund 2>&1 | tail -3 )
[[ -d "$SHIM_DIR/node_modules/@modelcontextprotocol/sdk" ]] || { err "shim deps missing after npm install"; exit 1; }

# 2. mint token (ONLY if absent) + record port ------------------------------------
if [[ -z "$(get_env FALKORDB_MCP_TOKEN '')" ]]; then
  tok="$(openssl rand -hex 24 2>/dev/null || node -e 'console.log(require("crypto").randomBytes(24).toString("hex"))')"
  set_env FALKORDB_MCP_TOKEN "$tok"
  ok "Minted FALKORDB_MCP_TOKEN in .env."
fi
[[ -n "$(get_env FALKORDB_MCP_PORT '')" ]] || set_env FALKORDB_MCP_PORT "$PORT"

# 3. offline smoke gate (mock graph; no real FalkorDB, no models) -------------------
log "Smoke: falkordb-mcp offline test (tools + injection guards + http token gate)…"
if ( cd "$SHIM_DIR" && node test.mjs >/dev/null 2>&1 ); then
  ok "Smoke passed."
else
  err "Phase 41 smoke failed (falkordb-mcp/test.mjs) — not stamping."
  exit 1
fi

# 4. register the stdio MCP with the host Claude session (claude-cli) ----------------
# The shim defaults FALKORDB_URL=redis://falkordb:6379 (resolves on the host alias) +
# graph=fleet-memory; stdio needs no token.
_mem_claude_register_stdio falkordb node "$SHIM_DIR/bin.mjs" --stdio || true

# 5. start the http shim daemon (the fleet's path) ----------------------------------
if bash "$AI_STACK/bin/start-falkordb_mcp.sh"; then :; else warn "falkordb-mcp http daemon did not start cleanly (continuing; fleet wiring still recorded)."; fi

# 6. live-apply the fleet policy (which now carries the additive falkordb_mcp egress) so the
#    running sandbox gains :7083 immediately (mirrors Phase 27/40 backstop; ADDITIVE — nothing
#    retired). pi stays denied (no falkordb egress for pi).
OSH="$(_mem_resolve_openshell)"
if sandbox_present "$OSH" "$SANDBOX"; then
  if "$OSH" policy set "$SANDBOX" --policy "$FLEET_POLICY" --wait --timeout 60 </dev/null >/dev/null 2>&1; then
    ok "applied falkordb_mcp egress policy to live sandbox $SANDBOX (:7083 reachable)"
  else
    warn "live policy set for $SANDBOX returned non-zero — re-apply via 'mayssam-ai-stack.sh install 04'"
  fi
fi

# 7. wire the Hermes fleet to the shim (token-gated), if the sandbox is Ready --------
# sandbox_ready (common.sh), NOT `sandbox list | grep -q` — see sandbox_present's comment for
# the EPIPE race, and sandbox_ready's for why the WIRING branch needs Ready, not mere presence.
if sandbox_ready "$OSH" "$SANDBOX"; then
  configure_hermes_mcp_falkordb "$OSH" "$SANDBOX" "$PORT" \
    || warn "Hermes fleet FalkorDB wiring returned non-zero — verifying the post-condition…"
  # VERIFY-THEN-STAMP — see Phase 39 for the rationale. This probe IS doctor check 76's own
  # assertion (_mem_hermes_falkordb_wired), so a stamp can never mean "the doctor will red-bar".
  if _mem_hermes_falkordb_wired "$OSH" "$PORT"; then
    ok "Hermes fleet FalkorDB wiring verified (hermes_manager → host.docker.internal:${PORT})."
  else
    err "Hermes fleet FalkorDB wiring did NOT land — hermes_manager profile is missing 'falkordb:' / 'host.docker.internal:${PORT}'. NOT stamping Phase 41."
    err "  Inspect: openshell sandbox exec -n $SANDBOX -- cat ~/.hermes/profiles/hermes_manager/config.yaml"
    err "  Then re-run: mayssam-ai-stack.sh install falkordb_mcp"
    exit 1
  fi
else
  # GENUINE no-sandbox/not-Ready skip → still stamp + exit 0 (below): the stamp is the OPT-IN
  # RECORD that arms 04f_hermes_fleet.sh:667 (`stamp_check 41`) so a fleet built LATER gets wired.
  note "Hermes fleet sandbox '$SANDBOX' not present or not Ready — skipping fleet FalkorDB wiring."
  note "  (It auto-wires on the next 'install 04f', gated on stamp_check 41.)"
fi

# pi falkordb: pi's runtime ships no MCP client, so it is NOT wired here (needs a pi extension,
# tracked with slice 2b). pi's raw :6379 access remains denied regardless.
note "pi FalkorDB: deferred (pi has no MCP client) — raw :6379 stays denied for pi."

stamp_mark "$PHASE"
ok "Phase 41 (falkordb_mcp) — claude-cli graph memory wired; hermes fleet wired when present."
