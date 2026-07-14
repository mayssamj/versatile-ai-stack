# Fleet memory MCP wiring (opt-in Phase 39). GRACEFUL by design: when the phase has
# not been installed this returns 0 with a neutral skip note — it must NEVER red-bar a
# stack that simply didn't opt into fleet memory.
#
# When installed it verifies (fast, ALWAYS-ON):
#   - claude-cli: the host Claude session has both `mempalace` (verbatim recall) and
#     `docs-mcp` (doc-RAG search) registered;
#   - hermes-fleet: when a fleet sandbox is Ready, a representative profile carries the
#     `docs` MCP server pointing at :8765 (fleet doc-RAG wired). Mirrors check 49.
# With FLEET_MEMORY_DEEP_CHECK=1 it also asserts the ai-stack-docs Qdrant collection holds
# > 0 points — a registered-but-empty docs-mcp answers every query with nothing, the
# llm_guard-style false-green trap this check exists to avoid.
CHECKS+=(fleet_memory_mcp)
CHECK_TITLE[fleet_memory_mcp]="Fleet memory (opt-in): claude-cli + hermes-fleet MCP wiring (mempalace + doc-RAG); skip-clean when absent"

# Resolver kept as its own fn so the offline smoke can stub it to "" (skip the fleet probe).
_fm_resolve_openshell() {
  if [[ -x /opt/homebrew/bin/openshell ]]; then echo /opt/homebrew/bin/openshell
  elif command -v openshell >/dev/null 2>&1; then command -v openshell
  else echo ""
  fi
}

fleet_memory_mcp_diagnose() {
  # (0) Not installed → skip-clean (opt-in Phase 39; never red-bar).
  if ! compgen -G "$AI_STACK/installer/state/phase_39*.done" >/dev/null 2>&1; then
    echo "(fleet memory not installed — opt-in Phase 39: vz-ai-stack.sh install fleet_memory; skip)"
    return 0
  fi

  local fails=()

  # (1) claude-cli host MCPs (only if the claude CLI is present).
  if command -v claude >/dev/null 2>&1; then
    local listing; listing="$(claude mcp list 2>/dev/null)"
    grep -q '^mempalace[: ]' <<<"$listing" || fails+=("  claude-cli MCP 'mempalace' not registered — run: vz-ai-stack.sh install fleet_memory")
    grep -q '^docs-mcp[: ]'  <<<"$listing" || fails+=("  claude-cli MCP 'docs-mcp' not registered — run: vz-ai-stack.sh install fleet_memory")
  else
    echo "  (claude CLI not on PATH — skipping the claude-cli MCP checks)"
  fi

  # (2) hermes-fleet doc-RAG wiring — only when a fleet sandbox is Ready (else nothing to
  # wire yet). Per-profile probe of the committed config, like check 49.
  local osh; osh="$(_fm_resolve_openshell)"
  if [[ -n "$osh" ]] && "$osh" sandbox list 2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' \
       | awk 'NR>1 && $1=="hermes-fleet-v1" && $NF=="Ready"{ok=1} END{exit !ok}'; then
    local wired
    wired="$("$osh" sandbox exec -n hermes-fleet-v1 --no-tty --timeout 20 </dev/null -- bash -c \
      'f="$HOME/.hermes/profiles/hermes_manager/config.yaml"; [[ -f "$f" ]] && grep -q "docs:" "$f" && grep -q "host.docker.internal:8765" "$f" && echo WIRED || echo MISSING' \
      2>/dev/null | sed $'s/\x1b\\[[0-9;]*m//g' | tr -d '[:space:]')"
    [[ "$wired" == "WIRED" ]] || fails+=("  hermes_manager profile NOT wired to doc-RAG MCP (got '${wired:-no-response}') — run: vz-ai-stack.sh install fleet_memory")
  fi

  # (DEEP) doc-RAG corpus actually POPULATED? A registered-but-empty docs-mcp answers
  # every query with nothing (the llm_guard false-green). ingestor/ingest.py creates the
  # ai-stack-docs collection BEFORE inserting points, so on-disk existence != non-empty —
  # ask Qdrant for the real point count instead of globbing the collections dir.
  if [[ "${FLEET_MEMORY_DEEP_CHECK:-0}" == "1" ]]; then
    local qurl="http://qdrant:6333/collections/ai-stack-docs" body pts
    body="$(curl -s --max-time 4 "$qurl" 2>/dev/null || true)"
    pts="$(printf '%s' "$body" | python3 -c 'import sys,json; print(json.load(sys.stdin)["result"]["points_count"])' 2>/dev/null || true)"
    if [[ -z "$body" ]]; then
      fails+=("  DEEP: Qdrant unreachable at $qurl — start it: vz-ai-stack.sh start qdrant")
    elif [[ -z "$pts" ]]; then
      fails+=("  DEEP: ai-stack-docs collection absent at Qdrant (doc-RAG returns nothing) — populate: cd $AI_STACK/ingestor && python ingest.py")
    elif [[ "$pts" == "0" ]]; then
      fails+=("  DEEP: ai-stack-docs collection holds 0 points (doc-RAG returns nothing) — populate: cd $AI_STACK/ingestor && python ingest.py")
    fi
  else
    echo "  (static wiring check only; set FLEET_MEMORY_DEEP_CHECK=1 to assert the doc-RAG corpus is populated)"
  fi

  if (( ${#fails[@]} > 0 )); then
    printf '%s\n' "${fails[@]}"
    return 1
  fi
  return 0
}

fleet_memory_mcp_fix() {
  warn "Fleet memory not fully wired for claude-cli. Wire MemPalace recall + doc-RAG search:"
  warn "    vz-ai-stack.sh install fleet_memory"
  warn "Enable MemPalace auto-capture (opt-in, changes live behavior):"
  warn "    bin/mempalace-hooks install --apply"
  return 1
}
