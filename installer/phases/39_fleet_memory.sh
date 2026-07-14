#!/usr/bin/env bash
# Phase 39 — Fleet Memory (OPT-IN; wire the memory subsystems to fleet consumers).
#
# NOT in `install all` — install by name:  vz-ai-stack.sh install fleet_memory
# (auto-opt-in: any phase file outside install_all_phase_order is opt-in; resolvable
# by name via *_fleet_memory.sh — `memory` alone is already the alt_memory alias).
#
# GOAL (per §24 council 2026-07-13 + operator decisions): make each memory subsystem
# usable by each fleet consumer, not merely running. This is built in reviewed slices:
#   claude-cli  : MemPalace verbatim recall + doc-RAG search  ← THIS SLICE
#   pi / hermes : doc-RAG + honcho (host-side scoped MCP gateway)   ← later slices
#   falkordb    : minimal graph-memory MCP                          ← later slice (gated)
#
# SAFE UNDER BLANKET `install all --include-optionals`: there is no exclude list, so
# this phase is written to be a harmless no-op when its inputs are absent — the
# claude-cli cells only add read tools to the OPERATOR'S OWN Claude session (reversible,
# not a security-posture change), and the security-sensitive sandbox/honcho cells
# (later slices) will be gated behind explicit opt-in env flags so a blanket run never
# silently wires sandbox egress or cross-consumer memory (council must-fix #8).
#
# What THIS slice does (idempotent, reversible):
#   1. register the MemPalace 29-tool stdio MCP (`mempalace-mcp`) with the host Claude
#      session  → verbatim conversation recall as a tool.
#   2. register the doc-RAG HTTP MCP (`docs-mcp` on :8765) with the host Claude session
#      → `search_documents` over the ai-stack-docs Qdrant collection.
#   3. print (does NOT auto-apply) the MemPalace auto-capture opt-in — Stop/PreCompact
#      hooks change live harness behavior, so per the stack constitution they are never
#      wired during install; the operator runs `bin/mempalace-hooks install --apply`.
#
# Rollback:
#   claude mcp remove -s user mempalace ; claude mcp remove -s user docs-mcp
#   bin/mempalace-hooks uninstall --apply   (if auto-capture was opted into)
#   rm installer/state/phase_39.done
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"
source "$AI_STACK/installer/lib/env.sh"
source "$AI_STACK/installer/lib/worktree.sh"
source "$AI_STACK/installer/lib/memory_mcp.sh"
source "$AI_STACK/installer/lib/mcp.sh"          # configure_hermes_mcp_docs (untokened doc-RAG)

PHASE=39
NAME=fleet_memory
# docs-mcp port is hardcoded 8765 in its server + launcher (single source of truth:
# ingestor/mcp_server.py + bin/start-docs_mcp.sh); mirror it here, don't invent an env var.
DOCS_MCP_PORT=8765
MEMPALACE_MCP_WRAPPER="$AI_STACK/bin/mempalace-mcp"

# precheck: claude-cli cells already registered?  (claude absent → nothing to verify;
# rely on the stamp for the skip so the phase still runs once to print guidance.)
# `claude mcp list` does live per-server health probing, so call it ONCE.
precheck() {
  # claude-cli MCPs (skip this part when claude is absent).
  if command -v claude >/dev/null 2>&1; then
    local listing; listing="$(claude mcp list 2>/dev/null)"
    grep -q '^mempalace[: ]' <<<"$listing" || return 1
    grep -q '^docs-mcp[: ]'  <<<"$listing" || return 1
  fi
  # ALSO require hermes-fleet doc-RAG wiring IF a fleet sandbox is Ready — otherwise a
  # re-run after the fleet was built later would skip before the hermes block ever runs.
  # (Returns ok when no fleet sandbox is Ready — nothing to wire yet.)
  _mem_hermes_docs_wired "$(_mem_resolve_openshell)"
}

if precheck 2>/dev/null && stamp_check "$PHASE"; then
  ok "Phase 39 (fleet_memory) already wired (claude-cli + hermes-fleet where a fleet sandbox is present) — skipping. (Re-run 'reset' first to rewire.)"
  exit 0
fi

worktree_guard "install fleet_memory"

log "Wiring fleet memory — claude-cli consumer (host MCP registrations)…"

# 1. claude-cli · MemPalace verbatim recall (29-tool stdio MCP) ----------------------
# Register the bin/mempalace-mcp WRAPPER, not the raw `mempalace-mcp` binary: the wrapper
# injects the on-device-embedding + LiteLLM-refiner env (OPENAI_*/LLM_*/MEMPALACE_EMBEDDING_*)
# that the raw server otherwise starts without — reading the minted key from .env at runtime
# so no secret is baked into ~/.claude.json. Guard on the REAL server binary being installed
# (Phase 26); the committed wrapper is always present.
if [[ -x "$HOME/.local/bin/mempalace-mcp" ]] || command -v mempalace-mcp >/dev/null 2>&1; then
  if [[ -x "$MEMPALACE_MCP_WRAPPER" ]]; then
    _mem_claude_register_stdio mempalace "$MEMPALACE_MCP_WRAPPER" || true
  else
    warn "bin/mempalace-mcp wrapper missing — expected at $MEMPALACE_MCP_WRAPPER (re-checkout the branch)."
  fi
else
  note "MemPalace not installed (no mempalace-mcp binary) — install it first: vz-ai-stack.sh install 26"
  note "  then re-run: vz-ai-stack.sh install fleet_memory"
fi

# 2. claude-cli · doc-RAG search (docs-mcp HTTP on the host loopback) ----------------
# Registration is declarative config; the server may be started later and the
# ai-stack-docs collection may still be empty (docs-RAG then returns nothing until
# `cd ingestor && python ingest.py` has populated it — see doctor check 74 DEEP probe).
_mem_claude_register_http docs-mcp "http://localhost:${DOCS_MCP_PORT}/mcp" || true

# 3. MemPalace auto-capture (opt-in — NOT auto-applied; changes live harness behavior) --
note "MemPalace auto-capture (Stop/PreCompact hooks) is OPT-IN — it changes live session"
note "behavior, so it is not auto-wired. Enable when ready:"
note "  bin/mempalace-hooks install --apply            # repo-local .claude/settings.local.json"
note "  bin/mempalace-hooks install --apply --global   # ~/.claude/settings.json"
note "  bin/mempalace-hooks status | uninstall --apply # inspect / roll back"

# 4. hermes-fleet · doc-RAG search (untokened docs-mcp) ------------------------------
# Egress to :8765 already ships in hermes-fleet-v1.yaml; wire it per-profile if a fleet
# sandbox exists now. A fleet built/rebuilt LATER is covered by 04f, which re-wires docs
# gated on `stamp_check 39` (stays opt-in but survives rebuilds).
OSH_BIN="$(_mem_resolve_openshell)"   # brew-first (avoids the uv-tool-shadow relay outage)
HERMES_SB="hermes-fleet-v1"
if [[ -n "$OSH_BIN" ]] && "$OSH_BIN" sandbox list 2>/dev/null | grep -q "$HERMES_SB"; then
  configure_hermes_mcp_docs "$OSH_BIN" "$HERMES_SB" "$DOCS_MCP_PORT" || warn "Hermes fleet doc-RAG wiring incomplete (non-fatal)."
else
  note "Hermes fleet sandbox '$HERMES_SB' not present — skipping fleet doc-RAG wiring."
  note "  (Install the fleet, then re-run 'install fleet_memory'; or it auto-wires on the next 'install 04f'.)"
fi

# pi sandbox doc-RAG: pi's runtime ships NO MCP client, so it needs a dedicated pi
# extension that bridges to docs-mcp — tracked as a separate slice; not wired here yet.

stamp_mark "$PHASE"
ok "Phase 39 (fleet_memory) — claude-cli memory wired; hermes-fleet doc-RAG wired when the fleet sandbox is present."
