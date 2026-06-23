# Alternatives

For every tool in `~/ai-stack`, two-to-four well-known alternatives with
a one-line differentiator. Use this when you are evaluating "should I
swap X for Y?" — you want a quick map of the landscape, not a deep
review.

The header for each section calls out **what slot the tool fills** in
the stack. Substitutes need to fill the same slot — a vector database
is not a graph database is not a memory server, even if all three
"store stuff related to LLMs."

For "what does this tool actually do?", read [STACK-GUIDE.md](STACK-GUIDE.md).
For "how does it fit?", read [DIAGRAMS.md](DIAGRAMS.md).

---

## Platform / container runtime

### OrbStack
**Slot:** macOS container runtime. Hosts every Docker container.

| Alternative | Differentiator |
|---|---|
| **Docker Desktop** | The default. Heavier on battery/CPU, more memory overhead on Apple Silicon. Familiar UI. |
| **Colima** | Open-source CLI-only QEMU/Lima wrapper. Free, lower-level, no UI. |
| **Podman Desktop** | Daemonless container engine + rootless. Compatible with Docker CLI. Better for security audits. |
| **Rancher Desktop** | Includes Kubernetes by default; uses moby or containerd. Aimed at K8s developers. |

---

## Local model serving

### Ollama
**Slot:** Runs open-weight LLMs locally with an HTTP API.

| Alternative | Differentiator |
|---|---|
| **LM Studio** | Desktop app with a GUI for browsing/downloading models. Same OpenAI-compatible API. |
| **llama.cpp server** | The C++ inference engine Ollama wraps. Use directly for max control or quantization tweaking. |
| **vLLM** | Production-grade serving engine, much faster batched throughput but heavier setup. Linux/GPU first. |
| **MLX (Apple)** | Apple's framework for Apple Silicon. Lower-level; pair with `mlx-lm` for serving. |

---

## Inference proxy / LLM gateway

### LiteLLM
**Slot:** One HTTP endpoint that forwards to any LLM provider.

| Alternative | Differentiator |
|---|---|
| **Helicone AI Gateway** | OSS gateway from Helicone. Built-in observability, cache, rate limits. Was in this stack before the Phoenix migration. |
| **Portkey** | Hosted + OSS. Strong on prompt management, routing, virtual keys. |
| **OpenRouter** | Hosted-only single endpoint for 100+ models with built-in fallbacks. Not self-hosted; you trust them with prompts. |
| **Apache APISIX with ai-proxy** | Generic API gateway with an LLM plugin. Use if you already run APISIX. |
| **Vercel AI Gateway** | Hosted, integrated with the Vercel AI SDK. Cloud-only. |

---

## Observability for LLM apps

### Phoenix (Arize)
**Slot:** Trace/eval dashboard for LLM calls and agent runs.

| Alternative | Differentiator |
|---|---|
| **Langfuse** | OSS, broader integrations, hosted option. Strong prompt management + evals. |
| **Helicone** | Hosted + OSS. Per-call cost tracking is the headline feature. |
| **LangSmith** | LangChain's hosted observability. Best if you live in LangChain/LangGraph. |
| **OpenLLMetry by Traceloop** | OSS OTel-native instrumentation; send traces to any OTel backend (Jaeger, Datadog, Honeycomb). |
| **Weights & Biases Weave** | Built on top of W&B. Strong for ML teams already using W&B for training. |

---

## Graph database

### FalkorDB
**Slot:** Graph DB for knowledge graphs, GraphRAG, and relational queries.

| Alternative | Differentiator |
|---|---|
| **Neo4j** | The reference graph DB. Mature, big ecosystem, Cypher. Heavier resource use; community edition has license restrictions. |
| **Memgraph** | In-memory, real-time graph queries. Cypher-compatible. Aimed at streaming use cases. |
| **Apache AGE** | Postgres extension that adds graph queries. Stay in Postgres, get graph. |
| **NebulaGraph** | Distributed, horizontally scalable. Overkill for one laptop. |
| **Kùzu** | Embedded graph DB (like SQLite for graphs). No server. |

---

## Vector database

### Qdrant
**Slot:** Stores embeddings, returns nearest neighbors.

| Alternative | Differentiator |
|---|---|
| **Chroma** | Embedded-first, dead-simple API. Default in many tutorials. Less scalable. |
| **Weaviate** | OSS + cloud. Strong hybrid search (BM25 + vector) and built-in vectorizer modules. |
| **Milvus** | Designed for billions of vectors at scale; needs more infra. |
| **pgvector** | Postgres extension. Use if you already run Postgres and want one less service. |
| **LanceDB** | Embedded, file-based, columnar. Great for notebooks and edge. |
| **FAISS** | Facebook's library, not a server. Lower-level building block. |

---

## Cross-agent memory

### Honcho
**Slot:** Persistent memory server that derives facts/insights from chats.

| Alternative | Differentiator |
|---|---|
| **Mem0** | OSS + hosted. Focuses on "memories" as discrete facts an agent can recall. Big community traction. |
| **Letta (formerly MemGPT)** | OSS server with a richer "agent state" model and tooling, plus a UI. |
| **Zep** | OSS + hosted. Combines vector + graph for conversational memory. Strong for chatbots. |
| **Cognee** | OSS knowledge-graph memory layer with extraction pipelines. |
| **remnic / byterover** | Already in this stack as Phase 09 alternatives (file-based, local-first). |

---

## Agent sandbox / runtime

### OpenShell (NVIDIA)
**Slot:** Safe runtime for autonomous agents with policy-based isolation.

| Alternative | Differentiator |
|---|---|
| **E2B** | Hosted sandboxes for code execution by AI. Strong code-interpreter use case. |
| **Daytona** | OSS dev environments + cloud. Used as a Hermes backend. |
| **Modal** | Hosted serverless functions/sandboxes. Pay-per-second; great for ephemeral agent tasks. |
| **Firecracker microVMs (raw)** | The primitive Blaxel etc. build on. DIY route. |
| **Docker containers with `--read-only` + custom seccomp** | The "no extra tool" route. Less guard rails, more manual. |

---

## Autonomous agent framework

### Hermes Agent (Nous Research) — and the `hermes_fleet` of 9 profiles
**Slot:** Terminal agent with persistent memory, skills, and profiles.
The "fleet" is the same agent run with nine different SOUL.md identities — a
9-role software-engineering team (manager, techlead, frontend/backend/ml
engineers, QA, reviewing engineer, SRE, incident manager) running a spec→deploy
pipeline under a shared team-protocol. The same team is also realized as Pi
personas and Claude Code agents (the manager is the main agent; the other 8 are subagents).

| Alternative | Differentiator |
|---|---|
| **Claude Code** | Anthropic's official terminal coding agent. Strong for coding; less general. |
| **OpenCode** | OSS terminal agent (TUI) by SST. Provider-agnostic. |
| **Aider** | OSS pair-programmer in the terminal. Git-aware; opinionated about diffs. |
| **Goose (Block)** | OSS agent CLI with a plugin model. Strong for ops/coding. |
| **OpenAI Codex CLI** | Official OpenAI agent CLI. Tightly integrated with OpenAI models. |

---

## Chat UI (for any LLM)

### Open WebUI
**Slot:** Self-hosted web chat UI in front of any OpenAI-compatible API.

| Alternative | Differentiator |
|---|---|
| **LibreChat** | OSS, more "enterprise" feel: SSO, multi-user, presets. |
| **AnythingLLM** | Heavy on RAG out of the box; workspace metaphor for documents. |
| **LobeChat** | Polished React UI; supports plugins and TTS. |
| **Chatbox** | Desktop app (Electron) rather than web. |
| **text-generation-webui (oobabooga)** | Power-user UI focused on local model tuning + character chats. |

---

## Agent fleet UI / control plane

### Hermes Workspace
**Slot:** Web UI for managing multiple Hermes profiles, memory, skills.

| Alternative | Differentiator |
|---|---|
| **Paperclip** | Already in this stack (Phase 08). Orchestrator-style with budgets and approval gates. |
| **AutoGen Studio** | Microsoft's UI for AutoGen multi-agent setups. |
| **CrewAI Studio** | UI for CrewAI's role-based crews. |
| **LangGraph Studio** | Visual graph editor + debugger for LangGraph apps. |

---

## Document parsing for RAG

### Docling
**Slot:** Parse PDFs/Office docs/HTML into structured, RAG-ready text.

| Alternative | Differentiator |
|---|---|
| **Unstructured.io** | OSS + hosted API. Very wide format support. Heavier dependency footprint. |
| **MinerU** | Strong on scientific PDFs (formulas, layout). Chinese-language friendly. |
| **LlamaParse** | Hosted (by LlamaIndex). Pay-per-page; very good at messy PDFs. |
| **Marker** | Fast OSS PDF→markdown. Less polish than Docling but quicker. |
| **PyMuPDF / pdfplumber** | Library-level. Use when you want code-first control and minimal abstractions. |

---

## RAG framework

### LlamaIndex
**Slot:** Python glue for parse → chunk → embed → store → retrieve.

| Alternative | Differentiator |
|---|---|
| **LangChain** | Bigger ecosystem, more abstractions. Often paired with LangGraph for agents. |
| **Haystack (deepset)** | Pipeline-oriented; strong for IR research. |
| **DSPy** | "Programming, not prompting" — declarative pipelines with auto-optimization. |
| **txtai** | Lightweight; vector + graph + LLM in one library. Less battle-tested. |

---

## Agent tool protocol

### Model Context Protocol (MCP) — and `docs_mcp` as our MCP server
**Slot:** Standard interface for agents to call external tools and read
resources. `docs_mcp` is our concrete MCP server exposing
`search_documents` over port 8765.

| Alternative | Differentiator |
|---|---|
| **OpenAI function calling / Responses tools** | Proprietary, model-specific. Simpler; less portable. |
| **A2A (Agent-to-Agent) protocol** | Google's competing standard for agent-agent calls. |
| **LangChain Tools** | Library-level abstraction; not a wire protocol. |
| **Bespoke OpenAPI** | Just expose REST and let the agent read your OpenAPI spec. |
| **Open WebUI's RAG tools** | Already integrated for chat-driven retrieval; less general than MCP. |

---

## Built-in / lightweight guardrails

### LiteLLM in-process guardrails (`litellm_guardrails_builtin` + `litellm_guardrails_secrets`)
**Slot:** Cheap regex pre-call deny + post-call secret redaction.
Two sub-features in `services.yml`: `_builtin` covers the deny list;
`_secrets` covers the redaction.

| Alternative | Differentiator |
|---|---|
| **Guardrails AI** | Rich Python framework for input/output validation. JSON schema + checks. |
| **NeMo Guardrails (NVIDIA)** | Programmable rails in Colang DSL; conversation-level flow control. |
| **Promptfoo** | Eval-first; great for testing guardrails. |
| **Prompt Armor** | Hosted commercial alternative. |
| **TruffleHog / gitleaks** | For the secrets half specifically — battle-tested regex sets. |

---

## Untrusted-content reading pattern

### Dual-LLM researcher (`dual_llm_researcher`)
**Slot:** Discipline (not a service) of routing untrusted text through a
summarizer model before any action model sees it.

| Alternative | Differentiator |
|---|---|
| **Spotlight / data marking** | Tag untrusted segments; hope the model respects the tags. |
| **Output-only filtering** | Let the model see everything, only filter outputs. Less safe. |
| **Hard input sanitization** | Strip patterns from input. Brittle; misses paraphrases. |
| **Constitutional AI / system prompt rules** | Tell the model to ignore injection. Necessary but not sufficient. |

---

## Heavy guardrails / scanner sidecar

### LLM Guard (Protect AI)
**Slot:** ML-based scanner for prompt injection, toxicity, secrets, etc.

| Alternative | Differentiator |
|---|---|
| **NeMo Guardrails** | Programmable rails + integrations with Llama Guard models. |
| **Llama Guard (Meta)** | Open-weights moderation model. Run via Ollama; lower-level. |
| **Lakera Guard** | Hosted commercial scanner. Strong on prompt injection. |
| **Rebuff** | Self-hostable prompt-injection detector. |

---

## Coding agent (managed UI)

### AutoFyn _(unverified)_
**Slot:** Coding agent with its own UI on port 3400. Public source not findable.

| Alternative | Differentiator |
|---|---|
| **Cursor** | Most popular AI IDE; commercial. |
| **Continue.dev** | OSS VS Code/JetBrains extension; provider-agnostic. |
| **Cline** | OSS VS Code agent. Plan/act loops. |
| **Aider** | CLI-based; git-native. Already listed under Hermes alternatives. |
| **Sweep** | OSS GitHub-app-style coding agent. |

---

## Task / agent orchestrator

### Paperclip
**Slot:** Org-chart-style orchestrator for fleets of agents with budgets.

| Alternative | Differentiator |
|---|---|
| **CrewAI** | Role-based agent crews; Python-first. |
| **AutoGen** | Microsoft's multi-agent framework; mature, conversation-driven. |
| **LangGraph** | DAG/graph-based orchestration. Lower-level, very flexible. |
| **AgentForce / Salesforce Agentforce** | Commercial enterprise option. |
| **OpenAI Swarm (experimental)** | Lightweight reference impl from OpenAI. |

---

## Agent-swarm simulation

### OASIS · MetaGPT · AgentScope (opt-in Phases 34 · 32 · 33)
**Slot:** "Agents living in a world" — spin up many agents in a shared simulation and watch emergent behavior, every LLM call routed through LiteLLM (scoped keys) → traced in Phoenix. Three complementary, opt-in, fully-reversible **host-venv** tools, none in `install all`: **OASIS** (large-scale social swarms, ≤1M agents upstream — dozens on-box), **MetaGPT** (a fixed, goal-directed "software company": PM→architect→engineer→QA), and **AgentScope** (a framework to *build your own* multi-agent sims). The watchable container web-app siblings — **AI Town** and **ChatDev** — are tracked as separate phases (and AgentScope ships an optional Studio web GUI to watch swarms run). Reality on an M4/24GB: local inference serializes, so keep swarms to dozens on `local-gemma4` or route a scoped key to a cloud/sub model (metered).

| Alternative | Differentiator |
|---|---|
| **AI Town** (a16z-infra) | The most *watchable* — characters live, move, and chat in a 2D town; self-hosted Convex compose stack. Evaluated/built as a container web app (Phase 36, feasibility-gated). |
| **ChatDev** (OpenBMB) | Fixed ~5-role software-company role-play; goal-directed, not really a large *swarm*. Evaluated/built as a separate phase (Phase 35). |
| **Concordia** (DeepMind) | Generative-agent social-science framework; library-only, no GUI. |
| **TinyTroupe** (Microsoft) | Persona-driven simulation for product/marketing insight rather than open-world swarms. |
| **Generative Agents** (Stanford "Smallville") | The original agents-in-a-town research; not packaged for turnkey self-host. |
| **Mesa** | Classic (non-LLM) agent-based modeling in Python — no model calls. |
| **SwarmClaw** | Persistent agent-runtime GUI; evaluated → kept out of core (duplicates Honcho/MemPalace), useful only as a throwaway swarm visualizer. |

---

## Ingestion script

### docs_ingestor (Phase 06)
**Slot:** Manual-run Python script that sweeps `ingestor/inbox/`, parses, embeds, stores.

| Alternative | Differentiator |
|---|---|
| **LlamaHub loaders** | Many ready-made document loaders for LlamaIndex; less custom code. |
| **Unstructured.io pipelines** | Heavier, more formats, built-in chunking strategies. |
| **Apache Tika + custom script** | Java-based parser; older, very robust on weird formats. |
| **fsspec + watchdog** | Roll your own with a file watcher instead of a manual sweep. |

---

## Per-app memory wiring

### paperclip_honcho_plugin (Phase 08)
**Slot:** Plugin that lets Paperclip-dispatched agents read shared Honcho memory.

| Alternative | Differentiator |
|---|---|
| **Direct Honcho SDK calls in each agent** | More boilerplate, finer control. |
| **MCP memory tool** | Expose Honcho via MCP and let agents call it as a tool. Less structural; agent can forget. |
| **No memory plugin** | Sometimes the task does not need cross-session continuity. |

---

## File-based memory plugin

### remnic-hermes (Phase 09, off by default)
**Slot:** Local-first memory in plain markdown; structural recall every turn.

| Alternative | Differentiator |
|---|---|
| **Honcho** | The default in this stack. Server-based, cross-agent. |
| **byterover CLI** | Other Phase 09 option. Codebase-centric. |
| **Mem0** | Hosted + OSS; popular discrete-fact memory. |
| **Plain markdown + grep** | Sometimes the right answer. |

---

## Codebase memory CLI

### byterover_cli (Phase 09, off by default)
**Slot:** Local context tree of markdown files describing a codebase.

| Alternative | Differentiator |
|---|---|
| **Aider's repo map** | Auto-generated repo summary built into Aider. |
| **Cursor / Continue codebase indexing** | IDE-integrated, less portable. |
| **agentmemory** | OSS memory layer for coding agents, benchmark-driven. |
| **Greptile** | Hosted code-search/chat over private repos. |

---

## Verbatim conversation memory

### MemPalace (Phase 26)
**Slot:** Local-first **verbatim** recall of past Claude Code sessions —
CLI + MCP (29 tools) + Python lib. A spatial model
(wings/rooms/drawers) over a temporal SQLite knowledge graph; embeddings
are computed **on-device** (local ONNX/CoreML, default `all-MiniLM-L6-v2`),
so nothing leaves the machine. Distinct from the other memory slots: it keeps
the *actual transcript* searchable, not derived facts.

| Alternative | Differentiator |
|---|---|
| **Honcho** | The stack default. Derives *facts/insights* from chats (per-peer representation); MemPalace keeps the raw conversation verbatim. Complementary, not a swap. |
| **Qdrant + docs_ingestor** | Document RAG over your files; MemPalace is session-recall over your *conversations*. Different corpus. |
| **Lumen** | Semantic *code* search; MemPalace is conversation search. Different corpus again. |
| **remnic / byterover** | The dormant Phase 09 local-first memory options (markdown / codebase context tree). MemPalace is conversation-transcript memory with on-device embeddings. |
| **Storage backend** | Ships on local ChromaDB; a **Qdrant backend adapter is staged** (`mempalace/backend-qdrant/`, RFC-001, conformance-tested vs live Qdrant) but not yet runtime-wired (3.3.5 hardcodes ChromaBackend). |

> **Security:** install MemPalace only from PyPI (`mempalace`) or
> github.com/MemPalace/mempalace — the domain `mempalace.tech` is a known
> malware squat.

---

## Multi-agent research / super-agent harness

### DeerFlow (ByteDance)
**Slot:** LangGraph-based orchestrator for long-running research/tasks with sub-agents.

| Alternative | Differentiator |
|---|---|
| **GPT Researcher** | Single-purpose deep-research agent. Lighter. |
| **STORM (Stanford)** | Wikipedia-style article generation from sources. |
| **OpenHands** | OSS general-purpose dev agent (formerly OpenDevin). |
| **CrewAI** | Role-based crews; more conversational, less workflow. |
| **AutoGen** | Conversation-driven multi-agent. |

---

## Trace analyzer / agent loop optimizer

### HALO (Context Labs)
**Slot:** Offline CLI that reads agent traces and finds failure patterns.

| Alternative | Differentiator |
|---|---|
| **Phoenix evals** | Already in the stack. UI-driven evals; less optimization-focused. |
| **Promptfoo** | Test-suite-style eval framework. |
| **Inspect (UK AISI)** | Eval framework with policy/agent runners. |
| **TruLens** | OSS evals + feedback functions; integrates with LangChain/LlamaIndex. |
| **Galileo** | Hosted observability+eval platform. |

---

## Long-context recursion harness

### RLM — Recursive Language Models (Phase 18)
**Slot:** Lets a model recursively call itself over long context via a REPL
(run in a Docker sandbox). The substrate HALO is built on.

| Alternative | Differentiator |
|---|---|
| **RAG / retrieval over chunks** | Index the long context and retrieve top-k instead of recursing. Cheaper; loses cross-chunk reasoning. |
| **Map-reduce summarization** | Summarize chunks then combine. Simpler; lossy on details that matter later. |
| **Long-context models (e.g. 1M-token)** | Just use a bigger window. Costly per call; degrades on "needle in haystack." |
| **LongRoPE / context-extension tricks** | Stretch an existing model's window. Engineering-heavy; quality varies. |

---

## Iterative self-refinement pattern

### autoreason (Nous Research, clone-only)
**Slot:** Reference codebase for a three-version + blind-judge refinement loop.

| Alternative | Differentiator |
|---|---|
| **DSPy + Borda** | Roll your own with DSPy's optimizers. |
| **Reflexion / Self-Refine** | The original papers on iterative refinement. |
| **OpenAI o-series reasoning** | Built into the model; less control, more black box. |
| **Best-of-N sampling** | Naïve baseline; pick the best of N samples. |

---

## Cloud agent runtime

### Blaxel
**Slot:** Hosted always-on microVM sandboxes + co-located inference.

| Alternative | Differentiator |
|---|---|
| **Modal** | Serverless functions and sandboxes; pay per second. |
| **E2B** | Sandboxes specifically for AI code execution. |
| **Daytona** | OSS + cloud dev environments; supports remote agents. |
| **Fly.io machines** | Generic always-on micro-VMs. DIY but cheap and battle-tested. |
| **AWS Fargate / Cloud Run** | Vanilla cloud serverless containers. More setup; cheaper at scale. |

---

## Heavy-RAG self-hosted (reserved slot)

### RAGFlow (Phase 13, no-op placeholder)
**Slot:** Full RAG engine with deep document parsing + hybrid search + citations.

| Alternative | Differentiator |
|---|---|
| **Open WebUI built-in RAG** | Already in the stack. Simpler; UI-driven. |
| **Verba (Weaviate)** | OSS RAG UI on top of Weaviate. |
| **Danswer / Onyx** | OSS knowledge assistant; strong for enterprise/Slack search. |
| **PrivateGPT** | OSS doc-Q&A focused on local privacy. |
| **Cognita** | OSS RAG framework with a focus on production deployment. |

---

## Quick decision rules

When evaluating any swap, ask the same four questions:

1. **Does the alternative fill the same slot?** A graph DB is not a
   vector DB, even if both store "stuff related to embeddings."
2. **Does it preserve the privacy story?** Many alternatives are
   cloud-only or hosted-by-default — swapping them in changes the
   "where my data goes" diagram in [DIAGRAMS.md](DIAGRAMS.md).
3. **Does it speak the same protocol?** OpenAI-compatible APIs swap
   freely. OTel traces swap freely. Bespoke protocols (LangChain Tools
   vs MCP) do not.
4. **What does it cost in operator effort?** This stack is one
   `bash vz-ai-stack.sh` away from working. A tool that needs a Kubernetes
   cluster or its own DBA is not a peer alternative for a personal
   laptop stack.

---

## Evaluated candidates (2026-05-31)

Tools considered for the "versatile experimental" layer (terminal multiplexing,
many parallel agent sessions, provider/config management, port management, skill
safety). Verdicts are for *this* stack — macOS/Apple-Silicon, terminal-first, many
concurrent Claude Code/agent sessions, local-first LiteLLM→Ollama. Researched live.

| Candidate | Category | macOS/ARM | License | Verdict | Why (for this stack) |
|---|---|---|---|---|---|
| **[cmux](https://github.com/manaflow-ai/cmux)** | Native-macOS terminal for parallel **agent** sessions (per-tab git/PR/port sidebar + `cmux notify` hooks; Ghostty-based) | ✓ | GPL-3.0 (+commercial) | **try-now** | Purpose-built for the core daily pain — many Claude Code sessions, which one needs attention. Sits *above* OpenShell/LiteLLM, duplicates neither. `brew install --cask cmux`. Young/fast-moving. |
| **[Zellij](https://github.com/zellij-org/zellij)** | Rust terminal multiplexer; KDL layouts; web client | ✓ | MIT | **try-now** | Layouts can pin one agent/worktree per pane + auto-launch; CLI automation drives panes. `brew install zellij`. |
| **[tmux](https://github.com/tmux/tmux)** | Classic multiplexer; detach/reattach | ✓ | ISC | **try-now** | Ubiquitous; keeps long-running agents alive across disconnects. Pick **tmux *or* zellij** as the daily driver (cmux largely subsumes both for agents). `brew install tmux`. |
| **[portless](https://github.com/vercel-labs/portless)** | Agent-aware local proxy — named `name.localhost` HTTPS URLs; ships a Claude Code skill | ✓ | Apache-2.0 | **experiment** | Fixes "agents test the wrong port" across many worktrees; bundled CC skill (`portless get`). Pre-1.0 (Vercel Labs). `npm i -g portless` (Node 24+). |
| **[CC Switch](https://github.com/farion1231/cc-switch)** | GUI to switch Claude Code/Codex provider configs + MCP + Skills | ✓ | MIT | **experiment** | One-click point Claude Code at LiteLLM; manage MCP (Lumen)/skills. GUI (terminal-first users: CLI fork `SaladDay/cc-switch-cli`). `brew install --cask cc-switch`. Beware imposter sites. |
| **[NVIDIA SkillSpector](https://github.com/NVIDIA/skillspector)** | Security scanner for agent skills/MCP (prompt-injection, tool-poisoning) before install | unknown | Apache-2.0 | **experiment** | We install many 3rd-party skills; static mode is offline, optional LLM stage points at LiteLLM. Very new (~5 commits). Complements (not duplicates) the Semgrep plugin. |
| **[OpenAgents Launcher](https://openagents.org/launcher)** | "Ollama for AI agents" — install/manage CC/Codex/Aider/etc. | unknown | Apache-2.0 | **maybe-later** | Heavily duplicates our installer + Hermes fleet + LiteLLM routing; imposes its own config layer. Throwaway-worktree try only. |
| **[wterm](https://github.com/vercel-labs/wterm)** | Web terminal-emulator **library** (embed in a web app) | ✓ | Apache-2.0 | **skip** | A frontend component, not a tool you run. Meets no stated need; only use would be a custom terminal pane inside claw3d/Open WebUI. |

**Bottom line:** for "many concurrent agent sessions," **cmux** is the standout (agent-aware); **portless** is the low-effort high-payoff add for worktree/port chaos. tmux/zellij are an either/or classic-multiplexer choice. See [ATTRIBUTION.md](ATTRIBUTION.md) for license/ToS detail (note cmux is GPL-3.0; the rest tried are MIT/Apache-2.0).
