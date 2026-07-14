#!/usr/bin/env bash
# installer/lib/memory_mcp.sh — shared wiring helpers for the fleet-memory phase
# (Phase 39). Mirrors installer/lib/mcp.sh (sourcegraph/understand) but for the
# memory subsystems: MemPalace (verbatim recall) + doc-RAG (qdrant/docs-mcp), and
# later honcho/falkordb via the host-side memory-MCP gateway family.
#
# This file holds the HOST-CLAUDE ("claude-cli" consumer) registration helpers.
# House style (per installer/phases/30_understand.sh) registers host MCPs inline via
# `claude mcp add -s user`; these helpers just DRY the idempotent remove-then-add so
# every memory cell (mempalace, docs-mcp, and future honcho-mcp/falkordb-mcp) wires
# the same way. Sandbox (pi / hermes-fleet) wiring reuses installer/lib/mcp.sh's
# per-profile `hermes config set` pattern and lands with the honcho slice.
#
# Assumes the caller has already sourced installer/lib/common.sh (log/ok/warn/note).
[[ -n "${_AI_STACK_MEMORY_MCP_SH:-}" ]] && return 0
_AI_STACK_MEMORY_MCP_SH=1

# _mem_resolve_openshell — brew-first openshell path. A bare `command -v openshell` can
# resolve to a uv-tool shadow in ~/.local/bin at a different version than the running
# gateway (documented ROOT CAUSE of the 2026-06-06 04f relay outage — see
# installer/phases/04f_hermes_fleet.sh). Prefer the brew binary, like every other
# sandbox-touching site (04f, doctor checks 49/74, lib/fleet.sh, lib/hermes.sh).
_mem_resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""
  fi
}

# _mem_hermes_docs_wired <osh> — is the hermes fleet's doc-RAG wiring in place?
# Returns 0 (nothing to do) when NO hermes-fleet-v1 sandbox is Ready OR when a Ready
# sandbox already carries the `docs` MCP server; returns 1 (needs wiring) only when a
# Ready fleet sandbox is present but NOT wired. Shared by Phase 39 precheck (mirrors the
# doctor check-74 probe) so a re-run after the fleet appears actually re-wires it.
_mem_hermes_docs_wired() {
  local osh="$1"
  [[ -n "$osh" ]] || return 0
  "$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk 'NR>1 && $1=="hermes-fleet-v1" && $NF=="Ready"{ok=1} END{exit !ok}' || return 0
  local wired
  wired="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 </dev/null -- bash -c \
    'f="$HOME/.hermes/profiles/hermes_manager/config.yaml"; [[ -f "$f" ]] && grep -q "docs:" "$f" && grep -q "host.docker.internal:8765" "$f" && echo WIRED || echo MISSING' \
    2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
  [[ "$wired" == "WIRED" ]]
}

# _mem_claude_register_stdio <name> <cmd> [args...]
# Idempotent user-scope stdio MCP registration for the host Claude session.
# claude-absent → skip non-fatal (print the manual command). Returns 0 on wired/skip,
# 1 only when `claude mcp add` actually failed.
_mem_claude_register_stdio() {
  local name="$1"; shift
  if ! command -v claude >/dev/null 2>&1; then
    note "claude CLI not on PATH — skip registering '$name'. Register later:"
    note "  claude mcp add -s user $name -- $*"
    return 0
  fi
  # remove-then-add: `claude mcp add` appends (does not dedupe), so removing first
  # keeps re-runs idempotent.
  claude mcp remove -s user "$name" >/dev/null 2>&1 || true
  if claude mcp add -s user "$name" -- "$@" >/dev/null 2>&1; then
    ok "Registered stdio MCP '$name' (user scope) with Claude Code."
    return 0
  fi
  warn "Could not register stdio MCP '$name' with Claude Code — register manually:"
  warn "  claude mcp add -s user $name -- $*"
  return 1
}

# _mem_claude_register_http <name> <url> [header]
# Idempotent user-scope HTTP MCP registration for the host Claude session.
_mem_claude_register_http() {
  local name="$1" url="$2" header="${3:-}"
  if ! command -v claude >/dev/null 2>&1; then
    note "claude CLI not on PATH — skip registering '$name'. Register later:"
    note "  claude mcp add -s user --transport http $name $url"
    return 0
  fi
  claude mcp remove -s user "$name" >/dev/null 2>&1 || true
  local -a args=(mcp add -s user --transport http "$name" "$url")
  [[ -n "$header" ]] && args+=(--header "$header")
  if claude "${args[@]}" >/dev/null 2>&1; then
    ok "Registered http MCP '$name' → $url (user scope) with Claude Code."
    return 0
  fi
  warn "Could not register http MCP '$name' with Claude Code — register manually:"
  warn "  claude mcp add -s user --transport http $name $url${header:+ --header \"$header\"}"
  return 1
}
