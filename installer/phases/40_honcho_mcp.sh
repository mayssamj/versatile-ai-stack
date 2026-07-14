#!/usr/bin/env bash
# Phase 40 — Honcho memory MCP (OPT-IN + an EXPLICIT security opt-in on top).
#
# Makes Honcho memory usable by claude-cli + the Hermes fleet via a host-side token-gated
# MCP shim (honcho-mcp/, served on 127.0.0.1:7082), and ATOMICALLY retires the raw auth-off
# Honcho REST egress (:8000) from the sandboxes so the shim is the only memory path.
#
# NOT in `install all`. And because it changes the SECURITY POSTURE, it is gated behind an
# explicit env flag so even `install all --include-optionals` cannot flip it silently:
#     HONCHO_MEMORY_OPT_IN=1 vz-ai-stack.sh install honcho_mcp
# The posture it establishes (operator decision, §24 council 2026-07-13): FULL-SHARED memory —
# all consumers share one Honcho workspace, no per-agent isolation; the shim closes the raw
# auth-off hole and requires HONCHO_MCP_TOKEN, but does not isolate peers.
#
# Idempotent: token minted ONLY if absent (re-mint would break wired consumers); shim start
# is _alive+_health-gated; `hermes config set` + `claude mcp add` (remove-then-add) re-assert
# cleanly; `openshell policy set` re-applies the same committed policy.
#
# Rollback: claude mcp remove -s user honcho ; vz-ai-stack.sh stop honcho_mcp ;
#   rm installer/state/phase_40.done ; (to re-open pi/hermes :8000 egress you would have to
#   revert the 04_openshell.sh heredoc + pi-v1.yaml — deliberately hard).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/worktree.sh"
source "$AI_STACK/installer/lib/memory_mcp.sh"
source "$AI_STACK/installer/lib/mcp.sh"
source "$AI_STACK/installer/lib/honcho.sh"   # honcho_ensure_embedding_env (self-heal, no deadlock)

PHASE=40
NAME=honcho_mcp
PORT="$(get_env HONCHO_MCP_PORT '7082')"
SHIM_DIR="$AI_STACK/honcho-mcp"
SANDBOX=hermes-fleet-v1
FLEET_POLICY="$AI_STACK/openshell/policies/hermes-fleet-v1.yaml"
PI_POLICY="$AI_STACK/openshell/policies/pi-v1.yaml"

# --- EXPLICIT security opt-in gate (keeps blanket --include-optionals from flipping posture) ---
if [[ "${HONCHO_MEMORY_OPT_IN:-0}" != "1" ]]; then
  note "Phase 40 (honcho_mcp) is an EXPLICIT opt-in — it changes the security posture:"
  note "  • retires the raw honcho:8000 sandbox egress (closes the auth-off REST hole)"
  note "  • exposes a token-gated honcho-mcp shim on 127.0.0.1:$PORT for claude + the fleet"
  note "  • FULL-SHARED memory: all consumers share one Honcho workspace (no per-agent isolation)"
  note "Enable deliberately:  HONCHO_MEMORY_OPT_IN=1 vz-ai-stack.sh install honcho_mcp"
  exit 0
fi

precheck() {
  [[ -d "$SHIM_DIR/node_modules/@modelcontextprotocol/sdk" ]] || return 1
  [[ -n "$(get_env HONCHO_MCP_TOKEN '')" ]] || return 1
  if command -v claude >/dev/null 2>&1; then
    claude mcp list 2>/dev/null | grep -q '^honcho[: ]' || return 1
  fi
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 40 (honcho_mcp) already installed — skipping. (Re-run 'reset' first to rebuild.)"
  exit 0
fi

worktree_guard "install honcho_mcp"

# 0. Ensure honcho's embedding is pointed at LiteLLM, else honcho embeds against
#    platform.openai.com and search/recall/ingest 401→500 (a wired-but-broken shim). Apply it
#    HERE directly + reload honcho if it changed (honcho_ensure_embedding_env force-recreates
#    only api+deriver) — do NOT defer to 'install 03', which is a NO-OP on an already-stamped
#    honcho (its precheck short-circuits). Fails only if honcho isn't installed at all.
if ! honcho_ensure_embedding_env; then
  err "Honcho is not installed (no honcho/.env). Install it first:  vz-ai-stack.sh install 03"
  err "then re-run:  HONCHO_MEMORY_OPT_IN=1 vz-ai-stack.sh install honcho_mcp"
  exit 1
fi
command -v node >/dev/null 2>&1 || { err "node not found on PATH. Run 'vz-ai-stack.sh deps'."; exit 1; }

# 1. shim deps ----------------------------------------------------------------------
log "Installing honcho-mcp shim deps…"
( cd "$SHIM_DIR" && npm install --no-audit --no-fund 2>&1 | tail -3 )
[[ -d "$SHIM_DIR/node_modules/@modelcontextprotocol/sdk" ]] || { err "shim deps missing after npm install"; exit 1; }

# 2. mint token (ONLY if absent) + record port -------------------------------------
if [[ -z "$(get_env HONCHO_MCP_TOKEN '')" ]]; then
  tok="$(openssl rand -hex 24 2>/dev/null || node -e 'console.log(require("crypto").randomBytes(24).toString("hex"))')"
  set_env HONCHO_MCP_TOKEN "$tok"
  ok "Minted HONCHO_MCP_TOKEN in .env."
fi
[[ -n "$(get_env HONCHO_MCP_PORT '')" ]] || set_env HONCHO_MCP_PORT "$PORT"

# 3. offline smoke gate (mock honcho; no real honcho, no models) --------------------
log "Smoke: honcho-mcp offline test (tools + honcho-down + http token gate)…"
if ( cd "$SHIM_DIR" && node test.mjs >/dev/null 2>&1 ); then
  ok "Smoke passed."
else
  err "Phase 40 smoke failed (honcho-mcp/test.mjs) — not stamping."
  exit 1
fi

# 4. register the stdio MCP with the host Claude session (claude-cli) ----------------
# The shim defaults HONCHO_BASE_URL=http://honcho:8000 (resolves on the host alias) +
# workspace=default; stdio needs no token.
_mem_claude_register_stdio honcho node "$SHIM_DIR/bin.mjs" --stdio || true

# 5. start the http shim daemon (the fleet's path) ----------------------------------
if bash "$AI_STACK/bin/start-honcho_mcp.sh"; then :; else warn "honcho-mcp http daemon did not start cleanly (continuing; fleet wiring still recorded)."; fi

# 6. ATOMIC egress retirement — live-apply the (already-committed, retired) policies so the
#    running sandboxes lose raw :8000 NOW and hermes gains :7082 (mirrors Phase 27's backstop).
OSH="$(_mem_resolve_openshell)"
if [[ -n "$OSH" ]]; then
  _apply_policy() {  # <sandbox> <policy-file>
    local _sb="$1" _pf="$2"
    "$OSH" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | awk -v n="$_sb" 'NR>1 && $1==n{f=1} END{exit !f}' || return 0
    if "$OSH" policy set "$_sb" --policy "$_pf" --wait --timeout 60 </dev/null >/dev/null 2>&1; then
      ok "applied retired-honcho-egress policy to live sandbox $_sb (raw :8000 now denied)"
    else
      warn "live policy set for $_sb returned non-zero — re-apply via 'vz-ai-stack.sh install 04' (fleet) / 'install 15' (pi)"
    fi
  }
  _apply_policy "$SANDBOX" "$FLEET_POLICY"
  _apply_policy "pi-v1" "$PI_POLICY"
fi

# 7. wire the Hermes fleet to the shim (token-gated), if the sandbox is present ------
if [[ -n "$OSH" ]] && "$OSH" sandbox list 2>/dev/null | grep -q "$SANDBOX"; then
  configure_hermes_mcp_honcho "$OSH" "$SANDBOX" "$PORT" || warn "Hermes fleet honcho wiring incomplete (non-fatal; re-run 'install honcho_mcp')."
else
  note "Hermes fleet sandbox '$SANDBOX' not present — skipping fleet honcho wiring."
  note "  (It auto-wires on the next 'install 04f', gated on stamp_check 40.)"
fi

# pi honcho: pi's runtime ships no MCP client, so it is NOT wired here — it needs a dedicated
# pi extension (tracked with pi doc-RAG, slice 2b). pi's raw :8000 egress is still retired above.
note "pi honcho: deferred (pi has no MCP client; needs a pi extension) — its raw :8000 egress is retired regardless."

stamp_mark "$PHASE"
ok "Phase 40 (honcho_mcp) — claude-cli honcho wired; hermes fleet wired when present; raw honcho:8000 egress retired."
