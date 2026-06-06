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
| **2 — services** | OrbStack (Docker runtime) | `brew list --cask orbstack` + `docker info` | `brew install --cask orbstack` | `open -a OrbStack` → wait `docker info` (≤90s) |
| | Ollama | `command -v ollama` + `:11434/api/tags` | `brew install ollama` | patch launchd plist (`OLLAMA_HOST=0.0.0.0`, `OLLAMA_ORIGINS=*`, `OLLAMA_KEEP_ALIVE=0`) → `brew services start ollama` → wait `:11434` |
| **3 — opt-in / phase-owned** | `lms` (LM Studio), `openshell`, `blaxel`/`bl`, `unsloth`, `portless`, `cmux`, `mempalace`, `hermes`, `halo` | per-phase | each phase installs/ensures its own (often opt-in, not in `install all`) | per-phase |

## Where each tier is ensured

- **`preflight()`** (runs before any `install`/`verify`) → `bootstrap_host_deps`
  = Tier 0 + Tier 1 + the Docker service. So the install can't die on a missing
  `yq` the way it used to — preflight previously *asserted and exited* on the very
  tools that Phase 00 installs, which made Phase 00 unreachable on a clean machine.
- **Phase 00 (`00_host.sh`)** → `ensure_core_tools` + `ensure_orbstack` (idempotent
  re-affirm), then the directory tree + `.env`.
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
containers) and `OLLAMA_KEEP_ALIVE=0` (never pin a model resident — a 24 GB box
thrashes otherwise), then restarts the service. Idempotent: it patches + restarts
only when a key is missing.

## Notes

- **Idempotent throughout** — every `ensure_*` is a no-op on an already-prepared
  host; safe to re-run.
- **`NO_PROMPT=1`** makes the Homebrew bootstrap non-interactive (for CI / cold
  automation).
- The privileged host step (`/etc/hosts` + `lo0` aliases) is separate:
  `sudo bash vz-ai-stack.sh prepare-sudo` (see [INSTALL.md](INSTALL.md)).
