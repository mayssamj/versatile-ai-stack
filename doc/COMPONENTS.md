# Components — what's in this stack

A brief catalog of everything in `~/ai-stack`. One line each. For the *why* and
deep tour see [STACK-GUIDE.md](STACK-GUIDE.md); for ports see [PORTS.md](PORTS.md);
for commands see [OPERATIONS.md](OPERATIONS.md); for **source links + licenses + ToS**
see [ATTRIBUTION.md](ATTRIBUTION.md) (incl. the non-permissive ones — OrbStack, Phoenix,
FalkorDB, LFM2, etc.).

- **27 core install phases** (+6 opt-in extras: `portless`, `cmux`, `skillspector`, `openagents`, `lmstudio`, `mempalace`), **40 services** (`services.yml`), **44 doctor checks**.
- Phases accept a **name or number**: `vz-ai-stack.sh install phoenix` == `install 01h`. Run `vz-ai-stack.sh phases` for the table.
- Everything local-first: all LLM calls route through **LiteLLM → Ollama** (no cloud
  unless you explicitly pick a cloud model). Reach services by alias (`http://litellm:4000`).

---

## Inference & gateway
| Component | What it is | Reach it |
|---|---|---|
| **Ollama** | Local model server (host brew service) | `:11434` |
| **LiteLLM** | OpenAI-compatible gateway — virtual keys, model allowlists, guardrails, Phoenix tracing | `http://litellm:4000` |

**Local models** (declared per-agent in `installer/models.yml`; see [models.md](models.md)): `local-gemma4` = `gemma4:e4b` (Ollama, fast, ~9.6 GB — **the default for any unassigned agent**) · `local-qwen3.6` = `qwen/qwen3.6-27b` (LM Studio MLX, ~17.5 GB, heavy reasoning, opt-in) · `local-qwen3-coder` = `qwen3-coder-30b-a3b-instruct-mlx` (LM Studio MLX, ~17.2 GB, coding, opt-in) · embeddings: `nomic-embed-text`, `jina-embeddings-v2-base-code`. Legacy aliases (`local`, `local-heavy`, `local-lfm2`) still resolve but `local-heavy` (Ollama `qwen3.6:27b`) is no longer auto-pulled.

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
| **Hermes fleet** | A 9-role engineering team (manager, techlead, frontend_engineer, backend_engineer, ml_engineer, qa_test_engineer, reviewing_engineer, sre_engineer, incident_manager) in the `hermes-fleet-v1` sandbox, routed to LiteLLM; same team also runs as Pi personas + Claude Code subagents, sharing the `team-protocol` skill | `openshell sandbox exec -n hermes-fleet-v1 -- hermes …` |
| **Pi** | Earendil terminal coding agent in the `pi-v1` sandbox | `bin/pi` |
| **AutoFyn** | Multi-agent framework (dashboard + agent + sandbox) | `http://autofyn:3400` |
| **DeerFlow** | Multi-step research agent (LangGraph) | `http://localhost:2026` |
| **dual_llm_researcher** | Documented planner+executor agent *pattern* (not a daemon) | — |

## User interfaces
| Component | What it is | Reach it |
|---|---|---|
| **Open WebUI** | Chat UI in front of LiteLLM | `http://openwebui:8080` |
| **Hermes Workspace** | Chat workspace UI — *community project (`outsourc-e`), built on Nous Research's `hermes-agent`; not a Nous product* | `http://workspace:3000` |
| **claw3d** | 3D agent "office" — visualizes + chats with your sandboxed agents (Hermes ×7, Pi, DeerFlow) via the stack-agents bridge. Each agent's model is declared per-agent in `models.yml` (default `local-gemma4`) | `http://claw3d:4310` (alias) or `http://localhost:4310` |
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
| **MemPalace** | Verbatim CONVERSATION memory for Claude Code sessions (CLI + stdio MCP; opt-in Phase 26). Local-first ChromaDB + on-device ONNX/CoreML embeddings (all-MiniLM-L6-v2, no cloud, not via LiteLLM); the optional entity-refiner LLM routes through LiteLLM (`MEMPALACE_LITELLM_KEY` → visible in Phoenix). Complements Honcho (derived facts) / Qdrant (doc RAG) / Lumen (code) — its niche is verbatim session recall | `bin/mempalace` |
| **Unsloth Studio** | Local model fine-tuning UI | `http://unsloth:8898` |
| **Paperclip** | Screenshot / computer-use agent | `http://paperclip:3100` |
| **Blaxel CLI** | Cloud agent-platform CLI (cloud-only; installed on demand) | `bl` / `blaxel` |
| **remnic-hermes** | Alternative memory library (PyPI) | `alt-memory/.venv` |
| **byterover CLI** | Alternative memory CLI | `brv` |
| **autoreason** | NousResearch research clone (reference only) | `halo/autoreason/` |
| **paperclip↔honcho plugin** | Wires Paperclip into Honcho memory | — |
| **transformers.js PoC** | Evaluated capability — local **on-device embeddings + semantic search** (browser WebGPU + Node), zero load on Ollama/host; a candidate to drop into claw3d | `experiments/transformersjs-poc/` |

## Opt-in experimental extras (Phases 21–26 — NOT in `install all`)
Install individually by name: `vz-ai-stack.sh install <name>`. Doctor checks 34–38 + 44 pass-as-skip when not installed.
| Component | What it is | Install |
|---|---|---|
| **portless** | Agent-aware local dev proxy — stable `name.localhost` HTTPS URLs; ships a Claude Code skill so agents stop guessing ports | `vz-ai-stack.sh install portless` |
| **cmux** | Native macOS terminal for many parallel agent sessions (per-tab git/PR/port + `cmux notify` hooks) | `vz-ai-stack.sh install cmux` |
| **SkillSpector** | NVIDIA scanner that vets agent skills/MCP for prompt-injection/tool-poisoning *before* install (offline by default) | `vz-ai-stack.sh install skillspector` → `bin/skillspector scan <path>` |
| **OpenAgents Launcher** | "Ollama for AI agents" (`agn`); ⚠️ overlaps the stack — NOT wired into LiteLLM/sandboxes; installs to `~/.openagents` | `vz-ai-stack.sh install openagents` |
| **LM Studio (MLX)** | 2nd local runtime behind LiteLLM (`:1234`) — Apple MLX engine. Now the home of the two big MLX models `local-qwen3.6` + `local-qwen3-coder` (~17 GB each, JIT-loaded one-at-a-time with idle TTL) and `local-lfm2-mlx` (LFM2.5 with *working tool-calling* the Ollama GGUF can't do). Ollama stays default; lmstudio-assigned agents fall back to `local-gemma4` when this is down. ⚠️ The desktop app idle-spins ~0.8–1 core even stopped — run only when needed and **quit it when done** (`lms server stop` + Cmd-Q); headless alt: `mlx_lm.server` | `vz-ai-stack.sh install lmstudio` |
| **MemPalace** | Verbatim Claude Code session memory (CLI + stdio MCP, no daemon/port). PyPI-only (`uv tool install mempalace`); runs on local on-device ChromaDB with ONNX/CoreML embeddings (no cloud). Stop/PreCompact auto-save hooks are opt-in/reversible via `bin/mempalace-hooks` (NOT wired by install). Doctor check 44 green-skips when not installed | `vz-ai-stack.sh install mempalace` (alias for `install 26`) |

## Platform
| Component | What it is |
|---|---|
| **OrbStack** | macOS Docker runtime hosting every container |
| **Networking** | `/etc/hosts` aliases (`127.0.10.x`) + the `ai-stack` bridge network — same URL form on host and in-container |

---

## The `stack` CLI (`bin/stack` = `vz-ai-stack.sh`)
`install [phase\|all]` · `reset --confirm soft\|hard\|nuke [--yes]` · `verify` · `status` ·
`doctor [filter]` · `start/stop <svc>` · `adopt <svc>` · `apply-restarts` · `logs <svc>` ·
`prepare-sudo`. Per-service launchers live in `bin/start-<svc>.sh`; daily-driver wrappers
are `bin/{pi,ace,rlm,halo,lumen,mempalace}` (mempalace is opt-in — Phase 26).
