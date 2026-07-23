# Understand-Anything (Phase 30) — orientation for every runtime

**Opt-in.** A Claude Code plugin that maps a codebase into an interactive
**knowledge graph**, plus a net-new `understand-mcp` server that serves that graph
to the host (Claude Code + Pi) and the Hermes fleet. The pattern is
**generate centrally, consume everywhere**: you run `/understand` once, commit the
graph, and all runtimes read the same artifact.

For the catalog see [COMPONENTS.md](COMPONENTS.md); for the journey see
[TUTORIAL.md](TUTORIAL.md).

---

## What it is

The **Understand-Anything** plugin (already installed) analyzes a repo and writes an
interactive knowledge graph to `.understand-anything/knowledge-graph.json`:

- **nodes** = files / functions / classes / concepts, each with a summary,
  `file:line`, and tags
- **edges** = `imports` / `calls` / `depends_on` / … relationships
- plus **architectural layers** and a **guided tour**

Plugin skills: `/understand`, `/understand-dashboard`, `/understand-chat`,
`/understand-explain`, `/understand-diff`, `/understand-domain`,
`/understand-onboard`, `/understand-knowledge`.

**Split of concerns:** *generation* (`/understand`) is bound to Claude Code subagent
orchestration (it fans out analyzer agents). *Querying* is fully **headless** — no
LLM, no network — so any runtime can read the graph cheaply.

---

## The stack integration

The graph is the **shared artifact**. You generate it in Claude Code or Pi, commit
`.understand-anything/knowledge-graph.json` to the repo, and every runtime consumes it.

A net-new **`understand-mcp`** server (in the repo at `understand-mcp/`) wraps the
plugin's query core and exposes the graph as MCP tools over two transports:

| Transport | Consumer | Wiring |
|---|---|---|
| **stdio** | host Claude Code + Pi | `claude mcp add -s user understand-anything` |
| **http** | the Hermes fleet | `http://host.docker.internal:<PORT>/mcp`, token-gated, wired **per-profile** (same mechanism as Sourcegraph) |

The server runs **on the host** — where the repo source actually lives — so it can
serve both the **graph** and the **real source** behind it.

### MCP tools

| Tool | Purpose |
|---|---|
| `graph_search(query, limit?)` | hydrated hits `{id,name,type,filePath,lineRange,summary,score}` |
| `get_node(id, neighbors?)` | a node + its incident edges (and, optionally, the connected nodes) |
| `read_node_source(id, context?)` | the actual source snippet for the node's `file:lineRange` — the graph→source bridge that makes fleet agents actionable **without the repo mounted** |
| `list_layers()` | the architectural layers |
| `get_tour()` | the guided onboarding tour |
| `project_summary()` | languages / frameworks / description / counts **+ staleness** (graph commit vs repo HEAD) |
| `reload_graph()` | re-read the graph after a regeneration |

---

## Boundary: orientation vs source retrieval

Keep these straight — they answer different questions:

- **`understand-mcp` = orientation / architecture.** Where things live, the layers,
  the tour, the summaries. "What is this system and how is it shaped?"
- **Sourcegraph MCP / Lumen = source retrieval.** Find a symbol or a string in the
  raw code. "Where exactly is `X` and what does the code say?"
- `read_node_source` **bridges** orientation to code when Sourcegraph isn't present —
  enough to act on a node, not a full code search.

---

## Usage (worked on this repo, `ai-stack`)

### 1. Generate & commit the graph

```bash
cd ~/ai-stack          # MAIN checkout, not a worktree
/understand .          # in Claude Code (or Pi)
git add .understand-anything/knowledge-graph.json
git commit -m "chore(understand): refresh knowledge graph"
```

> **Run from the main checkout.** A worktree's `.understand-anything/` is ephemeral
> (it vanishes when the worktree is removed); the skill redirects generation to main
> anyway. Generate on main, commit there, let every runtime read the committed graph.

### 2. Query from Claude Code (stdio)

Once registered (`claude mcp add -s user understand-anything`), the tools are live in
the session:

```text
graph_search("litellm")
  → hits across the LiteLLM gateway config, the key store, the model wiring …

read_node_source("<node-id-from-the-hit>")
  → the actual source lines for that node's file:lineRange
```

### 3. Query from the Hermes fleet (http)

Phase 30 wires the fleet **per-profile** (each profile gets the `understand-anything`
HTTP MCP entry; not inherited). Prove a fleet profile can reach the `ai-stack` graph:

```bash
mayssam-ai-stack.sh test understand     # E2E: fleet profile → http MCP → ai-stack graph
```

### 4. Open the dashboard

```bash
mayssam-ai-stack.sh understand-dashboard            # current repo
mayssam-ai-stack.sh understand-dashboard ~/ai-stack # explicit path
```

Launches the interactive browser dashboard (Vite preview from the plugin),
health-gated, then auto-opens. The native `/understand-dashboard` skill works too.

### 5. Keeping the graph fresh

The graph is a **periodically-refreshed snapshot, not live.** It reflects the commit
it was generated at, not your working tree.

- `project_summary()` and `mayssam-ai-stack.sh doctor` surface **staleness** (graph SHA vs
  repo HEAD).
- Re-run `/understand` on **material drift** (new layers, big refactors, new
  subsystems) — **not** every commit. After regenerating, commit the graph and call
  `reload_graph()` (or restart consumers).

### 6. Install / uninstall

```bash
mayssam-ai-stack.sh install understand     # opt-in; needs Node >= 22 + pnpm
```

Rollback:

```bash
claude mcp remove -s user understand-anything   # drop the stdio registration
# then un-wire the http MCP entry from the Hermes profiles
```

---

## Deferred / known gaps

Honest about what's **not** in this cycle:

- **Hermes-side generation is deferred.** Generation needs an agentic CLI; only
  **consumption** is wired into Hermes this cycle. The fleet reads the graph, it
  doesn't build it.
- **Semantic search is deferred.** `graph_search` is **fuzzy keyword** by default —
  no embeddings. For semantic code recall, reach for Lumen / the docs RAG path.

---

## See also

- [COMPONENTS.md](COMPONENTS.md) — the full stack catalog
- [TUTORIAL.md](TUTORIAL.md) — the guided platform journey
- Upstream: <https://github.com/Lum1104/Understand-Anything>
