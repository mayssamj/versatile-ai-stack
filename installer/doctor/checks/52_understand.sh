# Understand-Anything (Phase 30): the understand-mcp graph-query server. OPT-IN —
# skips clean when Phase 30 hasn't run. The framework is binary PASS/FAIL (no WARN),
# so the council's 3-state intent maps as:
#   • not installed (no stamp)          → PASS + "skipping" (opt-in, green)
#   • installed, plugin/shim broken     → FAIL (re-install)
#   • installed, no graph committed yet  → PASS + actionable note (do NOT red-bar a
#                                          user who hasn't run /understand yet)
#   • installed + graph present          → TRUE E2E: a real headless query must answer;
#                                          FAIL only on a real query failure. Staleness
#                                          (graph commit vs HEAD) is surfaced as a note.
CHECKS+=(understand)
CHECK_TITLE[understand]="understand-mcp answers a real graph query (Phase 30)"

understand_diagnose() {
  # compgen -G (not `ls`) — doctor.sh runs under nullglob.
  if ! compgen -G "$AI_STACK/installer/state/phase_30*.done" >/dev/null 2>&1; then
    echo "Understand-Anything not installed in this stack — Phase 30 (opt-in) hasn't run yet (skipping)"
    return 0
  fi

  local link="$HOME/.understand-anything-plugin"
  [[ -f "$link/packages/core/dist/index.js" ]] || { echo "plugin core not built ($link/packages/core/dist) — re-run 'vz-ai-stack.sh install understand'"; return 1; }
  [[ -d "$AI_STACK/understand-mcp/node_modules/@modelcontextprotocol/sdk" ]] || { echo "understand-mcp deps missing — re-run 'vz-ai-stack.sh install understand'"; return 1; }

  if [[ ! -f "$AI_STACK/.understand-anything/knowledge-graph.json" ]]; then
    echo "Installed, but no knowledge graph committed yet. Generate it from the MAIN checkout:"
    echo "  cd $AI_STACK && /understand .   then commit .understand-anything/knowledge-graph.json"
    return 0   # non-blocking (WARN-equivalent): not a failure, just not generated yet
  fi

  # TRUE E2E: load the graph + run a real query through the actual code path.
  local out
  # NB: AI_STACK_LIB must be an ENV prefix BEFORE `node` — placed after `node -e '…'`
  # it becomes argv (process.argv), not process.env, and the import would be undefined.
  out="$(UNDERSTAND_PLUGIN_ROOT="$link" UNDERSTAND_GRAPH_ROOT="$AI_STACK" AI_STACK_LIB="$AI_STACK/understand-mcp/lib.mjs" node -e '
    import("file://"+process.env.AI_STACK_LIB).then(async (m)=>{
      const s=await new m.GraphState().load();
      const r=m.TOOLS.project_summary(s);
      if(!s.ok()||!r.name){ console.error("QUERY_FAIL:"+(s.error||"no project name")); process.exit(1); }
      console.log("OK name="+r.name+" nodes="+r.counts.nodes+" | "+(r.staleness||""));
    }).catch(e=>{ console.error("QUERY_FAIL:"+e.message); process.exit(1); });
  ' 2>&1)" || { echo "graph query FAILED: $out — re-run 'install understand' or regenerate the graph"; return 1; }
  echo "$out"

  # Bonus: surface http daemon + staleness, non-blocking.
  if [[ -n "$out" && "$out" == *"STALE"* ]]; then
    echo "  (graph is stale vs HEAD — re-run '/understand .' on material drift)"
  fi
  local port; port="$(get_env UNDERSTAND_MCP_PORT '7081' 2>/dev/null || echo 7081)"
  if curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:$port/healthz" 2>/dev/null | grep -q '^200$'; then
    echo "  http daemon healthy on :$port (fleet-reachable via host.docker.internal:$port)"
  else
    echo "  http daemon not running (start with 'vz-ai-stack.sh start understand' for fleet access)"
  fi
  return 0
}

understand_fix() {
  echo "vz-ai-stack.sh install understand   # rebuild plugin core + shim, re-register MCP, restart daemon"
}
