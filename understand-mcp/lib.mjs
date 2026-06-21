// understand-mcp — shared logic: plugin/graph resolution, graph loading, and the
// read-only query tools that wrap @understand-anything/core. Designed to be headless
// (zero LLM, zero network) and to NEVER throw at startup — a missing/invalid graph
// degrades to a clear per-tool error, so registering this server (-s user) is safe in
// repos that have no knowledge graph.
//
// Resolution (all overridable by env, so the installer/launcher controls them):
//   UNDERSTAND_PLUGIN_ROOT  — plugin root (contains packages/core/dist/index.js)
//   UNDERSTAND_GRAPH_ROOT   — project root containing .understand-anything/  (graph + source)
//   UNDERSTAND_GRAPH_FILE   — direct path to a knowledge-graph.json (testing/fixtures)
//   UNDERSTAND_SOURCE_ROOT  — root the source files live under (defaults to GRAPH_ROOT)

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { join, resolve, isAbsolute, sep } from "node:path";
import { homedir } from "node:os";
import { pathToFileURL } from "node:url";
import { execFileSync } from "node:child_process";

// ── plugin root resolution (never hardcode the version-pinned cache path) ──────────
export function resolvePluginRoot() {
  const candidates = [];
  if (process.env.UNDERSTAND_PLUGIN_ROOT) candidates.push(process.env.UNDERSTAND_PLUGIN_ROOT);
  candidates.push(join(homedir(), ".understand-anything-plugin"));
  // Last-resort: newest versioned dir in the Claude Code plugin cache.
  const cacheBase = join(homedir(), ".claude", "plugins", "cache", "understand-anything", "understand-anything");
  if (existsSync(cacheBase)) {
    try {
      const versions = readdirSync(cacheBase).filter((v) => /^\d/.test(v)).sort().reverse();
      for (const v of versions) candidates.push(join(cacheBase, v));
    } catch { /* ignore */ }
  }
  for (const c of candidates) {
    if (c && existsSync(join(c, "packages", "core", "dist", "index.js"))) return c;
  }
  return null;
}

// ── dynamic import of the built core (Node walks up to core/node_modules for deps) ──
let _core = null;
export async function loadCore() {
  if (_core) return _core;
  const root = resolvePluginRoot();
  if (!root) throw new Error("understand-anything plugin not found (set UNDERSTAND_PLUGIN_ROOT or run `vz-ai-stack.sh install understand`)");
  const entry = pathToFileURL(join(root, "packages", "core", "dist", "index.js")).href;
  _core = await import(entry);
  return _core;
}

// ── graph state (loaded once; reloadable) ─────────────────────────────────────────
export class GraphState {
  constructor() {
    this.graph = null;
    this.engine = null;
    this.error = null;
    this.sourceRoot = null;
    this.loadedFrom = null;
  }

  async load() {
    this.graph = null; this.engine = null; this.error = null;
    try {
      const core = await loadCore();
      const fileOverride = process.env.UNDERSTAND_GRAPH_FILE;
      const graphRoot = process.env.UNDERSTAND_GRAPH_ROOT || process.cwd();
      this.sourceRoot = process.env.UNDERSTAND_SOURCE_ROOT || graphRoot;

      if (fileOverride) {
        // Direct file (fixtures/tests): validate via core, no .understand-anything wrapper.
        if (!existsSync(fileOverride)) throw new Error(`UNDERSTAND_GRAPH_FILE not found: ${fileOverride}`);
        const raw = JSON.parse(readFileSync(fileOverride, "utf8"));
        const v = core.validateGraph ? core.validateGraph(raw) : { success: true, data: raw };
        this.graph = v.success && v.data ? v.data : raw;
        this.loadedFrom = fileOverride;
      } else {
        const g = core.loadGraph(graphRoot, { validate: false });
        if (!g) throw new Error(`no knowledge graph at ${join(graphRoot, ".understand-anything", "knowledge-graph.json")} — run \`/understand .\` and commit it`);
        this.graph = g;
        this.loadedFrom = join(graphRoot, ".understand-anything", "knowledge-graph.json");
      }
      this.engine = new core.SearchEngine(this.graph.nodes);
    } catch (e) {
      this.error = e.message || String(e);
    }
    return this;
  }

  ok() { return this.graph && !this.error; }
  nodeById(id) { return this.graph?.nodes.find((n) => n.id === id) || null; }
}

// ── tool implementations (pure; return plain JS objects) ──────────────────────────
function hydrate(node) {
  if (!node) return null;
  return {
    id: node.id, name: node.name, type: node.type,
    filePath: node.filePath, lineRange: node.lineRange,
    summary: node.summary, tags: node.tags, complexity: node.complexity,
  };
}

export const TOOLS = {
  graph_search(state, { query, limit }) {
    if (!state.ok()) return { error: state.error };
    const hits = state.engine.search(query, { limit: limit || 10 });
    return {
      query,
      results: hits.map((h) => {
        const n = state.nodeById(h.nodeId);
        return { ...hydrate(n), score: Number(h.score?.toFixed?.(4) ?? h.score) };
      }).filter((r) => r.id),
    };
  },

  get_node(state, { id, neighbors }) {
    if (!state.ok()) return { error: state.error };
    const node = state.nodeById(id);
    if (!node) return { error: `node not found: ${id}` };
    const edges = state.graph.edges
      .filter((e) => e.source === id || e.target === id)
      .map((e) => ({ source: e.source, target: e.target, type: e.type, direction: e.direction, description: e.description }));
    const out = { node: hydrate(node), edges };
    if (neighbors) {
      const ids = new Set();
      for (const e of edges) { ids.add(e.source); ids.add(e.target); }
      ids.delete(id);
      out.neighbors = [...ids].map((nid) => hydrate(state.nodeById(nid))).filter(Boolean);
    }
    return out;
  },

  read_node_source(state, { id, context }) {
    if (!state.ok()) return { error: state.error };
    const node = state.nodeById(id);
    if (!node) return { error: `node not found: ${id}` };
    if (!node.filePath || !node.lineRange) return { error: `node ${id} has no filePath/lineRange (it is a concept, not a code location)` };
    // Path validation: must resolve inside sourceRoot AND match a graph node's filePath.
    const rel = node.filePath;
    if (isAbsolute(rel)) return { error: `unexpected absolute filePath in graph: ${rel}` };
    const abs = resolve(state.sourceRoot, rel);
    const rootAbs = resolve(state.sourceRoot);
    if (abs !== rootAbs && !abs.startsWith(rootAbs + sep)) return { error: `path escapes source root: ${rel}` };
    if (!existsSync(abs)) return { error: `source file not present on this host: ${rel} (the MCP server must run where the source lives)` };
    const pad = Number.isInteger(context) ? context : 0;
    const lines = readFileSync(abs, "utf8").split("\n");
    const start = Math.max(1, node.lineRange[0] - pad);
    const end = Math.min(lines.length, node.lineRange[1] + pad);
    return {
      id, filePath: rel, lineRange: [start, end],
      source: lines.slice(start - 1, end).join("\n"),
    };
  },

  list_layers(state) {
    if (!state.ok()) return { error: state.error };
    return {
      layers: (state.graph.layers || []).map((l) => ({
        id: l.id, name: l.name, description: l.description, nodeCount: l.nodeIds?.length || 0, nodeIds: l.nodeIds,
      })),
    };
  },

  get_tour(state) {
    if (!state.ok()) return { error: state.error };
    return {
      tour: (state.graph.tour || []).slice().sort((a, b) => a.order - b.order)
        .map((t) => ({ order: t.order, title: t.title, description: t.description, nodeIds: t.nodeIds })),
    };
  },

  project_summary(state) {
    if (!state.ok()) return { error: state.error };
    const p = state.graph.project || {};
    const summary = {
      name: p.name, languages: p.languages, frameworks: p.frameworks,
      description: p.description, analyzedAt: p.analyzedAt, graphCommit: p.gitCommitHash,
      counts: { nodes: state.graph.nodes.length, edges: state.graph.edges.length, layers: (state.graph.layers || []).length, tourSteps: (state.graph.tour || []).length },
      loadedFrom: state.loadedFrom,
    };
    // Best-effort staleness: compare graph commit to current HEAD of the source root.
    try {
      const head = execFileSync("git", ["-C", state.sourceRoot, "rev-parse", "HEAD"], { encoding: "utf8" }).trim();
      summary.repoHead = head;
      if (p.gitCommitHash && head) {
        if (p.gitCommitHash === head) {
          summary.staleness = "fresh (graph matches HEAD)";
        } else {
          let behind = null;
          try { behind = execFileSync("git", ["-C", state.sourceRoot, "rev-list", "--count", `${p.gitCommitHash}..${head}`], { encoding: "utf8" }).trim(); } catch { /* commit may be unknown */ }
          summary.staleness = behind ? `STALE: graph at ${p.gitCommitHash.slice(0, 8)}, repo at ${head.slice(0, 8)} (${behind} commits behind) — consider re-running /understand` : `STALE: graph commit ${p.gitCommitHash.slice(0, 8)} not on current branch`;
        }
      }
    } catch { summary.staleness = "unknown (source root is not a git repo on this host)"; }
    return summary;
  },

  async reload_graph(state) {
    await state.load();
    return state.ok() ? { reloaded: true, loadedFrom: state.loadedFrom, nodes: state.graph.nodes.length } : { reloaded: false, error: state.error };
  },
};

// ── MCP registration ──────────────────────────────────────────────────────────────
export function registerTools(server, state, z) {
  const text = (obj) => ({ content: [{ type: "text", text: JSON.stringify(obj, null, 2) }] });

  server.registerTool("graph_search", {
    title: "Search the codebase knowledge graph",
    description: "Fuzzy keyword search over the Understand-Anything knowledge graph for THIS project. Returns matching nodes (files, functions, classes, concepts) with summaries and file:line locations. Use this to ORIENT — find where a concept lives. For raw source retrieval use read_node_source, Sourcegraph, or lumen.",
    inputSchema: { query: z.string().describe("keywords, symbol, or concept"), limit: z.number().int().positive().max(50).optional() },
  }, async (args) => text(TOOLS.graph_search(state, args)));

  server.registerTool("get_node", {
    title: "Get a graph node and its relationships",
    description: "Return a single knowledge-graph node (by id) with its incident edges (imports/calls/depends_on/…). Pass neighbors=true to also include the connected nodes. Node ids look like 'file:path/to/x.ts' or 'function:path#name'.",
    inputSchema: { id: z.string(), neighbors: z.boolean().optional() },
  }, async (args) => text(TOOLS.get_node(state, args)));

  server.registerTool("read_node_source", {
    title: "Read the source code for a graph node",
    description: "Return the actual source snippet for a node's file:lineRange (read from the host checkout). This is the graph→source bridge that lets agents WITHOUT the repo mounted (e.g. the Hermes fleet) read real code. Optional context=N adds N lines above/below.",
    inputSchema: { id: z.string(), context: z.number().int().min(0).max(200).optional() },
  }, async (args) => text(TOOLS.read_node_source(state, args)));

  server.registerTool("list_layers", {
    title: "List architectural layers",
    description: "Return the logical architectural layers of the project and the node ids in each — the high-level structure.",
    inputSchema: {},
  }, async () => text(TOOLS.list_layers(state)));

  server.registerTool("get_tour", {
    title: "Get the guided code tour",
    description: "Return the ordered guided tour through the codebase — a pedagogical walk for onboarding.",
    inputSchema: {},
  }, async () => text(TOOLS.get_tour(state)));

  server.registerTool("project_summary", {
    title: "Project summary + graph freshness",
    description: "Return the project's languages, frameworks, description, graph counts, and a STALENESS signal comparing the committed graph's commit to the repo's current HEAD. Check this first to know if the graph is current.",
    inputSchema: {},
  }, async () => text(TOOLS.project_summary(state)));

  server.registerTool("reload_graph", {
    title: "Reload the knowledge graph from disk",
    description: "Re-read the knowledge graph (after a /understand regeneration) without restarting the server.",
    inputSchema: {},
  }, async () => text(await TOOLS.reload_graph(state)));
}
