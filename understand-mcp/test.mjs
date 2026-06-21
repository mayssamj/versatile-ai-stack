// Offline test for understand-mcp. Uses the plugin's own fixture graph
// (packages/dashboard/public/knowledge-graph.json) whose source files exist under the
// plugin root, so read_node_source is exercised against REAL files.
//
// Run: node test.mjs   (or `npm test`). Exits non-zero on any failure.

import { existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import http from "node:http";
import { GraphState, TOOLS, resolvePluginRoot } from "./lib.mjs";

let failures = 0;
function check(name, cond, detail) {
  if (cond) { console.log(`  ok   ${name}`); }
  else { console.log(`  FAIL ${name}${detail ? " — " + detail : ""}`); failures++; }
}

// Resolve plugin root (env or cache) and point graph+source at the fixture.
const pluginRoot = process.env.UNDERSTAND_PLUGIN_ROOT || resolvePluginRoot() || (() => {
  const base = join(homedir(), ".claude", "plugins", "cache", "understand-anything", "understand-anything");
  const v = existsSync(base) ? readdirSync(base).filter((x) => /^\d/.test(x)).sort().reverse()[0] : null;
  return v ? join(base, v) : null;
})();
if (!pluginRoot) { console.error("cannot find plugin root for test"); process.exit(2); }
process.env.UNDERSTAND_PLUGIN_ROOT = pluginRoot;
process.env.UNDERSTAND_GRAPH_FILE = join(pluginRoot, "packages", "dashboard", "public", "knowledge-graph.json");
process.env.UNDERSTAND_SOURCE_ROOT = pluginRoot;

console.log("understand-mcp offline test");
console.log("  plugin:", pluginRoot);

const state = await new GraphState().load();
check("graph loads", state.ok(), state.error);
if (!state.ok()) process.exit(1);

const ps = TOOLS.project_summary(state);
check("project_summary has name+counts", !!ps.name && ps.counts.nodes > 0, JSON.stringify(ps.counts));
check("project_summary reports staleness", typeof ps.staleness === "string");

const search = TOOLS.graph_search(state, { query: "search", limit: 5 });
check("graph_search returns hydrated hits", Array.isArray(search.results) && search.results.length > 0 && !!search.results[0].id && !!search.results[0].summary, JSON.stringify(search.results?.[0] || {}));

const firstId = search.results[0].id;
const node = TOOLS.get_node(state, { id: firstId, neighbors: true });
check("get_node returns node+edges", !!node.node && Array.isArray(node.edges));
check("get_node neighbors present", Array.isArray(node.neighbors));

// read_node_source against a real file node (one with filePath+lineRange).
const fileNode = state.graph.nodes.find((n) => n.filePath && n.lineRange);
const src = TOOLS.read_node_source(state, { id: fileNode.id });
check("read_node_source returns real source", typeof src.source === "string" && src.source.length > 0, src.error || "");

// path-escape guard: a forged absolute filePath must be rejected (simulate via missing node).
const bad = TOOLS.read_node_source(state, { id: "file:../../etc/passwd" });
check("read_node_source rejects unknown id", !!bad.error);

// REAL path-escape: inject a node whose filePath traverses out of sourceRoot.
state.graph.nodes.push({ id: "file:evil", type: "file", name: "evil", filePath: "../../../../../../etc/passwd", lineRange: [1, 1], summary: "x", tags: [], complexity: "simple" });
const esc = TOOLS.read_node_source(state, { id: "file:evil" });
check("read_node_source rejects path traversal", !!esc.error && /escape|not present/.test(esc.error), esc.error || JSON.stringify(esc));
state.graph.nodes.pop();

const layers = TOOLS.list_layers(state);
check("list_layers returns layers", Array.isArray(layers.layers) && layers.layers.length > 0);

const tour = TOOLS.get_tour(state);
check("get_tour returns ordered steps", Array.isArray(tour.tour) && tour.tour.length > 0 && tour.tour[0].order <= (tour.tour[1]?.order ?? Infinity));

// missing-graph degradation: a fresh state pointed at nothing must error gracefully, not throw.
const empty = new GraphState();
process.env.UNDERSTAND_GRAPH_FILE = join(pluginRoot, "does-not-exist.json");
await empty.load();
check("missing graph degrades (no throw)", !empty.ok() && typeof empty.error === "string");
check("tools on missing graph return error", !!TOOLS.graph_search(empty, { query: "x" }).error);
process.env.UNDERSTAND_GRAPH_FILE = join(pluginRoot, "packages", "dashboard", "public", "knowledge-graph.json");

// ── HTTP E2E: real JSON-RPC initialize + tools/call over the transport, with token gate ──
await httpE2E();

async function httpE2E() {
  const { spawn } = await import("node:child_process");
  const port = 5399;
  const token = "test-token-123";
  const env = { ...process.env, UNDERSTAND_MCP_TOKEN: token, UNDERSTAND_MCP_PORT: String(port) };
  const child = spawn(process.execPath, [join(import.meta.dirname, "bin.mjs"), "--http", "--port", String(port)], { env, stdio: ["ignore", "ignore", "inherit"] });
  try {
    await waitFor(`http://127.0.0.1:${port}/healthz`, 5000);
    // 401 without token
    const un = await rpc(port, null, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    check("http rejects missing token (401)", un.status === 401, "status " + un.status);
    // initialize + tools/call graph_search with token
    const init = await rpc(port, token, { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } } });
    check("http initialize ok", init.status === 200 && init.json?.result?.serverInfo?.name === "understand-anything", JSON.stringify(init.json));
    const call = await rpc(port, token, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "graph_search", arguments: { query: "search", limit: 3 } } });
    const payload = call.json?.result?.content?.[0]?.text;
    const parsed = payload ? JSON.parse(payload) : null;
    check("http tools/call graph_search returns hits", call.status === 200 && parsed?.results?.length > 0, JSON.stringify(call.json)?.slice(0, 200));
  } finally {
    child.kill("SIGKILL");
  }
}

function waitFor(url, ms) {
  const deadline = Date.now() + ms;
  return new Promise((resolve, reject) => {
    const tick = () => {
      http.get(url, (r) => { r.resume(); resolve(true); }).on("error", () => {
        if (Date.now() > deadline) reject(new Error("server did not start")); else setTimeout(tick, 100);
      });
    };
    tick();
  });
}

function rpc(port, token, body) {
  return new Promise((resolve, reject) => {
    const data = Buffer.from(JSON.stringify(body));
    const headers = { "content-type": "application/json", accept: "application/json, text/event-stream", "content-length": data.length };
    if (token) headers.authorization = `Bearer ${token}`;
    const req = http.request({ host: "127.0.0.1", port, path: "/mcp", method: "POST", headers }, (res) => {
      const chunks = [];
      res.on("data", (c) => chunks.push(c));
      res.on("end", () => {
        const raw = Buffer.concat(chunks).toString("utf8");
        let json = null;
        try { json = JSON.parse(raw); } catch {
          // SSE framing: extract the data: line
          const m = raw.match(/data: (\{.*\})/s); if (m) try { json = JSON.parse(m[1]); } catch { /* */ }
        }
        resolve({ status: res.statusCode, json, raw });
      });
    });
    req.on("error", reject); req.write(data); req.end();
  });
}

console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);
