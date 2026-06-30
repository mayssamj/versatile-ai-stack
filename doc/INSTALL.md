# Install guide

The installer is `bash ~/ai-stack/vz-ai-stack.sh`. It's idempotent — re-running it
on a healthy stack is a no-op of `✓ already complete` lines. Re-running on a
partial install resumes from where it left off.

---

## 0. Prerequisites (on a clean Mac)

Just these:

- macOS on Apple Silicon (M1 or newer; tested on M4 24 GB).
- [Homebrew](https://brew.sh/).
- Internet access (for image pulls and brew).
- Ability to run `sudo` interactively once (Phase 00·N writes a managed block
  to `/etc/hosts`).

You do **not** need to pre-install anything else. The installer **verifies,
installs what's missing, starts what needs starting, and re-verifies** — run
`bash vz-ai-stack.sh deps` to do that host-tooling bootstrap explicitly (or
`deps --check` for a read-only CI gate). It's also folded into `preflight`, so
`install all` self-bootstraps. See [PREREQUISITES.md](PREREQUISITES.md) for the
full tier map.

> If you already have OrbStack, Ollama, brew, jq, yq, node, etc., the installer
> detects them and skips. It will not duplicate work.

---

## Networking — the two-layer alias system

`ai-stack` services are reached by **name**, not by `127.0.0.1:<port>`. The
installer maintains two parallel name-resolution layers so the same alias
works whether you are dialing from a Mac shell, a browser, or another
container:

1. **`/etc/hosts` block (Mac side).** Phase 00·N appends a contiguous block
   between `# >>> ai-stack` markers that pins every alias to a unique
   `127.0.10.x` loopback IP. Mac processes (`curl`, browser, `python`,
   `node`, `bin/audit.sh`) resolve `litellm`, `phoenix`, `qdrant`, etc.
   through this. Writing the block is the one place the installer asks for
   `sudo`; it is idempotent (no-op if the block is already correct) and
   atomic (`mktemp` → `mv`).

2. **`ai-stack` Docker bridge network.** A user-defined bridge network
   created at `10.99.0.0/24` (configurable via `AI_STACK_SUBNET`). Every
   managed container joins it via `--network ai-stack`, and Docker's
   embedded DNS resolves bare container names inside the network
   (`http://litellm:4000`, `http://phoenix:6006`, …) — no `/etc/hosts`
   needed from inside a container.

3. **Ollama is the one host-gateway exception.** Ollama is a brew service
   on the host, not a container. Containers that consume it (LiteLLM
   today) carry an `--add-host=ollama:host-gateway` flag so `ollama:11434`
   resolves to the host's gateway IP from inside the container. The port
   stays in the URL because Ollama listens natively on 11434 and we
   declined to front it with a proxy.

Phase 00·N is between 00·S and 01 in the install order. It is idempotent
(safe to re-run; no-op when the block is already correct, the network is
up, and `dscacheutil -q host -a name litellm` returns the expected IP) and
self-verifying. The full alias→IP table lives at
`installer/lib/aliases.tsv`; it is the canonical source the doctor checks,
the migration script, and every start script all read from.

---

## 1. Bootstrap

**Canonical first-run order** — exactly one command needs `sudo`; the rest runs as
you. `deps` and `setup` are optional-but-recommended (both run as your normal user):

```bash
git clone <wherever-you-keep-it> ~/ai-stack   # or copy the directory in
cd ~/ai-stack

# Step 1 (optional, recommended) — host-dependency bootstrap (no sudo).
# Verifies + installs + starts + re-verifies Homebrew, the core CLI tools
# (yq jq node@22 pnpm uv git tesseract openssl), OrbStack, and Ollama.
# `--check` is a read-only CI gate. Companion doc: PREREQUISITES.md.
bash vz-ai-stack.sh deps

# Step 2 (optional, recommended) — .env / API-key bootstrap (no sudo).
# Ensures the non-interactive baseline (generates LITELLM_MASTER_KEY +
# PHOENIX_SECRET, service-URL defaults), then offers each OPTIONAL external
# secret — every prompt skippable. A local-only / Claude-subscription (-sub)
# setup needs ZERO keys. Alias: `keys`. (Skip it — ANY `install` (all or a single
# `install <phase>`) ensures this .env baseline as its first step and offers `setup`
# on the first interactive run anyway.)
bash vz-ai-stack.sh setup

# Step 3 — one-time host-system setup (sudo).
# Writes the /etc/hosts alias block, binds 127.0.10.x aliases on lo0,
# installs the launchd plist for reboot persistence, flushes the macOS
# DNS cache. Idempotent: safe to re-run.
sudo bash vz-ai-stack.sh prepare-sudo

# Step 4 — runtime verification (no sudo). Probes the alias chain
# end-to-end before any container starts. Catches lo0/DNS regressions
# while the fix is still cheap. Safe to re-run anytime.
bash vz-ai-stack.sh verify

# Step 5 — full install (no sudo). Interactive top-to-bottom.
# Walks every phase, prompts to adopt foreign containers, prompts for the
# Phoenix API key, drains the restart queue, runs the final doctor.
# Preview first with `install all --dry-run` (alias --plan): read-only, lists
# every phase ✓already-complete vs •would-run and changes nothing.
bash vz-ai-stack.sh install all

# Optional — ALSO install every opt-in extra (the 5 agent-sims, sourcegraph, aionui,
# openwork, understand, ingress, lmstudio, …) in one shot. Best-effort + heavy (some
# need host deps / large builds); a failing optional warns + continues. Preview with
# `install all --include-optionals --dry-run` first:
#   bash vz-ai-stack.sh install all --include-optionals   # alias: --with-optionals

# Step 6 — verify everything is healthy. Expect 66/66.
bash vz-ai-stack.sh doctor
```

That's the whole bootstrap. **After Step 3, no further `sudo` prompts will
appear** during the later steps. This is the recommended path. (`bash
vz-ai-stack.sh` with no args is equivalent to `install all` — interactive
top-to-bottom resume.)

### `vz-ai-stack.sh verify` (Step 4)

`bash vz-ai-stack.sh verify` runs Phase 00·V — six runtime probes against
the alias chain:

1. `/etc/hosts` ownership (root:wheel, mode 644).
2. `lo0` routability for every alias in `aliases.tsv`.
3. `dscacheutil` and `getent hosts` agree on `litellm` → `127.0.10.1`.
4. `--add-host=ollama:host-gateway` resolves in a transient container.
5. End-to-end: `docker -p 127.0.10.X:Y:80` → `curl` → 200.
6. ai-stack network attaches transient containers cleanly (skipped if
   the network doesn't exist yet — legitimate pre-install state).

Failure prints the exact fix command — usually `sudo bash vz-ai-stack.sh
prepare-sudo` — and exits 1. Phase 00·V also runs automatically as part
of Step 5 (`install all`), between Phase 00·N (networking foundation) and Phase 01
(inference plane); the standalone `verify` subcommand is for re-checking
after any networking change (VPN connect/disconnect, OrbStack restart).

### Hardening notes (Step 3, `prepare-sudo`)

`prepare-sudo` refuses to run if any of these guards trip:
- `vz-ai-stack.sh` lives in a temp directory (`/tmp`, `/var/tmp`).
- `vz-ai-stack.sh` is not under `/Users/`.
- The script path goes through a symlink.
- `~/ai-stack` (or any ancestor of it) is owned by anyone other than the
  user invoking `sudo`.
- Key library files (`installer/lib/{common,network,env}.sh`, `vz-ai-stack.sh`)
  are symlinks.
- `SUDO_USER` is empty or `root` (use plain `sudo`, not `sudo -i` or
  `su -`).

These guards prevent path-injection attacks where a forged installer tree
could trick `sudo` into sourcing attacker-controlled bash as root. The
script also takes a `mkdir`-based lock before any system mutation so
concurrent `prepare-sudo` runs serialize cleanly, and uses `chown -h`
(no `-R`) only on the specific files it writes — never recursive on
`$AI_STACK`. Design record:
[preparesudo-design-final.md](../installer/state/preparesudo-design-final.md).

### Fallback: no separate Step 3

You can run `bash vz-ai-stack.sh` directly without Step 3 **IF you're running it
in an interactive terminal**. Phase 00·N will prompt for your sudo password
inline when it hits `/etc/hosts`. The two-step flow above is just cleaner
(sudo upfront, then sit back) and is the only path that works in CI or
piped contexts.

If your terminal won't accept an inline sudo prompt, run `sudo -v` once
before `bash vz-ai-stack.sh` to refresh your sudo timestamp — that gives
Phase 00·N's `sudo -n` (non-interactive) call a 5-minute window where it
succeeds without re-prompting.

Expect 5–20 minutes on first run depending on what's already cached:

- ~5 min: brew installs (orbstack cask, bash, yq, jq, node, pnpm, uv, tesseract, openssl).
- ~3 min: Ollama model pulls — only `gemma4:e4b` (~9.6 GB) + `nomic-embed-text` (Phase 01 `REQUIRED_MODELS`). The heavy/coder models now live on LM Studio MLX (opt-in), so `qwen3.6:27b` and LFM2.5 are **no longer auto-pulled** — a `reset --hard` → `install all` no longer triggers a ~17 GB download.
- ~5 min: docker image pulls (litellm, phoenix, falkordb, qdrant, openwebui, llm_guard).
- ~30 sec each: honcho, hermes-workspace, deer-flow git clones.

If anything fails mid-install, the script prints exactly which phase failed and
how to resume (`bash vz-ai-stack.sh install <phase>`).

The installer is **non-interactive** by default for everything except prompts
where it genuinely needs your input (e.g., a confirmation before recreating an
existing container).

### If Phase 01 (LiteLLM) fails on a cold / second machine

Phase 01 is **self-healing** and self-diagnosing, so a failure here is rarely
fatal — re-running `install 01` usually clears it. Two cold-machine fixes are
worth understanding:

- **LiteLLM Postgres DB auto-create.** LiteLLM's `DATABASE_URL` names a `litellm`
  database, but Honcho's Postgres only ships the server + a `postgres` DB — nothing
  else creates `litellm`. On a machine where it doesn't already exist, LiteLLM's
  Prisma blocks `uvicorn` startup waiting on a DB it can't reach, so `/v1/models`
  times out even though the container is `Up` and `:5432` is reachable.
  `bin/start-litellm.sh` now issues an idempotent `CREATE DATABASE litellm` (via the
  Honcho pg container) after the `:5432` reachability check, on every fresh start /
  `--recreate`. A healthy managed LiteLLM is never touched.
- **Cold-start self-heal.** A running+managed `litellm` (or `phoenix` / `openwebui`)
  left over from a prior/partial run is no longer trusted blindly — Phase 01
  **health-probes** it (`litellm_wait_ready`) and, if it isn't actually serving,
  recreates it via `start-litellm.sh --recreate` (which re-runs the Postgres
  precheck, injects the current master key, and writes fresh config) and re-waits.
- **Self-diagnosing failure output.** On a genuine smoke failure the phase prints
  `litellm_diagnose` — container state, published ports, `:5432` reachability, a
  `litellm DB present/MISSING` line, master-key match between container env and
  `.env`, raw `/v1/models`, and a redacted log tail — instead of dying with a bare
  "did not return a model list". The diagnostic runs to completion even under
  `set -Eeuo pipefail` (it's wrapped in a `+e` subshell), so the most useful part
  (the logs) is never truncated. This is the first thing to read if Phase 01 fails.

---

## 2. What runs at the end

After a successful install, you should see this from `bash vz-ai-stack.sh status`:

```
NAME             DECLARED   ACTUAL     OWNERSHIP    NOTES
ollama           enabled    running    -
litellm          enabled    running    managed
phoenix          enabled    running    managed
falkordb         enabled    running    managed
qdrant           enabled    running    managed
honcho           enabled    running    (compose)
llm_guard        enabled    running    managed
openwebui        enabled    running    managed
hermes_workspace enabled    running    managed
...
```

If `OWNERSHIP` shows `foreign` for one of the docker containers, see
[Post-install § 2 — Adopt foreign containers](#2-adopt-foreign-containers).

---

## 3. Post-install — the manual steps that remain

These are things the installer can't do for you without your decisions or
credentials. Each is reversible.

### 1. Create the Phoenix API key

Phoenix runs with auth on. LiteLLM's OTLP exporter needs a key to push traces.
Without it, you'll see `Failed to export batch code: 401, reason: Invalid token`
in litellm logs and the Phoenix dashboard will stay empty.

```bash
open http://phoenix:6006
```

- Log in: `admin@localhost` / (your password — initial is `admin`, force-reset
  on first login. Mayssam's is recorded in `.env` as `PHOENIX_ADMIN_PASSWORD`).
- **Settings → API Keys → Create new key**.
- Copy the key and paste into `~/ai-stack/.env`:

```bash
# Easiest: use the installer's safe set_env helper from a bash subshell
source ~/ai-stack/installer/lib/common.sh
source ~/ai-stack/installer/lib/env.sh
set_env PHOENIX_API_KEY 'paste-the-key-here'
```

Or edit `.env` directly (mode 0600 — preserve it). Then drain the queued
restart:

```bash
bash vz-ai-stack.sh apply-restarts
```

LiteLLM gets recreated, picks up `PHOENIX_API_KEY` from `--env-file`, and the
next inference call lands as a trace in the `ai-stack` project.

Verify:

```bash
bash vz-ai-stack.sh test 01h
```

Should print `Phoenix has 'ai-stack' project — traces are flowing`.

### 2. Adopt foreign containers

If the installer found one or more containers running that it didn't start
itself (e.g., a previous session started them by hand), it leaves them alone
and flags them as `foreign` in `status`. Conservative-mode default: never
auto-`docker rm -f` anything that holds your data.

To take ownership:

```bash
bash vz-ai-stack.sh adopt qdrant       # start with the lowest-risk one
bash vz-ai-stack.sh adopt falkordb
bash vz-ai-stack.sh adopt phoenix
bash vz-ai-stack.sh adopt litellm
```

Adoption is a 4-step confirmed flow:

1. Prints the existing container's mounts, ports, image, env-var count.
2. Prints what `bin/start-<svc>.sh` *would* produce.
3. Asks `Proceed? [y/N]`. (You can decline and walk away — nothing is touched.)
4. On yes:
   - `docker cp <container>:<data-path> data/<svc>.bak-<ts>/` for stateful
     services (Phoenix sqlite, Falkor RDB, Qdrant snapshot, litellm config).
   - `docker rm -f <name>`.
   - `bash bin/start-<svc>.sh` — recreate with managed labels.
   - Smoke test (HTTP healthcheck or TCP probe).

If the smoke test passes, the `ai-stack.partial=true` label is removed and the
container is "ours" going forward. If anything fails, the backup directory has
your data.

> **Why conservative?** OrbStack's bind-mount semantics have a quirk where a
> running container holds a snapshot view of its mount; if the host path was
> empty when the new container started (common after `docker rm`), the new
> container sees no data. The `docker cp` step extracts the in-container view
> *before* destruction so we can re-seed.

### 3. (Optional) Finish the OpenShell sandbox

The OpenShell CLI (`v0.0.50` at time of writing) has moved meaningfully from
the version the install guide assumed. Phase 04 installs the binary + writes
the network policy + creates the sandbox via the hang-resilient watchdog in
`installer/lib/openshell.sh` (polls `Phase=Ready` and frees the hung create
CLI — the sandbox CREATE hang is now auto-recovered in code). The sandbox
EXEC relay idle-timeout remains a separate upstream issue and is still manual.

Phase 04 also installs a **second, distinct** watchdog —
`bin/openshell-watchdog.sh` (launchd, every 600 s) — for the
*expired-token CPU storm*: after ~8 h a sandbox's gateway token expires and the
agent reconnect-storms at ~36% CPU; only recreating the sandbox mints a fresh
token. By default the watchdog is **warn-only** — it halts the container to stop
the burn and raises an alert (surfaced by `doctor` check 43) but does **not**
delete/recreate the sandbox (recreation discards in-sandbox state); you recreate
when ready, or opt into auto-recreate with `AI_STACK_WATCHDOG_RECREATE=1`. Check its
status with `bash bin/openshell-watchdog.sh status`; see
[TROUBLESHOOTING.md § OpenShell CPU storm](TROUBLESHOOTING.md).

If a gateway/sandbox step still needs hand-holding, the manual steps live in
`~/ai-stack/installer/state/openshell-manual-steps.md`:

```bash
cat ~/ai-stack/installer/state/openshell-manual-steps.md
```

Once the `hermes-fleet-v1` sandbox is up:

```bash
bash vz-ai-stack.sh install 04f       # mounts SOULs + runs the bootstrap
```

(SOUL templates for all 9 fleet profiles are pre-staged on the host at
`~/ai-stack/openshell/fleet-souls/` so the bootstrap is just a mount + exec.)

> **Two fleet installers, two scopes.** `install 04f` installs the fleet
> *inside* the Hermes sandbox (`hermes-fleet-v1`). `install 04h` (which runs
> **last** in the phase order) installs the cross-platform fleet to Claude Code
> + Pi personas and widens the `PI_*`/`HERMES_*` virtual keys to cover the
> full 9-role roster.

### 4. (Optional) Best-effort upstream phases

The following phases try to clone from upstream repos whose URLs may have
moved. If any of them logged a warning during install:

- **Phase 05 Hermes Workspace** — clone of `NousResearch/hermes-workspace` may
  404. If you have the source elsewhere, drop it at
  `~/ai-stack/hermes-workspace/` and re-run `bash vz-ai-stack.sh install 05`.
- **Phase 07 AutoFyn** — same pattern with `~/ai-stack/autofyn/`.
- **Phase 08 Paperclip** — `~/ai-stack/tools/paperclip/`.
- **Phase 09 alt-memory** — `remnic-hermes` (pip) and `@byterover/cli` (npm)
  packages may not exist under those names; both are flagged optional and the
  phase stamps anyway.
- **Phase 11 HALO** — installs the `halo-engine` package (exposes `bin/halo`).
  `bin/halo` routes via LiteLLM (local default) and disables the agents-SDK
  cloud trace export. Caveat: HALO wants OTel-format traces (not our custom
  `traces/litellm.jsonl`) and its openai-agents SDK uses the Responses API,
  so full analysis on local models is experimental. HALO is built on the RLM
  substrate (Phase 18).
- **Phase 12 Blaxel** — `@blaxel/cli` npm package; if you know the correct
  install command (sometimes a `curl | sh`), run it manually.
- **Phase 14 Unsloth Studio** — the official `curl|sh` installer (≈ 2400-line
  shell script that runs `uv` + `pip`) needs network access to pypi and
  `huggingface.co`. On corp networks behind a proxy, set `HTTPS_PROXY` /
  `HTTP_PROXY` before re-running. First launch pre-caches a helper GGUF
  (~150 MB) — be patient on slow connections.
- **Phase 15 Pi (Earendil coding agent)** — `installer/phases/15_pi.sh`
  needs (a) Phase 04 OpenShell gateway operational (post-2026-05-29 fix,
  it is), (b) Phase 03 Honcho up so the LiteLLM Prisma DB can connect to
  Honcho's Postgres, (c) `pi/pi-bootstrap.tar.gz` (auto-built by Phase 15
  the first time from `pi/package.json`). To upgrade Pi: `rm
  pi/pi-bootstrap.tar.gz pi/package-lock.json && bash vz-ai-stack.sh install
  15`. Phase 15 mints `PI_LITELLM_KEY` server-side against the fixed local-model
  superset (`local`, `local-gemma4`, `local-heavy`, `local-lfm2`,
  `local-qwen3-coder`, `local-qwen3.6`) — no cloud spend possible. Pi's
  declared model is `local-qwen3-coder` (see [models.md](models.md)); the
  superset lets `model assign`/`sync` re-point it without re-minting the key.
- **Phase 16 Lumen (Ory's local code semantic search MCP)** —
  `installer/phases/16_lumen.sh` downloads the pinned v0.0.41
  `darwin-arm64` binary (SHA256-verified against the release's
  `checksums.txt`), pulls the `ordis/jina-embeddings-v2-base-code`
  embedding model via Ollama (~322 MB on disk), and auto-indexes the
  ai-stack repo as a useful default. Lumen is stdio-only (no daemon,
  no port) — each MCP client (AutoFyn, Open WebUI, Claude Code, Codex,
  Cursor) spawns its own `~/ai-stack/bin/lumen stdio` subprocess. Pi
  cannot use Lumen today; see the §2.14 catalog entry in USER-GUIDE.md
  for the deferred-work note. To upgrade Lumen: bump version constants
  in `installer/phases/16_lumen.sh` (and the SHA256 from the new
  release's checksums.txt), then re-run the phase.
- **Phase 18 RLM (Recursive Language Models)** — installs the `rlms` library
  (pip) plus `bin/rlm` wrapper and `rlm/run_rlm.py` runner
  (github.com/alexzhang13/rlm): the model recursively calls itself over long
  context via a REPL that runs in a Docker sandbox (`python:3.11-slim`), not
  on the host. Routes via LiteLLM + `RLM_LITELLM_KEY` and works on local
  models. It's the substrate HALO (Phase 11) is built on.

None of these block the core stack. The default fleet (Hermes profiles using
LiteLLM + Phoenix + Honcho + Open WebUI) works without any of them.

---

## 4. Verify everything

Run the per-phase smoke tests:

```bash
bash vz-ai-stack.sh test 01      # /v1/models + chat + trace file + per-model ping
bash vz-ai-stack.sh test 01h     # Phoenix has ai-stack project
bash vz-ai-stack.sh test 02      # FalkorDB + Qdrant write+read
bash vz-ai-stack.sh test 03      # Honcho /health
bash vz-ai-stack.sh test 05      # Open WebUI UI 200
```

Then run the full doctor:

```bash
bash vz-ai-stack.sh doctor
```

Expected: 68/71 checks pass after the post-install steps above and a
successful `sudo bash vz-ai-stack.sh prepare-sudo` (which wires `/etc/hosts`
+ lo0 + the launchd plist). Three of the checks (15 `/etc/hosts` block, 19 lo0
aliases, 17 alias reachability) require `prepare-sudo` to have run. Ten more
(24 `pi-v1` Ready, 25 pi-v1 network policy, 26 `PI_LITELLM_KEY`
allowlist, 27 Lumen MCP binary + embed model, 28 DeerFlow config.yaml
model entries + compose passthrough, 29 ACE + LiteLLM virtual key, 30 Hermes
routing, 31 RLM install, 32 claw3d office + bridge, 33 Hermes Telegram gateway)
require Phases 14, 15, 16, 10, 17, 04f, 18, 19, 20. Check 33 skips cleanly
(counts as a pass) when `HERMES_TELEGRAM_BOT_TOKEN` isn't set.

Checks 34–38 cover the five opt-in extras (Phases 21–25: portless, cmux,
skillspector, openagents, lmstudio) and **pass-as-skip when the tool isn't
installed**, so the doctor stays green on a default `install all`. Check 39
(`openshell_storm`) verifies no OpenShell sandbox is in an expired-token CPU
storm and reports that the (warn-only-by-default) watchdog installed by Phase 04
is loaded — it skips cleanly when OpenShell isn't present. Checks 40–43 cover the
model↔agent binding (40), the opt-in Meridian/Claude-subscription wiring (41), the
9-role agent fleet (42), and any pending watchdog alert (43). Check 44
(`mempalace`) covers MemPalace, now a core phase (Phase 26: verbatim Claude Code
session memory) — it verifies the tool + wrapper + launchers + palace config +
LiteLLM key and **green-skips when Phase 26 hasn't run yet** (e.g. a stack predating the change, or a partial install). Check 49
(`sourcegraph_mcp`) covers the seventh opt-in extra (Phase 27: local Sourcegraph
code search wired into the Hermes fleet over MCP) — it verifies the network-policy
stanza + fleet wiring and **skip-cleans when Sourcegraph isn't installed**.

---

## 5. What's on which URL

| What | URL | Auth |
|---|---|---|
| LiteLLM proxy | http://litellm:4000 | `Bearer $LITELLM_MASTER_KEY` |
| Phoenix dashboard | http://phoenix:6006 | `admin@localhost` / your password |
| FalkorDB browser | http://falkordb-ui:3000 | none |
| Qdrant dashboard | http://qdrant:6333/dashboard | none |
| Honcho API | http://honcho:8000 | none (auth off for local) |
| Open WebUI | http://openwebui:8080 | none (auth off) |
| Hermes Workspace | http://workspace:3000 | depends on upstream |
| LLM Guard | http://llm-guard:8000 | bearer token |
| Docs MCP server | http://docs-mcp:8765 | none |
| AutoFyn | http://autofyn:3400 | depends |
| Paperclip | http://paperclip:3100 | depends |
| Unsloth Studio | http://unsloth:8898 | bootstrap user `unsloth` / pwd at `~/.unsloth/studio/auth/.bootstrap_password` |
| Pi (coding agent) | `bin/pi` (no HTTP — sandboxed) | virtual key `PI_LITELLM_KEY` injected by `bin/pi`; never echoed |
| Lumen (code search MCP) | `bin/lumen` (stdio MCP / shell CLI; no HTTP) | none — local subprocess only |
| HALO | `bin/halo` (no HTTP — CLI) | routes via LiteLLM (local default) |
| RLM (Recursive Language Models) | `bin/rlm` (no HTTP — REPL in Docker sandbox) | virtual key `RLM_LITELLM_KEY` |

All services bind to `127.0.10.x` (loopback range — named via `/etc/hosts`)
only, **except Unsloth Studio**, which the studio's own bootstrap binds to
`0.0.0.0:8898` to support LAN-side training tools (macOS Application
Firewall still blocks LAN ingress unless you allow it; the studio's
own auth gate is the second layer). Smoke-check the alias chain
end-to-end with:

```bash
curl -sf http://litellm:4000/health      # → 200 once litellm is up
curl -sf http://phoenix:6006/healthz     # → 200
curl -sf http://qdrant:6333/collections  # → 200
dscacheutil -q host -a name litellm # → ip_address: 127.0.10.1
```

---

## 6. Resetting

If something goes badly wrong and you want a clean slate, the installer has
tiered resets that print the blast radius before acting:

```bash
bash vz-ai-stack.sh reset --confirm soft   # state + bin/  (keeps .env, data/, containers)
bash vz-ai-stack.sh reset --confirm hard   # + managed containers + data/ (with backup)
bash vz-ai-stack.sh reset --confirm nuke   # + .env + ollama models (re-download all)
```

`reset --confirm hard` now also deletes the OpenShell sandboxes and tears
down every compose project (deerflow/autofyn/hermes-workspace) plus their
volumes (including `honcho_redis-data`). It preserves Ollama + its models,
Docker images, `.env`, and the `/etc/hosts` block. To recover a wedged
install, run `reset --confirm hard --yes` then `install all` (this replaces
the old `force-sandbox-reset-preinstall.sh` / `full-reinstall.sh` scripts,
which are gone — folded into the watchdog + `reset --confirm hard`).

Add `--yes` / `-y` (or set `AI_STACK_ASSUME_YES`) to run any reset
non-interactively. `nuke` still requires typing `nuke ai-stack` literally to
confirm.

---

## 7. What the installer does NOT do

By design:

- **Does not modify your shell rc.** The installer suggests
  `export PATH="$HOME/ai-stack/bin:$PATH"` but won't write to `~/.zshrc` for
  you. Add it yourself if you want the `stack` short command.
- **Does not run under sudo.** Refuses to start if `EUID == 0`. Sudo strips
  PATH and would chown `.env` to root.
- **Does not auto-restart containers when `.env` changes.** Conservative
  policy — it queues restarts to `installer/state/restarts-needed.txt` and you
  drain with `vz-ai-stack.sh apply-restarts`.
- **Does not adopt foreign containers without confirmation.** See § 3.2 above.
- **Does not push your data anywhere.** Phoenix is self-hosted. Honcho is
  self-hosted. The only egress is to LLM provider APIs (per your `.env` keys)
  and OpenRouter/Blaxel if you use them.
