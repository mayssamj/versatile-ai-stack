#!/usr/bin/env bash
# understand-dashboard.sh — launch the Understand-Anything interactive dashboard for a
# repo's committed knowledge graph. Foreground serve (Ctrl-C to stop), like
# tutorial-serve / fleet-studio.
#
# The dashboard is a Vite app whose graph/file-content endpoints + token gate live in
# Vite middleware (configureServer) — so we run Vite (not a plain static server) from
# the plugin's packages/dashboard with GRAPH_DIR pointed at the target repo. Vite
# generates a one-time access token, prints the tokenised URL, and opens the browser.
#
# Usage: understand-dashboard.sh [repo-path] [--no-open] [--port N]
set -Eeuo pipefail
AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AI_STACK/installer/lib/common.sh"

GRAPH_DIR="$AI_STACK"
NO_OPEN=0
PORT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-open) NO_OPEN=1 ;;
    --port)    shift; PORT="${1:-}" ;;
    --port=*)  PORT="${1#--port=}" ;;
    -*)        : ;;
    *)         GRAPH_DIR="$(cd "$1" 2>/dev/null && pwd || echo "$1")" ;;
  esac
  shift
done

# Resolve plugin root (stable symlink preferred; cache fallback).
PLUGIN_ROOT="${UNDERSTAND_PLUGIN_ROOT:-$HOME/.understand-anything-plugin}"
if [[ ! -d "$PLUGIN_ROOT/packages/dashboard" ]]; then
  base="$HOME/.claude/plugins/cache/understand-anything/understand-anything"
  if [[ -d "$base" ]]; then
    v="$(ls "$base" 2>/dev/null | grep -E '^[0-9]' | sort -r | head -1)"
    [[ -n "$v" ]] && PLUGIN_ROOT="$base/$v"
  fi
fi
DASH="$PLUGIN_ROOT/packages/dashboard"
[[ -d "$DASH" ]] || { err "dashboard not found under $PLUGIN_ROOT — run 'mayssam-ai-stack.sh install understand'"; exit 1; }

if [[ ! -f "$GRAPH_DIR/.understand-anything/knowledge-graph.json" ]]; then
  err "No knowledge graph at $GRAPH_DIR/.understand-anything/knowledge-graph.json"
  note "Generate it first (from the MAIN checkout):  cd $GRAPH_DIR && /understand ."
  exit 1
fi

if [[ ! -d "$DASH/node_modules" ]]; then
  warn "dashboard deps not installed — running pnpm install (first run can take a few min)…"
  ( cd "$PLUGIN_ROOT" && pnpm install --frozen-lockfile ) || { err "pnpm install failed"; exit 1; }
fi

log "Serving Understand-Anything dashboard for: $GRAPH_DIR"
note "Graph: $GRAPH_DIR/.understand-anything/knowledge-graph.json"
note "Ctrl-C to stop."
export GRAPH_DIR
args=(run dev --)
[[ -n "$PORT" ]] && args+=(--port "$PORT")
(( NO_OPEN )) && export NO_OPEN=1   # vite.config honors open; we hint via env where supported
exec npm --prefix "$DASH" "${args[@]}"
