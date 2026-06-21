# Docker global-context policy — kill the mid-run prompt (2026-06-21)

**Status:** shipped. Supersedes the *consented `docker context use`* prompt described in
[`2026-06-17-docker-engine-selection.md`](2026-06-17-docker-engine-selection.md) §key-decisions 2
and [`2026-06-17-docker-engine-selection-plan.md`](2026-06-17-docker-engine-selection-plan.md)
Task 7 (`engine_pin`).

## Problem

`engine_pin` (called from Phase 00 preflight, `deps.sh`, and doctor checks 01/47/48 —
i.e. *every* `install` and `doctor`) prompted interactively:

```
Also point your global `docker context` at OrbStack (ctx: ai-stack-orbstack)? [y/N]
```

It was gated only by `NO_PROMPT` + TTY, so any interactive `install`/`doctor` **blocked
mid-execution** waiting for a keypress. Bad UX, and it asked for consent on something
that is **cosmetic inside ai-stack** anyway: the exported `DOCKER_HOST` always overrides
`docker context`, so the switch only affects the user's *other* shells/tools.

## Decision

The global-context choice becomes a **persisted preference**, applied **silently and
non-interactively** — never a mid-run prompt. Configured once via `setup` (or the new
`docker-engine context` subcommand).

- **`AI_STACK_DOCKER_CONTEXT`** in `.env`:
  - `switch` *(default — the user's choice)* → `engine_pin` silently points the global
    `docker context` at `ai-stack-<engine>`, recording the prior context **once** in
    `AI_STACK_DOCKER_CONTEXT_PRIOR` for a clean undo. Idempotent (no-op once aligned).
  - `keep` → never touch the global context.
  - Any unrecognized value → treated as `keep` (fail-safe: never silently mutate on a typo).
- **Resolution:** the process env var `AI_STACK_DOCKER_CONTEXT` overrides the `.env` value;
  `.env` is the persisted source of truth. Note this overloads the **same** name for both
  the override and the persisted value (unlike the engine path's separate `AI_STACK_ENGINE_FLAG`),
  so a value **exported in your shell profile shadows `.env` persistently**, not just for one
  run — use it for one-shot/CI/test overrides, and set the durable preference via `setup` /
  `docker-engine context` (which write `.env`).
- **CI note:** under the default `switch`, `engine_pin` will silently point the global context
  at `ai-stack-<engine>` in CI too (there is intentionally **no** `NO_PROMPT` gate — that was
  the bug). A shared CI runner that relies on its global context pointing elsewhere should set
  `AI_STACK_DOCKER_CONTEXT=keep`. The stack itself is unaffected either way (`DOCKER_HOST` wins).
- **`engine_pin` never calls `read`.** A structural smoke-test guard enforces this so the
  UX regression can't silently come back.

## Surface

| Piece | Change |
| --- | --- |
| `engine_pin` | Delegates context handling to `engine_apply_context` (no prompt). |
| `engine_apply_context <id> <sock>` | New. Preference-driven, silent, idempotent, records prior once. |
| `engine_restore_context` | New. `keep` / `context keep` restores the recorded prior context. |
| `docker-engine context [status\|switch\|keep]` | New subcommand. `status` read-only; `switch`/`keep` persist + apply. |
| `docker-engine status` | Now also prints the context policy. |
| `setup` | New `setup_docker_context` step (the one interactive place it's asked). |
| `installer/smoke/engine.sh` | Stub-`docker` tests for keep/switch/idempotent/restore + the no-`read` guard. |

## Reversibility (SOUL §8)

- The prior context is recorded once (`AI_STACK_DOCKER_CONTEXT_PRIOR`); `docker-engine
  context keep` (or `docker context use <prior>`) restores it.
- `keep` is fully non-invasive. The default is `switch` per the operator's explicit choice.
- No container/image/volume is ever touched — purely a `docker context` pointer change.

## Doctor interaction

Check 47 (docker-engine consistency) compares the **ambient** context socket to the
selected socket. Because `engine_apply_context` creates `ai-stack-<engine>` with
`--docker host=$sock` using the **same** `engine_socket` value check 47 compares against,
the happy path is internally consistent:

- **`switch`, switch succeeded** → ambient context is `ai-stack-<engine>` → matches → 47 green.
- **`switch`, but `docker context use` FAILED** (the `warn` branch — e.g. a wedged docker CLI):
  `.env` says `switch` yet the ambient context is still the prior (non-ai-stack) one, so 47
  goes **red** — correctly surfacing that the global context does *not* reflect the selected
  engine. 47's auto-fix re-runs `engine_pin` → `engine_apply_context`, which retries the
  switch; if the underlying cause persists it stays red (a genuine signal, not a flap to paper
  over). The stack itself is unaffected throughout (`DOCKER_HOST` pins it regardless).
- **`keep`** → 47 behaves exactly as it did before this change. That means a `keep` user whose
  ambient context points at a *different* engine than the selected one will still see 47 red —
  this is pre-existing behavior, not introduced here, and is the cost of opting out of `switch`.
