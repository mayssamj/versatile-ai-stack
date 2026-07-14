#!/usr/bin/env node
// honcho-mcp entrypoint — two transports, selected by flag:
//   honcho-mcp --stdio              (local clients: host Claude Code, Pi-on-host)
//   honcho-mcp --http [--port N]    (Hermes fleet, via host.docker.internal; token-gated)
//
// A thin MCP wrapper over Honcho's REST API so agents get memory as TOOLS. The HTTP path
// is the ONLY sandbox route to Honcho: the raw auth-off Honcho REST port (:8000) is NOT
// reachable from the sandboxes (Phase-40 retires that egress), so this shim + its token
// are the choke point. HTTP uses the stateless StreamableHTTP pattern (fresh
// server+transport per request) like understand-mcp.
import http from "node:http";
import { timingSafeEqual } from "node:crypto";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StreamableHTTPServerTransport } from "@modelcontextprotocol/sdk/server/streamableHttp.js";
import { z } from "zod";
import { HonchoClient, registerTools } from "./lib.mjs";

const argv = process.argv.slice(2);
const has = (f) => argv.includes(f);
const valOf = (f, d) => { const i = argv.indexOf(f); return i >= 0 && argv[i + 1] ? argv[i + 1] : d; };

function buildServer(client) {
  const server = new McpServer({ name: "honcho-memory", version: "0.1.0" }, {
    instructions: "Shared fleet memory via Honcho. honcho_remember writes a turn; honcho_recall/honcho_ask read a peer's derived facts; honcho_search searches messages. FULL-SHARED workspace: pass your own agent id as `peer`.",
  });
  registerTools(server, client, z);
  return server;
}

async function runStdio() {
  const client = new HonchoClient();
  const server = buildServer(client);
  await server.connect(new StdioServerTransport());
}

function tokenOk(req) {
  const expected = process.env.HONCHO_MCP_TOKEN || "";
  if (!expected) return true; // belt+braces: runHttp() refuses to start without a token
  const auth = req.headers["authorization"] || "";
  const m = auth.match(/^(?:Bearer|token)\s+(.+)$/i);
  const provided = (m && m[1]) || req.headers["x-honcho-token"] || "";
  const a = Buffer.from(String(provided)); const b = Buffer.from(expected);
  return a.length === b.length && timingSafeEqual(a, b);
}

async function runHttp() {
  // Fail CLOSED: the http server is reachable by every container on the engine's
  // host.docker.internal bridge, so it must never run unauthenticated. (stdio needs none.)
  if (!process.env.HONCHO_MCP_TOKEN && !has("--allow-no-token")) {
    process.stderr.write("[honcho-mcp] refusing to start --http without HONCHO_MCP_TOKEN (set it in .env, or pass --allow-no-token for loopback-only dev)\n");
    process.exit(1);
  }
  const port = parseInt(valOf("--port", process.env.HONCHO_MCP_PORT || "7082"), 10);
  const host = valOf("--host", process.env.HONCHO_MCP_HOST || "127.0.0.1");
  const path = valOf("--path", "/mcp");
  const client = new HonchoClient();

  const httpServer = http.createServer(async (req, res) => {
    if (req.url?.split("?")[0] === "/healthz") {
      const honcho = await client.reachable();
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, honcho, base: client.base, workspace: client.ws }));
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

      const server = buildServer(client);
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
      try {
        await server.connect(transport);
        // Register cleanup AFTER connect (an early disconnect before connect would close()
        // an unconnected transport → unhandled rejection).
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
    process.stderr.write(`[honcho-mcp] http on http://${host}:${port}${path} (honcho ${client.base}, workspace ${client.ws})\n`);
  });
}

const mode = has("--http") ? "http" : "stdio";
(mode === "http" ? runHttp() : runStdio()).catch((e) => {
  process.stderr.write(`[honcho-mcp] fatal: ${e?.stack || e}\n`);
  process.exit(1);
});
