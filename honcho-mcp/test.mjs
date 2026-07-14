// Offline test for honcho-mcp. Spawns a MOCK Honcho REST server (no real Honcho, no
// models, no network beyond loopback), exercises the 4 tools + graceful honcho-down
// handling, then a real HTTP JSON-RPC E2E with the token gate.
//
// Run: node test.mjs   (or `npm test`). Exits non-zero on any failure.
import http from "node:http";
import { HonchoClient, TOOLS } from "./lib.mjs";

let failures = 0;
function check(name, cond, detail) {
  if (cond) console.log(`  ok   ${name}`);
  else { console.log(`  FAIL ${name}${detail ? " — " + detail : ""}`); failures++; }
}

function listen(server) { return new Promise((r) => server.listen(0, "127.0.0.1", () => r(server.address().port))); }

// ── mock Honcho v3 ──────────────────────────────────────────────────────────────────
const seen = [];
const mock = http.createServer(async (req, res) => {
  const chunks = []; for await (const c of req) chunks.push(c);
  let body = {}; try { body = chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : {}; } catch { /* */ }
  seen.push({ method: req.method, url: req.url, body });
  const send = (code, obj) => { res.writeHead(code, { "content-type": "application/json" }); res.end(JSON.stringify(obj)); };
  const u = req.url || "";
  if (req.method === "GET") return send(200, { ok: true });                 // reachability probe
  if (u.endsWith("/peers")) return send(200, { id: body.id });              // get_or_create peer
  if (u.endsWith("/sessions")) return send(200, { id: body.id });           // get_or_create session
  if (u.includes("/messages")) return send(200, { count: (body.messages || []).length });
  if (u.includes("/representation")) return send(200, { representation: "pi knows about deploys" });
  if (u.includes("/chat")) return send(200, { content: "the deploy pipeline uses X" });
  if (u.includes("/search")) return send(200, [{ content: "hit1" }, { content: "hit2" }]);
  send(404, { detail: "not found" });
});
const mockPort = await listen(mock);

// a guaranteed-dead port (bind then close) for the honcho-down path
const dead = http.createServer(); const deadPort = await listen(dead); await new Promise((r) => dead.close(r));

console.log("honcho-mcp offline test");
console.log("  mock honcho:", `http://127.0.0.1:${mockPort}`);

process.env.HONCHO_BASE_URL = `http://127.0.0.1:${mockPort}`;
process.env.HONCHO_WORKSPACE_ID = "default";

const client = new HonchoClient();
check("reachable() true against mock", await client.reachable());

const rem = await TOOLS.honcho_remember(client, { peer: "pi", content: "deployed X" });
check("remember ok", rem.remembered === true && !rem.error, JSON.stringify(rem));
check("remember ensured a session before posting", seen.some((s) => s.url.endsWith("/sessions")) && seen.some((s) => s.url.includes("/messages") && (s.body.messages || [])[0]?.peer_id === "pi"), JSON.stringify(seen.map((s) => s.url)));

const rec = await TOOLS.honcho_recall(client, { peer: "pi" });
check("recall returns representation", rec.representation === "pi knows about deploys", JSON.stringify(rec));

const ask = await TOOLS.honcho_ask(client, { peer: "pi", query: "deploys?" });
check("ask returns answer", ask.answer === "the deploy pipeline uses X", JSON.stringify(ask));

const srch = await TOOLS.honcho_search(client, { peer: "pi", query: "X" });
check("search returns results", Array.isArray(srch.results) && srch.results.length === 2, JSON.stringify(srch));

check("remember requires peer+content", !!(await TOOLS.honcho_remember(client, { peer: "pi" })).error);
check("recall requires peer", !!(await TOOLS.honcho_recall(client, {})).error);

// honcho DOWN → graceful {error}, never throws
process.env.HONCHO_BASE_URL = `http://127.0.0.1:${deadPort}`;
const downClient = new HonchoClient();
const remDown = await TOOLS.honcho_remember(downClient, { peer: "pi", content: "x" });
check("honcho-down → {error}, no throw", !!remDown.error && /unreachable/.test(remDown.error), JSON.stringify(remDown));
process.env.HONCHO_BASE_URL = `http://127.0.0.1:${mockPort}`; // restore for the http E2E child

await httpE2E(mockPort);

mock.close();
console.log(failures === 0 ? "\nALL PASS" : `\n${failures} FAILURE(S)`);
process.exit(failures === 0 ? 0 : 1);

// ── HTTP E2E: real JSON-RPC initialize + tools/call over the transport, token-gated ──
async function httpE2E(honchoPort) {
  const { spawn } = await import("node:child_process");
  const { join } = await import("node:path");
  const port = 5401;
  const token = "test-token-abc";
  const env = { ...process.env, HONCHO_MCP_TOKEN: token, HONCHO_MCP_PORT: String(port), HONCHO_BASE_URL: `http://127.0.0.1:${honchoPort}` };
  const child = spawn(process.execPath, [join(import.meta.dirname, "bin.mjs"), "--http", "--port", String(port)], { env, stdio: ["ignore", "ignore", "inherit"] });
  try {
    await waitFor(`http://127.0.0.1:${port}/healthz`, 5000);
    const un = await rpc(port, null, { jsonrpc: "2.0", id: 1, method: "tools/list" });
    check("http rejects missing token (401)", un.status === 401, "status " + un.status);
    const init = await rpc(port, token, { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-06-18", capabilities: {}, clientInfo: { name: "test", version: "0" } } });
    check("http initialize ok (honcho-memory)", init.status === 200 && init.json?.result?.serverInfo?.name === "honcho-memory", JSON.stringify(init.json));
    const call = await rpc(port, token, { jsonrpc: "2.0", id: 2, method: "tools/call", params: { name: "honcho_recall", arguments: { peer: "pi" } } });
    const payload = call.json?.result?.content?.[0]?.text;
    const parsed = payload ? JSON.parse(payload) : null;
    check("http tools/call honcho_recall returns representation", call.status === 200 && parsed?.representation === "pi knows about deploys", JSON.stringify(call.json)?.slice(0, 200));
  } finally {
    child.kill("SIGKILL");
  }
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
