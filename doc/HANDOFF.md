# Handoff — for the next agent

If you're a Claude (or human) picking this up cold, read this **first**. It
gets you to "I know what's done, what's known-flaky, and what to do next"
in fifteen minutes.

---

## 0. Snapshot — state as of 2026-05-31

| Property | Value |
|---|---|
| Host | Mayssam Sayyadian's MacBook Pro M4 24 GB, macOS Sequoia, OrbStack docker, Homebrew, Python 3.13, brew bash 5.x |
| Stack root | `~/ai-stack/` (= `/Users/mayssam.sayyadian/ai-stack/`) |
| Entry point | `bash install.sh` (and the `stack` alias = `bash install.sh`) |
| Total phases | **25** (00, 00s, 00n, 00v, 01, 01h, 02, 03, 04, 04f, 04g, 05, 06, 07, 08, 09, 10, 11, 12, 13, 14, 15, 16, 17, 18) |
| Default phase order | `00 00s 00n 00v 02 03 01 01h 04 04f 04g 05 06 07 08 09 10 11 12 13 14 15 16 17 18` (note: 03 before 01 — see §3.1) |
| Total services in `services.yml` | **31** (added `rlm`, Phase 18) |
| Total doctor checks | **31** (added `hermes_routing` #30, `rlm_install` #31) |
| Docs + ingestion layout | All docs now live under `doc/` (except `README.md` + `CHANGELOG.md` at repo root). Ingestion drop dirs are `ingestor/inbox` + `ingestor/processed` (drop files into `~/ai-stack/ingestor/inbox`); there is NO top-level `docs/` dir anymore. |
| Last verified doctor pass | 2026-05-30 cycle-2 = 30/30 green (fresh). 2026-05-31 added Phase 18 (RLM) + check 31, verified individually → a fresh `install all` is now **31/31**. ⚠️ A long-idle live stack can show 2 OpenShell-exec checks (25 pi-v1, 30 hermes) failing — that's the §2.1 relay idle-timeout, NOT a regression; a reset clears it. |
| Last verified cold install | 2026-05-31 — `reset --confirm hard --yes` → `install all` → `doctor` 31/31 green, end-to-end (incl. Phase 18 RLM) |

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

**Memory pointers** (auto-loaded in this user's Claude sessions, see `~/.claude/projects/-Users-mayssam-sayyadian-ai-stack/memory/MEMORY.md`):
- `feedback-autonomous-execution.md`
- `feedback-background-tasks.md`
- `project_pi_phase15.md`
- `project_doctor_count.md` (was 26, now 31 — update if you add checks)

---

## 1. What's working (verified live)

### Inference + observability
- **LiteLLM** (`http://litellm:4000`) — virtual-key gateway, Postgres-backed key store, Phoenix OTLP export, custom JSONL trace logger, in-built guardrails (denied-words + secrets regex). On `ai-stack` docker network.
- **Phoenix** (`http://phoenix:6006`) — observability UI + OTLP collector. Project `ai-stack` for all traces.
- **Ollama** — host brew service. Models pulled: `gemma4:e4b`, `qwen3.6:27b-q4_K_M`, `nomic-embed-text`, `hf.co/LiquidAI/LFM2.5-8B-A1B-GGUF:Q4_K_M`.

### Storage
- **FalkorDB** (`redis://falkordb:6379`, browser `http://falkordb-ui:3000`) — graph DB on Redis protocol.
- **Qdrant** (`http://qdrant:6333`) — vector DB.
- **Honcho** (`http://honcho:8000`) — memory store. Brings up its own Postgres (`honcho-database-1` on `host.docker.internal:5432`) which LiteLLM ALSO uses for the virtual-key Prisma DB (DATABASE_URL=`postgresql://postgres:postgres@host.docker.internal:5432/litellm`).

### Agent runtimes
- **OpenShell** (brew service, gateway `:17670`) — sandbox host. Two sandboxes:
  - **hermes-fleet-v1** — 7 Hermes profiles (cos, software_engineer, researcher, creator, reviewer, data_analyst, ops). Installed via PyPI `hermes-agent` v0.15.2 inside `/sandbox/.venv` (uv-managed venv inside the sandbox).
  - **pi-v1** — Pi (`@earendil-works/pi-coding-agent`) installed from pre-staged tarball at `pi/pi-bootstrap.tar.gz` to bypass scoped-npm-URL proxy issue. Auth via `PI_LITELLM_KEY` virtual key scoped to `[local, local-heavy, local-lfm2]`.

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
- **Hermes** — invoke inside hermes-fleet-v1: `openshell sandbox exec -n hermes-fleet-v1 -- hermes profile use <name>`. **Now genuinely routes to LiteLLM** (verified `hermes --profile hermes_cos -m local -z` → `PONG`). Previously it silently never reached local models (dead `llm.*` config) — see §2.6.
- **Lumen** (Phase 16) — Ory's local code semantic-search MCP. Binary at `vendor/lumen/lumen-0.0.41-darwin-arm64`. Wrapper `bin/lumen`. Embeddings via `ordis/jina-embeddings-v2-base-code` on Ollama. Stdio MCP (no daemon).
- **ACE** (Phase 17, NEW 2026-05-29) — Stanford's Agentic Context Engineering. Cloned at `ace/`, uv venv, wrapper `bin/ace`. Routes via LiteLLM through `OPENAI_BASE_URL=http://litellm:4000/v1`. ACE_LITELLM_KEY virtual key scoped to local models. **`ace appworld` requires explicit confirmation** (executes model-generated tool calls on host).
- **Unsloth Studio** (Phase 14) — daemon on `:8898` for local model fine-tuning. PID file at `installer/state/unsloth.pid`.
- **HALO** (Phase 11) — installs `halo-engine` (exposes `bin/halo`), routes via LiteLLM (local default), agents-SDK cloud trace export disabled. CAVEAT: HALO wants OTel-format traces (not our custom `traces/litellm.jsonl`) and its openai-agents SDK uses the Responses API, so full analysis on LOCAL models is experimental.
- **RLM** (Phase 18, NEW 2026-05-31) — Recursive Language Models (`rlms` pip lib, `bin/rlm` wrapper + `rlm/run_rlm.py` runner). Model recursively calls itself over long context via a REPL that runs in a DOCKER SANDBOX (`python:3.11-slim`, not the host). Routes via LiteLLM + `RLM_LITELLM_KEY`, works on local models. It's the substrate HALO is built on.
- **Blaxel CLI** (Phase 12) — installed only.

### `stack` CLI subcommands (`install.sh`)
- `install [phase|all]` — run a phase or all phases
- `prepare-sudo` — sudo'd /etc/hosts + lo0 + launchd plist setup (idempotent)
- `verify` — runtime probes (lo0, /etc/hosts, host-gateway, end-to-end routing). Cheap, < 10s.
- `status` — declared vs actual + ownership table
- `doctor [<filter>]` — 31 checks, per-check auto-fix
- `adopt <svc>` — claim a foreign container with docker-cp backup
- `start <svc>` / `stop <svc>` — invoke `bin/start-<svc>.sh` / `bin/stop-<svc>.sh` (added 2026-05-29 for deerflow)
- `<svc> start` / `<svc> stop` — reverse-form shortcut (e.g. `stack deerflow start`)
- `apply-restarts` — drain queued container recreates
- `logs <svc> [-f]` — docker logs
- `reset --confirm soft|hard|nuke` — tiered destructive resets. `hard` is now COMPLETE: deletes OpenShell sandboxes, tears down all compose projects (honcho/deerflow/autofyn/hermes-workspace incl. volumes like `honcho_redis-data`), and removes managed containers + the `ai-stack` network. Add `--yes`/`-y` for non-interactive (sets `AI_STACK_ASSUME_YES=1`; nuke's typed gate stays manual). PRESERVES ollama + models, docker images, `.env`, `/etc/hosts` ai-stack block.

---

## 2. Known-flaky (recovery dances ready)

These bite repeatedly. Each has a tested workaround.

### 2.1 OpenShell relay times out under idle
**Symptom:** `openshell sandbox exec` returns `× status: DeadlineExceeded, message: "relay open timed out"`. Affects pi-v1 AND hermes-fleet-v1 simultaneously. Happens after several hours of idle.

**Recovery:**
```bash
brew services restart openshell
# This puts BOTH sandboxes into "Error" phase. You must delete+recreate:
openshell sandbox delete pi-v1 2>/dev/null
openshell sandbox delete hermes-fleet-v1 2>/dev/null
bash ~/ai-stack/install.sh install 04   # recreates hermes-fleet-v1
bash ~/ai-stack/install.sh install 04f  # reinstalls Hermes in it
bash ~/ai-stack/install.sh install 15   # recreates pi-v1 + reinstalls Pi
```

**Why this hasn't been fixed in-code:** the relay timeout is upstream OpenShell. A doctor auto-fix that does this dance behind a y/n prompt would be the right move (~50 LOC), but not landed yet.

### 2.2 OpenShell `sandbox create` hangs (≠ relay timeout)
**Symptom:** `openshell sandbox create --from base` sleeps in state `S` indefinitely (no output, no progress). Different from 2.1 — gateway is up, port :17670 responds, but create RPC is stuck.

**Status: AUTO-RECOVERED IN-CODE (2026-05-30).** `installer/lib/openshell.sh::openshell_sandbox_ensure` runs `create` in the background, polls `sandbox get` for `Phase=Ready`, then kills the hung create CLI (which on macOS never returns even after Ready) and retries/escalates. Phases 04 and 15 use it. The old manual create-hang dance is no longer needed — this is handled automatically.

### 2.3 `openshell-docker` network missing
**Symptom:** `sandbox create` fails with `Docker responded with status code 404: failed to set up container networking: network openshell-docker not found`. Happens after `docker network prune` or a fresh OrbStack install. **Now patched defensively in Phase 04 itself (2026-05-30).** If you see it anyway:
```bash
docker network create openshell-docker
openshell sandbox delete hermes-fleet-v1 2>/dev/null  # clear errored record
bash install.sh install 04                            # will succeed now
```

### 2.4 DeerFlow CPU thrash (Pydantic crash loop)
**Symptom:** `docker stats deer-flow-gateway` shows ~340% CPU continuously even idle.

**Cause:** `deer-flow/config.yaml` `models:` block had only commented entries → Pydantic validator returns `None ≠ list` → 4 uvicorn workers crash on import → restart → repeat. **Fixed: Phase 10 now idempotently patches config.yaml + docker-compose.yaml + .env. Doctor check 28 catches regressions.**

### 2.5 LiteLLM `WARN[0000] The "LITELLM_MASTER_KEY" variable is not set`
**Cause:** deerflow's `scripts/deploy.sh` doesn't pass `--env-file`; compose looks for `.env` next to the compose file (`docker/.env`) for `${VAR}` substitution at parse time. **Fixed: `bin/start-deerflow.sh` exports `LITELLM_MASTER_KEY` from `~/ai-stack/.env` before invoking deploy.sh.** Use `stack start deerflow`, not `bash scripts/deploy.sh start` directly.

### 2.6 Hermes-agent v0.15.2 CLI drift — RESOLVED (2026-05-30)
**Original symptoms:** `hermes config set llm.openai_api_key …` → `ValueError: Invalid environment variable name: 'LLM.OPENAI_API_KEY'`; `hermes profile config <name> --set llm.model=…` → `invalid choice: 'config'`. Root cause: hermes-agent v0.15.2 has NO `llm.*` config namespace, so the old `llm.model`/`llm.openai_api_base`/`llm.openai_api_key` config was a dead no-op + a ValueError, and Hermes silently never reached local models.

**Status: RESOLVED.** Phase 04f now mints `HERMES_LITELLM_KEY`, adds a `litellm_proxy` endpoint to the hermes policy, and sets per-profile `model.default` + `model.provider=custom:litellm` + `providers.litellm.{base_url=http://host.docker.internal:4000/v1, api_key, model}`. Config rewritten for the real v0.15.2 schema; per-profile model + LiteLLM routing now wired and verified live (`hermes --profile hermes_cos -m local -z` → `PONG`).

### 2.7 status.sh used to mislabel compose services as `absent`
**Fixed 2026-05-29** via `ownership_compose()` + `project:` / `process_pattern:` overrides in services.yml. If you see it again, check that the `services.<name>.project:` field matches the actual compose project name (kebab-case).

---

## 3. Recent session deltas (2026-05-29 → 2026-05-30)

Read **CHANGELOG.md top to bottom** for full reasoning. Summary of major changes:

### 3.1 install.sh cold-path phase ordering (2026-05-30)
**Problem:** `install all` from cold (post hard reset) failed at Phase 01 because LiteLLM's Prisma migration hangs without Postgres, which doesn't exist until Phase 03.

**Fix:** Phase array reordered to `… 02 03 01 01h …`. Phase 03 (Honcho/Postgres) runs before Phase 01 (LiteLLM). Also: `bin/start-litellm.sh` now does a TCP check on `:5432` and fails-loud BEFORE starting LiteLLM (saves the 60s hang).

**File:** `install.sh:325` (default phase array), `install.sh:178` (usage), `bin/start-litellm.sh:55-72` (Postgres precheck).

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
- `install.sh` gained `cmd_start` / `cmd_stop` that dispatch to `bin/start-<svc>.sh` / `bin/stop-<svc>.sh` (falls back to `docker stop` if no script).
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
install.sh                      ← entry; bash 5+ gate; dispatches subcommands
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

### 5.6 install.sh adopt for compose services
`installer/lib/docker.sh::container_exists` is single-container-only. `install.sh adopt`, `stack stop`, and several doctor checks may not work cleanly on compose services. Cross-cutting cleanup follow-up.

### 5.7 Phoenix per-key tagging propagation
Unverified whether LiteLLM `tags` field propagates into Phoenix project name. Needs manual UI eyeball before promoting to a doctor check.

### 5.8 ACE pin file format
Phase 17 captures `ACE_PIN` SHA in `.env`. Should also be in a separate `installer/state/ace.pin` for visibility. Cosmetic.

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
11. **Cold install ordering: Phase 03 BEFORE Phase 01** (2026-05-30). LiteLLM needs Postgres from Honcho. Reordered in `install.sh:325`.
12. **`openshell-docker` network needed before Phase 04** (2026-05-30). Phase 04 now creates it defensively.
13. **OpenShell sandbox uses `/sandbox/.venv` uv venv internally.** Don't use `--user` or `--break-system-packages` for `pip install` inside — both fail in a venv. Plain `pip install` works.

---

## 7. From-scratch install (verified procedure)

```bash
# 1. One-time sudo prep (writes /etc/hosts ai-stack block + lo0 aliases + launchd plist)
sudo bash ~/ai-stack/install.sh prepare-sudo

# 2. Hard reset if there's prior state (add --yes / -y for non-interactive)
bash ~/ai-stack/install.sh reset --confirm hard --yes

# 3. Install everything (30–60 min depending on docker pulls)
bash ~/ai-stack/install.sh install all

# 4. Verify (31/31 expected)
bash ~/ai-stack/install.sh doctor
```

This canonical flow is VERIFIED end-to-end (31/31 doctor, 2026-05-31). OpenShell sandbox-create hangs are now auto-recovered in-code (§2.2), so step 3 should no longer stall there.

**If something still hangs at OpenShell sandbox create** (rare now — see §2.2), in a second terminal:
```bash
pkill -9 -f 'install.sh|openshell sandbox create'
rm -f ~/ai-stack/installer/state/.lock
brew services restart openshell ; sleep 5
openshell sandbox delete hermes-fleet-v1 2>/dev/null
openshell sandbox delete pi-v1 2>/dev/null
bash ~/ai-stack/install.sh install all   # resumes from where it left off
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
2. `stack doctor` — 31 checks, each with auto-fix offer.
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
| `install.sh` | Entry point, phase dispatcher, lock + bash5 gate |
| `services.yml` | Single source of truth: 31 services with type/enabled/path/port/project/process_pattern/etc. |
| `installer/lib/aliases.tsv` | Canonical alias table (alias, IP, protocol, host_port, container_port, phase, service_key) |
| `installer/lib/openshell.sh` | Hang-resilient OpenShell sandbox create. `openshell_sandbox_ensure` backgrounds `create`, polls `sandbox get` for `Phase=Ready`, kills the hung create CLI, retries/escalates. Used by Phases 04 + 15. |
| `installer/phases/NN_*.sh` | One per phase. `precheck()` → work → `stamp_mark` |
| `installer/doctor/checks/NN_*.sh` | One per failure mode (31 checks). Each defines `CHECKS+=(name)` + `<name>_diagnose` + `<name>_fix` |
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
| `doc/USER-GUIDE.md`, `doc/USER-GUIDE.html` | End-user onboarding (every service + 12 recipes) |
| `README.md` | Top-level entrypoint + Mayssam's constitution (stays at repo root) |

> **Layout note (2026-05-30):** All docs now live under `doc/` (this file is `doc/HANDOFF.md`) EXCEPT `README.md` + `CHANGELOG.md`, which stay at repo root.

---

## 13. Contact

Mayssam Sayyadian — `mayssam.sayyadian@veza.com`. Read [README.md § Operating principles](../README.md#operating-principles-mayssams-constitution-internalized) and the auto-loaded memories under `~/.claude/projects/-Users-mayssam-sayyadian-ai-stack/memory/` before engaging.
