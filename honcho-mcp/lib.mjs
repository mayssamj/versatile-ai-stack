// honcho-mcp — shared logic: a thin Honcho v3 REST client + the memory tools that wrap
// it. Headless, no LLM of its own. NEVER throws at startup (the client is constructed
// from env only; the network is touched per-tool), so registering this server is safe
// even when Honcho is down — a call then returns a clear {error} rather than crashing.
//
// Env (all overridable by the launcher/installer):
//   HONCHO_BASE_URL     — Honcho REST base (default http://honcho:8000)
//   HONCHO_WORKSPACE_ID — workspace (default "default"; FULL-SHARED: all consumers share it)
//   HONCHO_API_KEY      — optional bearer (Honcho runs AUTH_USE_AUTH=false → ignored, harmless)
//   HONCHO_MCP_TIMEOUT_MS — per-request timeout (default 20000)
//
// Peer model (operator decision = full-shared, no isolation): the CALLER passes its own
// `peer` id (e.g. "claude" / "pi" / "hermes-<profile>"); all peers share one workspace and
// a default "fleet" session, so cross-agent recall works with no isolation layer.

const DEFAULT_SESSION = "fleet";

export class HonchoClient {
  constructor() {
    this.base = (process.env.HONCHO_BASE_URL || "http://honcho:8000").replace(/\/+$/, "");
    this.ws = process.env.HONCHO_WORKSPACE_ID || "default";
    this.key = process.env.HONCHO_API_KEY || "";
    this.timeoutMs = parseInt(process.env.HONCHO_MCP_TIMEOUT_MS || "20000", 10);
  }

  _url(path) { return `${this.base}/v3/workspaces/${encodeURIComponent(this.ws)}${path}`; }

  async _post(path, body) {
    const headers = { "content-type": "application/json" };
    if (this.key) headers.authorization = `Bearer ${this.key}`;
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), this.timeoutMs);
    try {
      const r = await fetch(this._url(path), { method: "POST", headers, body: JSON.stringify(body), signal: ac.signal });
      const raw = await r.text();
      let json; try { json = raw ? JSON.parse(raw) : {}; } catch { json = { raw }; }
      if (!r.ok) {
        const detail = typeof json?.detail === "string" ? json.detail : (raw || "").slice(0, 300);
        return { error: `honcho HTTP ${r.status}: ${detail}` };
      }
      return { ok: json };
    } catch (e) {
      return { error: `honcho unreachable at ${this.base} (${e?.name === "AbortError" ? "timeout" : e?.message || e})` };
    } finally { clearTimeout(t); }
  }

  // Reachability probe for /healthz: any HTTP response (even 404) = the server is up.
  async reachable() {
    const ac = new AbortController();
    const t = setTimeout(() => ac.abort(), 3000);
    try { await fetch(this.base, { method: "GET", signal: ac.signal }); return true; }
    catch { return false; }
    finally { clearTimeout(t); }
  }

  ensurePeer(peer)       { return this._post(`/peers`, { id: peer }); }        // get_or_create
  ensureSession(session) { return this._post(`/sessions`, { id: session }); } // get_or_create

  async addTurn(peer, content, session) {
    const s = session || DEFAULT_SESSION;
    const es = await this.ensureSession(s);
    if (es.error) return es;
    return this._post(`/sessions/${encodeURIComponent(s)}/messages`, { messages: [{ peer_id: peer, content }] });
  }
  getRepresentation(peer, opts = {}) { return this._post(`/peers/${encodeURIComponent(peer)}/representation`, opts); }
  chat(peer, query, opts = {})       { return this._post(`/peers/${encodeURIComponent(peer)}/chat`, { query, ...opts }); }
  search(peer, query, limit)         { return this._post(`/peers/${encodeURIComponent(peer)}/search`, { query, limit: limit || 10 }); }
}

// ── tool implementations (return plain objects; never throw) ────────────────────────
export const TOOLS = {
  async honcho_remember(client, { peer, content, session }) {
    if (!peer || !content) return { error: "peer and content are required" };
    const r = await client.addTurn(peer, content, session);
    return r.error ? { error: r.error } : { remembered: true, peer, session: session || DEFAULT_SESSION };
  },
  async honcho_recall(client, { peer, target, session }) {
    if (!peer) return { error: "peer is required" };
    const opts = {};
    if (target) opts.target = target;
    if (session) opts.session_id = session;
    const r = await client.getRepresentation(peer, opts);
    return r.error ? { error: r.error } : { peer, representation: r.ok?.representation ?? r.ok };
  },
  async honcho_ask(client, { peer, query, session }) {
    if (!peer || !query) return { error: "peer and query are required" };
    const opts = {};
    if (session) opts.session_id = session;
    const r = await client.chat(peer, query, opts);
    return r.error ? { error: r.error } : { peer, query, answer: r.ok?.content ?? r.ok };
  },
  async honcho_search(client, { peer, query, limit }) {
    if (!peer || !query) return { error: "peer and query are required" };
    const r = await client.search(peer, query, limit);
    return r.error ? { error: r.error } : { peer, query, results: r.ok };
  },
};

// ── MCP registration ────────────────────────────────────────────────────────────────
export function registerTools(server, client, z) {
  const text = (obj) => ({ content: [{ type: "text", text: JSON.stringify(obj, null, 2) }] });

  server.registerTool("honcho_remember", {
    title: "Persist a turn to shared fleet memory",
    description: "Write a message/turn to Honcho for a peer (agent). Honcho derives durable facts about the peer in the background. FULL-SHARED: all fleet consumers share one workspace, so anything remembered is recallable by any peer. Pass your own agent id as `peer` (e.g. claude/pi/hermes-manager).",
    inputSchema: { peer: z.string().describe("the agent/participant id"), content: z.string().describe("what was said/observed"), session: z.string().optional().describe("session id (default: fleet)") },
  }, async (args) => text(await TOOLS.honcho_remember(client, args)));

  server.registerTool("honcho_recall", {
    title: "Recall a peer's derived representation",
    description: "Return Honcho's derived representation of a peer — the durable facts/beliefs it has synthesized. Optionally `target` for one peer's view of another. Read-only.",
    inputSchema: { peer: z.string(), target: z.string().optional().describe("peer whose view you want (default: the peer's own)"), session: z.string().optional() },
  }, async (args) => text(await TOOLS.honcho_recall(client, args)));

  server.registerTool("honcho_ask", {
    title: "Ask a natural-language question of a peer's memory",
    description: "Dialectic query: ask a natural-language question answered from a peer's derived representation (e.g. 'what does pi know about the deploy pipeline?'). Read-only.",
    inputSchema: { peer: z.string(), query: z.string().describe("natural-language question"), session: z.string().optional() },
  }, async (args) => text(await TOOLS.honcho_ask(client, args)));

  server.registerTool("honcho_search", {
    title: "Search a peer's messages",
    description: "Semantic search over a peer's stored messages. Read-only.",
    inputSchema: { peer: z.string(), query: z.string(), limit: z.number().int().positive().max(100).optional() },
  }, async (args) => text(await TOOLS.honcho_search(client, args)));
}
