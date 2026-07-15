// Offline test for falkordb-mcp. Unit-tests the tools via a MOCK graph provider (no real
// FalkorDB, no Redis, no models), then an HTTP E2E for the token gate + initialize (which do
// NOT touch FalkorDB, so no dead-connection hang). Run: node test.mjs. Exits non-zero on fail.
import http from "node:http";
import { TOOLS } from "./lib.mjs";

let failures = 0;
function check(name, cond, detail) {
  if (cond) console.log(`  ok   ${name}`);
  else { console.log(`  FAIL ${name}${detail ? " — " + detail : ""}`); failures++; }
}

// mock graph provider: records queries, returns canned data. down=true → provider {error}.
function mockProvider(opts = {}) {
  const seen = [];
  const graph = {
    query:   async (cy, o) => { seen.push({ rw: "query",   cy, params: o?.params }); return { data: [{ ok: true }], metadata: ["Query internal execution time: 0.1 ms"] }; },
    roQuery: async (cy, o) => { seen.push({ rw: "roQuery", cy, params: o?.params }); return { data: opts.roRows ?? [{ rel: "KNOWS", related: "Bob", labels: ["Entity"] }], metadata: [] }; },
  };
  const getGraph = async () => (opts.down ? { error: "falkordb connect failed (mock down)" } : { graph });
  return { getGraph, seen };
}

console.log("falkordb-mcp offline test");

{ const { getGraph, seen } = mockProvider();
  const r = await TOOLS.graph_query(getGraph, { cypher: "MATCH (n) RETURN n LIMIT 5" });
  check("graph_query returns rows (RO)", Array.isArray(r.rows) && !r.error && seen.some(s => s.rw === "roQuery"), JSON.stringify(r)); }

{ const { getGraph } = mockProvider();
  const r = await TOOLS.graph_query(getGraph, { cypher: "CREATE (n:X) RETURN n" });
  check("graph_query REJECTS a write cypher", !!r.error && /read-only/i.test(r.error), JSON.stringify(r)); }

{ const { getGraph, seen } = mockProvider();
  const r = await TOOLS.graph_write(getGraph, { cypher: "CREATE (n:X {name:'a'})" });
  check("graph_write ok + uses query (RW)", r.ok === true && seen.some(s => s.rw === "query"), JSON.stringify(r)); }

{ const { getGraph, seen } = mockProvider();
  const r = await TOOLS.remember_fact(getGraph, { subject: "pi", predicate: "DEPLOYED", object: "service-x" });
  check("remember_fact ok", r.remembered === true, JSON.stringify(r));
  const q = seen.find(s => s.rw === "query") || {};
  check("remember_fact MERGEs on name identity (no dup nodes)", /MERGE \(a:Entity \{name:\$s\}\)/.test(q.cy || "") && /MERGE \(a\)-\[r:DEPLOYED\]->\(b\)/.test(q.cy || ""), q.cy);
  check("remember_fact passes values as PARAMS (not interpolated)", q.params?.s === "pi" && q.params?.o === "service-x"); }

{ const { getGraph } = mockProvider();
  const r = await TOOLS.remember_fact(getGraph, { subject: "a", predicate: "BAD REL) DELETE (x", object: "b" });
  check("remember_fact REJECTS an injection-y predicate (labels/reltypes can't be params)", !!r.error, JSON.stringify(r)); }

{ const { getGraph } = mockProvider();
  const r = await TOOLS.recall_related(getGraph, { name: "pi" });
  check("recall_related returns related (RO)", Array.isArray(r.related) && !r.error, JSON.stringify(r)); }

check("graph_query requires cypher", !!(await TOOLS.graph_query(mockProvider().getGraph, {})).error);
check("remember_fact requires subject/predicate/object", !!(await TOOLS.remember_fact(mockProvider().getGraph, { subject: "a" })).error);

{ const { getGraph } = mockProvider({ down: true });
  const r = await TOOLS.remember_fact(getGraph, { subject: "a", predicate: "R", object: "b" });
  check("falkordb-down → {error}, no throw", !!r.error && /connect failed/.test(r.error), JSON.stringify(r)); }

await httpE2E();

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);

// HTTP E2E: token gate + initialize only — these never call the graph provider, so no
// FalkorDB is needed and there is no dead-connection hang. (Tool-level DB-down is unit-tested.)
async function httpE2E() {
  const { spawn } = await import("node:child_process");
  const { join } = await import("node:path");
  const port = 5402, token = "test-tok-fk";
  const env = { ...process.env, FALKORDB_MCP_TOKEN: token, FALKORDB_MCP_PORT: String(port) };
  const child = spawn(process.execPath, [join(import.meta.dirname, "bin.mjs"), "--http", "--port", String(port)], { env, stdio: ["ignore", "ignore", "inherit"] });
  try {
    // readiness: a GET /mcp with no token returns 401 once the server is up (no provider call).
    await waitFor(`http://127.0.0.1:${port}/mcp`, 5000);
    const un = await rpc(port, null, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    check("http rejects missing token (401)", un.status === 401, "status " + un.status);
    const wrong = await rpc(port, "nope", { jsonrpc: "2.0", id: 1, method: "tools/list" });
    check("http rejects WRONG token (401)", wrong.status === 401, "status " + wrong.status);
    const init = await rpc(port, token, { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } } });
    check("http initialize ok (falkordb-graph-memory)", init.status === 200 && init.json?.result?.serverInfo?.name === "falkordb-graph-memory", JSON.stringify(init.json));
  } finally { child.kill("SIGKILL"); }
}

function waitFor(url, ms) {
  const deadline = Date.now() + ms;
  return new Promise((resolve, reject) => {
    const tick = () => { http.get(url, (r) => { r.resume(); resolve(true); }).on("error", () => { if (Date.now() > deadline) reject(new Error("server did not start")); else setTimeout(tick, 100); }); };
    tick();
  });
}
function rpc(port, token, body) {
  return new Promise((resolve, reject) => {
    const data = Buffer.from(JSON.stringify(body));
    const headers = { "content-type": "application/json", accept: "application/json, text/event-stream", "content-length": data.length };
    if (token) headers.authorization = `Bearer ${token}`;
    const req = http.request({ host: "127.0.0.1", port, path: "/mcp", method: "POST", headers }, (res) => {
      const chunks = []; res.on("data", (c) => chunks.push(c));
      res.on("end", () => { const raw = Buffer.concat(chunks).toString("utf8"); let json = null; try { json = JSON.parse(raw); } catch { const m = raw.match(/data: (\{.*\})/s); if (m) try { json = JSON.parse(m[1]); } catch { /* */ } } resolve({ status: res.statusCode, json, raw }); });
    });
    req.on("error", reject); req.write(data); req.end();
  });
}
