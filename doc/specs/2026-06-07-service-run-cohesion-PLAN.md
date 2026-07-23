# Execution plan — service run/lifecycle cohesion (2026-06-07)

Orchestrated multi-agent build. Companion to the approved design:
`doc/specs/2026-06-07-service-run-cohesion.md`. The orchestrator (main agent) decomposes,
coordinates, runs the gates, integrates, and is the ONLY one allowed to commit/push.

## Locked decisions (do not re-litigate)
1. **start-when-not-set-up = PROMPT-then-auto-setup** in an interactive TTY (`"<svc> isn't set up — set it up now? [y/N]"` → run install → continue). In **CI / non-interactive / NO_PROMPT** → do NOT auto-install; print the exact `install` command and exit non-zero. Enumerated services only (claw3d, lmstudio).
2. **claw3d stays provisioned by `install all`** (phase 19). `install` = setup; `start`/`run` = run+open. Doctor check 32 unchanged.

## Cardinal rule — NO TWO AGENTS EDIT THE SAME FILE
Parallelism is by strict **file ownership**. Each file has exactly ONE owning workstream for the whole run. Agents run in the shared working tree; disjoint files ⇒ no collisions. The orchestrator integrates + verifies between phases. ≥2 reviews + debate before "done" (team-protocol). bash -n every shell edit. Commit → pull → push only at the end (orchestrator).

---

## Interface contract (orchestrator defines BEFORE Phase 1; all agents code to it)
`cmd_start`/`cmd_stop` read these from `services.yml` per service:
- `.services.<svc>.type` — drives behavior (daemon-with-script | brew-service | non-daemon).
- `.services.<svc>.open_url` — OPTIONAL absolute URL; present ⇒ UI ⇒ browser-open eligible.
- `.services.<svc>.alias` / `.host_port` — fallback for the "Endpoint:" report line.
Helpers (live in `mayssam-ai-stack.sh`, owned by WS-A): `_report_started <svc>` (prints URL/Endpoint + `Stop:` line), `_browser_open <url>` (gated: macOS `open`/Linux `xdg-open`, interactive TTY, not `NO_BROWSER`/CI, only on fresh start), `_ensure_setup <svc>` (prompt-then-install per Decision 1). Start scripts exit 0 idempotently and print their own logs; the authoritative reach line + browser-open come from `cmd_start`.

---

## PHASE 1 — CODE (4 agents, parallel, file-disjoint)
- **WS-A — `mayssam-ai-stack.sh` ONLY** (backend-engineer/strongest): add `run` alias (is_subcommand + dispatch case + reverse-form); rewrite `cmd_start` → drop `exec`, type-aware dispatch, `_report_started`, `_browser_open`, `_ensure_setup`; honest non-daemon messages; update `usage`/inline help. MUST preserve exit codes + not break the 17 existing start scripts.
- **WS-B — `bin/start-lmstudio.sh` (NEW) + `installer/phases/25_lmstudio.sh`** (backend-engineer): create the guarded server-only start script (Darwin→app→lms CLI→idempotent→`lms server start -p 1234 --bind 0.0.0.0`→wait→CPU warning); strip `LMS_AUTOSTART`-as-run-path from phase 25, point its "server down" note to `start lmstudio`.
- **WS-C — `bin/start-claw3d.sh` + `bin/start-claw3d-bridge.sh` + `installer/phases/19_claw3d.sh`** (backend-engineer): `start-claw3d.sh` starts the bridge first + health-gates `/health` before the UI, aborts if bridge unhealthy; phase 19 delegates its launch to `start claw3d` (no duplicated launch logic).
- **WS-D — `services.yml` ONLY** (backend-engineer): add `open_url` to UI services (claw3d 4310, openwebui, phoenix, falkordb-ui, qdrant /dashboard, deerflow 2026, autofyn, paperclip, hermes_workspace, unsloth); ensure each service has a correct `type`; update the lmstudio/claw3d `help` blocks to the new run contract.

**GATE 1 (orchestrator):** integrate; `bash -n` all; smoke `start`/`run`/`stop` for one of each type; `start claw3d` live (bridge+UI+open); `start lmstudio` guard paths (incl. non-mac/app-missing message); `NO_BROWSER=1` no-op; reverse-form `<svc> start`; `_is_brew_service` unchanged; doctor 32/38 green. Fix before proceeding.

## PHASE 2 — CODE REVIEW (2 agents, parallel) + debate
- reviewing-engineer (adversarial bug/regression: the `exec`-drop blast radius, errexit, browser-open races, prompt-install footguns, idempotency).
- general-purpose (design/UX-cohesion + the non-daemon matrix honesty + backward-compat: `install claw3d`/`install lmstudio`/`LMS_AUTOSTART` still work as SETUP).
Orchestrator runs a 3-way debate, applies must-fixes, re-verifies (GATE 2).

## PHASE 3 — DOC SWEEP (5 agents, parallel, file-disjoint). Each agent: (a) update for the new run/start contract, (b) RETIRE the deprecated `local-lfm2` Ollama GGUF refs (remove or mark deprecated/manual `ollama pull`; use `local-gemma4` in runnable examples).
- **DS-1** → `README.md`, `doc/USER-GUIDE.md` (+ regen `USER-GUIDE.html` if a generator exists, else edit).
- **DS-2** → `doc/OPERATIONS.md`, `doc/TROUBLESHOOTING.md`, `doc/DOCTOR.md`, `doc/models.md`.
- **DS-3** → `doc/ARCHITECTURE.md`, `doc/COMPONENTS.md`, `doc/DIAGRAMS.md` (+ `DIAGRAMS.html`), `doc/ATTRIBUTION.md`.
- **DS-4** → `doc/EXPLORE.html` (single-file; verify embedded SERVICES array consistency).
- **DS-5** → `doc/TUTORIAL.md` THEN regen `doc/TUTORIAL.html` via `installer/lib/build_tutorial_html.py` (NEVER hand-edit the .html acts). Retire `local-lfm2` in the recipes.
- **DS-6 (orchestrator)** → `doc/HANDOFF.md`, `CHANGELOG.md`. (`services.yml` help stays WS-D's.)

**GATE 3 (orchestrator):** `build_tutorial_html.py --check` + doctor 45 green; grep the whole repo for residual stale claims (`install lmstudio` as run, `LMS_AUTOSTART` as run, `bash bin/start-*`, bare `local-lfm2`).

## PHASE 4 — DOC AUDIT (2 agents, parallel, read-only) + debate
Two independent agents audit the ENTIRE doc stack vs the shipped code/system for drift, contradictions, broken commands, and any surviving `local-lfm2`/old-run-path references. Orchestrator reconciles + fixes (owners re-edit their files).

## PHASE 5 — FINALIZE (orchestrator)
Full doctor pass; final `bash -n`; commit (one focused commit, or split code/docs) → `git pull --rebase` → `git push`; verify `origin/main == main`; update `HANDOFF.md` + `CHANGELOG.md` + memory (`MEMORY.md` + relevant files).

---

## Concurrency / safety notes
- Phase 1: 4 agents in parallel (A,B,C,D) — disjoint files. Phase 3: 5 agents in parallel (DS-1..5) — disjoint files. Reviews/audits are read-only (any number parallel).
- The ONLY shared-file hazard is `mayssam-ai-stack.sh` (WS-A) and `services.yml` (WS-D) — each single-owned; doc agents must NOT touch either.
- If an agent needs a field not in the contract, it asks the orchestrator (do not invent schema).
- Verification is non-negotiable between phases; never advance a gate on an unverified phase.
