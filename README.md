# ai-stack

A personal, self-hosted, comprehensive and versatile multi-agent AI stack.
One command brings it up, validates it, and heals itself.

```bash
bash ~/ai-stack/install.sh
```

That's the daily-driver entry point. It is idempotent, interactive only when it
truly needs your input, and conservative by default — it never destroys a
running container without explicit confirmation.

---

## What's in the box

| Layer | Tool | Alias | Phase |
|---|---|---|---|
| Container runtime | OrbStack | — | 00 |
| Networking layer | `/etc/hosts` + `ai-stack` Docker bridge | — | 00·N |
| Inference proxy | LiteLLM | `litellm` | 01 |
| Local model serving | Ollama | `ollama` (host brew) | 01 |
| Observability | Phoenix (Arize) | `phoenix` + `phoenix-otlp` | 01·H |
| Graph DB | FalkorDB | `falkordb` + `falkordb-ui` | 02 |
| Vector DB | Qdrant | `qdrant` | 02 |
| Cross-agent memory | Honcho (self-hosted) | `honcho` | 03 |
| Agent sandbox | OpenShell | — | 04 |
| Agent fleet | Hermes — 7 profiles | `hermes-gw` (reserved) | 04·F |
| Security | guardrails + LLM Guard + audit | `llm-guard` | 04·G |
| Chat UI | Open WebUI | `openwebui` | 05 |
| Fleet UI | Hermes Workspace | `workspace` | 05 |
| Docs RAG | Docling + LlamaIndex + MCP | `docs-mcp` | 06 |
| Coding agent | AutoFyn | `autofyn` | 07 |
| Task agent | Paperclip | `paperclip` | 08 |
| Research | DeerFlow | — | 10 |
| Cloud runtime | Blaxel (keys only) | — | 12 |
| Fine-tuning / training | Unsloth Studio | `unsloth` | 14 |
| Sandboxed coding agent | Pi (Earendil) | `pi-v1` (OpenShell sandbox) | 15 |
| Code semantic search (MCP) | Lumen (Ory) | `bin/lumen` (stdio, no port) | 16 |
| Recursive Language Models | RLM (`rlms`) | `bin/rlm` (Docker REPL sandbox) | 18 |
| 3D agent office | claw3d + stack-agents bridge | `localhost:4310` | 19 |
| Fleet chat from your phone | Hermes Telegram gateway | `@vz_hermes_controller_bot` | 20 |

### Networking

Mac and containers reach services by name: `http://litellm:4000`, `http://phoenix:6006`,
`redis://falkordb:6379`, etc. The aliases are populated into `/etc/hosts`
(pointing at the `127.0.10.x` loopback range) and into Docker's embedded DNS
(via the `ai-stack` bridge network). Phase 00·N sets both up in one
idempotent pass. See [PORTS.md](doc/PORTS.md) for the full alias table.

---

## Quick start

```bash
# First-time only: handle every sudo step in one shot
# (writes /etc/hosts block, binds lo0 aliases, installs launchd plist)
sudo bash ~/ai-stack/install.sh prepare-sudo

# Verify the alias chain end-to-end (cheap; < 10 sec)
bash ~/ai-stack/install.sh verify

# Full install (resumes from last incomplete phase)
bash ~/ai-stack/install.sh

# See declared vs actual state
bash ~/ai-stack/install.sh status

# 32 health checks + auto-fixes
bash ~/ai-stack/install.sh doctor

# Take ownership of a container started outside the installer
bash ~/ai-stack/install.sh adopt <service>

# Apply queued restarts (e.g. after .env changes)
bash ~/ai-stack/install.sh apply-restarts
```

Add this to your shell rc for the short `stack` alias:

```bash
export PATH="$HOME/ai-stack/bin:$PATH"
# Then:  stack status, stack doctor, stack adopt litellm, etc.
```

---

## Where to read next

### Learn the stack (start here if it's all new)

- **[USER-GUIDE.md](doc/USER-GUIDE.md)** — task-oriented walkthrough for the
  first-time-in-this-stack reader. 5-minute wow → 4 core recipes (RAG,
  memory-aware coding, sandboxed Pi, Phoenix evals from JSONL replay) →
  3 stretch recipes (research fleet, paranoid mode, fine-tune) → daily
  cheatsheet → triage. Every recipe ends with the Phoenix trace pattern
  to look for. ~540 lines.
- **[STACK-GUIDE.md](doc/STACK-GUIDE.md)** — service-by-service tour. What every
  tool is, why it exists, what it does for you. Written for someone who
  knows what an LLM is but not what an "LLM proxy" or "vector DB" is. 20
  small Mermaid diagrams (every service box shows `name :port`). ~990 lines,
  but each service is ~200 words.
- **[DIAGRAMS.md](doc/DIAGRAMS.md)** — system architecture in pictures. System
  overview, 8-layer boundary diagram, 4 user-story sequence diagrams (chat
  via Open WebUI, Hermes researcher uses local+cloud, PDF ingestion, agent
  runs a shell command in sandbox), security/trust boundaries, data
  locality ("what stays local vs goes to the cloud"), the 4 memory profiles.
- **[ALTERNATIVES.md](doc/ALTERNATIVES.md)** — for each tool, 3–5 substitutes
  with one-line differentiators. Useful if you're evaluating "should I use
  X instead of Y."

### Reference

- **[COMPONENTS.md](doc/COMPONENTS.md)** — brief catalog of everything in the stack:
  all 38 services + CLI tools, grouped by layer (inference, memory, agents, UIs,
  tools, platform), one line + access point each. The "what's in the box" index.
- **[ATTRIBUTION.md](doc/ATTRIBUTION.md)** — source link + license + ToS for every
  third-party tech piece (software *and* model weights), leading with the
  non-permissive ones to watch (OrbStack, Phoenix, FalkorDB, LFM2, …).
- **[PORTS.md](doc/PORTS.md)** — authoritative port + service map. Every port
  cross-referenced against `services.yml`, the start scripts, and live
  `docker inspect`. Conflict notes, reserved ports, and a single bash
  command to see what's actually listening right now.
- **[DEPENDENCIES.md](doc/DEPENDENCIES.md)** — dependency DAG, network topology
  (host vs container vs `honcho_default` network vs sandbox), talks-to
  matrix, 3 sequence diagrams for the most-important request flows,
  startup-order graph, and a failure-mode-cascade table for triage.

### Operate

- **First-time install** — read [INSTALL.md](doc/INSTALL.md). Step-by-step from a
  fresh machine, plus the post-install manual steps (Phoenix API key,
  foreign-container adoption, OpenShell sandbox).
- **Day-to-day** — read [OPERATIONS.md](doc/OPERATIONS.md). Daily commands, how to
  enable/disable services, common recipes.
- **Something's broken** — read [DOCTOR.md](doc/DOCTOR.md) for what each of the 33
  doctor checks means and how to fix, then [TROUBLESHOOTING.md](doc/TROUBLESHOOTING.md)
  for less common issues.

### Modify or extend

- **Modifying the installer** — read [ARCHITECTURE.md](doc/ARCHITECTURE.md). Design
  decisions, file-by-file responsibilities, idempotency model, lock strategy,
  the multi-agent review cycle that produced the current shape.
- **Continuing this work** (next session, another Claude/human) — read
  [HANDOFF.md](doc/HANDOFF.md) first.
- **What changed and why** — read [CHANGELOG.md](CHANGELOG.md). The architecture
  decision and outcome of each non-trivial action are recorded there.

---

## Operating principles (Mayssam's constitution, internalized)

The installer follows these at every step. They override every other instinct:

1. **Do not assume; verify.** Every shell command was executed in a sandbox
   before being committed. Every config format is parsed back. Every env var
   is fetched from upstream docs, not pattern-matched from memory.
2. **Hypothesis-first.** Before changing code: state what's happening, why,
   what would prove or disprove it, smallest test to validate.
3. **Validate every step.** After any action, verify the intended effect.
4. **End-to-end success.** "Container started" ≠ done. "Exit 0" ≠ done.
   Done = works from your real perspective.
5. **Reversibility.** Backup before risky changes. Atomic writes for `.env`.
   `docker cp` before any container recreate that holds state.
6. **Fail loudly at preconditions.** Every script aborts at the top if
   required files / env vars / services are missing.

If you find yourself fighting the installer because it's being "too careful,"
that's the design — re-read [ARCHITECTURE.md](doc/ARCHITECTURE.md) before patching
the guard rails.

---

## Layout

```
~/ai-stack/
├── install.sh              # entry point — bash-5+ gate + subcommand dispatcher
├── services.yml            # single source of truth (38 services, 4 profiles)
├── .env                    # secrets + config (0600)
├── README.md ← you are here
├── CHANGELOG.md            # what was decided + done
├── doc/                    # all docs: INSTALL, ARCHITECTURE, OPERATIONS, DOCTOR, TROUBLESHOOTING, HANDOFF, PORTS, …
├── CHANGELOG.d/            # per-run logs (avoid race on multi-shell)
├── bin/                    # daily-driver: stack, start-<svc>.sh, audit.sh
├── installer/
│   ├── lib/                # common, env, docker, validate, prompt, litellm, status, adopt, gc, history, reset, openshell
│   ├── phases/             # one file per phase (00 .. 24)
│   ├── doctor/checks/      # one file per failure mode (37 checks)
│   ├── smoke/              # per-phase end-to-end smoke tests
│   └── state/              # stamp files, restart queue, lock dir
├── litellm/                # config.yaml, trace_to_file.py, guardrails.py
├── data/                   # {phoenix,falkor,qdrant,honcho,openwebui}
├── traces/                 # litellm.jsonl + guardrails.jsonl
├── honcho/                 # cloned upstream + override
├── hermes-workspace/       # cloned upstream (Phase 05)
├── openshell/policies/     # network allowlists for sandboxes
└── ingestor/               # Phase 06: docs ingestion venv
    └── {inbox,processed}   # drop files here to ingest
```

---

## Status

See [CHANGELOG.md](CHANGELOG.md) and [doc/HANDOFF.md](doc/HANDOFF.md) for the full
snapshot; run `bash install.sh doctor` for live state. Top-line:

- **27 core install phases (+4 opt-in extras: portless · cmux · skillspector · openagents) · 38 services · 37 doctor checks.**
- A clean `reset --confirm hard --yes` → `install all` reaches **37/37 doctor green**
  (verified end-to-end 2026-05-31, incl. Phase 18 RLM, Phase 19 claw3d, Phase 20 Telegram).
- Known-flaky: OpenShell's relay can idle-timeout (HANDOFF § 2.1) and surface 2
  sandbox-exec check failures (pi-v1, hermes) on a long-idle stack — a reset clears it.
