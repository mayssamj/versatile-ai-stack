# Phase 29 — Understand-Anything (cross-runtime codebase knowledge graphs)

**Status:** DESIGN v2 (post-§24 council; awaiting user review)
**Date:** 2026-06-21
**Branch:** `feat/understand-anything-phase29` (worktree)
**Author:** manager (single-entrance)
**Council:** reviewing-engineer + techlead + sre-engineer + PM → all SHIP-WITH-FIXES; fixes folded into v2 (see §12).

---

## 1. Problem

The `Understand-Anything` Claude Code plugin (v2.7.4, marketplace `Egonex-AI/Understand-Anything`,
upstream `Lum1104/Understand-Anything`, MIT) is **already installed** and its skills/subagents are live
in the interactive Claude Code session. It is **not** part of the ai-stack machinery (no phase → not
reproducible on cold-install; no doctor check; no `services.yml`/`EXPLORE` entry; no docs/tutorial) and —
critically — **cannot be used from any runtime other than an interactive Claude Code session.**

User requirement: *"I don't want this limited to Claude Code. The architecture should enable using it in
Hermes as well."* (Hermes = the containerized agent fleet.)

## 2. Key facts (verified, not assumed)

- **Generation engine = Claude-Code subagent orchestration.** `/understand` runs a 7-phase pipeline driven
  by Claude Code subagents. Heavy lifting (extract-structure.mjs, merge-batch-graphs.py, fingerprinting)
  is deterministic; semantic parts (summaries/tags/layers/tour) need the host agent's LLM. **Generation is
  bound to an agentic CLI.**
- **Querying is fully headless.** `@understand-anything/core` exports `loadGraph()`, `SearchEngine` (fuzzy,
  Fuse.js), `SemanticSearchEngine` (cosine over *pre-computed* embeddings), graph/layer/tour traversal —
  **zero LLM, zero network.** *Empirically proven by the council:* importing the built `core` from outside
  the plugin monorepo via a `file:` npm dependency + `npm install` + bare import **works**.
- **The graph is a metadata map, not the source.** `GraphNode` has `summary`, `tags`, `filePath`,
  `lineRange`, `complexity` — **no source-content field** (verified). Consumers needing code must read the
  file themselves.
- **The graph is portable & committable.** `.understand-anything/knowledge-graph.json` (+ `meta.json`,
  `config.json`, `fingerprints.json`) is self-contained, relative-path-sanitized JSON. **Realistic size is
  larger than first estimated: ~3–5 MB** (a 3,929-node graph measured at 3.8 MB); ai-stack will be on the
  high end. `project.gitCommitHash` is stored in the graph (enables staleness detection).
- **The plugin ships NO MCP server** (verified). The cross-runtime bridge is **net-new** (the shim).
- **`/understand` writes no embeddings** (verified). Default query path = fuzzy `SearchEngine` (needs
  nothing); `SemanticSearchEngine` with an empty embeddings map silently returns zero — so the shim must
  use `SearchEngine`, not expect semantic fallback.
- **OpenShell sandboxes do not bind-mount the host** (`installer/phases/04f_hermes_fleet.sh:200` — "copies,
  doesn't bind-mount"). A fleet container therefore cannot read the host's committed graph *or* the host
  source directly. Its only proven channel to host capabilities is **HTTP via `host.docker.internal`**
  (LiteLLM :4000, Sourcegraph :7080 — both verified live). Lumen's own notes (`16_lumen.sh:9-18`) confirm
  the sandbox cannot reach a host **stdio** process — that's why HTTP is mandatory for the fleet.
- **Hermes has a proven capability channel:** per-profile HTTP MCP wiring via `installer/lib/mcp.sh`
  (`configure_hermes_mcp_sourcegraph()`), with a live E2E proof in `installer/smoke/27.sh`.
- **The dashboard is a Vite app whose token gate + graph/file-content endpoints live in Vite's
  `configureServer` middleware** (verified in `vite.config.ts`) — they run only under `vite dev`/`vite
  preview`. A plain static server of `dist/` returns 404 on every API call. The launcher must run
  `vite preview` (not "any static server").

## 3. Decisions (user-approved 2026-06-21)

1. **Integration depth:** Full first-class, **opt-in** Phase 29 (aionui/mempalace family).
2. **Generation scope:** *Central generate, universal consume.* Generate via `/understand` in Claude Code
   or Pi → commit the graph → all runtimes **consume**. Hermes-side **generation** is explicitly
   **deferred** (documented follow-up, surfaced to the user in plain language in `doc/UNDERSTAND.md`).
3. **Hermes transport:** **HTTP MCP server on the host**, wired per Hermes profile via `lib/mcp.sh`
   (sourcegraph pattern) — gated, non-fatal, stable token, short connect-timeout.
4. **Launcher:** both — a `mayssam-ai-stack.sh understand-dashboard` wrapper (runs `vite preview`,
   health-gated, auto-open) **and** documented native `/understand…` commands. Built **last** (human-only
   value).

## 4. Architecture — generate centrally, consume everywhere; server on the host

```
            ┌─────────────────────────────────────────────────────────┐
   GENERATE │  /understand  (Claude Code session OR Pi, from MAIN)     │
            │      → .understand-anything/knowledge-graph.json         │
            │      → COMMITTED to the repo (single source of truth)    │
            └───────────────────────────┬─────────────────────────────┘
                                         │
                 understand-mcp  (Node shim wrapping core query API)
                 runs ON THE HOST, where the repo source also lives
                 ├── stdio entrypoint  ─►  host Claude Code, Pi-on-host (local)
                 └── http  entrypoint  ─►  Hermes fleet profiles
                          (host.docker.internal:PORT, wired via lib/mcp.sh)
                          ▲ server reads graph AND source from host checkout
                          └─ read_node_source(id) returns the actual snippet

            understand-dashboard  (vite preview, GRAPH_DIR=<repo>)  ─►  humans
```

**Why the server runs on the host:** the sandbox can't read the host graph or source. Running the HTTP
server on the host means it has both the committed graph *and* the source tree, so it can serve
orientation (graph) *and* the actual code (`read_node_source`) to fleet agents over HTTP — closing the
"map with no terrain" gap.

### 4.1 `understand-mcp` shim (net-new — the cross-runtime core)
A small Node package wrapping `@understand-anything/core`, with **two explicit entrypoints**:
- `understand-mcp --stdio` → `StdioServerTransport` (registered with `claude mcp add`; spawned per local client).
- `understand-mcp --http --port N --token …` → `StreamableHTTPServerTransport`, loopback bind, token-gated
  (run as a managed daemon; this is what Hermes connects to). MCP SDK version pinned in the shim's
  `package.json`.

**Behavior:**
- **Startup never throws.** Catch `loadGraph` exceptions (incl. invalid-JSON) at startup; start
  successfully regardless; defer "no/invalid graph" to a clear per-tool error ("run `/understand` and
  commit the graph"). This protects Claude Code's MCP init when the server is registered `-s user` but the
  CWD has no graph.
- **Load the graph once** at startup (held in memory); expose a `reload_graph()` tool (and/or `fs.watch`)
  so a regenerate doesn't require a restart.
- Uses `SearchEngine` (fuzzy). Semantic search deferred; tool descriptions say "fuzzy keyword search".

**Tools (read-only, no LLM):**
- `graph_search(query, limit?)` → **hydrated** hits `{id, name, type, filePath, lineRange, summary, score}`
  (not raw `{nodeId, score}` — avoids a round-trip per hit over a slow HTTP MCP).
- `get_node(id, {neighbors?})` → node + incident edges (+ neighbor nodes when asked).
- `read_node_source(id)` → the source snippet for the node's `[filePath, lineRange]`, read from the host
  checkout. **This is the graph→source bridge that makes Hermes actionable.** Path-validated against the
  graph (no arbitrary file reads).
- `list_layers()` → architectural layers + node ids.
- `get_tour()` → guided tour steps.
- `project_summary()` → project meta **including staleness**: graph `gitCommitHash` vs current repo HEAD
  ("graph at X; repo at Y; N commits behind").

### 4.2 Phase `installer/phases/29_understand.sh` (opt-in, idempotent, reversible)
1. **Prechecks** (mirror P26/P28): `command -v node` with `node --version` ≥ v22; `command -v pnpm`. Fail
   with a clear message if absent (deps.sh provides both, but P29 is opt-in and may run on a drifted box).
   Worktree guard via `installer/lib/worktree.sh` (refuse to operate the live stack from a worktree;
   offline build steps allowed).
2. **Resolve plugin root** via the documented fallback chain (`CLAUDE_PLUGIN_ROOT`,
   `~/.understand-anything-plugin`, symlink walk) — **never** the version-pinned cache path. Create/refresh
   a stable `~/.understand-anything-plugin` symlink → resolved plugin root.
3. **Build the plugin** (marketplace path has no `dist/`): `pnpm install --frozen-lockfile` in the plugin
   root, then build `@understand-anything/core` and (later) `@understand-anything/dashboard`. **Gate on
   `dist/index.js` existing.** Stream output `| tail`; log "first run may take 3–5 min (tree-sitter native
   builds)". Idempotent via mtime/hash short-circuit.
4. **Build the shim** at a **committed** source path `understand-mcp/` (NOT `vendor/` — `vendor/` is
   gitignored). The shim's `package.json` declares `@understand-anything/core` via
   `file:~/.understand-anything-plugin/packages/core` + the pinned MCP SDK; phase runs `npm install` there
   (proven to work). `understand-mcp/node_modules/` is gitignored (built at install). Write
   `understand-mcp/VERSION` stamped to the detected plugin version (precheck compares → re-run on drift).
5. **Wire stdio MCP into host Claude Code idempotently:** `claude mcp remove -s user understand-anything
   2>/dev/null; claude mcp add -s user understand-anything -- <node> understand-mcp --stdio` (remove-then-
   add is idempotent; `-s user` matches the stack convention and avoids the committed-`.claude` leak-trap;
   graceful no-graph behavior makes `-s user` safe in unrelated repos). Pi-on-host inherits the same.
6. **Wire HTTP MCP into Hermes** via a new `configure_hermes_mcp_understand()` in `lib/mcp.sh` — mirror
   `configure_hermes_mcp_sourcegraph()` exactly: stable token from `.env` (`UNDERSTAND_MCP_TOKEN`,
   generated once), token via **STDIN** (never argv), **single** uploaded in-sandbox wire script run
   **once** (relay-contention fix), explicit `connect_timeout` in the wired stanza, per-profile, gated +
   non-fatal (absent token/server → skip+warn, fleet stays green).
7. Stamp on success. **Rollback documented in the phase header:** `claude mcp remove -s user
   understand-anything`; un-wire profiles; `rm -rf understand-mcp/node_modules vendor/understand-mcp`.

### 4.3 Launcher, doctor, smoke
- **Launcher** `mayssam-ai-stack.sh understand-dashboard [path]` — runs `vite preview` from the plugin root with
  `GRAPH_DIR=<repo>` on a **registered** loopback port (see §5), health-gated, auto-open (gated), honest
  non-daemon messaging; `stop` tears it down. (Not "any static server" — the API endpoints are Vite
  middleware.)
- **Doctor** `installer/doctor/checks/51_understand.sh` — **three states**, gated on the phase-29 stamp:
  (a) phase not installed → skip-clean (like check 50);
  (b) installed but no committed graph → **WARN** (actionable: "run `/understand .` from main and commit");
  (c) installed + graph present → **true E2E**: invoke `project_summary` (or `graph_search`) via the stdio
  entrypoint, assert a known field in stdout; FAIL only on a real query failure. Also surface staleness as
  a WARN (graph SHA vs HEAD). Never emit PASS without a real tool call (no `pgrep`/`curl /health` green).
- **Smoke** `installer/smoke/29.sh` + `mayssam-ai-stack.sh test understand` — the credibility artifact (mirrors
  `smoke/27.sh`): run a real `graph_search`/`read_node_source` **from inside a Hermes profile** against the
  committed ai-stack graph over HTTP MCP and assert a recognizable ai-stack node (e.g. a LiteLLM node).
  This is what proves "usable in Hermes" rather than "wired, trust me."

### 4.4 Boundary vs. existing code-search capabilities (avoid 3 confusable MCPs)
- **understand-mcp** = *orientation / architecture*: layers, tour, summaries, `project_summary`, `explain`,
  and a curated semantic **map** of the codebase. `read_node_source` is the bridge to code.
- **Sourcegraph MCP / Lumen** = *source retrieval*: "where is symbol/text X" over raw source.
- The distinction is encoded in each MCP tool's `description` (how an agent chooses) and stated in
  `doc/UNDERSTAND.md`. If Sourcegraph is present, the runbook shows the pair (understand = navigator,
  Sourcegraph = reader); `read_node_source` makes understand-mcp self-sufficient when it isn't.

## 5. Service classification & registry
- `services.yml`: new entry `understand_anything`, `type: mcp-server` (the durable artifact is the MCP
  server + dashboard; the plugin is a build input). `phase: "29"`, `network: host`. Assign **registered
  `host_port`s** (free ones verified at impl) for the HTTP MCP server and the dashboard so
  `11_port_collisions.sh` guards them and `help` can report them. `help:` block (what/why/usage/config).
- `doc/EXPLORE.html`: one new service card; bump the hardcoded service-count (subtitle + comment).

## 6. Documentation cohesion sweep (definition-of-done)
- `doc/UNDERSTAND.md` — runbook: what it is; generate→commit→consume model; per-runtime usage (Claude Code,
  Pi, Hermes via MCP); the graph→source boundary + Sourcegraph pairing; **"Keeping the graph fresh"**
  (when/how to regenerate, staleness signal); the deferred Hermes-generation note in one plain sentence;
  dashboard.
- `doc/TUTORIAL.md` — one lesson (generate on ai-stack from main → query from Claude Code → query from a
  Hermes profile → open dashboard); regenerate `TUTORIAL.html` via `installer/lib/build_tutorial_html.py`
  (`--check` drift guard); never hand-edit generated acts.
- `README.md`, `doc/COMPONENTS.md` — bump counts; **re-verify at impl** (today: doctor = 51 checks → 52;
  opt-in phases 7 → 8; services count drifts between README "42" and file count — reconcile in the sweep).
- `CHANGELOG.md` — Phase 29 entry. Per-service `help:` block (+ `help regen`).

## 7. Sample usage (on this repo) — observable success
1. `cd ~/ai-stack` (**main checkout**, not the worktree — R2), `/understand .` → produces
   `.understand-anything/knowledge-graph.json`.
2. **Commit** the graph (+ `meta.json`) on main; it's the shared artifact.
3. Demonstrate, with real recognizable output (not "it returned JSON"):
   - Claude Code (stdio): `graph_search("litellm")` → a real ai-stack node.
   - Hermes profile (HTTP): the `smoke/29.sh` query returning the same.
   - `read_node_source` on a node → the actual snippet.
4. `mayssam-ai-stack.sh understand-dashboard` → browser graph of ai-stack.
   `doc/UNDERSTAND.md` uses ai-stack itself as the worked example, including a copy-pasteable Hermes
   transcript.

## 8. Scope / YAGNI
- **In:** opt-in phase; `understand-mcp` shim (stdio+http) with `read_node_source` + staleness; dashboard
  launcher (last); doctor check (3-state, true E2E); `smoke/29.sh` Hermes E2E; services/EXPLORE; docs +
  tutorial; committed sample graph; Hermes HTTP wiring + boundary doc.
- **Out (deferred, flagged):** Hermes-side graph *generation*; semantic-search embeddings pipeline
  (default = fuzzy); auto-update-on-commit hooks (opt-in only, like mempalace); making it core (non-opt-in).

## 9. Risks & mitigations
- **R1 — plugin path/version drift:** resolve via fallback chain + stable `~/.understand-anything-plugin`
  symlink; shim VERSION stamp catches drift. Never hardcode `…/2.7.4/…`.
- **R2 — worktree wipes `.understand-anything/`** (upstream issue #133; the SKILL's Phase 0 redirects
  worktree output to main — verified in source): generate the sample from **main**; runbook says
  `cd ~/ai-stack` first.
- **R3 — MCP server down / slow:** startup never throws; explicit `connect_timeout` on the Hermes client
  stanza; non-fatal fan-out guards.
- **R4 — Node/pnpm absence on cold/drifted box:** explicit prechecks (§4.2.1).
- **R5 — committed-graph churn/bloat (~3–5 MB):** `.gitattributes` `knowledge-graph.json
  linguist-generated=true -diff` (suppress diff noise); `.gitignore` `.understand-anything/intermediate/`,
  `tmp/`, embeddings, `fingerprints.json`; **un-ignore** `knowledge-graph.json` + `meta.json`
  (`!.understand-anything/knowledge-graph.json`). Runbook: regenerate only on material drift, not per
  commit. Revisit LFS if it grows.
- **R6 — false-green doctor:** 3-state + true tool-call E2E (§4.3); no `pgrep`/`/health` PASS.
- **R7 — capability confusion (3 MCPs):** boundary doc + tool descriptions (§4.4).
- **R8 — MCP-add duplication:** remove-then-add idempotency (§4.2.5).

## 10. Definition of done
- Phase 29 installs idempotently from clean; re-run is a no-op; rollback documented and works.
- `understand-mcp` answers a query from **both** stdio (Claude Code) **and** HTTP (a Hermes profile) —
  verified live; `read_node_source` returns real source to a fleet agent.
- `smoke/29.sh` (Hermes E2E) and `mayssam-ai-stack.sh test understand` pass live; the transcript is in
  `doc/UNDERSTAND.md`.
- Doctor check 51 is 3-state, true E2E, WARNs on absent/stale, never false-green; live `doctor` green from
  **main**.
- Dashboard opens in a browser on the host; staleness is visible via `project_summary`.
- Docs + tutorial + counts cohesive (`build_tutorial_html.py --check` clean); sample graph committed;
  CHANGELOG updated; `.gitignore`/`.gitattributes` set.
- §24 council consensus recorded (done — §12); merged + pushed.

## 11. Build sequence (de-risk order, per PM)
1. `understand-mcp` shim + **stdio** into host Claude Code (proves headless query).
2. Generate + **commit** the ai-stack sample graph (from main) — unblocks all demos.
3. **HTTP** transport + Hermes wiring + `smoke/29.sh` real query from a profile — **the ship-gate
   milestone** (the user's actual ask); add `read_node_source`.
4. Staleness signal (`project_summary` + doctor WARN).
5. Doctor check, services.yml/EXPLORE, docs + tutorial + counts.
6. Dashboard launcher **last** (human-only nicety).

## 12. §24 council resolutions (debate → consensus: all four SHIP-WITH-FIXES)
- **[BLOCKER, techlead+reviewing] graph metadata-only + sandbox can't read host:** server runs on host;
  add `read_node_source`; document boundary + Sourcegraph pairing. → §4 intro, §4.1, §4.4.
- **[BLOCKER, reviewing] one process can't be both stdio+http:** two explicit entrypoints, pinned SDK. → §4.1.
- **[BLOCKER, sre] `claude mcp add` not idempotent:** remove-then-add. → §4.2.5.
- **[BLOCKER, sre] marketplace path has no dist/:** build plugin first, gate on dist, resolve via symlink. → §4.2.3.
- **[BLOCKER, sre+reviewing] dashboard isn't a static bundle:** launcher runs `vite preview`, registered
  port. → §2, §4.3, §5.
- **[MAJOR] vendor/ gitignored:** shim source committed under `understand-mcp/`, node_modules gitignored. → §4.2.4.
- **[MAJOR] doctor false-green:** 3-state + true tool-call E2E. → §4.3.
- **[MAJOR, PM] no Hermes E2E proof:** `smoke/29.sh` real query from a profile + transcript in docs. → §4.3, §7.
- **[MAJOR, PM+techlead] silent staleness:** `project_summary` + doctor WARN (graph SHA vs HEAD). → §4.1, §4.3.
- **[MAJOR, reviewing] SemanticSearchEngine returns empty:** use `SearchEngine`; describe as fuzzy. → §2, §4.1.
- **[MAJOR, reviewing] startup throws on bad graph:** never throw at startup; defer to tool errors. → §4.1.
- **[MAJOR, reviewing+sre] HTTP token provisioning:** stable `UNDERSTAND_MCP_TOKEN` in `.env`, STDIN-seeded. → §4.2.6.
- **[MAJOR, sre] ports unregistered:** assign registered host_ports for MCP + dashboard. → §5.
- **[MINOR, techlead] hydrate `graph_search` results; fold neighbors into `get_node`.** → §4.1.
- **[MINOR, debate] `-s user` vs `-s local`:** keep `-s user` (stack convention) + graceful no-graph. → §4.2.5.
- **[MINOR, debate] stdio-only (lumen) vs HTTP:** keep both; sandbox can't reach host stdio. → §2, §4.
- **[MINOR] graph size estimate wrong:** corrected to ~3–5 MB. → §2.
- **[MINOR, sre] gitignore/gitattributes for committed graph.** → R5.
- **[MINOR, sre] node/pnpm prechecks + build-time note.** → §4.2.1, §4.2.3.
