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
// Env: FALKORDB_URL (default redis://falkordb:6379), FALKORDB_GRAPH (default fleet-memory),
//   FALKORDB_MCP_TIMEOUT_MS (connect budget, default 5000),
//   FALKORDB_MCP_AUDIT_LOG (append-only graph_write audit, default ~/.ai-stack/falkordb-writes.jsonl).
import { appendFile, mkdir } from "node:fs/promises";
import os from "node:os";
import path from "node:path";

export const DEFAULT_GRAPH = process.env.FALKORDB_GRAPH || "fleet-memory";

const _connectMs = () => { const n = parseInt(process.env.FALKORDB_MCP_TIMEOUT_MS || "5000", 10); return Number.isFinite(n) && n > 0 ? n : 5000; };

// makeGraphProvider — lazy, cached connect to FalkorDB + select the shared graph. Only bin.mjs
// uses this; tests pass their own provider. Returns {graph}|{error}; never throws AND never hangs:
// the connect is bounded by FALKORDB_MCP_TIMEOUT_MS via Promise.race, so a resolvable-but-black-
// holed host yields a fast {error} instead of blocking on the OS TCP timeout (which would stall
// /healthz past doctor's `curl --max-time 3` and any concurrent tool call). This mirrors honcho-
// mcp's AbortController discipline — race, not AbortController, since the falkordb client is
// redis-based, not fetch-based.
export function makeGraphProvider() {
  let cached = null;
  return async () => {
    if (cached) return { graph: cached };
    const url = process.env.FALKORDB_URL || "redis://falkordb:6379";
    const ms = _connectMs();
    let timer;
    try {
      const { FalkorDB } = await import("falkordb");
      const timeout = new Promise((_, rej) => { timer = setTimeout(() => rej(new Error(`connect timed out after ${ms}ms`)), ms); });
      const db = await Promise.race([FalkorDB.connect({ url }), timeout]);
      cached = db.selectGraph(DEFAULT_GRAPH);
      return { graph: cached };
    } catch (e) {
      return { error: `falkordb connect failed (${url}): ${e?.message || e}` };
    } finally {
      clearTimeout(timer);
    }
  };
}

// _audit — append-only record of every graph_write (the destructive tool) so a bad/injected write
// against the shared, un-isolated, un-backed-up graph is at least replayable. Best-effort: an audit
// failure warns on stderr but never blocks the write (the log is a compensating control, not a gate).
const _auditPath = () => process.env.FALKORDB_MCP_AUDIT_LOG || path.join(os.homedir(), ".ai-stack", "falkordb-writes.jsonl");
async function _audit(tool, cypher, params) {
  const p = _auditPath();
  const line = JSON.stringify({ ts: new Date().toISOString(), tool, cypher, params: params || {} }) + "\n";
  try {
    await appendFile(p, line, "utf8");
  } catch (e) {
    if (e?.code === "ENOENT") {
      try { await mkdir(path.dirname(p), { recursive: true }); await appendFile(p, line, "utf8"); return; }
      catch (e2) { process.stderr.write(`[falkordb-mcp] audit append failed (${p}): ${e2?.message || e2}\n`); return; }
    }
    process.stderr.write(`[falkordb-mcp] audit append failed (${p}): ${e?.message || e}\n`);
  }
}

// A Cypher write clause anywhere → not allowed via the read-only tool.
const _hasWrite = (q) => /\b(CREATE|MERGE|SET|DELETE|REMOVE|DROP|CALL\s+db\.)\b/i.test(q);
// Labels + relationship types CANNOT be Cypher params — validate to a safe identifier charset.
const _ident = (s) => (typeof s === "string" && /^[A-Za-z][A-Za-z0-9_]*$/.test(s)) ? s : null;
// Optional label: ABSENT (undefined/null/empty) → default "Entity"; PRESENT-but-invalid → error
// (never silently coerced — a caller's typo would otherwise fragment node identity, e.g. a
// mistyped :Persn silently becoming :Entity so MERGE can't match the real :Person node).
const _label = (v, which) => {
  if (v === undefined || v === null || v === "") return { label: "Entity" };
  const ok = _ident(v);
  return ok ? { label: ok } : { error: `${which} '${v}' is not a valid node label (letters/digits/_ , must start with a letter — it cannot be a Cypher param)` };
};
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
    // DESTRUCTIVE, SHARED, UN-BACKED-UP graph → audit every write BEFORE executing, so even a
    // write that then throws is on the record and an injected wipe is replayable/attributable.
    await _audit("graph_write", cypher, params);
    const g = await getGraph(); if (g.error) return { error: g.error };
    try { const r = await g.graph.query(cypher, { params: params || {} }); return { ok: true, rows: _rows(r), stats: r?.metadata }; }
    catch (e) { return { error: String(e?.message || e) }; }
  },

  // Idempotent fact: MERGE on identity (name) only, then the relationship — MERGE matches the
  // ENTIRE inline pattern, so merging on name-only avoids duplicate nodes when other props differ.
  async remember_fact(getGraph, { subject, predicate, object, subject_label, object_label }) {
    if (!subject || !predicate || !object) return { error: "subject, predicate and object are required" };
    const s0 = _label(subject_label, "subject_label"); if (s0.error) return { error: s0.error };
    const o0 = _label(object_label, "object_label"); if (o0.error) return { error: o0.error };
    const sl = s0.label, ol = o0.label;
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
    title: "Write Cypher to the shared fleet graph — DESTRUCTIVE, no isolation, no backup",
    description: "⚠️ DESTRUCTIVE & SHARED: runs arbitrary write Cypher (GRAPH.QUERY) against the ONE fleet-memory graph that every agent shares — there is NO per-agent isolation and NO backup, so an unbounded `MATCH (n) DETACH DELETE n` / `DROP` irrecoverably wipes the entire fleet's memory. ALWAYS scope destructive MATCHes with a WHERE and a LIMIT; prefer remember_fact for simple (subject)-[predicate]->(object) facts. Every call is audit-logged. Use `params` for values (not string interpolation).",
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
