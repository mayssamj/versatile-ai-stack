# Per-service `help` command — design

**Date:** 2026-06-03 · **Branch:** `worktree-service-help`

## Goal
`mayssam-ai-stack.sh help <service>` prints, for any stack service: **what it is**, **how
it's configured (and where)**, and **how to use it / what it's for**.
`mayssam-ai-stack.sh help services` lists every service that has a help entry.

## Decisions (approved)
- **Help prose lives in `services.yml`** as a per-service `help:` block (authored;
  seeded from the verified prose already in `doc/EXPLORE.html`).
- **"How it's configured" is COMPUTED at render time** (never stored, so it can't
  drift): install `phase`, `consumes_env` keys, config-file paths, port/alias —
  pulled live from `services.yml`/phase data — then any authored `config_notes`.
- **A regeneration command refreshes the prose from the live codebase** so it
  never goes stale (hybrid engine, below).
- **Command verb is `help`** (no bare `<service>` shorthand — avoids colliding
  with existing subcommands).
- **Scope:** all 39 `services.yml` entries. Per-Hermes-profile help is a follow-on
  (`hermes_fleet` help covers the team + points to `fleet list`).

## Data model — `help:` block
```yaml
services:
  claw3d:
    desc: "..."           # existing one-liner (kept)
    phase: "19"
    consumes_env: [...]   # existing — feeds the computed config section
    help:
      what:  "1–3 sentences: what it is."
      why:   "Purpose / when to reach for it."
      usage: ["bash bin/start-claw3d.sh", "open http://localhost:4310"]
      config_notes: "optional extra gotchas beyond the computed facts"
      _gen: { at: "<iso8601>", model: "<litellm model>", reviewed: false }
```

## Components
- `installer/lib/help.sh` — library (render + list + regen), sourced by the
  entrypoint, mirroring `installer/lib/models.sh` structure & house style.
- `mayssam-ai-stack.sh` — new `help)` dispatch → `cmd_help`.
- `services.yml` — `help:` blocks (data).

## Commands
- `help` → general usage + pointer to `help services`.
- `help services` → list services with a `help:` block (name + one-line `what`),
  grouped by phase/tier. Marks entries missing a block.
- `help <service|alias>` → render WHAT · HOW IT'S CONFIGURED (computed + notes) ·
  HOW TO USE / WHY. Alias resolution reuses the entrypoint's existing resolver.
  Unknown name → fuzzy suggestion + `help services`.
- `help regen [<service>] [--apply] [--check]`:
  - facts: always computed live (nothing to regenerate).
  - prose (`--apply`): per service, gather real context (start-script header,
    phase file, `desc`, `consumes_env`, code dir) → POST to **LiteLLM `:4000`**
    (configurable model; default a cheap/local one) → draft what/why/usage →
    write to a STAGING file + show a diff; `--apply` writes into `services.yml`
    via `yq`. Never silent-overwrites authored content.
  - `--check`: report services with missing/stale `help:` blocks (CI/doctor hook).

## Invariants / safety
- `set -Eeuo pipefail` + `inherit_errexit`; yq reads via captured vars (no
  pipefail SIGPIPE traps — see lib/models.sh notes).
- NEVER print secrets; regen sends only code/docs context to LiteLLM, never `.env`
  values. Uses the master key only to reach LiteLLM, never echoes it.
- Atomic writes (temp+mv) for any `services.yml` mutation.
- Pure-render path (`help <svc>`, `help services`) has NO network dependency —
  works even when the stack is down.

## Testing / verification
- `bash -n` on all touched files.
- `help services` + `help <svc>` for several services (claw3d, pi, unsloth,
  litellm) render all three sections correctly, offline.
- `help regen <svc> --check` and a single-service `--apply` dry diff against the
  live LiteLLM.
- Multi-agent code-review panel (shell-safety, security, conventions) before commit.
