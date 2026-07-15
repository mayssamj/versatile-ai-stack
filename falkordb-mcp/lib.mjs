// falkordb-mcp — minimal graph-memory tools over FalkorDB (Cypher via GRAPH.QUERY /
// GRAPH.RO_QUERY on a Redis endpoint). Thin wrapper, NO auto-extraction (operator decision:
// build the minimal primitive). One shared graph (FALKORDB_GRAPH, default "fleet-memory") —
// the graph analog of honcho's one shared workspace (full-shared, no per-agent isolation).
//
// NEVER throws at startup: the DB connection is lazy (first tool call) and cached; a down /
// unreachable FalkorDB surfaces as {error} per call, so registering this server is always safe.
// TOOLS take a `getGraph` async provider (returns {graph}|{error}) so the offline test can
// inject a mock graph with no real FalkorDB.
//
// Env: FALKORDB_URL (default redis://falkordb:6379), FALKORDB_GRAPH (default fleet-memory).

export const DEFAULT_GRAPH = process.env.FALKORDB_GRAPH || "fleet-memory";

// makeGraphProvider — lazy, cached connect to FalkorDB + select the shared graph. Only bin.mjs
// uses this; tests pass their own provider. Returns {graph}|{error}; never throws.
export function makeGraphProvider() {
  let cached = null;
  return async () => {
    if (cached) return { graph: cached };
    try {
      const { FalkorDB } = await import("falkordb");
      const db = await FalkorDB.connect({ url: process.env.FALKORDB_URL || "redis://falkordb:6379" });
      cached = db.selectGraph(DEFAULT_GRAPH);
      return { graph: cached };
    } catch (e) {
      return { error: `falkordb connect failed (${process.env.FALKORDB_URL || "redis://falkordb:6379"}): ${e?.message || e}` };
    }
  };
}

// A Cypher write clause anywhere → not allowed via the read-only tool.
const _hasWrite = (q) => /\b(CREATE|MERGE|SET|DELETE|REMOVE|DROP|CALL\s+db\.)\b/i.test(q);
// Labels + relationship types CANNOT be Cypher params — validate to a safe identifier charset.
const _ident = (s) => (typeof s === "string" && /^[A-Za-z][A-Za-z0-9_]*$/.test(s)) ? s : null;
const _rows = (r) => (r && typeof r === "object" && "data" in r) ? r.data : r;

export const TOOLS = {
  async graph_query(getGraph, { cypher, params }) {
    if (!cypher) return { error: "cypher is required" };
    if (_hasWrite(cypher)) return { error: "graph_query is READ-ONLY (GRAPH.RO_QUERY) — use graph_write for CREATE/MERGE/SET/DELETE" };
    const g = await getGraph(); if (g.error) return { error: g.error };
    try { const r = await g.graph.roQuery(cypher, { params: params || {} }); return { rows: _rows(r), stats: r?.metadata }; }
    catch (e) { return { error: String(e?.message || e) }; }
  },

  async graph_write(getGraph, { cypher, params }) {
    if (!cypher) return { error: "cypher is required" };
    const g = await getGraph(); if (g.error) return { error: g.error };
    try { const r = await g.graph.query(cypher, { params: params || {} }); return { ok: true, rows: _rows(r), stats: r?.metadata }; }
    catch (e) { return { error: String(e?.message || e) }; }
  },

  // Idempotent fact: MERGE on identity (name) only, then the relationship — MERGE matches the
  // ENTIRE inline pattern, so merging on name-only avoids duplicate nodes when other props differ.
  async remember_fact(getGraph, { subject, predicate, object, subject_label, object_label }) {
    if (!subject || !predicate || !object) return { error: "subject, predicate and object are required" };
    const sl = _ident(subject_label) || "Entity";
    const ol = _ident(object_label) || "Entity";
    const rel = _ident(predicate);
    if (!rel) return { error: `predicate '${predicate}' is not a valid relationship type (letters/digits/_ , must start with a letter — it cannot be a Cypher param)` };
    const g = await getGraph(); if (g.error) return { error: g.error };
    const cypher = `MERGE (a:${sl} {name:$s}) MERGE (b:${ol} {name:$o}) MERGE (a)-[r:${rel}]->(b) RETURN a.name AS s, type(r) AS p, b.name AS o`;
    try { await g.graph.query(cypher, { params: { s: subject, o: object } }); return { remembered: true, fact: `(${sl}:${subject}) -[${rel}]-> (${ol}:${object})` }; }
    catch (e) { return { error: String(e?.message || e) }; }
  },

  async recall_related(getGraph, { name, limit }) {
    if (!name) return { error: "name is required" };
    const k = Number.isInteger(limit) ? limit : 25;
    const g = await getGraph(); if (g.error) return { error: g.error };
    const cypher = `MATCH (a {name:$n})-[r]-(b) RETURN type(r) AS rel, b.name AS related, labels(b) AS labels LIMIT $k`;
    try { const r = await g.graph.roQuery(cypher, { params: { n: name, k } }); return { name, related: _rows(r) }; }
    catch (e) { return { error: String(e?.message || e) }; }
  },
};

export function registerTools(server, getGraph, z) {
  const text = (obj) => ({ content: [{ type: "text", text: JSON.stringify(obj, null, 2) }] });

  server.registerTool("graph_query", {
    title: "Read-only Cypher query over the shared fleet graph",
    description: "Run a READ-ONLY Cypher query (GRAPH.RO_QUERY) against the shared fleet-memory graph. Rejects write clauses. Pass `params` (values only) to avoid Cypher injection.",
    inputSchema: { cypher: z.string(), params: z.record(z.any()).optional() },
  }, async (a) => text(await TOOLS.graph_query(getGraph, a)));

  server.registerTool("graph_write", {
    title: "Write Cypher (CREATE/MERGE/SET) to the shared fleet graph",
    description: "Run a write Cypher statement (GRAPH.QUERY). Prefer remember_fact for simple subject-predicate-object facts. Use `params` for values.",
    inputSchema: { cypher: z.string(), params: z.record(z.any()).optional() },
  }, async (a) => text(await TOOLS.graph_write(getGraph, a)));

  server.registerTool("remember_fact", {
    title: "Remember a fact: (subject)-[predicate]->(object)",
    description: "Idempotently store a fact as a graph edge in the shared fleet graph. Labels default to Entity; predicate must be a valid relationship type (letters/digits/_, starts with a letter). MERGEs on the `name` identity so repeats don't duplicate nodes.",
    inputSchema: { subject: z.string(), predicate: z.string(), object: z.string(), subject_label: z.string().optional(), object_label: z.string().optional() },
  }, async (a) => text(await TOOLS.remember_fact(getGraph, a)));

  server.registerTool("recall_related", {
    title: "Recall entities related to a named entity",
    description: "Return the entities directly related to `name` in the shared fleet graph (neighbors + relationship types + labels). Read-only.",
    inputSchema: { name: z.string(), limit: z.number().int().positive().max(200).optional() },
  }, async (a) => text(await TOOLS.recall_related(getGraph, a)));
}
