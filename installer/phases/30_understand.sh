#!/usr/bin/env bash
# Phase 30 — Understand-Anything (OPT-IN; cross-runtime codebase knowledge graphs).
#
# NOT in `install all` — install by name: `vz-ai-stack.sh install understand`.
# Architecture = "generate centrally, consume everywhere" (spec:
# docs/superpowers/specs/2026-06-21-understand-anything-phase29-design.md, §24-vetted):
#   GENERATE  /understand (Claude Code or Pi) writes .understand-anything/
#             knowledge-graph.json → you COMMIT it (the shared artifact).
#   CONSUME   the net-new host `understand-mcp` server (understand-mcp/) wraps the
#             plugin's headless query core and serves the graph as MCP tools over:
#               • stdio  → host Claude Code + Pi   (claude mcp add -s user)
#               • http   → the Hermes fleet        (host.docker.internal:7081, wired
#                          per-profile via lib/mcp.sh, token-gated, like Sourcegraph)
#
# What this phase does (idempotent, reversible):
#   1. precheck Node ≥22 + pnpm; refuse to operate the live stack from a worktree
#   2. resolve the plugin root; create the stable ~/.understand-anything-plugin symlink
#   3. build the plugin core (marketplace path ships no dist/) — pnpm install + build
#   4. build the shim (npm install in understand-mcp/)  [node_modules gitignored]
#   5. mint UNDERSTAND_MCP_TOKEN in .env (once); register the stdio MCP with Claude Code
#   6. start the http daemon (bin/start-understand.sh) + wire the Hermes fleet (gated)
#   7. smoke-gate (offline shim test) → stamp
#
# Rollback: claude mcp remove -s user understand-anything ; vz-ai-stack.sh stop
#   understand ; rm -rf understand-mcp/node_modules ; stamp_clear 29 ; (un-wire
#   profiles: `hermes config unset mcp_servers.understand` per profile).
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/worktree.sh"
source "$AI_STACK/installer/lib/mcp.sh"

PHASE=30
NAME=understand
PLUGIN_LINK="$HOME/.understand-anything-plugin"
SHIM_DIR="$AI_STACK/understand-mcp"
MCP_PORT="$(get_env UNDERSTAND_MCP_PORT '7081')"

# --- resolve the installed plugin root (never the version-pinned cache path) ---------
resolve_plugin_root() {
  local c
  for c in "${UNDERSTAND_PLUGIN_ROOT:-}" "$PLUGIN_LINK" \
           "$HOME/.claude/plugins/marketplaces/understand-anything/understand-anything-plugin"; do
    [[ -n "$c" && -f "$c/packages/core/package.json" ]] && { echo "$c"; return 0; }
  done
  local base="$HOME/.claude/plugins/cache/understand-anything/understand-anything" v
  if [[ -d "$base" ]]; then
    v="$(ls "$base" 2>/dev/null | grep -E '^[0-9]' | sort -r | head -1)"
    [[ -n "$v" && -f "$base/$v/packages/core/package.json" ]] && { echo "$base/$v"; return 0; }
  fi
  return 1
}

# --- precheck: built plugin + shim deps + stdio registered + token → already done ---
precheck() {
  [[ -f "$PLUGIN_LINK/packages/core/dist/index.js" ]] || return 1
  [[ -d "$SHIM_DIR/node_modules/@modelcontextprotocol/sdk" ]] || return 1
  [[ -n "$(get_env UNDERSTAND_MCP_TOKEN '')" ]] || return 1
  # If claude is present, the stdio MCP must be registered; if claude is absent we
  # can't (and didn't) register it, so don't force a re-run on that account.
  if command -v claude >/dev/null 2>&1; then
    claude mcp list 2>/dev/null | grep -q '^understand-anything' || return 1
  fi
  return 0
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 30 (understand) already installed — skipping. (Re-run with 'reset' first to rebuild.)"
  exit 0
fi

worktree_guard "install understand"

# 1. prechecks ----------------------------------------------------------------------
command -v node >/dev/null 2>&1 || { err "Node not found. Run 'vz-ai-stack.sh deps' (installs node@22)."; exit 1; }
case "$(node --version)" in v2[2-9].*|v[3-9][0-9].*) : ;; *) err "Node ≥22 required (have $(node --version)). Run 'vz-ai-stack.sh deps'."; exit 1 ;; esac
command -v pnpm >/dev/null 2>&1 || { err "pnpm not found. Run 'vz-ai-stack.sh deps' (installs pnpm)."; exit 1; }

# 2. plugin root + stable symlink ---------------------------------------------------
PLUGIN_ROOT="$(resolve_plugin_root)" || { err "Understand-Anything plugin not found. Install it in Claude Code first: /plugin marketplace add Egonex-AI/Understand-Anything"; exit 1; }
log "Plugin root: $PLUGIN_ROOT"
if [[ "$(readlink "$PLUGIN_LINK" 2>/dev/null)" != "$PLUGIN_ROOT" ]]; then
  rm -f "$PLUGIN_LINK"; ln -s "$PLUGIN_ROOT" "$PLUGIN_LINK"
  ok "Linked $PLUGIN_LINK → $PLUGIN_ROOT"
fi
export UNDERSTAND_PLUGIN_ROOT="$PLUGIN_LINK"

# 3. build the plugin core (marketplace path has no dist/) ---------------------------
if [[ ! -f "$PLUGIN_LINK/packages/core/dist/index.js" ]]; then
  log "Building @understand-anything/core (first run can take 3–5 min — tree-sitter native builds)…"
  # NOT --frozen-lockfile: the upstream marketplace copy can ship a pnpm-lock.yaml that
  # diverges from its package.json (observed live: vite ^6.0.0 vs ^6.4.2), which we do
  # not control — frozen hard-fails a clean install. A lenient install reconciles it.
  # set -o pipefail inside the subshell so a failing pnpm isn't masked by `tail`.
  ( cd "$PLUGIN_LINK" && set -o pipefail && pnpm install 2>&1 | tail -8 ) \
    || { err "pnpm install failed in plugin root ($PLUGIN_LINK) — see output above."; exit 1; }
  ( cd "$PLUGIN_LINK" && set -o pipefail && pnpm --filter @understand-anything/core run build 2>&1 | tail -8 ) \
    || { err "pnpm build of @understand-anything/core failed — see output above."; exit 1; }
  [[ -f "$PLUGIN_LINK/packages/core/dist/index.js" ]] || { err "core build produced no dist/index.js"; exit 1; }
  ok "core built."
else
  ok "core already built (dist/index.js present)."
fi

# 4. build the shim -----------------------------------------------------------------
log "Installing understand-mcp shim deps…"
( cd "$SHIM_DIR" && npm install --no-audit --no-fund 2>&1 | tail -4 )
[[ -d "$SHIM_DIR/node_modules/@modelcontextprotocol/sdk" ]] || { err "shim deps missing after npm install"; exit 1; }

# 5. token + stdio MCP registration -------------------------------------------------
if [[ -z "$(get_env UNDERSTAND_MCP_TOKEN '')" ]]; then
  tok="$(openssl rand -hex 24 2>/dev/null || node -e 'console.log(require("crypto").randomBytes(24).toString("hex"))')"
  set_env UNDERSTAND_MCP_TOKEN "$tok"
  ok "Minted UNDERSTAND_MCP_TOKEN in .env."
fi
[[ -n "$(get_env UNDERSTAND_MCP_PORT '')" ]] || set_env UNDERSTAND_MCP_PORT "$MCP_PORT"

if command -v claude >/dev/null 2>&1; then
  # Idempotent: remove-then-add (claude mcp add appends, it does not dedupe).
  claude mcp remove -s user understand-anything >/dev/null 2>&1 || true
  if claude mcp add -s user understand-anything \
        --env "UNDERSTAND_PLUGIN_ROOT=$PLUGIN_LINK" \
        -- node "$SHIM_DIR/bin.mjs" --stdio >/dev/null 2>&1; then
    ok "Registered stdio MCP 'understand-anything' (user scope) with Claude Code."
  else
    warn "Could not register the stdio MCP with Claude Code (claude mcp add failed) — register manually."
  fi
else
  note "claude CLI not on PATH — skipping stdio MCP registration. Register later with:"
  note "  claude mcp add -s user understand-anything --env UNDERSTAND_PLUGIN_ROOT=$PLUGIN_LINK -- node $SHIM_DIR/bin.mjs --stdio"
fi

# 6. start the http daemon + wire the Hermes fleet (both gated/non-fatal) ------------
if bash "$AI_STACK/bin/start-understand.sh"; then :; else warn "understand-mcp http daemon did not start cleanly (continuing; fleet wiring still recorded)."; fi

OSH="$(command -v openshell || true)"
SB="hermes-fleet-v1"
if [[ -n "$OSH" ]] && "$OSH" sandbox list 2>/dev/null | grep -q "$SB"; then
  configure_hermes_mcp_understand "$OSH" "$SB" "$MCP_PORT" || warn "Hermes fleet wiring incomplete (non-fatal)."
else
  note "Hermes fleet sandbox '$SB' not present — skipping fleet wiring (install the fleet, then re-run 'install understand')."
fi

# 7. smoke-gate (offline shim test) → stamp -----------------------------------------
log "Smoke: running understand-mcp offline test (graph load + tools + http E2E)…"
if ( cd "$SHIM_DIR" && UNDERSTAND_PLUGIN_ROOT="$PLUGIN_LINK" node test.mjs >/dev/null 2>&1 ); then
  ok "Smoke passed."
else
  err "Phase 30 smoke failed (understand-mcp/test.mjs) — not stamping."
  exit 1
fi

stamp_mark "$PHASE"
ok "Phase 30 (understand) installed."
echo
note "Generate the graph (from the MAIN checkout):  cd $AI_STACK && /understand ."
note "Then commit .understand-anything/knowledge-graph.json (the shared artifact)."
note "Query: in Claude Code use the 'understand-anything' MCP tools (graph_search, read_node_source, …)."
note "Fleet E2E proof:  vz-ai-stack.sh test understand"
note "Dashboard:        vz-ai-stack.sh understand-dashboard"
note "Docs:             doc/UNDERSTAND.md"
