# Operations

Daily commands and common recipes. For initial install, see [INSTALL.md](INSTALL.md).

---

## The `stack` command

After install, `~/ai-stack/bin/stack` is a thin wrapper around `vz-ai-stack.sh`
subcommands. Add `~/ai-stack/bin` to your `$PATH` (the installer prints the
exact line to add):

```bash
echo 'export PATH="$HOME/ai-stack/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Then everywhere below, `stack <cmd>` is equivalent to `bash ~/ai-stack/vz-ai-stack.sh <cmd>`.

---

## The commands you'll actually use

```bash
stack                                   # interactive install/resume
stack deps [--check]                    # bootstrap host deps; --check = read-only CI gate (see PREREQUISITES.md)
stack setup                             # interactive, skippable .env / API-key bootstrap (alias: keys)
stack phases                            # list every phase as id → name (also: steps, list)
stack install <phase|all>               # install one phase by NAME or number (or everything)
stack install <phase|all> --dry-run     # read-only preview of what would run (alias: --plan)
stack verify                            # Phase 00·V — 6 runtime probes; no install
stack status                            # declared vs actual table + host-memory pressure + auto-heal posture
stack <cmd> --help  /  stack help <cmd> # focused per-command usage (bare `help`/`--help` = full list)
stack help <svc>|services|regen         # what it is · how it's configured · how to use (see below)
stack model list|assign|sync|superset   # declarative model<->agent binding (see models.md)
stack fleet list|add|remove|new|destroy # Hermes 9-role fleet manager (see models.md / STACK-GUIDE)
stack doctor                            # 70 health checks + auto-fix offers
stack doctor <filter>                   # only checks whose name contains <filter>
stack test <phase>                      # smoke test for one phase (name or number)
stack adopt <svc>                       # take ownership of a foreign container
stack apply-restarts                    # drain the queued-restart list
stack logs <container> [-f]             # docker logs wrapper
stack gc                                # remove partial container orphans
stack reset --confirm soft|hard|nuke    # tiered destructive reset
```

### Phases by name or number

`install` and `test` accept a **phase name OR number**. Phase files are
`<id>_<name>.sh`, so the name is the filename suffix — `vz-ai-stack.sh install phoenix`
is the same as `install 01h`. `vz-ai-stack.sh phases` prints the full `id → name` table.

```bash
stack install phoenix          # == install 01h
stack install telegram         # alias → hermes_telegram (Phase 20)
stack install lmstudio         # opt-in Phase 25
stack test inference           # alias → smoke test for phase 01 (litellm)
```

Friendly aliases: `litellm`→inference, `telegram`→hermes_telegram,
`slack`→hermes_slack, `hermes`→hermes_fleet, `sandbox`→openshell,
`unsloth`→unsloth_studio, `halo`→halo_autoreason, `ui`→uis, `docs`→documents,
`memory`→alt_memory. The
resolver tries id-prefix → exact-name → alias → unique fuzzy match; an ambiguous
or unknown selector errors and points you at `stack phases`.

The **17 opt-in extras** (Phases 21–25, 27–38: `portless`, `cmux`, `skillspector`,
`openagents`, `lmstudio`, `sourcegraph`, `aionui`, `openwork`, `understand`, `ingress`, `metagpt`, `agentscope`, `oasis`, `chatdev`, `aitown`, `concordia`, `slack`) are NOT part of `install all` — add them
individually by name. Their doctor checks (34–38, 49, 50, 51, 52, 57–61) pass-as-skip until installed.

### Per-service help (`stack help`)

`stack help <service>` prints three things for any service: **what it is**, **how
it's configured** (computed live from `services.yml` + aliases + the rendered
config — not hand-maintained), and **how to use it**. Prose lives in the `help:`
blocks in `services.yml`; the "how it's configured" section is derived at runtime.

```bash
stack help                       # overview + pointer to `help services`
stack help services              # list services that have help prose
stack help litellm               # what / how-configured / usage for one service
stack help regen [<svc>]         # refresh help prose from the live codebase via the
                                 #   stack's own LiteLLM gateway (drafts to a staging
                                 #   file + diff). --apply writes it back; --check is a
                                 #   CI staleness gate; --model <m> picks the drafting model.
```

### Bootstrap helpers (`deps`, `setup`, `--dry-run`, per-command help)

```bash
stack deps                       # show the host-dependency map; install/start anything missing
stack deps --check               # read-only; non-zero exit if anything's missing/down (CI gate)
stack setup                      # interactive .env / API-key bootstrap (alias: stack keys)
stack install all --dry-run      # preview: host-dep status + each phase ✓already / •would-run; changes nothing
stack install all --plan         # alias for --dry-run
stack install --help             # per-command usage (same as `stack help install`)
```

- **`deps`** (`installer/lib/deps.sh`) is the authoritative host-dependency
  bootstrap — it verifies, installs, starts, and re-verifies Homebrew + the core
  CLI tools + OrbStack + Ollama. `--check` is the read-only CI gate. It runs as
  your normal user (no sudo). [PREREQUISITES.md](PREREQUISITES.md) is its companion map.
- **`setup`** (alias **`keys`**) is an interactive, fully skippable `.env` / API-key
  bootstrap. It always ensures the non-interactive baseline first (generates
  `LITELLM_MASTER_KEY` + `PHOENIX_SECRET`, service-URL defaults), then offers each
  *optional* external secret (cloud LLM keys, Helicone, GitHub, Blaxel, Telegram) —
  every prompt is skippable (Enter = keep/skip), written `0600`, never echoed. A
  **local-only or Claude-subscription (`-sub`) setup needs ZERO keys** — skip every
  prompt and you still reach `doctor`. ANY `install` (whether `install all` or a single
  `install <phase>`) makes ensuring this `.env` baseline its **first step**, then
  auto-offers `setup` on first run only when interactive (TTY) and no cloud key is set
  yet; non-interactive/CI never blocks.
- **`install … --dry-run`** (alias **`--plan`**) is a read-only preview: it prints the
  host-dependency status plus every phase in run-order marked `✓ already-complete` vs
  `• would-run`. It makes **no** changes — never runs preflight, never takes the lock,
  never runs a phase body. Works for `all`, a single phase, and the `--plan` alias.
- **Per-command help** — `stack <cmd> --help` (or `stack help <cmd>`) prints focused
  usage for one subcommand; a bare `stack help` / `stack --help` prints the full
  command list. (`stack help <service>` / `help services` / `help regen` go to the
  per-service help above.)

`stack verify` is the cheapest health probe in the toolbox — it does not
install or restart anything; it just confirms the alias chain
(lo0 + /etc/hosts + Docker DNS + `--add-host=ollama:host-gateway` +
end-to-end routing) still works. Run it after any networking change
(VPN connect/disconnect, OrbStack restart) before assuming the stack
is healthy.

---

## Recipes

### Send a chat request through LiteLLM

```bash
KEY="$(grep ^LITELLM_MASTER_KEY= ~/ai-stack/.env | cut -d= -f2-)"

curl -s http://litellm:4000/v1/chat/completions \
  -H "Authorization: Bearer $KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"hello"}]}' \
  | jq -r ".choices[0].message.content"
```

Mac and container both dial `http://litellm:4000` — the URL form is
identical on both sides (each HTTP service publishes on its native
container port; see [CHANGELOG.md 2026-05-28 entry](../CHANGELOG.md) for
why we don't use port 80 anymore).

Use any model from `~/ai-stack/services.yml` (or `curl /v1/models | jq`).
Verified models: `local`, `local-heavy`, `local-nemotron3-nano-4b`,
`claude-sonnet`, `claude-opus`, `openai-gpt-5.5`, `openrouter-claude-opus-4.7`,
`google-gemini-3.1-pro`, plus more (the retired `local` / `local-heavy` /
`local` slugs still resolve for old keys but aren't auto-pulled — use
`local`). Run `vz-ai-stack.sh model list` for the live per-agent matrix.

### Watch traces stream

```bash
docker exec litellm tail -f /traces/litellm.jsonl
```

Each line is one chat call: `ts`, `kind` (success/failure), `model`,
`messages`, `response`, `latency_ms`, `cost`.

### Open the Phoenix dashboard

```bash
open http://phoenix:6006
```

Log in as `admin@localhost` / (your password). Click the **ai-stack** project
(not `default` — that's the catch-all for untagged traces).

### Working with aliases

After install, services are reached by name on both the Mac and from within
containers. Concrete examples:

```bash
# Mac side — same URL form as container side
curl -sf http://litellm:4000/health
curl -sf http://phoenix:6006/healthz
curl -sf http://qdrant:6333/collections
open http://openwebui:8080

# Redis-protocol services use their native port form
redis-cli -h falkordb -p 6379 PING

# Resolve from the Mac to confirm /etc/hosts is correct
dscacheutil -q host -a name litellm     # → ip_address: 127.0.10.1
host litellm                            # same answer via mDNSResponder
awk '$2=="litellm"{print $1}' /etc/hosts # fallback if DNS layer is unhappy

# Verify lo0 is bound (required because macOS does not auto-route 127.0.0.0/8)
ifconfig lo0 | grep 127.0.10            # one line per alias from aliases.tsv

# Container side — bare names via Docker DNS, same explicit container port
docker run --rm --network ai-stack alpine getent hosts litellm
docker exec litellm wget -qO- http://phoenix:6006/healthz
docker exec litellm wget -qO- http://ollama:11434/api/tags

# List who's on the ai-stack network
docker network inspect ai-stack --format '{{range .Containers}}{{.Name}} {{end}}'
```

If an `http://<alias>:<port>` curl returns "connection refused" or hangs,
run `bash vz-ai-stack.sh verify` — Phase 00·V's probes pinpoint which layer
broke (lo0 binding, /etc/hosts, DNS, host-gateway, end-to-end). See
[TROUBLESHOOTING.md § Connection refused](TROUBLESHOOTING.md) for the
manual diagnosis sequence.

### Flip a service on/off

```bash
# Disable Open WebUI (don't stop, just declare disabled — `apply` then stops it)
yq -i '.services.openwebui.enabled = false' ~/ai-stack/services.yml

# Then either run the doctor (reports drift) or stop manually:
docker stop openwebui

# Re-enable
yq -i '.services.openwebui.enabled = true' ~/ai-stack/services.yml
vz-ai-stack.sh start openwebui
```

### Recreate one container (drift detected)

```bash
stack apply-restarts                  # drains the queue (recommended)

# Or one-off:
bash ~/ai-stack/bin/start-litellm.sh --recreate   # backup → docker rm -f → start
```

Conservative: `--recreate` is the only way to silently destroy a managed
container.

### Ingest a doc into the RAG (phase 06)

```bash
# Drop a file
cp ~/Downloads/manual.pdf ~/ai-stack/ingestor/inbox/

# Run the ingester (one-off; not a daemon by default)
cd ~/ai-stack/ingestor
source .venv/bin/activate
python ingest.py

# Or serve the MCP server for agents (cohesive way; binds :8765)
vz-ai-stack.sh start docs_mcp        # (low-level: python mcp_server.py)
```

The MCP server exposes a `search_documents(query, top_k)` tool that Hermes
profiles (especially `hermes_ml_engineer`) can call.

### Run the 4/4 security audit

```bash
bash ~/ai-stack/bin/audit.sh
```

Checks: 127.0.10.x loopback-only binds; `.env` is 0600; guardrails.handler
loaded without ImportError; obvious-bad prompt is denied with HTTP 400.

### Switch memory-mode profile

`services.yml` declares 4 profiles (`fleet`, `coding`, `research`, `paranoid`)
that bulk-enable / bulk-disable services. To switch:

```bash
# What's in each profile:
yq '.profiles' ~/ai-stack/services.yml

# Apply (currently manual — flip enabled flags then re-apply):
# (No `stack profile <name>` shortcut yet; mutate services.yml then run install)
```

### See what you decided when

```bash
stack history
```

Assembles `CHANGELOG.d/<run-id>.md` files into one timeline. Useful when "wait,
when did I change that?"

---

## Hermes Telegram gateway (Phase 20)

The native hermes gateway runs **inside** the `hermes-fleet-v1` sandbox (it is not
a host daemon — a process started in the sandbox self-persists, and it long-polls
`api.telegram.org` directly via Phase 04's `telegram` egress policy). Lifecycle is
hermes' own commands; the stack just (re)starts it idempotently.

```bash
OSH=/opt/homebrew/bin/openshell

# Start / restart (idempotent — ends with exactly one gateway on the latest config):
bash ~/ai-stack/bin/start-hermes-telegram.sh
# or, to also (re)apply token + allowlist from .env:
bash ~/ai-stack/vz-ai-stack.sh install 20

# Status / logs / stop:
$OSH sandbox exec -n hermes-fleet-v1 -- hermes gateway status
$OSH sandbox exec -n hermes-fleet-v1 -- tail -f /sandbox/.hermes-gateway.log
$OSH sandbox exec -n hermes-fleet-v1 -- hermes gateway stop
```

**Access control (read this before expecting replies).** The gateway is
secure-by-default: with no allowlist it DENIES every user. Set ONE in `.env`, then
re-run `install 20`:

- `HERMES_TELEGRAM_ALLOWED_USERS=<id>[,<id>…]` — numeric Telegram user ids (find
  yours by DMing `@userinfobot`). **Recommended.**
- `HERMES_TELEGRAM_ALLOW_ALL=true` — open access. Not advised (the bot drives 9
  profiles).

`stack status` shows `hermes_telegram` as `n/a` (it's a sandbox-internal daemon);
the real liveness probe is `doctor` check 33. See
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) if the bot doesn't reply.

---

## Hermes Slack gateway (Phase 38, opt-in)

Opt-in Slack role router for the Hermes fleet. By default ai-stack disables the
upstream native Slack adapter and runs `/sandbox/fleet-boot/hermes_slack_role_router.py`
inside `hermes-fleet-v1`. The router uses **Socket Mode** — an OUTBOUND WebSocket to
slack.com (Phase 04's `slack` egress policy) — so there is no inbound webhook and no
exposed port. Tokens + allowlist live in `.env`; `install 38` writes them into the
sandbox and (re)starts the router.

```bash
OSH=/opt/homebrew/bin/openshell

# Start / restart (idempotent — latest Slack role-router config):
bash ~/ai-stack/bin/start-hermes-slack.sh
# or, to also (re)apply tokens + egress + allowlist from .env:
bash ~/ai-stack/vz-ai-stack.sh install 38            # alias: install slack

# Status / logs / stop:
$OSH sandbox exec -n hermes-fleet-v1 -- cat /sandbox/.hermes-slack/health.json
$OSH sandbox exec -n hermes-fleet-v1 -- tail -f /sandbox/.hermes-slack-role-router.log
$OSH sandbox exec -n hermes-fleet-v1 -- bash -c 'kill "$(cat /sandbox/.hermes-slack-role-router.pid)"'
```

**Access control (read this before expecting replies).** The role router is
secure-by-default: with no allowlist it DENIES every user. Set your Slack member id
in `.env`, then re-run `install 38`:

- `HERMES_SLACK_ALLOWED_USERS=<U…>[,<U…>…]` — Slack member ids (Slack profile → ⋮
  *More* → *Copy member ID*). Allowlisted users have normal Hermes operator
  authority through Slack: DMs, channel mentions, `sre:`, `incident:`, `release:`,
  and custom role/group routes enqueue work for the corresponding Hermes profile.
- `HERMES_SLACK_ALLOW_ALL=true` — does **not** grant role-router operator
  authority. It is only honored when `HERMES_SLACK_ROLE_ROUTER=false` returns Slack
  to the upstream native adapter.

Needs BOTH `HERMES_SLACK_BOT_TOKEN` (`xoxb-…`) and `HERMES_SLACK_APP_TOKEN`
(`xapp-…`, `connections:write` for Socket Mode); create the app at
<https://api.slack.com/apps>. `stack status` shows `hermes_slack` as `n/a` (a
sandbox-internal daemon); the real liveness probe is `doctor` check 67. See
[TROUBLESHOOTING.md](TROUBLESHOOTING.md) if the bot doesn't reply.

---

## Which model each agent uses (declarative, per-agent)

Each agent's LLM is **declared per-agent** in `installer/models.yml` (the single source
of truth) and rendered into every agent's config by `vz-ai-stack.sh model {list,assign,sync,superset}`.
See [models.md](models.md) for the full reference. One local chat model (nemotron-only, 2026-07-01):

| model | runtime | role |
|---|---|---|
| `local` / `local-heavy` (`nemotron-3-nano:4b`, ~2.8 GB) | Ollama | the ONLY local chat model + always-on fallback every agent gates to when its runtime is down; light + fast. Both aliases map here. |
| `local-nemotron3-nano-4b-mlx` (opt-in) | LM Studio MLX | the same nemotron model on Apple MLX (Phase 25, opt-in) |

Shipped assignments: every agent routes to the **Claude Opus subscription via
Meridian**, uniformly — all nine Hermes roles (`hermes_manager`, `hermes_techlead`,
`hermes_ml_engineer`, `hermes_frontend_engineer`, `hermes_backend_engineer`,
`hermes_qa_test_engineer`, `hermes_reviewing_engineer`, `hermes_sre_engineer`,
`hermes_incident_manager`) plus `pi`, `deerflow`, `ace`, and `rlm` →
`claude-opus-sub-max`. A subscription-assigned agent **auto-falls-back to `local`** when
the Meridian host daemon is down, so a plain `install all` works with no Meridian. To
activate the subscription models: bring Meridian up (`bin/start-meridian.sh`), then
`vz-ai-stack.sh model sync`.

```bash
vz-ai-stack.sh model list                 # read-only catalog + live per-agent matrix
vz-ai-stack.sh model assign pi local   # re-point one agent (then syncs it)
vz-ai-stack.sh model assign all local       # blanket-assign EVERY agent (before→after + models.yml.bak), then syncs
vz-ai-stack.sh model sync [<agent>]       # render every agent + the LiteLLM model_list (crash-safe)
vz-ai-stack.sh model superset             # print the canonical scoped-key allowlist
```

Ollama is kept lazy (`OLLAMA_KEEP_ALIVE=30m`, the default model stays warm for 30 min
of inactivity, then unloads). `nemotron-3-nano:4b` is the ONLY local chat model (~2.8 GB,
2026-07-01); `local` and `local-heavy` both map to it — there is no heavy 27B local
model anymore. The opt-in LM Studio MLX slug (`local-nemotron3-nano-4b-mlx`) serves the
same nemotron model on Apple MLX.

---

## OpenShell CPU-storm watchdog (warn-only by default)

A sandbox's gateway token expires after ~8 h, and the in-sandbox agent then retries
log-push with no backoff → a ~36%-CPU-per-sandbox `ExpiredSignature` storm. **Only
recreating the sandbox mints a fresh token (a gateway restart does not).** Phase 04
installs a launchd watchdog (`com.ai-stack.openshell-watchdog`, every 600 s) that
detects the storm. By **default it is warn-only and data-safe**: it halts the
container to stop the CPU burn and writes an alert (surfaced by `doctor` check 43)
— it does **not** delete/recreate the sandbox, because recreation discards in-sandbox
state. You recreate when ready (`vz-ai-stack.sh install 04 04f 15 20 04h`), then clear
the alert (`rm installer/state/openshell-watchdog.alert`). Opt into automatic
delete+recreate (capability-checked, Ready-verified, fails loud) with
`AI_STACK_WATCHDOG_RECREATE=1`.

```bash
WD=~/ai-stack/bin/openshell-watchdog.sh
$WD status        # is the launchd job loaded? last run / exit
$WD run           # run one detect cycle now (warn-only; halts the burn, raises an alert)
$WD uninstall     # remove the launchd timer
$WD install       # (re)install it
AI_STACK_WATCHDOG_RECREATE=1 $WD run   # opt-in: also delete+recreate the dead sandbox
```

Logs: `installer/state/openshell-watchdog.log`. The on-demand twin is `stack doctor
openshell` (check 39); a pending alert surfaces in check 43. Full failure write-up in
[TROUBLESHOOTING.md § OpenShell CPU storm](TROUBLESHOOTING.md).

---

## LM Studio (opt-in, quit it when done)

LM Studio (Phase 25) is a *second* local runtime behind LiteLLM (Apple MLX, home of
`local-nemotron3-nano-4b-mlx`) — Ollama stays the default. It is **opt-in**
because the LM Studio desktop app idle-spins ~0.8–1 core **even with no model loaded
and the server stopped**. Run it only when you need MLX, and quit it afterward.

`install lmstudio` is **assignment-driven**: it loads ONLY the MLX models you've
assigned to an agent in `models.yml` (`model assign <agent> local`) — it does
**not** auto-load anything otherwise. (The retired LFM2.5 demo `local-lfm2-mlx` is no
longer wired by default; it remains an `LMS_LOAD_LFM2=1` install-time opt-in.)

Run the server with `vz-ai-stack.sh start lmstudio` (idempotent; macOS-guarded). It
prints the endpoint, warns the app idle-spins ~0.8 core (quit when done), and reminds
you **no model auto-loads** — assign one in `models.yml` + `vz-ai-stack.sh model sync`.
`vz-ai-stack.sh stop lmstudio` stops the `:1234` server.

```bash
stack install lmstudio                          # one-time setup: loads only assigned MLX models
vz-ai-stack.sh start lmstudio                   # start the :1234 server (idempotent)
vz-ai-stack.sh stop lmstudio                    # stop the server when done…
#   …then Cmd-Q the LM Studio app (stopping the server alone is not enough)
```

Lighter headless alternative: `pip install mlx-lm` → `mlx_lm.server`. See
[TROUBLESHOOTING.md § LM Studio CPU](TROUBLESHOOTING.md).

---

## MemPalace verbatim memory (Phase 26)

MemPalace is installed by `install all` (Phase 26, appended last) — local-first **verbatim**
conversation memory for Claude Code — CLI + MCP, no daemon, no host port. Embeddings
run **on-device** (CoreML, default `all-MiniLM-L6-v2` 384-dim; `embeddinggemma`
opt-in); there are no cloud embeddings. Storage is on-device ChromaDB. An optional
refiner LLM routes via LiteLLM (`MEMPALACE_LITELLM_KEY`). Install is **PyPI-only**
(`mempalace.tech` is a malware squat — never install from it).

```bash
stack install 26                              # add it (Phase 26; first mine downloads a ~80MB
                                              #   on-device model once — retry if it times out)

# Day-to-day (the bin/mempalace wrapper):
bash ~/ai-stack/bin/mempalace wake-up         # prime a fresh session with prior context
bash ~/ai-stack/bin/mempalace search "<q>"    # search verbatim memory
bash ~/ai-stack/bin/mempalace mine <dir> --mode convos --extract general   # backfill (large/slow)
bash ~/ai-stack/bin/mempalace status          # palace contents, model, backend

# Opt-in auto-save hooks (reversible, backup-first):
bash ~/ai-stack/bin/mempalace-hooks install --apply
MEMPALACE_HOOKS_AUTO_SAVE=false …             # disable auto-save live without uninstalling
```

`stack status` shows `mempalace` only when installed; the liveness/install probe is
`doctor` check 44 (green-skip when not installed). See
[TROUBLESHOOTING.md § MemPalace](TROUBLESHOOTING.md) for the known gotchas (first-mine
model download, embeddinggemma fallback, the qdrant-client/chromadb conflict, "No
palace found", and the GUI-spawned-PATH fix).

---

## Restart vs recreate

Important distinction:

- **`docker restart <c>`** restarts the process but **keeps the original env
  vars** (set at `docker run` time). If you edited `.env` after the container
  was created, `docker restart` will NOT pick up the new value.
- **`bin/start-<svc>.sh --recreate`** runs `docker rm -f` + `docker run` with
  the current `--env-file`. This is the only way to pick up `.env` changes.

The doctor's `litellm_env_loaded` check detects this drift by inspecting the
running container's env via `docker exec litellm env`.

The installer's `apply-restarts` command exists for exactly this reason —
it does the recreate path, not `docker restart`.

---

## Upgrading services (`vz-ai-stack.sh upgrade`)

A generic, **type-dispatched** upgrade verb — it reads each service's `type`
from `services.yml` and does the right thing: docker → `pull` + recreate,
compose → `pull && up -d`, brew (ollama) → `brew upgrade`, openshell (hermes/pi)
→ in-sandbox update + phase re-assert. It registers no doctor checks and pulls
no models.

**`upgrade all` is EXHAUSTIVE (2026-07-01).** Every *other* service now does real
work too — no more silent "manual note" no-ops. A service with a declared
`upgrade:` block in `services.yml` is version-bumped directly by its method
(`npm-global` → `npm i -g <pkg>@latest`, `uv-venv` → `uv pip install -U`,
`git-pull` → `git pull --ff-only`, `rebuild` → its start script); everything else
re-runs its install phase with `AI_STACK_UPGRADE=1` to re-assert/upgrade via the
phase's own logic. Bare `upgrade all` **also** upgrades the host npm globals that
aren't stack services — **Meridian** (`@rynfar/meridian`) and **Claude Code**
(`@anthropic-ai/claude-code`); **Codex** is invoked via `npx --yes @openai/codex`
(always latest), so it needs no step. Upgrade one host global directly with
`stack upgrade meridian` / `stack upgrade claude-code`.

### 1. See what has an update available (read-only)

```bash
stack upgrade --check            # scan; downloads nothing, changes nothing
stack upgrade --check --all      # include non-checkable (CLI/sandbox/npm) services
stack upgrade --check --json     # machine-readable
stack upgrade --check openwebui  # just one service
```

How it decides — **no image is downloaded**:

| type | "available?" oracle |
|------|---------------------|
| `docker` | local image `RepoDigest` vs the registry **index digest** (`docker buildx imagetools inspect`). Both resolve to the manifest-list digest, so the compare is sound on multi-arch images. |
| `compose`/`docker-compose` | every image from `docker compose config --images` is digest-checked; any newer → `update-available`; locally-built/uncheckable images → `rebuild`. |
| `brew-service` (ollama) | the same shared 3-way brew oracle as `status --versions` (formula-arg `brew outdated --json`, bounded) — a probe timeout/refusal reads `unknown`, never a false `up-to-date`, so the two commands can't disagree. |
| `npm-global` / `pip`(uv-venv) / `clone-only`(git) | **now checked** (2026-07-02) via `npm view` / PyPI JSON / `git ls-remote` (bounded — a blocked registry degrades to `unknown`, never hangs). These show real installed+available instead of `manual`. |
| declared `upgrade:` methods — `uv-tool` (mempalace/halo) · `sandbox-pip` (hermes_fleet, read through the sandbox) · `uv-reqs` (docs_mcp — the 7 ingestor requirements, same-resolver dry-run so check and handler converge) · `brew` (openshell/blaxel, formula-aware) | **now checked** (2026-07-15/16). git-pull services with a `build:`/`restart:` also rebuild and PID-verify the daemon recycle on upgrade. |
| deliberately **pinned** (`upgrade.pin`: openwork, metagpt, concordia, ace, lumen, aionui, pi) | shown as `pinned` with real installed versions where readable — **held on every upgrade path** (`upgrade all` cannot trample a pin); `upgrade <svc>` prints the exact bump recipe. |
| configuration surfaces (guardrails, MCP shims, telegram/slack, …) | reported `config` — they version with the stack repo or their owning service; nothing to upgrade per-service. |
| everything else (real artifact, no oracle yet: docs_ingestor, unsloth, cmux, lmstudio, openagents, …) | reported `manual` (hidden unless `--all`). **NOTE:** bare `upgrade all` still re-asserts them via a phase re-run — see the exhaustive note above. |

Status legend: `update-available` · `up-to-date` · `pinned` (fixed tag or a
declared `upgrade.pin` — held, never auto-swept) · `config` (configuration
surface, versions with the repo/owning service) · `rebuild`/`build` (locally-built
— run `upgrade` to pull+rebuild) · `manual` (real artifact, no version oracle yet)
· `unknown` (any probe failure on any plane — registry/proxy unreachable, a
timed-out/refused brew probe, image never pulled, or an untrusted brew tap —
fix: `brew trust <tap>`).

**Honest results (2026-07-02).** `upgrade` never reports success it didn't verify:
- Every run first prints an **installed → available** version report (skip with
  `--no-check`), and the summary has a **VERSION** column showing what actually moved
  — a no-op reads `up-to-date`, a real bump `a→b`, an unverifiable path `done (unverified)`.
  So even when `REVERIFY` says `ok` (something is alive), VERSION shows whether the *new*
  version is live.
- A swallowed `brew`/`pip` failure now reports **FAILED** (was a false `upgraded`); a
  failed ollama `OLLAMA_HOST=0.0.0.0` re-assert is FAILED (load-bearing).
- `upgrade all` skips services **not installed on this host** (install-stamp gate) — a
  routine upgrade never unsolicited-installs an opt-in sim or fires its live model smoke.
- The green "everything up to date" is **suppressed** when any row is `unknown`/`rebuild`
  (it used to over-claim currency for services it never actually checked).

**See versions anytime (read-only):** `stack status --versions` prints a focused
installed-vs-available table for the whole stack (`--local` = installed only, no network).

### 2. Upgrade them

```bash
stack upgrade --outdated             # upgrade ONLY the services found outdated
stack upgrade --outdated --dry-run   # scan, then print the plan; change nothing
stack upgrade openwebui              # upgrade one, selectively (from the --check list)
stack upgrade all                    # upgrade every enabled service
stack upgrade all --dry-run          # plan the whole fleet, change nothing
```

`--outdated` re-runs the same read-only scan and then upgrades **only** the
services whose status is exactly `update-available` — `rebuild`, `unknown`,
`pinned`, `config`, and `manual` are never auto-upgraded (so a flaky registry
call can't trigger a surprise recreate, and a declared pin is never advanced).
Clones with local uncommitted changes are skipped (`skipped (dirty tree)`) rather
than mutated. After each upgrade it re-verifies with a health probe — daemons
with a declared `restart:` must provably recycle (PID change) or the run FAILS.
Set `AI_STACK_ASSUME_YES=1` to auto-accept the version-pinned re-pull prompt.

Typical flow: `stack upgrade --check` → eyeball the list → `stack upgrade
--outdated` (everything) or `stack upgrade <service>` (selectively).

---

## Updating LiteLLM's model list

```bash
# Edit
$EDITOR ~/ai-stack/litellm/config.yaml

# Validate YAML parses
yq -e '.model_list[0]' ~/ai-stack/litellm/config.yaml

# Recreate to pick up new entries
bash ~/ai-stack/bin/start-litellm.sh --recreate

# Verify
stack test 01            # /v1/models lists new entry; per-model ping
```

If a per-model ping fails (provider deprecated, key invalid, slug typo):

```bash
cat ~/ai-stack/installer/state/model-ping-results.txt
```

Shows `<model>\t<PASS|FAIL(code)|SKIP>` so you can decide what to remove or fix.

---

## Adding a new doctor check

Drop a new file in `installer/doctor/checks/` named
`<NN>_<short_name>.sh`. Follow the existing pattern:

```bash
# installer/doctor/checks/14_my_new_check.sh
CHECKS+=(my_new_check)
CHECK_TITLE[my_new_check]="What this checks, in one line"

my_new_check_diagnose() {
  # Return 0 on PASS, non-zero on FAIL.
  # Write diagnostic detail to stdout (re-run by doctor on failure to show user).
  [[ -f some/file ]] || { echo "missing some/file"; return 1; }
}

my_new_check_fix() {
  # Optional. If defined, doctor offers Y/N to run it after a failed diagnose.
  echo "default content" > some/file
}
```

Variable naming discipline: if your function uses a `for` loop or similar that
might shadow doctor.sh's iteration variable, declare it `local`. (The doctor
itself uses `__check` to minimize collision risk.)

---

## Adding a new managed service

1. Add an entry to `services.yml`:

   ```yaml
   services:
     my_service:
       enabled: true
       type: docker
       image: someorg/something:tag
       alias: my-service           # add to installer/lib/aliases.tsv too
       host_ip: 127.0.10.99        # pick the next free .x (see PORTS.md)
       host_port: 80               # HTTP-on-80 is the default
       container_port: 9999
       network: ai-stack
       health: http://my-service/health
       depends_on: [litellm]
       phase: "XX"
       consumes_env: [MY_SERVICE_API_KEY]
   ```

2. Write `bin/start-my_service.sh` following the canonical flag order (copy
   from `bin/start-qdrant.sh` for the simplest template).

3. If it's a new phase, add a phase script. If it belongs to an existing
   phase, edit that phase script to call `bash bin/start-my_service.sh`.

4. Add a smoke test in `installer/smoke/<phase>.sh`.

5. Add a doctor check in `installer/doctor/checks/`.

6. Re-run: `bash vz-ai-stack.sh install <phase>`.

---

## Common questions

**Q: Will `vz-ai-stack.sh install all` mess with my running containers?**
A: No, not in conservative mode (the default). It detects foreign containers,
flags them in `status`, and tells you to `adopt` when you're ready. It will
start NEW containers for services that aren't running.

**Q: I edited `.env`. Did the running containers pick it up?**
A: No. `docker restart` doesn't reload `--env-file`. Run `stack doctor` —
the `litellm_env_loaded` check compares declared vs container env. Then
`stack apply-restarts`.

**Q: Phoenix is showing 'Waiting for traces to arrive…' forever.**
A: Most likely `PHOENIX_API_KEY` is empty in `.env`. See INSTALL.md § 3.1.
Verify: `docker logs litellm | grep "Failed to export"`.

**Q: I want to nuke everything and start fresh.**
A: `stack reset --confirm nuke` (requires typing `nuke ai-stack` literally).
This backs up `.env` and `data/` first, then removes containers + ollama
models + `.env`.

**Q: A phase keeps re-running every time even though the work is done.**
A: That phase's `precheck()` is returning non-zero. Read the precheck function
in `installer/phases/<NN>_*.sh` to see what it checks. Fix the underlying
state, or (last resort) `touch installer/state/phase_<NN>.done` to manually
stamp.

**Q: How do I see what the installer decided?**
A: `cat CHANGELOG.md` for the architecture-level decisions. `stack history`
for per-run logs. `installer/state/` for current state files.
