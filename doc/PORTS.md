# PORTS.md

Authoritative port and service map for `~/ai-stack`. Every alias row here is cross-referenced cell-for-cell against `installer/lib/aliases.tsv` (the canonical IP table — if anything below disagrees with the .tsv, the .tsv wins), and supporting claims against `services.yml`, `bin/start-*.sh`, an `installer/phases/*.sh`, an `installer/doctor/checks/*.sh`, or a live `docker inspect`. Alias rows re-verified against the .tsv on **2026-05-31**.

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

Every aliased `ai-stack` service is reached by an **alias** (e.g.,
`litellm`, `phoenix`, `qdrant`) that resolves to a unique `127.0.10.x`
loopback IP via the `/etc/hosts` block. Container-to-container traffic
uses Docker's embedded DNS on the `ai-stack` bridge network so the same
alias works from inside any joined container.

**`prepare-sudo` installs the whole contract — it is the ONE sudo step.**
`sudo bash vz-ai-stack.sh prepare-sudo` writes the managed `/etc/hosts` block
(`hosts_ensure_block`), binds each `127.0.10.x` to `lo0`
(`lo0_ensure_aliases`), installs the launchd persistence plist
(`lo0_install_persistence_plist`) so the binds survive reboot, and
flushes DNS. It is idempotent. (Phase 00·N re-asserts the same helpers
during a normal `install`, but the alias system as a whole is owned by
`prepare-sudo`; the rest of `install all` then runs as your normal user
with no sudo.)

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

The helper `lib/network.sh::hosts_ensure_block` is idempotent: no-op if
the block matches `aliases.tsv`, atomic write under `sudo` otherwise.
IPv4 only (no `::1` lines); see ARCHITECTURE.md § "What's in /etc/hosts"
for the marker format.

**lo0 binding is also required.** macOS does NOT auto-route `127.0.0.0/8`;
only `127.0.0.1` is on `lo0` by default. `prepare-sudo` runs
`lo0_ensure_aliases` (under `sudo`) to `ifconfig lo0 alias 127.0.10.X up`
for each row of `aliases.tsv`, and `lo0_install_persistence_plist` writes
`/Library/LaunchDaemons/com.ai-stack.loopback.plist` so the aliases
survive reboot. Without this, /etc/hosts resolves correctly but kernel
routing drops every packet. Doctor check 19 (`19_lo0_aliases.sh`)
enforces it.

---

## The alias table (verbatim from `installer/lib/aliases.tsv`)

These are the **15 active alias rows** in `installer/lib/aliases.tsv`, in
file order. Each row is `alias → IP → protocol → host_port →
container_port → phase → service_key`. Under the 2026-05-28 scheme
`host_port == container_port` for every row, so the Mac-side and
container-side URL are identical (e.g., `http://litellm:4000` works from
both). If this table and the .tsv ever disagree, the .tsv wins.

| Alias          | Alias URL                  | IP          | Host port | Container port | Phase | What it is                                  |
|----------------|----------------------------|-------------|-----------|----------------|-------|---------------------------------------------|
| `litellm`      | `http://litellm:4000`      | 127.0.10.1  | 4000      | 4000           | 01    | LiteLLM OpenAI-compat proxy (the model hub) |
| `phoenix`      | `http://phoenix:6006`      | 127.0.10.2  | 6006      | 6006           | 01h   | Phoenix UI + OTLP HTTP collector            |
| `phoenix-otlp` | `phoenix-otlp:4317` (gRPC) | 127.0.10.3  | 4317      | 4317           | 01h   | Phoenix OTLP gRPC ingest (`extra_alias`)    |
| `docs-mcp`     | `http://docs-mcp:8765`     | 127.0.10.4  | 8765      | 8765           | 06    | Docs MCP search server                      |
| `qdrant`       | `http://qdrant:6333`       | 127.0.10.5  | 6333      | 6333           | 02    | Qdrant vector DB (REST)                     |
| `honcho`       | `http://honcho:8000`       | 127.0.10.6  | 8000      | 8000           | 03    | Honcho cross-agent memory API               |
| `falkordb`     | `redis://falkordb:6379`    | 127.0.10.7  | 6379      | 6379           | 02    | FalkorDB graph (Redis RESP)                 |
| `falkordb-ui`  | `http://falkordb-ui:3000`  | 127.0.10.8  | 3000      | 3000           | 02    | FalkorDB browser UI (`extra_alias`)         |
| `openwebui`    | `http://openwebui:8080`    | 127.0.10.9  | 8080      | 8080           | 05    | Open WebUI chat UI                          |
| `workspace`    | `http://workspace:3000`    | 127.0.10.10 | 3000      | 3000           | 05    | Hermes Workspace UI                         |
| `hermes-gw`    | `http://hermes-gw:8642`    | 127.0.10.11 | 8642      | 8642           | 04    | Hermes/OpenShell L7 gateway                 |
| `llm-guard`    | `http://llm-guard:8000`    | 127.0.10.12 | 8000      | 8000           | 04g   | LLM Guard scanner sidecar                   |
| `autofyn`      | `http://autofyn:3400`      | 127.0.10.13 | 3400      | 3400           | 07    | AutoFyn coding agent                        |
| `paperclip`    | `http://paperclip:3100`    | 127.0.10.14 | 3100      | 3100           | 08    | Paperclip personal task agent               |
| `unsloth`      | `http://unsloth:8898`      | 127.0.10.16 | 8898      | 8898           | 14    | Unsloth Studio (fine-tuning + train UI)     |

**Notes on the table:**
- The `phoenix-otlp` row carries protocol `grpc` in the .tsv — it is an
  OTLP/gRPC endpoint, not HTTP, so dial it as `phoenix-otlp:4317` (gRPC),
  not with an `http://` prefix.
- **`127.0.10.15` is skipped.** The .tsv has a commented-out reserved row
  `phoenix-otlp-http  127.0.10.15  http  4318  4318  01h  phoenix` (OTLP/HTTP
  spec port 4318), ready to uncomment if a Phoenix/OTel client mandates it.
  The live range therefore jumps `127.0.10.14` → `127.0.10.16`. `.17`+ is
  free for future services.

### Brew host service with no alias row — `ollama`

`ollama` is NOT in `aliases.tsv` (it is a brew service, not a container,
and not on `lo0`). It binds `127.0.0.1:11434` on the host. Containers
reach it as `http://ollama:11434` via the `--add-host=ollama:host-gateway`
flag baked into each consumer's `docker run` (e.g., LiteLLM). Port
`:11434` stays in the URL on both sides.

### Fully-qualified DNS for multi-network containers

Honcho's `api` and `deriver` containers are on multiple Docker networks
(`honcho_default` + `ai-stack`). Cross-stack call sites use
**fully-qualified DNS**: `http://litellm.ai-stack:4000/v1` (not
`http://litellm:4000/v1`) to avoid Docker's unspec'd multi-network
resolution order.

---

## Loopback-only services with NO alias (intentional)

These newer host services LISTEN on a port but are deliberately left OUT
of `aliases.tsv` — they get no `/etc/hosts` alias and no `127.0.10.x`
`lo0` bind. The reasons are spelled out in the comment block at the foot
of `aliases.tsv`:

| Service          | Reach it at                          | Port | Phase | Why no alias                                                                                                   |
|------------------|--------------------------------------|------|-------|----------------------------------------------------------------------------------------------------------------|
| claw3d UI        | `http://localhost:4310`              | 4310 | 19    | claw3d REFUSES to bind a public host without `STUDIO_ACCESS_TOKEN` (its own security), so it binds `127.0.0.1`. |
| claw3d-bridge    | `http://localhost:7780`              | 7780 | 19    | Auth-less and can drive **all 9 agents** → loopback-only by design (never expose it under a named address).     |
| lmstudio         | `host.docker.internal:1234` (OPT-IN) | 1234 | 25    | Reached from the LiteLLM **container**, so it uses host-gateway (`host.docker.internal`), not a host `lo0` alias. |

Detail:
- **claw3d UI (`:4310`)** and **claw3d-bridge (`:7780`)** both run with
  `network: host` (Phase 19). The bridge routes chat across every
  isolated agent; because it is auth-less it must stay on loopback. Run it
  with `vz-ai-stack.sh start claw3d` (health-gated composite — starts the
  bridge, waits for its `/health`, then the UI, then opens the browser at
  `http://localhost:4310`).
- **lmstudio (`:1234`)** is an OPT-IN extra (Phase 25 — install by name).
  When enabled, LM Studio's OpenAI server is bound `0.0.0.0:1234` on the
  host and LiteLLM dials it from inside its container via
  `http://host.docker.internal:1234`. It is a 2nd local runtime behind
  LiteLLM; Ollama stays the default. There is no `lo0` alias because the
  caller is a container, not the Mac. Start the server with
  `vz-ai-stack.sh start lmstudio` (idempotent; no model auto-loads — assign
  one in `models.yml` + `model sync`); stop it with `vz-ai-stack.sh stop
  lmstudio`. (`LMS_AUTOSTART` / `lms server start` are no longer the run path.)

**Pi** (Phase 15) also has no alias — but unlike the above it has no host
listener at all. Pi runs inside the `pi-v1` OpenShell sandbox; launch via
`bin/pi`. From inside that sandbox VM it reaches LiteLLM via
`http://host.docker.internal:4000` (which resolves to the Mac's
`127.0.0.1:4000`), authenticating with `PI_LITELLM_KEY`. See the per-service
detail below.

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
| `mempalace`                   | cli-only         | on-device (CoreML embeddings + ChromaDB); Phase 26; `bin/mempalace` + `bin/mempalace-hooks`; optional refiner via `MEMPALACE_LITELLM_KEY` |
| `deerflow` (`${PORT:-2026}`)  | docker-compose   | upstream default; not yet aliased             |

> **`setup` / `deps` are CLI subcommands, not services.** `vz-ai-stack.sh setup`
> (`installer/lib/setup.sh`, interactive `.env`/API-key bootstrap) and
> `vz-ai-stack.sh deps` (`installer/lib/deps.sh`, host-dependency bootstrap) listen
> on nothing and have no alias — they run, mutate `.env` / the host, and exit.

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
  - `litellm` → `http://ollama:11434` (api_base for the Ollama-served models — canonically `local` → `nemotron-3-nano:4b` plus `nomic-embed-text` embeddings; see `installer/models.yml` for the canonical bindings and `litellm/config.yaml` for any legacy add-only slugs that 404 until pulled; container reaches host via host-gateway alias)
- **Healthcheck**: `curl -s http://ollama:11434/api/tags` (Mac side, after `/etc/hosts` setup)
- **Source**: `services.yml:18-24`, `installer/phases/01_inference.sh:60`

### `litellm` (docker)

- **Listens**: `127.0.10.1:4000:4000` (Mac dials `http://litellm:4000`) → `litellm:4000` (inside `ai-stack` network)
- **Internal**: stateless; writes to `/traces/litellm.jsonl` (bind-mounted to `~/ai-stack/traces/`)
- **Callers**:
  - `openwebui` → `http://litellm:4000/v1` (set via `OPENAI_API_BASE_URL`)
  - `honcho-api-1` → `http://litellm.ai-stack:4000/v1` (fully-qualified for multi-network; set via `LLM_OPENAI_BASE_URL`)
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
  - `docs_ingestor` → `http://qdrant:6333` (host-side; collection `ai-stack-docs`, vectors size 768 — `embed-local` = Ollama `nomic-embed-text`; the ingestor auto-recreates a stale 1536-dim collection left by the old cloud embedder)
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
- **Internal**: two compose containers on the `hermes-workspace_default` bridge — the UI (`hermes-workspace`) and its backend `hermes-agent` (gateway `:8642` + dashboard `:9119`). The dashboard binds `0.0.0.0`/`--insecure` so the UI reaches it cross-container (it serves the Sessions API); `:9119` is **never host-published** (only the gateway `:8642` is, on `127.0.10.11`). Clone is `outsourc-e/hermes-workspace` (community UI for Nous's `hermes-agent`). Both images are **digest-pinned** in `docker-compose.override.yml` (no `:latest` drift), and the UI runs an ai-stack **hardened** derived image (guards the gateway sessions `.map` so a dashboard outage shows an empty sidebar, not a 500).
- **Callers**: human in browser
- **Healthcheck**: `curl -s http://workspace:3000/`
- **Source**: `services.yml:119-125`, `installer/phases/05_uis.sh`, `installer/lib/aliases.tsv`

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

- **Listens**: Paperclip's `pnpm dev` binds `127.0.0.1:3100` only (its upstream-recommended "trusted local loopback" mode, which also bypasses the auth gate for loopback connections). The `aliases.tsv` row maps `paperclip → 127.0.10.14:3100 → :3100`, but because Paperclip binds `127.0.0.1` (not `127.0.10.14`), `bin/start-paperclip.sh` runs a tiny Node TCP **relay** on `127.0.10.14:3100` that forwards to `127.0.0.1:3100`. So `http://paperclip:3100` works on the Mac via the relay; `http://localhost:3100` hits Paperclip directly.
- **Embedded Postgres**: `pnpm dev` **auto-provisions an embedded PostgreSQL** (with an auto-generated DB password); this is internal to Paperclip and not exposed via any alias. Our tooling does not pin its port, so do not assume a fixed value — inspect with `lsof -nP -iTCP -sTCP:LISTEN | grep -i postgres` while Paperclip is up if you need the live port.
- **Health**: `http://127.0.0.1:3100/api/health`. First build can take 60–120s before the port binds.
- **Source**: `services.yml:158-162`, `installer/phases/08_paperclip.sh`, `bin/start-paperclip.sh`, `installer/lib/aliases.tsv`

### `pi` (openshell-sandbox) — Phase 15

- **Listens**: nothing on the host. Pi runs inside the `pi-v1` OpenShell sandbox; launch via `bin/pi` which `exec`s into the sandbox.
- **Egress**: per `openshell/policies/pi-v1.yaml` — Pi can reach `host.docker.internal:4000` (LiteLLM), `:8000` (Honcho), `:8765` (docs-mcp), and npm/pypi/github for runtime fetches. All other destinations return HTTP 403 with body `{"error":"policy_denied"}` from the OpenShell egress proxy.
- **Auth**: Pi calls LiteLLM with `PI_LITELLM_KEY` (a LiteLLM virtual key minted in Phase 15, allowlisted against the canonical scoped-key superset — see `vz-ai-stack.sh model superset`). Pi's assigned model is `local` (`installer/models.yml`). Lives in `.env` mode 0600. Pi never sees `LITELLM_MASTER_KEY`.
- **Stop / kill**: `bin/pi-kill` (pkills the pi process inside the sandbox without removing the sandbox itself).
- **Source**: `services.yml:308-323`, `installer/phases/15_pi.sh`, `bin/pi`, `bin/pi-kill`, `pi/inference-local.ts`, `openshell/policies/pi-v1.yaml`

### LiteLLM dual-bind note (Phase 15 side-effect)

Phase 15 needed `host.docker.internal:4000` to reach LiteLLM from inside the `pi-v1` sandbox VM. Inside that VM, `host.docker.internal` resolves to the Mac's `127.0.0.1` (not `127.0.10.1`). `bin/start-litellm.sh` now publishes LiteLLM on BOTH `127.0.10.1:4000` (the canonical alias bind) AND `127.0.0.1:4000` (so the host.docker.internal route reaches it). Same dual-bind shape Honcho already uses for `host.docker.internal:8000`. Doctor check 25 enforces the `host.docker.internal:4000` reach from inside the sandbox.

### LiteLLM Postgres backend (Phase 15 prerequisite)

Phase 15 needs `/key/generate` to mint `PI_LITELLM_KEY`, which requires LiteLLM to have a database. LiteLLM's Prisma schema is hardcoded to `postgresql://` (SQLite is not supported). Rather than spin up a dedicated Postgres container, `bin/start-litellm.sh` points at Honcho's existing `honcho-database-1:5432` via `host.docker.internal:5432` and uses a sibling database named `litellm`. `bin/start-litellm.sh` now **ensures the `litellm` DATABASE itself exists** on every start (a reachable Postgres server on `:5432` ≠ the `litellm` db being present — nothing else creates it), running `CREATE DATABASE litellm` via `docker exec <pg> psql -U postgres` if missing; this self-heals a cold/second machine where the server is up but the db was never created. `installer/lib/litellm.sh` adds `litellm_smoke_ok` (is `/v1/models` serving?) and `litellm_diagnose` (a secret-free, actionable diagnostic — e.g. the exact `CREATE DATABASE litellm` + `start-litellm.sh --recreate` fix) [89778b9, ad01a9f]. Coupling tradeoff: Honcho compose lifecycle now affects LiteLLM's key store — bringing Honcho down kicks LiteLLM's Prisma connection until it reconnects.

### `unsloth` (python-bg)

- **Listens**: `0.0.0.0:8898` on the host (Mac dials `http://unsloth:8898` or `http://localhost:8898`)
- **Internal**: Python FastAPI backend (`/api/*`) + OpenAI-compatible `/v1/chat/completions`, `/v1/models`, `/v1/embeddings` (all auth-gated; bootstrap user `unsloth` with password at `~/.unsloth/studio/auth/.bootstrap_password`).
- **Healthcheck**: `curl -s http://unsloth:8898/api/health` (returns `{"status":"healthy",...}`)
- **Models cache**: `~/.cache/huggingface/hub/`
- **Stop / start**: `vz-ai-stack.sh start unsloth` (idempotent) / `vz-ai-stack.sh stop unsloth` (PID-file stop)
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

### `mempalace` (cli-only) — Phase 26

- **Listens**: none. No daemon, no host port. Local-first **verbatim** Claude Code conversation memory, CLI + MCP. Run on demand via `bin/mempalace` (`wake-up`, `search`, `mine`, `status`); auto-save hooks via `bin/mempalace-hooks` (reversible, backup-first; the `bin/mempalace-hook-*` launchers set `PATH` so GUI/launchd-spawned Claude Code finds it).
- **Embeddings**: **on-device** (CoreML; default `all-MiniLM-L6-v2` 384-dim, `embeddinggemma` opt-in). No cloud embeddings — nothing dialed for them.
- **Storage**: local on-device **ChromaDB** (MemPalace 3.3.5 hardcodes `ChromaBackend`). A Qdrant backend adapter is staged at `mempalace/backend-qdrant/` but NOT live (tested in an isolated venv; co-installing `qdrant-client` into the tool env breaks `import chromadb`).
- **Routes**: optional refiner LLM only → `http://litellm:4000/v1` with `MEMPALACE_LITELLM_KEY` (→ Phoenix). Install is **PyPI-only** (`mempalace.tech` is a malware squat).
- **Source**: `installer/phases/26_mempalace.sh`, `bin/mempalace`, `bin/mempalace-hooks`, `installer/doctor/checks/44_mempalace.sh`

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
| 3100  | `paperclip`    | Started via `bin/start-paperclip.sh` (daemonizes `pnpm dev` in `~/ai-stack/tools/paperclip`); only listening when running. Reached on the alias via the `127.0.10.14:3100 → 127.0.0.1:3100` relay. |
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
