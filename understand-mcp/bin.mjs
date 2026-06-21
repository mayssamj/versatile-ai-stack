#!/usr/bin/env node
// understand-mcp entrypoint — two transports, selected by flag:
//   understand-mcp --stdio              (local clients: host Claude Code, Pi-on-host)
//   understand-mcp --http [--port N]    (Hermes fleet, via host.docker.internal; token-gated)
//
// The HTTP path uses the stateless StreamableHTTP pattern (a fresh server+transport per
// request) so concurrent fleet profiles never collide on request ids.

import http from "node:http";
import { timingSafeEqual } from "node:crypto";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { GraphState, registerTools } from "./lib.mjs";

const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const valOf = (f, d) => { const i = argv.indexOf(f); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };

function buildServer(state) {
  const server = new McpServer({ name: "understand-anything", version: "0.1.0" }, {
    instructions: "Read-only knowledge-graph navigator for this project. Use graph_search/list_layers/get_tour to ORIENT, read_node_source to read code, project_summary to check graph freshness.",
  });
  registerTools(server, state, z);
  return server;
}

async function runStdio() {
  const state = await new GraphState().load(); // never throws; errors surface per-tool
  const server = buildServer(state);
  await server.connect(new StdioServerTransport());
  // stdio server stays alive on the transport; nothing else to do.
}

function tokenOk(req) {
  const expected = process.env.UNDERSTAND_MCP_TOKEN || "";
  if (!expected) return true; // belt+braces: runHttp() refuses to start without a token
  const auth = req.headers["authorization"] || "";
  const m = auth.match(/^(?:Bearer|token)\s+(.+)$/i);
  const provided = (m && m[1]) || req.headers["x-understand-token"] || "";
  // Constant-time compare (length-guarded) to avoid a token-byte timing oracle.
  const a = Buffer.from(String(provided)); const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

async function runHttp() {
  // Fail CLOSED: the http server is reachable by every container on the engine's
  // host.docker.internal bridge, so it must never run unauthenticated. (stdio mode,
  // for local clients only, needs no token.)
  if (!process.env.UNDERSTAND_MCP_TOKEN && !has("--allow-no-token")) {
    process.stderr.write("[understand-mcp] refusing to start --http without UNDERSTAND_MCP_TOKEN (set it in .env, or pass --allow-no-token for loopback-only dev)\n");
    process.exit(1);
  }
  const port = parseInt(valOf("--port", process.env.UNDERSTAND_MCP_PORT || "7081"), 10);
  const host = valOf("--host", process.env.UNDERSTAND_MCP_HOST || "127.0.0.1");
  const path = valOf("--path", "/mcp");
  // One shared graph state (read-only) — reused across per-request servers.
  const state = await new GraphState().load();

  const httpServer = http.createServer(async (req, res) => {
    if (req.url?.split("?")[0] === "/healthz") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, graph: state.ok(), error: state.error || null }));
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

      const server = buildServer(state);
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
      try {
        await server.connect(transport);
        // Register cleanup AFTER connect — registering before lets an early client
        // disconnect close() an unconnected transport (throws / unhandled rejection).
        res.on("close", () => { try { transport.close(); server.close(); } catch { /* already torn down */ } });
        await transport.handleRequest(req, res, body);
      } catch (e) {
        if (!res.headersSent) res.writeHead(500, { "content-type": "application/json" }).end(JSON.stringify({ jsonrpc: "2.0", error: { code: -32603, message: String(e?.message || e) }, id: null }));
      }
      return;
    }
    // Stateless: no SSE/GET stream, no session DELETE.
    res.writeHead(405, { "content-type": "application/json", allow: "POST" }).end(JSON.stringify({ jsonrpc: "2.0", error: { code: -32000, message: "Method not allowed (stateless server: use POST)" }, id: null }));
  });

  httpServer.listen(port, host, () => {
    process.stderr.write(`[understand-mcp] http on http://${host}:${port}${path} (graph ${state.ok() ? "loaded: " + state.graph.nodes.length + " nodes" : "NOT loaded: " + state.error})\n`);
  });
}

const mode = has("--http") ? "http" : "stdio";
(mode === "http" ? runHttp() : runStdio()).catch((e) => {
  // Last-resort guard — should not happen (GraphState.load never throws), but never crash silently.
  process.stderr.write(`[understand-mcp] fatal: ${e?.stack || e}\n`);
  process.exit(1);
});
