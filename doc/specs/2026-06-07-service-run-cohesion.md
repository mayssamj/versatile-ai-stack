# Service run/lifecycle cohesion — design spec (2026-06-07)

Source: 3-agent design council (lifecycle architect · UX-contract lead · adversarial risk) + user decisions.

## Goal

One predictable way to run **any** service. `vz-ai-stack.sh start <svc>` (and its alias `run <svc>`)
works for every service, tells the user exactly how to reach it, and **opens the browser for UI
services**. No per-service custom incantations (`LMS_AUTOSTART`, `lms server start`, `install` used as
"run", `bash bin/start-*.sh`). Plus a full documentation sweep, including retiring the deprecated
`local-lfm2` (Ollama GGUF) references everywhere.

## Verb contract (true for every service)

| Verb | Contract |
|---|---|
| `install <svc>` | Provision: fetch/clone/build/configure so the service *exists & is ready*. Idempotent. Not the way to "run" it. |
| `start <svc>` / `run <svc>` / `enable <svc>` | Bring it up **now**, print the reachable URL + the `stop` command, and **open the browser if it's a UI**. Idempotent ("already running" = success, no re-open). `run` is a pure alias of `start`. |
| `stop <svc>` / `disable <svc>` | Bring it down now; idempotent. |
| `status [<svc>]` | The map: every service's up/down + URL + the one command to flip it. |

## `cmd_start` — the single funnel (vz-ai-stack.sh)

1. **Drop `exec`** (`exec bash "$script"` → `bash "$script"`) so post-start actions run. Preserve exit code. **Regression-test all 17 existing `bin/start-*.sh`.**
2. Add `run|enable` (already) + **`run`** to `is_subcommand`, the dispatch `case`, and the reverse-form `case`.
3. **Type-aware** behavior — read `services.yml` `.services.<svc>.type`:
   - has `bin/start-<svc>.sh` → run it; on success print the uniform report; browser-open if UI.
   - brew service (ollama/openshell) → `brew services start` (existing) + existing warnings.
   - **non-daemon** (`cli-only`, `clone-only`, `pip-package`, `npm-global`, `agent-pattern`, `litellm-feature`, `litellm-virtual-key`, `paperclip-plugin`, `hermes-profiles`, sandbox `openshell`/`sandbox-daemon` agents) → print an **honest categorical message** + the correct invocation (from `services.yml` `help.usage`), exit 0. **Never** the misleading "no start script" error.
   - unknown/no script + not brew + not a known non-daemon type → the existing error.
4. **Uniform report helper** `_report_started <svc>`: prints `URL: <url>` (or `Endpoint:` for non-UI) + `Stop: vz-ai-stack.sh stop <svc>`, computed from `services.yml` (`open_url`/`alias`/`host_port`). cmd_start calls it after a successful start (scripts keep their own logs; the authoritative reach line comes from here).
5. **Browser-open** `_browser_open <url>`: best-effort, **gated** — only when `open_url` set AND fresh start (not idempotent) AND macOS `open` / Linux `xdg-open` present AND interactive TTY AND not `NO_BROWSER`/CI. Always **print the URL** even when it can't open ("no browser opened — headless; open it yourself: <url>"). Flags: `--no-open`, `--open`.

## Browser URL source

New **optional `open_url:`** field in `services.yml` per UI service (explicit = correct for the no-alias/path-suffix cases: claw3d `localhost:4310`, deerflow `localhost:2026`, qdrant `/dashboard`, falkordb-ui). Absent → no browser-open. Add to: claw3d, openwebui, phoenix, falkordb(-ui), qdrant, deerflow, autofyn, paperclip, hermes_workspace, unsloth.

## Not-installed boundary (user decision: prompt-then-setup)

`start <svc>` checks setup prerequisites (enumerated: claw3d → `claw3d/node_modules`; lmstudio → `/Applications/LM Studio.app`). If missing:
- **Interactive TTY** → prompt: `"<svc> isn't set up yet — set it up now? (e.g. clone+npm, ~2 min) [y/N]"`. On `y` → run the install phase, then continue to start+open. On `n`/timeout → exit with the exact command.
- **Non-interactive / CI / NO_PROMPT** → do **not** auto-install; print `"<svc> isn't set up — run: vz-ai-stack.sh install <svc>"` and exit non-zero.
- Enumerated only (claw3d, lmstudio) — never a generic "install anything on start" hook.

## claw3d (user decision: stays in `install all`)

- `install all` / `install claw3d` (phase 19) keeps **provisioning** (clone + npm + `.env`/`settings.json`). It no longer "runs" claw3d as the user-facing path; it may leave it started, but the documented run path is `start`.
- **`start claw3d`** = the composite, idempotent, health-gated: **start `claw3d-bridge` → wait `/health` on its port → start the UI → wait `:4310` → open browser.** `bin/start-claw3d.sh` calls `bin/start-claw3d-bridge.sh` first and aborts if the bridge isn't healthy (no more "UI up, bridge dead, broken Connect"). Phase 19 delegates its launch to `start claw3d` (single source of truth — no duplicated launch logic).
- Doctor check 32 unchanged (claw3d stays provisioned by install all).

## lmstudio

- New **`bin/start-lmstudio.sh`** — guard-gated, server-only: `uname Darwin` → `/Applications/LM Studio.app` present → `lms` CLI bootstrapped → idempotent (`lms_server_up` ⇒ exit 0) → `lms server start -p 1234 --bind 0.0.0.0` → wait ready. Prints the CPU-idle-spin warning + "no model auto-loads; assign one + `model sync`". On non-mac / app-missing → clear refusal with the right command (not "no start script").
- `start lmstudio` routes to it.
- Phase 25 (install) keeps config/model wiring (assignment-driven, `LMS_LOAD_LFM2` opt-in); **`LMS_AUTOSTART`-as-run-path is removed** — its "server down" note now points to `vz-ai-stack.sh start lmstudio`.

## Documentation sweep (all levels, must be consistent)

- **New contract** (`run` alias, `start <svc>` opens UIs, `start lmstudio`, `start claw3d`, no `bash bin/*`, no `LMS_AUTOSTART`/`lms server start` as run path) reflected in: README, USER-GUIDE, OPERATIONS, ARCHITECTURE, DIAGRAMS(.md+.html), COMPONENTS, HANDOFF, EXPLORE.html, services.yml `help` blocks + the two in-CLI help texts, and **TUTORIAL.md → regen TUTORIAL.html** (doctor check 45 must stay green).
- **Deprecated `local-lfm2` (Ollama GGUF)** — no longer auto-pulled. Every reference (TUTORIAL recipes, USER-GUIDE, ARCHITECTURE, etc.) updated to either remove it or clearly mark it deprecated/manual-`ollama pull`, and use a zero-config model (`local-gemma4`) in runnable examples. Consistent everywhere.
- 2 independent agents audit the whole doc stack for residual drift after the sweep.

## Non-negotiable guardrails (Council C)

1. **`start` ≠ `install`**: no *silent* auto-install; prompt (interactive) or name the command (CI). No network/clone/npm without consent.
2. **Honest per-type degradation**: non-daemons get a categorical message + correct invocation, never "no start script".
3. **claw3d is a health-gated composite**; browser-open only after ready + GUI-gated.
4. **lmstudio**: macOS/app/`lms` guards; no lie on Linux/CI; keep the CPU-cost warning.
5. **Backward-compat**: `install claw3d` / `install lmstudio` still work as **setup**; `LMS_AUTOSTART` for the *install* path may stay but is no longer the run path.

## Out of scope (kept as distinct verbs, surfaced in status/help, NOT folded into start)

`bin/pi` / `bin/pi-as` (interactive REPL sessions), `tutorial-serve` (ephemeral demo server), `start-meridian.sh install/uninstall` (launchd persistence). `status`/`help` must make these discoverable so nothing is hidden.

## Verification

- bash -n all touched files; `start`/`run`/`stop` for a representative service of each type; `start claw3d` (bridge+UI+open) live; `start lmstudio` guard paths; `_is_brew_service` unaffected; doctor 32/38/45 green; `NO_BROWSER=1` no-op; reverse-form `<svc> start`.
- 2 code reviews + 2 doc audits + debate before merge; commit → pull → push.
