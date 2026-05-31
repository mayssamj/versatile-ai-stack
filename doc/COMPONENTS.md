# Components — what's in this stack

A brief catalog of everything in `~/ai-stack`. One line each. For the *why* and
deep tour see [STACK-GUIDE.md](STACK-GUIDE.md); for ports see [PORTS.md](PORTS.md);
for commands see [OPERATIONS.md](OPERATIONS.md).

- **25 install phases**, **31 services** (`services.yml`), **31 doctor checks**.
- Everything local-first: all LLM calls route through **LiteLLM → Ollama** (no cloud
  unless you explicitly pick a cloud model). Reach services by alias (`http://litellm:4000`).

---

## Inference & gateway
| Component | What it is | Reach it |
|---|---|---|
| **Ollama** | Local model server (host brew service) | `:11434` |
| **LiteLLM** | OpenAI-compatible gateway — virtual keys, model allowlists, guardrails, Phoenix tracing | `http://litellm:4000` |

**Local models** (via LiteLLM aliases): `local` = `gemma4:e4b` (fast, ~9.6 GB) · `local-heavy` = `qwen3.6:27b` (~22 GB) · `local-lfm2` = LFM2.5-8B · embeddings: `nomic-embed-text`, `jina-embeddings-v2-base-code`.

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
| **Hermes fleet** | 7 Hermes profiles (cos, software_engineer, researcher, creator, reviewer, data_analyst, ops) in the `hermes-fleet-v1` sandbox, routed to LiteLLM | `openshell sandbox exec -n hermes-fleet-v1 -- hermes …` |
| **Pi** | Earendil terminal coding agent in the `pi-v1` sandbox | `bin/pi` |
| **AutoFyn** | Multi-agent framework (dashboard + agent + sandbox) | `http://autofyn:3400` |
| **DeerFlow** | Multi-step research agent (LangGraph) | `http://localhost:2026` |
| **dual_llm_researcher** | Documented planner+executor agent *pattern* (not a daemon) | — |

## User interfaces
| Component | What it is | Reach it |
|---|---|---|
| **Open WebUI** | Chat UI in front of LiteLLM | `http://openwebui:8080` |
| **Hermes Workspace** | Nous Research chat workspace | `http://workspace:3000` |

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
| **Unsloth Studio** | Local model fine-tuning UI | `http://unsloth:8898` |
| **Paperclip** | Screenshot / computer-use agent | `http://paperclip:3100` |
| **Blaxel CLI** | Cloud agent-platform CLI (cloud-only; installed on demand) | `bl` / `blaxel` |
| **remnic-hermes** | Alternative memory library (PyPI) | `alt-memory/.venv` |
| **byterover CLI** | Alternative memory CLI | `brv` |
| **autoreason** | NousResearch research clone (reference only) | `halo/autoreason/` |
| **paperclip↔honcho plugin** | Wires Paperclip into Honcho memory | — |

## Platform
| Component | What it is |
|---|---|
| **OrbStack** | macOS Docker runtime hosting every container |
| **Networking** | `/etc/hosts` aliases (`127.0.10.x`) + the `ai-stack` bridge network — same URL form on host and in-container |

---

## The `stack` CLI (`bin/stack` = `install.sh`)
`install [phase\|all]` · `reset --confirm soft\|hard\|nuke [--yes]` · `verify` · `status` ·
`doctor [filter]` · `start/stop <svc>` · `adopt <svc>` · `apply-restarts` · `logs <svc>` ·
`prepare-sudo`. Per-service launchers live in `bin/start-<svc>.sh`; daily-driver wrappers
are `bin/{pi,ace,rlm,halo,lumen}`.
