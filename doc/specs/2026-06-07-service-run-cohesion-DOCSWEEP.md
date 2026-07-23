# Doc-sweep contract — service run/lifecycle cohesion (Phase 3)

Shared facts ALL doc agents apply, consistently. Companion to the approved design + the SHIPPED
code (Phases 1+2, verified at GATE 1/2). Read this + your assigned files only. STRICT file
ownership — no two agents touch the same file. Don't touch `mayssam-ai-stack.sh`, `bin/*`,
`installer/*` (code is frozen + verified).

## The shipped run/stop contract (state it this way everywhere)

1. **One way to run anything:** `mayssam-ai-stack.sh start <svc>` — alias **`run <svc>`** (also `enable`).
   It prints a uniform reach line (`URL: …` for UIs, `Endpoint: …` for APIs) + a `Stop: …` line, and
   **auto-opens UIs in the browser**. Idempotent ("already running" = success, no re-open).
   Reverse-form `mayssam-ai-stack.sh <svc> start` also works.
   - Browser-open is **gated**: skipped on headless/CI/no-TTY, `NO_BROWSER=1`, or `--no-open`; the URL
     is always printed regardless. `--open` forces it.
2. **Never document `bash bin/start-<svc>.sh` as the way to run a service.** Replace such how-to-run
   lines with `mayssam-ai-stack.sh start <svc>`. (The `bin/start-*.sh` scripts remain the implementation;
   users don't invoke them directly.)
3. **claw3d:** `mayssam-ai-stack.sh start claw3d` is a **health-gated composite** — starts the bridge,
   waits for its `/health`, then starts the UI and opens the browser at **http://localhost:4310**.
   `install claw3d` (phase 19) = **SETUP only** (clone + npm), still part of `install all`.
   `stop claw3d` stops **both** the UI and the bridge.
4. **lmstudio:** `mayssam-ai-stack.sh start lmstudio` starts the LM Studio server (macOS/app/CLI-guarded;
   idempotent). It warns the app idle-spins ~0.8 core (quit when done) and that **no model
   auto-loads** — assign one in `models.yml` + `mayssam-ai-stack.sh model sync`. `stop lmstudio` stops the
   server. **`LMS_AUTOSTART` / `lms server start` are NO LONGER the documented run path** — use
   `start lmstudio`. (`LMS_AUTOSTART` may persist only as an install-time convenience.)
   `install lmstudio` (phase 25, opt-in) = setup + model wiring.
5. **Stop contract:** `mayssam-ai-stack.sh stop <svc>` (alias `disable`) brings any service down;
   idempotent. Stop paths now exist for every startable service: docker (`docker stop`), brew
   (ollama/openshell, with warnings), host-process via PID-file (claw3d, paperclip, docs_mcp,
   unsloth, …), and compose. New composite/compose stops: `stop claw3d` (UI+bridge), `stop paperclip`
   (daemon+relay), `stop honcho` (compose down — **warns it also stops the Postgres LiteLLM uses**),
   `stop autofyn` / `stop hermes_workspace` (compose down), `stop lmstudio` (server).
6. **Which UIs auto-open** (have an `open_url`): claw3d, openwebui, phoenix, qdrant (`/dashboard`),
   falkordb (→ the falkordb-ui dashboard at :3000), deerflow, autofyn, paperclip, hermes_workspace,
   unsloth. **API-only** services (litellm, honcho, llm_guard, docs_mcp) print an `Endpoint:` line and
   do NOT auto-open.
7. **Out-of-scope verbs (unchanged, keep documenting as distinct):** `bin/pi` / `bin/pi-as`
   (interactive REPL), `tutorial-serve` (ephemeral demo), `start-meridian.sh install/uninstall`
   (launchd). These are NOT folded into `start`; `status`/`help` surface them.

## Deprecated models — RETIRE everywhere (this is half the sweep)

The stack auto-pulls only `gemma4:e4b` (= `local-gemma4`, the zero-config Ollama default) +
`nomic-embed-text`. Two model ids are deprecated/removed and MUST be retired from docs:

- **`local-lfm2`** (LiquidAI LFM2.5 GGUF on Ollama) — **no longer auto-pulled**. Remove it from any
  runnable example. If it must be mentioned, mark it **deprecated** and note it requires a manual
  `ollama pull` by the user. Replace runnable-example usage with **`local-gemma4`**.
- **`local-heavy`** (the legacy Ollama `qwen3.6:27b`) — **removed from Ollama**. The heavy model now
  lives in **LM Studio as `local-qwen3.6`** (opt-in MLX, needs `start lmstudio` + assignment).
  Replace `local-heavy` references with `local-qwen3.6` (noting it's opt-in via LM Studio), or mark
  removed. Runnable examples should default to **`local-gemma4`**.

**Current model roster** (state consistently): 3 local — `local-gemma4` (Ollama default, zero-config),
`local-qwen3.6` + `local-qwen3-coder` (LM Studio MLX, opt-in) — plus the Claude **subscription**
effort ladder `claude-opus-4.8-sub-*` / `claude-sonnet-4.6-sub-*` via the Meridian host daemon
(no API key). Use `local-gemma4` in any "try it" / runnable example (zero-config, always available).

## Style / safety
- Match each file's existing voice + formatting; surgical edits, no gratuitous reflow.
- Keep claims TRUE to the shipped code — if unsure whether a command/behavior exists, flag it for the
  orchestrator rather than inventing.
- Do NOT hand-edit generated HTML acts in `TUTORIAL.html` (DS-5 regenerates it from the .md).
- Report a typed handoff: files touched, # of local-lfm2/local-heavy/bash-bin/old-run-path refs fixed,
  anything flagged.
