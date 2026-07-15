#!/usr/bin/env node
// falkordb-mcp entrypoint — two transports, selected by flag:
//   falkordb-mcp --stdio              (local clients: host Claude Code, Pi-on-host)
//   falkordb-mcp --http [--port N]    (Hermes fleet, via host.docker.internal; token-gated)
//
// A thin MCP wrapper over FalkorDB's Cypher (GRAPH.QUERY / GRAPH.RO_QUERY on a Redis endpoint)
// exposing minimal graph-memory tools. Sandboxes reach the shim over host.docker.internal
// (raw falkordb:6379 stays denied to them). HTTP uses the stateless StreamableHTTP pattern
// (fresh server+transport per request), like honcho-mcp/understand-mcp.
import http from "node:http";
import { timingSafeEqual } from "node:crypto";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { makeGraphProvider, registerTools, DEFAULT_GRAPH } from "./lib.mjs";

const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const valOf = (f, d) => { const i = argv.indexOf(f); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };

function buildServer(getGraph) {
  const server = new McpServer({ name: "falkordb-graph-memory", version: "0.1.0" }, {
    instructions: "Shared fleet graph memory via FalkorDB. remember_fact stores (subject)-[predicate]->(object); recall_related returns an entity's neighbors; graph_query runs read-only Cypher. One shared graph (fleet-memory); no per-agent isolation. graph_write runs ARBITRARY write Cypher against that one shared, un-backed-up graph and can irrecoverably wipe fleet memory — prefer remember_fact, and scope any destructive MATCH with WHERE/LIMIT.",
  });
  registerTools(server, getGraph, z);
  return server;
}

async function runStdio() {
  const getGraph = makeGraphProvider();
  const server = buildServer(getGraph);
  await server.connect(new StdioServerTransport());
}

function tokenOk(req) {
  const expected = process.env.FALKORDB_MCP_TOKEN || "";
  if (!expected) return true; // belt+braces: runHttp() refuses to start without a token
  const auth = req.headers["authorization"] || "";
  const m = auth.match(/^(?:Bearer|token)\s+(.+)$/i);
  const provided = (m && m[1]) || req.headers["x-falkordb-token"] || "";
  const a = Buffer.from(String(provided)); const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

async function runHttp() {
  // Fail CLOSED: the http server is reachable by every container on the engine's
  // host.docker.internal bridge, so it must never run unauthenticated. (stdio needs none.)
  if (!process.env.FALKORDB_MCP_TOKEN && !has("--allow-no-token")) {
    process.stderr.write("[falkordb-mcp] refusing to start --http without FALKORDB_MCP_TOKEN (set it in .env, or pass --allow-no-token for loopback-only dev)\n");
    process.exit(1);
  }
  const port = parseInt(valOf("--port", process.env.FALKORDB_MCP_PORT || "7083"), 10);
  const host = valOf("--host", process.env.FALKORDB_MCP_HOST || "127.0.0.1");
  const path = valOf("--path", "/mcp");
  const getGraph = makeGraphProvider();

  const httpServer = http.createServer(async (req, res) => {
    if (req.url?.split("?")[0] === "/healthz") {
      // Bound the probe to under doctor's `curl --max-time 3`: makeGraphProvider already caps the
      // connect (~5s), but a black-holed backend must degrade to falkordb:false FAST, not stall the
      // probe so doctor misreads it as "shim not answering" rather than "backend down".
      const probeTimeout = new Promise((resolve) => { const t = setTimeout(() => resolve({ error: "healthz probe timed out" }), 2500); t.unref?.(); });
      const g = await Promise.race([getGraph(), probeTimeout]);
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, falkordb: !g.error, error: g.error || null, graph: DEFAULT_GRAPH }));
      return;
    }
    if (req.url?.split("?")[0] !== path) { res.writeHead(404).end(); return; }
    if (!tokenOk(req)) { res.writeHead(401, { "content-type": "application/json" }).end(JSON.stringify({ error: "unauthorized" })); return; }

    if (req.method === "POST") {
      const chunks = [];
      for await (const c of req) chunks.push(c);
      let body;
      try { body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : undefined; }
      catch { res.writeHead(400, { "content-type": "application/json" }).end(JSON.stringify({ jsonrpc: "2.0", error: { code: -32700, message: "Parse error" }, id: null })); return; }

      const server = buildServer(getGraph);
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
      try {
        await server.connect(transport);
        res.on("close", () => { try { transport.close(); server.close(); } catch { /* already torn down */ } });
        await transport.handleRequest(req, res, body);
      } catch (e) {
        if (!res.headersSent) res.writeHead(500, { "content-type": "application/json" }).end(JSON.stringify({ jsonrpc: "2.0", error: { code: -32603, message: String(e?.message || e) }, id: null }));
      }
      return;
    }
    res.writeHead(405, { "content-type": "application/json", allow: "POST" }).end(JSON.stringify({ jsonrpc: "2.0", error: { code: -32000, message: "Method not allowed (stateless server: use POST)" }, id: null }));
  });

  httpServer.listen(port, host, () => {
    process.stderr.write(`[falkordb-mcp] http on http://${host}:${port}${path} (graph ${DEFAULT_GRAPH} @ ${process.env.FALKORDB_URL || "redis://falkordb:6379"})\n`);
  });
}

const mode = has("--http") ? "http" : "stdio";
(mode === "http" ? runHttp() : runStdio()).catch((e) => {
  process.stderr.write(`[falkordb-mcp] fatal: ${e?.stack || e}\n`);
  process.exit(1);
});
