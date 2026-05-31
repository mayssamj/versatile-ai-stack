# PORTS.md

Authoritative port and service map for `~/ai-stack`. Every claim here is cross-referenced against `installer/lib/aliases.tsv` (canonical IP table), `services.yml`, `bin/start-*.sh`, an `installer/phases/*.sh`, an `installer/doctor/checks/*.sh`, or a live `docker inspect` run on **2026-05-28**.

Sister doc: see [DEPENDENCIES.md](DEPENDENCIES.md) for topology, talks-to matrix, and sequence diagrams. Architecture rationale lives in [ARCHITECTURE.md](ARCHITECTURE.md).

> **Important** (2026-05-28). The port-free Mac URLs from the original alias
> design (`http://litellm`, `http://phoenix`, etc.) no longer apply.
> OrbStack collapses every `--publish 127.0.10.X:80:Y` mapping into one
> `*:80` wildcard listener so multiple HTTP services on host port 80
> all routed to the first registered container. Every HTTP service now
> publishes on its native container port; Mac and container URLs are
> identical: `http://litellm:4000`, `http://phoenix:6006`,
> `http://openwebui:8080`. See
> [CHANGELOG.md 2026-05-28 entry](../CHANGELOG.md) for the diagnosis.

---

## The `127.0.10.x` scheme

Every `ai-stack` service is reached by an **alias** (e.g., `litellm`,
`phoenix`, `qdrant`) that resolves to a unique `127.0.10.x` loopback IP
via the `/etc/hosts` block written by Phase 00·N. Container-to-container
traffic uses Docker's embedded DNS on the `ai-stack` bridge network so
the same alias works from inside any joined container.

Why `127.0.10.x`:
- **Still loopback** (127.0.0.0/8) — no LAN exposure, security story
  unchanged.
- **Distinct from `127.0.0.1`** — old tooling and pre-refactor containers
  that bind there don't interfere.
- **Per-alias unique IP** — each service has its own IP so the
  publish-IP is distinct even when many services use the same internal
  port (e.g., honcho-api and llm-guard both `8000`). The brief originally
  used this to bind everything on host port `80`; the 2026-05-28 patch
  walked that back to native ports because of the OrbStack `*:80`
  wildcard listener — see the note at the top of this doc.
- **Visually recognizable** — `10.` in the second octet flags ai-stack.

Phase 00·N's helper `lib/network.sh::hosts_ensure_block` is idempotent:
no-op if the block matches `aliases.tsv`, atomic write under `sudo`
otherwise. IPv4 only (no `::1` lines); see ARCHITECTURE.md § "What's in
/etc/hosts" for the marker format.

**lo0 binding is also required.** macOS does NOT auto-route `127.0.0.0/8`;
only `127.0.0.1` is on `lo0` by default. Phase 00·N runs
`lo0_ensure_aliases` (under `sudo`) to `ifconfig lo0 alias 127.0.10.X up`
for each row of `aliases.tsv`, and `lo0_install_persistence_plist` writes
`/Library/LaunchDaemons/com.ai-stack.loopback.plist` so the aliases
survive reboot. Without this, /etc/hosts resolves correctly but kernel
routing drops every packet. Doctor check 19 enforces it.

---

## At-a-glance table

Sorted by install phase, then alias. The canonical source for these rows is
`installer/lib/aliases.tsv` — if this table and the .tsv ever disagree, the
.tsv wins.

| Alias          | From Mac                    | From container             | Purpose                            | Phase | Default IP  |
|----------------|-----------------------------|----------------------------|------------------------------------|-------|-------------|
| `ollama`       | `http://ollama:11434`       | `http://ollama:11434`†     | Local models (brew on host)        | 01    | 127.0.0.1   |
| `litellm`      | `http://litellm:4000`       | `http://litellm:4000`      | LiteLLM OpenAI-compat proxy        | 01    | 127.0.10.1  |
| `phoenix`      | `http://phoenix:6006`       | `http://phoenix:6006`      | Phoenix UI + OTLP HTTP collector   | 01·H  | 127.0.10.2  |
| `phoenix-otlp` | `http://phoenix-otlp:4317`  | `http://phoenix:4317`      | Phoenix OTLP gRPC                  | 01·H  | 127.0.10.3  |
| `qdrant`       | `http://qdrant:6333`        | `http://qdrant:6333`       | Qdrant vector DB                   | 02    | 127.0.10.5  |
| `falkordb`     | `redis://falkordb:6379`     | `redis://falkordb:6379`    | FalkorDB graph (Redis RESP)        | 02    | 127.0.10.7  |
| `falkordb-ui`  | `http://falkordb-ui:3000`   | `http://falkordb:3000`     | FalkorDB browser UI                | 02    | 127.0.10.8  |
| `honcho`       | `http://honcho:8000`        | `http://honcho:8000`‡      | Honcho memory API                  | 03    | 127.0.10.6  |
| `hermes-gw`    | `http://hermes-gw:8642`     | `http://hermes-gw:8642`    | OpenShell L7 proxy (reserved)      | 04    | 127.0.10.11 |
| `llm-guard`    | `http://llm-guard:8000`     | `http://llm-guard:8000`    | LLM Guard scanner sidecar          | 04·G  | 127.0.10.12 |
| `openwebui`    | `http://openwebui:8080`     | `http://openwebui:8080`    | Open WebUI chat UI                 | 05    | 127.0.10.9  |
| `workspace`    | `http://workspace:3000`     | `http://workspace:3000`    | Hermes Workspace UI                | 05    | 127.0.10.10 |
| `docs-mcp`     | `http://docs-mcp:8765`      | `http://docs-mcp:8765`     | Docs MCP server                    | 06    | 127.0.10.4  |
| `autofyn`      | `http://autofyn:3400`       | `http://autofyn:3400`      | AutoFyn coding agent               | 07    | 127.0.10.13 |
| `paperclip`    | `http://paperclip:3100`     | `http://paperclip:3100`    | Paperclip orchestrator             | 08    | 127.0.10.14 |
| `unsloth`      | `http://unsloth:8898`       | `http://unsloth:8898`      | Unsloth Studio (fine-tuning UI)    | 14    | 127.0.10.16 |
| `pi` (sandbox) | `bin/pi` (no HTTP)          | n/a                         | Pi coding agent inside `pi-v1`     | 15    | (sandboxed) |
| `lumen` (CLI)  | `bin/lumen` (stdio MCP)     | n/a (subprocess per client) | Local code semantic search         | 16    | (no port)   |

† Ollama runs as a brew service on the host (not a container). From inside a container, `ollama:11434` resolves to the host's gateway IP via the `--add-host=ollama:host-gateway` flag baked into each consumer's `docker run`. Port `:11434` stays in the URL on both sides — the one HTTP-port-not-on-80 exception.

‡ Honcho's `api` and `deriver` containers are on multiple Docker networks (`honcho_default` + `ai-stack`). Cross-stack call sites use **fully-qualified DNS**: `http://litellm.ai-stack:4000/v1` (not `http://litellm:4000/v1`) to avoid Docker's unspec'd multi-network resolution order.

### Reserved-but-commented

`aliases.tsv` carries a commented-out row for `phoenix-otlp-http  127.0.10.15  http  4318  4318  01h  phoenix` ready to uncomment when a Phoenix/OTel client mandates OTLP/HTTP spec port 4318. `unsloth` occupies `127.0.10.16`. .17+ stays free for future services. **Pi** (Phase 15) does NOT get its own loopback alias — it runs inside the `pi-v1` OpenShell sandbox and reaches LiteLLM via `host.docker.internal:4000` from the sandbox VM.

### Services with no host port (CLI-only / pattern-only)

These appear in `services.yml` but have no alias because they have no listener:

| Service                       | Type             | Auth                                          |
|-------------------------------|------------------|-----------------------------------------------|
| `openshell`                   | openshell        | sandbox-local (no host port)                  |
| `hermes_fleet`                | hermes-profiles  | inside-sandbox only                           |
| `litellm_guardrails_builtin`  | litellm-feature  | piggybacks LiteLLM                            |
| `litellm_guardrails_secrets`  | litellm-feature  | piggybacks LiteLLM                            |
| `dual_llm_researcher`         | agent-pattern    | prompting convention only                     |
| `docs_ingestor`               | python-bg        | reads `LITELLM_MASTER_KEY` env                |
| `paperclip_honcho_plugin`     | paperclip-plugin | activated inside Paperclip UI                 |
| `remnic_hermes`               | pip-package      | installed-disabled                            |
| `byterover_cli`               | npm-global       | installed-disabled                            |
| `halo`                        | cli-only         | routes via LiteLLM (`bin/halo`)               |
| `rlm`                         | cli-only         | routes via LiteLLM (`bin/rlm`); REPL in Docker sandbox |
| `autoreason`                  | clone-only       | research artifact (disabled)                  |
| `blaxel_cli`                  | cli-only         | `BLAXEL_API_KEY` env                          |
| `deerflow` (`${PORT:-2026}`)  | docker-compose   | upstream default; not yet aliased             |

**Container-internal ports that are NOT published to host** (live in the docker network only):
- `honcho-redis-1` → `6379/tcp` (intentionally unpublished; FalkorDB owns `127.0.10.7:6379`)
- `honcho-deriver-1` → `8000/tcp` (worker, no API surface)
- `phoenix` → `9090/tcp` (Phoenix's internal Prometheus metrics; not bound)
- `qdrant` → `6334/tcp` (gRPC; not published by our start script)
- `honcho-database-1` → `5432/tcp` (Postgres; no host publish — nothing on the Mac dials it)

---

## Per-service detail

Each entry: ports listened on, what calls in, healthcheck command.

### `ollama` (brew-service)

- **Listens**: `127.0.0.1:11434` (Mac brew). Reached from containers as `ollama:11434` via `--add-host=ollama:host-gateway`.
- **Internal**: none (single-process; runs as the user's `ollama` daemon via `brew services start ollama`)
- **Callers**:
  - `litellm` → `http://ollama:11434` (api_base for `local`, `local-heavy`, `embed-local`; see `litellm/config.yaml`; container reaches host via host-gateway alias)
- **Healthcheck**: `curl -s http://ollama:11434/api/tags` (Mac side, after `/etc/hosts` setup)
- **Source**: `services.yml:18-24`, `installer/phases/01_inference.sh:60`

### `litellm` (docker)

- **Listens**: `127.0.10.1:4000:4000` (Mac dials `http://litellm:4000`) → `litellm:4000` (inside `ai-stack` network)
- **Internal**: stateless; writes to `/traces/litellm.jsonl` (bind-mounted to `~/ai-stack/traces/`)
- **Callers**:
  - `openwebui` → `http://litellm:4000/v1` (set via `OPENAI_API_BASE_URL`)
  - `honcho-api-1` → `http://litellm.ai-stack:4000/v1` (fully-qualified for multi-network; set via `LLM_OPENAI_API_BASE`)
  - `docs_ingestor` and `docs_mcp` → `http://litellm:4000/v1` (host-side python)
  - Hermes profiles inside OpenShell sandbox → `https://inference.local/v1` (L7 proxy to LiteLLM; sandbox-side hostname)
  - `bin/audit.sh` → `http://litellm:4000/v1/chat/completions`
- **Egress to**: Anthropic, OpenAI, OpenRouter, Google (over HTTPS, per provider's API)
- **Healthcheck**: `curl -s http://litellm:4000/health`
- **Source**: `services.yml:26-42`, `bin/start-litellm.sh:62`, `installer/lib/aliases.tsv`

### `phoenix` (docker)

- **Listens**: `127.0.10.2:6006:6006` (Mac dials `http://phoenix:6006`) → `phoenix:6006` (HTTP UI + OTLP HTTP `/v1/traces`); `127.0.10.3:4317:4317` (gRPC OTLP) → `phoenix:4317`
- **Internal**: `9090/tcp` (Prometheus metrics; not published)
- **Callers**:
  - `litellm` → `http://phoenix:6006/v1/traces` (arize_phoenix callback; OTLP HTTP)
- **Auth**: PHOENIX_SECRET signs session JWTs (NOT the login password). First login is `admin@localhost` / `admin` with forced reset.
- **Healthcheck**: `curl -s http://phoenix:6006/healthz`
- **Source**: `services.yml:45-54`, `bin/start-phoenix.sh:57-58`, `installer/lib/aliases.tsv`

### `falkordb` (docker)

- **Listens**: `127.0.10.7:6379:6379` (Mac dials `redis://falkordb:6379`) → `falkordb:6379` (Redis RESP). Browser UI on `127.0.10.8:3000:3000` → `falkordb-ui` alias (no port-remap workaround needed; under aliasing, the `:3000` collision with `workspace` is resolved by distinct IPs).
- **Internal**: none
- **Callers**:
  - No callers currently wired in services.yml; reserved for future graph-memory work
- **Healthcheck**: `(echo > /dev/tcp/falkordb/6379) 2>/dev/null && echo ok` (TCP-level), or `curl http://falkordb-ui:3000/` for browser
- **Source**: `services.yml:57-63`, `bin/start-falkordb.sh:24-25`, `installer/lib/aliases.tsv`

### `qdrant` (docker)

- **Listens**: `127.0.10.5:6333:6333` (Mac dials `http://qdrant:6333`) → `qdrant:6333` (REST)
- **Internal**: `6334/tcp` (gRPC; not published)
- **Callers**:
  - `docs_ingestor` → `http://qdrant:6333` (host-side; collection `ai-stack-docs`, vectors size 1536)
  - `docs_mcp` → `http://qdrant:6333` (host-side search reads)
- **Healthcheck**: `curl -s http://qdrant:6333/collections`
- **Source**: `services.yml:64-71`, `bin/start-qdrant.sh:24`, `installer/phases/06_documents.sh:71-77`

### `honcho` (compose) — 4 containers

The compose stack publishes one host port via the new alias scheme and keeps three services container-internal. `api` and `deriver` join both `honcho_default` (compose internal) and `ai-stack` (external) so they can reach LiteLLM and be reached by other ai-stack services.

| Container           | Container ports | Host ports                 | Role                              |
|---------------------|-----------------|----------------------------|-----------------------------------|
| `honcho-api-1`      | `8000/tcp`      | `127.0.10.6:8000:8000`     | FastAPI public surface            |
| `honcho-database-1` | `5432/tcp`      | **none** (compose-internal)| pgvector-on-Postgres 15           |
| `honcho-redis-1`    | `6379/tcp`      | **none** (intentionally)   | Job queue + cache (Redis 8.2)     |
| `honcho-deriver-1`  | `8000/tcp`      | **none**                   | Background worker (no API)        |

- **Callers** (Mac side):
  - All Honcho host-side clients → `http://honcho:8000` (`HONCHO_BASE_URL` in `.env`)
- **Callers** (inside `honcho_default` docker network):
  - `honcho-api-1` → `database:5432`, `redis:6379`
  - `honcho-deriver-1` → `api:8000` (depends_on), `database:5432`, `redis:6379`
- **Callers** (inside `ai-stack` docker network — other services reaching honcho):
  - any → `http://honcho:8000`
- **Egress**: `honcho-api-1` and `honcho-deriver-1` → `http://litellm.ai-stack:4000/v1` (fully-qualified Docker DNS — they're multi-network, so bare `litellm` is ambiguous)
- **Healthcheck**: `curl -s http://honcho:8000/health`
- **Source**: `services.yml:74-82`, `honcho/docker-compose.yml`, `honcho/docker-compose.override.yml` (redis port reset, ai-stack network attach), `installer/phases/03_honcho.sh:78-91`

### `openshell` (CLI + sandbox runtime)

- **Listens**: no host port. Sandbox `hermes-fleet-v1` is reached via `openshell sandbox exec ...`.
- **Sandbox-internal**:
  - `inference.local:443` (L7 proxy to LiteLLM, presented by OpenShell to the sandbox)
  - Sandbox is allowed to reach `honcho:8000` (Honcho), `docs-mcp:8765` (Docs MCP), and a small allowlist (`api.github.com`, `pypi.org`, `registry.npmjs.org`, etc.). The sandbox does NOT join the `ai-stack` Docker network (per design D4); resolution of these aliases happens via the sandbox's egress policy + the Mac's `/etc/hosts`.
- **Source**: `services.yml:86-89`, `installer/phases/04_openshell.sh:55-71`

### `hermes_fleet` (hermes-profiles inside sandbox)

- **Listens**: no host port. Profiles are configured to talk to `https://inference.local/v1` (the OpenShell L7 proxy).
- **Source**: `services.yml:90-95`, `installer/phases/04f_hermes_fleet.sh:269-274`

### `litellm_guardrails_builtin` and `litellm_guardrails_secrets` (litellm-feature)

- **Listens**: none — they're in-process LiteLLM callbacks (regex/keyword denylist; secrets-leak blocker).
- **Source**: `services.yml:98-105`, `installer/phases/04g_security.sh:33-44`

### `llm_guard` (docker)

- **Listens**: `127.0.10.12:8000:8000` (Mac dials `http://llm-guard:8000`) → `llm-guard:8000` (in network). Honcho also uses container port 8000 but on a different IP (`127.0.10.6`), so there's no host-side collision.
- **Internal**: none
- **Callers**: LiteLLM's `guardrails.handler` (if configured to call it; currently the in-process callback is the primary; LLM Guard is an optional sidecar).
- **Auth**: `AUTH_TOKEN=$LITELLM_MASTER_KEY` (bearer in `Authorization: Bearer ...`)
- **Healthcheck**: `curl -s http://llm-guard:8000/healthz` (best-effort; image's exact endpoint _unverified_)
- **Source**: `services.yml:106-112`, `bin/start-llm_guard.sh:30`, `installer/lib/aliases.tsv`

### `dual_llm_researcher` (agent-pattern)

- **Listens**: none. Prompting convention where the researcher reads through a summarizer first. Documented in `prompts/` _unverified_.
- **Source**: `services.yml:113-116`

### `hermes_workspace` (compose)

- **Listens**: `127.0.10.10:3000:3000` (Mac dials `http://workspace:3000`) → `workspace:3000`
- **Internal**: _unverified_; clone of `NousResearch/hermes-workspace` not present locally at this writing (installer phase 05 best-effort).
- **Callers**: human in browser
- **Healthcheck**: `curl -s http://workspace:3000/`
- **Source**: `services.yml:119-125`, `installer/phases/05_uis.sh:62`, `installer/lib/aliases.tsv`

### `openwebui` (docker)

- **Listens**: `127.0.10.9:8080:8080` (Mac dials `http://openwebui:8080`) → `openwebui:8080` (container's native port)
- **Internal**: none (single container)
- **Callers**: human in browser
- **Egress**: `http://litellm:4000/v1` (LiteLLM, via `ai-stack` Docker DNS)
- **Auth**: `WEBUI_AUTH=False` (no auth — relies on `127.0.10.x` loopback-only bind; same security story as before, just under a named address)
- **Healthcheck**: `curl -s http://openwebui:8080/health`
- **Source**: `services.yml:126-133`, `bin/start-openwebui.sh:30-33`, `installer/lib/aliases.tsv`

### `docs_ingestor` (python-bg)

- **Listens**: none (one-shot or interactive sweep of `~/ai-stack/ingestor/inbox/`)
- **Egress**: `http://qdrant:6333` (Qdrant) and `http://litellm:4000/v1` (LiteLLM embeddings) — host-side python reads `QDRANT_URL` and `LITELLM_BASE_URL` from `.env`
- **Source**: `services.yml:136-140`, `installer/phases/06_documents.sh:58-111`

### `docs_mcp` (python-bg)

- **Listens**: `127.0.10.4:8765:8765` (Mac dials `http://docs-mcp:8765`); only actively listening when `python mcp_server.py` is running. The alias is reserved in `/etc/hosts` even when the process is down.
- **Callers**: MCP-aware agents inside OpenShell sandbox (`docs-mcp:8765` in the sandbox allowlist) or any local MCP client
- **Egress**: `http://qdrant:6333` (Qdrant) and `http://litellm:4000/v1` (LiteLLM) — host-side python reads from env vars
- **Source**: `services.yml:141-147`, `installer/phases/06_documents.sh:124`, `installer/lib/aliases.tsv`

### `autofyn` (docker-compose)

- **Listens**: `127.0.10.13:3400:3400` (Mac dials `http://autofyn:3400`) → `autofyn:3400`
- **Internal**: _unverified_ (clone not present locally)
- **Healthcheck**: `curl -s http://autofyn:3400/`
- **Source**: `services.yml:150-156`, `installer/phases/07_autofyn.sh:46`, `installer/lib/aliases.tsv`

### `paperclip` (node-bg)

- **Listens**: `127.0.10.14:3100:3100` (Mac dials `http://paperclip:3100`) → `paperclip:3100`
- **Internal**: _unverified_ (not currently running; phase 08's `bin/start-paperclip.sh` is referenced but not present in `bin/`)
- **Source**: `services.yml:158-162`, `installer/phases/08_paperclip.sh:46`, `installer/lib/aliases.tsv`

### `pi` (openshell-sandbox) — Phase 15

- **Listens**: nothing on the host. Pi runs inside the `pi-v1` OpenShell sandbox; launch via `bin/pi` which `exec`s into the sandbox.
- **Egress**: per `openshell/policies/pi-v1.yaml` — Pi can reach `host.docker.internal:4000` (LiteLLM), `:8000` (Honcho), `:8765` (docs-mcp), and npm/pypi/github for runtime fetches. All other destinations return HTTP 403 with body `{"error":"policy_denied"}` from the OpenShell egress proxy.
- **Auth**: Pi calls LiteLLM with `PI_LITELLM_KEY` (a LiteLLM virtual key minted in Phase 15, scoped to `models=[local,local-heavy,local-lfm2]`). Lives in `.env` mode 0600. Pi never sees `LITELLM_MASTER_KEY`.
- **Stop / kill**: `bin/pi-kill` (pkills the pi process inside the sandbox without removing the sandbox itself).
- **Source**: `services.yml:308-323`, `installer/phases/15_pi.sh`, `bin/pi`, `bin/pi-kill`, `pi/inference-local.ts`, `openshell/policies/pi-v1.yaml`

### LiteLLM dual-bind note (Phase 15 side-effect)

Phase 15 needed `host.docker.internal:4000` to reach LiteLLM from inside the `pi-v1` sandbox VM. Inside that VM, `host.docker.internal` resolves to the Mac's `127.0.0.1` (not `127.0.10.1`). `bin/start-litellm.sh` now publishes LiteLLM on BOTH `127.0.10.1:4000` (the canonical alias bind) AND `127.0.0.1:4000` (so the host.docker.internal route reaches it). Same dual-bind shape Honcho already uses for `host.docker.internal:8000`. Doctor check 25 enforces the `host.docker.internal:4000` reach from inside the sandbox.

### LiteLLM Postgres backend (Phase 15 prerequisite)

Phase 15 needs `/key/generate` to mint `PI_LITELLM_KEY`, which requires LiteLLM to have a database. LiteLLM's Prisma schema is hardcoded to `postgresql://` (SQLite is not supported). Rather than spin up a dedicated Postgres container, `bin/start-litellm.sh` points at Honcho's existing `honcho-database-1:5432` via `host.docker.internal:5432` and uses a sibling database named `litellm`. Phase 15 creates that database the first time it runs (`CREATE DATABASE litellm` via `docker exec honcho-database-1 psql -U postgres`). Coupling tradeoff: Honcho compose lifecycle now affects LiteLLM's key store — bringing Honcho down kicks LiteLLM's Prisma connection until it reconnects.

### `unsloth` (python-bg)

- **Listens**: `0.0.0.0:8898` on the host (Mac dials `http://unsloth:8898` or `http://localhost:8898`)
- **Internal**: Python FastAPI backend (`/api/*`) + OpenAI-compatible `/v1/chat/completions`, `/v1/models`, `/v1/embeddings` (all auth-gated; bootstrap user `unsloth` with password at `~/.unsloth/studio/auth/.bootstrap_password`).
- **Healthcheck**: `curl -s http://unsloth:8898/api/health` (returns `{"status":"healthy",...}`)
- **Models cache**: `~/.cache/huggingface/hub/`
- **Stop / start**: `bash bin/start-unsloth.sh` (idempotent); `kill $(cat installer/state/unsloth.pid)`
- **Source**: `services.yml:301-307`, `installer/phases/14_unsloth_studio.sh`, `bin/start-unsloth.sh`, `installer/lib/aliases.tsv`

### `paperclip_honcho_plugin` (paperclip-plugin)

- **Listens**: none (plugin loaded inside Paperclip UI; talks to Honcho via `HONCHO_BASE_URL`)
- **Source**: `services.yml:163-166`

### `remnic_hermes` (pip-package) — disabled

- **Listens**: none (alt-memory pip pkg, installed-disabled)
- **Source**: `services.yml:167-170`

### `byterover_cli` (npm-global) — disabled

- **Listens**: none (host-side memory CLI, installed-disabled)
- **Source**: `services.yml:171-174`

### `deerflow` (docker-compose)

- **Listens**: `127.0.0.1:${PORT:-2026}` (upstream default `2026`; no canonical alias yet — orchestrator decision pending if/when DeerFlow is brought up regularly)
- **Internal** (within `deer-flow` docker network):
  - `nginx` → host port
  - `frontend` (Next.js)
  - `gateway:8001` (FastAPI)
  - `provisioner` (optional)
- **Source**: `services.yml:175-179`, `deer-flow/docker/docker-compose.yaml:15,30`

### `halo` (cli-only)

- **Listens**: none. Run on demand on host via `bin/halo`.
- **Routes**: via LiteLLM (local default); the agents-SDK cloud trace export is disabled. CAVEAT: HALO wants OTel-format traces (NOT our custom `traces/litellm.jsonl`) and its openai-agents SDK uses the Responses API, so full analysis on local models is experimental.
- **Source**: `services.yml:180-183`, `installer/phases/11_halo_autoreason.sh`, `bin/halo`

### `autoreason` (clone-only) — disabled

- **Listens**: none (research artifact; cloned to `halo/autoreason/`)
- **Source**: `services.yml:184-187`

### `blaxel_cli` (cli-only)

- **Listens**: none (cloud-only). `bl` / `blaxel` commands talk to Blaxel cloud over HTTPS.
- **Auth**: `BLAXEL_API_KEY`, `BLAXEL_WORKSPACE` env
- **Source**: `services.yml:190-193`, `installer/phases/12_blaxel.sh`

### `rlm` (cli-only) — Phase 18

- **Listens**: none. Run on demand on host via `bin/rlm` (wraps `rlm/run_rlm.py`). Recursive Language Models (`rlms` pip package) — a model recursively calls itself over long context via a REPL.
- **Routes**: via LiteLLM (works on local models); calls LiteLLM with `RLM_LITELLM_KEY`.
- **REPL sandbox**: the REPL runs in a Docker sandbox (`python:3.11-slim`), not on the host. RLM is the substrate HALO is built on.
- **Source**: `installer/phases/18_rlm.sh`, `bin/rlm`, `rlm/run_rlm.py`

---

## Conflict notes

These were real or potential collisions in the pre-refactor world. Under the
new `127.0.10.x` scheme each alias has its own IP, so most "same host port,
different service" collisions are resolved by distinct binding IPs.

| # | Collision                                                  | Resolution                                                                                                                                                                  | Source                                            |
|---|------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------|
| 1 | **FalkorDB :6379** vs **Honcho's redis :6379** (RESP)      | FalkorDB owns `127.0.10.7:6379`. Honcho's compose override blanks Honcho-redis's host publish via `ports: !reset []`. Honcho's `api` and `deriver` reach Redis over the internal `honcho_default` network at `redis:6379`. | `installer/phases/03_honcho.sh:78-91`             |
| 2 | **FalkorDB Browser :3000** (container) vs **Hermes Workspace :3000** (host) | Each alias owns a distinct `127.0.10.x` IP: `falkordb-ui` is `127.0.10.8:3000:3000`, `workspace` is `127.0.10.10:3000:3000`. The legacy `3000 → 3010` host-remap is no longer required. | `bin/start-falkordb.sh:25`, `services.yml:61,123` |
| 3 | **LLM Guard container :8000** vs **Honcho API container :8000** | Each alias on a distinct IP: `llm-guard` on `127.0.10.12:8000:8000`, `honcho` on `127.0.10.6:8000:8000`. No host-side collision. | `bin/start-llm_guard.sh:30`                       |
| 4 | **Open WebUI container :8080** vs anything else            | OpenWebUI runs internally on `8080`; published as `127.0.10.9:8080:8080`. No conflict.                                                                                          | `bin/start-openwebui.sh:33`                       |
| 5 | Phoenix's `9090` (Prometheus) vs Honcho compose's commented-out Prometheus `9090` | Honcho's monitoring services are commented out in upstream compose. Phoenix's `9090` is container-internal, not published.                                            | `honcho/docker-compose.yml:112-127`               |
| 6 | Honcho compose's commented-out Grafana `3000` vs Hermes Workspace `3000` | Honcho's Grafana is commented out. Hermes Workspace wins.                                                                                                                | `honcho/docker-compose.yml:130-140`               |

The doctor check that catches non-docker collisions: `installer/doctor/checks/11_port_collisions.sh`. It now scans by `IP:PORT` pair (not bare port) per row in `installer/lib/aliases.tsv`.

---

## Reserved-but-not-bound ports

These ports are declared in `services.yml` but only listen when their service is actively running.

| Port  | Service        | Why it might not be listening                                                                          |
|-------|----------------|--------------------------------------------------------------------------------------------------------|
| 8765  | `docs_mcp`     | Foreground `python mcp_server.py` (no `start-docs_mcp.sh`); only up when user runs it.                |
| 3000  | `hermes_workspace` | Clone may not be present (upstream `NousResearch/hermes-workspace` may not exist); best-effort.   |
| 3100  | `paperclip`    | No `bin/start-paperclip.sh` shipped; launched on-demand from `~/ai-stack/tools/paperclip`.            |
| 3400  | `autofyn`      | Clone may not be present (best-effort upstream).                                                       |
| 2026  | `deerflow`     | Phase 10 auto-starts via `bin/start-deerflow.sh` (wrapper exports `LITELLM_MASTER_KEY` so compose's `${VAR}` substitution resolves warning-free). Stop with `stack stop deerflow` (~520 MB), restart with `stack start deerflow`. Doctor check 28 guards the config patches. |
| 5432  | `honcho-database-1` | Only when honcho compose is up.                                                                   |

---

## How to verify

Run this as the user. It prints every host-listening TCP socket alongside the owning process and the matching service from this table.

```bash
# What's actually listening on localhost right now?
lsof -nP -iTCP -sTCP:LISTEN | awk '
  NR==1 {print; next}
  {
    split($9, a, ":"); port = a[length(a)];
    if (port ~ /^[0-9]+$/) print $1, $2, port, $9
  }
' | sort -k3 -n

# Cross-check with docker:
docker ps --format 'table {{.Names}}\t{{.Ports}}\t{{.Image}}'

# Per-container actual bindings (run for any name in `docker ps`):
docker inspect <name> --format '{{json .HostConfig.PortBindings}}' | jq
```

Spot-check that bound-to-127.0.10.x holds:

```bash
docker ps --format '{{.Names}}: {{.Ports}}' | \
  grep -vE '127\.0\.10\.|^[^:]+:$'   # should print nothing
```

Also probe that aliases resolve:

```bash
dscacheutil -q host -a name litellm   # → ip_address: 127.0.10.1
for a in litellm phoenix qdrant falkordb honcho openwebui workspace; do
  printf "%-12s " "$a"
  awk -v a="$a" '$2==a{print $1}' /etc/hosts || echo "missing"
done
```

---

## External-facing summary

**Every ai-stack service binds to a `127.0.10.x` loopback address only.** No service listens on `0.0.0.0`, no port is exposed to the LAN. Aliases are populated into `/etc/hosts` and Docker's embedded DNS by Phase 00·N.

Confirmation (probed live after refactor): all published port mappings bind their `HostIp` to a `127.0.10.x` address per the canonical alias table in `installer/lib/aliases.tsv`. The single non-container host listener inside our port range is `ollama` (brew service), which binds to `127.0.0.1:11434` and is reached from containers via the `--add-host=ollama:host-gateway` flag.

The audit script `bin/audit.sh` (phase 04·G) enforces this as one of its 4/4 checks:

```bash
! docker ps --format "{{.Ports}}" | grep -vE "(127\.0\.10\.|^$)" | grep -q ":"
```

A failing audit means a container leaked to `0.0.0.0` — investigate immediately.

External egress (LiteLLM → Anthropic / OpenAI / OpenRouter / Google over HTTPS) is unrelated to ingress and unaffected by this guarantee. See [DEPENDENCIES.md § Talks-to matrix](DEPENDENCIES.md#talks-to-matrix) for the full egress list.
