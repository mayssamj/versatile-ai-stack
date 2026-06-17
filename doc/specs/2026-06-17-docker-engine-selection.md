# Intentional Docker-engine selection & single-engine guarantee

- **Date:** 2026-06-17
- **Status:** Approved (design) — ready for implementation plan
- **Author:** mayssams (with Claude)
- **Area:** installer (host prep, deps, OpenShell gateway), doctor, docs

## Problem

The installer assumes OrbStack is the Docker provider, and two components pick
their Docker engine *independently*:

1. **The main stack** (litellm, phoenix, falkordb, qdrant, openwebui, …) uses the
   bare `docker` CLI, which silently follows whatever `docker context` /
   `DOCKER_HOST` is active. On a machine with **Docker Desktop** already
   installed and running, that is Desktop's socket.
2. **The fleet / workspace sandboxes** are created by the OpenShell gateway,
   which `installer/phases/04_openshell.sh:220` **hard-pins** to
   `$HOME/.orbstack/run/docker.sock` whenever that socket exists.

Consequences on a Docker-Desktop-present machine:

- `installer/lib/deps.sh::ensure_orbstack` (line 162) treats *any* reachable
  `docker info` as "Docker daemon ready" — so OrbStack can be installed but
  unused, or the flow proceeds against Desktop while assuming OrbStack.
- The main containers can land in one engine while fleets/workspaces land in
  another → **split brain**: different bridge networks, different
  `host.docker.internal`, broken per-service alias IPs (`installer/lib/aliases.tsv`).
  The install fails confusingly.

The user wants engine selection to be **intentional and explicit at the start of
install**, the **same engine** used by the whole stack (main containers AND
fleets/workspaces), and **doctor** to detect and fix the situations this creates.

## Goals

- Explicit, intentional selection among **OrbStack, Docker Desktop, Colima,
  Podman** at the start of install (and re-runnable later).
- A single source of truth that the *entire* stack — main containers and the
  OpenShell gateway — derives its Docker engine from, guaranteeing one engine.
- Doctor checks that detect engine mismatch / split-brain / missing selection and
  fix them where safe (never auto-destroy data).

## Non-goals

- Migrating existing containers *between* engines automatically (guided/manual
  only — consistent with the conservative `recreate_guard` philosophy).
- Supporting non-macOS hosts (the stack is macOS Apple-Silicon only).
- Sweeping `docker` → `podman` at call sites (see key decision below).

## Key design decisions (from brainstorming)

1. **Engine scope:** all four — OrbStack, Docker Desktop, Colima, Podman.
2. **Pinning strategy:** *both* — always pin explicitly via a derived
   `DOCKER_HOST` (non-invasive guarantee) **and** offer (with consent) to switch
   the user's global `docker context`.
3. **Auto-select / tie-break:** prefer the single **running** engine; if multiple
   run or none does, prompt interactively; under `NO_PROMPT=1` fall back to a
   fixed priority `orbstack > docker-desktop > colima > podman`, logged loudly.
4. **Keep the `docker` CLI everywhere.** Podman and Colima both expose a
   Docker-API-compatible socket, so the real `docker` CLI talks to all four
   engines unchanged. The **only** things that vary per engine are (a) which
   socket `DOCKER_HOST` points at and (b) whether `host.docker.internal` needs an
   explicit `--add-host=host.docker.internal:host-gateway`. No `$DOCKER` binary
   indirection.

## Architecture

### Single source of truth

`AI_STACK_DOCKER_ENGINE` persisted in `.env` (`orbstack` | `docker-desktop` |
`colima` | `podman`). From it the stack derives a fixed `DOCKER_HOST` that is:

- exported for **every** stack-owned docker invocation (set centrally when env
  loads), and
- written into `~/.config/openshell/gateway.env` as the gateway's `DOCKER_HOST`.

This removes the independent engine choice in (1) and (2) above.

### New module: `installer/lib/docker-engine.sh` (engine registry)

A data table keyed by engine id. Each row carries:

| field | orbstack | docker-desktop | colima | podman |
|---|---|---|---|---|
| display name | OrbStack | Docker Desktop | Colima | Podman |
| install probe | `/Applications/OrbStack.app` or cask `orbstack` | `/Applications/Docker.app` or cask `docker` | `command -v colima` (brew `colima`) | `command -v podman` (brew `podman`) |
| socket path | `$HOME/.orbstack/run/docker.sock` | `/var/run/docker.sock` (and `$HOME/.docker/run/docker.sock`) | `$HOME/.colima/default/docker.sock` | `podman machine inspect` → socket path |
| daemon start | `open -a OrbStack` | `open -a Docker` | `colima start` | `podman machine start` |
| needs `--add-host` for `host.docker.internal` | no | no | yes | yes |
| install method | `brew install --cask orbstack` | `brew install --cask docker` | `brew install colima` (+ docker CLI) | `brew install podman` (+ docker CLI) |

Socket paths are **probed/derived**, not assumed: Docker Desktop and Colima/Podman
expose their socket in user-specific locations that the registry resolves at
runtime (e.g. `colima status`, `podman machine inspect --format '{{.ConnectionInfo.PodmanSocket.Path}}'`).
Colima and Podman require the `docker` CLI to be present (`brew install docker`
provides the client only); the registry ensures it.

Functions:

- `engine_detect_installed` → ids with their app/binary present.
- `engine_detect_running` → ids whose daemon answers `docker -H <socket> info`
  (bounded with a timeout; a wedged daemon must not hang the installer).
- `engine_socket <id>` → resolved `DOCKER_HOST` value.
- `engine_addhost_args <id>` → `--add-host=host.docker.internal:host-gateway`
  when the engine needs it, else nothing.
- `engine_select` → resolve the selection by precedence:
  `--engine <id>` flag → `AI_STACK_DOCKER_ENGINE` in `.env` → single **running**
  engine → interactive prompt → (`NO_PROMPT=1`) fixed priority. Always logs the
  chosen engine and *why*.
- `engine_ensure <id>` → install if missing (with consent; honors `NO_PROMPT`) +
  start the daemon + wait (bounded) for it to answer **on that engine's socket**.
- `engine_pin <id>` → persist `AI_STACK_DOCKER_ENGINE` to `.env`, export
  `DOCKER_HOST`, rewrite `gateway.env`, and **offer** (consented) to run
  `docker context use` (creating/using an `ai-stack-<engine>` context).

### Wiring changes

- **`installer/lib/deps.sh`**: `ensure_orbstack` becomes a thin wrapper over
  `engine_ensure "$(engine_select)"` (keep the old name as an alias for callers).
  `deps_report` prints the **selected** engine and whether CLI socket == gateway
  socket == selected socket.
- **`installer/phases/00_host.sh` / preflight**: run selection *before* any
  docker use. Idempotent: if `.env` already pins an engine and it is still
  installed, skip the prompt.
- **`installer/lib/docker.sh`**: `docker_run_managed` and
  `probe_host_docker_internal` append `engine_addhost_args` for the selected
  engine.
- **`installer/phases/04_openshell.sh`**: replace the OrbStack-hardcoded
  `DESIRED_DOCKER_HOST` (lines 220–230) with `engine_socket "$selected"`.
- **`vz-ai-stack.sh`**: new subcommand `docker-engine [status|select|set <id>]`
  for intentional, re-runnable selection, plus a `help docker-engine` block in
  `installer/lib/help.sh` and `services.yml` help prose.
- **Central env load** (`installer/lib/common.sh` / `env.sh`): export
  `DOCKER_HOST` from `AI_STACK_DOCKER_ENGINE` so all stack docker calls inherit it.

### Doctor

- **Expand check 01** (`01_orbstack_running.sh` → "selected Docker engine
  reachable"): probe the **selected** engine's socket, not just any `docker info`.
  Fix = `engine_ensure`.
- **New check — engine consistency / no split-brain** (`46_docker_engine_consistency.sh`):
  assert (a) active `DOCKER_HOST` resolves to the selected engine, (b)
  `gateway.env` `DOCKER_HOST` == selected socket, and (c) every
  `ai-stack.managed=true` container lives in the selected engine. Fix = re-pin
  `gateway.env` + re-export `DOCKER_HOST`; if managed containers are stranded in
  another engine, **warn + guide** (offer re-pin to where they live, or guided
  recreate — never auto-destroy).
- **New check — selection present & valid** (`47_docker_engine_selection.sh`):
  `AI_STACK_DOCKER_ENGINE` set and that engine still installed. Fix = run
  `engine_select` + `engine_pin`.
- **Make check 02** (`02_host_docker_internal.sh`) engine-aware: on Colima/Podman
  the resolution path requires the `--add-host` flag; the probe and message
  account for it.
- Doctor check count rises **45 → 47**. Update the count in `doc/` (TUTORIAL,
  EXPLORE, README where stated), the doctor-count memory, and
  `installer/lib/check_fleet_parity.sh` only if it references the count.

## Data flow

```
--engine flag / AI_STACK_DOCKER_ENGINE / running-singleton / prompt
        │  engine_select
        ▼
AI_STACK_DOCKER_ENGINE (.env)  ── single source of truth
        │  engine_socket
        ├──────────────► DOCKER_HOST exported  ─► all stack `docker` calls
        ├──────────────► gateway.env DOCKER_HOST ─► OpenShell fleets/workspaces
        └──────────────► engine_addhost_args ─► docker_run_managed / probe
```

## Error handling / edge cases

- Selected engine not installed under `NO_PROMPT` → hard fail with the exact
  `brew install …` remediation.
- Engine installed but daemon down → `engine_ensure` starts + waits (bounded,
  per-engine guidance on timeout).
- Selection changed on an existing install → doctor surfaces stranded managed
  containers; offers re-pin (to where they live) or guided recreate.
- Wedged daemon during detection → all `docker -H … info` probes are timeout-bounded.

## Testing

- **Registry selection-precedence unit tests** in a git worktree with a
  **throwaway `ENV_FILE`** (never the real `.env` — standing rule). Cover: flag >
  env > running-singleton > priority; NO_PROMPT fallback; unknown id rejected.
- **Regression:** full doctor green on the current OrbStack box; existing
  OrbStack install path unchanged.
- **Docker-Desktop-present simulation:** fake a second socket + `docker context`
  to prove the consistency check (46) fires and re-pin fixes it.
- **Colima / Podman:** cannot be fully exercised without installing them; gate
  behind `--dry-run` / plan output and document a manual verification matrix.
  `log()` clearly what is verified vs. assumed — no silent caps.
- **Docs cohesion sweep:** `doc/PREREQUISITES.md`, `.env.example`,
  `installer/lib/help.sh`, EXPLORE/TUTORIAL where Docker/OrbStack is named, and
  the relevant memory file.

## Review gate

Per `doc/SOUL.md` §24: ≥2 independent reviews (adversarial + domain/infra) +
debate-to-consensus before merge. This change touches host prep, the gateway
pin, and doctor — test the **failure** paths (Desktop present, daemon down, split
brain), not just the happy OrbStack path.
