# Architecture

The installer is intentionally **not** a monolithic bash script. It's a small,
disciplined system with clear responsibility boundaries. This doc explains
where things live and why.

If you're patching the installer, read this first. The choices below were
debated through a three-way review (AI-infra, DevOps, adversarial) and the
debate outcomes are in [CHANGELOG.md](../CHANGELOG.md).

The rest of this doc is implementation-focused (file layout, idempotency,
locking, Docker discipline). For the *runtime* shape of the stack — who calls
whom at request time — start with the layered view immediately below.

---

## The layered view

The stack is five layers stacked on a single inference egress. Read it
top-down: a UI or CLI hands a request to an agent, the agent routes through
LiteLLM, LiteLLM fans out to a local runtime, and the call lands in Phoenix as
a trace "for free."

```
┌──────────────────────────────────────────────────────────────────────────┐
│  UI LAYER (host)                                                           │
│    Open WebUI :8080   ·   Hermes Workspace :3000   ·   claw3d :4310 (local) │
│    (browsers/chat front-ends; all dial LiteLLM)                            │
└───────────────────────────────────┬────────────────────────────────────────┘
                                     │  scoped virtual key (per agent)
┌────────────────────────────────────▼───────────────────────────────────────┐
│  AGENT LAYER (isolated)                                                     │
│    Hermes fleet — 9-role eng team in OpenShell sandbox  hermes-fleet-v1     │
│      manager · techlead · frontend · backend · ml · qa · reviewing ·       │
│      sre · incident   (+ Telegram gateway runs inside the same box)        │
│    Pi (Earendil) coding agent in OpenShell sandbox  pi-v1                   │
│    DeerFlow · ACE · RLM    (host-side, each minting its own scoped key)     │
└────────────────────────────────────┬───────────────────────────────────────┘
                                     │  HERMES_/PI_/ACE_/RLM_LITELLM_KEY
┌────────────────────────────────────▼───────────────────────────────────────┐
│  MODEL-HUB LAYER  —  LiteLLM  :4000   (the single inference egress)         │
│    · every agent's ONLY route to a model                                   │
│    · virtual keys, each allowlisted against the derived superset           │
│    · models.yml is the canonical model↔agent binding                       │
│    · emits OTLP on every call ───────────────────────────────┐             │
└──────────┬───────────────────────────────┬───────────────────┼─────────────┘
           │ ollama (host-gateway)          │ host.docker.internal:1234        │
┌──────────▼──────────┐         ┌───────────▼──────────┐        │ OTLP gRPC
│  Ollama (brew :11434)│         │  LM Studio (:1234)    │        │
│   gemma4:e4b default │         │   MLX: qwen3.6-27b,   │        │
│   nomic-embed-text   │         │   qwen3-coder-30b     │        │
└─────────────────────┘         └──────────────────────┘        │
                                                                 │
┌──────────────────────────────────┐   ┌─────────────────────────▼─────────┐
│  DATA / MEMORY LAYER              │   │  OBSERVABILITY LAYER              │
│    Qdrant :6333 (vectors)         │   │    Phoenix :6006                  │
│    FalkorDB :6379 (graph + UI)    │   │    OTLP gRPC ingest :4317         │
│    Honcho :8000 (cross-agent mem; │   │    (alias phoenix-otlp)           │
│      its Postgres also backs the  │   │    project "ai-stack" — every     │
│      LiteLLM key store)           │   │    LLM call lands here for free   │
│    MemPalace (verbatim convo mem; │   │                                   │
│      host CLI/MCP, no port; opt-in)│   │                                   │
└───────────────────────────────────┘   └───────────────────────────────────┘
```

### UI layer

Host-side front-ends, all of which terminate at LiteLLM for inference:

- **Open WebUI** — reached at `http://openwebui:8080` (alias `127.0.10.9:8080`
  → container `8080`, Phase 05), the general chat UI.
- **Hermes Workspace** — `:3000` (Phase 05), the fleet's own workspace UI.
- **claw3d** — the 3D agent-office UI on `:4310` plus its `claw3d-bridge`
  on `:7780` (Phase 19), routing chat across every isolated agent. Both are
  **loopback-only by design** (no `/etc/hosts` alias — see the host/sandbox
  boundary below); claw3d refuses to bind a public host without
  `STUDIO_ACCESS_TOKEN`, and the bridge is auth-less and can drive all 9
  agents, so both stay on `127.0.0.1`.

### Model-hub layer — LiteLLM is the single inference egress

**Every agent's only route to a model is `http://litellm:4000/v1`.** There is
no second door. This is the architectural spine: one process holds the
provider keys (`ANTHROPIC` / `OPENAI` / `OPENROUTER` / `GOOGLE` +
`LITELLM_MASTER_KEY`), one process enforces the guardrails callback chain, and
one process emits OTLP. Centralizing egress is what makes per-agent virtual
keys, allowlists, and free tracing possible.

LiteLLM fans out to two local runtimes: **Ollama** (brew service on the host,
reached via `--add-host=ollama:host-gateway`) and **LM Studio** (host OpenAI
server on `:1234`, reached via `host.docker.internal`, opt-in Phase 25).

### Agent layer

- **Hermes fleet — a 9-role software-engineering team** (`hermes_manager`,
  `hermes_techlead`, `hermes_frontend_engineer`, `hermes_backend_engineer`,
  `hermes_ml_engineer`, `hermes_qa_test_engineer`, `hermes_reviewing_engineer`,
  `hermes_sre_engineer`, `hermes_incident_manager`) lives inside the OpenShell
  sandbox `hermes-fleet-v1` (Phase 04·F). They run a spec→deploy pipeline
  governed by the shared **team-protocol** skill (definition-of-done, typed
  handoffs, review gate, escalation, turn budget). The **same team is realized
  on three platforms** — Hermes profiles here, **Pi personas** (`bin/pi-as
  <role>`), and **Claude Code** (the manager is the **main agent** via `~/.claude/CLAUDE.md`; the other 8 are subagents in `~/.claude/agents`). All nine route
  to a Claude subscription via Meridian, availability-gated to `local-gemma4`
  when Meridian is down. The Hermes Telegram gateway (Phase 20) runs the
  gateway process *inside the same sandbox*.
- **Pi (Earendil)** coding agent is isolated in its own OpenShell sandbox
  `pi-v1` (Phase 15) with a tight egress allowlist; it reaches LiteLLM via
  `http://host.docker.internal:4000` with `PI_LITELLM_KEY`.
- **DeerFlow** (Phase 10), **ACE** (Phase 17), **RLM** (Phase 18) are
  host-side agents, each routing through LiteLLM with its own scoped key.

### Data / memory layer

The stack runs four distinct memory layers, each with a different shape and
niche:

- **Qdrant** `:6333` — vector store (RAG corpus; the Documents ingestor at
  Phase 06 sweeps `ingestor/inbox` → Qdrant). Document vector RAG.
- **FalkorDB** `:6379` (+ UI `:3000`) — graph/redis memory (reserved for future
  graph-memory work; no current callers).
- **Honcho** `:8000` — self-hosted cross-agent memory: *derived/summarized*
  facts about peers (Postgres + Redis), shared across the whole fleet. Its
  compose Postgres *also* backs the LiteLLM key store, which is why Phase 03
  (Honcho) runs before Phase 01 (LiteLLM): LiteLLM's Prisma migration needs
  Postgres at startup.
- **MemPalace** (Phase 26, opt-in) — **local-first, verbatim conversation
  memory** for Claude Code sessions: a CLI + MCP server (29 tools) + Python
  library (PyPI `mempalace`, MIT). **No daemon, no network port** — it is a
  host-side tool, not a container. Its spatial model maps people/projects to
  *wings*, topics to *rooms*, and content to *drawers*, over a temporal
  entity-relationship knowledge graph in SQLite. Embeddings are **local ONNX,
  on-device via CoreML** (M4 ANE) — default `all-MiniLM-L6-v2` (384-dim,
  English), `embeddinggemma` multilingual opt-in; **no cloud, and NOT via
  LiteLLM**. The only LiteLLM dependency is the *optional* entity-refiner
  (`--extract general`), which routes through LiteLLM via virtual key
  `MEMPALACE_LITELLM_KEY` (openai-compat provider) and is traced in Phoenix.
  Storage backend is local **ChromaDB** (on-device); a Qdrant backend adapter
  is **staged** at `mempalace/backend-qdrant/` (RFC-001 `BaseBackend`,
  conformance-tested against live Qdrant) but **not live** — MemPalace 3.3.5
  hardcodes `ChromaBackend` in `palace.py` and does not consume the backend
  registry / `MEMPALACE_BACKEND` at runtime yet, so Qdrant consolidation is
  *staged, pending upstream registry wiring*.

These four layers cover complementary niches: Honcho is derived/summarized
cross-agent facts, Qdrant is document vector RAG, FalkorDB is graph (reserved),
and MemPalace is verbatim conversation/session recall — the gap that `.remember/`
+ curated memory previously only filled manually. (Code semantic search is a
fifth lens, served by Lumen at Phase 16 — local-only, no LiteLLM dependency.)

### Observability layer

- **Phoenix** `:6006` collects OTLP traces via the `arize_phoenix` callback
  added to LiteLLM at Phase 01·H; OTLP gRPC ingest is on `:4317` (alias
  `phoenix-otlp`). Because every agent's calls go through the single LiteLLM
  egress, every LLM call lands in Phoenix project `ai-stack` with no per-agent
  instrumentation.

---

## Request / data flow — a typical inference

What happens end-to-end when, say, Pi answers a coding prompt:

```
1.  Pi (in pi-v1 sandbox) builds a chat request.
2.  Pi dials  http://host.docker.internal:4000/v1  with  PI_LITELLM_KEY
        (sandbox → host boundary; Pi has no other egress).
3.  LiteLLM authenticates the virtual key and checks the model against that
        key's allowlist (the derived superset — see binding below).
4.  Guardrails callback runs (pre-call deny on the in-process regex/keyword
        rules + secret-leak blocker).
5.  LiteLLM resolves Pi's bound model (local-qwen3-coder) and dispatches:
        · ollama runtime  → Ollama on the host (host-gateway)
        · lmstudio runtime → LM Studio :1234 (host.docker.internal)
6.  Response streams back through LiteLLM; post-call redaction runs.
7.  LiteLLM emits OTLP → Phoenix :4317; the call appears in project
        "ai-stack". The trace_to_file callback also appends to
        traces/litellm.jsonl.
8.  Pi receives the completion. No agent ever touched Ollama / LM Studio
        directly — LiteLLM was the only hop.
```

The same shape holds for every agent; only the key (`HERMES_LITELLM_KEY`,
`ACE_LITELLM_KEY`, `RLM_LITELLM_KEY`, …) and the bound model differ.

---

## Model↔agent binding

`installer/models.yml` (`version: 1`) is the **canonical single source of
truth** for which model each agent uses. It declares 3 canonical models and a
per-agent assignment table; `installer/lib/models.sh` is the `vz-ai-stack.sh
model` implementation that reconciles declarations against what LiteLLM
actually serves.

### The 3 canonical models

| key | runtime | served id | notes |
|---|---|---|---|
| `local-gemma4` | ollama | `gemma4:e4b` | The always-on Ollama **fallback** (`default`) — what every agent gates to when its runtime is down; an unassigned agent renders the `primary` (`claude-opus-4.8-sub-max`) and gates to this (~9.6 GB, stays on Ollama). |
| `local-qwen3.6` | lmstudio | `qwen/qwen3.6-27b` | ~17.5 GB MLX. Cannot coexist with `local-qwen3-coder` on 24 GB. |
| `local-qwen3-coder` | lmstudio | `qwen3-coder-30b-a3b-instruct-mlx` | ~17.2 GB MLX. Cannot coexist with `local-qwen3.6` on 24 GB. |

`default: local-gemma4`. (Phase 25 can optionally add the `local-lfm2-mlx` slug,
but ONLY when opted in via `LMS_LOAD_LFM2=1` — by default `install lmstudio` is
assignment-driven and wires only models.yml-assigned MLX slugs. The heavy
Ollama model `local-heavy` (`qwen3.6:27b`) is **removed** — it now lives in LM
Studio as `local-qwen3.6` (opt-in MLX). `local-heavy` / `local-lfm2` remain
add-only legacy entries in `litellm/config.yaml` that 404 until manually pulled;
neither is auto-pulled, and neither is in the canonical roster.)

### Availability-gating — fallback to `local-gemma4`

The two big models are LM Studio MLX models that may not be loaded. If an
agent is assigned an `lmstudio` model that LiteLLM doesn't currently serve,
`models.sh` does **not** fail — it renders that agent against an effective
fallback (the default, `local-gemma4`) and warns:

```
<agent>: assigned '<model>' (lmstudio) not servable — rendering '<eff>' (availability-gated)
```

This is what keeps a fresh, light 24 GB install functional before any heavy
MLX model is pulled (and it pairs with lazy-Ollama: Phase 01 eager-pulls only
`gemma4:e4b` + `nomic-embed-text`, and `OLLAMA_KEEP_ALIVE=0` keeps nothing
resident).

### The superset allowlist

Every scoped virtual key (`HERMES_`, `PI_`, `ACE_`, `RLM_LITELLM_KEY`) is
minted against a **DERIVED**, sorted-unique **superset** of model names
(`vz-ai-stack.sh model superset` prints it — the union of the legacy
`{local, local-heavy, local-lfm2}` plus every model key in `models.yml`, **not**
a hardcoded list; the `LEGACY_SUPERSET` array in `installer/lib/models.sh` is
only the fallback when `models.yml` is absent). Because each key already allows
the whole superset, `model assign <agent> <model>` (or `model assign all <model>` to
blanket-assign every agent) can re-point agents without ever re-minting their keys.
`model sync` is the crash-safe, opt-in reconcile
(register model_list ADD-ONLY → restart litellm once if changed → widen
scoped-key allowlists to the superset → render agents); it is *not* run by
`install all`. Doctor check 40 (`40_models_binding.sh`) validates the binding
and turns RED on scoped-key/superset drift.

### Overkill protection — the RAM-budget preflight

Before loading a big MLX model, `lms_ram_preflight`
(`installer/lib/lmstudio.sh`) refuses the load **iff**, *strictly*,
`cap + padded_model + headroom > total` RAM — equality **loads**. Constants:
headroom **5 GiB** (`5368709120` B), unknown-size fallback **18 GiB**
(`19327352832` B), resident pad **+15%**, `cap` from `~/.orbstack/vmconfig.json`
`memory_mib` (fallback `max(8 GiB, total/2)`), `total` from `sysctl hw.memsize`.
It **degrades OPEN** (allows, with a note) on any measurement failure — never
fail-closed. A refusal makes the agent availability-gate to `local-gemma4`. The
one-big-MLX policy unloads any other model before load; bypass with
`LMS_SKIP_RAM_PREFLIGHT=1`. See `installer/lib/lmstudio.sh`.

The **Honcho deriver** is a deliberate exception to *per-agent* `models.yml`
selection: it uses one stack-wide model for all derivation, regardless of each
agent's chat-model binding, and the memory plane does not go through `models.yml`
availability-gating. It defaults to the canonical stack default
(`models.yml .default` = `local-gemma4`/gemma4:e4b, which is pre-pulled and
resident) like every other service, and is **overridable via the
`HONCHO_DERIVER_MODEL` env var** in `.env` (Phase 03 reads it and writes
`LLM_OPENAI_MODEL` into `honcho/.env`). Set it to a heavier slug (e.g.
`local-qwen3.6`) for richer personas when you have the RAM headroom.

---

## Host vs. sandbox boundary + lo0 alias networking

There are three vantage points and the same alias is meant to resolve from
each — but the *mechanism* differs, and that boundary is the security story.

- **Container → container** uses Docker's embedded DNS in the `ai-stack`
  bridge: from inside any joined container, `http://litellm:4000`,
  `http://phoenix:6006`, `redis://falkordb:6379` resolve directly. No
  `/etc/hosts` lookup needed.
- **Mac host → service** uses the `/etc/hosts` block + `lo0` aliases (the
  `127.0.10.x` scheme, installed by `prepare-sudo`). Same URL form as the
  container side (`host_port == container_port`).
- **Sandbox → host** (the isolated agents) uses `host.docker.internal`. Pi in
  `pi-v1` reaches LiteLLM at `http://host.docker.internal:4000` — it cannot
  use the `127.0.10.x` aliases, and its egress allowlist is deliberately
  tight. This is the boundary that makes "Pi can only talk to LiteLLM" true.

Two host services that drive agents are **intentionally loopback-only with no
alias** — `claw3d` (`:4310`, refuses a public bind without
`STUDIO_ACCESS_TOKEN`) and `claw3d-bridge` (`:7780`, auth-less and can drive
all 9 agents). LM Studio (`:1234`) likewise has no `lo0` alias because it is
reached from the LiteLLM *container* via `host.docker.internal`, not from a
host alias. (The detailed two-layer aliasing mechanics live in
[Networking (Phase 00·N)](#networking-phase-00n--two-layer-aliasing) below.)

---

## File-by-file responsibility

```
~/ai-stack/
├── vz-ai-stack.sh                       — entry point, dispatcher, NO logic
├── services.yml                     — single source of truth (service registry)
├── .env                             — secrets + config (mode 0600)
│
├── installer/
│   ├── lib/                         — sourced helpers; no direct exec
│   │   ├── common.sh                — log/color/lock/stamp/queue/atomic_write
│   │   ├── env.sh                   — atomic .env read/write (awk-based) + env_ensure_baseline (the .env baseline SSoT)
│   │   ├── deps.sh                  — `vz-ai-stack.sh deps`: host-dependency verify/install/start/re-verify
│   │   ├── setup.sh                 — `vz-ai-stack.sh setup`: interactive, skippable .env / API-key bootstrap
│   │   ├── docker.sh                — managed docker run; recreate guard; backup
│   │   ├── validate.sh              — wait_http / port_listening / require_disk
│   │   ├── prompt.sh                — confirm / choose / secret_input
│   │   ├── litellm.sh               — callback chain mutation helpers
│   │   ├── openshell.sh             — hang-resilient sandbox-create watchdog (phases 04 + 15)
│   │   ├── network.sh               — ai-stack net + /etc/hosts block + lo0 alias binding + launchd plist
│   │   ├── verify.sh                — runtime-probe helpers (used by Phase 00·V + vz-ai-stack.sh verify)
│   │   ├── prepare-sudo.sh          — sudo-only pre-flight (lo0 + /etc/hosts) with path-injection guards
│   │   ├── aliases.tsv              — canonical alias→IP table (single source of truth)
│   │   ├── status.sh                — `vz-ai-stack.sh status` (run via bash)
│   │   ├── adopt.sh                 — `vz-ai-stack.sh adopt <svc>` (interactive)
│   │   ├── gc.sh                    — `vz-ai-stack.sh gc` (partial orphan cleanup)
│   │   ├── history.sh               — `vz-ai-stack.sh history` (assemble CHANGELOG.d)
│   │   └── reset.sh                 — `vz-ai-stack.sh reset --confirm soft|hard|nuke`
│   │
│   ├── phases/                      — one script per phase, all self-contained
│   │   ├── 00_host.sh               — brew + dir tree + .env defaults
│   │   ├── 00s_services.sh          — services.yml validate + stack CLI wrapper
│   │   ├── 00n_networking.sh        — ai-stack docker net + /etc/hosts block + lo0 aliases + launchd plist
│   │   ├── 00v_verify.sh            — runtime verification pre-flight (6 probes; side-effect-free)
│   │   ├── 01_inference.sh          — ollama + LiteLLM
│   │   ├── 01h_phoenix.sh           — Phoenix + arize_phoenix callback
│   │   ├── 02_storage.sh            — FalkorDB + Qdrant
│   │   ├── 03_honcho.sh             — clone + compose + redis port fix
│   │   ├── 04_openshell.sh          — OpenShell binary + policy
│   │   ├── 04f_hermes_fleet.sh      — 9 SOULs + bootstrap (sandbox-side deferred; all-local routing)
│   │   ├── 04g_security.sh          — guardrails.handler + LLM Guard + audit.sh
│   │   ├── 05_uis.sh                — Open WebUI + Hermes Workspace
│   │   ├── 06_documents.sh          — Docling + LlamaIndex venv + MCP server
│   │   ├── 07_autofyn.sh            — best-effort clone
│   │   ├── 08_paperclip.sh          — best-effort clone + pnpm
│   │   ├── 09_alt_memory.sh         — best-effort installed-disabled
│   │   ├── 10_deerflow.sh           — best-effort clone
│   │   ├── 11_halo_autoreason.sh    — best-effort halo-engine (bin/halo) + clone
│   │   ├── 12_blaxel.sh             — npm CLI (cloud-only)
│   │   ├── 13_ragflow_reserved.sh   — no-op placeholder
│   │   ├── 14 … 17                  — best-effort (15 is OpenShell-isolated)
│   │   ├── 18_rlm.sh                — RLM (Recursive Language Models): rlms + bin/rlm
│   │   ├── 19_claw3d.sh             — claw3d 3D agent office + host bridge
│   │   ├── 20_hermes_telegram.sh    — Hermes Telegram gateway (allowlist-gated)
│   │   ├── 21 … 27                  — opt-in extras (install BY NAME): portless … sourcegraph
│   │   └── 04h_agent_fleet.sh       — RUNS LAST: cross-platform 9-role fleet (Claude Code + Pi) + widens PI/HERMES keys
│   │
│   ├── doctor/
│   │   ├── doctor.sh                — discovers + runs all checks/*.sh
│   │   └── checks/                  — one file per failure mode (45 today; 39–45 cover openshell_storm, models_binding, meridian, agent_fleet, watchdog_alert, mempalace, tutorial)
│   │       ├── 01_orbstack_running.sh
│   │       ├── 02_host_docker_internal.sh
│   │       ├── 03_env_valid.sh
│   │       ├── 04_phoenix_endpoint_set.sh
│   │       ├── 05_litellm_env_loaded.sh
│   │       ├── 06_arize_phoenix_callback.sh
│   │       ├── 07_guardrails_file_or_remove.sh
│   │       ├── 08_ollama_models.sh
│   │       ├── 09_phoenix_project.sh
│   │       ├── 10_helicone_cleanup.sh
│   │       ├── 11_port_collisions.sh
│   │       ├── 12_foreign_containers.sh
│   │       ├── 13_phoenix_api_key.sh
│   │       ├── 14_ai_stack_network.sh
│   │       ├── 15_hosts_block.sh
│   │       ├── 16_container_network_membership.sh
│   │       ├── 17_alias_resolution.sh
│   │       ├── 18_dns_collision_guard.sh
│   │       ├── 19_lo0_aliases.sh
│   │       ├── 20_container_alias_routable.sh
│   │       ├── 21_container_dns_in_network.sh
│   │       ├── 22_etc_hosts_ownership.sh
│   │       └── 23_… 49_sourcegraph_mcp.sh  — full list in doc/DOCTOR.md (49 checks total)
│   │
│   ├── smoke/                       — per-phase end-to-end smoke
│   │   ├── 01.sh                    — /v1/models + chat + trace + per-model ping
│   │   ├── 01h.sh                   — Phoenix has ai-stack project
│   │   ├── 02.sh                    — FalkorDB + Qdrant write+read
│   │   ├── 03.sh                    — Honcho /health
│   │   └── 05.sh                    — Open WebUI UI 200
│   │
│   └── state/                       — installer's own state
│       ├── phase_<NN>.done          — empty stamp files (mtime = completion time)
│       ├── restarts-needed.txt      — queued service-restart list
│       ├── .lock/                   — mkdir-as-atomic-lock; PID inside
│       ├── model-ping-results.txt   — per-model PASS/FAIL/SKIP
│       └── openshell-manual-steps.md — generated by phase 04 when CLI has drifted
│
├── bin/                             — daily-driver scripts
│   ├── stack                        — wrapper: `exec bash vz-ai-stack.sh "$@"`
│   ├── ace / pi / lumen             — agent CLIs (route via LiteLLM)
│   ├── halo                         — halo-engine entry (routes via LiteLLM)
│   ├── rlm                          — RLM wrapper → rlm/run_rlm.py (routes via LiteLLM)
│   ├── audit.sh                     — phase 04·G's 4/4 security smoke
│   └── start-*.sh                   — one per managed container service
│
├── litellm/                         — LiteLLM config + custom callbacks
│   ├── config.yaml                  — 23 verified model entries + fallback chains
│   ├── trace_to_file.py             — per-call JSONL writer
│   └── guardrails.py                — pre-call deny + post-call redaction
│
├── data/                            — service state (bind-mounted into containers)
│   ├── phoenix/                     — sqlite + traces
│   ├── falkor/                      — RDB
│   ├── qdrant/                      — vector storage
│   ├── honcho/                      — postgres data
│   └── openwebui/                   — webui-state
│
├── traces/                          — /traces inside litellm container
│   ├── litellm.jsonl                — every LLM call (trace_to_file callback)
│   └── guardrails.jsonl             — every deny/redact event
│
├── guardrails/                      — additional rule files (RO-mounted)
├── honcho/                          — cloned upstream + compose override
├── hermes-workspace/                — cloned upstream (phase 05)
├── openshell/
│   ├── policies/                    — network allowlists per sandbox
│   ├── fleet-souls/                 — Hermes SOUL.md templates (staged on host)
│   └── fleet-bootstrap/             — bootstrap.sh (mounted into sandbox)
├── ingestor/                        — phase 06: docs Python venv + ingest + MCP
├── ingestor/{inbox,processed}/      — drop files in inbox; ingest.py sweeps to processed
└── CHANGELOG.md + CHANGELOG.d/<run>.md   — decisions + per-run logs
```

---

## Why these splits

### Single-source-of-truth: `services.yml`

The Old Way was a `~/.docker-compose.yml` plus a `.env` plus a shell function
in `~/.zshrc` plus a wiki page. Drift between them was inevitable.

The New Way: `services.yml` declares everything (image, ports, bind, depends,
health, phase ownership, env-var consumption). Every other piece of the
installer reads from it:

- `status.sh` joins declared `services.yml` against actual `docker ps` /
  `brew services list` / `pgrep`.
- Phase scripts read `services.yml` for image names + ports.
- Doctor uses `services.yml` for the "should be running" check.
- The `stack` daily-driver CLI is a thin wrapper.

Edit `services.yml`, run `bash vz-ai-stack.sh status` — drift is visible
immediately.

### One file per phase

The old install guide was an HTML doc with 18 sections. The new installer has
35 phase scripts (`installer/phases/00_host.sh` through `27_sourcegraph.sh`; 7 of
them — 21–27 — are opt-in extras installed by name), each:

- Self-contained — can run standalone via `bash vz-ai-stack.sh install <phase>`.
- Has a `precheck()` function that returns 0 if the phase is already done.
- Short-circuits at the top: `if precheck && stamp_check "$PHASE"; then ok && exit 0`.
- Stamps itself at the end via `stamp_mark "$PHASE"`.

The phase order is the install order. Forward references (a phase using
something not yet installed) are physically impossible — each phase script
fails-loud at its own preconditions.

### One file per doctor check

Same logic for the doctor. Each `installer/doctor/checks/<NN>_<name>.sh`:

- Appends its name to `CHECKS=()`.
- Sets `CHECK_TITLE[<name>]="human-readable title"`.
- Defines `<name>_diagnose()` — exits 0 = pass, non-zero = fail.
- Optionally defines `<name>_fix()` — applies the fix (may prompt).

`doctor.sh` discovers them via `checks/*.sh` glob and runs them all. Adding a
new failure mode = adding a new file. No central registry to update.

### lib/ — small, single-purpose helpers

Each helper does one thing:

- `common.sh`: log/color, lock, stamp, restart-queue, atomic_write, per-run id.
- `env.sh`: get_env / set_env / require_env / env_hash / load_env_strict / fix_crlf;
  `env_ensure_baseline` is the **single source of truth for the `.env` baseline**
  (non-secret DEFAULTS + one-time `LITELLM_MASTER_KEY`/`PHOENIX_SECRET` generation +
  stale-`host.docker.internal`-URL migration), called by **both** Phase 00 (`00_host.sh`)
  and `vz-ai-stack.sh setup`.
- `deps.sh`: `vz-ai-stack.sh deps` — bootstraps host dependencies (verify → install → start → re-verify).
- `setup.sh`: `vz-ai-stack.sh setup` — interactive, skippable `.env` / API-key bootstrap; always
  ensures `env_ensure_baseline` first, so a local-only / Claude-subscription user can skip every prompt.
- `docker.sh`: container_exists / managed / recreate_guard / backup / ensure_image.
- `validate.sh`: wait_http / port_listening / require_disk_free.
- `prompt.sh`: confirm / choose / secret_input.
- `litellm.sh`: callback list mutation + verification.

Phase scripts source what they need. Daily-driver scripts under `bin/` source
the same helpers via the same path resolution.

---

## Idempotency model

**Stamps are an advisory cache, not the source of truth.** This was the most
important refinement from the adversarial review.

Every phase script does this:

```bash
if precheck && stamp_check "$PHASE"; then
  ok "phase $PHASE already complete"
  exit 0
fi
# ... actual work ...
stamp_mark "$PHASE"
```

`precheck()` re-verifies actual state: containers running, files present,
ports listening, env vars non-empty. If the stamp says "done" but reality
disagrees, the phase re-runs.

This catches the failure mode where the user manually `docker rm -f honcho`
and then runs `vz-ai-stack.sh install all`. Without the precheck, the stamp would
make the installer skip phase 03 and downstream phases would fail mysteriously.

---

## Locking — `mkdir` is atomic, `flock` is not portable

macOS doesn't have `flock(1)`. The portable atomic primitive is `mkdir`:

```bash
mkdir "$LOCKDIR" 2>/dev/null || lock_held
echo $$ > "$LOCKDIR/pid"
trap 'rm -rf "$LOCKDIR"' EXIT INT TERM
```

`lib/common.sh::lock_acquire` adds stale-lock recovery: on lock-held, if
`$LOCKDIR/pid` exists and `kill -0 $pid` fails, the lock is broken and
re-acquired. `LOCK_FORCE=1` is the manual override.

Only the `install` and `doctor` commands take the lock. `status`, `logs`, and
`history` are read-only and lock-free.

---

## .env writes — atomic, awk-based, never sed -i

`set_env KEY VALUE`:

1. Refuses if `KEY` doesn't match `^[A-Z_][A-Z0-9_]*$`.
2. Refuses if `VALUE` contains a newline.
3. `mktemp ${ENV_FILE}.XXXXXX` → `chmod 600 $tmp` (secrets never touch disk
   world-readable).
4. `awk` rewrites: passes through comments, upserts the key, appends if new.
5. `mv -f $tmp $ENV_FILE` — atomic on same filesystem (one `rename(2)`).

Readers see the old file or the new file; never a half-written one.

`load_env_strict` validates every non-comment line matches `^[A-Z_][A-Z0-9_]*=`
and has no trailing CR. Used as a pre-flight before `docker run --env-file`.

---

## Networking (Phase 00·N) — two-layer aliasing

Every managed service in `ai-stack` is reached by **name**, not by
`127.0.0.1:<port>`. Two layers co-operate to make the same alias resolve
from any vantage point:

| Layer | Who consumes it | How |
|---|---|---|
| `/etc/hosts` block | Mac shell / browser / host-side Python / `bin/audit.sh` | Phase 00·N writes a managed block of 14 `127.0.10.x  <alias>` lines (root:wheel 644) |
| `lo0` aliases | Kernel routing layer | Phase 00·N runs `ifconfig lo0 alias 127.0.10.X up` per row; required because macOS does NOT auto-route `127.0.0.0/8`. Persistence via `/Library/LaunchDaemons/com.ai-stack.loopback.plist` |
| `ai-stack` Docker bridge | Every joined container (via `--network ai-stack`) | Docker's embedded DNS resolves bare container names |
| `--add-host=ollama:host-gateway` | Containers that talk to Ollama (LiteLLM) | Per-container override; only Ollama is host-gateway-routed |

The single source of truth is `installer/lib/aliases.tsv`, a tab-separated
file with one row per alias (alias, IP, protocol, host_port, container_port,
phase, service_key). Phase 00·N, Phase 00·V, the doctor checks (14–22),
the v1→v2 services.yml migration, and every `bin/start-*.sh` all source
`lib/network.sh::aliases_load` and read from the resulting bash associative
arrays. Hand-edited drift between the table and the runtime is impossible
without changing the .tsv.

> **Port form (2026-05-28).** `host_port == container_port` for HTTP
> services. The brief originally proposed `host_port=80` so the Mac
> could dial port-free (`http://litellm`), but OrbStack collapses every
> `--publish *:80:Y` into a single `*:80` wildcard listener — so all
> HTTP services routed to whichever container was registered first.
> Mac and container URLs are now identical
> (`http://litellm:4000`, `http://phoenix:6006`, etc.).

### Why 127.0.10.x

- **Still loopback.** Anything in 127.0.0.0/8 is unreachable from the LAN —
  the security story (services not exposed to the network) is unchanged.
- **Distinct from `127.0.0.1`.** Existing tools or pre-refactor containers
  that bind to `127.0.0.1:<port>` don't interfere with the new bindings.
- **Visually recognizable.** The `10.` octet flags "this is `ai-stack`."
- **Per-alias unique IP** means multiple services can share the same host
  port (e.g., port 80 for HTTP-on-80 service) without `EADDRINUSE`.

### The `ai-stack` Docker network

Created by `installer/phases/00n_networking.sh` with an explicit subnet to
avoid VPN collisions:

```bash
docker network create \
  --driver bridge \
  --subnet 10.99.0.0/24 \
  --gateway 10.99.0.1 \
  ai-stack
```

`10.99.0.0/24` was chosen to avoid Docker's default 172.17/172.18 picks
and the common corp-VPN ranges (10.0–10.50). If your environment uses
10.99.0.0/24, override via `AI_STACK_SUBNET` env var.

### What Phase 00·N actually does

1. **Pre-flight**: refuse if `netstat -nr` shows a pre-existing
   `127.0.10.x` route on a non-`lo0` interface (a VPN client could
   otherwise route /etc/hosts dials off-host). Routes that already point
   at `lo0` are expected — those are our own aliases from a previous
   run.
2. **Pre-flight**: refuse if `AI_STACK_SUBNET` is already used by another
   Docker network (override via env var if needed).
3. Create the `ai-stack` Docker bridge if missing (idempotent).
4. Source `installer/lib/aliases.tsv` and compute the expected /etc/hosts
   block (sha-comparable).
5. If the on-disk block matches, skip the write (no sudo prompt). Else,
   `mktemp` → write merged content → `sudo mv -f` → `sudo chown
   root:wheel /etc/hosts` → `sudo chmod 644 /etc/hosts` → flush
   dscacheutil and mDNSResponder → self-verify the lookup.
6. **`lo0_ensure_aliases`**: for every row in `aliases.tsv` whose IP is
   in `127.0.10.0/24`, run `sudo ifconfig lo0 alias 127.0.10.X up` if
   not already bound. macOS does NOT auto-route `127.0.0.0/8` (only
   `127.0.0.1` is on `lo0` by default) — without this step, /etc/hosts
   resolves but no packets reach the listener.
7. **`lo0_install_persistence_plist`**: write
   `/Library/LaunchDaemons/com.ai-stack.loopback.plist` (root:wheel 0644)
   and `launchctl load` it. The plist re-runs `ifconfig lo0 alias ...`
   on every boot so the aliases survive reboots. Best-effort: a failure
   here downgrades to a warning since the next manual `prepare-sudo` can
   re-establish them.
8. Verify every alias resolves to its expected IP via `dscacheutil` AND
   `getent hosts` (catches the case where dscacheutil is broken or not
   flushed).
9. Stamp `installer/state/phase_00n.done`.

The phase is idempotent and self-healing; running it twice is a no-op,
running it after a partial install reconciles whatever's missing.

### Phase 00·V — runtime verification pre-flight

Phase 00·V runs between 00·N and 01. It is **side-effect-free** — it
only probes; it never mutates. The premise: every architectural claim
the installer makes ("X is reachable at Y") gets a corresponding runtime
probe BEFORE Phase 01 starts a single container.

This phase exists because syntactic checks (`bash -n`, `yq -e`,
`ast.parse`, `docker network inspect`) proved every patch "clean" in the
original Phase 01 incident while the actual TCP path was dead air.

The 6 probes:

1. **`/etc/hosts` ownership**: root:wheel mode 644.
2. **`lo0` routability**: `nc -z 127.0.10.X 0` (or `ifconfig` grep) for
   every alias.
3. **DNS agreement**: `dscacheutil -q host -a name litellm` and
   `getent hosts litellm` return the same IP as `aliases.tsv`.
4. **`--add-host=ollama:host-gateway`**: spawn a transient probe
   container, confirm `getent hosts ollama` resolves to the host gateway
   inside.
5. **End-to-end routing**: bind a transient `--publish 127.0.10.3:65182:80`
   listener (phoenix-otlp IP, port 65182 to avoid collisions), `curl` it,
   confirm 200.
6. **ai-stack network**: a transient `docker run --rm --network ai-stack`
   succeeds. Skips gracefully when the network doesn't yet exist
   (legitimate pre-install state).

Stamp `phase_00v.done` is honored only when fresh (< 5 min) so re-running
the orchestrator doesn't skip stale probes. Failure prints the exact fix
command — usually `sudo bash vz-ai-stack.sh prepare-sudo` — and exits 1
*before* a single Phase 01 container starts.

### `vz-ai-stack.sh verify` subcommand

`bash vz-ai-stack.sh verify` runs Phase 00·V standalone (and clears its own
stamp first so it always actually probes). Use this after any networking
change (VPN connect/disconnect, OrbStack restart, sudo changes) to
confirm the alias chain is still intact before installing or starting
anything.

### `prepare-sudo` — the sudo-only pre-flight

`sudo bash vz-ai-stack.sh prepare-sudo` is the one-shot path that handles
every operation that requires `sudo`. After it succeeds, the rest of
`vz-ai-stack.sh install all` runs without prompting. It:

- writes the `/etc/hosts` managed block (root:wheel 0644);
- binds every alias on `lo0`;
- installs the launchd plist for reboot persistence;
- nothing else — it does NOT install brew, does NOT start containers, and
  does NOT mutate `~/ai-stack/.env`.

Hardening (post-2026-05-28):
- Refuses to run if `AI_STACK` is not under `/Users/`, is a symlink, is
  inside `/tmp/` or `/var/`, or has a foreign-owned ancestor directory.
- Validates `SUDO_USER` is the original invoker (`$SUDO_USER == $USER`
  where `$USER` is the pre-sudo user).
- Uses `chown -h` only on the specific files written; never `chown -R`
  on `$AI_STACK` (which would follow symlinks and corrupt unrelated trees).
- Takes `lock_acquire` before any system mutation; concurrent invocations
  serialize cleanly.

Design record: `installer/state/preparesudo-design-final.md`. Three-agent
review: `installer/state/preparesudo-review-{A,B,C}.md`.

---

## Docker discipline

`bin/start-<svc>.sh` is the only path that creates managed containers. Each
follows three rules:

### 1. Flag order is FIXED

```
docker run -d \
  --name <name> \
  --label ai-stack.managed=true \
  --label ai-stack.phase=<NN> \
  --label ai-stack.partial=true \
  --network ai-stack \
  --add-host=ollama:host-gateway \
  --restart unless-stopped \
  --env-file ~/ai-stack/.env \
  -e VAR=val \
  -p 127.0.10.X:HOST:CONTAINER \
  -v /host/path:/container/path \
  IMAGE \
  CMD ARGS
```

Mixing `-e` after `-p`/`-v` leaks env flags to the entrypoint CLI as args.
LiteLLM then errors `No such option: -e`. The order above is the only safe one.
The `--add-host=ollama:host-gateway` line is only required for containers
that consume Ollama (LiteLLM today); other services can drop it.

### 2. Bind to 127.0.10.x (named loopback) on the service's native port

The host firewall is not the security boundary; explicit bind is. Every port
mapping is `127.0.10.x:PORT:PORT` where `x` comes from the alias→IP
table in `installer/lib/aliases.tsv` (also listed in [PORTS.md](PORTS.md))
and `PORT` is the service's native container port. Each alias gets a
unique loopback address; combined with native-port publish, every service
has a unique `IP:PORT` host-side surface.

> The original design used `host_port=80` to give the Mac port-free URLs
> (`http://litellm`), but OrbStack collapsed every `*:80` publish into a
> single host-side wildcard listener. See
> [CHANGELOG.md 2026-05-28 entry](../CHANGELOG.md) for the diagnosis. Native
> ports avoid the wildcard and Mac+container URLs are now identical.

Container-to-container traffic uses Docker's embedded DNS in the `ai-stack`
bridge network: from inside any joined container, `http://litellm:4000`,
`http://phoenix:6006`, etc. resolve to the corresponding container's
internal IP. No `/etc/hosts` lookup is needed inside containers.

The only host-from-container path that survives this refactor is Ollama
(brew service on the Mac, not a container). Consumers get
`--add-host=ollama:host-gateway` so `ollama:11434` resolves to the host's
gateway IP from inside the container. Phase 00·N probes the `ai-stack`
network exists with the bridge driver, `/etc/hosts` has every alias, lo0
is bound for every alias IP, and `dscacheutil -q host -a name <alias>`
agrees with the table.

### What's in `/etc/hosts`

Phase 00·N appends a contiguous block delimited by markers
(`# >>> ai-stack (managed; do not edit manually) >>>` … `# <<< ai-stack
(managed) <<<`) containing one IPv4 entry per alias (15 lines today). The
block is computed from `installer/lib/aliases.tsv`; if the on-disk block
matches, the write is skipped (and no sudo prompt fires). On change, the
helper writes via `mktemp` → `sudo mv` → `sudo dscacheutil -flushcache`
→ `sudo killall -HUP mDNSResponder`, then self-verifies with a fresh
`dscacheutil -q host -a name`. IPv6 (::1) is intentionally not used —
the stack listens IPv4-only.

### 3. Labels for ownership + GC

Every managed container gets:

- `ai-stack.managed=true` — this installer owns it. (Foreign containers
  without this label are reported as `foreign` in status; user must
  `vz-ai-stack.sh adopt` to take ownership.)
- `ai-stack.phase=<NN>` — which phase installed it.
- `ai-stack.partial=true` — set at create, removed by `mark_ready` after
  smoke test passes. `vz-ai-stack.sh gc` cleans `partial=true` orphans.

### 4. Recreate guard

`recreate_guard "$NAME" "$RECREATE_FLAG"` aborts unless `--recreate` is
explicit or `FORCE_RECREATE=1` is set. On `--recreate`:

- Backs up stateful data via `docker cp` to `data/<svc>.bak-<ts>/`.
- `docker rm -f <name>`.
- Caller proceeds to `docker run` the new one.

No silent `docker rm -f` anywhere. Conservative-mode is the default.

---

## Adoption flow (foreign containers)

`bash vz-ai-stack.sh adopt <svc>` is the path for a container that was started
outside the installer (typical situation: a previous session). It's
intentionally hand-cranked, never auto:

1. `docker inspect` — show user the current ports, mounts, labels, env count.
2. Print what `bin/start-<svc>.sh` *would* produce.
3. Ask `Proceed? [y/N]`. Decline = no-op.
4. On yes: `docker cp <name>:<path>/. data/<svc>.bak-<ts>/` for stateful
   services (Phoenix sqlite, Falkor RDB, Qdrant snapshot, litellm config tree).
5. `docker rm -f <name>`.
6. `bash bin/start-<svc>.sh` — new container with managed labels.
7. Smoke test (HTTP 200 or TCP connect).
8. On success: `mark_ready` removes the `partial=true` label.

The data is in the backup dir until you delete it. If anything went wrong
during recreate, manual recovery is `docker cp` from the backup back into the
new container.

---

## LiteLLM callback chain

`lib/litellm.sh` enforces the rule: **file first, list second, recreate
third, verify fourth**.

```bash
litellm_ensure_callback "guardrails.handler" "guardrails.py"
```

does:

1. Assert `litellm/guardrails.py` exists on host (else LiteLLM crashes
   `ImportError` at startup).
2. yq-mutate `litellm_settings.callbacks` in `config.yaml`, idempotent
   (`unique` filter).
3. Caller is responsible for triggering recreate via `queue_restart litellm`
   (conservative mode) or calling `start-litellm.sh --recreate`.
4. After recreate, `litellm_assert_callback_loaded "$mod"` greps the new logs.

This is the order; reversing any pair causes a known landmine.

---

## Downstream-restart queue

A phase that mutates `.env` in a way that requires restarting an
already-installed upstream service writes to
`installer/state/restarts-needed.txt`:

- Phase 01·H sets `arize_phoenix` callback → needs litellm restart.
- Phase 03 generates `HONCHO_API_KEY` → needs litellm restart (consumer).
- Phase 04·G adds `guardrails.handler` → needs litellm restart.

End of `install all` prints:

```
⚠ Queued restarts pending (run 'vz-ai-stack.sh apply-restarts'):
    litellm
```

User runs `bash vz-ai-stack.sh apply-restarts`, which executes
`bash bin/start-<svc>.sh --recreate` per queued service (interactive
confirmation, with backup-before-recreate for stateful services).

The queue is conservative by design: phases never auto-restart something the
user is actively using.

---

## Multi-agent review (one-time, build-time)

The architecture was approved by three independent reviewers at build time
(transcripts and decisions in [CHANGELOG.md](../CHANGELOG.md)):

- **Domain Expert A** (AI infra) — LiteLLM/Ollama/Phoenix/OTel/OrbStack runtime
  concerns.
- **Domain Expert B** (DevOps/bash/macOS) — bash 5+ requirement, strict-mode
  flags, awk-based env writes, mkdir-lock, doctor namespacing.
- **Adversarial reviewer** — found 13 failure modes including the existing-
  foreign-container drift loop, OrbStack bind-mount data nuke, `.env` typo
  silent-fail, progress.json staleness, Honcho chicken-and-egg.

Every one of their concrete recommendations is in the code. The review is
captured in CHANGELOG so future maintainers can see the reasoning, not just
the outcome.

---

## What's intentionally **not** here

- **No central state DB.** Stamps are individual files. Progress is computed
  from filesystem + docker ps + curl. Adding more state would create more
  drift surface.
- **No installer-internal "framework."** Phases call lib helpers; doctor
  discovers checks via glob. No DSL, no plugin registry, no annotations.
- **No automatic config migration.** `services.yml` has a `version: 1` field
  for the day a breaking schema change is needed, but there are no migration
  scripts yet. When that day comes, write
  `installer/migrations/v1-to-v2.sh` and detect at vz-ai-stack.sh startup.
- **No silent destructive ops anywhere.** Even `reset --confirm` requires
  the tier name as a second arg; `nuke` requires typing `nuke ai-stack`
  literally.

These omissions are deliberate. If you find yourself reaching for them, that
might be a sign the system has grown past its current operating model — read
the principles in [README.md § Operating principles](../README.md#operating-principles-mayssams-constitution-internalized) first.
