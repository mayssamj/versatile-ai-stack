/**
 * Pi extension — fleet-memory MCP tools (slice 2b).
 *
 * Pi (@earendil-works/pi-coding-agent) ships NO MCP client, so it cannot speak
 * to the fleet's three host-side MCP shims the way Hermes does (Hermes uses the
 * python `mcp` streamable-http client, wired per-profile in installer/lib/mcp.sh).
 * This extension gives Pi the SAME memory surface by hand-rolling a tiny
 * MCP-over-HTTP (JSON-RPC 2.0) client with the runtime's global `fetch`, then
 * registering the shim tools as native Pi tools via `pi.registerTool()`.
 *
 * Bridged shims (all reached over host.docker.internal, mirroring hermes-fleet):
 *   - docs-mcp     :8765  search_documents                         [UNAUTH]
 *   - honcho-mcp   :7082  honcho_remember/recall/ask/search        [Bearer token]
 *   - falkordb-mcp :7083  remember_fact/recall_related/graph_query [Bearer token]
 *                         graph_write                              [OPT-IN, destructive]
 *
 * ── Why hand-rolled, not @modelcontextprotocol/sdk ──────────────────────────
 * Pi's extension runtime does not bundle the MCP SDK. Its documented available
 * imports are only @earendil-works/pi-{coding-agent,ai,tui}, `typebox`, and
 * node builtins — plus global `fetch` (the docs' async-factory example calls
 * `fetch()` directly; pi also ships undici). Both shims expose the STATELESS
 * StreamableHTTP pattern (fresh McpServer+transport per POST, sessionIdGenerator
 * undefined, enableJsonResponse:true). Their shipped E2E tests
 * (honcho-mcp/test.mjs, falkordb-mcp/test.mjs) prove a bare `tools/call` POST —
 * with NO preceding `initialize` in the same request — returns 200 with the
 * tool payload, because each POST builds a brand-new server. So the whole client
 * is: one authenticated POST of `{jsonrpc,id,method:"tools/call",params}` with
 * `Accept: application/json, text/event-stream`, then parse `result.content[0].text`.
 *
 * ── Auth / tokens ───────────────────────────────────────────────────────────
 * honcho-mcp + falkordb-mcp fail CLOSED without their token, and accept it as
 * `Authorization: Bearer <tok>`. docs-mcp is UNAUTHENTICATED (ingestor/mcp_server.py
 * has no token gate; hermes wires it with no Authorization header). This extension
 * reads the tokens from the sandbox process env — HONCHO_MCP_TOKEN / FALKORDB_MCP_TOKEN —
 * which bin/pi injects (mirroring how it injects PI_LITELLM_KEY; see the bin/pi patch
 * in the slice). A shim whose token is absent from env is SKIPPED (its tools are not
 * registered), so an un-patched bin/pi or an un-installed shim degrades cleanly to
 * "fewer memory tools" rather than a wall of 401s. docs tools always register.
 *
 * ── Security posture (see SUMMARY.md for the council rationale) ──────────────
 * Honcho is a FULL-SHARED memory pool (operator-accepted; no per-peer isolation).
 * falkordb `graph_write` runs ARBITRARY destructive Cypher against ONE shared,
 * un-backed-up graph — an injected `MATCH (n) DETACH DELETE n` irrecoverably wipes
 * the entire fleet's graph memory. Pi is the most-quarantined, most prompt-injectable
 * agent in the fleet, so graph_write is OMITTED by default and gated behind the
 * explicit opt-in env `PI_MEMORY_ALLOW_GRAPH_WRITE=1`. Pi's legitimate write need is
 * fully covered by the idempotent, identifier-validated `remember_fact`.
 *
 * Mirrors the house style of pi/inference-local.ts (default-export factory,
 * type-only ExtensionAPI import, host.docker.internal, env-interpolated secrets).
 */
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

// ── config: endpoints + tokens (all overridable by env; host.docker.internal
//    defaults mirror hermes-fleet-v1.yaml + the shim launchers) ───────────────
const DOCS_MCP_URL     = process.env.DOCS_MCP_URL     || "http://host.docker.internal:8765/mcp";
const HONCHO_MCP_URL   = process.env.HONCHO_MCP_URL   || "http://host.docker.internal:7082/mcp";
const FALKORDB_MCP_URL = process.env.FALKORDB_MCP_URL || "http://host.docker.internal:7083/mcp";

const HONCHO_TOKEN   = process.env.HONCHO_MCP_TOKEN   || "";
const FALKORDB_TOKEN = process.env.FALKORDB_MCP_TOKEN || "";

// Pi's Honcho peer id (Phase 15 pre-creates peer "pi"). honcho_* tools default
// `peer` to this so the model never needs to know its own id; it can still override.
const DEFAULT_PEER = process.env.PI_MEMORY_PEER || "pi";

// graph_write is DESTRUCTIVE + fleet-wide + un-backed-up → opt-in only.
const ALLOW_GRAPH_WRITE = process.env.PI_MEMORY_ALLOW_GRAPH_WRITE === "1";

// Per-call transport budget. Matches honcho-mcp's own 20s HONCHO_MCP_TIMEOUT_MS
// so we don't abort a call the shim would still answer.
const CALL_TIMEOUT_MS = parseInt(process.env.PI_MEMORY_TIMEOUT_MS || "20000", 10);

// ── minimal MCP-over-HTTP (JSON-RPC 2.0) client ─────────────────────────────
let _rpcId = 0;

interface McpTarget { url: string; token?: string; label: string; }

/**
 * callTool — one authenticated `tools/call` POST against a stateless
 * StreamableHTTP MCP shim. Returns the tool's decoded result object (which may
 * itself carry a shim-level `{ error }`), or a transport-level `{ error }`.
 * Never throws.
 */
async function callTool(
  target: McpTarget,
  name: string,
  args: Record<string, unknown>,
  ctx: ExtensionContext,
): Promise<Record<string, unknown>> {
  const id = ++_rpcId;
  const body = JSON.stringify({ jsonrpc: "2.0", id, method: "tools/call", params: { name, arguments: args } });

  // The StreamableHTTP transport REQUIRES both media types in Accept (else 406),
  // and JSON content-type on POST. Verified in both shims' test.mjs rpc() helper.
  const headers: Record<string, string> = {
    "content-type": "application/json",
    accept: "application/json, text/event-stream",
  };
  if (target.token) headers.authorization = `Bearer ${target.token}`;

  // Bound the call by our own timeout AND honor pi's turn-abort signal (Esc).
  const ac = new AbortController();
  const timer = setTimeout(() => ac.abort(), CALL_TIMEOUT_MS);
  const onAbort = () => ac.abort();
  ctx.signal?.addEventListener("abort", onAbort);

  try {
    const res = await fetch(target.url, { method: "POST", headers, body, signal: ac.signal });
    const raw = await res.text();

    if (!res.ok) {
      // 401 here = missing/rotated token; 403 "policy_denied" = egress not allowed yet.
      const hint = res.status === 401 ? " (token missing/rotated?)"
                 : /policy_denied/.test(raw) ? " (egress not allowed by pi-v1 policy?)"
                 : "";
      return { error: `${target.label} HTTP ${res.status}${hint}: ${raw.slice(0, 300)}` };
    }

    // enableJsonResponse:true → plain JSON. Fall back to SSE `data: {...}` framing,
    // exactly like the shims' own rpc() parser.
    let rpc: any = null;
    try { rpc = JSON.parse(raw); }
    catch { const m = raw.match(/data: (\{.*\})/s); if (m) { try { rpc = JSON.parse(m[1]); } catch { /* */ } } }
    if (!rpc) return { error: `${target.label}: unparseable response: ${raw.slice(0, 300)}` };
    if (rpc.error) return { error: `${target.label} JSON-RPC error: ${JSON.stringify(rpc.error)}` };

    // A tools/call result is { content: [{ type:"text", text:"<json>" }], isError? }.
    // The shims JSON-encode their tool output (incl. their own {error}) in that text.
    if (rpc.result?.isError) {
      const t = rpc.result?.content?.[0]?.text;
      return { error: `${target.label} tool error: ${t || JSON.stringify(rpc.result)}` };
    }
    const text = rpc.result?.content?.[0]?.text;
    if (typeof text !== "string") return { error: `${target.label}: no text content in result: ${JSON.stringify(rpc.result).slice(0, 300)}` };
    try { return JSON.parse(text); } catch { return { text }; }  // non-JSON tool text → pass through
  } catch (e: any) {
    const why = e?.name === "AbortError" ? (ctx.signal?.aborted ? "cancelled" : `timeout after ${CALL_TIMEOUT_MS}ms`) : (e?.message || String(e));
    return { error: `${target.label} unreachable at ${target.url} (${why})` };
  } finally {
    clearTimeout(timer);
    ctx.signal?.removeEventListener("abort", onAbort);
  }
}

// Wrap a decoded tool result as a Pi tool result. `isError` is set whenever the
// decoded object carries an `error` (transport OR shim-domain), so the LLM sees
// failures as errors rather than as a "successful" empty answer.
// NOTE: `isError` is validated against pi's ToolResultEventResult / ToolExecutionEndEvent
// (which mirror AgentToolResult) — see SUMMARY.md "verified vs assumed".
const toolResult = (obj: Record<string, unknown>) => ({
  content: [{ type: "text" as const, text: JSON.stringify(obj, null, 2) }],
  details: obj,
  isError: typeof obj?.error === "string",
});

const DOCS: McpTarget     = { url: DOCS_MCP_URL,     label: "docs-mcp" };
const HONCHO: McpTarget   = { url: HONCHO_MCP_URL,   token: HONCHO_TOKEN,   label: "honcho-mcp" };
const FALKORDB: McpTarget = { url: FALKORDB_MCP_URL, token: FALKORDB_TOKEN, label: "falkordb-mcp" };

export default function (pi: ExtensionAPI) {
  const active: string[] = [];

  // ── docs-mcp (always; unauthenticated) ────────────────────────────────────
  pi.registerTool({
    name: "search_documents",
    label: "Search docs (RAG)",
    description: "Semantic search over the ai-stack-docs corpus (Qdrant + local embeddings). Read-only. Returns the top matching chunks with score + metadata. Empty until the corpus is ingested.",
    promptSnippet: "Search the ai-stack documentation corpus for relevant passages",
    promptGuidelines: ["Use search_documents to ground answers about ai-stack in the indexed docs before answering from memory."],
    parameters: Type.Object({
      query: Type.String({ description: "natural-language search query" }),
      top_k: Type.Optional(Type.Integer({ minimum: 1, maximum: 50, description: "how many chunks to return (default 5)" })),
    }),
    async execute(_id, params, _signal, _onUpdate, ctx) {
      const args: Record<string, unknown> = { query: params.query };
      if (params.top_k !== undefined) args.top_k = params.top_k;
      return toolResult(await callTool(DOCS, "search_documents", args, ctx));
    },
  });
  active.push("search_documents");

  // ── honcho-mcp (only if its token was injected) ───────────────────────────
  if (HONCHO_TOKEN) {
    pi.registerTool({
      name: "honcho_remember",
      label: "Remember (Honcho)",
      description: "Persist a turn/observation to shared fleet memory (Honcho). FULL-SHARED: anything remembered is recallable by any fleet agent. `peer` defaults to this agent ('pi').",
      promptSnippet: "Persist a durable note/observation to shared fleet memory",
      promptGuidelines: ["Use honcho_remember to record durable facts/decisions worth recalling in a later session."],
      parameters: Type.Object({
        content: Type.String({ description: "what to remember (a statement/observation)" }),
        peer: Type.Optional(Type.String({ description: "agent id to attribute this to (default: pi)" })),
        session: Type.Optional(Type.String({ description: "session id (default: fleet)" })),
      }),
      async execute(_id, params, _signal, _onUpdate, ctx) {
        const args: Record<string, unknown> = { content: params.content, peer: params.peer || DEFAULT_PEER };
        if (params.session !== undefined) args.session = params.session;
        return toolResult(await callTool(HONCHO, "honcho_remember", args, ctx));
      },
    });

    pi.registerTool({
      name: "honcho_recall",
      label: "Recall representation (Honcho)",
      description: "Return Honcho's derived representation (durable facts/beliefs) for a peer. Read-only. `peer` defaults to 'pi'; pass `target` for one peer's view of another.",
      promptGuidelines: ["Use honcho_recall to retrieve what the fleet durably knows about a peer before acting."],
      parameters: Type.Object({
        peer: Type.Optional(Type.String({ description: "whose representation (default: pi)" })),
        target: Type.Optional(Type.String({ description: "peer whose view you want (default: the peer's own)" })),
        session: Type.Optional(Type.String()),
      }),
      async execute(_id, params, _signal, _onUpdate, ctx) {
        const args: Record<string, unknown> = { peer: params.peer || DEFAULT_PEER };
        if (params.target !== undefined) args.target = params.target;
        if (params.session !== undefined) args.session = params.session;
        return toolResult(await callTool(HONCHO, "honcho_recall", args, ctx));
      },
    });

    pi.registerTool({
      name: "honcho_ask",
      label: "Ask memory (Honcho)",
      description: "Ask a natural-language question answered from a peer's derived memory (dialectic query). Read-only. `peer` defaults to 'pi'.",
      promptGuidelines: ["Use honcho_ask to query fleet memory in natural language (e.g. 'what do we know about the deploy pipeline?')."],
      parameters: Type.Object({
        query: Type.String({ description: "natural-language question" }),
        peer: Type.Optional(Type.String({ description: "whose memory to ask (default: pi)" })),
        session: Type.Optional(Type.String()),
      }),
      async execute(_id, params, _signal, _onUpdate, ctx) {
        const args: Record<string, unknown> = { query: params.query, peer: params.peer || DEFAULT_PEER };
        if (params.session !== undefined) args.session = params.session;
        return toolResult(await callTool(HONCHO, "honcho_ask", args, ctx));
      },
    });

    pi.registerTool({
      name: "honcho_search",
      label: "Search messages (Honcho)",
      description: "Semantic search over a peer's stored messages. Read-only. `peer` defaults to 'pi'.",
      parameters: Type.Object({
        query: Type.String({ description: "search query" }),
        peer: Type.Optional(Type.String({ description: "whose messages (default: pi)" })),
        limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 100, description: "max hits (default 10)" })),
      }),
      async execute(_id, params, _signal, _onUpdate, ctx) {
        const args: Record<string, unknown> = { query: params.query, peer: params.peer || DEFAULT_PEER };
        if (params.limit !== undefined) args.limit = params.limit;
        return toolResult(await callTool(HONCHO, "honcho_search", args, ctx));
      },
    });

    active.push("honcho_remember", "honcho_recall", "honcho_ask", "honcho_search");
  }

  // ── falkordb-mcp (only if its token was injected) ─────────────────────────
  if (FALKORDB_TOKEN) {
    pi.registerTool({
      name: "remember_fact",
      label: "Remember fact (graph)",
      description: "Idempotently store a fact as a graph edge (subject)-[predicate]->(object) in the shared fleet graph. Safe/additive: MERGEs on name identity, validates identifiers, passes values as params. Predicate must be a relationship type (letters/digits/_ , starts with a letter).",
      promptSnippet: "Record a (subject)-[predicate]->(object) fact in the shared fleet graph",
      promptGuidelines: ["Use remember_fact for simple relational facts; it is the safe additive way to write to the shared graph."],
      parameters: Type.Object({
        subject: Type.String(),
        predicate: Type.String({ description: "relationship type: letters/digits/_ , must start with a letter" }),
        object: Type.String(),
        subject_label: Type.Optional(Type.String({ description: "node label for subject (default: Entity)" })),
        object_label: Type.Optional(Type.String({ description: "node label for object (default: Entity)" })),
      }),
      async execute(_id, params, _signal, _onUpdate, ctx) {
        const args: Record<string, unknown> = { subject: params.subject, predicate: params.predicate, object: params.object };
        if (params.subject_label !== undefined) args.subject_label = params.subject_label;
        if (params.object_label !== undefined) args.object_label = params.object_label;
        return toolResult(await callTool(FALKORDB, "remember_fact", args, ctx));
      },
    });

    pi.registerTool({
      name: "recall_related",
      label: "Recall related (graph)",
      description: "Return the entities directly related to `name` in the shared fleet graph (neighbors + relationship types + labels). Read-only.",
      promptGuidelines: ["Use recall_related to explore what the shared graph connects to a named entity."],
      parameters: Type.Object({
        name: Type.String({ description: "entity name to expand from" }),
        limit: Type.Optional(Type.Integer({ minimum: 1, maximum: 200, description: "max neighbors (default 25)" })),
      }),
      async execute(_id, params, _signal, _onUpdate, ctx) {
        const args: Record<string, unknown> = { name: params.name };
        if (params.limit !== undefined) args.limit = params.limit;
        return toolResult(await callTool(FALKORDB, "recall_related", args, ctx));
      },
    });

    pi.registerTool({
      name: "graph_query",
      label: "Graph query (read-only Cypher)",
      description: "Run a READ-ONLY Cypher query (GRAPH.RO_QUERY) against the shared fleet-memory graph. Write clauses are rejected by the shim. Pass `params` (values only) to avoid injection.",
      promptGuidelines: ["Use graph_query for read-only Cypher; it cannot mutate the graph."],
      parameters: Type.Object({
        cypher: Type.String({ description: "read-only Cypher" }),
        params: Type.Optional(Type.Record(Type.String(), Type.Unknown(), { description: "query parameter values" })),
      }),
      async execute(_id, params, _signal, _onUpdate, ctx) {
        const args: Record<string, unknown> = { cypher: params.cypher };
        if (params.params !== undefined) args.params = params.params;
        return toolResult(await callTool(FALKORDB, "graph_query", args, ctx));
      },
    });

    active.push("remember_fact", "recall_related", "graph_query");

    // graph_write: DESTRUCTIVE, shared, un-backed-up → registered ONLY under the
    // explicit PI_MEMORY_ALLOW_GRAPH_WRITE=1 opt-in. Default Pi has no way to run
    // arbitrary write Cypher against the one shared fleet graph.
    if (ALLOW_GRAPH_WRITE) {
      pi.registerTool({
        name: "graph_write",
        label: "Graph write (DESTRUCTIVE Cypher)",
        description: "⚠️ DESTRUCTIVE & SHARED: arbitrary write Cypher (GRAPH.QUERY) against the ONE fleet-memory graph every agent shares — NO isolation, NO backup. An unbounded DELETE/DROP irrecoverably wipes fleet memory. Prefer remember_fact. ALWAYS scope destructive MATCHes with WHERE + LIMIT. Every call is audit-logged by the shim.",
        promptGuidelines: ["Prefer remember_fact over graph_write; only use graph_write for graph shapes remember_fact can't express, and always bound destructive MATCHes with WHERE and LIMIT."],
        parameters: Type.Object({
          cypher: Type.String({ description: "write Cypher — scope destructive MATCHes with WHERE + LIMIT" }),
          params: Type.Optional(Type.Record(Type.String(), Type.Unknown(), { description: "query parameter values (use instead of string interpolation)" })),
        }),
        async execute(_id, params, _signal, _onUpdate, ctx) {
          const args: Record<string, unknown> = { cypher: params.cypher };
          if (params.params !== undefined) args.params = params.params;
          return toolResult(await callTool(FALKORDB, "graph_write", args, ctx));
        },
      });
      active.push("graph_write");
    }
  }

  // One-line summary at session start so the operator can see which memory tools
  // are live (and which shims were skipped for a missing token). Mirrors
  // dynamic-tools.ts's session_start notify.
  pi.on("session_start", (_event, ctx) => {
    const skipped: string[] = [];
    if (!HONCHO_TOKEN) skipped.push("honcho (no HONCHO_MCP_TOKEN)");
    if (!FALKORDB_TOKEN) skipped.push("falkordb (no FALKORDB_MCP_TOKEN)");
    if (!ALLOW_GRAPH_WRITE && FALKORDB_TOKEN) skipped.push("graph_write (opt-in: PI_MEMORY_ALLOW_GRAPH_WRITE=1)");
    let msg = `fleet-memory tools: ${active.join(", ")}`;
    if (skipped.length) msg += ` | skipped: ${skipped.join("; ")}`;
    ctx.ui.notify(msg, "info");
  });
}
