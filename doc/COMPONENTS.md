# Components — what's in this stack

A brief catalog of everything in `~/ai-stack`. One line each. For the *why* and
deep tour see [STACK-GUIDE.md](STACK-GUIDE.md); for ports see [PORTS.md](PORTS.md);
for commands see [OPERATIONS.md](OPERATIONS.md); for **source links + licenses + ToS**
see [ATTRIBUTION.md](ATTRIBUTION.md) (incl. the non-permissive ones — OrbStack, Phoenix,
FalkorDB, LFM2, etc.).

- **29 core install phases** (+21 opt-in extras: `portless`, `cmux`, `skillspector`, `openagents`, `lmstudio`, `sourcegraph`, `aionui`, `openwork`, `understand`, `ingress`, `metagpt`, `agentscope`, `oasis`, `chatdev`, `aitown`, `concordia`, `slack`, `fleet_memory`, `honcho_mcp`, `falkordb_mcp`, `omp`), **54 services** (`services.yml`), **85 doctor checks**.
- Phases accept a **name or number**: `mayssam-ai-stack.sh install phoenix` == `install 01h`. Run `mayssam-ai-stack.sh phases` for the table.
- Everything local-first: all LLM calls route through **LiteLLM → Ollama** (no cloud
  unless you explicitly pick a cloud model). Reach services by alias (`http://litellm:4000`).

---

## Inference & gateway
| Component | What it is | Reach it |
|---|---|---|
| **Ollama** | Local model server (host brew service) | `:11434` |
| **LiteLLM** | OpenAI-compatible gateway — virtual keys, model allowlists, guardrails, Phoenix tracing | `http://litellm:4000` |

**Local models** (declared in `installer/models.yml`; see [models.md](models.md)): `local` / `local-heavy` / `local-nemotron3-nano-4b` = `nemotron-3-nano:4b` (Ollama, ~2.8 GB — the ONLY local chat model + **the always-on `default` fallback** every agent gates to when its runtime is down; an unassigned agent renders the `primary` `claude-opus-sub-max` and gates to this; all three aliases map to the same model). Opt-in LM Studio MLX (Phase 25): `local-nemotron3-nano-4b-mlx` (the same nemotron model on Apple MLX) + the `local-lfm2-mlx` LFM2.5 demo. Embeddings: `nomic-embed-text`, `jina-embeddings-v2-base-code`.

## Observability & security
| Component | What it is | Reach it |
|---|---|---|
| **Phoenix** | OTel trace UI + collector (project `ai-stack`) | `http://phoenix:6006` |
| **LLM Guard** | Input/output scanning sidecar | `http://llm-guard:8000` |
| **LiteLLM guardrails** | Built-in denied-words + secrets-regex callbacks (fail-closed) | in LiteLLM |

## Memory & storage
| Component | What it is | Reach it |
|---|---|---|
| **Honcho** | Agent memory store (also backs LiteLLM's virtual-key Postgres) | `http://honcho:8000` |
| **Qdrant** | Vector database | `http://qdrant:6333` |
| **FalkorDB** | Graph database (Redis protocol) + browser UI | `redis://falkordb:6379` · UI `http://falkordb-ui:3000` |

## Agent runtimes & frameworks
| Component | What it is | Reach it |
|---|---|---|
| **OpenShell** | Sandbox host for isolated agents (`hermes-fleet-v1`, `pi-v1`) | gateway `:17670` |
| **Hermes fleet** | A 9-role engineering team (manager, techlead, frontend_engineer, backend_engineer, ml_engineer, qa_test_engineer, reviewing_engineer, sre_engineer, incident_manager) in the `hermes-fleet-v1` sandbox, routed to LiteLLM; same team also runs as Pi personas + Claude Code agents (manager = the main agent, the other 8 = subagents), sharing the `team-protocol` skill | `openshell sandbox exec -n hermes-fleet-v1 -- hermes …` |
| **Pi** | Earendil terminal coding agent in the `pi-v1` sandbox | `bin/pi` |
| **AutoFyn** | Multi-agent framework (dashboard + agent + sandbox) | `http://autofyn:3400` |
| **DeerFlow** | Multi-step research agent (LangGraph) | `http://localhost:2026` |
| **dual_llm_researcher** | Documented planner+executor agent *pattern* (not a daemon) | — |

## User interfaces
| Component | What it is | Reach it |
|---|---|---|
| **Open WebUI** | Chat UI in front of LiteLLM | `http://openwebui:8080` |
| **Hermes Workspace** | Chat workspace UI — *community project (`outsourc-e`), built on Nous Research's `hermes-agent`; not a Nous product* | `http://workspace:3000` |
| **claw3d** | 3D agent "office" — visualizes + chats with your sandboxed agents (Hermes ×9, Pi, DeerFlow) via the stack-agents bridge. Each agent's model is declared per-agent in `models.yml` (fallback `local`) | `http://claw3d:4310` (alias) or `http://localhost:4310` |
| **claw3d bridge** | Host daemon implementing claw3d's custom runtime; routes chat authentically to each agent (`claw3d-bridge/bridge.py`). Intentionally **`127.0.0.1`-only** (auth-less, drives all 9 agents → loopback by design) | `http://127.0.0.1:7780` (internal) |
| **Hermes Telegram gateway** | Native hermes gateway (runs inside `hermes-fleet-v1`); DM the bot to reach the fleet from your phone. Secure-by-default (allowlist required) | `@vz_hermes_controller_bot` on Telegram |

## Documents & RAG
| Component | What it is | Reach it |
|---|---|---|
| **docs ingestor** | Docling + LlamaIndex pipeline — drop files in `ingestor/inbox`, embeds into Qdrant | `cd ingestor && python ingest.py` |
| **docs-mcp** | MCP server exposing document search over the ingested corpus | `:8765` |

## CLI tools · batch · experimental
| Component | What it is | Reach it |
|---|---|---|
| **ACE** | Agentic Context Engineering — generates reusable "playbooks" | `bin/ace` |
| **RLM** | Recursive Language Models — recursive long-context inference; REPL in a Docker sandbox | `bin/rlm` |
| **HALO** | Trace-analysis engine (`halo-engine`); reasons over OTel traces ⚠️ *experimental on local models* | `bin/halo` |
| **Lumen** | Code semantic-search MCP server | `bin/lumen` |
| **MemPalace** | Verbatim CONVERSATION memory for Claude Code sessions (CLI + stdio MCP; Phase 26). Local-first ChromaDB + on-device ONNX/CoreML embeddings (all-MiniLM-L6-v2, no cloud, not via LiteLLM); the optional entity-refiner LLM routes through LiteLLM (`MEMPALACE_LITELLM_KEY` → visible in Phoenix). Complements Honcho (derived facts) / Qdrant (doc RAG) / Lumen (code) — its niche is verbatim session recall | `bin/mempalace` |
| **Unsloth Studio** | Local model fine-tuning UI | `http://unsloth:8898` |
| **Paperclip** | Screenshot / computer-use agent | `http://paperclip:3100` |
| **Blaxel CLI** | Cloud agent-platform CLI (cloud-only; installed on demand) | `bl` / `blaxel` |
| **remnic-hermes** | Alternative memory library (PyPI) | `alt-memory/.venv` |
| **byterover CLI** | Alternative memory CLI | `brv` |
| **autoreason** | NousResearch research clone (reference only) | `halo/autoreason/` |
| **paperclip↔honcho plugin** | Wires Paperclip into Honcho memory | — |
| **transformers.js PoC** | Evaluated capability — local **on-device embeddings + semantic search** (browser WebGPU + Node), zero load on Ollama/host; a candidate to drop into claw3d | `experiments/transformersjs-poc/` |

## Opt-in experimental extras (Phases 21–25 · 27–38 — NOT in `install all`)
Install individually by name: `mayssam-ai-stack.sh install <name>`. Doctor checks 34–38 + 49–52 + 56–61 + 84 pass-as-skip when not installed (check 45 guards the self-contained tutorial).
| Component | What it is | Install |
|---|---|---|
| **portless** | Agent-aware local dev proxy — stable `name.localhost` HTTPS URLs; ships a Claude Code skill so agents stop guessing ports | `mayssam-ai-stack.sh install portless` |
| **cmux** | Native macOS terminal for many parallel agent sessions (per-tab git/PR/port + `cmux notify` hooks) | `mayssam-ai-stack.sh install cmux` |
| **SkillSpector** | NVIDIA scanner that vets agent skills/MCP for prompt-injection/tool-poisoning *before* install (offline by default) | `mayssam-ai-stack.sh install skillspector` → `bin/skillspector scan <path>` |
| **OpenAgents Launcher** | "Ollama for AI agents" (`agn`); ⚠️ overlaps the stack — NOT wired into LiteLLM/sandboxes; installs to `~/.openagents` | `mayssam-ai-stack.sh install openagents` |
| **LM Studio (MLX)** | 2nd local runtime behind LiteLLM (`:1234`) — Apple MLX engine. Serves `local-nemotron3-nano-4b-mlx` (the same nemotron model on Apple MLX) plus the opt-in `local-lfm2-mlx` LFM2.5 demo. `install lmstudio` is **assignment-driven**: it loads ONLY MLX models actually assigned to an agent in `models.yml` — it does NOT auto-load anything otherwise. The `local-lfm2-mlx` demo model (LFM2.5, *working tool-calling*) is **opt-in** via `LMS_LOAD_LFM2=1`. Ollama stays default; lmstudio-assigned agents fall back to `local` when this is down. Start the server with `mayssam-ai-stack.sh start lmstudio` (idempotent; no model auto-loads — assign one in `models.yml` + `model sync`). ⚠️ The desktop app idle-spins ~0.8–1 core even stopped — run only when needed and **quit it when done** (`mayssam-ai-stack.sh stop lmstudio` + Cmd-Q); headless alt: `mlx_lm.server` | `mayssam-ai-stack.sh install lmstudio` (setup + model wiring) · `start lmstudio` (run) |
| **Sourcegraph** | Self-hosted code search + intelligence (single-container `sourcegraph/server:6.12.5040`, loopback) exposing a **native MCP** server (12 tools, works on the free tier) for raw-source retrieval — wired into Claude Code and the Hermes fleet as the code-search companion to Understand-Anything's orientation map. Opt-in (Phase 27). | `mayssam-ai-stack.sh install sourcegraph` |
| **AionUi** | Local Cowork workspace — desktop app (brew `--cask aionui`) + a headless WebUI server (prebuilt `aionui-web`, loopback `:25808`). Chats with any OpenAI-compatible model and drives CLI agents in parallel over ACP. `install aionui` adds the cask + WebUI daemon + a model-scoped LiteLLM key + host `hermes-agent[acp]`. Loopback-only. | `mayssam-ai-stack.sh install aionui` · `start aionui` |
| **OpenWork** | Local Cowork workspace built on the **OpenCode** engine — the stack runs its headless orchestrator (prebuilt `openwork-orchestrator` binary, npm) as a loopback browser UI on `:8787`. File-centric agentic work with skills/plugins/MCP, approval-gated. `install openwork` npm-installs the binary + mints a model-scoped LiteLLM key + pre-seeds `~/.openwork-stack/opencode.json` (LiteLLM provider). Self-manages OpenCode (no separate install). Loopback-only, `--approval manual`. | `mayssam-ai-stack.sh install openwork` · `start openwork` |
| **Understand-Anything** | The Understand-Anything Claude Code plugin, integrated **cross-runtime** — a codebase orientation/architecture map. Generate a knowledge graph with `/understand` (Claude Code or Pi), **commit** it, then **consume it everywhere** via a net-new host `understand-mcp` server: stdio for Claude Code/Pi, http (`127.0.0.1:7081`, token-gated, `host.docker.internal` for the fleet, wired like Sourcegraph) for the Hermes fleet. Tools: `graph_search`, `get_node`, `read_node_source`, `list_layers`, `get_tour`, `project_summary`. Boundary: understand = the orientation map; Sourcegraph/lumen = raw source retrieval (`read_node_source` bridges to code). Dashboard: `understand-dashboard`; E2E proof: `test understand`. Hermes-side generation deferred; search is fuzzy (semantic deferred). Runbook: [UNDERSTAND.md](UNDERSTAND.md). | `mayssam-ai-stack.sh install understand` · `understand-dashboard` |
| **MetaGPT** | A fixed **software-company** agent swarm (PM→architect→engineer→QA) that turns a one-line brief into code in `metagpt/workspace/`. Host uv venv; routes through LiteLLM (scoped key) → Phoenix. Opt-in (Phase 32). | `mayssam-ai-stack.sh install metagpt` · `bin/metagpt "build a CLI todo app"` |
| **AgentScope** | A framework to **build/scale your own** multi-agent sims — agents converse, observe, act (async 2.x). Host uv venv; routes through LiteLLM (scoped key) → Phoenix. Opt-in (Phase 33). | `mayssam-ai-stack.sh install agentscope` · `bin/agentscope agentscope/sims/smoke_sim.py` |
| **OASIS** | **Large social-agent swarms** (CAMEL-based) — agents post/follow/react in a shared world (≤1M upstream; dozens on-box). Host uv venv; routes through LiteLLM (scoped key) → Phoenix. Opt-in (Phase 34). | `mayssam-ai-stack.sh install oasis` · `bin/oasis oasis/sims/smoke_sim.py` |
| **ChatDev** | A **watchable** multi-agent *software company* (ChatDev 2.0 "DevAll") you drive from a Vue web app (host `:5274`; FastAPI backend `:6400`). Two loopback-only containers; routes through LiteLLM (scoped key) → Phoenix. Opt-in (Phase 35). | `mayssam-ai-stack.sh install chatdev` · open `http://chatdev:5274/` |
| **AI Town** | A **watchable** virtual town — AI characters live, move, and chat in real time (Convex docker-compose stack; frontend `:5273`, dashboard `:6791`). Routes through LiteLLM (scoped key). Opt-in (Phase 36). | `mayssam-ai-stack.sh install aitown` · open `http://aitown:5273/` |

## Platform
| Component | What it is |
|---|---|
| **Docker engine** | macOS Docker runtime hosting every container — the selected engine (`AI_STACK_DOCKER_ENGINE`: OrbStack default, or Docker Desktop / Colima / Podman). Pick it with `docker-engine select`. |
| **Networking** | `/etc/hosts` aliases (`127.0.10.x`) + the `ai-stack` bridge network — same URL form on host and in-container |

---

## The `stack` CLI (`bin/stack` = `mayssam-ai-stack.sh`)
`install [phase\|all] [--dry-run]` · `deps [--check]` · `setup` (alias `keys`) ·
`reset --confirm soft\|hard\|nuke [--yes]` · `verify` · `status` ·
`doctor [filter]` · `start/stop <svc>` · `adopt <svc>` · `apply-restarts` · `logs <svc>` ·
`prepare-sudo`. `deps` (`installer/lib/deps.sh`) bootstraps + verifies host dependencies;
`setup` (`installer/lib/setup.sh`) is the interactive, skippable `.env` / API-key bootstrap
(both layer over `env.sh::env_ensure_baseline`, the single source of truth for the `.env`
baseline shared with Phase 00). Per-service launchers live in `bin/start-<svc>.sh`;
daily-driver wrappers are `bin/{pi,ace,rlm,halo,lumen,mempalace}` (mempalace = Phase 26).
