# Service Playground — a 2-minute hands-on for every service

This is the appendix to [the 7-act tutorial](TUTORIAL.md). The tutorial teaches the
platform as a *story*; this page is the *index* — one self-contained, ~2-minute hands-on
entry per service, alphabetical, so you can jump straight to whichever service you care
about right now.

Every command below is verified against `services.yml` and the per-service `help` blocks.
Everything is **local-first**: nothing leaves your machine unless you wire in a cloud key.
Services are reached by **name** (`http://litellm:4000`, `http://phoenix:6006`), which
requires the one-time `sudo bash vz-ai-stack.sh prepare-sudo` step (Act I, L2); where a
bare hostname won't resolve yet, the loopback `127.0.x.x` fallback is noted.

## Tier legend

| Tier | Meaning | How you try it |
|------|---------|----------------|
| **Tier 1** | live-widget | Has a first-party in-browser demo in `doc/TUTORIAL.html` (start `vz-ai-stack.sh tutorial-serve`). Five services: **litellm · qdrant · docs_mcp · honcho · phoenix**. |
| **Tier 2** | guided-walkthrough | Ships a web UI you open in the browser — chat UIs, dashboards, watchable sims. |
| **Tier 3** | API / CLI | Driven from a terminal: a `curl` endpoint, a `bin/<tool>` CLI, or a library import. |
| **Tier 4** | infra | A behind-the-scenes capability (storage, a guardrail hook, a virtual key, a sandbox) — you verify it's working rather than "open" it. |

General health/status for any service:

```
vz-ai-stack.sh status            # one-line health per service
vz-ai-stack.sh doctor            # full check suite
vz-ai-stack.sh help <name>       # what / config / usage for one service
```

---

## ace · Tier 3 · Phase 17

**What it is:** Batch CLI that evolves reusable agent-context playbooks via LiteLLM (opt-in).

**Setup/health:** `bin/ace --help` · results land under `ace/results/`.

**Try it:** `bin/ace eval.finance.run --task_name finer --mode eval_only --save_path results/smoke`

**Notes:** Opt-in (not in `install all`). Every call routes through LiteLLM, so the batch shows up as spans in Phoenix.

## agentscope · Tier 3 · Phase 33

**What it is:** Multi-agent simulation framework for building/scaling your own agent swarms, run via `bin/agentscope` (opt-in).

**Setup/health:** `vz-ai-stack.sh test 33` · sims live in `agentscope/sims/`.

**Try it:** `bin/agentscope agentscope/sims/smoke_sim.py`

**Notes:** Opt-in; needs the host venv (`agentscope/.venv`). Optional Studio web GUI (`AGENTSCOPE_STUDIO=1`) on `http://127.0.0.1:5275` visualizes OTLP spans. On a 24 GB box keep swarms small on local models or route to a metered cloud model.

## aionui · Tier 2 · Phase 28

**What it is:** Desktop + browser Cowork workspace over your stack (LiteLLM models + a Hermes agent via ACP).

**Setup/health:** `vz-ai-stack.sh install aionui && vz-ai-stack.sh start aionui`

**Try it:** open `http://aionui:25808` (web UI), or `open -a AionUi` (desktop app).

**Notes:** Opt-in. The prebuilt `aionui-web` server provides the browser UI (the cask ships no web server).

## aitown · Tier 2 · Phase 36

**What it is:** A watchable virtual town — AI characters live, move, and chat in a Convex world (browser sim).

**Setup/health:** `bash ~/ai-stack/bin/start-aitown.sh`

**Try it:** open `http://aitown:5273` (fallback `http://127.0.10.19:6791`).

**Notes:** Opt-in (Phase 36). Convex admin URL must use the loopback alias, not `127.0.0.1`. Every agent call routes through LiteLLM — watch the town think in Phoenix.

## autofyn · Tier 2 · Phase 07

**What it is:** Docker-compose coding-automation agent with a dashboard UI on `:3400`.

**Setup/health:** `docker compose -f ~/ai-stack/autofyn/docker-compose.yml ps`

**Try it:** open `http://autofyn:3400`.

**Notes:** Also reachable via the tutorial page's opt-in **Launch a service** panel (`--launch-enabled`).

## autoreason · Tier 3 · Phase 11

**What it is:** Clone-only research artifact: an A/B/AB self-refinement tournament (the reference behind HALO's restraint).

**Setup/health:** `ls ~/ai-stack/halo/autoreason/`

**Try it:** `open ~/ai-stack/halo/autoreason/README.md` then read `tasks/` and `experiments/`.

**Notes:** Clone-only — it's reference material, not a running service.

## blaxel_cli · Tier 3 · Phase 12

**What it is:** Cloud-only CLI for deploying agents on Blaxel; no local service runs.

**Setup/health:** `blaxel version`

**Try it:** `blaxel login && blaxel workspaces`

**Notes:** Cloud-only — requires a Blaxel account/keys. Nothing runs on-box.

## byterover_cli · Tier 3 · Phase 09

**What it is:** Host npm-global Node CLI for a local, curatable context-tree memory (the `brv` command).

**Setup/health:** `command -v brv` · `brv status`

**Try it:** `brv query 'what did I store about X'`

**Notes:** An optional fifth memory slot — a hand-curated context tree you edit yourself (vs Honcho's auto-derived facts).

## chatdev · Tier 2 · Phase 35

**What it is:** Multi-agent software-company sim (Vue + FastAPI web app; role agents collaborate to build software).

**Setup/health:** `vz-ai-stack.sh install chatdev && vz-ai-stack.sh start chatdev`

**Try it:** open `http://chatdev:5274` (also via the tutorial **Launch a service** panel).

**Notes:** Opt-in (Phase 35). Needs the `127.0.10.x` lo0 alias bound (+ restart) for its hostname. Role agents route through LiteLLM → traced in Phoenix.

## claw3d · Tier 2 · Phase 19

**What it is:** Next.js 3D virtual-office UI to visualize and chat with stack agents.

**Setup/health:** `curl -s -o /dev/null -w '%{http_code}' http://localhost:4310/`

**Try it:** `vz-ai-stack.sh start claw3d` then open `http://localhost:4310`.

**Notes:** The UI talks to its bridge (`claw3d_bridge`); start that too. Reachable via the tutorial **Launch a service** panel. See doc/HERMES-HANDSON.md for the full hands-on.

## claw3d_bridge · Tier 3 · Phase 19

**What it is:** Host daemon exposing every stack agent on one OpenAI-style endpoint (port `7780`).

**Setup/health:** `curl -s http://127.0.0.1:7780/health`

**Try it:** `curl -s http://127.0.0.1:7780/v1/chat/completions -d '{"role":"pi","messages":[{"role":"user","content":"print fizzbuzz 1..15 in python"}]}'`

**Notes:** Backs the claw3d 3D UI; `curl -s http://127.0.0.1:7780/state | python3 -m json.tool` shows live agent state.

## cmux · Tier 3 · Phase 22

**What it is:** Native macOS terminal for running many parallel agent sessions in tabs.

**Setup/health:** `bash vz-ai-stack.sh install cmux`

**Try it:** `open -a cmux` · `cmux notify --title 'agent' --message 'session needs you'`

**Notes:** Opt-in desktop app (not in `install all`).

## deerflow · Tier 2 · Phase 10

**What it is:** Multi-step deep-research agent (LangGraph) that writes cited reports, with a web UI.

**Setup/health:** `bash ~/ai-stack/bin/start-deerflow.sh` (`stop-deerflow.sh` to stop).

**Try it:** open `http://deerflow:2026` and run a research query.

**Notes:** Its model picker is data-driven from `deer-flow/config.yaml` (auth-gated `/api/models`). Multi-step calls + summarizer/operator clusters show in Phoenix.

## docs_ingestor · Tier 3 · Phase 06

**What it is:** One-shot CLI that parses dropped files and embeds them into Qdrant.

**Setup/health:** `ls ~/ai-stack/ingestor/processed/`

**Try it:** drop a file (`cp ~/Downloads/example.pdf ~/ai-stack/ingestor/inbox/`) then `cd ~/ai-stack/ingestor && source .venv/bin/activate && python ingest.py`.

**Notes:** Populates the `ai-stack-docs` Qdrant collection that powers the **Docs search** widget (demo 9).

## docs_mcp · Tier 1 · Phase 06

**What it is:** Host MCP daemon serving semantic retrieval over the Qdrant doc store.

**Setup/health:** `bash ~/ai-stack/bin/start-docs_mcp.sh` then `curl -s -o /dev/null -w '%{http_code}' http://docs-mcp:8765/` (404 = up).

**Try it:** **Live widget** — the **Docs search** panel (demo 9, `POST /api/docs/search`) in `doc/TUTORIAL.html` embeds your query and vector-searches the same doc store this MCP serves. See [TUTORIAL.html → Interactive demos](TUTORIAL.html).

**Notes:** Read-only retrieval; needs the docs index built first (`docs_ingestor`).

## dual_llm_researcher · Tier 4 · Phase 04·G

**What it is:** A prompting *convention* (not a daemon): the operator only ever sees a summarizer's safe summary, so a prompt-injected document can't reach the operator agent.

**Setup/health:** `source ~/ai-stack/.env` (uses `LITELLM_MASTER_KEY`).

**Try it:** run the worked example in `vz-ai-stack.sh help dual_llm_researcher` — feed a document containing `IGNORE PREVIOUS INSTRUCTIONS…` and watch the injection get dropped from the operator-visible summary.

**Notes:** Security pattern, Phase 04·G. There's no port; it's how you wire two LiteLLM calls.

## falkordb · Tier 2 · Phase 02

**What it is:** Graph database speaking Cypher over the Redis protocol, with a web UI.

**Setup/health:** `redis-cli -h falkordb -p 6379 PING`

**Try it:** open the browser UI at `http://falkordb-ui:3000`, pick a graph, and run a `MATCH … RETURN` query (Act III, L11 builds the `org` graph). Or from the CLI: `redis-cli -h falkordb -p 6379 GRAPH.QUERY mygraph "CREATE (a:Person {name:'Alice'}) RETURN a"`.

**Notes:** Ports `6379` (Redis protocol) + `3010`; UI on `:3000`.

## halo · Tier 3 · Phase 11

**What it is:** CLI agent that reads a LiteLLM trace to find failures and propose fixes (built on RLM-style recursive reasoning).

**Setup/health:** `bin/halo --help`

**Try it:** `bin/halo ~/ai-stack/traces/litellm.jsonl -p "Find the most common failure"`

**Notes:** Turns the observability plane into a self-healing input; drives RLM over your traces automatically.

## hermes_fleet · Tier 3 · Phase 04·F

**What it is:** The 9-role Hermes engineering-team fleet, running in the `hermes-fleet-v1` OpenShell sandbox.

**Setup/health:** `vz-ai-stack.sh fleet list` (add `--json` for machine-readable).

**Try it:** `vz-ai-stack.sh model list` to see each role's bound model, then dispatch work to a role.

**Notes:** Each role holds a *scoped* LiteLLM key (never the master key). The team-protocol skill is the keystone. See doc/HERMES-HANDSON.md for the full hands-on.

## hermes_telegram · Tier 3 · Phase 20

**What it is:** Hermes gateway inside the sandbox bridging the fleet to a Telegram bot.

**Setup/health:** `openshell sandbox exec -n hermes-fleet-v1 -- hermes gateway status`

**Try it:** `bash ~/ai-stack/bin/start-hermes-telegram.sh` (stop via `hermes gateway stop` in the sandbox).

**Notes:** Needs a Telegram bot token. `Phase=Ready` ≠ relay-live — confirm the gateway is actually up. See doc/HERMES-HANDSON.md for the full hands-on.

## hermes_workspace · Tier 2 · Phase 05

**What it is:** Web UI for managing the Hermes fleet (profiles, load, memory state).

**Setup/health:** `curl -s http://workspace:3000/` · `docker ps --filter name=hermes-workspace`

**Try it:** open `http://workspace:3000`.

**Notes:** On hermes-agent v0.18.0 the dashboard fail-closes off-loopback, so it binds `127.0.0.1` and the UI runs in the agent's network namespace (`network_mode: service:hermes-agent`) to reach it over the shared loopback. See doc/HERMES-HANDSON.md for the full hands-on.

## honcho · Tier 1 · Phase 03

**What it is:** Self-hosted cross-agent, per-user memory server (Postgres + Redis). Separates *what was said* (messages) from *what is known* (a derived peer representation).

**Setup/health:** `curl -s http://honcho:8000/health` → `{"status":"ok"}` (fallback `http://127.0.10.6:8000/health`).

**Try it:** **Live widget** — the **Agent memory** panel (demo 8, `POST /api/honcho/demo`) in `doc/TUTORIAL.html` reads one fixed, non-sensitive demo session read-only. See [TUTORIAL.html → Interactive demos](TUTORIAL.html).

**Notes:** Honcho's Postgres is LiteLLM's *shared* key DB — a single point of failure for key minting if it's down. The widget only ever touches the `tutorial` session, never your `default` fleet memory.

## litellm · Tier 1 · Phase 01

**What it is:** OpenAI-compatible proxy fronting every model behind one endpoint (`http://litellm:4000/v1`). The hub everything dials.

**Setup/health:** `curl -s http://127.0.0.1:4000/health` · list models: `source ~/ai-stack/.env && curl -s -H "Authorization: Bearer $LITELLM_MASTER_KEY" http://litellm:4000/v1/models | jq '.data[].id'`.

**Try it:** **Live widget** — the **List models** / **Chat** / **Model compare** panels (demos 1–3, `GET /api/models` + `POST /api/chat`) and **Embeddings** (demo 5, `POST /api/embed`) all route through LiteLLM. See [TUTORIAL.html → Interactive demos](TUTORIAL.html).

**Notes:** Master key stays server-side only; consumers get scoped virtual keys. A new provider key must be added to `start-litellm.sh`'s `-e` allowlist and applied with `--recreate` (not `docker restart`).

## litellm_guardrails_builtin · Tier 4 · Phase 04·G

**What it is:** In-process LiteLLM pre-call hook that denies prompts matching a deny-set.

**Setup/health:** `bash ~/ai-stack/bin/audit.sh` · `docker logs litellm 2>&1 | grep -i guardrails`.

**Try it:** **Live widget** too — the **Guardrail block** panel (demo 4) sends a deny-set prompt and you watch it come back blocked (400). By hand: POST a risky prompt to `/v1/chat/completions` and check the HTTP code.

**Notes:** Always-on once Phase 04·G runs; enforced server-side at the gateway.

## litellm_guardrails_secrets · Tier 4 · Phase 04·G

**What it is:** LiteLLM post-call hook that redacts secrets a model echoes in responses.

**Setup/health:** `grep -nE 'REDACT_PATTERNS|async_post_call_success_hook' ~/ai-stack/litellm/guardrails.py` · `bash ~/ai-stack/bin/audit.sh`.

**Try it:** ask a model (via `/v1/chat/completions`) to echo a token-shaped string and observe the redaction in the response.

**Notes:** Companion to the builtin deny-set hook; the *after* half of guardrails.

## llm_guard · Tier 4 · Phase 04·G

**What it is:** Optional second-layer security scanner sidecar (Docker container).

**Setup/health:** `bash ~/ai-stack/bin/start-llm_guard.sh` then `docker ps --filter name=llm_guard --format '{{.Names}} {{.Status}} {{.Ports}}'`.

**Try it:** start it (above) and confirm the container reports healthy.

**Notes:** Memory-hungry — has been seen to OOM; check the container-liveness census (doctor check 53) confirms it's actually up.

## lmstudio · Tier 3 · Phase 25

**What it is:** LM Studio MLX engine as a *second* OpenAI-compatible runtime behind LiteLLM.

**Setup/health:** `~/.lmstudio/bin/lms ps`

**Try it:** `vz-ai-stack.sh install lmstudio && vz-ai-stack.sh start lmstudio` — then the MLX models become routable via LiteLLM.

**Notes:** Opt-in. Hosts the nemotron MLX model (`local-nemotron3-nano-4b-mlx`) — the same model Ollama serves as GGUF.

## lumen_mcp · Tier 3 · Phase 16

**What it is:** Ory's Lumen — semantic code search, as a CLI or stdio MCP server.

**Setup/health:** `~/ai-stack/bin/lumen version`

**Try it:** `~/ai-stack/bin/lumen search 'openshell policy' --path ~/ai-stack`

**Notes:** `bin/lumen` auto-rewrites its path to the cwd on worktree entry — never commit a path-rewritten copy.

## mempalace · Tier 3 · Phase 26

**What it is:** Local-first verbatim conversation memory + temporal knowledge graph; Claude Code session recall (now part of `install all`).

**Setup/health:** `bin/mempalace wake-up`

**Try it:** `bin/mempalace search 'what did we decide about the watchdog'` · mine history: `bin/mempalace mine ~/.claude/projects --mode convos --extract general`.

**Notes:** Embeddings are computed **on-device** (local ONNX/CoreML); the store is local (ChromaDB). ⚠ Install only from PyPI (`mempalace`) or github.com/MemPalace/mempalace — `mempalace.tech` is a known malware squat.

## metagpt · Tier 3 · Phase 32

**What it is:** Multi-agent software-company sim (PM → architect → engineer → QA), run via `bin/metagpt` (opt-in).

**Setup/health:** `vz-ai-stack.sh test 32`

**Try it:** `bin/metagpt "create a CLI 2048 game in python"` (override model with `METAGPT_MODEL=claude-opus-sub-xhigh bin/metagpt "…"`).

**Notes:** Opt-in host-venv batch sim. Every agent step routes through LiteLLM → traced in Phoenix.

## oasis · Tier 3 · Phase 34

**What it is:** Large-scale social-media agent swarm simulation (CAMEL), run via `bin/oasis` (opt-in).

**Setup/health:** `vz-ai-stack.sh test 34`

**Try it:** `bin/oasis oasis/sims/smoke_sim.py` (write your own in `oasis/sims/`).

**Notes:** Opt-in. Watch the swarm in Phoenix; on a 24 GB box local inference serializes — keep swarms small or route to a metered model.

## ollama · Tier 3 · Phase 01

**What it is:** Local open-weight model server (host brew service, Metal-accelerated).

**Setup/health:** `ollama list` · `curl -s http://ollama:11434/api/ps | jq` (fallback `http://127.0.0.1:11434/api/tags`).

**Try it:** `curl -s http://ollama:11434/api/generate -d '{"model":"nemotron-3-nano:4b","prompt":"in one sentence: what is a Merkle tree?","stream":false}' | jq -r .response`

**Notes:** Default local model is `nemotron-3-nano:4b` (`local`), a reasoning model — give it room (`max_tokens >= 512`). `brew services restart ollama` wipes `OLLAMA_HOST=0.0.0.0` back to loopback. Reached *through* LiteLLM in normal use.

## openagents · Tier 3 · Phase 24

**What it is:** Launcher/dashboard + `agn` CLI to install and manage coding agents.

**Setup/health:** `bash vz-ai-stack.sh install openagents`

**Try it:** `agn`

**Notes:** Opt-in (not in `install all`).

## openshell · Tier 4 · Phase 04

**What it is:** Linux sandbox platform hosting the Hermes fleet and Pi sandboxes (isolation layer).

**Setup/health:** `openshell status` · `openshell sandbox list`.

**Try it:** `openshell sandbox exec -n hermes-fleet-v1 -- /bin/sh -c 'whoami; uname -srm'`

**Notes:** `Phase=Ready` ≠ relay-live. Gateway runs on `:17670`; needs `brew trust nvidia/openshell` (doctor check 54). gRPC `exec -- sh -c` rejects newlines.

## openwebui · Tier 2 · Phase 05

**What it is:** ChatGPT-style web chat UI wired to LiteLLM (model picker, built-in file RAG).

**Setup/health:** `curl -s http://openwebui:8080/health` · `docker ps --filter name=openwebui`.

**Try it:** open `http://openwebui:8080`, pick a model, chat. For file-RAG: click `+`, upload a `.md`, then ask a grounded question. Also in the tutorial **Launch a service** panel.

**Notes:** Embeds via the same local Ollama embedder — no cloud calls.

## openwork · Tier 2 · Phase 29

**What it is:** Headless OpenCode-powered Cowork workspace over your stack (browser UI, LiteLLM models, skills/plugins/MCP, approval-gated).

**Setup/health:** `vz-ai-stack.sh help openwork`

**Try it:** `vz-ai-stack.sh install openwork && vz-ai-stack.sh start openwork` then open `http://openwork:8787/ui`.

**Notes:** Opt-in. The `openwork-orchestrator` daemon self-manages OpenCode (no host dependency).

## paperclip · Tier 2 · Phase 08

**What it is:** Personal task agent (Node host daemon) serving its API + UI on `:3100`.

**Setup/health:** `curl -s http://paperclip:3100/api/health | jq`

**Try it:** `bash ~/ai-stack/bin/start-paperclip.sh` then open `http://paperclip:3100`.

**Notes:** Pairs with the Honcho plugin below to persist dispatched tasks into memory.

## paperclip_honcho_plugin · Tier 4 · Phase 08

**What it is:** In-UI Paperclip plugin that wires every dispatched task into Honcho memory.

**Setup/health:** `curl -s http://honcho:8000/health | jq`

**Try it:** dispatch a task in Paperclip, then `curl -s "http://honcho:8000/v3/workspaces/default/peers/paperclip/search?query=task" | jq`.

**Notes:** A plugin, not a standalone service — verify via Honcho, not its own port.

## phoenix · Tier 1 · Phase 01·H

**What it is:** Arize Phoenix — OpenTelemetry collector + tracing/eval UI for LiteLLM. Every call lands as a span (model, tokens, latency, cost).

**Setup/health:** `curl -s http://phoenix:6006/healthz` · UI: `open http://phoenix:6006`.

**Try it:** **Live widget** — the **Recent traces** panel (demo 10, `GET /api/traces`) in `doc/TUTORIAL.html` reads the most recent project-`ai-stack` spans read-only. See [TUTORIAL.html → Interactive demos](TUTORIAL.html). Read-only spans API: `GET http://phoenix:6006/v1/spans?project=ai-stack&start=<ISO8601>`.

**Notes:** Auth is **off** in this build (`PHOENIX_ENABLE_AUTH=false`) — no login for the UI. The UI is `:6006`, but LiteLLM pushes spans to the *separate* gRPC OTLP endpoint `http://phoenix-otlp:4317`.

## pi · Tier 3 · Phase 15

**What it is:** Earendil's tree-branching TUI coding agent, in its own `pi-v1` OpenShell sandbox.

**Setup/health:** `bash ~/ai-stack/bin/pi` (emergency stop: `bin/pi-kill`).

**Try it:** `bash ~/ai-stack/bin/pi --model local`

**Notes:** Pi is isolated — it can think (via LiteLLM) and remember (via Honcho) but cannot reach phoenix, qdrant, the workspace, or any other stack service. Uses a scoped key (`PI_LITELLM_KEY`), never the master key.

## pi_gateway_litellm · Tier 4 · Phase 15

**What it is:** The LiteLLM virtual key minted for Pi — a local-model superset, no master key.

**Setup/health:** `grep -c PI_LITELLM_KEY ~/ai-stack/.env`

**Try it:** `source ~/ai-stack/.env && curl -s http://litellm:4000/v1/models -H "Authorization: Bearer $PI_LITELLM_KEY"` — see exactly the model allowlist Pi is granted.

**Notes:** Re-mint with `vz-ai-stack.sh install 15`. The 403-on-out-of-allowlist behavior is the scoped-key guarantee in action.

## portless · Tier 3 · Phase 21

**What it is:** Agent-aware local dev proxy mapping named HTTPS URLs to dev servers.

**Setup/health:** `portless --version`

**Try it:** `portless myapp 'npm run dev'` → serves it at `https://myapp.localhost`.

**Notes:** Opt-in (not in `install all`).

## qdrant · Tier 1 · Phase 02

**What it is:** Vector database for embeddings and nearest-neighbor search.

**Setup/health:** `curl -s http://qdrant:6333/collections | jq` · docs index size: `curl -s http://qdrant:6333/collections/ai-stack-docs | jq '.result.points_count'`. Dashboard: `http://qdrant:6333/dashboard`.

**Try it:** **Live widget** — the **Docs search** panel (demo 9, `POST /api/docs/search`) embeds your query and vector-searches the `ai-stack-docs` collection. See [TUTORIAL.html → Interactive demos](TUTORIAL.html).

**Notes:** Build the index first with `docs_ingestor`; the widget degrades to the populate command when the collection is empty.

## remnic_hermes · Tier 3 · Phase 09

**What it is:** Alternative agent-memory Python library; an installed-disabled candidate.

**Setup/health:** `~/ai-stack/alt-memory/.venv/bin/pip show remnic-hermes`

**Try it:** `~/ai-stack/alt-memory/.venv/bin/python -c 'import remnic_hermes; print("import OK")'`

**Notes:** A library, not a service — verify by import. Honcho is the active memory server; this is a comparison candidate.

## rlm · Tier 3 · Phase 18

**What it is:** CLI + library for recursive long-context inference over huge inputs (Alex Zhang's original Recursive Language Models; LiteLLM-routed, Docker-sandboxed REPL).

**Setup/health:** `bin/rlm --help`

**Try it:** `bin/rlm "Use the REPL to compute the 20th Fibonacci number." -m local --max-depth 2`

**Notes:** Bound to `claude-opus-sub-max` by default (keyless box falls back to `local`). In Phoenix you'll see a *parent* call plus the *recursive sub-calls* it spawns — a tree of small prompts. HALO (Phase 11) drives RLM over your traces.

## skillspector · Tier 3 · Phase 23

**What it is:** NVIDIA offline-first scanner that vets a skill / MCP server before you install it.

**Setup/health:** `~/ai-stack/bin/skillspector --help`

**Try it:** `~/ai-stack/bin/skillspector scan ./path/to/skill`

**Notes:** Opt-in (`vz-ai-stack.sh install 23`). Offline-first — runs on-box.

## sourcegraph · Tier 2 · Phase 27

**What it is:** Local self-hosted Sourcegraph (code search) + native MCP for the Hermes fleet.

**Setup/health:** `vz-ai-stack.sh start sourcegraph`

**Try it:** `vz-ai-stack.sh install sourcegraph` then open `http://localhost:7080` (or `http://sourcegraph:7080`).

**Notes:** Opt-in. Native MCP works on the free tier (12 tools). The `:6.12.5040` tag is the last single-container release (amd64-emulated).

## understand · Tier 3 · Phase 30

**What it is:** Understand-Anything — a codebase knowledge graph, queryable from Claude Code, Pi, and the Hermes fleet via MCP.

**Setup/health:** `vz-ai-stack.sh install understand && vz-ai-stack.sh start understand`

**Try it:** from your **main** checkout: `cd ~/ai-stack && /understand .` to generate the graph, then commit it.

**Notes:** Opt-in (Phase 30). The `understand-mcp` shim serves both stdio (Claude Code / Pi) and HTTP (fleet, `:7081`). Generate from main; doctor check 52 covers it.

## unsloth · Tier 2 · Phase 14

**What it is:** Local fine-tuning + training web UI (LoRA/QLoRA, MLX) on `:8898`.

**Setup/health:** `curl http://127.0.0.1:8898/`

**Try it:** `bash vz-ai-stack.sh install unsloth && open http://unsloth:8898`.

**Notes:** Opt-in. Training is RAM-hungry — mind the 24 GB ceiling.
