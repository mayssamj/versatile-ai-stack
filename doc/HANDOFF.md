# Handoff — for the next agent

If you're a Claude (or human) picking this up cold, read this **first**. It
gets you to "I know what's done, what's known-flaky, and what to do next"
in fifteen minutes.

---

## ✅ SHIPPED (2026-06-17): SOUL → 25-rule constitution + doc-sync

`doc/SOUL.md` is the canonical constitution and now has **25 rules** (was 24). Added **Rule 25** (Git worktrees — guard a repo/workspace from colliding edits by parallel agents on different branches) and clarified **Rule 24.1** ("convening your council (24.2–24.4) is an autonomous act, not permission-seeking" — resolves the apparent 24.1↔24.2 tension: autonomy = no human-permission for reversible work; the 3-agent council is the internal method; both always apply). Also fixed pre-existing defects: Rule 21 was mislabeled "2.", Rule 22 cadence unified to 5 min, Rule 24.3 reviewer count 2→3 + a stray comma, Rule 20 "Internalize". Each change went through a §24.2 council (audit → propose → 3-reviewer consensus + debate).

Propagated the 24→25 count to the **canonical sources** — `agent-profiles/SOUL-SUPERSET.md`, `agent-profiles/hermes/profiles/manager/SOUL.md`, `doc/specs/2026-06-11-manager-second-brain.md` — plus the two project-memory files. **NEXT STEP (user's):** the derived `pi/` + `claude-code/` + installed `~/.claude/` copies (incl. `~/.claude/fleet/manager.md`) still read "24 rules" until you run `bash vz-ai-stack.sh install 04h` (every-session ~/.claude blast radius = the user's step). See CHANGELOG 2026-06-17.

---

## ✅ SHIPPED (2026-06-07): service run/lifecycle cohesion

Design + plan + interface contract + doc-sweep contract: `doc/specs/2026-06-07-service-run-cohesion*.md`.
Built by orchestrated multi-agent run (4 parallel code workstreams → GATE 1 live-verify → 2 adversarial
reviews + 3-way debate → GATE 2 → 5 parallel doc agents → 2 doc audits → full doctor). See CHANGELOG
2026-06-07 for the full entry.

**What changed (user-facing):**
- **`vz-ai-stack.sh start <svc>`** is the one way to run anything; **`run <svc>`** is a pure alias
  (also `enable`/`disable`, and reverse-form `<svc> start|run|stop`). It prints a uniform `URL:`
  (UIs) / `Endpoint:` (APIs) + `Stop:` line and **auto-opens UI services in the browser** — gated:
  skipped on headless/no-TTY, `NO_BROWSER`/`CI`, or `--no-open`; `--open` forces; URL always printed.
  Idempotent. Non-daemon types print an honest categorical message (never "no start script").
- **`start claw3d`** = health-gated composite (bridge → `/health` → UI :4310 → browser); `stop claw3d`
  stops both. **`start lmstudio`** / **`stop lmstudio`** manage the LM Studio server (`LMS_AUTOSTART`/
  `lms server start` are no longer the run path). `install claw3d`/`install lmstudio` remain SETUP.
- **`stop <svc>`** now works for every startable service (docker / brew / PID-file host-process /
  compose), incl. new `stop-claw3d|paperclip|honcho|autofyn|hermes_workspace|lmstudio.sh`. The
  PID-file stop verifies ownership before killing (recycled-PID safety).
- Deprecated models retired in all docs: `local-lfm2` (LFM2.5 GGUF) + `local-heavy` (Ollama
  qwen3.6:27b) — runnable examples use `local-gemma4`; heavy model is `local-qwen3.6` (LM Studio,
  opt-in). The code-asserted `LEGACY_SUPERSET` slugs (doctor 40) are kept on purpose.

**Locked decisions (honored):** (1) start-when-not-set-up = prompt-then-auto-setup interactively /
fail-with-exact-command in CI; (2) claw3d stays provisioned by `install all` (doctor 32 unchanged).

**Known minors (not bugs, documented):** a 2nd `start` of a compose UI service (autofyn/
hermes_workspace) may re-open the browser; `start claw3d_bridge` (underscore) is an edge name — use
`start claw3d` (or `start claw3d-bridge`, hyphen). doctor count unchanged at **46**; services **41**.

### Follow-ups (2026-06-07, later same day) — `doctor` back to 46/46 + full doc cohesion

1. **Start-regression fixed** (commit `82411ae`): the `cmd_start` docker-idempotency short-circuit
   skipped the start script when a `type:docker` container was already running, bypassing pre-flight
   side-effects incl. `start-litellm.sh`'s P1010 grant-probe. Now `cmd_start` ALWAYS runs the script
   and maps the benign "already exists + running" exit to idempotent success.
2. **Ollama runtime restored** (host/upstream, not the change): the Homebrew `ollama` 0.30.6 FORMULA
   bottle ships **no `llama-server`** (GGUF chat → HTTP 500); fixed by installing the official
   `ollama-darwin` runner set into `Cellar/.../libexec/lib/ollama`. Also: `brew services restart`
   regenerates the plist and wipes the `OLLAMA_HOST=0.0.0.0` env-patch → `deps.sh` now boots the
   edited plist via `launchctl bootout/bootstrap`. See memory `project_ollama_runner_gotcha`. ⚠ The
   runner workaround is overwritten by a future `brew upgrade/reinstall ollama` — re-apply if GGUF
   chat 500s again (`llama-server binary not found`).
3. **Full doc cohesion sweep** (this commit): a model-assignment drift predating the change
   (commit `6157e59` moved ALL agents to Claude **Opus** subscription — manager/qa/sre/incident →
   `sub-xhigh`, techlead/ml/frontend/backend/reviewing → `sub-max`, pi/deerflow → `sub-max`,
   ace/rlm → `sub-xhigh`) was never propagated to docs. Fixed across models.md, USER-GUIDE(.md/.html),
   OPERATIONS, TROUBLESHOOTING, DIAGRAMS(.md/.html), STACK-GUIDE, EXPLORE.html, TUTORIAL(.md→regen),
   `bin/pi-as` comment, `models.yml` comment. NOTE: `agent-profiles/*/README.md` keep "(Sonnet)" for
   junior roles **on purpose** — that reflects the **claude-code subagents** (`~/.claude/agents`,
   verified backend/frontend/qa = sonnet), which are a SEPARATE binding from the all-Opus
   models.yml fleet. `models.yml` is the authoritative source for hermes/pi/deerflow/ace/rlm.

4. **Install populates `.env` first** (this commit): `cmd_install` now runs `env_ensure_baseline`
   + the first-run `setup_maybe_offer` (skippable API-key prompt) as the FIRST step for BOTH
   `install all` AND a standalone `install <phase>` (was `install all`-only). `--dry-run` unaffected;
   CI/non-TTY never blocks; local/-sub still need zero keys. 2 reviews + debate; `setup_maybe_offer`
   now `mkdir -p`s its stamp dir.

**State: `vz-ai-stack.sh doctor` = 46/46, 0 failed** (verified live, incl. a real `local-gemma4` chat).

---

## 0. Snapshot — state as of 2026-06-05

| Property | Value |
|---|---|
| Host | Mayssam Sayyadian's MacBook Pro M4 24 GB, macOS Sequoia, OrbStack docker, Homebrew, Python 3.13+, brew bash 5.x |
| Stack root | `~/ai-stack/` (= `/Users/mayssam.sayyadian/ai-stack/`) |
| Entry point | **`bash vz-ai-stack.sh`** (renamed from `install.sh` on 2026-06-02 — project-wide sweep, commit `a796e2e`). The `bin/stack` wrapper takes the same args (`stack status`, `stack doctor`, …). |
| Total phases | **29 core + 9 opt-in extras** = 38 phase files. Core (in `install all`): 00, 00s, 00n, 00v, 01, 01h, 02, 03, 04, 04f, 04g, **04h**, 05, 06, 07, 08, 09, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, **26**. **04h `agent_fleet`** (NEW 2026-06-02) installs the cross-platform agent fleet; **26 `mempalace`** (local-first conversation memory; joined `install all` 2026-06-20) is appended LAST as a zero-dependency leaf. Opt-in (install by name, NOT in `install all`): 21 portless, 22 cmux, 23 skillspector, 24 openagents, 25 lmstudio, **27 sourcegraph**, 28 aionui, **29 openwork**, 30 understand. |
| Default phase order (`install all`) | `00 00s 00n 00v 02 03 01 01h 04 04f 04g 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 04h 26` (note: 03 before 01 — see §3.1; 04h after its deps — uploads to pi-v1 (15) + widens the PI/HERMES keys; 26 mempalace appended LAST — zero-dependency leaf, fail-isolated) |
| Total services in `services.yml` | **43** |
| Total doctor checks | **55** (`litellm_keystore` #05a (AUTOHEAL — Postgres self-heal; runs before the per-phase key checks), `hermes_routing` #30, `rlm` #31, `claw3d` #32, `hermes_telegram` #33, opt-in extras #34–38, `openshell_storm` #39, `models_binding` #40, **`meridian` #41**, **`agent_fleet` #42**, `watchdog_alert` #43, **`mempalace` #44** (Phase 26, green-skips only if not yet run), **`tutorial` #45** (ALWAYS-ON — validates `doc/TUTORIAL.html` via `build_tutorial_html.py --check`: self-contained, link-clean, in sync with the `.md`), **`agent_fleet_parity` #46** (ALWAYS-ON — wraps `check_fleet_parity.sh`: 7 skills + Tier-1 + role bodies identical ×3), **`docker_engine_consistency` #47** (no split-brain across ambient CLI / gateway.env / managed containers), **`docker_engine_selection` #48** (`AI_STACK_DOCKER_ENGINE` present + valid + installed), **`sourcegraph_mcp` #49** (opt-in Phase 27, skip-clean when Sourcegraph not installed), **`aionui` #50** (opt-in Phase 28, skip-clean when AionUi not installed), **`openwork` #51** (opt-in Phase 29, skip-clean when OpenWork not installed), **`understand` #52** (opt-in Phase 30, skip-clean when no knowledge graph committed), **`container_liveness` #53** (ALWAYS-ON — census: every managed container EXISTS + running & healthy), **`openshell_gateway` #54** (ALWAYS-ON — gateway up on :17670 + brew-manageable; reds on an untrusted nvidia/openshell tap)) |
| Model↔agent binding | `installer/models.yml` is the single source of truth. **3 local models** (`local-gemma4` Ollama default, `local-qwen3.6` + `local-qwen3-coder` LM Studio MLX, opt-in) **+ the Claude SUBSCRIPTION effort-ladder** via the Meridian host daemon: `claude-opus-4.8-sub-{low,medium,high,xhigh,max,ultracode}` + `claude-sonnet-4.6-sub-{low,medium,high,max,ultracode}` (runtime `meridian`, availability-gated to `local-gemma4` when Meridian is down; `ultracode` = the coding-focused highest effort tier). The 9-role Hermes fleet + Pi are assigned subscription models. `vz-ai-stack.sh model {list,assign,sync,superset,discover,add}` renders agents + the LiteLLM model_list. `model sync` is opt-in (NOT run by `install all`). See [models.md](models.md). |
| Docs + ingestion layout | All docs under `doc/` (except `README.md` + `CHANGELOG.md` at repo root). Ingestion drop dirs are `ingestor/inbox` + `ingestor/processed`. NEW: `doc/TUTORIAL.md` + `doc/TUTORIAL.html` (hands-on tutorial). |
| Last verified doctor pass | **2026-06-21: `doctor` = 54/55** on the live stack — the new **54th = `openshell_gateway`** reds until `brew trust nvidia/openshell` (DOCTOR.md §54); 44th check = `mempalace`, green-skips when not installed; **45th = `tutorial`**, always-on — validates `doc/TUTORIAL.html` is self-contained, link-clean & in sync with the `.md` via `installer/lib/build_tutorial_html.py --check`; **46th = `agent_fleet_parity`**, always-on — wraps `check_fleet_parity.sh`). ⚠️ If the sandbox-exec checks (24/25 pi-v1, 30/33 hermes, 40 models_binding) fail, the **sandboxes have dropped** — see §2.1. (Root-caused 2026-06-03: the openshell-watchdog's old auto-recreate DESTROYED both sandboxes; now **warn-only by default** + doctor check **43 `watchdog_alert`** surfaces it. Recreate with `vz-ai-stack.sh install 04 04f 15 20 04h`.) The `help` command (below) is **doctor-independent**; `help --check` is its own CI lint, not wired into doctor. |
| Last verified cold install | **2026-06-02: `reset --confirm hard --yes` → `install all` → `doctor` 43/43** green, end-to-end (incl. the 9-role fleet rebuilt to exactly 9 profiles + a live subscription chat). See CHANGELOG / commit `6971198`. (MemPalace check #44 is opt-in and green-skips, so `install all` now passes 54/55 — the new check 54 `openshell_gateway` reds until the nvidia/openshell tap is trusted via `brew trust nvidia/openshell`.) |
| NEW since last handoff | **First-run onboarding + cold-start hardening** (2026-06-04→05) — see §1 CLI list + §3.-1. New verbs: **`setup`/`keys`** (interactive, skippable .env/API-key bootstrap; `4f67e43`, `f142da4`), **`deps [--check]`** (host-dependency bootstrap; `19d8464`), **`install --dry-run`/`--plan`** (read-only preview; `e472386`), **per-command help** (`<cmd> --help` / `help <cmd>`; `df371a3`). **LiteLLM cold-start self-heal + P1010 DB-grant fix** (`89778b9`, `ad01a9f`, `1e18dfa`, `652c447`). **MemPalace Phase 26** + doctor check 44 (`b2f4f4b`). **Tutorial doctor check 45** (`8a4768d`). Canonical first-run order is now **deps → setup → prepare-sudo → install all → doctor**. **2026-06-06 batch:** `start`/`stop` now manage brew services (`stop ollama`/`stop openshell` work — with blast-radius/gateway-only warnings); **`model assign all <model>`** blanket-assigns every agent (before→after table + `models.yml.bak` backup + atomic write); **Phase 25 (LM Studio) is assignment-driven** — loads only models.yml-assigned MLX, the LFM2.5 demo is opt-in via `LMS_LOAD_LFM2=1`; `docs/` folder consolidated into `doc/`. |

**Constitutional rules** (Mayssam's repeated explicit asks):
1. **Autonomous execution.** Diagnose → fix in code → update installer → sweep docs → verify → THEN report. Don't hand back a recipe.
2. **No copy-paste docker commands.** Start scripts are source of truth.
3. **No cloud embeddings.** All embeddings local (nomic-embed-text, jina-embeddings).
4. **Per-service env injection** for LiteLLM (not `--env-file` blanket).
5. **Guardrails must fail-CLOSED** on internal errors.
6. **`.env` mode 0600 always.** Never echo secret values to stdout/logs.
7. **`/etc/hosts` root:wheel mode 644.** Doctor check 22 enforces.
8. **Never leave zombie background tasks.** The user has complained ≥3 times. Foreground anything under 60s; if you must bg, kill on completion.
9. **OrbStack `*:80` collision is permanent.** Don't try port-free aliases (`http://litellm/`) — it was investigated 2026-05-28 and reverted. Stay on `http://litellm:4000`.

> **Two methodology layers (don't fork them).** These C1–C9 are the **ai-stack-specific** rules for the Claude Code *main* agent operating on this repo. The **generic, portable engineering methodology** (verify-don't-assume, hypothesis-first, E2E verification, reversibility, multi-agent contract, runtime invariants, reporting) lives in the fleet's **shared skills** (`agent-profiles/*/skills/`: `team-protocol` keystone + `verification-gates` · `hypothesis-debugging` · `reversible-changes` · `tdd` · `brainstorming`) and the shared **Ethos** (team-protocol §Ethos + a couplet in every soul's "Operating discipline" block). The 7 skills are byte-identical across the 3 fleets (the 6 shared above + `memory-management`, the manager-only second-brain protocol); **edit hermes then `cp` to pi + claude-code**, and run `bash installer/lib/check_fleet_parity.sh` (a lint, not a doctor check) to assert parity. (See `doc/specs/2026-06-08-operator-manager-ethos.md`.)

**Memory pointers** (auto-loaded in this user's Claude sessions, see `~/.claude/projects/-Users-mayssam-sayyadian-ai-stack/memory/MEMORY.md`):
- `feedback_autonomous_execution.md`, `feedback_background_tasks.md`, `feedback_upgrade_fleet_prefs.md`
- `project_doctor_count.md` (now **50** checks — update if you add checks)
- `project_model_strategy.md` (3 local + Claude subscription via Meridian; the `-sub-*` effort ladder)
- `project_agent_fleet.md` (the 9-role team across Hermes/Pi/Claude Code; phase 04h)
- `project_tutorial.md` (doc/TUTORIAL.md+.html + the `tutorial-serve` ephemeral-key proxy)
- `project_pi_phase15.md`, `project_cpu_gotchas.md`, `project_ollama_memory.md`

---

## 1. What's working (verified live)

### Inference + observability
- **LiteLLM** (`http://litellm:4000`) — virtual-key gateway, Postgres-backed key store, Phoenix OTLP export, custom JSONL trace logger, in-built guardrails (denied-words + secrets regex). On `ai-stack` docker network.
- **Phoenix** (`http://phoenix:6006`) — observability UI + OTLP collector. Project `ai-stack` for all traces.
- **Ollama** — host brew service. Eager-pulled models (Phase 01 `REQUIRED_MODELS`, lazy policy 2026-05-31): `gemma4:e4b` (=`local-gemma4`, default) + `nomic-embed-text` only. The heavy/coder models moved to LM Studio MLX (`local-qwen3.6`, `local-qwen3-coder`, ~17 GB each, opt-in); the legacy Ollama `qwen3.6:27b` (`local-heavy`) and LFM2.5 GGUF are **no longer auto-pulled**. `OLLAMA_KEEP_ALIVE=30m` (set in Phase 00) keeps the default model warm for 30 min of inactivity, then releases it.

### Storage
- **FalkorDB** (`redis://falkordb:6379`, browser `http://falkordb-ui:3000`) — graph DB on Redis protocol.
- **Qdrant** (`http://qdrant:6333`) — vector DB.
- **Honcho** (`http://honcho:8000`) — memory store. Brings up its own Postgres (`honcho-database-1` on `host.docker.internal:5432`) which LiteLLM ALSO uses for the virtual-key Prisma DB (DATABASE_URL=`postgresql://postgres:postgres@host.docker.internal:5432/litellm`).

### Agent runtimes
- **OpenShell** (brew service, gateway `:17670`) — sandbox host. Two sandboxes:
  - **hermes-fleet-v1** — the 9-role Hermes engineering team (manager, techlead, frontend_engineer, backend_engineer, ml_engineer, qa_test_engineer, reviewing_engineer, sre_engineer, incident_manager), running a spec→deploy pipeline under the shared team-protocol skill; all nine route to a Claude subscription via Meridian (gated to local-gemma4 when Meridian is down). Installed via PyPI `hermes-agent` v0.15.2 inside `/sandbox/.venv` (uv-managed venv inside the sandbox).
  - **pi-v1** — Pi (`@earendil-works/pi-coding-agent`). Auth via `PI_LITELLM_KEY` virtual key. Pi is now assigned a **Claude subscription** model in `models.yml` (`claude-opus-4.8-sub-max`), availability-gated by Phase 15 to `local-gemma4` when Meridian (and LM Studio) are down. **Phase 04h widens `PI_LITELLM_KEY`** to the full superset (legacy + all models.yml ids incl. `claude-*-sub-*`) so the subscription models are reachable. The 9 fleet personas are uploaded to `/sandbox/agents/<role>/SYSTEM.md`; switch with `bin/pi-as <role>`. (Plain `bin/pi` for a generic session.)

### UIs
- **Open WebUI** (`http://openwebui:8080`) — chat UI in front of LiteLLM.
- **Hermes Workspace** (compose stack at `~/ai-stack/hermes-workspace`, `http://workspace:3000`) — Nous Research's chat workspace.

### Background services
- **docs-mcp** (host python daemon, `:8765`) — Docling+LlamaIndex+Qdrant MCP server. PID file at `installer/state/docs_mcp.pid`. Embeddings via local nomic-embed-text (never cloud).
- **Paperclip** (host node daemon, `:3100`) — alt screenshot agent. Started by `bin/start-paperclip.sh`.
- **AutoFyn** (compose stack at `~/ai-stack/autofyn`, gateway `:3400`) — agent framework.
- **DeerFlow** (compose stack at `~/ai-stack/deer-flow`, nginx at `http://localhost:2026`) — multi-step research agent. **Phase 10 idempotently patches its `config.yaml` + `docker-compose.yaml` + `.env`** to point at `host.docker.internal:4000` for LiteLLM with `LITELLM_MASTER_KEY` passthrough.

### CLI-only / on-demand
- **Pi** — invoke via `bin/pi` (handles sandbox session inside pi-v1).
- **Hermes** — invoke inside hermes-fleet-v1: `openshell sandbox exec -n hermes-fleet-v1 -- hermes profile use <name>`. **Now genuinely routes to LiteLLM** (verified `hermes --profile hermes_manager -m local -z` → `PONG`). Previously it silently never reached local models (dead `llm.*` config) — see §2.6.
- **Lumen** (Phase 16) — Ory's local code semantic-search MCP. Binary at `vendor/lumen/lumen-0.0.41-darwin-arm64`. Wrapper `bin/lumen`. Embeddings via `ordis/jina-embeddings-v2-base-code` on Ollama. Stdio MCP (no daemon).
- **ACE** (Phase 17, NEW 2026-05-29) — Stanford's Agentic Context Engineering. Cloned at `ace/`, uv venv, wrapper `bin/ace`. Routes via LiteLLM through `OPENAI_BASE_URL=http://litellm:4000/v1`. ACE_LITELLM_KEY virtual key scoped to local models. **`ace appworld` requires explicit confirmation** (executes model-generated tool calls on host).
- **Unsloth Studio** (Phase 14) — daemon on `:8898` for local model fine-tuning. PID file at `installer/state/unsloth.pid`.
- **HALO** (Phase 11) — installs `halo-engine` (exposes `bin/halo`), routes via LiteLLM (local default), agents-SDK cloud trace export disabled. CAVEAT: HALO wants OTel-format traces (not our custom `traces/litellm.jsonl`) and its openai-agents SDK uses the Responses API, so full analysis on LOCAL models is experimental.
- **RLM** (Phase 18, NEW 2026-05-31) — Recursive Language Models (`rlms` pip lib, `bin/rlm` wrapper + `rlm/run_rlm.py` runner). Model recursively calls itself over long context via a REPL that runs in a DOCKER SANDBOX (`python:3.11-slim`, not the host). Routes via LiteLLM + `RLM_LITELLM_KEY`, works on local models. It's the substrate HALO is built on.
- **Blaxel CLI** (Phase 12) — installed only.
- **MemPalace** (Phase 26, in `install all` since 2026-06-20 — appended last; also installable by name `vz-ai-stack.sh install 26` / alias `mempalace`) — local-first, **verbatim CONVERSATION memory** for Claude Code sessions (CLI + stdio MCP, no daemon, no port). PyPI-only (`uv tool install mempalace`). Runs on local on-device **ChromaDB** with **on-device ONNX/CoreML embeddings** (default `all-MiniLM-L6-v2`, 384-dim English; `embeddinggemma` multilingual opt-in) — **no cloud embeddings, NOT routed through LiteLLM**. The OPTIONAL entity-refiner LLM *does* route through LiteLLM (`MEMPALACE_LITELLM_KEY` → visible in Phoenix). Stop/PreCompact auto-save hooks are **opt-in/reversible** via `bin/mempalace-hooks` (NOT wired by install). A Qdrant backend adapter is **STAGED at `mempalace/backend-qdrant/` but NOT live** (MemPalace 3.3.5 hardcodes ChromaBackend + doesn't consume the backend registry yet). Complements Honcho (derived cross-agent facts) / Qdrant (document RAG) / Lumen (code search) — its niche is **verbatim Claude Code session recall**. Doctor check **44 `mempalace`** (conditional green-skip until Phase 26 has run).

### `stack` CLI subcommands (`vz-ai-stack.sh`)
- `deps [--check]` — host-dependency bootstrap (verify → install → start → re-verify: brew, yq, jq, node, orbstack, ollama). `--check` is verify-only. Lib `installer/lib/deps.sh`; see [PREREQUISITES.md](PREREQUISITES.md). (NEW 2026-06-04, `19d8464`)
- `setup` (alias `keys`) — interactive, skippable `.env` / API-key bootstrap. Ensures the **baseline first** (generates `LITELLM_MASTER_KEY` + `PHOENIX_SECRET` + service-URL defaults) via `installer/lib/env.sh::env_ensure_baseline` (SHARED with Phase 00), then walks an optional-secret catalog (cloud LLM keys, Helicone, GitHub, Blaxel, Telegram) — **all skippable, written 0600, never echoed**. Local-only / Claude-subscription (`-sub`, incl. opus) needs **ZERO keys**. `install all` offers it on first run (TTY-only). Lib `installer/lib/setup.sh`. (NEW 2026-06-04, `4f67e43`, `f142da4`)
- `install [phase|all] [--dry-run|--plan]` — run a phase or all phases. `--dry-run`/`--plan` is a read-only preview of host-deps + the ordered phase list (no changes). (`--dry-run` NEW 2026-06-04, `e472386`)
- `prepare-sudo` — sudo'd /etc/hosts + lo0 + launchd plist setup (idempotent)
- `verify` — runtime probes (lo0, /etc/hosts, host-gateway, end-to-end routing). Cheap, < 10s.
- `status` — declared vs actual + ownership table
- `model list|assign|sync|superset|discover|add` — declarative model↔agent binding (see [models.md](models.md)); `sync` is opt-in
- `fleet list|add|remove|new|destroy` — manage the Hermes fleet (add/remove a profile in hermes-fleet-v1; `new`/`destroy` a separate fleet sandbox)
- `upgrade <service|all> [--dry-run] | --check [--all|--json] | --outdated` — type-dispatched upgrade; `--check` is a read-only "what's outdated?" registry-digest scan
- `tutorial-serve [--port N] [--ttl 30m] [--revoke]` — serve doc/TUTORIAL.html + a safe live-demo proxy (ephemeral local-only LiteLLM key, server-side; see [TUTORIAL.md](TUTORIAL.md))
- `help` / `--help` (full subcommand list) · `<cmd> --help` / `help <cmd>` (focused per-command usage, NEW 2026-06-04 `df371a3`) · `help <service>` / `help services` / `help regen [<svc>] [--apply] [--check] [--model <m>] [--force]` — per-service help (NEW 2026-06-03). `help <svc>` prints **what it is** (authored prose) · **how it's configured** (computed LIVE from services.yml/aliases/env-key names — never `.env` _values_) · **how to use**. Prose lives in `services.yml` `help:` blocks (**38 seeded** from doc/EXPLORE.html's verified prose). `help regen` drafts/refreshes prose via the stack's own LiteLLM (default model `local-gemma4`, override `--model` or `HELP_REGEN_MODEL`), writes a STAGED overlay + unified diff; `--apply` merges it back (atomic `yq -i`). `--check` is a CI lint (NOT a doctor check). Lib: `installer/lib/help.sh`.
- `doctor [<filter>]` — 55 checks, per-check auto-fix
- `adopt <svc>` — claim a foreign container with docker-cp backup
- `start <svc>` / `stop <svc>` — invoke `bin/start-<svc>.sh` / `bin/stop-<svc>.sh` (added 2026-05-29 for deerflow)
- `<svc> start` / `<svc> stop` — reverse-form shortcut (e.g. `stack deerflow start`)
- `apply-restarts` — drain queued container recreates
- `logs <svc> [-f]` — docker logs
- `reset --confirm soft|hard|nuke` — tiered destructive resets. `hard` is now COMPLETE: deletes OpenShell sandboxes, tears down all compose projects (honcho/deerflow/autofyn/hermes-workspace incl. volumes like `honcho_redis-data`), and removes managed containers + the `ai-stack` network. Add `--yes`/`-y` for non-interactive (sets `AI_STACK_ASSUME_YES=1`; nuke's typed gate stays manual). PRESERVES ollama + models, docker images, `.env`, `/etc/hosts` ai-stack block.

---

## 2. Known-flaky (recovery dances ready)

These bite repeatedly. Each has a tested workaround.

### 2.1 OpenShell relay times out under idle — OR the sandboxes are GONE
**Symptom:** `openshell sandbox exec` returns `× status: DeadlineExceeded` (relay open timed out) — OR `openshell sandbox list` shows **"No sandboxes found"**. Both make the sandbox-exec doctor checks (24/25/30/33/40) fail.

**✅ FIXED in-code 2026-06-06 — `install` self-heals this, and 04f no longer misreports it.** There are TWO distinct causes that both surfaced as a 04f `relay open timed out`:
- **(1) Expired gateway token.** A sandbox's short-lived token expires; the sandbox still reports `Phase: Ready` (control-plane) and `policy set` still works, but the exec **relay is dead** — and it can be dead at **LOW CPU (~0.2%)**, so a CPU-based detector misses it. The token **cannot self-refresh**; only RECREATING mints a fresh one. Detected via the in-container **LOG signature** (`ExpiredSignature`/`RefreshSandboxToken…Unauthenticated`) by `openshell_token_storm` in `installer/lib/openshell.sh` — **reliable + non-invasive**. `openshell_sandbox_ensure` recreates a `Ready`-but-storming sandbox; prechecks in **04/04f/15** use the same signal so a stamped-but-dead sandbox re-runs its body. Heal: `install 04 04f` (hermes) / `install 15` (pi).
- **(2) CLI/gateway VERSION SKEW.** Phase 04f used **bare `openshell`**, which a uv-tool install (`~/.local/bin`, e.g. v0.0.57) **shadows** ahead of the brew binary (v0.0.51) that matches the gateway Phase 04 starts as a brew service. A mismatched client fails execs with `phase: Unspecified` / `relay open timed out` **on a perfectly healthy sandbox**. Fix: 04f now resolves `$OSH` (= brew binary, like 04/15/fleet) and uses it for EVERY sandbox op; Phase 04 logs a **VERSION SKEW warning** when the PATH default disagrees with the gateway binary.

> ⚠️ **Superseded approach:** an earlier same-day commit (`f7dc329`) tried to detect (1) with a *backgrounded `sandbox exec` probe* (`openshell_relay_ok`). That was REMOVED — it was unreliable (job-control reap races) AND **harmful** (killing the CLI mid-relay-open degraded the gateway into `phase: Unspecified`), and it didn't address (2). The current design uses **log-signature detection only** + the brew-binary fix.

(Recreation still DISCARDS in-sandbox `/sandbox`+`/tmp` scratch — no snapshot; persist to host/Honcho.) Verified end-to-end: `install all` passes 04f; doctor 30/43 green. STILL TODO (tracked): centralize the ~10 copied `resolve_openshell` defs into `lib/openshell.sh`; add a doctor check for version skew (warn-only today fires only during `install 04`); proactive token refresh / self-heal at interactive entry points. See [[project_cpu_gotchas]].

**⚠️ If the sandboxes are GONE (not just slow): root-caused 2026-06-03.** The `openshell-watchdog` detected an ~8h expired-token storm and its old heal was *delete-then-recreate*. It deleted both sandboxes, but the rebuild shelled `vz-ai-stack.sh install …` under launchd's PATH (which lacked OrbStack's `~/.orbstack/bin/docker`) → preflight aborted → rebuild failed → **ZERO sandboxes, with a false "done" in the log** (`installer/state/openshell-watchdog.log`). **FIXED (`ed8d6c1`): the watchdog is now WARN-ONLY by default** — it never auto-deletes; it logs + notifies + writes `installer/state/openshell-watchdog.alert` (doctor check **43 `watchdog_alert`** surfaces it). Auto-recreate is opt-in (`AI_STACK_WATCHDOG_RECREATE=1`) and now verifies docker is reachable *before* deleting + verifies Ready after + fails loud. **Recreate after any drop:** `bash vz-ai-stack.sh install 04 04f 15 20 04h` (NOTE: recreation mints a fresh token but DISCARDS in-sandbox runtime state — there is no snapshot; persist anything important to the host/Honcho). See [[project_cpu_gotchas]].


**Recovery:**
```bash
brew services restart openshell
# This puts BOTH sandboxes into "Error" phase. You must delete+recreate:
openshell sandbox delete pi-v1 2>/dev/null
openshell sandbox delete hermes-fleet-v1 2>/dev/null
bash ~/ai-stack/vz-ai-stack.sh install 04   # recreates hermes-fleet-v1
bash ~/ai-stack/vz-ai-stack.sh install 04f  # reinstalls Hermes in it
bash ~/ai-stack/vz-ai-stack.sh install 15   # recreates pi-v1 + reinstalls Pi
```

**Status:** the relay-timeout case is now **fixed in-code** (see the ✅ note above — `install 04 04f`/`15` self-heal it via `openshell_sandbox_ensure`'s relay probe + recreate). The manual `brew services restart` dance above is only needed for the harder GONE/Error cases or a stuck-create (§2.2). Remaining gap: no auto-heal at interactive entry points yet, and the doctor checks still only *detect* (no y/n auto-fix prompt).

### 2.2 OpenShell `sandbox create` hangs (≠ relay timeout)
**Symptom:** `openshell sandbox create --from base` sleeps in state `S` indefinitely (no output, no progress). Different from 2.1 — gateway is up, port :17670 responds, but create RPC is stuck.

**Status: AUTO-RECOVERED IN-CODE (2026-05-30).** `installer/lib/openshell.sh::openshell_sandbox_ensure` runs `create` in the background, polls `sandbox get` for `Phase=Ready`, then kills the hung create CLI (which on macOS never returns even after Ready) and retries/escalates. Phases 04 and 15 use it. The old manual create-hang dance is no longer needed — this is handled automatically.

### 2.3 `openshell-docker` network missing
**Symptom:** `sandbox create` fails with `Docker responded with status code 404: failed to set up container networking: network openshell-docker not found`. Happens after `docker network prune` or a fresh OrbStack install. **Now patched defensively in Phase 04 itself (2026-05-30).** If you see it anyway:
```bash
docker network create openshell-docker
openshell sandbox delete hermes-fleet-v1 2>/dev/null  # clear errored record
bash vz-ai-stack.sh install 04                            # will succeed now
```

### 2.4 DeerFlow CPU thrash (Pydantic crash loop)
**Symptom:** `docker stats deer-flow-gateway` shows ~340% CPU continuously even idle.

**Cause:** `deer-flow/config.yaml` `models:` block had only commented entries → Pydantic validator returns `None ≠ list` → 4 uvicorn workers crash on import → restart → repeat. **Fixed: Phase 10 now idempotently patches config.yaml + docker-compose.yaml + .env. Doctor check 28 catches regressions.**

### 2.5 LiteLLM `WARN[0000] The "LITELLM_MASTER_KEY" variable is not set`
**Cause:** deerflow's `scripts/deploy.sh` doesn't pass `--env-file`; compose looks for `.env` next to the compose file (`docker/.env`) for `${VAR}` substitution at parse time. **Fixed: `bin/start-deerflow.sh` exports `LITELLM_MASTER_KEY` from `~/ai-stack/.env` before invoking deploy.sh.** Use `stack start deerflow`, not `bash scripts/deploy.sh start` directly.

### 2.6 Hermes-agent v0.15.2 CLI drift — RESOLVED (2026-05-30)
**Original symptoms:** `hermes config set llm.openai_api_key …` → `ValueError: Invalid environment variable name: 'LLM.OPENAI_API_KEY'`; `hermes profile config <name> --set llm.model=…` → `invalid choice: 'config'`. Root cause: hermes-agent v0.15.2 has NO `llm.*` config namespace, so the old `llm.model`/`llm.openai_api_base`/`llm.openai_api_key` config was a dead no-op + a ValueError, and Hermes silently never reached local models.

**Status: RESOLVED.** Phase 04f now mints `HERMES_LITELLM_KEY`, adds a `litellm_proxy` endpoint to the hermes policy, and sets per-profile `model.default` + `model.provider=custom:litellm` + `providers.litellm.{base_url=http://host.docker.internal:4000/v1, api_key, model}`. Config rewritten for the real v0.15.2 schema; per-profile model + LiteLLM routing now wired and verified live (`hermes --profile hermes_manager -m local -z` → `PONG`).

### 2.7 status.sh used to mislabel compose services as `absent`
**Fixed 2026-05-29** via `ownership_compose()` + `project:` / `process_pattern:` overrides in services.yml. If you see it again, check that the `services.<name>.project:` field matches the actual compose project name (kebab-case).

### 2.8 Fleet / Claude-subscription routing (NEW — most likely 2026-06 debugging area)
The 9-role fleet + Pi route to the Meridian Claude subscription. The common failure modes + fixes:
- **403 / "key not allowed to access model"** for a `claude-*-sub-*` model → the scoped key (`HERMES_LITELLM_KEY` / `PI_LITELLM_KEY`) wasn't widened. **Fix:** `vz-ai-stack.sh model sync` (re-widens) or re-run `vz-ai-stack.sh install agent_fleet` (04h widens inline).
- **Fleet answers on `local-gemma4` instead of the subscription model** → Meridian daemon (`:3456`) is down, so availability-gating fell back **by design**. **Fix:** `bash bin/start-meridian.sh status` / `restart`; `claude login` if OAuth expired. Doctor check **41 `meridian`** surfaces this.
- **All `claude-*-sub-*` entries show `effort: high` in `litellm/config.yaml`** → a register-without-effort flattened the ladder (was a Phase 01 bug, fixed `3328206`). **Fix:** `vz-ai-stack.sh model sync` → `bash bin/start-litellm.sh --recreate`. Doctor check 41 has an effort-drift guard.
- **In-sandbox Hermes profiles ≠ the 9-role roster (stale / 16-profile "Frankenfleet")** → an interrupted 04f. Doctor check **30** catches it. **Fix:** re-run `vz-ai-stack.sh install 04f` (it prunes non-roster profiles), or hard-reset the sandbox.
- **`tutorial-serve` live demos dead** → the page is opened via `file://` (no proxy) — run `vz-ai-stack.sh tutorial-serve` and open the printed URL; or LiteLLM is down (`bin/start-litellm.sh`).

### 2.9 LiteLLM `/v1/models` times out on a cold / 2nd machine — `P1010` (RESOLVED 2026-06-06)
**Symptom:** Phase 01 reports the litellm container `Up`, `:5432` reachable, master key matches `.env`, yet `/v1/models` never responds (60s timeout). `litellm_diagnose` / container logs show Prisma: **`Error: P1010: User \`postgres\` was denied access on the database \`litellm.public\`**.
**Cause:** the `litellm` DB exists but the connecting role doesn't OWN it, and on **PG15+/wolfi-based** Postgres the locked-down `public` schema denies a non-owner role `CREATE` — so Prisma `migrate deploy` can't create its tables and uvicorn never serves. (On the dev Mac the `postgres` role is a superuser+owner, which is why it only bit on a second machine — classic happy-path blind spot.)
**Fixed (`652c447`):** `bin/start-litellm.sh` now idempotently runs `ALTER DATABASE litellm OWNER TO postgres` + `GRANT ALL PRIVILEGES ON DATABASE litellm TO postgres` + `GRANT ALL ON SCHEMA public TO postgres`, then **PROVES** the role can `CREATE` in `public` via a rolled-back probe before reporting success (a failing probe warns loudly with the exact superuser remediation). This also REPAIRS a DB left by the earlier create-only version, so the fix lands on the next `install 01` / `bin/start-litellm.sh --recreate`. **Manual fix** if ever needed: run the three statements above as a Postgres superuser, then `bash bin/start-litellm.sh --recreate`.

---

## 3. Recent session deltas

Read **CHANGELOG.md top to bottom** for full reasoning. Newest first:

### 3.-1 — 2026-06-04 → 06-05 (first-run onboarding, cold-start hardening, MemPalace, tutorial guard)

Newest work. Brings the cold/second-machine first-run experience up to spec and adds two doctor checks (then 45; now **46** total after `agent_fleet_parity`):

- **`setup` / `keys` — interactive `.env` bootstrap** (`4f67e43`, `f142da4`). Skippable wizard. Ensures the **baseline first** — generates `LITELLM_MASTER_KEY` + `PHOENIX_SECRET` and the service-URL defaults via `installer/lib/env.sh::env_ensure_baseline` (the SAME function Phase 00 calls, so `setup` and a plain `install all` converge on identical baseline `.env`). Then an **optional-secret catalog** (cloud LLM keys, Helicone, GitHub, Blaxel, Telegram) — every entry skippable, written **0600, never echoed to stdout/log** (constitutional rule 6). The local-only / Claude-subscription path (`-sub`, incl. opus) needs **ZERO keys**. `install all` offers `setup` on first run (TTY-only; non-interactive installs skip it). `f142da4` fixed a prompt-loop that was writing the catalog's own help text into `.env` values. Lib `installer/lib/setup.sh`.
- **`deps [--check]` — host-dependency bootstrap** (`19d8464`). verify → install → start → re-verify for brew/yq/jq/node/orbstack/ollama. `--check` is verify-only (no installs). Lib `installer/lib/deps.sh` + new `doc/PREREQUISITES.md`.
- **`install [all] --dry-run` (alias `--plan`)** (`e472386`). Read-only preview of host-deps + the ordered phase list; also fixed arg-forwarding so flags reach the phase runner.
- **Per-command help** (`df371a3`). `<cmd> --help` / `help <cmd>` → focused usage; bare `help` / `--help` → full subcommand list; `help <service>` → per-service (§1). Also fixed an ERR-trap leak.
- **LiteLLM cold-start hardening** (`89778b9`, `ad01a9f`, `1e18dfa`, `652c447`). (1) A running-but-**managed-and-unhealthy** litellm/phoenix/openwebui is now health-probed and **recreated** (self-heal) instead of assumed-good. (2) `bin/start-litellm.sh` now ensures the **`litellm` Postgres DATABASE exists** — server-reachable ≠ db-present was the real cause of the cold / 2nd-machine `/v1/models` timeout. (2b, `652c447`) It also **grants the connecting role owner + `public`-schema rights** and then **PROVES it can CREATE in `public`** (rolled-back probe). A bare `CREATE DATABASE` is not enough on PG15+/wolfi Postgres — the locked-down `public` schema otherwise denies the role and Prisma `migrate deploy` fails with `P1010: User postgres was denied access on the database litellm.public`. The DB identity (`PG_USER`/`PG_PASS`/`PG_DB`) is single-sourced so the granted role can't diverge from `DATABASE_URL`. (3) `litellm_diagnose` is a self-explaining, **secret-redacted** diagnostic. (4) The Ollama model disk-space precheck was right-sized + gated.
- **MemPalace Phase 26** (`b2f4f4b`) — opt-in local-first conversation memory. ChromaDB live; a **Qdrant adapter is STAGED at `mempalace/backend-qdrant/` but NOT runtime-wired** (MemPalace 3.3.5 hardcodes ChromaBackend). On-device CoreML/ONNX embeddings (no cloud, **NOT via LiteLLM**); the optional entity-refiner DOES route via LiteLLM (`MEMPALACE_LITELLM_KEY`). **Doctor check 44 `mempalace`** (green-skips when not installed). See §1 + §12.
- **Tutorial doctor check 45** (`8a4768d`, with `d239eb1`, `a12f5b0`) — **ALWAYS-ON** `tutorial` check validates `doc/TUTORIAL.html` is self-contained, link-clean, and in sync with `doc/TUTORIAL.md` via `installer/lib/build_tutorial_html.py --check`. (MemPalace was surfaced in EXPLORE/USER-GUIDE/DIAGRAMS HTML + the 39→40 service-count bump in `746f622`, `41375f7`, `6e62263`.)
- **Canonical first-run order is now: `deps → setup → prepare-sudo → install all → doctor`** (see §7).

### 3.0 — 2026-06-01 → 06-03 (help command, rename, agent fleet, subscription wiring, tutorial)

A debugger should know these touched a lot of surface area:

- **Per-service `help` command** (`831262b`, `178044a`; design spec `c0fe83c`/`b769731`) — NEWEST addition, **merged to main**. `vz-ai-stack.sh help <svc>` prints three sections: **what it is** (authored prose), **how it's configured** (computed live from `services.yml` / `aliases.tsv` / env-key _names_ — **never `.env` values**), **how to use**. `help services` lists services with prose; `help regen [<svc>] [--apply] [--check] [--model <m>]` drafts/refreshes prose via the stack's own LiteLLM (default `local-gemma4`), staging to `installer/state/help-staged-<key>.yaml` + a unified diff, only writing back on `--apply` (atomic `yq -i`). Prose authored in `services.yml` `help:` blocks — **38 seeded** from doc/EXPLORE.html's verified prose. Lib: `installer/lib/help.sh`. **Doctor was untouched by the help work (it stayed at 43 checks then; the count is now 45 after the opt-in MemPalace check #44 + the always-on tutorial check #45 landed — see §3.-1)** — `help --check` is a standalone CI lint, NOT yet wired into doctor (candidate next step). A **doc-cohesion audit across `doc/*.md`** was run alongside this.
- **`install.sh` → `vz-ai-stack.sh` rename** (`a796e2e`, `667af6b`). Project-wide sweep (797 refs, 124 files): the entrypoint, all `bin/*`, installer code, all docs. `bin/stack` wraps it. **Third-party `install.sh` URLs were preserved** (pi.dev, unsloth, OpenShell, blaxel, hermes `scripts/install.sh`). If you find a stale `install.sh`, it's either third-party (leave it) or a miss (fix it). Memory + `~/.claude/` global agent copies may still say `install.sh` until re-synced.
- **9-role agent fleet across 3 platforms** (`b867c34`). The Hermes fleet was REPLACED (old 7 `hermes_cos/...` → 9 `hermes_{manager,techlead,frontend_engineer,backend_engineer,ml_engineer,qa_test_engineer,reviewing_engineer,sre_engineer,incident_manager}`). Same roster on Pi (`bin/pi-as <role>`) + Claude Code (GLOBAL in `~/.claude`: the manager is the MAIN agent via a `~/.claude/CLAUDE.md` @-import of `~/.claude/fleet/manager.md`, the other 8 roles are subagents in `~/.claude/agents`). Source of truth: `agent-profiles/{hermes,pi,claude-code}/`. Keystone shared skill `team-protocol`. Installed by **phase `04h_agent_fleet.sh`** (`vz-ai-stack.sh install agent_fleet`). 04f is now fully data-driven (souls sourced from `agent-profiles/`, prunes stale in-sandbox profiles so a 7→9 swap can't leave a Frankenfleet). claw3d-bridge `bridge.py` registry migrated to the 9 roles. *(Superseded 2026-06-17: the manager install was re-rooted — it is now an absolute `@`-import of the repo canonical `~/ai-stack/fleet/manager.md`, with no `~/.claude/fleet/manager.md` copy. See CHANGELOG 2026-06-17 / spec §10.)*
- **All-subscription model wiring + cold-path fixes** (`6971198`, `3328206`, `9f8992b`). Hermes+Pi route to the Meridian Claude subscription. Two real bugs fixed: (1) `resolve_profile_model` only gated `lmstudio` → on a cold `install all` with Meridian down it pinned the fleet to unreachable `claude-*-sub-*` slugs; now gates `meridian` too (04f + fleet.sh + 15_pi.sh). (2) Phase 01's register loop dropped the per-model `effort`, flattening the subscription effort ladder to `high` on every install; now passes effort. NEW doctor checks: **41 `meridian`** (incl. an effort-ladder-drift guard) + **42 `agent_fleet`** (verifies the cross-platform fleet landed; opt-in green-skip). Check 30 got a Frankenfleet guard.
- **`upgrade` verb + `model discover|add`** (`f5f642b`, `3fd8516`). `vz-ai-stack.sh upgrade --check` = read-only registry-digest "what's outdated?" scan; `--outdated` upgrades only those.
- **Hands-on tutorial** (`c4b695f`, `7b145a5`, `e535b86`). `doc/TUTORIAL.md` (7-act/31-lesson from-scratch journey) + `doc/TUTORIAL.html` (4 live demos) + `vz-ai-stack.sh tutorial-serve` (`installer/lib/tutorial-serve.sh` + `tutorial_proxy.py`): mints an ephemeral, local-only, budget-capped, short-TTL LiteLLM key injected SERVER-SIDE (no token in the browser), serves the page + an allowlisted `/api/{health,models,chat}` proxy, auto-revokes on exit. **Gotcha:** the launcher must NOT `exec` the python proxy or the bash EXIT-trap revoke is orphaned. Also fixed deprecated fleet docs across 17 files.

### 3.1–3.10 — 2026-05-29 → 2026-05-30 (earlier)

Summary of major changes:

### 3.1 vz-ai-stack.sh cold-path phase ordering (2026-05-30)
**Problem:** `install all` from cold (post hard reset) failed at Phase 01 because LiteLLM's Prisma migration hangs without Postgres, which doesn't exist until Phase 03.

**Fix:** Phase array reordered to `… 02 03 01 01h …`. Phase 03 (Honcho/Postgres) runs before Phase 01 (LiteLLM). Also: `bin/start-litellm.sh` now does a TCP check on `:5432` and fails-loud BEFORE starting LiteLLM (saves the 60s hang).

**File:** `vz-ai-stack.sh:325` (default phase array), `vz-ai-stack.sh:178` (usage), `bin/start-litellm.sh:55-72` (Postgres precheck).

### 3.2 Phase 17 ACE (NEW 2026-05-29)
- `installer/phases/17_ace.sh` — clones `github.com/ace-agent/ace`, runs `uv sync` (~600MB), mints `ACE_LITELLM_KEY` virtual key, writes `ace/.env` with `OPENAI_BASE_URL=http://litellm:4000/v1`, generates `bin/ace` wrapper with `appworld` safety guard.
- `installer/doctor/checks/29_ace.sh` — verifies clone + venv + wrapper + .env routing + virtual key.
- `services.yml` entry (`type: cli-only`, `enabled: true`).

### 3.3 Phase 04f Hermes via PyPI (2026-05-29)
- Switched from `curl scripts/install.sh | bash` (was 403'd by OpenShell egress proxy) to `python3 -m pip install --upgrade hermes-agent` (PyPI v0.14.0+, lands in `/sandbox/.venv`).
- `sandbox mount` → `sandbox upload` per-file (OpenShell CLI removed `mount`).
- Multi-line `bash -c '<...>'` → single-line (OpenShell exec API rejects newlines in args).
- Positional `sandbox exec "$SANDBOX"` → `-n "$SANDBOX" --no-tty --` (current CLI form).
- `bash -n` validated; verified live: 7 profiles created.

### 3.4 services.yml host_port cleanup + ACE entry (2026-05-29)
- 11 stale `host_port: 80` lines fixed to match each block's `container_port`. Result of the OrbStack `*:80` collapse revert from 2026-05-28.
- New `ace:` entry (type: cli-only).
- New `project:` overrides: `deerflow → deer-flow`, `hermes_workspace → hermes-workspace`.
- New `process_pattern: mcp_server.py` for docs_mcp.
- `docs_ingestor.type` corrected from `python-bg` (was wrong — it's a one-shot CLI) to `cli-only`.

### 3.5 stack start/stop subcommands (2026-05-29)
- `vz-ai-stack.sh` gained `cmd_start` / `cmd_stop`. Dispatch order: `bin/start-<svc>.sh` / `bin/stop-<svc>.sh` → **brew services** for the allowlisted brew services `ollama`/`openshell` (2026-06-06; `stop ollama` warns it's the default+fallback, `stop openshell` warns it only cycles the gateway) → `docker stop` for other containers (stop only).
- Reverse-form `stack <svc> start` works via case-fallback in main dispatcher.
- `enable`/`disable` accepted as aliases for `start`/`stop`.
- `bin/start-deerflow.sh` / `bin/stop-deerflow.sh` wrap deerflow's `scripts/deploy.sh` and export `LITELLM_MASTER_KEY` for compose substitution.

### 3.6 DIAGRAMS.html pure-CSS-transform zoom (2026-05-29)
- Removed svg-pan-zoom CDN dependency entirely (third attempt at the zoom UX). Now uses a wrapping `.diag-pan-layer` with CSS `transform: translate() scale()`. Zoom range 0.15–40x (was 4x). Drag-pan via mousedown/move/up on window. Wheel zoom cursor-centered. Keyboard +/-/0. Fullscreen via `requestFullscreen()` with transform reset on enter/exit. Doesn't depend on any CDN library.

### 3.7 status.sh compose-aware ownership (2026-05-29)
- New `ownership_compose()` uses `com.docker.compose.project.working_dir` label.
- New helpers `svc_project()`, `svc_process_pattern()`, `svc_pidfile_alive()` read overrides from services.yml.
- All 6 false-alarm rows now read correctly (honcho, hermes_workspace, autofyn, deerflow as managed; docs_mcp as running; docs_ingestor as n/a).

### 3.8 Phase 15 ANSI strip + load_env bug fix (2026-05-29)
- Wait-for-Ready loop in `15_pi.sh` was comparing colored output `[32mReady[39m` against `"Ready"` → never matched. Fixed with `sed $'s/\x1b\\[[0-9;]*m//g'` before awk.
- `load_env || true` typo (function doesn't exist — env.sh only has `get_env`/`load_env_strict`) → replaced with `get_env LITELLM_MASTER_KEY ''`.

### 3.9 Phase 04f sandbox-existence check (2026-05-29)
- `grep -qxF "$SANDBOX"` against `openshell sandbox list` (tabular rows) never matched → `SKIP_SANDBOX_ACTIONS=1` always fired. Fixed with awk on `$1` after ANSI strip.

### 3.10 openshell-docker network defensive create (2026-05-30)
- Phase 04 now creates `openshell-docker` if missing (was assumed pre-existing; broke post-`docker network prune` or fresh installs).

---

## 4. Architecture (short — full in ARCHITECTURE.md)

```
vz-ai-stack.sh                      ← entry; bash 5+ gate; dispatches subcommands
  │
  ├── installer/lib/*.sh        ← helpers (sourced, not run directly)
  │   ├── common.sh             ← log/ok/warn/err, lock_acquire, stamp_*
  │   ├── env.sh                ← .env upserts (atomic mv), get_env, set_env
  │   ├── docker.sh             ← docker_run_managed, container_exists, …
  │   ├── network.sh            ← aliases.tsv loader, network_ensure_ai_stack
  │   ├── status.sh             ← `stack status` (compose-aware as of 2026-05-29)
  │   ├── litellm.sh            ← virtual key minting helpers
  │   └── …
  ├── installer/phases/NN_*.sh  ← one per phase; precheck() then work then stamp_mark
  ├── installer/doctor/checks/  ← one file per failure mode; doctor.sh discovers
  ├── installer/smoke/<phase>.sh ← end-to-end smoke per phase
  └── installer/state/          ← stamps, restart queue, lock dir
```

Three discipline rules:
1. **Stamps are advisory cache.** Every phase has a `precheck()` that re-verifies. Don't trust the stamp without re-checking.
2. **Docker run flag order is FIXED.** `--env-file`, `-e`, `-p`, `-v`, `--restart`, IMAGE, CMD. Mixing breaks LiteLLM with `No such option: -e`.
3. **`.env` writes go through `lib/env.sh::set_env`.** awk → tmpfile → mv. Never `sed -i`. Never `echo >>` for an upsert.

---

## 5. What's NOT done (deliberately or known-stale)

These are NOT bugs. They're things deferred for design or upstream-availability reasons.

### 5.1 hermes-agent v0.15.2 per-profile model config — DONE (2026-05-30)
~~Bootstrap creates 7 profiles, but per-profile model config was unwired.~~ Phase 04f now sets per-profile `model.default` + `model.provider=custom:litellm` against the real v0.15.2 schema. See §2.6.

### 5.2 hermes-agent v0.15.2 `llm.openai_api_key` config — DONE (2026-05-30)
~~`hermes config set llm.openai_api_key …` rejected with strict env-name validator.~~ Phase 04f now mints `HERMES_LITELLM_KEY` and sets `providers.litellm.api_key` per profile (no `llm.*` namespace exists in v0.15.2). See §2.6.

### 5.3 DIAGRAMS.html mermaid SRI
Mermaid CDN script lacks `integrity="sha384-..."` SRI hash. Defer until next pass — security guidance noted in CHANGELOG.

### 5.4 OpenShell relay auto-recovery doctor check
Doctor check 25 detects relay timeout but only surfaces the manual recovery dance. A doctor auto-fix that runs `brew services restart openshell` + sandbox delete+recreate behind a y/n prompt would prevent the user hitting it manually. ~50 LOC.

### 5.5 `pi_gateway_litellm` status detector
`stack status` shows `?` for this row — OpenShell L7 inference route, no `python-bg`/`compose`/`docker`-style detector. Add a new service type or special-case.

### 5.6 vz-ai-stack.sh adopt for compose services
`installer/lib/docker.sh::container_exists` is single-container-only. `vz-ai-stack.sh adopt`, `stack stop`, and several doctor checks may not work cleanly on compose services. Cross-cutting cleanup follow-up.

### 5.7 Phoenix per-key tagging propagation
Unverified whether LiteLLM `tags` field propagates into Phoenix project name. Needs manual UI eyeball before promoting to a doctor check.

### 5.8 ACE pin file format
Phase 17 captures `ACE_PIN` SHA in `.env`. Should also be in a separate `installer/state/ace.pin` for visibility. Cosmetic.

### 5.9 `help --check` not wired into doctor (NEW 2026-06-03)
`vz-ai-stack.sh help --check` is a standalone CI lint (verifies every enabled service has a `help:` block + the blocks parse). It is **not** a doctor check yet. Wiring it into doctor (or folding it into an existing services-coverage check) is the obvious next step — deliberately deferred so the help feature could ship doctor-neutral. (Doctor check #44 is the `mempalace` check.) 1 service of 41 still lacks authored prose (40 seeded of 41); `help regen <svc> --apply` fills it.

---

## 6. The biggest landmines (from prior + recent sessions)

1. **PHOENIX_COLLECTOR_HTTP_ENDPOINT empty** → OTel defaults to `localhost:6006` which inside the container is the container itself. Doctor check 04 catches.
2. **PHOENIX_API_KEY empty when auth on** → 401 on every trace push. Doctor check 13 catches.
3. **`docker restart` doesn't reload `--env-file`.** Always full recreate via `bin/start-<svc>.sh`. Doctor check 05 catches in-container drift.
4. **OrbStack bind-mount snapshot quirk.** Container holds snapshot view; host writes don't propagate; recreate without `docker cp` first can lose data.
5. **Honcho's redis collides with FalkorDB on :6379.** Phase 03 fixes via `docker-compose.override.yml` with `ports: !reset []`.
6. **OpenShell CLI drift.** Alpha tool; commands move. Each Phase 04/04f/15 reflects whatever the CLI shape is at install time.
7. **Bash 3.2 on macOS lacks associative arrays.** Installer re-execs under bash 5+.
8. **`-e` flag after `-p`/`-v` in docker run** leaks env flags to the litellm CLI. All start scripts use canonical order.
9. **OrbStack `*:80` wildcard listener.** Every `--publish 127.0.10.X:80:Y` collapses into single host-side `*:80`; HTTP services on port 80 routed to whichever container was registered first. **Fix permanent:** every HTTP service publishes on its native container port.
10. **macOS does NOT auto-route `127.0.0.0/8`.** Only `127.0.0.1` is on `lo0` by default; `/etc/hosts` resolves but kernel routing drops packets to `127.0.10.X` unless explicitly bound via `ifconfig lo0 alias`. `prepare-sudo` binds; launchd plist re-binds on boot. Doctor check 19 enforces.
11. **Cold install ordering: Phase 03 BEFORE Phase 01** (2026-05-30). LiteLLM needs Postgres from Honcho. Reordered in `vz-ai-stack.sh:325`.
12. **`openshell-docker` network needed before Phase 04** (2026-05-30). Phase 04 now creates it defensively.
13. **OpenShell sandbox uses `/sandbox/.venv` uv venv internally.** Don't use `--user` or `--break-system-packages` for `pip install` inside — both fail in a venv. Plain `pip install` works.

---

## 7. From-scratch install (verified procedure)

Canonical first-run order (2026-06-04): **deps → setup → prepare-sudo → install all → doctor**.

```bash
# 0. Host-dependency bootstrap (brew/yq/jq/node/orbstack/ollama). `--check` = verify-only.
bash ~/ai-stack/vz-ai-stack.sh deps

# 0.5 Interactive .env / API-key bootstrap (skippable; local-only / Claude-sub needs ZERO keys).
#     `install all` also offers this on first run (TTY-only).
bash ~/ai-stack/vz-ai-stack.sh setup          # alias: keys

# 1. One-time sudo prep (writes /etc/hosts ai-stack block + lo0 aliases + launchd plist)
sudo bash ~/ai-stack/vz-ai-stack.sh prepare-sudo

# 2. Hard reset if there's prior state (add --yes / -y for non-interactive)
bash ~/ai-stack/vz-ai-stack.sh reset --confirm hard --yes

# (preview-only, optional) read-only plan of host-deps + ordered phases, no changes
bash ~/ai-stack/vz-ai-stack.sh install all --dry-run

# 3. Install everything (30–60 min depending on docker pulls)
bash ~/ai-stack/vz-ai-stack.sh install all

# 4. Verify (53/53 expected — #05a litellm_keystore AUTOHEALS the LiteLLM key-store/Postgres (runs before the per-phase key checks); MemPalace check #44 runs once Phase 26 is installed (green-skips only on a pre-change/partial install); #45 tutorial is always-on; #46 = agent_fleet_parity; #47/#48 = docker-engine consistency/selection; #49 sourcegraph_mcp skip-cleans when SG not installed; #50 aionui skip-cleans when AionUi not installed; #51 openwork skip-cleans when OpenWork not installed; #52 understand skip-cleans / passes-with-note until a knowledge graph is committed)
bash ~/ai-stack/vz-ai-stack.sh doctor
```

This canonical flow was verified end-to-end at the prior doctor count via a cold `reset --hard → install all → doctor`. For the **50/50** state, the docker-engine feature's offline suite is green and its engine checks (01/47/48) were live-sanity-verified against the OrbStack daemon — but a fresh cold install re-confirming **50/50** has not yet been re-run; do so post-merge. OpenShell sandbox-create hangs are auto-recovered in-code (§2.2), so step 3 should no longer stall there.

**If something still hangs at OpenShell sandbox create** (rare now — see §2.2), in a second terminal:
```bash
pkill -9 -f 'vz-ai-stack.sh|openshell sandbox create'
rm -f ~/ai-stack/installer/state/.lock
brew services restart openshell ; sleep 5
openshell sandbox delete hermes-fleet-v1 2>/dev/null
openshell sandbox delete pi-v1 2>/dev/null
bash ~/ai-stack/vz-ai-stack.sh install all   # resumes from where it left off
```

**Most likely Phase 04f failure:** if PyPI is 403'd through the OpenShell egress proxy (per past Phase 04f notes — has happened intermittently), you'd need to pre-stage `hermes-agent` as a tarball like Phase 15 does for Pi. Not happened yet on Mayssam's host but documented as risk.

---

## 8. What to do FIRST if you're picking this up

1. **Read [README.md § Operating principles](../README.md#operating-principles-mayssams-constitution-internalized).** Constitution.
2. **Run `stack verify` then `stack status` then `stack doctor`** — see live state. Compare against §1 above.
3. **Read `CHANGELOG.md` top-to-bottom.** Architecture decisions + review-cycle outcomes are there with reasoning. Don't re-litigate without new evidence.
4. **If a phase needs updating**: read its existing script + its `precheck()` + its smoke (`installer/smoke/NN.sh`) BEFORE changing anything. Match local conventions.
5. **If you find a new failure mode**: add a doctor check (don't bury the fix in the phase script). One file per failure mode. Pattern in [OPERATIONS.md § Adding a new doctor check](OPERATIONS.md#adding-a-new-doctor-check).

---

## 9. What NOT to do

- **Don't `docker rm -f` a running container without confirmation.** Conservative mode. `docker cp` first. The `recreate_guard` enforces.
- **Don't restart OpenShell casually.** It Errors both sandboxes. Always be prepared to delete+recreate. Use only when relay is verifiably stuck (see §2.1).
- **Don't add a `progress.json` or central state DB.** Per-file stamps are the model. Adversarial review caught this.
- **Don't auto-restart anything when `.env` changes.** Write to `restarts-needed.txt`. User runs `apply-restarts` when ready.
- **Don't promise "I'll be more careful" without changing behavior.** Demonstrate, don't promise.
- **Don't auto-edit `~/.zshrc`** or other user config. Print the line, let user choose.
- **Don't add a new service by hard-coding its IP.** Append a row to `installer/lib/aliases.tsv`.
- **Don't leave background tasks running.** User has called this out ≥3 times. If you bg something, kill it on completion.
- **Don't try port-free aliases (`http://litellm/`).** Investigated 2026-05-28, OrbStack collapses `*:80`. Stay on `:4000` etc.

---

## 10. If something's broken — diagnosis order

1. `stack status` — most things land here. Check for false alarms (see §3.7 — should be fixed but worth verifying for new services).
2. `stack doctor` — 55 checks, each with auto-fix offer.
3. [DOCTOR.md](DOCTOR.md) — what each check means.
4. [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — less common issues.
5. `docker logs <container>` — actual error here.
6. [ARCHITECTURE.md](ARCHITECTURE.md) — shape before patching.

---

## 11. The two things Mayssam should never have to do again

1. **Copy-paste a `docker run` command from a chat.** Start scripts are source of truth. If you're tempted to give him a docker command, stop and either write/update `bin/start-<svc>.sh` or document why an existing one needs amending.

2. **Be the debug loop.** When something fails, the doctor should detect it, the failure should have a clear diagnosis, and the auto-fix should work. New failure mode → new doctor check, before moving on.

If you keep these as constraints, you'll write the right code.

---

## 12. File map (where to look)

| File | Purpose |
|---|---|
| `vz-ai-stack.sh` | Entry point, phase dispatcher, lock + bash5 gate |
| `services.yml` | Single source of truth: 44 services with type/enabled/path/port/project/process_pattern/etc. (schema `version: 2`) |
| `installer/lib/aliases.tsv` | Canonical alias table (alias, IP, protocol, host_port, container_port, phase, service_key) |
| `installer/lib/env.sh` | `.env` upserts (atomic mv), `get_env`/`set_env`. **`env_ensure_baseline`** generates `LITELLM_MASTER_KEY` + `PHOENIX_SECRET` + service-URL defaults; SHARED by Phase 00 and `setup` so both converge on identical baseline `.env`. |
| `installer/lib/deps.sh` | Backs `vz-ai-stack.sh deps [--check]` — host-dependency bootstrap (verify → install → start → re-verify: brew/yq/jq/node/orbstack/ollama). See `doc/PREREQUISITES.md`. |
| `installer/lib/setup.sh` | Backs `vz-ai-stack.sh setup` (alias `keys`) — interactive, skippable `.env`/API-key bootstrap. Calls `env_ensure_baseline` first, then an optional-secret catalog (all skippable, 0600, never echoed). |
| `installer/lib/openshell.sh` | Hang-resilient OpenShell sandbox create. `openshell_sandbox_ensure` backgrounds `create`, polls `sandbox get` for `Phase=Ready`, kills the hung create CLI, retries/escalates. Used by Phases 04 + 15. |
| `installer/phases/NN_*.sh` | One per phase. `precheck()` → work → `stamp_mark` |
| `installer/doctor/checks/NN_*.sh` | One per failure mode (**55 checks**). Each defines `CHECKS+=(name)` + `<name>_diagnose` + `<name>_fix`. Check **05a `litellm_keystore`** (AUTOHEAL — auto-recovers the LiteLLM key-store/Postgres before the per-phase key checks) + **44 `mempalace`** (Phase 26; green-skips until Phase 26 has run) + **45 `tutorial`** (always-on; validates `doc/TUTORIAL.html` via `build_tutorial_html.py --check`) + **46 `agent_fleet_parity`** (always-on; wraps `check_fleet_parity.sh` — 7 skills + Tier-1 + role bodies identical ×3) + **47 `docker_engine_consistency`** (no split-brain across ambient CLI / gateway.env / managed containers) + **48 `docker_engine_selection`** (`AI_STACK_DOCKER_ENGINE` present + valid + installed) + **49 `sourcegraph_mcp`** (opt-in Phase 27; skip-cleans when Sourcegraph not installed) + **50 `aionui`** (opt-in Phase 28; skip-cleans when AionUi not installed) + **51 `openwork`** (opt-in Phase 29; skip-cleans when OpenWork not installed) + **52 `understand`** (opt-in Phase 30; skip-cleans, or passes-with-note until a knowledge graph is committed) + **53 `container_liveness`** (ALWAYS-ON; census — every managed container EXISTS + running & healthy). |
| `installer/smoke/NN.sh` | End-to-end smoke per phase |
| `installer/state/` | Stamps, restart queue, lock dir, daemon PID files |
| `ingestor/inbox/`, `ingestor/processed/` | Ingestion drop dirs (formerly `docs/inbox` + `docs/processed`; there is no top-level `docs/` anymore). Drop files to ingest into `~/ai-stack/ingestor/inbox`. |
| `bin/start-<svc>.sh` | Per-service launcher. Canonical docker run flag order. |
| `litellm/config.yaml` | LiteLLM model + callback config |
| `litellm/trace_to_file.py` | Custom JSONL trace logger |
| `litellm/guardrails.py` | Pre/post-call guardrail callbacks (denied-words + secrets regex) |
| `CHANGELOG.md` | **Read this** — full history with reasoning (stays at repo root) |
| `doc/DOCTOR.md` | Per-check reference |
| `doc/OPERATIONS.md` | `stack` CLI cheatsheet |
| `doc/ARCHITECTURE.md` | Deep design notes |
| `doc/TROUBLESHOOTING.md` | Diagnose-from-scratch recipes |
| `doc/PORTS.md`, `doc/DEPENDENCIES.md`, `doc/STACK-GUIDE.md`, `doc/DIAGRAMS.md`, `doc/DIAGRAMS.html` | Reference |
| `doc/USER-GUIDE.md`, `doc/USER-GUIDE.html` | End-user onboarding (every service + recipes) |
| `doc/TUTORIAL.md`, `doc/TUTORIAL.html` | Hands-on from-scratch tutorial (7 acts, 31 lessons) + interactive page |
| `agent-profiles/{hermes,pi,claude-code}/` | **Source of truth for the 9-role fleet** — SOUL.md / SYSTEM.md / `.claude` subagents + the `team-protocol` skill. Phase 04f (Hermes) + 04h (Pi+Claude) install from here. |
| `installer/lib/tutorial-serve.sh` + `tutorial_proxy.py` | `tutorial-serve` live-demo: mints an ephemeral local-only LiteLLM key, serves TUTORIAL.html + an allowlisted `/api` proxy (key injected server-side), auto-revokes. |
| `installer/lib/build_tutorial_html.py` | Builds `doc/TUTORIAL.html` from `doc/TUTORIAL.md`. **`--check`** mode (no write) validates the HTML is self-contained, link-clean, and in sync with the `.md` — invoked by doctor check **45 `tutorial`**. |
| `installer/lib/help.sh` | Backs `vz-ai-stack.sh help`. Renders authored `help:` prose + LIVE-computed config (services.yml/aliases/env-key NAMES; never `.env` values). `help regen` drafts via LiteLLM (default `local-gemma4`), stages to `installer/state/help-staged-<key>.yaml` + diff, applies on `--apply`. Prose source-of-truth = `services.yml` `help:` blocks (38 seeded). |
| `installer/phases/04h_agent_fleet.sh` | Installs the fleet to Claude Code (`~/.claude`, global) + Pi (`pi-v1`), re-runs 04f, widens the PI/HERMES keys. |
| `installer/phases/26_mempalace.sh` | Part of `install all` (appended last). Installs MemPalace via PyPI (`uv tool install mempalace`), writes `bin/mempalace` + launchers + palace config, mints `MEMPALACE_LITELLM_KEY` (for the OPTIONAL entity-refiner LLM only — embeddings stay on-device ONNX/CoreML, never via LiteLLM). Stop/PreCompact auto-save hooks are opt-in/reversible via `bin/mempalace-hooks` (NOT wired here). Doctor check 44 `mempalace`. |
| `mempalace/backend-qdrant/` | **STAGED, NOT LIVE.** A Qdrant backend adapter for MemPalace. MemPalace 3.3.5 hardcodes `ChromaBackend` and does not consume the backend registry yet, so MemPalace runs on local on-device ChromaDB; this adapter is parked here for when upstream exposes the registry. |
| `README.md` | Top-level entrypoint + Mayssam's constitution (stays at repo root) |

> **Layout note (2026-05-30):** All docs now live under `doc/` (this file is `doc/HANDOFF.md`) EXCEPT `README.md` + `CHANGELOG.md`, which stay at repo root.

---

## 13. Contact

Mayssam Sayyadian — `mayssam.sayyadian@veza.com`. Read [README.md § Operating principles](../README.md#operating-principles-mayssams-constitution-internalized) and the auto-loaded memories under `~/.claude/projects/-Users-mayssam-sayyadian-ai-stack/memory/` before engaging.
