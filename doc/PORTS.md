# PORTS.md

Authoritative port and service map for `~/ai-stack`. Every alias row here is cross-referenced cell-for-cell against `installer/lib/aliases.tsv` (the canonical IP table — if anything below disagrees with the .tsv, the .tsv wins), and supporting claims against `services.yml`, `bin/start-*.sh`, an `installer/phases/*.sh`, an `installer/doctor/checks/*.sh`, or a live `docker inspect`. Alias rows re-verified against the .tsv on **2026-07-05**.

Sister doc: see [DEPENDENCIES.md](DEPENDENCIES.md) for topology, talks-to matrix, and sequence diagrams. Architecture rationale lives in [ARCHITECTURE.md](ARCHITECTURE.md).

> **Two addressing layers (read this first).**
>
> 1. **`name:port` (always on).** Every aliased service is reachable at
>    `http://<alias>:<port>` from both the Mac and containers (e.g.
>    `http://litellm:4000`, `http://phoenix:6006`, `http://openwebui:8080`).
>    This is the baseline and needs only `prepare-sudo`.
> 2. **Port-free `http://name/` (opt-in, Phase 31 `ingress up`).** A
>    host-native Caddy adds port-free `http://litellm/` + `https://litellm/`
>    on top of the above. See [The bare-hostname ingress](#the-bare-hostname-ingress-phase-31) below.
>
> **Historical note (2026-05-28).** The *original* port-free design bound every
> service on host port `80`, but OrbStack collapses every `--publish 127.0.10.X:80:Y`
> mapping into one `*:80` wildcard listener, so multiple HTTP services all routed to
> the first-registered container. The fix moved every service to its **native**
> container port (`host_port == container_port`), making Mac and container URLs
> identical. Phase 31's `ingress up` later restored port-free URLs a *different* way —
> a **host** Caddy process (not a docker `--publish`), which sidesteps the OrbStack
> `*:80` wildcard entirely. See [CHANGELOG.md 2026-05-28 entry](../CHANGELOG.md).

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
enforces it. (`127.0.0.1`-pinned rows — see below — are skipped by the
lo0-bind step and by doctor checks 19/20 by design, since `127.0.0.1` is
already the lo0 primary.)

---

## The alias table (verbatim from `installer/lib/aliases.tsv`)

These are the **22 active alias rows** in `installer/lib/aliases.tsv`,
sorted here by IP (the .tsv lists them in a slightly different order — the
three `127.0.0.1` rows and `deerflow` interleave differently in the file).
Each row is `alias → IP → protocol → host_port →
container_port → phase → service_key`. For the original scheme
`host_port == container_port`, so the Mac-side and container-side URL are
identical (e.g., `http://litellm:4000` works from both) — but the newest
container rows (`chatdev`, `aitown`) **remap** the host port off the
container port (see the ⚠ notes). If this table and the .tsv ever
disagree, the .tsv wins.

| Alias               | Alias URL                       | IP            | Host port | Cont. port | Phase | What it is                                          |
|---------------------|---------------------------------|---------------|-----------|------------|-------|-----------------------------------------------------|
| `litellm`           | `http://litellm:4000`           | 127.0.10.1    | 4000      | 4000       | 01    | LiteLLM OpenAI-compat proxy (the model hub)         |
| `phoenix`           | `http://phoenix:6006`           | 127.0.10.2    | 6006      | 6006       | 01h   | Phoenix UI + OTLP HTTP collector                    |
| `phoenix-otlp`      | `phoenix-otlp:4317` (gRPC)      | 127.0.10.3    | 4317      | 4317       | 01h   | Phoenix OTLP gRPC ingest (`extra_alias`)            |
| `docs-mcp`          | `http://docs-mcp:8765`          | 127.0.10.4    | 8765      | 8765       | 06    | Docs MCP search server                              |
| `qdrant`            | `http://qdrant:6333`            | 127.0.10.5    | 6333      | 6333       | 02    | Qdrant vector DB (REST)                             |
| `honcho`            | `http://honcho:8000`            | 127.0.10.6    | 8000      | 8000       | 03    | Honcho cross-agent memory API                       |
| `falkordb`          | `redis://falkordb:6379`         | 127.0.10.7    | 6379      | 6379       | 02    | FalkorDB graph (Redis RESP)                         |
| `falkordb-ui`       | `http://falkordb-ui:3000`       | 127.0.10.8    | 3000      | 3000       | 02    | FalkorDB browser UI (`extra_alias`)                 |
| `openwebui`         | `http://openwebui:8080`         | 127.0.10.9    | 8080      | 8080       | 05    | Open WebUI chat UI                                  |
| `workspace`         | `http://workspace:3000`         | 127.0.10.10   | 3000      | 3000       | 05    | Hermes Workspace UI                                 |
| `hermes-gw`         | `http://hermes-gw:8642`         | 127.0.10.11   | 8642      | 8642       | 04    | Hermes/OpenShell L7 gateway                         |
| `llm-guard`         | `http://llm-guard:8000`         | 127.0.10.12   | 8000      | 8000       | 04g   | LLM Guard scanner sidecar                           |
| `autofyn`           | `http://autofyn:3400`           | 127.0.10.13   | 3400      | 3400       | 07    | AutoFyn coding agent                                |
| `paperclip`         | `http://paperclip:3100`         | 127.0.10.14   | 3100      | 3100       | 08    | Paperclip personal task agent                       |
| `unsloth`           | `http://unsloth:8898`           | 127.0.10.16   | 8898      | 8898       | 14    | Unsloth Studio (fine-tuning + train UI)             |
| `deerflow`          | `http://deerflow:2026`          | 127.0.10.17   | 2026      | 2026       | 10    | DeerFlow deep-research UI (compose)                 |
| `chatdev`           | `http://chatdev:5274`           | 127.0.10.18   | 5274      | **5173** ⚠ | 35    | ChatDev software-company sim (Vue+FastAPI)          |
| `aitown`            | `http://aitown:5273`            | 127.0.10.19   | 5273      | **5173** ⚠ | 36    | AI Town watchable Convex world                      |
| `sourcegraph`       | `http://sourcegraph:7080`       | 127.0.10.20   | 7080      | 7080       | 27    | Local Sourcegraph code search + MCP                 |
| `openwork`          | `http://openwork:8787`          | **127.0.0.1** | 8787      | 8787       | 29    | OpenWork headless orchestrator (Cowork on OpenCode) |
| `aionui`            | `http://aionui:25808`           | **127.0.0.1** | 25808     | 25808      | 28    | AionUi WebUI Cowork workspace                       |
| `agentscope-studio` | `http://agentscope-studio:5275` | **127.0.0.1** | 5275      | 5275       | 33    | AgentScope Studio swarm visualizer (opt-in flag)    |

**Notes on the table:**
- **`phoenix-otlp` is gRPC, not HTTP.** Dial it as `phoenix-otlp:4317`
  (gRPC), never with an `http://` prefix. It currently has **no active
  caller** — LiteLLM's arize_phoenix callback pushes OTLP **HTTP** to
  `http://phoenix:6006/v1/traces` (see the `litellm` / `phoenix` entries),
  so the `:4317` gRPC ingest is effectively reserved.
- **⚠ `chatdev` and `aitown` remap the host port off the container port**
  (`5274 → :5173`, `5273 → :5173`). Both apps serve their Vite frontend on
  container `:5173`; the host publishes distinct ports (`5274`/`5273`) so
  they don't collide. The old "`host_port == container_port` for every
  row" invariant no longer holds — these two rows are the exceptions.
- **Three rows use `127.0.0.1`, not a `127.0.10.x` alias** (`openwork`,
  `aionui`, `agentscope-studio`). Their daemons bind `127.0.0.1`
  directly, so the alias maps a friendly *name* to `127.0.0.1` (letting
  the Mac browse `http://openwork:8787/ui` instead of the raw IP) rather
  than to a dedicated `10.x` IP. The lo0-bind step + doctor checks 19/20
  skip `127.0.0.1` by design. ⚠ `agentscope-studio` is opt-in
  (`AGENTSCOPE_STUDIO=1`) and its `as_studio` server actually binds
  `0.0.0.0` — the `127.0.0.1` alias is a *convenience name*, not a
  security boundary (see the per-service detail + Studio OTLP note).
- **`127.0.10.15` is skipped (reserved).** The .tsv has a commented-out
  row `phoenix-otlp-http 127.0.10.15 http 4318 4318 01h phoenix`
  (OTLP/HTTP spec port 4318), ready to uncomment if a Phoenix/OTel client
  mandates it. The live `10.x` range therefore jumps `.14 → .16`. ⚠ Note
  its port `4318` is the same port `agentscope-studio`'s OTLP receiver
  binds on `0.0.0.0` (see that entry) — with Studio enabled, uncommenting
  `.15` would collide on `:4318`, so pick a different OTLP/HTTP port first.
- **`127.0.10.x` IP map:** `.1`–`.14` and `.16`–`.20` are in use, `.15`
  is reserved (above), and **`.21`+ are used by per-machine `ingress add`
  rows in `aliases.local.tsv`** (see below) — on this repo's shared table
  the next free shared IP is **`.21`**.

### The two-file alias system — `aliases.tsv` + `aliases.local.tsv`

`aliases_load` reads the shared, committed `installer/lib/aliases.tsv`
**and then merges the gitignored `installer/lib/aliases.local.tsv` ON
TOP** — a local row reusing a name overrides the shared one. The local
file holds your **personal `ingress add` hostnames** (see the ingress
section) and is never committed to the public repo, so its `127.0.10.x`
IPs are assigned per machine (typically `.21`+). The live alias set on any
given box = the shared table above **plus** whatever that box's
`aliases.local.tsv` adds. This doc only enumerates the shared table; run
`vz-ai-stack.sh ingress list` to see the effective merged set on your box.

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

## The bare-hostname ingress (Phase 31)

An **opt-in** host ingress (`vz-ai-stack.sh ingress up`) adds port-free
Mac-browser URLs `http://litellm/` + `https://litellm/` on top of the
`name:port` scheme, via a **host-native Caddy** process that binds each
service's OWN `127.0.10.x:80/:443`. Because it's a host process (not a
docker `--publish`), it sidesteps the OrbStack `*:80` wildcard that
killed the original port-80 design. `name:port` and container URLs are
unchanged; the ingress is purely additive.

**What gets a site:** HTTP rows on a `127.0.10.x` IP. **Excluded:**
redis/gRPC rows (`falkordb`, `phoenix-otlp`) and `127.0.0.1`-pinned rows
(`openwork`, `aionui`, `agentscope-studio` — nothing binds a `10.x` IP
for them, so there's no site to reverse-proxy without an explicit
`ingress add`).

**`ingress add <name> <port>`** registers a port-free `http://name/` for
any host server bound to `127.0.0.1:<port>` (e.g. a `*-serve` viewer),
**without modifying that server**. It appends a row with protocol
`http-loopback` to the gitignored `aliases.local.tsv`: the host Caddy
binds the alias `127.0.10.x:80/:443` and reverse-proxies to
`127.0.0.1:<port>` with an upstream `header_up Host` rewrite (so a
loopback Host-pin still passes). Such a row yields **`name/` ONLY** — NOT
`name:port` (nothing binds the alias IP). `ingress remove <name>`
reverses an `add`.

**Commands:** `ingress up | down | list | add | remove | trust | reload`.
`ingress list` shows every hostname + all URL forms + reachability + bind
posture (and flags any `0.0.0.0` host-bind). `ingress trust` installs the
local Caddy root CA so `https://name/` is trusted (needed for
secure-context UIs like `fleet-studio`).

**Activate / teardown:** `sudo vz-ai-stack.sh prepare-sudo` (picks up new
rows, including `aliases.local.tsv`) **then** `sudo vz-ai-stack.sh ingress
reload`. Phase 31 owns the ingress; doctor check 56 guards hostname
coverage. Spec: `doc/specs/2026-06-21-bare-hostname-ingress.md`.

---

## Loopback-only services with NO alias (intentional)

These host services LISTEN on a port but are deliberately left OUT of
`aliases.tsv` — no `/etc/hosts` alias, no `127.0.10.x` lo0 bind. The
reasons are spelled out in the comment block at the foot of `aliases.tsv`:

| Service          | Reach it at                          | Port | Phase | Why no alias                                                                                                     |
|------------------|--------------------------------------|------|-------|-----------------------------------------------------------------------------------------------------------------|
| claw3d UI        | `http://localhost:4310`              | 4310 | 19    | claw3d REFUSES to bind a public host without `STUDIO_ACCESS_TOKEN` (its own security), so it binds `127.0.0.1`.  |
| claw3d-bridge    | `http://localhost:7780`              | 7780 | 19    | Auth-less and can drive **all 9 agents** → loopback-only by design (never expose it under a named address).       |
| understand-mcp   | `host.docker.internal:7081` (token)  | 7081 | 30    | Reached from the **Hermes fleet containers** via host-gateway (token-gated); local clients use the stdio entrypoint. |
| lmstudio         | `host.docker.internal:1234` (OPT-IN) | 1234 | 25    | Reached from the LiteLLM **container**, so it uses host-gateway (`host.docker.internal`), not a host `lo0` alias. |

Detail:
- **claw3d UI (`:4310`)** and **claw3d-bridge (`:7780`)** both run with
  `network: host` (Phase 19). The bridge routes chat across every
  isolated agent; because it is auth-less it must stay on loopback. Run it
  with `vz-ai-stack.sh start claw3d` (health-gated composite — starts the
  bridge, waits for its `/health`, then the UI, then opens the browser at
  `http://localhost:4310`).
- **understand-mcp (`:7081`)** — Phase 30 (opt-in) `understand`. A
  host-loopback node daemon (`bin/start-understand.sh`) serving the
  Understand-Anything knowledge graph over HTTP; the Hermes fleet dials it
  at `host.docker.internal:7081` (token-gated by `UNDERSTAND_MCP_TOKEN`,
  same mechanism as Sourcegraph). Host Claude Code / Pi use the **stdio**
  entrypoint instead. The interactive browser graph is a separate
  foreground serve: `vz-ai-stack.sh understand-dashboard` (Vite, ephemeral
  port). Not a container / not on the `ai-stack` bridge.
- **lmstudio (`:1234`)** is an OPT-IN extra (Phase 25 — install by name).
  When enabled, LM Studio's OpenAI server is bound `0.0.0.0:1234` on the
  host and LiteLLM dials it from inside its container via
  `http://host.docker.internal:1234`. It is a 2nd local runtime behind
  LiteLLM; Ollama stays the default. There is no `lo0` alias because the
  caller is a container, not the Mac. Start with `vz-ai-stack.sh start
  lmstudio`; stop with `vz-ai-stack.sh stop lmstudio`.

### On-demand host viewers (no alias by design; `localhost:PORT`)

These are foreground viewer servers you start when you want them; they
bind `127.0.0.1:PORT` and are Host-pinned to loopback. Give any of them a
port-free `http://name/` with `ingress add <name> <port>` (their rows
then live in your personal `aliases.local.tsv`).

| Viewer                | Port | Notes                                                                                                       |
|-----------------------|------|-------------------------------------------------------------------------------------------------------------|
| `tutorial-serve`      | 8899 | serves `doc/` (the built TUTORIAL/EXPLORE/etc.); loopback Host-pinned.                                       |
| `models-serve`        | 8898 | Model & Agent Console (wraps the `model` CLI). ⚠ **Shares :8898 with `unsloth`** — don't run both at once.   |
| `fleet-studio`        | 8975 | Fleet Studio (edit agent-profiles). Needs an `https://` secure context to use a hostname (`ingress add` + `ingress trust`). |
| `understand-dashboard`| Vite | Understand-Anything browser graph; ephemeral Vite port.                                                      |

**Pi** (Phase 15) also has no alias — but unlike the above it has no host
listener at all. Pi runs inside the `pi-v1` OpenShell sandbox; launch via
`bin/pi`. From inside that sandbox VM it reaches LiteLLM via
`http://host.docker.internal:4000` (which resolves to the Mac's
`127.0.0.1:4000`), authenticating with `PI_LITELLM_KEY`. See the per-service
detail below.

### Sandbox-daemons with NO host port (Hermes gateways)

These run **inside** the `hermes-fleet-v1` OpenShell sandbox and reach the
outside world via **outbound** connections only — no inbound port, no
alias.

| Service           | Phase | Transport                                              | Lifecycle                                                        |
|-------------------|-------|--------------------------------------------------------|------------------------------------------------------------------|
| `hermes_telegram` | 20    | long-polls `api.telegram.org` directly (outbound)      | hermes' own `gateway status/stop/restart`; doctor check 33.      |
| `hermes_slack`    | 38    | Socket Mode — outbound WebSocket to `slack.com`        | in-sandbox role-router process (`.hermes-slack-role-router.pid`). |

Both are secure-by-default: with **no** allowlist they DENY all users
until `HERMES_TELEGRAM_ALLOWED_USERS` / `HERMES_SLACK_ALLOWED_USERS` is
set. Started by `bin/start-hermes-telegram.sh` / `bin/start-hermes-slack.sh`.

### Services with no host port (CLI-only / pattern-only)

These appear in `services.yml` but have no alias because they have no listener:

| Service                       | Phase | Type             | Auth / how it runs                                     |
|-------------------------------|-------|------------------|--------------------------------------------------------|
| `openshell`                   | 04    | openshell        | sandbox-local (no host port)                           |
| `hermes_fleet`                | 04f   | hermes-profiles  | inside-sandbox only (gateway alias `hermes-gw:8642`)   |
| `litellm_guardrails_builtin`  | 04g   | litellm-feature  | piggybacks LiteLLM                                     |
| `litellm_guardrails_secrets`  | 04g   | litellm-feature  | piggybacks LiteLLM                                     |
| `dual_llm_researcher`         | 04g   | agent-pattern    | prompting convention only                              |
| `docs_ingestor`               | 06    | cli-only         | reads `LITELLM_MASTER_KEY` env                         |
| `paperclip_honcho_plugin`     | 08    | paperclip-plugin | activated inside Paperclip UI                          |
| `remnic_hermes`               | 09    | pip-package      | installed-disabled                                     |
| `byterover_cli`               | 09    | npm-global       | installed-disabled                                     |
| `halo`                        | 11    | cli-only         | routes via LiteLLM (`bin/halo`)                        |
| `autoreason`                  | 11    | clone-only       | research artifact (disabled)                           |
| `blaxel_cli`                  | 12    | cli-only         | `BLAXEL_API_KEY` env (cloud)                           |
| `pi_gateway_litellm`          | 15    | litellm-virtual-key | scoped key for Pi (no listener)                     |
| `lumen_mcp`                   | 16    | cli-only         | local semantic-search MCP (`bin/lumen`)                |
| `ace`                         | 17    | cli-only         | research artifact                                      |
| `rlm`                         | 18    | cli-only         | routes via LiteLLM (`bin/rlm`); REPL in Docker sandbox |
| `portless`                    | 21    | cli-only         | dev tool                                               |
| `cmux`                        | 22    | cli-only         | dev tool                                               |
| `skillspector`                | 23    | cli-only         | dev tool                                               |
| `openagents`                  | 24    | cli-only         | dev tool                                               |
| `mempalace`                   | 26    | cli-only         | on-device (CoreML + ChromaDB); `bin/mempalace`         |
| `metagpt`                     | 32    | cli-only         | software-company sim via LiteLLM (`bin/metagpt`)       |
| `agentscope`                  | 33    | cli-only         | swarm framework via LiteLLM (`bin/agentscope`); Studio is the opt-in web GUI |
| `oasis`                       | 34    | cli-only         | social-sim framework via LiteLLM (`bin/oasis`)         |
| `concordia`                   | 37    | cli-only         | DeepMind GABM sim via LiteLLM (`bin/concordia`)        |

> **`setup` / `deps` are CLI subcommands, not services.** `vz-ai-stack.sh setup`
> (`installer/lib/setup.sh`, interactive `.env`/API-key bootstrap) and
> `vz-ai-stack.sh deps` (`installer/lib/deps.sh`, host-dependency bootstrap) listen
> on nothing and have no alias — they run, mutate `.env` / the host, and exit.

**Container-internal ports that are NOT published to host** (live in the docker network only):
- `honcho-redis-1` → `6379/tcp` (intentionally unpublished; FalkorDB owns `127.0.10.7:6379`)
- `honcho-deriver-1` → `8000/tcp` (worker, no API surface)
- `phoenix` → `9090/tcp` (Phoenix's internal Prometheus metrics; not bound)
- `qdrant` → `6334/tcp` (gRPC; not published by our start script)
- `honcho-database-1` → `5432/tcp` (Postgres; no host publish — but LiteLLM reaches it via `host.docker.internal:5432`; see the LiteLLM Postgres note)

---

## Per-service detail

Each entry: ports listened on, what calls in, healthcheck command.

### `ollama` (brew-service)

- **Listens**: `127.0.0.1:11434` (Mac brew). Reached from containers as `ollama:11434` via `--add-host=ollama:host-gateway`.
- **Internal**: none (single-process; runs as the user's `ollama` daemon via `brew services start ollama`)
- **Callers**:
  - `litellm` → `http://ollama:11434` (api_base for the Ollama-served models — canonically `local` → `nemotron-3-nano:4b` plus `nomic-embed-text` embeddings; see `installer/models.yml` for the canonical bindings and `litellm/config.yaml` for any legacy add-only slugs that 404 until pulled; container reaches host via host-gateway alias)
- **Healthcheck**: `curl -s http://ollama:11434/api/tags` (Mac side, after `/etc/hosts` setup)
- **Source**: `services.yml` (`ollama`), `installer/phases/01_inference.sh`

### `litellm` (docker)

- **Listens**: `127.0.10.1:4000:4000` (Mac dials `http://litellm:4000`) → `litellm:4000` (inside `ai-stack` network). Also dual-bound to `127.0.0.1:4000` (see the Phase 15 dual-bind note).
- **Internal**: stateless; writes to `/traces/litellm.jsonl` (bind-mounted to `~/ai-stack/traces/`)
- **Callers**:
  - `openwebui` → `http://litellm:4000/v1` (set via `OPENAI_API_BASE_URL`)
  - `honcho-api-1` → `http://litellm.ai-stack:4000/v1` (fully-qualified for multi-network; set via `LLM_OPENAI_BASE_URL`)
  - `docs_ingestor` and `docs_mcp` → `http://litellm:4000/v1` (host-side python)
  - Hermes profiles inside OpenShell sandbox → `https://inference.local/v1` (L7 proxy to LiteLLM; sandbox-side hostname)
  - The AionUi / OpenWork / MetaGPT / AgentScope / OASIS / Concordia scoped keys → `http://127.0.0.1:4000/v1` (host-side, each with its own virtual key)
  - `bin/audit.sh` → `http://litellm:4000/v1/chat/completions`
- **Egress to**: Anthropic, OpenAI, OpenRouter, Google, and the OpenAI-compat routes (over HTTPS, per provider's API)
- **Healthcheck**: `curl -s http://litellm:4000/health`
- **Source**: `services.yml` (`litellm`), `bin/start-litellm.sh`, `installer/lib/aliases.tsv`

### `phoenix` (docker)

- **Listens**: `127.0.10.2:6006:6006` (Mac dials `http://phoenix:6006`) → `phoenix:6006` (HTTP UI + OTLP HTTP `/v1/traces`); `127.0.10.3:4317:4317` (gRPC OTLP) → `phoenix:4317`
- **Internal**: `9090/tcp` (Prometheus metrics; not published)
- **Callers**:
  - `litellm` → `http://phoenix:6006/v1/traces` (arize_phoenix callback; OTLP HTTP)
- **Auth**: PHOENIX_SECRET signs session JWTs (NOT the login password). First login is `admin@localhost` / `admin` with forced reset.
- **Healthcheck**: `curl -s http://phoenix:6006/healthz`
- **Source**: `services.yml` (`phoenix`), `bin/start-phoenix.sh`, `installer/lib/aliases.tsv`

### `falkordb` (docker)

- **Listens**: `127.0.10.7:6379:6379` (Mac dials `redis://falkordb:6379`) → `falkordb:6379` (Redis RESP). Browser UI on `127.0.10.8:3000:3000` → `falkordb-ui` alias (distinct IP resolves the `:3000` collision with `workspace`).
- **Internal**: none
- **Callers**: No callers currently wired in services.yml; reserved for future graph-memory work
- **Healthcheck**: `(echo > /dev/tcp/falkordb/6379) 2>/dev/null && echo ok` (TCP-level), or `curl http://falkordb-ui:3000/` for browser
- **Source**: `services.yml` (`falkordb`), `bin/start-falkordb.sh`, `installer/lib/aliases.tsv`

### `qdrant` (docker)

- **Listens**: `127.0.10.5:6333:6333` (Mac dials `http://qdrant:6333`) → `qdrant:6333` (REST)
- **Internal**: `6334/tcp` (gRPC; not published)
- **Callers**:
  - `docs_ingestor` → `http://qdrant:6333` (host-side; collection `ai-stack-docs`, vectors size 768 — `embed-local` = Ollama `nomic-embed-text`)
  - `docs_mcp` → `http://qdrant:6333` (host-side search reads)
- **Healthcheck**: `curl -s http://qdrant:6333/collections`
- **Source**: `services.yml` (`qdrant`), `bin/start-qdrant.sh`, `installer/phases/06_documents.sh`

### `honcho` (compose) — 4 containers

The compose stack publishes one host port via the alias scheme and keeps three services container-internal. `api` and `deriver` join both `honcho_default` (compose internal) and `ai-stack` (external) so they can reach LiteLLM and be reached by other ai-stack services.

| Container           | Container ports | Host ports                 | Role                              |
|---------------------|-----------------|----------------------------|-----------------------------------|
| `honcho-api-1`      | `8000/tcp`      | `127.0.10.6:8000:8000`     | FastAPI public surface            |
| `honcho-database-1` | `5432/tcp`      | **none** (compose-internal)| pgvector-on-Postgres 15           |
| `honcho-redis-1`    | `6379/tcp`      | **none** (intentionally)   | Job queue + cache (Redis 8.2)     |
| `honcho-deriver-1`  | `8000/tcp`      | **none**                   | Background worker (no API)        |

- **Callers** (Mac side): all Honcho host-side clients → `http://honcho:8000` (`HONCHO_BASE_URL`)
- **Egress**: `honcho-api-1` and `honcho-deriver-1` → `http://litellm.ai-stack:4000/v1` (fully-qualified Docker DNS — they're multi-network)
- **Healthcheck**: `curl -s http://honcho:8000/health`
- **Source**: `services.yml` (`honcho`), `honcho/docker-compose.yml`, `honcho/docker-compose.override.yml`, `installer/phases/03_honcho.sh`

### `openshell` (CLI + sandbox runtime)

- **Listens**: no host port. Sandboxes (`hermes-fleet-v1`, `pi-v1`) are reached via `openshell sandbox exec ...`.
- **Sandbox-internal**: `inference.local:443` (L7 proxy to LiteLLM); the sandbox is allowed to reach `honcho:8000`, `docs-mcp:8765`, and a small egress allowlist. It does NOT join the `ai-stack` Docker network (design D4).
- **Source**: `services.yml` (`openshell`), `installer/phases/04_openshell.sh`

### `hermes_fleet` (hermes-profiles inside sandbox)

- **Listens**: no direct host port of its own — the fleet's L7 gateway is published as the `hermes-gw` alias (`127.0.10.11:8642`). Profiles talk to `https://inference.local/v1` (the OpenShell L7 proxy).
- **Source**: `services.yml` (`hermes_fleet`), `installer/phases/04f_hermes_fleet.sh`

### `litellm_guardrails_builtin` and `litellm_guardrails_secrets` (litellm-feature)

- **Listens**: none — they're in-process LiteLLM callbacks (regex/keyword denylist; secrets-leak blocker).
- **Source**: `services.yml`, `installer/phases/04g_security.sh`

### `llm_guard` (docker)

- **Listens**: `127.0.10.12:8000:8000` (Mac dials `http://llm-guard:8000`) → `llm-guard:8000` (in network). Honcho also uses container port 8000 but on a different IP (`127.0.10.6`), so there's no host-side collision.
- ⚠ **Port caveat:** `services.yml`'s top-level `port: 8001` is a **stale/inconsistent v1 field** — the authoritative reach is `:8000` (the `aliases.tsv` row `llm-guard 127.0.10.12 8000 8000` and the running container both say `:8000`). Its own `config_notes` flag this. Use `:8000`.
- **Internal**: none
- **Callers**: LiteLLM's `guardrails.handler` (optional sidecar; the in-process callback is the first line — if this is down, requests warn but still complete).
- **Auth**: `AUTH_TOKEN=$LITELLM_MASTER_KEY` (bearer)
- **Healthcheck**: `curl -s http://llm-guard:8000/healthz` (best-effort; image's exact endpoint _unverified_)
- **Source**: `services.yml` (`llm_guard`), `bin/start-llm_guard.sh`, `installer/lib/aliases.tsv`

### `dual_llm_researcher` (agent-pattern)

- **Listens**: none. Prompting convention where the researcher reads through a summarizer first.
- **Source**: `services.yml` (`dual_llm_researcher`)

### `hermes_workspace` (compose)

- **Listens**: `127.0.10.10:3000:3000` (Mac dials `http://workspace:3000`) → `workspace:3000`
- **Internal**: two compose containers where the UI (`hermes-workspace`) runs **inside the `hermes-agent`'s network namespace** (`network_mode: service:hermes-agent`), sharing its loopback. Backend `hermes-agent` = gateway `:8642` + dashboard `:9119`. On the current **hermes-agent v0.18.0** workspace (pinned image `nousresearch/hermes-agent:v2026.7.1`; the override's inline `= v0.17.0` comment is stale, pre-dating the v0.18.0 cutover in `63e7a35`) the dashboard fail-closes on a non-loopback bind, so it binds `127.0.0.1` and the UI reaches it over the shared-netns loopback (`HERMES_DASHBOARD_URL=http://127.0.0.1:9119`); a pinned `HERMES_DASHBOARD_SESSION_TOKEN` authenticates the Sessions API. `:9119` is **never host-published** and, now loopback-bound in a netns shared only by the pair, is unreachable even by other bridge peers. The UI `:3000` and the gateway `:8642` are host-published **on the agent service** (the netns-child can't own ports): `:3000` on `127.0.0.1` + `127.0.10.10` (the `workspace` alias), `:8642` on `127.0.10.11` (the `hermes-gw` ingress alias). Both images are **digest-pinned** in `docker-compose.override.yml`; `upgrade hermes` re-resolves the newest `hermes-agent` release, moves the pin forward, re-verifies the Sessions sidebar, and **auto-rolls-back** on a drifted release.
- **Callers**: human in browser
- **Healthcheck**: `curl -s http://workspace:3000/`
- **Source**: `services.yml` (`hermes_workspace`), `installer/phases/05_uis.sh`, `installer/lib/aliases.tsv`

### `openwebui` (docker)

- **Listens**: `127.0.10.9:8080:8080` (Mac dials `http://openwebui:8080`) → `openwebui:8080` (container's native port)
- **Callers**: human in browser
- **Egress**: `http://litellm:4000/v1` (LiteLLM, via `ai-stack` Docker DNS)
- **Auth**: `WEBUI_AUTH=False` (relies on the loopback-only bind)
- **Healthcheck**: `curl -s http://openwebui:8080/health`
- **Source**: `services.yml` (`openwebui`), `bin/start-openwebui.sh`, `installer/lib/aliases.tsv`

### `docs_ingestor` (cli-only)

- **Listens**: none (one-shot or interactive sweep of `~/ai-stack/ingestor/inbox/`)
- **Egress**: `http://qdrant:6333` (Qdrant) and `http://litellm:4000/v1` (LiteLLM embeddings)
- **Source**: `services.yml` (`docs_ingestor`), `installer/phases/06_documents.sh`

### `docs_mcp` (python-bg)

- **Listens**: it's a **host** FastMCP process that binds **`0.0.0.0:8765`** (`ingestor/mcp_server.py:20`) — NOT a docker loopback publish. It binds `0.0.0.0` deliberately so the `docs-mcp` lo0 alias (`127.0.10.4`) is reachable (FastMCP's `127.0.0.1` default would make the alias unreachable). ⚠ A side-effect is that `:8765` is LAN-reachable while the process runs (see the External-facing summary). Reached as `http://docs-mcp:8765`; only up when `python mcp_server.py` is running (the alias stays reserved in `/etc/hosts` when it's down).
- **Callers**: MCP-aware agents inside OpenShell sandbox (`docs-mcp:8765` in the sandbox allowlist) or any local MCP client
- **Egress**: `http://qdrant:6333` and `http://litellm:4000/v1`
- **Source**: `services.yml` (`docs_mcp`), `installer/phases/06_documents.sh`, `installer/lib/aliases.tsv`

### `autofyn` (docker-compose)

- **Listens**: `127.0.10.13:3400:3400` (Mac dials `http://autofyn:3400`) → `autofyn:3400`
- **Healthcheck**: `curl -s http://autofyn:3400/`
- **Source**: `services.yml` (`autofyn`), `installer/phases/07_autofyn.sh`, `installer/lib/aliases.tsv`

### `paperclip` (node-bg)

- **Listens**: Paperclip's `pnpm dev` binds `127.0.0.1:3100` only. The `aliases.tsv` row maps `paperclip → 127.0.10.14:3100`, so `bin/start-paperclip.sh` runs a tiny Node TCP **relay** on `127.0.10.14:3100 → 127.0.0.1:3100`. So `http://paperclip:3100` works via the relay; `http://localhost:3100` hits Paperclip directly.
- **Embedded Postgres**: `pnpm dev` auto-provisions an embedded PostgreSQL (auto-generated password); not exposed. Inspect with `lsof -nP -iTCP -sTCP:LISTEN | grep -i postgres` if you need the live port.
- **Health**: `http://127.0.0.1:3100/api/health`. First build can take 60–120s before the port binds.
- **Source**: `services.yml` (`paperclip`), `installer/phases/08_paperclip.sh`, `bin/start-paperclip.sh`, `installer/lib/aliases.tsv`

### `deerflow` (docker-compose)

- **Listens**: `127.0.10.17:2026:2026` (Mac dials `http://deerflow:2026`) → the compose `nginx` front. **Now aliased** (was previously loopback-only pending an orchestrator decision).
- **Internal** (within `deer-flow` docker network): `nginx` → host port; `frontend` (Next.js); `gateway:8001` (FastAPI); `provisioner` (optional).
- **Lifecycle**: Phase 10 auto-starts via `bin/start-deerflow.sh`. Stop with `stack stop deerflow` (~520 MB), restart with `stack start deerflow`. Doctor check 28 guards the config patches. The model picker is data-driven from `deer-flow/config.yaml` `models:`.
- **Source**: `services.yml` (`deerflow`), `deer-flow/docker/docker-compose.yaml`, `installer/lib/aliases.tsv`

### `sourcegraph` (docker) — Phase 27 (opt-in)

- **Listens**: **DUAL-bound** — `127.0.0.1:7080` (host + the sandbox's `host.docker.internal:7080` path, gated by the `sourcegraph_mcp` network policy) AND `127.0.10.20:7080` (the `sourcegraph` lo0 alias). Loopback-only, never `0.0.0.0`. Reach it at `http://localhost:7080` or `http://sourcegraph:7080` (+ port-free `http://sourcegraph/` via `ingress up`).
- **Image**: `sourcegraph/server:6.12.5040` (the LAST single-container tag; amd64-emulated on Apple Silicon).
- **MCP**: native MCP server (12 tools) at `http://localhost:7080/.api/mcp`; every Hermes fleet profile is wired to it.
- **Requires**: `sudo vz-ai-stack.sh prepare-sudo` (for the `127.0.10.20` lo0 alias; a pre-flight guard errors clearly if missing).
- **Auth**: `SOURCEGRAPH_ADMIN_PASSWORD` bootstraps the admin + a `user:all` token.
- **Healthcheck**: `curl -s http://localhost:7080/`
- **Source**: `services.yml` (`sourcegraph`), `bin/start-sourcegraph.sh`, `installer/phases/27_sourcegraph.sh`, `installer/lib/aliases.tsv`

### `aionui` (node-bg) — Phase 28 (opt-in)

- **Listens**: `127.0.0.1:25808` — the prebuilt `aionui-web` standalone binary run as a loopback launchd daemon (`bin/start-aionui.sh`). Named alias `aionui → 127.0.0.1` lets the Mac browse `http://aionui:25808`. The desktop app is a separate brew cask. Not a container / not on the ai-stack bridge.
- **Auth/models**: uses `AIONUI_LITELLM_KEY` (scoped); models must be picked in the UI (unlike OpenWork, which pre-seeds).
- **Healthcheck**: `curl -s http://127.0.0.1:25808/`
- **Source**: `services.yml` (`aionui`), `bin/start-aionui.sh`, `installer/phases/28_aionui.sh`, `installer/lib/aliases.tsv`

### `openwork` (node-bg) — Phase 29 (opt-in)

- **Listens**: `127.0.0.1:8787` — the headless `openwork-orchestrator` binary run as a loopback launchd daemon (`bin/start-openwork.sh`), health-gated on `/health`. Named alias `openwork → 127.0.0.1` → browse `http://openwork:8787/ui` (append `#token=<OPENWORK_CLIENT_TOKEN>` to connect; `start openwork` opens a pre-tokened URL so you don't type it). Bound `127.0.0.1` ONLY (never `--remote-access`); `--approval manual`. Not a container.
- **Models**: PRE-SEEDED — Phase 29 writes `~/.openwork-stack/opencode.json` with a LiteLLM provider (`base URL http://127.0.0.1:4000/v1`, apiKey `{env:OPENWORK_LITELLM_KEY}` — literal key never on disk). Self-manages OpenCode (downloads sidecars on first run → no `opencode` host dependency).
- **Healthcheck**: `curl -s http://127.0.0.1:8787/health` → `200`
- **Source**: `services.yml` (`openwork`), `bin/start-openwork.sh`, `installer/phases/29_openwork.sh`, `installer/doctor/checks/51_openwork.sh`, `installer/lib/aliases.tsv`

### `understand` / `understand-mcp` (node-bg) — Phase 30 (opt-in)

- **Listens**: `127.0.0.1:7081` — the `understand-mcp` HTTP server (`bin/start-understand.sh`). The Hermes fleet containers dial it at `host.docker.internal:7081` (token-gated by `UNDERSTAND_MCP_TOKEN`). Host Claude Code / Pi use the **stdio** entrypoint (no port). NOT aliased (reached from containers via host-gateway, same pattern as lmstudio). Not on the ai-stack bridge.
- **Dashboard**: `vz-ai-stack.sh understand-dashboard` (separate foreground Vite serve, ephemeral port).
- **Healthcheck**: `curl -s http://127.0.0.1:7081/healthz`
- **Source**: `services.yml` (`understand`), `bin/start-understand.sh`, `installer/phases/30_understand.sh`

### `chatdev` (docker) — Phase 35 (opt-in)

- **Listens**: `127.0.10.18:5274:5173` ⚠ (host `5274` → container `5173`; Mac dials `http://chatdev:5274`). Vue+FastAPI web app; role agents collaborate to build software. On the `ai-stack` bridge.
- **Image**: `ai-stack/chatdev:local` (locally built).
- **Healthcheck**: `curl -s http://chatdev:5274/`
- **Source**: `services.yml` (`chatdev`), `installer/phases/35_*`, `installer/lib/aliases.tsv`

### `aitown` (compose) — Phase 36 (opt-in)

- **Listens**: a 3-container Convex compose stack, **all published loopback-only on `127.0.10.19`** (the override puts `ports: !override` on each so its loopback entries REPLACE upstream's `0.0.0.0` binds — the phase asserts no `0.0.0.0` survives in the merged `compose config`):
  - frontend `127.0.10.19:5273:5173` ⚠ (host `5273` → container `5173`; watch the town at `http://aitown:5273`)
  - Convex backend `127.0.10.19:3210:3210` + site-proxy `127.0.10.19:3211:3211`
  - Convex **admin dashboard** `127.0.10.19:6791:6791` (`http://127.0.10.19:6791`)

  Only the frontend `5273` gets an `aliases.tsv` row (`aitown`); the other three are published directly by the compose override.
- **Network**: the Convex containers stay on their OWN `ai-town-network` (bridge-exempt) and reach LiteLLM via `host.docker.internal:4000` — they do NOT join `ai-stack`. Compose project name pinned to `aitown` (load-bearing for doctor check 53's container-liveness census).
- **Source**: `services.yml` (`aitown`), `ai-town/`, `installer/phases/36_*`, `installer/lib/aliases.tsv`

### `agentscope` / `agentscope-studio` (Phase 33, opt-in)

- **`agentscope`** (cli-only): the framework. Run sims via `bin/agentscope agentscope/sims/<file>.py`; LLM calls route through LiteLLM (`AGENTSCOPE_LITELLM_KEY` → `http://127.0.0.1:4000/v1`) and trace to Phoenix. No listener.
- **`agentscope-studio`** (opt-in web GUI, `AGENTSCOPE_STUDIO=1`): a host launchd daemon (`as_studio`, npm `@agentscope/studio`) that VISUALIZES the OTLP trace spans the sims emit — it makes no LLM calls. Named alias `agentscope-studio → 127.0.0.1:5275`.
  - ⚠ **Security:** `as_studio` binds **`0.0.0.0`** (its `host:'localhost'` config is inert; there is no loopback-only flag), so BOTH the UI `:5275` AND its **OTLP gRPC receiver `:4318`** are UNAUTHENTICATED on every interface. The loopback posture relies entirely on NOT exposing this box — keep it off untrusted networks / behind a host firewall.
  - **OTLP `:4318` (not 4317):** the sims export traces to `http://127.0.0.1:4318`. `4318` is used (not the OTel default `4317`) because `phoenix-otlp` already owns `:4317` and `as_studio` binds `0.0.0.0`, so `:4317` would collide with / hijack Phoenix's OTLP intake.
- **Manage**: `bash bin/start-agentscope-studio.sh [install|status|stop|uninstall]`.
- **Source**: `services.yml` (`agentscope`), `bin/agentscope`, `bin/start-agentscope-studio.sh`, `installer/lib/aliases.tsv`

### `hermes_telegram` (sandbox-daemon) — Phase 20

- **Listens**: nothing on the host. Runs INSIDE `hermes-fleet-v1` (`hermes gateway run`), long-polls `api.telegram.org` directly (outbound). Lifecycle via hermes' own `gateway status/stop/restart`; liveness = doctor check 33. Secure-by-default (denies all until `HERMES_TELEGRAM_ALLOWED_USERS` set).
- **Source**: `services.yml` (`hermes_telegram`), `bin/start-hermes-telegram.sh`

### `hermes_slack` (sandbox-daemon) — Phase 38 (opt-in)

- **Listens**: nothing on the host. Runs INSIDE `hermes-fleet-v1` over **Socket Mode** (outbound WebSocket to `slack.com` — no inbound webhook/public URL). Maps one Slack app to the nine Hermes profiles with role prefixes (`techlead:`, `backend:`, …) and mission threads. Needs both `HERMES_SLACK_BOT_TOKEN` (xoxb-) and `HERMES_SLACK_APP_TOKEN` (xapp-). Secure-by-default.
- **Source**: `services.yml` (`hermes_slack`), `bin/start-hermes-slack.sh`

### `pi` (openshell-sandbox) — Phase 15

- **Listens**: nothing on the host. Pi runs inside the `pi-v1` OpenShell sandbox; launch via `bin/pi`.
- **Egress**: per `openshell/policies/pi-v1.yaml` — Pi can reach `host.docker.internal:4000` (LiteLLM), `:8000` (Honcho), `:8765` (docs-mcp), and npm/pypi/github. All else returns HTTP 403 `{"error":"policy_denied"}`.
- **Auth**: `PI_LITELLM_KEY` (minted in Phase 15). Assigned model is `local`. Pi never sees `LITELLM_MASTER_KEY`.
- **Stop / kill**: `bin/pi-kill`.
- **Source**: `services.yml` (`pi`), `installer/phases/15_pi.sh`, `bin/pi`, `openshell/policies/pi-v1.yaml`

### LiteLLM dual-bind note (Phase 15 side-effect)

Phase 15 needed `host.docker.internal:4000` to reach LiteLLM from inside the `pi-v1` sandbox VM. Inside that VM, `host.docker.internal` resolves to the Mac's `127.0.0.1`. So `bin/start-litellm.sh` publishes LiteLLM on BOTH `127.0.10.1:4000` (the canonical alias bind) AND `127.0.0.1:4000`. The host-side scoped-key clients (aionui/openwork/agentscope/…) also use the `127.0.0.1:4000` route. Doctor check 25 enforces the `host.docker.internal:4000` reach from inside the sandbox.

### LiteLLM Postgres backend (Phase 15 prerequisite)

LiteLLM's `/key/generate` (to mint scoped keys) requires a Postgres DB (its Prisma schema is hardcoded to `postgresql://`; SQLite unsupported). Rather than a dedicated container, `bin/start-litellm.sh` points at Honcho's `honcho-database-1:5432` via `host.docker.internal:5432` and uses a sibling database named `litellm`, **ensuring the `litellm` DATABASE exists on every start** (self-heals a cold/second machine). `installer/lib/litellm.sh` adds `litellm_smoke_ok` + `litellm_diagnose`. Coupling tradeoff: bringing Honcho down kicks LiteLLM's Prisma connection until it reconnects.

### `unsloth` (python-bg) — Phase 14

- **Listens**: `0.0.0.0:8898` on the host (Mac dials `http://unsloth:8898` or `http://localhost:8898`). ⚠ Shares `:8898` with the `models-serve` viewer — don't run both at once.
- **Internal**: Python FastAPI backend + OpenAI-compatible `/v1/*` (all auth-gated; bootstrap user `unsloth`, password at `~/.unsloth/studio/auth/.bootstrap_password`).
- **Healthcheck**: `curl -s http://unsloth:8898/api/health`
- **Source**: `services.yml` (`unsloth`), `installer/phases/14_unsloth_studio.sh`, `bin/start-unsloth.sh`, `installer/lib/aliases.tsv`

### `mempalace` (cli-only) — Phase 26

- **Listens**: none. Local-first **verbatim** Claude Code conversation memory, CLI + MCP. Run via `bin/mempalace`; auto-save hooks via `bin/mempalace-hooks`.
- **Embeddings**: on-device (CoreML; default `all-MiniLM-L6-v2` 384-dim). Storage: on-device ChromaDB. Optional refiner LLM → `http://litellm:4000/v1` with `MEMPALACE_LITELLM_KEY`.
- **Source**: `installer/phases/26_mempalace.sh`, `bin/mempalace`, `installer/doctor/checks/44_mempalace.sh`

### Other CLI-only services (no listener)

`halo` (11, `bin/halo`), `rlm` (18, `bin/rlm` — REPL in a Docker sandbox), `metagpt` (32, `bin/metagpt`), `oasis` (34, `bin/oasis`), `concordia` (37, `bin/concordia`), `ace` (17), `lumen_mcp` (16), `portless` (21), `cmux` (22), `skillspector` (23), `openagents` (24), `blaxel_cli` (12, cloud), `autoreason` (11, disabled), `remnic_hermes` (09, disabled), `byterover_cli` (09, disabled), `paperclip_honcho_plugin` (08). All run on demand and route LLM calls (if any) through LiteLLM with their own scoped keys → traced in Phoenix.

---

## Conflict notes

Under the `127.0.10.x` scheme each alias has its own IP, so most "same host port, different service" collisions are resolved by distinct binding IPs.

| # | Collision                                                  | Resolution                                                                                                                | Source                                            |
|---|------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------|---------------------------------------------------|
| 1 | **FalkorDB :6379** vs **Honcho's redis :6379** (RESP)      | FalkorDB owns `127.0.10.7:6379`. Honcho's compose override blanks Honcho-redis's host publish; `api`/`deriver` reach it over `honcho_default` at `redis:6379`. | `installer/phases/03_honcho.sh`             |
| 2 | **FalkorDB Browser :3000** vs **Hermes Workspace :3000**   | Distinct IPs: `falkordb-ui` `127.0.10.8:3000`, `workspace` `127.0.10.10:3000`.                                             | `bin/start-falkordb.sh`, `services.yml` |
| 3 | **LLM Guard :8000** vs **Honcho API :8000**                | Distinct IPs: `llm-guard` `127.0.10.12:8000`, `honcho` `127.0.10.6:8000`.                                                  | `bin/start-llm_guard.sh`                       |
| 4 | **ChatDev :5173** vs **AI Town :5173** (container)         | Both serve Vite on container `:5173` but publish distinct host ports on distinct IPs: `chatdev` `127.0.10.18:5274`, `aitown` `127.0.10.19:5273`. | `services.yml` (`chatdev`,`aitown`) |
| 5 | **`unsloth` :8898** vs **`models-serve` viewer :8898**     | Both bind host `:8898` — do NOT run both at once. `models-serve` is an on-demand viewer; give it a different port or use `ingress add`. | `installer/lib/models-serve.sh:27`, `installer/lib/ingress.sh:490` |
| 6 | **AgentScope Studio OTLP :4318** vs **Phoenix OTLP :4317** | Studio pins its OTLP gRPC receiver to `:4318` precisely BECAUSE `phoenix-otlp` owns `:4317` and `as_studio` binds `0.0.0.0` (would hijack Phoenix). | `installer/lib/aliases.tsv` (comment), `services.yml` (`agentscope`) |
| 7 | Phoenix's `9090` (Prometheus) vs Honcho's commented-out Prometheus `9090` | Honcho's monitoring is commented out; Phoenix's `9090` is container-internal, not published.                | `honcho/docker-compose.yml`               |

The doctor check that catches non-docker collisions: `installer/doctor/checks/11_port_collisions.sh` — scans by `IP:PORT` pair (not bare port) per row in `installer/lib/aliases.tsv`.

---

## Reserved-but-not-bound ports

These ports are declared in `services.yml` / `aliases.tsv` but only listen when their service is actively running (many are opt-in phases not in `install all`).

| Port  | Service            | Why it might not be listening                                                                     |
|-------|--------------------|---------------------------------------------------------------------------------------------------|
| 8765  | `docs_mcp`         | Foreground `python mcp_server.py`; only up when the user runs it.                                  |
| 3100  | `paperclip`        | `bin/start-paperclip.sh`; reached on the alias via the `127.0.10.14:3100 → 127.0.0.1:3100` relay.  |
| 3400  | `autofyn`          | Clone may not be present (best-effort upstream).                                                   |
| 2026  | `deerflow`         | Phase 10 auto-starts via `bin/start-deerflow.sh`; stop/start with `stack stop\|start deerflow`.     |
| 7080  | `sourcegraph`      | Opt-in Phase 27; dual-bound `127.0.0.1` + `127.0.10.20`.                                            |
| 25808 | `aionui`           | Opt-in Phase 28; loopback launchd daemon.                                                          |
| 8787  | `openwork`         | Opt-in Phase 29; loopback launchd daemon (first start downloads OpenCode sidecars).                |
| 7081  | `understand-mcp`   | Opt-in Phase 30; loopback daemon dialed by the fleet via host-gateway.                             |
| 5274  | `chatdev`          | Opt-in Phase 35; host `5274` → container `5173`.                                                    |
| 5273  | `aitown`           | Opt-in Phase 36; host `5273` → container `5173`.                                                    |
| 5275  | `agentscope-studio`| Opt-in (`AGENTSCOPE_STUDIO=1`); binds `0.0.0.0` (see security note).                                |
| 4318  | `agentscope-studio`| OTLP gRPC trace receiver; only when Studio is enabled.                                             |
| 5432  | `honcho-database-1`| Only when honcho compose is up (LiteLLM's key store rides on it).                                  |

---

## How to verify

Run this as the user. It prints every host-listening TCP socket alongside the owning process.

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

# Per-container actual bindings:
docker inspect <name> --format '{{json .HostConfig.PortBindings}}' | jq

# The effective merged alias set on THIS machine (shared + aliases.local.tsv):
vz-ai-stack.sh ingress list
```

Spot-check that bound-to-127.0.10.x / 127.0.0.1 holds (no `0.0.0.0` leak from a container):

```bash
docker ps --format '{{.Names}}: {{.Ports}}' | \
  grep -vE '127\.0\.(10\.|0\.1)|^[^:]+: *$'   # should print nothing
```

(The `^[^:]+: *$` arm drops containers that publish no port — `docker ps`
emits a trailing space for an empty `{{.Ports}}`, so the ` *` is needed to
anchor it.)

> **Note:** this audit only covers **containers**. Three *host* processes
> bind `0.0.0.0` by design — `docs_mcp` (:8765), `unsloth` (:8898), and
> `agentscope-studio` (:5275/:4318) — so they won't appear in `docker ps`
> at all. See the [External-facing summary](#external-facing-summary) for
> the host-listener security posture.

---

## External-facing summary

**Every ai-stack *container* binds to a `127.0.10.x` (or `127.0.0.1`) loopback address only.** No container listens on `0.0.0.0`, so no *container* port is exposed to the LAN (host processes are the exception — see the table below). Aliases are populated into `/etc/hosts` and Docker's embedded DNS by Phase 00·N; the opt-in Phase 31 ingress adds port-free `http://name/` via a host-native Caddy on the same loopback IPs.

**Host processes are a different story — three of them bind `0.0.0.0`, so they ARE LAN-reachable while running.** These are NOT containers (so they don't violate the container guarantee above), but they are not loopback-bound either:

| Host listener        | Bind          | Installed by default? | Note                                                                 |
|----------------------|---------------|-----------------------|----------------------------------------------------------------------|
| `docs_mcp`           | `0.0.0.0:8765`| **Yes** (Phase 06)    | Binds `0.0.0.0` so the `127.0.10.4` lo0 alias resolves; LAN-reachable while up. |
| `unsloth`            | `0.0.0.0:8898`| No (Phase 14)         | FastAPI + OpenAI-compat, but auth-gated.                              |
| `agentscope-studio`  | `0.0.0.0:5275` + OTLP `0.0.0.0:4318` | No (opt-in flag) | Unauthenticated UI + OTLP receiver — the highest-risk of the three.  |

The remaining non-container host listeners are loopback-bound: `ollama` (`127.0.0.1:11434`) and the opt-in host daemons `aionui`, `openwork`, `understand-mcp`, `sourcegraph`. **Mitigation for the three `0.0.0.0` binders:** keep this box off untrusted networks / behind a host firewall (macOS `pf`), don't port-forward, and prefer stopping `unsloth`/`agentscope-studio` when idle. (`docs_mcp`'s `0.0.0.0` bind is a deliberate lo0-reachability workaround — a future hardening could dual-bind the specific alias IP instead.)

The audit script `bin/audit.sh` (phase 04·G) enforces the container guarantee as one of its checks (verbatim from `bin/audit.sh`):

```bash
bad="$(docker ps --format "{{.Ports}}" \
  | tr "," "\n" \
  | grep -E "\->" \
  | grep -vE "^ *(127\.[0-9.]+:|\[::1\]:)" || true)"
# non-empty $bad → a container published a non-loopback bind → FAIL
```

It splits each container's port list on `,`, keeps only published mappings (`->`), and flags any whose bind-IP is not `127.x.x.x` (covers both `127.0.0.1` and `127.0.10.x`) or IPv6 loopback `[::1]`. A failing audit means a **container** leaked to `0.0.0.0` — investigate immediately. (It is container-scoped, so it does NOT catch the three host `0.0.0.0` processes above — those aren't in `docker ps`.)

External egress (LiteLLM → Anthropic / OpenAI / OpenRouter / Google / OpenAI-compat routes over HTTPS) is unrelated to ingress and unaffected by this guarantee. See [DEPENDENCIES.md § Talks-to matrix](DEPENDENCIES.md#talks-to-matrix) for the full egress list.
