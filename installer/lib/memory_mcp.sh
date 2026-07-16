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

# _mem_hermes_profile_wired <osh> <key> <endpoint> — is an MCP server wired into the fleet's
# hermes_manager profile?  Mirrors the doctor's OWN assertion EXACTLY (check 74 for docs,
# check 76 for falkordb): the profile's config.yaml carries `<key>:` AND `<endpoint>`.
# Keeping the installer's post-condition and the doctor's probe identical is the whole point
# — a phase must not stamp .done in a state the doctor will red-bar.
#
# Returns 0 (nothing to assert) when NO hermes-fleet-v1 sandbox is Ready — same lenience as
# checks 74/76, which only assert against a Ready fleet. Returns 1 (needs wiring) only when a
# Ready fleet sandbox is present but NOT wired.
#
# <endpoint> is NOT a literal: it is port-templated from FALKORDB_MCP_PORT / HONCHO_MCP_PORT,
# i.e. .env DATA. Interpolating it into the in-sandbox `bash -c` program therefore let a value
# like '$PORT' (or a backtick) expand INSIDE the sandbox, where it evaluates to empty — and
# `grep -q ""` matches ANY file, returning a FALSE "WIRED" for an UNWIRED fleet, silently
# defeating the callers' verify-then-stamp gate. Pass <key>/<endpoint> as ARGV ($1/$2) instead,
# exactly as doctor check 76 does, so "$HOME" still expands in the sandbox while the data does
# not. (Correctness, not a trust boundary: .env is 0600 and same-owner as this script.)
# NB: openshell's gRPC exec REJECTS newlines — keep the -c program on ONE line.
_mem_hermes_profile_wired() {
  local osh="$1" key="$2" endpoint="$3"
  [[ -n "$osh" ]] || return 0
  # Ready-gate. NB: this awk has NO early `exit`, so it drains stdin and cannot trip the
  # openshell EPIPE/pipefail race — see sandbox_present() in common.sh. Keep it that way.
  "$osh" sandbox list 2>/dev/null </dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
    | awk 'NR>1 && $1=="hermes-fleet-v1" && $NF=="Ready"{ok=1} END{exit !ok}' || return 0
  local wired
  wired="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 </dev/null -- bash -c \
    'f="$HOME/.hermes/profiles/hermes_manager/config.yaml"; [[ -f "$f" ]] && grep -q "$1:" "$f" && grep -q "$2" "$f" && echo WIRED || echo MISSING' \
    _ "$key" "$endpoint" 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
  [[ "$wired" == "WIRED" ]]
}

# _mem_hermes_docs_wired <osh> — hermes fleet doc-RAG wiring in place? (doctor check 74)
# Shared by Phase 39's precheck AND its verify-then-stamp post-condition.
_mem_hermes_docs_wired() { _mem_hermes_profile_wired "$1" docs "host.docker.internal:8765"; }

# _mem_hermes_falkordb_wired <osh> [port] — hermes fleet graph-memory wiring in place?
# (doctor check 76). Phase 41's verify-then-stamp post-condition.
# Port is a PARAMETER (default 7083) because Phase 41's port is configurable via
# FALKORDB_MCP_PORT — hardcoding it would hard-fail a custom-port install.
_mem_hermes_falkordb_wired() {
  _mem_hermes_profile_wired "$1" falkordb "host.docker.internal:${2:-7083}"
}

# _mem_hermes_honcho_wired <osh> [port] — hermes fleet honcho-memory wiring in place?
# (doctor check 75). Phase 40's precheck AND its verify-then-stamp post-condition — the same
# shape as its 39/41 siblings, which is the whole point: phase 40 had NO post-condition at all
# (an unconditional stamp_mark after `configure_hermes_mcp_honcho ... || warn`), and making
# honcho default-on ARMED that defect on every `install all --include-optionals`.
# Port is a PARAMETER (default 7082) for the same reason as falkordb's.
_mem_hermes_honcho_wired() {
  _mem_hermes_profile_wired "$1" honcho "host.docker.internal:${2:-7082}"
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
