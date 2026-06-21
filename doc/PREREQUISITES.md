# Host prerequisites — the platform bootstrap map

`vz-ai-stack.sh` targets **macOS on Apple Silicon**. It no longer *assumes* host
tools are present — it **verifies, installs what's missing, starts what needs
starting, and re-verifies** before proceeding. No assumptions, only verified
actions.

> This is the **host-tooling** map (what must be on the machine to run the
> installer). For the **service/runtime** dependency graph (which container talks
> to which), see [DEPENDENCIES.md](DEPENDENCIES.md).

The single source of truth is **`installer/lib/deps.sh`** (the `DEPS_*` manifest +
the `ensure_*` routines). This document mirrors it.

Run it yourself:

```bash
vz-ai-stack.sh deps            # show the map; install/start anything missing
vz-ai-stack.sh deps --check    # read-only; non-zero exit if anything missing/down (CI)
```

## The map

| Tier | Dependency | Detect | If missing | Start + verify |
|---|---|---|---|---|
| **0 — bootstrap** | Homebrew | `command -v brew` | install via the official script (prompts; `NO_PROMPT=1` → unattended) | — |
| | bash 5+ | `BASH_VERSINFO` | `brew install bash` then re-exec | handled at the top of `vz-ai-stack.sh` |
| | Xcode CLT (git, curl, …) | `command -v git curl` | guidance: `xcode-select --install` | — |
| **1 — core CLI** | `yq` `jq` `node@22`(+`npm`) `pnpm` `uv`(+`uvx`) `git` `tesseract` `openssl@3` | `brew list` / `command -v` | `brew install <formula>` (per-formula; tolerant of symlink conflicts) | re-verify each command resolves |
| | `python3` | `command -v python3` | `brew install python3` | — |
| | base builtins: `awk grep sed stat mktemp lsof perl plutil launchctl open sysctl curl` | `command -v` | **fail loud** (broken PATH / base system) → `xcode-select --install` | — |
| **2 — services** | Docker engine — **OrbStack** (default) \| Docker Desktop \| Colima \| Podman | per-engine probe (e.g. `brew list --cask orbstack` + `docker info` on the engine's socket) | install the *selected* engine (OrbStack default: `brew install --cask orbstack`) | start the selected engine → wait `docker info` on its socket (≤90s) |
| | Ollama | `command -v ollama` + `:11434/api/tags` | `brew install ollama` | patch launchd plist (`OLLAMA_HOST=0.0.0.0`, `OLLAMA_ORIGINS=*`, `OLLAMA_KEEP_ALIVE=30m`) → `brew services start ollama` → wait `:11434` |
| **3 — opt-in / phase-owned** | `lms` (LM Studio), `openshell`, `blaxel`/`bl`, `unsloth`, `portless`, `cmux`, `mempalace`, `hermes`, `halo` | per-phase | each phase installs/ensures its own (often opt-in, not in `install all`) | per-phase |

## Choosing the Docker engine

OrbStack is the **default**, but it's one of **four selectable engines** — the
whole stack (every container *and* the OpenShell gateway) runs on whichever one
you pin:

| Engine | id | Notes |
|---|---|---|
| OrbStack | `orbstack` | default; lightest on Apple Silicon |
| Docker Desktop | `docker-desktop` | the mainstream option |
| Colima | `colima` | CLI-only Lima VM |
| Podman | `podman` | daemonless / rootless |

The single source of truth is **`AI_STACK_DOCKER_ENGINE`** in `.env`; the registry
module `installer/lib/docker-engine.sh` resolves each engine's socket and exports a
single `DOCKER_HOST`. Pick or change it intentionally:

```bash
vz-ai-stack.sh docker-engine select        # interactive picker (then ensure + pin)
vz-ai-stack.sh docker-engine set <id>       # pin explicitly (ensure + pin), e.g. set colima
vz-ai-stack.sh docker-engine status         # show selected engine, resolved socket, consistency, context policy
vz-ai-stack.sh docker-engine context status # show the global docker-context policy (switch|keep)
vz-ai-stack.sh --engine <id> <any command>  # one-off override for a single invocation
```

### Global `docker context` policy (no mid-run prompts)

ai-stack always drives its own containers through the exported **`DOCKER_HOST`**, so
the selected engine is correct inside the stack regardless of your global `docker
context`. Whether to *also* point your **global** `docker context` at the stack's
engine — so other shells/tools see it too — is a **persisted preference**,
**`AI_STACK_DOCKER_CONTEXT`** in `.env`, never an interactive question during
`install`/`doctor`:

| Value | Behavior |
| --- | --- |
| `switch` *(default)* | `install`/`doctor` silently point the global context at `ai-stack-<engine>`, recording your prior context once (`AI_STACK_DOCKER_CONTEXT_PRIOR`) for a clean undo. |
| `keep` | Your global context is never touched. |

Set it non-interactively, either in `setup` (it asks once) or directly:

```bash
vz-ai-stack.sh docker-engine context switch   # auto-point global context (default)
vz-ai-stack.sh docker-engine context keep      # never touch it (also restores the prior context now)
```

`AI_STACK_DOCKER_CONTEXT=keep vz-ai-stack.sh <cmd>` overrides it for a single run. (The
env var shadows `.env` for as long as it is exported — handy for CI, where you may want
`AI_STACK_DOCKER_CONTEXT=keep` so a shared runner's global context is never auto-switched;
the stack itself is unaffected either way because `DOCKER_HOST` always wins.)

Phase 00 preflight selects-before-use, so an `install all` on a fresh box pins the
engine before any container is created. Doctor checks **48** (selection present &
valid) and **47** (no split-brain across the ambient CLI / `gateway.env` / managed
containers) keep it honest. The podman/colima/docker-desktop sockets are wired but
**less battle-tested than OrbStack** — confirm `docker-engine status` + doctor
01/47/48 are green before relying on a non-default engine.

## Where each tier is ensured

- **`preflight()`** (runs before any `install`/`verify`) → `bootstrap_host_deps`
  = Tier 0 + Tier 1 + the Docker service. So the install can't die on a missing
  `yq` the way it used to — preflight previously *asserted and exited* on the very
  tools that Phase 00 installs, which made Phase 00 unreachable on a clean machine.
- **Phase 00 (`00_host.sh`)** → `ensure_core_tools` + `ensure_orbstack` (idempotent
  re-affirm; `ensure_orbstack` is now a back-compat **alias over `ensure_docker_engine`**,
  which selects → installs-if-missing → starts → waits on the *selected* engine's
  socket), then the directory tree + `.env`.
- **Phase 01 (`01_inference.sh`)** → `ensure_ollama` (install + plist env-patch +
  start + verify) **then** pull the default models. The env-patch lives here, with
  the install, because it must run *after* Ollama exists: on a cold install Ollama
  is installed in Phase 01, so a Phase-00-only patch (the old behavior) was skipped
  and LiteLLM→Ollama got `403 Forbidden`.

## The Ollama cross-container patch (why it matters)

Ollama defaults to binding `127.0.0.1` with a localhost-only origin allowlist, so
in-stack containers calling `http://ollama:11434` (via `--add-host
ollama:host-gateway`) get `403 Forbidden`. `ensure_ollama` patches the brew
launchd plist with `OLLAMA_HOST=0.0.0.0` + `OLLAMA_ORIGINS=*` (reachable from
containers) and `OLLAMA_KEEP_ALIVE=30m` (keep the default ~3.3 GB model warm
for 30 min of inactivity, then release it — the real RAM lever on a 24 GB box
is the OrbStack VM memory cap), then restarts the service. Idempotent: it patches + restarts
only when a key is missing or set to a stale value.

## Notes

- **Idempotent throughout** — every `ensure_*` is a no-op on an already-prepared
  host; safe to re-run.
- **`NO_PROMPT=1`** makes the Homebrew bootstrap non-interactive (for CI / cold
  automation).
- The privileged host step (`/etc/hosts` + `lo0` aliases) is separate:
  `sudo bash vz-ai-stack.sh prepare-sudo` (see [INSTALL.md](INSTALL.md)).
- **Secrets/`.env` are a separate, optional step** — `deps` bootstraps host *tooling*;
  it does **not** touch `.env`. To seed `.env` + (optionally) enter API keys, run
  `vz-ai-stack.sh setup` (alias `keys`). It always ensures the non-interactive baseline
  (generated `LITELLM_MASTER_KEY` + `PHOENIX_SECRET`, service-URL defaults), then offers
  each optional external secret — every prompt skippable. A local-only / Claude-subscription
  (`-sub`) setup needs **zero** keys. See [OPERATIONS.md § Bootstrap helpers](OPERATIONS.md#bootstrap-helpers-deps-setup---dry-run-per-command-help).

The canonical first-run order is **`deps` → `setup` → `prepare-sudo` → `install all`
→ `doctor`** (`deps` + `setup` are optional-but-recommended; both run as your normal
user — only `prepare-sudo` needs `sudo`).

## Undo an engine switch

Switching engines is **reversible** — nothing is auto-destroyed at any step (no
container is deleted, no image is removed, no volume is touched). If you switched
engines (e.g. `docker-engine set colima`) but your managed containers actually
live on the **previous** engine, the **docker-engine-consistency** doctor check
(check 47) flags it as split-brain. To roll back:

1. **Re-pin to where the containers actually live:**

   ```bash
   vz-ai-stack.sh docker-engine set <previous-engine>   # e.g. set orbstack
   ```

2. **Restart the OpenShell gateway** so it re-reads the freshly-rewritten
   `gateway.env` (`DOCKER_HOST`). If there is **no Ready sandbox**, a plain
   `install 04` re-reads it; if a Ready sandbox exists (gateway won't restart on
   its own), force the restart explicitly:

   ```bash
   OPENSHELL_FORCE_GATEWAY_RESTART=1 vz-ai-stack.sh install 04
   ```

3. **Restore your global `docker context`** if the `switch` policy moved it. The
   prior context is recorded in `AI_STACK_DOCKER_CONTEXT_PRIOR`, and the one-shot
   restore puts it back:

   ```bash
   vz-ai-stack.sh docker-engine context keep   # restores the recorded prior context
   # or, manually:
   docker context use <prior>                  # the name engine_pin printed when it switched
   ```

4. **Confirm it's clean:**

   ```bash
   vz-ai-stack.sh doctor          # checks 01/47/48 green (engine reachable; no
                                  # split-brain; selection present & valid)
   ```

Again: nothing is auto-destroyed at any of these steps — the rollback only
re-pins selection and re-points `DOCKER_HOST`; your containers stay where they are.

## Engine verification matrix (manual — UNVERIFIED on the build box)

OrbStack is exercised end-to-end by the test suite on the build box. The other
three engines (and the Docker Desktop cask-churn case) are **wired but not
exercised here** — they are residual UNVERIFIED paths, logged as such rather than
papered over. Before relying on a non-default engine, run it on a box that has it
and confirm the socket resolves and the doctor checks are green.

| engine | socket resolution to confirm | host.docker.internal |
|---|---|---|
| docker-desktop | `docker context inspect desktop-linux` endpoint, else `~/.docker/run` socket | auto (no flag) |
| colima | `colima status` `socket:` line, else `~/.colima/<profile>/docker.sock` | needs `--add-host` |
| podman | `podman machine inspect {{.ConnectionInfo.PodmanSocket.Path}}` | needs `--add-host` |
| docker-desktop cask churn | `brew info --cask docker-desktop`, else fall back to `docker` | n/a |

On a box that has the target engine:

```bash
vz-ai-stack.sh docker-engine set <engine>   # e.g. set podman
vz-ai-stack.sh docker-engine status         # selected engine + resolved socket + consistency
vz-ai-stack.sh doctor                        # checks 01/47/48 green before relying on it
```

`docker-engine status` plus doctor checks **01** (selected engine reachable), the
**docker-engine-consistency** check (47, no split-brain), and **48** (selection
present & valid) must all be green before you trust a non-default engine.
