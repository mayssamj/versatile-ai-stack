# Plan — Add 5 agent-swarm-simulation platforms as opt-in services

**Date:** 2026-06-23
**Branch:** `feat/agent-sim-platforms-plan` (worktree per SOUL §25)
**Status:** v2 — §24 council reviewed (adversarial + architect + qa/infra + PM → **SHIP-WITH-FIXES**); fixes folded in. Ready for per-service implementation.
**Author:** manager (orchestrator)

> **Use case (operator's words):** *experiment with creating large numbers of agents (swarms) and
> managing them in simulation / "agents-living-in-a-world" scenarios. NOT production. Don't overthink it.*
> So: **opt-in** services (never in `install all`), LLM traffic through **LiteLLM** with **scoped keys**,
> **loopback-only**, **fully reversible**, **observable in Phoenix** so you can watch a swarm run — but
> installed *cleanly* (same lifecycle/doctor/drift/docs/e2e gates as any service) so the playground is
> reproducible, not a pile of clones.

---

## 0a. Which tool, and how you'll play (read this first)

| Tool | Best for | Archetype | First command (after install) |
|---|---|---|---|
| **OASIS** | **Large-scale social swarms** (≤1M agents) — the headline for "agents in a world" | host venv (batch) | `vz-ai-stack.sh run oasis -- sims/twitter_demo.py` |
| **MetaGPT** | Role-play "software company" swarm (PM→architect→dev) | host venv (batch) | `vz-ai-stack.sh run metagpt -- "build a CLI todo app"` |
| **AgentScope** | Build/scale your own multi-agent sims **+ a Studio GUI to watch them** | host venv (+opt. Studio web UI) | `vz-ai-stack.sh run agentscope -- sims/two_agents.py` |
| **AI Town** | The "virtual town" — characters that live, move, chat (most *watchable*) | container (Convex compose) | `open http://aitown/` |
| **ChatDev** *(optional)* | Fixed small dev-team role-play (not really a *swarm*) | container (web app) | `open http://chatdev/` |

Watch any swarm's live model traffic in **Phoenix** (`http://phoenix:6006`) — it's already wired through LiteLLM, so every agent call is traced with no extra setup.

**Reality check (M4/24GB):** "large swarm" on-box = dozens of agents on a small fast model (`local-gemma4`) with queuing. For 100s–1000s, route the scoped key to a cheap cloud model (metered) — the *orchestrator* isn't the limit, local inference throughput is. Stated again in every tool's docs.

## 0b. Targets (verified live, 2026-06-23)

| Tool | Repo | ★ | License | LLM→LiteLLM | Archetype (post-review) |
|---|---|---|---|---|---|
| **MetaGPT** | `FoundationAgents/MetaGPT` (geekan/* redirects) | 69k | MIT | `~/.metagpt/config2.yaml` `base_url` ✅ (prove indirection expands) | **host venv** |
| **AgentScope** | `agentscope-ai/agentscope` (was modelscope/*) | 27k | Apache-2.0 | model config `base_url`/Ollama ⚠️ verify key | **host venv** + optional **Studio** (web) |
| **OASIS** | `camel-ai/oasis` | 4.8k | Apache-2.0 | CAMEL `ModelPlatformType.OPENAI_COMPATIBLE`+`url` ⚠️ verify wired through agents | **host venv** |
| **ChatDev** | `OpenBMB/ChatDev` (2.0) | 33k | Apache-2.0 | `.env` `BASE_URL`+`API_KEY` ✅ | **container web app** ⚠️ verify 2.0 is web (else venv) |
| **AI Town** | `a16z-infra/ai-town` | 10k | MIT | env OpenAI-compat base URL ⚠️ verify self-hosted Convex routes locally | **container** (Convex compose) |

## 0c. Rollout in waves (plan all 5; build incrementally)

- **Wave 1 — play soonest:** **OASIS + MetaGPT** (both host-venv batch; one is the literal large-swarm sim, one is the easy multi-role intro). ~40% of the build, covers the core intent.
- **Wave 2:** **AgentScope** (+Studio to watch), then **AI Town** (the watchable world; heaviest — gated behind its feasibility pre-check, §6 Prompt 5a).
- **Optional / on-demand:** **ChatDev** — weakest fit for "large swarms" (a fixed ~5-role team) and the heaviest non-AI-Town integration. Build only if you want the software-team genre.
- **Rejected:** a single umbrella `agent-sims` phase — it would break per-tool opt-in/teardown granularity (you couldn't try just OASIS without pulling Convex) and collapse 5 independent doctor/smoke signals into one. Per-service phases are the right call.

---

## 1. Hard constraints discovered (must respect)

1. **Archetype split is the spine.** *Host-venv batch libs* (MetaGPT, OASIS, AgentScope-lib) mirror **Phase 06 (docs_ingestor) / Phase 26 (MemPalace)**: `uv venv`/`uv tool`, a `bin/<svc>` wrapper that injects the scoped key from `.env` at runtime (like `bin/mempalace`), a `sims/` workspace, **no container, no port, no hostname**. *Web apps* (ChatDev, AI Town, AgentScope-Studio) mirror **Phase 28 (AionUi)**: container(s), loopback, scoped key via `{env:}`, hostname bridge, doctor health probe, browser e2e.
2. **Host-venv LLM routing = `http://127.0.0.1:4000/v1`** (the container DNS name `litellm` does NOT resolve from the host shell; `127.0.0.1:4000` always does). **Container routing**: on `ai-stack` net → `http://litellm:4000/v1`; off-bridge (AI Town) → `http://host.docker.internal:4000/v1` **and** pass `engine_addhost_args` (else breaks on colima/podman).

   > **Amendment (2026-06-23, §24.4 implementation-council decision):** this constraint's *premise* is now STALE — `litellm` DOES resolve from the host shell, because CORE Phase `00n` (in `install_all_phase_order`) writes the `/etc/hosts` `litellm`→`127.0.10.1` block + the `lo0` alias, and LiteLLM publishes on `127.0.10.1:4000`. Verified live: both `litellm:4000` and `127.0.0.1:4000` return 200, and the shipped Phase 26 mempalace exemplar already routes to `litellm:4000`. **Decision:** host-venv *wrappers* (`bin/metagpt`/`bin/oasis`) + the seeded sims route to `http://127.0.0.1:4000/v1` (always works, no dependency on 00n); install *preconditions* + *doctor checks* try `litellm:4000` then fall back to `127.0.0.1:4000`. This keeps the portability intent without the false premise. (Also: `metagpt` must be installed as `--prerelease=allow "metagpt==0.8.2"` — it depends on the `semantic-kernel==0.4.3.dev0` pre-release; the bare name backtracks to the ancient, unbuildable v0.1.)
3. **Port collisions — three web UIs default to Vite `:5173`** (AI Town fe, ChatDev fe, AgentScope Studio). Reassign **host** ports (pre-assigned in §7); container ports may stay default.
4. **Pre-assign loopback IPs in this plan** (§7) so 5 parallel worktrees don't race on "next free `127.0.10.x`". Implementer still **censuses `aliases.tsv` for the true current max before writing** (parallel-session churn is a documented risk) — blocking.
5. **`install all` must NOT include 32–36** — opt-in only (`install_all_phase_order()` in `vz-ai-stack.sh` is the sole lever; leave it untouched).
6. **Never the master key**; never commit secrets; loopback binds; `{env:}` / `${VAR}` indirection in config files (and **prove the indirection actually expands** — a literal placeholder = silent 401).
7. **Resource caps on every persistent container** (`--memory`, `--cpus`) + lean images (multi-stage; bound web-app images < ~800 MB) — fleet-durability lesson (uncapped → host starvation).
8. **arm64:** assert `pip/uv install` produces native arm64 (no silent amd64 fallback) before stamping.

---

## 2. The canonical "add a service" lifecycle (grounded; per archetype)

Verified against phases 06/26/28/30 + checks 50/52/53/16 + smoke 28/30 + the AionUi/OpenWork specs.

### 2A. Registration & install
**Both archetypes:** `installer/phases/<NN>_<svc>.sh` (NN = **32–36**; re-verify free with `ls` at write-time — blocking). `set -Eeuo pipefail`; source `common.sh`+`env.sh`+`worktree.sh`; `worktree_guard "install <svc>"`; `precheck()` idempotency → `stamp_check`; mint scoped key (§2C); smoke-gate before `stamp_mark`. `services.yml` entry (registry / source-of-truth for `help` + EXPLORE). **Do NOT touch `install_all_phase_order()`.** `models.yml` unchanged (key-scoped, not model-assigned).

- **Host-venv batch (MetaGPT/OASIS/AgentScope-lib)** — mirror **Phase 06/26**: `uv venv <svc>/.venv` + `uv pip install <pkg>` (or `uv tool install`); a **`bin/<svc>` wrapper** that sources `.env`, exports the scoped key + `OPENAI_BASE_URL=http://127.0.0.1:4000/v1`, and execs the lib against `<svc>/sims/`. Register a `run` verb (`vz-ai-stack.sh run <svc> -- …`). No `bin/start-*` daemon, no port, no hostname.
- **Container web app (ChatDev/AI Town/AgentScope-Studio)** — mirror **Phase 28**: `bin/start-<svc>.sh` (`install|run|uninstall|status`), idempotent `recreate_guard`, loopback publish, `--memory`/`--cpus` caps, labels (§2B), hostname (§2D).

### 2B. Container identity (web apps only — so doctor-53 liveness sees them)
- Single containers: `--label ai-stack.managed=true --label ai-stack.phase=<NN>` + join `ai-stack` net.
- **Compose stacks (AI Town)**: set a **stable `project:`** name AND register it in `services.yml` as `type: compose` with that `project:` — because if it's `bridge-exempt` + off-net, the **compose-project signal is the ONLY way check 53 sees it** (label/net signals are gone). Caps on every compose service.
- Off-bridge web app reaching only LiteLLM: `--label ai-stack.bridge-exempt=true` so **check 16** skips it — but **label only the containers that genuinely can't join the bridge**, and document why (don't blanket-exempt a whole stack and blind check 16).
- Host-venv tools have no container → not in check 53's census; their doctor check is venv+import+key (correct; note "invisible to 53 when idle" so it doesn't confuse).

### 2C. Hardening (per service — non-negotiable)
- **Scoped LiteLLM key:** `POST http://litellm:4000/key/generate` (mint via master, briefly in `-H` — inherited platform pattern, noted) body `{"models":[…],"key_alias":"<svc>","metadata":{"owner":"<svc>","purpose":"phase<NN>"}}`; validate by listing `/v1/models` (200 + `"id"`, else re-mint); `set_env <SVC>_LITELLM_KEY` (.env 0600). Default models `["local-gemma4","claude-opus-4.8-sub-xhigh","claude-sonnet-4.6-sub-high"]`.
- **Indirection + PROOF:** config references `{env:<SVC>_LITELLM_KEY}`/`${VAR}` — never the literal. **Prove the tool actually expands it** (MetaGPT's YAML loader, AgentScope's config, etc. may not) by asserting a real model call returns 200 through LiteLLM, not just that the process ran.
- **Loopback only**; secrets in env/launchd `EnvironmentVariables` (not argv → not in `ps`), plists `chmod 600`, `.env` never committed.
- **Observability:** every scoped key's traffic appears in **Phoenix** (`http://phoenix:6006`) automatically (LiteLLM → Phoenix OTLP). Name it in each service's `help.config_notes`.

### 2D. Hostname bridge (web apps only; host-venv tools skip entirely)
Add `installer/lib/aliases.tsv` row `<svc>  127.0.10.<N>  http  <host_port>  <container_port>  <NN>  <svc>` (IP from §7; `protocol=http`). Publish `-p 127.0.10.<N>:<port>:<port>`. `prepare-sudo`/Phase 00n binds the `lo0` alias; opt-in Phase 31 `ingress up` regenerates Caddy → `http(s)://<svc>/`. **The alias must target the BROWSER UX surface** (the frontend), not the API backend.

### 2E. Doctor + smoke (per service)
- **Doctor check** `installer/doctor/checks/<NN>_<svc>.sh` (ordinals **57+**; re-verify highest with `ls` — count auto-derives). `CHECKS+=(<svc>)`, `CHECK_TITLE[<svc>]`, `<svc>_diagnose()` (0=PASS), `<svc>_fix()`. **Skip-clean** if phase stamp absent. Health: `grep -q '^200$'` (NOT `http_ok` — `000000` false-healthy bug). Key probe gated on `litellm_db_down()`. Web-app/Studio checks **conditional on enabled** (don't fail a lib-only install). Host-venv check = venv present + `python -c import` + key lists models.
- **Smoke** `installer/smoke/<NN>.sh` (phase ordinal; `vz-ai-stack.sh test <NN>`). **Prove the REAL path with a LiteLLM usage delta** — capture the scoped key's request count before/after a tiny run (web: a real UI/model call; batch: a 2–5-agent step). "Exited 0" / "HTTP 200" alone is NOT a pass (catches the literal-placeholder-key 401 class).

### 2F. Docs + tutorial + drift sweep (ONCE, after services land — Prompt 6)
Update every count/list location; **note that prose docs (COMPONENTS/HANDOFF/ARCHITECTURE) have NO automated guard** → Prompt 6 does an explicit `grep` audit for stale counts (don't rely on a gate that won't fire):
- `COMPONENTS.md`, `HANDOFF.md`, `DOCTOR.md` (§ per new check), `INSTALL.md`, `ARCHITECTURE.md`, `DEPENDENCIES.md`, `PORTS.md` (web-app rows), `ALTERNATIVES.md` (**ADD** rows for these 5 — no SwarmClaw/sim row exists today; this is an add, not an update), `ATTRIBUTION.md` (5 licenses: 3 Apache-2.0, 2 MIT), `CHANGELOG.md`.
- `EXPLORE.html`: add 5 `SERVICES` objects; the subtitle auto-derives from `SERVICES.length`, but a **hardcoded count lives in a comment ~L815/820** — update that. Browser load must show no `console.warn` (tier sums == length).
- `TUTORIAL.md`: opt-in list + check count + a short "agent-swarm sims" lesson (the 0a table + the M4 ceiling + the Phoenix watch-surface). Then `python3 installer/lib/build_tutorial_html.py` and confirm `--check` exits 0. **Never hand-edit the `<!-- ACTS -->` block.**
- `vz-ai-stack.sh`: opt-in-extras help strings (~2 spots) **and the `start`/`stop`/`run` dispatch table** (shared file — serial edit).
- **Drift guards that DO fire:** `config_validate` (YAML), `build_tutorial_html.py --check`, EXPLORE `SERVICES.length` self-audit, checks 16/45/53. Plus an **explicit `aliases.tsv` IP+port uniqueness census** in Prompt 6 (config_validate does NOT check this).

### 2G. E2E (real-user perspective — SOUL §5)
- **Batch (OASIS/MetaGPT/AgentScope-lib):** run a real minimal sim; confirm role/agent artifacts + a **Phoenix trace** + the scoped key's **usage delta**.
- **Web (AI Town/ChatDev/AgentScope-Studio):** Playwright over `http://localhost:<host_port>` (file:// blocked) — UI loads, a swarm/world runs, a model reply flows through LiteLLM (Phoenix trace), hostname bridge resolves.

### 2H. Gates & process
Worktree for all edits (§25); **operate/doctor the live stack from MAIN only** (bind-mount breakage — [[feedback_worktree_breaks_live_stack]]); commit from the worktree, **doctor-green verification from MAIN**. §24 council on this plan (done), each implementation, the final PR. **DoD:** full `doctor` green from MAIN, smoke pass (usage-delta), e2e per tool + Phoenix trace, drift guards pass + prose-grep clean, CHANGELOG, council sign-off, then pull→commit→merge→push.

---

## 3. Per-service strategy

### 3.1 OASIS — Phase 34, check 59 *(Wave 1)*
- **Host venv** (`uv venv oasis/.venv && uv pip install camel-oasis`), `oasis/sims/` workspace, `bin/oasis` wrapper (key + `OPENAI_BASE_URL=http://127.0.0.1:4000/v1`).
- **LLM (⚠️ prove):** route OASIS's agents via CAMEL `ModelFactory.create(model_platform=ModelPlatformType.OPENAI_COMPATIBLE, url="http://127.0.0.1:4000/v1", api_key=<env>, model_type="local-gemma4")` — verify it's wired through OASIS's agent construction (quickstart defaults to OpenAI), proven by a **usage delta** on the scoped key.
- Doctor 59 = venv + `import oasis` + key valid (skip-clean). Smoke 34 = ~5-agent step loop with a usage delta. Docs state 1M-capability vs M4 ceiling. `oasis/sims/` is **data** (cleanup hard-exclude; not gitignored).

### 3.2 MetaGPT — Phase 32, check 57 *(Wave 1; easiest)*
- **Host venv** (`uv pip install metagpt`), `metagpt/workspace/` (data; cleanup-excluded), `bin/metagpt` wrapper.
- **LLM (⚠️ prove indirection):** write `~/.metagpt/config2.yaml` with `llm:{api_type:"openai", base_url:"http://127.0.0.1:4000/v1", model:"local-gemma4", api_key:"${METAGPT_LITELLM_KEY}"}`. **Verify MetaGPT's loader expands `${VAR}`** (if not, the wrapper writes the resolved key to a 0600 runtime config) — proven by a real role-output run with a usage delta.
- Doctor 57 = venv + `import metagpt` + key valid. Smoke 32 = trivial `metagpt "…"` emits a role artifact via LiteLLM (usage delta).

### 3.3 AgentScope — Phase 33, check 58 *(Wave 2)*
- **Host venv** (`uv pip install agentscope`, Py3.11+) `bin/agentscope` wrapper. **Optional Studio** (`examples/web_ui`, pnpm/Vite) → containerized web app on host **5275** (IP §7), labeled, hostname `agentscope`, **doctor/smoke conditional on Studio-enabled**.
- **LLM (⚠️ verify key):** OpenAI-compatible model config `base_url` → `http://127.0.0.1:4000/v1` (lib) / `http://litellm:4000/v1` (Studio container). Find the exact config key in docs.agentscope.io — don't assume.
- Doctor 58 = venv + import + key (+ Studio :5275 200 if enabled). Smoke 33 = 2-agent exchange, usage delta.

### 3.4 AI Town — Phase 36, check 61 *(Wave 2; heaviest — gated on Prompt 5a feasibility)*
- **Container** (Docker Compose: Convex backend :3210, frontend :5173→host **5273**, dashboard :6791). Self-contained → `ai-stack.bridge-exempt=true` on the containers that can't join the bridge; reach LiteLLM via `host.docker.internal:4000` + `engine_addhost_args`.
- **`services.yml` `type: compose` + stable `project:` name** (so check 53's census sees it — its only signal here). **Caps** per service. **Convex is a STATEFUL DB:** dedicated `data/aitown/` dir; teardown = `docker compose down` (**no `-v`**) by default, `-v` only on `--nuke`; a **tested restore**. Mirror [[project_fleet_durability]].
- **Embeddings:** confirm whether embeddings route through LiteLLM or stay on Ollama `mxbai-embed-large` — if Ollama, **pull it as a precondition** and document the untracked path. Don't leave it implicit.
- Hostname `aitown` → **frontend** (5273). Doctor 61 = compose project healthy + fe 200. Browser e2e: town renders, characters move/chat, model call via LiteLLM (Phoenix trace).

### 3.5 ChatDev — Phase 35, check 60 *(optional / on-demand)*
- **⚠️ Verify ChatDev 2.0 is genuinely a web app** (Vue fe :5173→host **5274** + backend :6400) and not still a CLI with a wrapper — if CLI, make it a **host venv** like the others. If web: containerize, on `ai-stack` net, caps.
- **LLM ✅:** `.env` `API_KEY=${CHATDEV_LITELLM_KEY}`, `BASE_URL=http://litellm:4000/v1`.
- Hostname `chatdev` → **frontend** (5274) unless the SPA is proven served from :6400. Doctor 60 = entry surface 200 + key. Smoke 35 = a "build X" kickoff with a **usage delta** (not just 200). Browser e2e.

---

## 4. Sequencing & parallelization

- **Waves:** W1 = OASIS, MetaGPT → W2 = AgentScope, AI Town (after Prompt 5a) → optional ChatDev. Build a wave, integrate (Prompt 6), verify (Prompt 7), council (Prompt 8), then next wave. Lets you play after W1.
- **Parallel-safe (per service, own worktree):** phase script, `bin/<svc>`/`bin/start-<svc>`, doctor check, smoke — file-disjoint.
- **Serialized (shared files — Prompt 6, once per wave):** `services.yml`, `aliases.tsv`, **`vz-ai-stack.sh` (opt-in help + start/stop/run dispatch)**, all of §2F docs, the single `CHANGELOG` entry.
- **Reserved (re-verify with `ls` before writing):** phases **32–36**, checks **57–61**, smoke **32–36**, loopback IPs §7.

---

## 5. Risks & rollback

| Risk | Mitigation |
|---|---|
| Containerizing libs (orig. plan) = friction + bind-drift | **C1 fix:** host uv venvs for the 3 libs (mirror Phase 06/26); container only web apps |
| Host-venv routing wrong (`litellm:4000` unreachable from host) | Use `http://127.0.0.1:4000/v1` for host tools |
| :5173 triple collision | Host-port reassignment (§7) |
| AI Town/Convex self-host + local routing may not work | **Prompt 5a feasibility pre-check BEFORE building Phase 36** |
| Convex statefulness / data loss | `data/aitown/`, `compose down` no-`-v`, `--nuke` gate, tested restore, caps |
| Local inference ceiling | Default `local-gemma4`; document; cloud-route opt-in; Phoenix to watch throughput |
| Disk (images) | Host venvs remove 3 images; web images multi-stage < ~800 MB; sim workspaces = data |
| LiteLLM routing unproven (OASIS/AgentScope/MetaGPT) | Smoke requires a **usage delta**, not just success |
| Doc drift (prose has no auto-guard) | Prompt 6 explicit `grep` audit + the guards that do fire |
| Parallel-worktree IP/ordinal race | Pre-assigned §7 + `ls`/`aliases.tsv` census before write |
| Running stack from worktree | Edit in worktree; operate/doctor from MAIN |
| Teardown | host venvs: `rm -rf <svc>/.venv` + unstamp; web: `bin/start-<svc>.sh uninstall` (`compose down`, no `-v`); data preserved unless `--nuke`; nothing touches core |

---

## 6. Associated prompts

> Each is self-contained and **carries the constitution** (SOUL §1–25; propagate per §21). Feed 1–5 to
> `sre-engineer`/`backend-engineer` subagents (per service, parallel, each its OWN worktree). 6–9 run after a
> wave's per-service code lands. Manager integrates. **Wave 1 = Prompts 1+3; Wave 2 = 2, then 5a→5; ChatDev (4) optional.**

### Prompt 0 — Orchestrator setup
```
Add opt-in agent-swarm-sim services to ~/ai-stack per
doc/specs/2026-06-23-agent-sim-platforms-install-plan.md. Constitution doc/SOUL.md §1–25 (verify don't
assume, hypothesis-first, validate every step, e2e from the real user's view, worktree §25, council §24).
OPT-IN (never edit install_all_phase_order), LLM via LiteLLM with SCOPED keys (never master), loopback,
reversible, observable in Phoenix. BLOCKING first step: `ls installer/phases installer/doctor/checks
installer/lib/aliases.tsv` and confirm phases 32–36 / checks 57–61 / the §7 loopback IPs are still free
(re-pick if a parallel session took one). Two archetypes: HOST VENV (MetaGPT/OASIS/AgentScope-lib — mirror
Phase 06/26, bin/<svc> wrapper, route http://127.0.0.1:4000/v1, no container/port/hostname) vs CONTAINER
WEB APP (ChatDev/AI Town/AgentScope-Studio — mirror Phase 28, caps, loopback, hostname). Build per-service
in parallel worktrees; edit shared files (services.yml, aliases.tsv, vz-ai-stack.sh, docs) ONCE per wave.
Operate/doctor the live stack from MAIN only.
```

### Prompt 1 — OASIS (Phase 34 / check 59) [Wave 1; sre-engineer, own worktree]
```
Constitution applies (SOUL §1–25; subagent per §21). Add OASIS (camel-ai/oasis, Apache-2.0) as OPT-IN
Phase 34, archetype = HOST VENV batch sim (mirror installer/phases/06_documents.sh + 26_mempalace.sh +
bin/mempalace; NOT a container). DO: `uv venv oasis/.venv` + `uv pip install camel-oasis`; assert arm64;
oasis/sims/ workspace; bin/oasis wrapper that sources .env, exports OASIS_LITELLM_KEY +
OPENAI_BASE_URL=http://127.0.0.1:4000/v1, runs a given sim script. Mint SCOPED key OASIS_LITELLM_KEY
(models local-gemma4 + 2 *-sub). CRITICAL+VERIFY (quickstart defaults to OpenAI): route OASIS agents via
CAMEL ModelPlatformType.OPENAI_COMPATIBLE url=http://127.0.0.1:4000/v1 — PROVE a multi-agent step actually
hits the scoped key (check its usage counter delta), not just that import works. services.yml entry
(consumes_env, help: note 1M-capability vs M4 concurrency ceiling + Phoenix http://phoenix:6006). Add a
`run oasis` verb. doctor 59 = venv + `import oasis` + key lists models (skip-clean, grep '^200$',
litellm_db_down-gated). smoke 34 = ~5-agent step loop with a LiteLLM USAGE DELTA. Ensure oasis/sims is NOT
gitignored and is hard-excluded in installer/lib/cleanup* (it's data). VERIFY from MAIN: install oasis,
`run oasis -- <tiny sim>`, `test 34`, `doctor` check 59 green, Phoenix shows the trace. Report the exact
CAMEL wiring + the usage-delta proof. No shared-file/doc edits.
```

### Prompt 2 — MetaGPT (Phase 32 / check 57) [Wave 1; sre-engineer, own worktree]
```
Constitution applies. Add MetaGPT (FoundationAgents/MetaGPT, MIT) as OPT-IN Phase 32, archetype = HOST VENV
batch (mirror Phase 06/26 + bin/mempalace). DO: `uv pip install metagpt` into metagpt/.venv; assert arm64;
metagpt/workspace/ (data, cleanup-excluded, not gitignored); bin/metagpt wrapper. Mint SCOPED METAGPT_
LITELLM_KEY. Write ~/.metagpt/config2.yaml: llm:{api_type:"openai", base_url:"http://127.0.0.1:4000/v1",
model:"local-gemma4", api_key:"${METAGPT_LITELLM_KEY}"}. VERIFY MetaGPT's config loader actually EXPANDS
${VAR} — if it stores the literal placeholder (→ 401), have the wrapper write the resolved key to a 0600
runtime config instead (never commit it). PROVE with a real role-output run that hits LiteLLM (usage delta).
services.yml entry + `run metagpt` verb + Phoenix note. doctor 57 = venv + `import metagpt` + key valid
(skip-clean). smoke 32 = `metagpt "build a CLI todo app"` emits a role artifact via LiteLLM (usage delta).
VERIFY from MAIN. Report the config2.yaml (key redacted) + whether ${VAR} expanded + usage-delta proof.
No shared/doc edits.
```

### Prompt 3 — AgentScope (Phase 33 / check 58) [Wave 2; sre-engineer, own worktree]
```
Constitution applies. Add AgentScope (agentscope-ai/agentscope, Apache-2.0, Py3.11+) as OPT-IN Phase 33,
archetype = HOST VENV lib + OPTIONAL Studio web app. DO: `uv pip install agentscope` into agentscope/.venv;
bin/agentscope wrapper (key + OPENAI_BASE_URL=http://127.0.0.1:4000/v1). VERIFY the exact AgentScope model-
config key for an OpenAI-compatible base_url (docs.agentscope.io — do NOT assume) and PROVE a 2-agent
exchange hits the scoped key (usage delta). Mint AGENTSCOPE_LITELLM_KEY. IF you enable Studio
(examples/web_ui): containerize it (mirror Phase 28), host port 5275→container default, IP 127.0.10.<§7>,
on ai-stack net (route http://litellm:4000/v1), --memory/--cpus caps, label managed+phase=33, aliases.tsv
row `agentscope 127.0.10.<N> http 5275 <cport> 33 agentscope` → frontend; doctor 58 ALSO probes :5275/ —
but make the Studio doctor/smoke CONDITIONAL on a Studio-enabled flag (lib-only install must pass). doctor
58 = venv + import + key (+ Studio 200 if enabled). smoke 33 = 2-agent exchange, usage delta. VERIFY from
MAIN; report whether Studio was enabled + the exact model-config snippet + usage-delta. No shared/doc edits.
```

### Prompt 4 — ChatDev (Phase 35 / check 60) [OPTIONAL; sre-engineer, own worktree]
```
Constitution applies. Add ChatDev (OpenBMB/ChatDev 2.0, Apache-2.0) as OPT-IN Phase 35. FIRST verify the
2.0 shape: is it genuinely a web app (Vue fe + Python backend) or still a CLI (`run.py`)? If CLI → make it a
HOST VENV like Prompts 1–3 (no container). If web app: containerize fe (host 5274→container 5173) + backend
(:6400) on the ai-stack net with --memory/--cpus caps; `uv sync` + npm. Mint SCOPED CHATDEV_LITELLM_KEY;
in-container .env API_KEY=${CHATDEV_LITELLM_KEY}, BASE_URL=http://litellm:4000/v1. aliases.tsv row pointing
at the BROWSER UX surface (the frontend 5274) unless you PROVE the SPA is served from :6400. label
managed+phase=35. services.yml (open_url, Phoenix note). doctor 60 = entry surface 200 + key. smoke 35 =
a "build X" kickoff with a LiteLLM USAGE DELTA (not just 200). Browser e2e (Playwright) over
http://localhost:5274. VERIFY from MAIN; report archetype decision + ports + e2e evidence + usage delta.
No shared/doc edits.
```

### Prompt 5a — AI Town FEASIBILITY pre-check (BLOCKING, before Prompt 5) [sre-engineer, throwaway dir]
```
Constitution applies. BEFORE any Phase 36 work, prove AI Town (a16z-infra/ai-town) can self-host with LOCAL
LLM routing — its LLM calls run inside Convex action functions and the base URL is set in the Convex env,
and self-hosted Convex is its own setup. In a THROWAWAY dir (NOT a worktree, NOT in ~/ai-stack), clone +
`docker compose up -d` per its README, point the OpenAI-compatible base URL at host.docker.internal:4000
(LiteLLM) with a scoped key, and confirm: (1) the self-hosted Convex backend starts, (2) the frontend
loads, (3) a character action makes a model call that LANDS on LiteLLM (usage delta / Phoenix trace),
(4) embeddings path (LiteLLM vs Ollama mxbai-embed-large) is identified. Report GO/NO-GO + the exact env
wiring + the compose project name. If NO-GO, recommend dropping Phase 36 or an alternative. Tear the
throwaway dir down. Do NOT touch ~/ai-stack.
```

### Prompt 5 — AI Town (Phase 36 / check 61) [Wave 2; only if 5a = GO; sre-engineer, own worktree]
```
Constitution applies. Add AI Town as OPT-IN Phase 36 using the 5a-proven wiring. Docker Compose stack
(Convex be :3210, fe :5173→host 5273, dash :6791). Self-contained → label the off-bridge containers
ai-stack.bridge-exempt=true (only those that truly can't join; document why) + ai-stack.managed=true +
ai-stack.phase=36; reach LiteLLM via host.docker.internal:4000 WITH engine_addhost_args (colima/podman).
services.yml `type: compose` + a STABLE `project:` name (so check 53's census sees the stack — its only
signal here). --memory/--cpus caps per service. Convex is STATEFUL: data/aitown/ dir; teardown =
`docker compose down` (NO -v) by default, `-v` ONLY on --nuke; write + RUN a restore test (mirror
doc/specs fleet-durability). Embeddings: route via LiteLLM if possible, else pull Ollama mxbai-embed-large
as a precondition + document it. SCOPED AITOWN_LITELLM_KEY via {env:} (never literal). aliases.tsv
`aitown 127.0.10.<§7> http 5273 5173 36 aitown` → frontend. doctor 61 = compose project healthy + fe 200
(skip-clean). smoke 36 = stack up + fe 200 + a model call usage delta. Browser e2e: town renders,
characters move/chat, LiteLLM trace in Phoenix. VERIFY from MAIN; report compose file, project name, ports,
data/teardown/restore story, e2e evidence. No shared/doc edits.
```

### Prompt 6 — Registry + docs + tutorial + drift sweep (ONCE per wave) [techlead or manager]
```
Constitution applies. The wave's phase scripts + doctor checks + smoke + services.yml entries exist. Make
the platform COHESIVE; edit SHARED files serially:
 - vz-ai-stack.sh: add the wave's services to the two opt-in-extras help strings AND the start/stop/run
   dispatch table. Confirm install_all_phase_order() UNCHANGED.
 - installer/lib/aliases.tsv: census existing rows for the true max 127.0.10.x BEFORE assigning; ensure the
   web services' rows are unique on IP AND host_port (config_validate does NOT check this — do it explicitly).
 - doc/: COMPONENTS.md, HANDOFF.md, DOCTOR.md (§ per new check), INSTALL.md, ARCHITECTURE.md, DEPENDENCIES.md,
   PORTS.md (web rows), ALTERNATIVES.md (ADD new rows — no sim/SwarmClaw row exists; not an update),
   ATTRIBUTION.md (licenses), CHANGELOG.md. These prose docs have NO auto drift-guard → run an explicit
   `grep -rn "<old service count>\|<old check count>" doc/` audit and fix every stale count.
 - doc/EXPLORE.html: add the SERVICES objects; update the hardcoded count COMMENT (~L815/820) — the subtitle
   auto-derives; load in a browser and confirm zero console.warn.
 - doc/TUTORIAL.md: opt-in list + check count + a short "agent-swarm sims" lesson (the 0a which-tool table +
   M4 ceiling + Phoenix watch-surface). Then `python3 installer/lib/build_tutorial_html.py` and confirm
   `--check` exits 0. NEVER hand-edit the ACTS block.
VERIFY: config_validate passes; build_tutorial_html.py --check exits 0; EXPLORE loads clean; grep finds no
stale counts. Report the diff summary + every guard run green.
```

### Prompt 7 — End-to-end verification (real-user perspective) [qa-test-engineer]
```
Constitution applies (SOUL §5 — validate from the real user's view, not a green log). From MAIN, stack
running, per service installed this wave:
 - OASIS: a ~5–10 agent social step loop completes via LiteLLM; capture the run + the scoped key's USAGE
   DELTA + the Phoenix trace; note throughput.
 - MetaGPT: a real "build X" run → role artifacts; usage delta + Phoenix trace.
 - AgentScope: a 2-agent exchange (Studio UI if enabled) → usage delta + trace.
 - AI Town: browser (Playwright) → town renders, characters move/chat, model call via LiteLLM (trace).
 - ChatDev (if built): browser → fe loads, a "build X" run kicks off, usage delta + trace.
For each: PASS/FAIL with the artifact/screenshot + the usage-delta + the Phoenix trace as proof. Then full
`vz-ai-stack.sh doctor` from MAIN → ALL green (new checks included; 53 sees the web/compose containers).
Flag anything that only "looked" done.
```

### Prompt 8 — §24 review council (on the implementation) [adversarial + architect + qa/infra + PM]
```
Constitution applies. Independently review the wave's implementation before merge (SOUL §24.2/24.4):
 - ADVERSARIAL (reviewing-engineer): secrets/master-key leak? a literal key in a config (did ${VAR} expand)?
   0.0.0.0 bind? a container missing the managed label / a compose stack missing services.yml project: (→
   invisible to 53)? install_all changed? a smoke that proves nothing (no usage delta)?
 - ARCHITECT (techlead): archetype correct (host venv vs container)? host-venv routing 127.0.0.1:4000?
   AI Town engine_addhost_args + bridge-exempt scope? hostname → frontend not backend? OASIS/AgentScope
   routing PROVEN (usage delta)?
 - QA/INFRA (sre): reversibility (venv rm / compose down no-v; data preserved; tested restore)? caps present?
   doctor-green-from-MAIN? drift guards + prose grep clean? disk?
 - PM: opt-in only + matches "swarm-sim experiment, not prod" intent; the which-tool table + M4 ceiling +
   Phoenix watch-surface are present and discoverable.
Debate to consensus; report decision + debate points + every must-fix. Verify any single flagged claim.
```

### Prompt 9 — Commit / PR [manager]
```
Constitution applies ([[feedback_always_pull_commit_merge_push]]). After council consensus + doctor green
FROM MAIN: from the worktree, stage the wave's installer/phases, installer/doctor/checks, installer/smoke,
bin/*, services.yml, installer/lib/aliases.tsv, doc/*, vz-ai-stack.sh, CHANGELOG.md. Commit (Co-Authored-By
trailer) + open a PR summarizing the services, the opt-in/scoped-key/loopback/Phoenix posture, the M4
concurrency caveat, and the council sign-off. Commit/push from the worktree; run the final doctor-green
verification FROM MAIN. Then pull→merge→push. Never operate the live stack from the worktree.
```

---

## 7. Pre-assigned ports & loopback IPs (web apps only; re-verify max before write)

| Service | Host port(s) | Loopback IP | Hostname |
|---|---|---|---|
| AgentScope Studio (if enabled) | 5275 → 5173 | 127.0.10.17 | `agentscope` |
| ChatDev (if web) | fe 5274 → 5173; be 6400 | 127.0.10.18 | `chatdev` (→ fe) |
| AI Town | fe 5273 → 5173; be 3210; dash 6791 | 127.0.10.19 | `aitown` (→ fe) |

> IPs tentative (current `aliases.tsv` max ≈ `127.0.10.16`); **census the file at write-time** and re-pick on collision. MetaGPT/OASIS/AgentScope-lib are host venvs → **no IP, no port, no hostname**. Verify host ports free vs `doc/PORTS.md`.

## 8. Open decisions (defaults chosen; override anytime)
1. **Wave 1 = OASIS + MetaGPT** (play soonest). Override: "all five now" — prompts execute as-is.
2. **ChatDev optional** (weakest "swarm" fit). Override: include in Wave 2.
3. **Default model `local-gemma4`** in every scoped key; swap to `*-sub`/cloud per tool for bigger swarms (metered).
4. **Host venvs for the 3 libs; containers for web apps** (council C1). Override only with a reason that beats the Phase 06/26 precedent.
```
