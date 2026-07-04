# Agent Onboarding — the new owner's handoff

> **Who this is for.** A fresh agent (or human) who will **own and develop** `ai-stack` — not
> just use it. By the end you should hold the mental model, the conventions, the operating
> constitution, and the recipe to ship features without breaking the live stack.
>
> **How it differs from the neighbours** (don't confuse them):
> - [`ONBOARDING.md`](ONBOARDING.md) — *"you installed it, now **use** it."* End-user usage.
> - [`HANDOFF.md`](HANDOFF.md) — *"continue my in-flight **session**."* A point-in-time state dump + known-flaky recovery dances (parts are stale; treat its counts/dates as historical).
> - **This file** — *"become the **owner**."* Durable model + conventions + extension recipe.
> - [`README.md`](../README.md) — the public "what is this" + quickstart.
>
> **Companion:** [Appendix A](#appendix-a--the-activation-prompt) is a copy-paste **activation
> prompt** — hand it to a fresh agent and it self-onboards using this doc.
>
> **Golden rule of this doc:** every count/name/port here is a *snapshot* (verified 2026-06-25).
> The running system is the source of truth. Wherever you see a number, the command to get the
> **live** value is given. Trust the command, not the number (SOUL #1).

---

## 0. The 60-second model

`ai-stack` turns **one Apple-Silicon Mac into a private AI cloud**: local models, a 9-role agent
fleet, memory, RAG, and full call-by-call observability — wired behind a **single local
endpoint**, driven by **one script**. Nothing leaves the machine unless you add a key.

Three things to burn in:

1. **One control surface.** Everything is `bash vz-ai-stack.sh <command>` (alias `bin/stack`).
   You almost never run `docker` by hand.
2. **One inference hub.** Every agent's only route to a model is `http://litellm:4000/v1`
   (LiteLLM). That's where keys, routing, guardrails, and tracing live. There is no second door.
3. **One source of truth per concern.** `services.yml` (services), `installer/models.yml`
   (model↔agent binding), `installer/lib/aliases.tsv` (hostnames), `doc/SOUL.md` (how you work).

```
        You ── UI / CLI ──┐
                          ▼
   ┌──────────────────────────────────────────────────────────────┐
   │  vz-ai-stack.sh  (install · start · doctor · model · …)        │
   └──────────────────────────────────────────────────────────────┘
                          │ operates
                          ▼
  Agents ───────►  LiteLLM :4000  ───►  Models (Ollama · LM Studio · Claude-sub · cloud)
  (Hermes fleet,        │  │                    └──────────────► every call traced
   Pi, DeerFlow,        │  └──► Guardrails (fail-closed)         to Phoenix :6006
   AutoFyn, …)          ▼
                  Memory & Data plane:
                  Honcho · Qdrant · FalkorDB · MemPalace · Lumen
```

**Live numbers (2026-06-25 — verify, don't trust):**

| Thing | Snapshot | Get it live |
|---|---|---|
| Services | **51** in `services.yml` (~25 networked; the rest are `network:none` patterns/features/keys) | `yq '.services\|keys\|length' services.yml` |
| Doctor checks | **68** (dynamic — a new check file auto-bumps it) | `bash vz-ai-stack.sh doctor` |
| Phase files | **46** (00–38 + sub-phases; 29 core / 17 opt-in) | `bash vz-ai-stack.sh phases` |
| Chat-model routes | **20** across **6 runtimes** | `bash vz-ai-stack.sh model list` |
| Host | M4 MacBook Pro, 24 GB, macOS, OrbStack, Homebrew, brew bash 5.x | `bash vz-ai-stack.sh status` |

> Why "51" but other docs say different: `services.yml` has 51 keys, but many are not *reachable
> services* — 2 `litellm-feature` (in-process callbacks), 1 `agent-pattern` (a prompting
> discipline, not a process), 1 `litellm-virtual-key` (a credential), 15 `cli-only` (no daemon).
> Counting "things with a URL" gives ~25. **This is the recurring trap: define what you're
> counting before you cite a number.**

---

## 1. The operating constitution & non-negotiables (read this first — it's what gets people in trouble)

This codebase is **built around** [`doc/SOUL.md`](SOUL.md) — a **25-rule constitution** — and the
owner enforces it without exception. Internalize it well enough to cite rules by number. The full
text is in `SOUL.md`; the spine:

- **#1 Verify, don't assume.** Inspect real state/config/ports/runtime before acting. (This whole
  doc is written to be re-verified, not believed.)
- **#2 Research when uncertain.** Read docs/source/issues; extract lessons before acting.
- **#3 Hypothesis-first debugging.** State what you think is happening + the smallest safe test
  before changing anything. No thrashing.
- **#4–#5 Validate every step; prove it end-to-end** from the **real user's** perspective
  (browser/CLI), not a green log. "Container up" ≠ done.
- **#6 Don't drift.** >4 failed attempts → stop, summarize, re-plan.
- **#8 Prefer reversible changes.** Back up before risk; keep a rollback path; update CHANGELOG.
- **#9/#11 Know your filesystem/runtime context.** Host vs OrbStack bind-mount vs sandbox are
  *not interchangeable*. Verify the running container sees your write.
- **#10 Script files for complex commands.** Anything with JSON/nested quotes/braces → write a
  script and run it.
- **#13–#14 Read before writing; minimal diffs.** Match local conventions; smallest safe change.
- **#15 Don't invent APIs/flags.** Verify from `--help`/source/tests.
- **#17/#23 Multi-agent rule.** Parallelize only clearly-separable work; you stay the orchestrator.
- **#24 Review to consensus before "done."** See §9. **#25 Always edit branch work in a worktree.**

### The non-negotiables that bite fastest (learned from real incidents)

| Rule | Why (the incident behind it) |
|---|---|
| **Edit branch work in a git worktree — always, before the first edit.** | A parallel session hijacks HEAD between `add` and `commit`; commits landed on the wrong branch (happened ≥2×). |
| **But OPERATE the live stack (install/start/doctor/recreate) only from the MAIN checkout.** | Containers bind-mount the workspace path; running the stack from a worktree, then removing it, took Honcho's Postgres down → LiteLLM 503 on every key. *Edit in worktree; run stack from main.* (`installer/lib/worktree.sh` enforces this — it **refuses** install/start/heal from a worktree.) |
| **Finish autonomously. No confirmation gates.** | "Given an order, finish it" — diagnose→fix→sweep docs→verify→report. Status updates fine; "shall I proceed?" gates make the owner *very* angry (repeated ≥10×). Only stop for genuinely destructive/irreversible/external actions. Convening the §24 council is autonomous, not permission-seeking. |
| **doctor-green ≠ done.** | "Done" was declared on a curated allowlist while a container crash-looped invisibly. Check the **full** `doctor` (incl. check 53 container-liveness census) from MAIN before claiming done. |
| **Doc-sweep on every service add/remove, in the same change.** | Counts/lists drift across README, EXPLORE.html, TUTORIAL.md(→regen .html), ATTRIBUTION, CHANGELOG. Sweep them together, never "later." |
| **Never `rm`/mutate the real `~/ai-stack/.env`.** | It's gitignored with no restore; a test cleanup deleted it. Env-touching smoke runs in a worktree with a throwaway `ENV_FILE`. |
| **Always pull → commit → merge → push after a task.** | Work isn't done while local/uncommitted. It's part of "done," not a follow-up ask. |
| **`.env` is 0600; never echo secret *values*.** Atomic writes only (§5 / §11). | Secrets in logs / world-readable `.env` are a hard fail. Writes go through `lib/env.sh::set_env` (awk→tmp→`mv`), never `sed -i`/`echo >>`. |

Plus these **codebase-specific** rules (the author's repeated explicit asks — they break the stack
or leak secrets fastest):
- **No copy-paste `docker` commands** — `bin/start-<svc>.sh` is the source of truth for running a service.
- **No cloud embeddings** — all embeddings are local (nomic-embed-text / jina), never a cloud API.
- **Per-service env injection** for LiteLLM keys (scoped `-e`, never a blanket `--env-file`).
- **Guardrails fail CLOSED** on internal errors (deny on doubt; never fail-open).
- **`/etc/hosts` ai-stack block stays `root:wheel` 644** (doctor check 22 enforces).
- **No zombie background tasks** — foreground anything under ~60s; if you must background it, kill on completion.
- **OrbStack `*:80` wildcard collision is permanent** — don't chase port-free aliases (`http://litellm/`); stay on `http://litellm:4000` (investigated + reverted 2026-05-28).

---

## 2. Architecture & the mental model

### Layers (host vs container vs sandbox — they're different worlds, SOUL #9)

```
HOST (your Mac, brew + launchd)        CONTAINERS (OrbStack, "ai-stack" bridge net)     SANDBOXES (OpenShell)
  ├─ Ollama            :11434           ├─ LiteLLM        :4000  (the hub)              ├─ hermes-fleet-v1 (9 roles)
  ├─ LM Studio (opt)   :1234            ├─ Phoenix        :6006  (traces)               └─ pi-v1 (Pi coder)
  ├─ Meridian daemon   :3456 (Claude)   ├─ Qdrant         :6333  (vectors)                 deny-by-default egress;
  ├─ docs-mcp, paperclip (bg daemons)   ├─ FalkorDB       :6379  (graph)                    reach LiteLLM via
  ├─ Caddy ingress (opt, :80/:443)      ├─ Honcho (+PG)   :8000  (memory)                   host.docker.internal
  └─ vz-ai-stack.sh + bin/* + installer/└─ Open WebUI     :8080  (chat UI)                  + a scoped virtual key
```

- **Reach everything by name, same on Mac and in containers**: `http://litellm:4000`,
  `http://phoenix:6006`, `redis://falkordb:6379`. `/etc/hosts` pins each alias to a `127.0.10.x`
  loopback IP; Docker's embedded DNS resolves bare names inside the `ai-stack` network.
  `installer/lib/aliases.tsv` is the alias↔IP↔port table; [`PORTS.md`](PORTS.md) is the readable map.
- **Two deliberate exceptions:** the claw3d bridge (`:7780`) and LM Studio (`:1234`) are
  `127.0.0.1`-only (no lo0 alias) by design.
- **The data plane hangs off LiteLLM**, not the agents. Agents are thin; the hub is where
  routing, scoped keys, guardrails, and tracing converge.

### The request you should be able to draw from memory

`Open WebUI → LiteLLM (auth + guardrail pre-check) → model → stream back → guardrail post-check →
OTLP trace to Phoenix (async) + one JSONL line to traces/litellm.jsonl`. If you understand that
round-trip, you understand the spine. Deep diagrams: [`DIAGRAMS.md`](DIAGRAMS.md) / `DIAGRAMS.html`.

Full design rationale, idempotency model, lock strategy, file responsibilities:
[`ARCHITECTURE.md`](ARCHITECTURE.md).

---

## 3. The control surface — `vz-ai-stack.sh`

One entry point (`bin/stack` is a thin wrapper). Put `bin/` on PATH:
`export PATH="$HOME/ai-stack/bin:$PATH"`.

**Daily drivers**

| Command | What it does |
|---|---|
| `status` | Declared-vs-actual + ownership table (your first read) |
| `doctor [filter]` | 70 health checks + per-check auto-fix; `doctor network`/`openshell` filters |
| `phases` | Every phase: id → name |
| `verify` | Cheap (<10s) runtime probe of the alias chain (lo0/`/etc/hosts`/DNS/routing) |
| `logs <svc> [-f]` | `docker logs` wrapper |
| `model list\|assign\|sync\|…` | Declarative model↔agent binding (see §5) |
| `bin/claude-litellm <model>` | Run the Claude Code CLI itself on any LiteLLM model (kimi/gpt/glm/…); see `doc/CLAUDE-CODE-MODELS.md` |
| `embedding list\|show\|assign\|global` | Embedding-model registry (guards dim/coupling) |

**Lifecycle**

| Command | Notes |
|---|---|
| `install <phase\|all> [--dry-run\|--plan] [--include-optionals]` | Run a phase by **name, number, or alias**; `all` = core only; `--include-optionals` adds every opt-in |
| `start <svc>` / `stop <svc>` / `run <svc>` | Idempotent funnel → `bin/start-<svc>.sh`; auto-opens UIs (gated; `--no-open`/`--open`). Reverse form: `stack <svc> start` |
| `upgrade <svc\|all> [--check\|--outdated\|--dry-run]` | Type-dispatched upgrade; `--check` = read-only "what's outdated?" |
| `apply-restarts` | Drain queued container recreates (after `.env`/config changes — the CLI is not a daemon) |
| `reset --confirm soft\|hard\|nuke [--yes]` | Tiered destructive reset (preserves Ollama/models/images/`.env`/hosts block) |
| `cleanup` / `gc` | Reclaim regenerable artifacts (node_modules/.venv/caches) / git gc |

**Setup & platform**

`deps [--check]` (host-dep bootstrap) · `setup`/`keys` (skippable `.env`/API-key wizard) ·
`prepare-sudo` (the one sudo step: `/etc/hosts` + lo0 + launchd) · `docker-engine select|status`
(pin the whole stack to one engine) · `ingress up|trust|reload` (host-native bare-hostname Caddy) ·
`adopt <svc>` (claim a foreign container) · `migrate-v2`.

**Fleet & agents**

`fleet list|add|remove|new|destroy` · `hermes …` · `fleet-studio` (edit agent profiles in a web UI).

**Web consoles (serve a doc + a safe live proxy)**

`tutorial-serve` (TUTORIAL.html + ephemeral-key demo proxy) · `models-serve` (Model & Agent
Console — view/stage/apply model+agent+fallback edits) · `understand-dashboard` (knowledge-graph UI).

**Help is first-class:** `help` / `<cmd> --help` / `help <svc>` (per-service: what / live config /
usage) / `help services` / `help regen`.

---

## 4. Installer & phase architecture

Read [`ARCHITECTURE.md`](ARCHITECTURE.md); the essentials:

- **Phases** live in `installer/phases/NN_name.sh`, one per concern. Each: sources
  `installer/lib/common.sh` (+ `env.sh`/`docker.sh`/`worktree.sh`), runs `precheck()` to
  **re-verify actual state**, does its idempotent work, then `stamp_mark`s a `.done` file in
  `installer/state/`.
- **Stamps are advisory cache, not truth (discipline rule #1).** `precheck()` re-checks every
  time; a `docker rm` + re-run won't be silently skipped.
- **Core vs opt-in is one lever:** `install_all_phase_order()` in `vz-ai-stack.sh` echoes the core
  phase IDs. **In the list → core** (run by `install all`). **Not in the list → opt-in** (install
  by name, or all of them via `--include-optionals`; the opt-in set is computed at runtime as
  *all phases − core*, so it can't drift). To promote an opt-in phase to core, add its ID to that
  echo string.
- **Core order (note the deliberate ordering):** `00 00s 00n 00v 02 03 01 01h 04 04f 04g 05 06 07
  08 09 10 11 12 13 14 15 16 17 18 19 20 04h 26`. **03 (Postgres) before 01 (LiteLLM)** — LiteLLM's
  Prisma migration hangs without Postgres. **04h (agent fleet) after its deps.** **26 (MemPalace)
  last** — a zero-dependency leaf, fail-isolated.
- **`install <target>` resolves** a numeric id, a phase-name suffix (`understand` → `30_understand.sh`),
  or a friendly alias (`litellm`→inference, `telegram`→hermes_telegram, `sandbox`→openshell, …).
- **`installer/lib/*.sh`** are sourced helpers, not run directly: `common.sh` (log/ok/warn/err,
  locks, stamps), `env.sh` (atomic `.env` upserts + `get_env`/`set_env`), `docker.sh`
  (`docker_run_managed`, …), `network.sh` (aliases loader), `litellm.sh` (virtual-key minting),
  `status.sh`, `models.sh`, `worktree.sh` (the guard), and ~30 more.
- **`installer/smoke/NN.sh`** = per-phase end-to-end smoke. **`installer/doctor/checks/NN_*.sh`** =
  one file per failure mode (auto-discovered).

**Two discipline rules that cause real outages if broken:**
1. **Docker run flag order is FIXED:** `-d --name <labels> --network --add-host --restart
   --env-file -e VAR -p -v IMAGE CMD`. Put `-e` after `-p`/`-v` and flags leak to the entrypoint
   (LiteLLM dies with `No such option: -e`). Start scripts are the source of truth — no copy-paste
   `docker run`.
2. **`.env` writes go through `lib/env.sh::set_env`** (awk → tmpfile → `chmod 600` → `mv`). Never
   `sed -i`, never `echo >>` for an upsert.

---

## 5. Models & routing

- **LiteLLM is the only egress.** Point anything at `http://litellm:4000/v1`; you get routing,
  scoped keys, guardrails, and tracing for free.
- **`installer/models.yml` is the single source of truth** for which model each agent uses and what
  LiteLLM serves. Render it with `model sync` (opt-in — *not* run by `install all`).
- **20 chat routes across 6 runtimes** (live: `model list`):
  - **ollama** (3 aliases, 1 model) — host brew; `local` (`nemotron-3-nano:4b`) is the
    **default + always-on fallback** every agent gates to when its runtime is down.
    `local`, `local-heavy`, and `local-nemotron3-nano-4b` all map to the same nemotron
    model (the ONLY local chat model). `OLLAMA_KEEP_ALIVE` keeps it warm.
  - **lmstudio** (1, opt-in) — `local-nemotron3-nano-4b-mlx` (the same nemotron on Apple
    MLX, Phase 25) plus the opt-in `local-lfm2-mlx` LFM2.5 demo (`LMS_LOAD_LFM2=1`).
    **Model names drift — `model list` is authoritative.**
  - **meridian** (7) — the **Claude subscription** via the host Meridian daemon (`:3456`): an
    effort ladder `claude-opus-sub-{low…max,ultracode}` + `claude-sonnet-sub-*`. **Availability-gated
    to `local` when Meridian is down** (doctor check 41 surfaces it).
  - **openai-compat** (2) — declarative cloud routes (e.g. Sakana Fugu) whose endpoint+key are *data*
    in `models.yml`.
  - **openai** (2) + **codex-bridge** (2) — metered OpenAI / GPT-5.x via the ChatGPT-subscription
    OAuth bridge (opt-in).
- **Naming convention:** version-less aliases (`claude-opus-sub-max`, `openai-gpt`, `sakana-fugu`).
- **Fallback policy:** primary `claude-opus-sub-max`; offline fallback `local`. Editable
  fallback chains via `model fallback` (CLI) / the Model Console (`models-serve`).
- **Scoped keys:** each agent (Hermes, Pi, ACE, RLM, MemPalace, …) mints its own LiteLLM virtual
  key allowlisted to a *derived superset* of models. **Gotcha:** add a model and the old keys
  don't allow it until you `model sync` (re-widens) — doctor check 40 goes RED on this drift.
- **Adding a new provider key:** it must go in `bin/start-litellm.sh`'s `-e` allowlist **and** the
  container must be `--recreate`d (a `docker restart` does **not** reload env).

Deep dive: [`models.md`](models.md). Embeddings are a separate, **local-only** registry
(`embedding list`); cloud embeddings are forbidden (constitutional).

---

## 6. The memory plane (five components, five niches — don't conflate them)

| Component | Phase | Niche | Reach |
|---|---|---|---|
| **Honcho** | 03 | Derived / summarized **cross-agent facts** about a user (Postgres + Redis) | `http://honcho:8000` |
| **Qdrant** | 02 | **Document RAG** vectors (`ai-stack-docs` collection) | `http://qdrant:6333` |
| **FalkorDB** | 02 | Graph DB (Cypher) — reserved/dormant | `redis://falkordb:6379` |
| **MemPalace** | 26 | **Verbatim Claude Code conversation/session** recall; on-device ChromaDB + ONNX embeddings (no cloud, not via LiteLLM) | `bin/mempalace` (CLI + stdio MCP, no port) |
| **Lumen** | 16 | **Code semantic search** MCP (local jina-code embeddings) | `bin/lumen` (stdio, no port) |

> Honcho's Postgres is **shared** with LiteLLM's virtual-key Prisma DB — a single point of failure;
> if Honcho's DB goes down you get LiteLLM 503s on every key. (Self-heal check `05a_litellm_keystore`.)
>
> MemPalace's **embeddings** are on-device (no LiteLLM); its *optional* entity-refiner is an **LLM**
> call that *does* route through LiteLLM (`MEMPALACE_LITELLM_KEY`, visible in Phoenix) — an LLM call,
> not an embedding, so "no cloud embeddings" still holds.

**Your own operating memory as the owner** (distinct from the stack's memory services):
- `.remember/` — rolling session history (`now.md` buffer, `today-*.md`, `recent.md`, `archive.md`,
  `core-memories.md`). The next handoff is written to `.remember/remember.md`.
- `~/.claude/projects/<slug>/memory/MEMORY.md` — the durable, auto-loaded project memory index
  (one line per fact, body in a sibling file). **Write the durable residue of your work here**
  (additive is free; an overwrite/delete is a §5-class action). This is how lessons survive sessions.

---

## 7. The agent fleet

A **9-role engineering team** realized identically on three platforms (source of truth:
`agent-profiles/{hermes,pi,claude-code}/`, installed by **Phase 04h**):

`manager · techlead · frontend_engineer · backend_engineer · ml_engineer · qa_test_engineer ·
reviewing_engineer · sre_engineer · incident_manager`

- **Hermes** — the team inside the `hermes-fleet-v1` OpenShell sandbox (PyPI `hermes-agent`).
- **Pi** — the same roster as personas: `bin/pi-as <role>` (sandboxed coder, `pi-v1`).
- **Claude Code** — the **manager is the *main* session** (a clobber-safe `@`-import of
  `fleet/manager.md` in `~/.claude/CLAUDE.md`); the other 8 are subagents it dispatches. A Claude
  Code subagent can't dispatch subagents, so single-entrance orchestration requires the manager to
  be the main agent.
- **`team-protocol`** (a shared skill) is the keystone: definition-of-done, typed handoffs, the
  review-gate pipeline (INTAKE→DESIGN→IMPLEMENT→QA→REVIEW→MERGE→DEPLOY), escalation, turn budget,
  and the **§5 autonomy hard line**. The 7 shared skills are byte-identical across the 3 fleets —
  edit hermes then `cp` to pi + claude-code, and run `installer/lib/check_fleet_parity.sh`.
- Review/edit any persona/skill in one page: `vz-ai-stack.sh fleet-studio` (`doc/FLEET.html`).

### §24 — the review council (how "done" is earned here)

Any non-trivial **investigation, decision, plan, or code change** is reviewed by **≥3 independent
reviewer agents** you create in fresh contexts — **one adversarial, one domain-expert architect,
one QA/infra** — **plus a PM** when it's design/product. You orchestrate a debate to consensus,
then proceed and **report the decision + the debate points**. Floor for small/reversible work: ≥2
reviewers. Convening the council is autonomous (not permission-seeking). Reviewers truncate — verify
any flagged claim directly before acting on it.

---

## 8. Health & verification

- `doctor` runs **74 checks**, each a file in `installer/doctor/checks/` that appends to a global
  array (the count is **dynamic** — drop in a new check file and it's counted). Many checks
  **auto-heal** (idempotent, safe); opt-in extras' checks **skip-clean** when their phase isn't
  installed.
- Load-bearing checks to know: `05a_litellm_keystore` (Postgres self-heal — runs first),
  `40_models_binding`, `41_meridian`, `42/46 agent_fleet[_parity]`, `43_watchdog_alert`,
  **`53_container_liveness`** (census: *every* managed container exists + healthy — catches the
  "doctor-green-but-a-container-is-down" trap), `62_audit_drift`, `63_loopback_publish`,
  `64_hostname_alias_coverage`.
- **Doctor must not cold-start.** Routine `doctor` checks wiring/presence only; real inference is
  opt-in via `MODELS_BINDING_DEEP_CHECK=1` / `CODEX_BRIDGE_DEEP_CHECK=1`.
- **Verification ritual before "done"** (SOUL #5, `verification-gates` skill): run the actual
  command, paste the output, validate from the user's perspective, confirm the **full** `doctor` is
  green **from the MAIN checkout** (the stack breaks if operated from a worktree).

---

## 9. How to develop a feature (the recipe)

### Lifecycle (every change)

1. **Brainstorm** the approach (the `brainstorming` skill) — don't jump to code on non-trivial work.
2. **Create a worktree** (SOUL #25) — *before* the first edit.
3. **Implement** against existing conventions (read a neighbour first — SOUL #13).
4. **Self-verify**: run the phase's smoke test + the relevant `doctor` checks.
5. **§24 council review** (≥3 reviewers + PM for product) → debate → consensus.
6. **Merge to main**, then **operate/verify the live stack from MAIN** end-to-end.
7. **Push**, update **CHANGELOG.md**, sweep docs, write a **memory** note.

### Recipe: add a new containerized service (the files, in order)

1. **`installer/phases/NN_name.sh`** — copy the skeleton from a recent neighbour
   (`30_understand.sh`, `35_chatdev.sh`):
   ```bash
   set -Eeuo pipefail
   AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
   source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
   PHASE=NN; NAME=svcname
   precheck(){ container_running "$NAME" && curl -sf http://svcname:PORT/health >/dev/null; }
   precheck 2>/dev/null && stamp_check "$PHASE" && { ok "already installed"; exit 0; }
   worktree_guard "install svcname"          # REFUSES from a worktree
   hdr "Phase NN — Svc"
   # 1) idempotent fetch/build  2) mint scoped LiteLLM key (litellm_master_curl → /key/generate;
   #    set_env <KEY>; litellm_reconcile_key <KEY> model…)  3) start via bin/start-svcname.sh
   stamp_mark "$PHASE"; ok "Phase NN complete."
   ```
2. **`services.yml`** — add an entry (schema below). Set `phase: "NN"`.
3. **`bin/start-<svcname>.sh`** (and `stop-…`) — the source-of-truth launcher (fixed flag order).
4. **`installer/doctor/checks/NN_name.sh`** — add a check (`doctor.sh` auto-discovers + sources
   every file in this dir, so the count bumps itself — copy a neighbour's registration convention exactly):
   ```bash
   CHECKS+=(svcname); CHECK_TITLE[svcname]="Svc reachable + healthy"
   svcname_diagnose(){ curl -sf http://svcname:PORT/health >/dev/null || { echo down; return 1; }; }
   svcname_fix(){ worktree_guard_soft "repair svcname" || return 1; bash "$AI_STACK/bin/start-svcname.sh"; }
   AUTOHEAL[svcname]=1   # only if the fix is safe + idempotent
   ```
5. **`installer/smoke/NN.sh`** — end-to-end probe (host alias **and** in-network Docker DNS):
   `verify_container_reachable_by_alias svcname svcname PORT /health`.
6. **`installer/lib/aliases.tsv`** — one row per endpoint:
   `svcname  127.0.10.X  http  HOSTPORT  CONTPORT  NN  svcname` (a service has a hostname **iff**
   it's in this TSV).
7. **Core vs opt-in** — leave it out of `install_all_phase_order()` to ship opt-in (recommended for
   new things); add the ID to make it core. (Deciding whether to *install* an existing opt-in:
   `help <svc>` and `doc/EXPLORE.html` say what each is and when you'd want it.)
8. **Doc sweep (same change):** README "what's in the box" + count, `doc/EXPLORE.html` card (+ its
   hardcoded core count if core), `doc/TUTORIAL.md` (→ regen `.html` via `build_tutorial_html.py`),
   `doc/ATTRIBUTION.md` (license/ToS), `CHANGELOG.md`. The `tutorial`/`audit_drift`/
   `hostname_alias_coverage` doctor checks will fail if you skip the relevant sweep.

### Definition of done (a feature isn't done until ALL hold)

- [ ] Smallest safe diff, matching existing conventions.
- [ ] Its smoke test + the relevant `doctor` checks pass — **output pasted, not assumed** (SOUL #5).
- [ ] §24 council reviewed → consensus (verify any flagged claim yourself — reviewers can misread).
- [ ] Merged to main; the **full** `doctor` is green run **from the main checkout**; verified
      end-to-end from the real user's view (browser/CLI), not a green log.
- [ ] Pushed; `CHANGELOG.md` updated; docs swept (counts/lists/EXPLORE/TUTORIAL→regen) in the same change.
- [ ] A memory note captures any non-obvious lesson.

### Service entry schema (`services.yml`, v2)

| Field | When | Notes |
|---|---|---|
| `enabled` | always | `true`/`false`; `stack enable/disable` toggles it |
| `type` | always | `docker` · `compose`/`docker-compose` · `cli-only` · `python-bg`/`node-bg` · `brew-service` · `openshell` · `hermes-profiles` · `litellm-feature` · `litellm-virtual-key` · `agent-pattern` (lifecycle class) |
| `desc` | always | one-line help |
| `image` | docker | image URI |
| `alias` / `host_ip` / `host_port` / `container_port` | networked | `127.0.10.x` for containers, `127.0.0.1` for host daemons; `host_port == container_port` (the OrbStack `*:80` rule) |
| `network` | always | `ai-stack` · `host` · `openshell` · `none` |
| `ports` / `extra_aliases` / `add_host` | optional | multi-port / multi-endpoint / extra `--add-host` |
| `path` / `project` | compose/cli | clone dir / docker-compose project override (kebab-case) |
| `process_pattern` | python-bg/node-bg | `pgrep` pattern for liveness |
| `phase` | always | phase ID (install order + opt-in status) |
| `open_url` / `consumes_env` / `depends_on` | optional | browser target / `.env` vars read / ordering hint |
| `help:` | always | nested `what:` / `why:` / `usage:` / `config_notes:` (drives `help <svc>`) |

> **Worktree guard recap** (`installer/lib/worktree.sh`): refuses `install`/`start`/`doctor --fix`
> (auto-heal)/`docker compose` from a worktree because containers bind-mount live paths;
> `git worktree remove` would then yank the mount out from under a running container. Read-only
> commands (`status`, `--dry-run`, `help`, `phases`) are allowed.

---

## 10. Key architectural decisions & why (the durable "why")

1. **Single LiteLLM egress** — one place for keys, guardrails, per-agent virtual keys, and free
   OTLP tracing. No second door. (`phases/01_inference.sh`, `bin/start-litellm.sh`)
2. **Per-service scoped virtual keys over a derived superset** — re-assign models without re-minting;
   doctor 40 guards drift. (`installer/lib/models.sh`)
3. **One idempotent entrypoint + stamp/precheck** — phases re-verify real state; stamps are cache.
4. **Local-first, no cloud embeddings** — embeddings/retrieval never leave the box by default.
5. **Four+ distinct memory niches** — Honcho (derived facts) / Qdrant (doc RAG) / MemPalace
   (verbatim sessions) / Lumen (code) / FalkorDB (graph). Not one "memory."
6. **FIXED docker flag order** — mixing leaks flags to entrypoints.
7. **Atomic `.env` writes** — awk→tmp→`mv`; readers never see a half-write; secrets stay 0600.
8. **Host-native bare-hostname ingress via loopback aliasing** — `127.0.10.x` + `/etc/hosts` + lo0
   + launchd; not LAN-exposed (127/8 is host-only).
9. **Local-first (Ollama default + opt-in LM Studio MLX) + Claude-subscription via Meridian +
   openai-compat** — sensible default (`local`), opt-in heavy MLX, subscription for quality,
   declarative cloud routes; always availability-gated to the local fallback.
10. **9-role fleet, manager-as-main-agent** — single entrance; the other 8 are dispatched subagents;
    identical roster on Hermes/Pi/Claude Code.
11. **OpenShell deny-by-default sandboxes** — Pi/Hermes isolated; egress allowlisted.
12. **Conservative restart queueing** — config-mutating phases queue recreates; you run
    `apply-restarts` (no silent in-flight mutation).
13. **OrbStack `*:80` collision is permanent** — investigated + reverted; stay on native ports.
14. **§24 council, outcomes recorded in CHANGELOG** — decisions don't become tribal knowledge.

---

## 11. Quirks & gotchas that bite (and the one-line fix)

- **LiteLLM cold-start hang / `P1010`** — container Up, `:5432` reachable, `/v1/models` times out:
  the role lacks `CREATE` on `public` (PG15+/wolfi). Fix is in `bin/start-litellm.sh` (ALTER OWNER
  + GRANTs + a rolled-back CREATE probe); re-run `install 01` or `--recreate`.
- **Phoenix OTLP 401** — empty `PHOENIX_API_KEY` → silent 401 on every trace; "Waiting for
  traces…" forever. Create a Phoenix key, put it in `.env`, `apply-restarts`.
- **`docker restart` doesn't reload env/config** — use `bin/start-<svc>.sh --recreate`.
- **OrbStack bind-mount snapshot lag** — a running container holds a snapshot of host→container
  mounts; read from inside (`docker exec … tail`) or recreate to pick up host writes.
- **OpenShell token-storm** — sandbox says `Phase: Ready` but the exec relay is dead at ~0.2% CPU;
  only **recreating** mints a fresh token. Detected by log-signature; heal with `install 04 04f` /
  `install 15`. The launchd watchdog is **warn-only** by default (it once auto-deleted both
  sandboxes — never again).
- **OpenShell CLI/gateway version skew** — a uv-installed `openshell` on PATH shadows the brew
  binary the gateway matches → `phase: Unspecified` on a healthy sandbox. Phases resolve `$OSH`
  (brew) explicitly.
- **`/etc/hosts` / lo0 aliases lost after VPN or `brew services restart`** — re-run
  `sudo prepare-sudo` + `verify`; `brew services restart ollama` also wipes `OLLAMA_HOST=0.0.0.0`.
- **`model sync` is opt-in** — `install all` doesn't run it; new models aren't key-allowed (doctor
  40 RED) until you do.
- **Meridian down → the fleet silently answers on `local`** (availability-gating, by design —
  not an error). If a Claude-sub agent seems "dumber," check Meridian (`:3456`) / doctor check 41,
  not the agent. `model list` shows the intended binding.
- **Honcho's Postgres is shared with LiteLLM's key DB → a single point of failure.** If that
  Postgres is down, **every** LiteLLM virtual key 503s (not just Honcho). Check `05a_litellm_keystore`
  (self-heals the common cases) before chasing per-agent key bugs.
- **24 GB RAM ceiling** — the local model is small (`nemotron-3-nano:4b`, ~2.8 GB); no heavy 27B local model exists any more. Quit LM Studio when
  idle (~1 core even stopped).
- **New provider key** → add to `start-litellm.sh` `-e` allowlist **and** `--recreate` (not
  `restart`); detect config dups with `yq '.model_list[].model_name'`, not `grep`.
- **`litellm/config.yaml` comment-strip drift** — `model sync` re-renders it and strips curated
  comments, dirtying this tracked file; `git restore` after test syncs.
- **`bin/lumen` auto-rewrites its path on worktree entry** — never commit that change.

(The full known-flaky catalog with recovery dances is [`HANDOFF.md` §2](HANDOFF.md);
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) / [`DOCTOR.md`](DOCTOR.md) are the operator references.)

---

## 12. Repo map (where to look)

```
~/ai-stack/
├── vz-ai-stack.sh          # THE entry point (bash-5 gate + subcommand dispatch)
├── services.yml            # 51 services + profiles (source of truth)
├── README.md · CHANGELOG.md
├── bin/                    # stack, start-/stop-<svc>.sh, pi, lumen, mempalace, ingress, audit.sh …
├── installer/
│   ├── lib/*.sh            # sourced helpers (common, env, docker, network, litellm, models, worktree, …)
│   ├── phases/NN_*.sh      # one per phase (00–36 + subphases)
│   ├── doctor/checks/      # one file per failure mode (66)
│   ├── smoke/              # per-phase E2E smoke
│   ├── models.yml          # model↔agent binding
│   └── state/              # .done stamps, restart queue, locks, logs
├── doc/                    # all docs incl. doc/SOUL.md (25-rule constitution — read first), ARCHITECTURE, STACK-GUIDE, models.md, this file, …
├── fleet/ · agent-profiles/# the 9-role fleet (manager.md = canonical; profiles per platform)
├── litellm/                # config.yaml, trace_to_file.py, guardrails.py
├── data/                   # persistent volumes (phoenix/falkor/qdrant/honcho/openwebui)
├── traces/                 # litellm.jsonl + guardrails.jsonl
├── ingestor/{inbox,processed}   # drop docs here to ingest into the RAG
└── <service clones>        # honcho/ deer-flow/ autofyn/ hermes-workspace/ metagpt/ … (cloned upstreams)
```

---

## 13. Licensing / ToS watch-list

Most of the stack is permissive (MIT/Apache/ISC). **Be careful with the non-permissive / gray
ones** before relying on them commercially or redistributing — and treat **[`ATTRIBUTION.md`](ATTRIBUTION.md)
as authoritative** (verify there, don't trust this summary):

- **OrbStack** — proprietary freemium (business use needs a paid license).
- **Arize Phoenix** — Elastic-2.0 (self-host OK; no resale-as-service).
- **FalkorDB** — SSPL-1.0 (service-resale triggers source disclosure).
- **Honcho**, **Unsloth UI** — AGPL-3.0 (network copyleft).
- **Open WebUI** — custom (branding-removal limits above a user threshold).
- **Blaxel** — proprietary SaaS. **Telegram Bot** — platform ToS.
- **Codex/GPT-via-ChatGPT-sub bridge** — ToS-gray; opt-in; activation is the operator's
  `codex login` (a §5 action).
- Model weights have their own terms (e.g. Gemma's custom use policy) — check each model card.

---

## 14. First-week checklist (become productive)

- [ ] Read `SOUL.md` (cite 3 rules from memory), this doc, and `README.md` (~1–2 h of real focus,
      not a skim — the mental model is the point).
- [ ] `cd ~/ai-stack && stack status && stack doctor && stack phases && stack model list` — read
      all output; find one thing a doc got wrong (it drifts).
- [ ] Do the 5-minute wow: chat in Open WebUI (`:8080`) on `local`, watch the trace in
      Phoenix (`:6006`).
- [ ] Open one phase (`installer/phases/35_chatdev.sh`) + its doctor check + smoke test — trace the
      conventions end-to-end.
- [ ] Read `ARCHITECTURE.md` (idempotency/lock/flag-order) and skim `CHANGELOG.md` top.
- [ ] Make a *trivial, reversible* change in a **worktree** (e.g. fix a help string), run its smoke
      + doctor, run a §24 mini-council, merge from main, verify, push — to exercise the full
      lifecycle once before anything real.
- [ ] Write a memory note (`MEMORY.md` pointer + a sibling file) capturing what surprised you.

---

## 15. The doc ecosystem (read on demand)

| Need | Doc |
|---|---|
| Use it after install | [`ONBOARDING.md`](ONBOARDING.md) · [`USER-GUIDE.md`](USER-GUIDE.md) |
| Service-by-service tour | [`STACK-GUIDE.md`](STACK-GUIDE.md) · [`COMPONENTS.md`](COMPONENTS.md) · `EXPLORE.html` |
| Installer internals / design | [`ARCHITECTURE.md`](ARCHITECTURE.md) |
| Model binding | [`models.md`](models.md) · `MODELS.html` (`models-serve`) |
| Topology / ports | [`DEPENDENCIES.md`](DEPENDENCIES.md) · [`PORTS.md`](PORTS.md) · [`DIAGRAMS.md`](DIAGRAMS.md) |
| Day-to-day ops | [`OPERATIONS.md`](OPERATIONS.md) |
| Something broke | [`DOCTOR.md`](DOCTOR.md) → [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) |
| Continue an in-flight session | [`HANDOFF.md`](HANDOFF.md) |
| Licensing | [`ATTRIBUTION.md`](ATTRIBUTION.md) |
| Hands-on tutorial | [`TUTORIAL.md`](TUTORIAL.md) (`tutorial-serve`) · [`SERVICE-PLAYGROUND.md`](SERVICE-PLAYGROUND.md) · [`HERMES-HANDSON.md`](HERMES-HANDSON.md) |
| The constitution | [`SOUL.md`](SOUL.md) · the fleet/manager persona in `fleet/manager.md` |

---

## Appendix A — the activation prompt

The copy-paste activation prompt now lives in one paste-ready, version-controlled file:
**[`doc/ONBOARDING-PROMPT.md`](ONBOARDING-PROMPT.md)**. Open it, copy everything below its `---`,
and paste it as the new agent's first message (a fresh Claude Code session in `~/ai-stack`, or any
capable coding agent — it self-onboards using this doc). It's kept in a single file to prevent the
drift two copies would cause; this appendix used to inline it.

---

## Appendix B — glossary

- **Phase** — one `installer/phases/NN_*.sh` install step (idempotent, stamped).
- **Core vs opt-in** — core runs in `install all` (it's in `install_all_phase_order()`); opt-in
  installs by name or via `--include-optionals`.
- **Scoped / virtual key** — a per-agent LiteLLM key allowlisted to a subset of models.
- **Superset** — the derived union of model ids a scoped key is widened to (so re-assigning a model
  doesn't require re-minting). `model sync` re-widens it.
- **Availability-gating** — an agent falls back to `local` when its assigned runtime
  (Meridian/LM Studio) is down.
- **Worktree guard** — `installer/lib/worktree.sh`; refuses stack-operating commands from a git
  worktree.
- **The census** — doctor check 53: every managed container exists + is healthy (defeats
  doctor-green-but-down).
- **§5 / autonomy hard line** — actions that always need explicit human approval (destructive/
  irreversible, credential/permission changes, secret exposure, external publish, messaging a real
  person).
- **§24 council** — the ≥3-reviewer + debate-to-consensus gate before "done".
- **Meridian** — the host daemon that bridges the Claude subscription into LiteLLM.

---

*Snapshot verified 2026-06-25 against the live repo. Counts are dynamic — always re-derive with the
commands above. If you change the platform, update this doc in the same change (SOUL #8, #18).*
