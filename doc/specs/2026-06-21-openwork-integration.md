# OpenWork Integration — Phase 29 (v1)

- **Date:** 2026-06-21
- **Status:** DRAFT — implemented in worktree; awaiting §24 council merge-review + live install test from main.
- **Owner:** OpenWork Integration lead (subagent) → manager (orchestrator) for council + live test + merge.
- **Scope of this spec:** **OpenWork only.** Follows the AionUi Phase 28 hybrid blueprint (`doc/specs/2026-06-20-aionui-integration.md`) where it fits; diverges where OpenWork's distribution differs (documented in §3).
- **Review:** §24 council to be convened by the orchestrator (architect + adversarial + QA/infra + PM) on the integration-shape decision + the security planks; consensus recorded post-review.

---

## 1. Problem & goal

Add first-class ai-stack support for **OpenWork** (`different-ai/openwork`, 16.2k★, MIT) — "the open-source alternative to Claude Cowork and Codex, powered by OpenCode." OpenWork is a free/local desktop **Cowork** app for doing work with AI agents on your own files; it brings any OpenAI-compatible LLM, extends agents with skills/plugins/MCP, and can run **headless** as a host orchestrator + browser UI. The goal: make OpenWork a managed, **opt-in** service of the stack — installed, wired to LiteLLM (so every stack model appears inside it), reachable in a browser, with the same install / doctor / tutorial / docs / help treatment every other service gets.

**Integration philosophy:** *Hybrid — native + stack-wired*, same as AionUi. But OpenWork's headless story is **first-class and prebuilt** (an npm-distributed, Bun-compiled standalone binary), so the *managed service* is the **headless orchestrator (web/host mode)**, not the desktop app. The desktop app is documented as an optional alternate UI. (This is the inverse of AionUi, where the cask was the install and the web binary was the bonus — justified in §3.)

## 2. Background — verified facts about OpenWork (FACT unless marked)

Each item below was directly verified at spec time (web docs + `gh` against the real repo/releases + the **actual binary run on this M4**), not assumed.

- **What it is / license:** Desktop Cowork app (macOS/Windows/Linux) **powered by OpenCode**. License = **MIT** for everything outside `/ee` (the `/ee` dir is Fair Source; we ship none of `/ee`). The orchestrator npm package's own `package.json` declares `"license": "MIT"`. FACT (read `LICENSE` from branch `dev`).
- **Headless distribution (THE key fact):** `npm install -g openwork-orchestrator` installs the `openwork` command. The npm package (`openwork-orchestrator@0.17.1`, 5.6 KB) is a thin platform-dispatcher with `optionalDependencies` on per-platform prebuilt binaries (`openwork-orchestrator-darwin-arm64@0.17.1`, a **63 MB Bun-compiled Mach-O arm64 standalone**) + a `postinstall.mjs` GitHub-Releases fallback (`openwork-bun-darwin-arm64` from the `openwork-orchestrator-v<version>` release). **"`openwork` ships as a compiled binary, so Bun is not required at runtime."** FACT — downloaded both tarballs; the binary is `Mach-O 64-bit executable arm64` and `--help` exits 0 on this M4.
- **OpenCode is NOT a new host dependency for the orchestrator:** the `openwork` binary **downloads + caches** the `opencode`, `openwork-server`, and `opencode-router` sidecars on first run via a **SHA-256 manifest** (`--opencode-source auto|bundled|downloaded|external`; `constants.json` pins `opencodeVersion v1.17.3`). **FACT, verified live:** a bounded `serve --check` run on this M4 spawned opencode itself (`opencode server listening on http://127.0.0.1:62722`, "Healthy") with zero host `opencode` install. The README's "OpenCode CLI on PATH" requirement applies only to the **desktop/source build**, not the orchestrator binary. → The OpenCode dependency cost is borne by OpenWork itself; the stack adds no `opencode` install.
- **Headless run + bind:** `openwork serve --workspace <path>` = "Start services and stream logs (no TUI)" — the headless mode. Defaults: `--openwork-host 127.0.0.1`, `--openwork-port 8787`, `--opencode-host 127.0.0.1` ("loopback only"). `--remote-access` is the ONLY 0.0.0.0 path (we never pass it). `--detach` keeps services running and exits (launchd-friendly). `--check` = run health checks then exit. `--approval manual|auto`, `--read-only`, `--sandbox none|auto|docker|container` (default `none`). FACT (`openwork --help` + `serve --help`, run live).
- **There IS a clean `/health` 200 endpoint:** the live `serve --check` run showed `[openwork-server] GET /health 200` and the orchestrator self-reported "Healthy", then `Checks: ok` / `rc=0`. So the daemon/doctor/smoke health-gate uses `http://127.0.0.1:8787/health` → `200` (a real health endpoint, NOT the bare root). FACT, verified live.
- **LLM wiring is FILE-SEEDABLE (a win over AionUi):** OpenWork drives OpenCode, which reads **`opencode.json`** (`$schema https://opencode.ai/config.json`). Provider scope: project `<workspace>/opencode.json` or global `~/.config/opencode/opencode.json`. An OpenAI-compatible endpoint (LiteLLM) is a `provider` block: `{ "npm": "@ai-sdk/openai-compatible", "name": "...", "options": { "baseURL": "http://127.0.0.1:4000/v1", "apiKey": "{env:VAR}" }, "models": { "<id>": {...} } }`. FACT (OpenCode provider docs + OpenWork README "uses the same format as the OpenCode CLI"). → We CAN pre-seed the config; the LiteLLM key stays out of the file via `{env:VAR}` indirection.
- **Secret hygiene is upstream-aligned:** the orchestrator "prints pairing URLs by default and **withholds live credentials from stdout** to avoid leaking them into shell history or collected logs. Use `--json` only when you explicitly need the raw pairing secrets." Tokens: `--openwork-token` (client), `--openwork-host-token` (approvals). FACT (orchestrator README + live run: every token printed as "issued (withheld from stdout)").
- **GitHub Releases ship only the DESKTOP app** (`.dmg`/`.zip` for mac, `.exe` for win) under `alpha-macos-*` / `v0.17.x` tags — **no headless tarball there**; the headless binary lives on **npm** (+ the separate `openwork-orchestrator-v<version>` release fallback for the raw `openwork-bun-*` asset). FACT (`gh release view`). → Our install path is npm/pinned, not curl+SHA of a GitHub release tarball (npm provides integrity: `dist.integrity` sha512 + provenance signatures).
- **macOS support:** Yes — native arm64 binary, runs on this M4 (the whole `serve --check` lifecycle: spawn opencode → spawn openwork-server → health 200 → clean shutdown). FACT.

## 3. Architecture decision — Design Y (headless orchestrator), X documented-only

Two shapes were considered (mirroring AionUi's X/Y framing):

- **Design X — desktop app + stack-wired.** Install the OpenWork desktop app (`.dmg` from Releases — there is no Homebrew cask as of spec time), seed `~/.config/opencode/opencode.json` → LiteLLM, document the rest. Lightest in moving parts, but: (1) no cask = no idempotent brew install (we'd hand-manage a 245 MB `.dmg` mount/copy/quarantine); (2) not browser-accessible / not a managed daemon → doesn't fit the stack's "reachable, health-gated, start/stop funnel" service model; (3) the desktop app's host mode still spawns the same orchestrator under the hood.
- **Design Y — headless `openwork-orchestrator` as a managed loopback daemon.** `npm i -g openwork-orchestrator` (prebuilt binary, OpenCode self-managed), seed a project `opencode.json` → LiteLLM via a scoped key, run `openwork serve` as a loopback launchd daemon on `:8787`, browser-accessible, with `start|stop|doctor|help` funnel. Richer AND, here, **lighter** than X (no `.dmg` handling, no Tauri/Rust, OpenCode self-bootstraps).

**Decision: Design Y. X is documented-only.** Rationale:
1. **Y is the stack-native shape** — a managed, loopback, health-gated, browser-reachable daemon with the full `start/stop/doctor/help` funnel, exactly like Open WebUI / Meridian / AionUi-web. X (a desktop `.dmg`) cannot be a managed service.
2. **Y is actually lighter here** — the headless binary is **prebuilt** (no source build, unlike AionUi-web's Bun compile), OpenCode is **self-managed** (no new host dep — verified live), and there's no 245 MB cask/`.dmg` to hand-install. The feared "OpenCode dependency" evaporates because OpenWork owns it.
3. **Y is file-seedable** — `opencode.json` lets us automate the LiteLLM wiring (a real UX win AionUi couldn't have: its config is UI-only SQLite). Less guided friction.
4. **The only cost of Y** — the orchestrator downloads ~tens-of-MB of sidecars on first run (network-dependent) and runs OpenCode on the host (not in the credential-isolated OpenShell sandbox). For a human-driven, loopback-only, approval-gated GUI this is acceptable and matches AionUi's accepted posture; it's mitigated by §7. OpenWork additionally offers `--sandbox docker|container` as a future hardening lever (out of scope for v1; documented).

The desktop app remains a **documented alternate UI** (`help openwork` + tutorial note: download from Releases, point its OpenCode at LiteLLM the same way) — not installed or managed by the phase.

## 4. v1 design (the planks)

Phase **29**, **opt-in**, fail-isolated **leaf** — NOT in `install_all_phase_order()` (the sole core-vs-opt-in lever). Its failure must not regress the doctor count or any other phase. Precedent: 27 sourcegraph, 28 aionui.

- **(a) Install the headless orchestrator** — `npm install -g openwork-orchestrator@<pinned>` (idempotent: skip if `openwork` resolves AND `openwork --version` matches the pin). Pin via `OPENWORK_VERSION` (default a known-good `0.17.1`; `latest` allowed as an override). Requires `node`/`npm` (host dep, bootstrapped by `installer/lib/deps.sh`). The npm install pulls the prebuilt platform binary (integrity-checked by npm); we additionally assert the resolved `openwork` binary is runnable (`--version`) before proceeding — fail-closed if it isn't.
- **(b) LiteLLM wiring** — mint a **separate, model-scoped** LiteLLM virtual key for OpenWork (only the models it needs; **never** the master key, **never** the fleet key; same mint+validate pattern as Phase 28). Then **pre-seed** a project `opencode.json` at the OpenWork workspace dir (`~/.openwork-stack/opencode.json`) with the LiteLLM provider block (`@ai-sdk/openai-compatible`, `baseURL http://127.0.0.1:4000/v1`, `apiKey {env:OPENWORK_LITELLM_KEY}`, the curated model map). The key is exported into the daemon's environment by the launchd plist (read from `.env` at install time) — it never lands literally in `opencode.json`. A `help openwork` + tutorial checklist documents the values for the desktop-app path.
- **(c) The managed daemon** — run `openwork serve` as a **loopback-only launchd daemon** mirroring `bin/start-aionui.sh`: `RunAtLoad`+`KeepAlive`, **bind `127.0.0.1` only** (never `--remote-access`/`0.0.0.0`), `--no-tui`, `--approval manual` (require approvals; no `auto` on the host), health-gate on `/health` 200 before declaring up, `install|run|uninstall|status|stop|restart` verbs, binary resolved without a login shell. Browser at `http://127.0.0.1:8787`. The `--openwork-token`/`--openwork-host-token` are generated via `openssl rand`, persisted to `.env` 0600, passed via **env vars** (never CLI flags → not visible in `ps`), never printed to stdout/logs.
- **(d) Agent bridge (documented, not auto-wired in v1)** — OpenWork's agents ARE OpenCode (with skills/plugins/MCP). Wiring the Hermes fleet or stack MCP servers into OpenWork = adding OpenCode plugins/MCP entries to `opencode.json` — a **documented follow-up** (Phase 29b), not a v1 plank. v1 ships the model wiring (b); the agent/skill layer is "works because it's OpenCode," documented in `help`/tutorial.

**Positioning (PM):** OpenWork's non-redundant value is a **local Cowork workspace built on the OpenCode engine** — file-centric agentic work with skills/plugins/MCP and an auditable approval flow, in a browser, over your stack's models. It complements Open WebUI (single-model chat), AionUi (ACP multi-agent GUI), and claw3d (fronts the roles). The tutorial leans into "OpenCode-powered agent workspace, file-first, approval-gated."

## 5. What gets built (platform contract)

**Create:**
- `installer/phases/29_openwork.sh` — opt-in, idempotent, **stamp-gated** (stamp AFTER smoke passes), sources `installer/lib/worktree.sh` (via common.sh's guard) before any launchctl; mirrors `28_aionui.sh`.
- `bin/start-openwork.sh` (+ `bin/stop-openwork.sh`) — Meridian/AionUi-pattern managed daemon (loopback-only, generated tokens, self-contained binary resolution).
- `installer/doctor/checks/51_openwork.sh` — **3-state pass-as-skip** (not installed → green advisory; installed-not-enabled → green advisory; enabled-unhealthy → red), modeled on `50_aionui.sh`. Health probe = explicit `grep -q '^200$'` on `:8787/health` (NOT the `http_ok` helper — the `000000` false-healthy bug). LiteLLM sub-check gated on LiteLLM reachable + 503-aware (`litellm_db_down`).
- `installer/smoke/29.sh` — see §10.

**Edit:**
- `services.yml` — one `openwork` entry, **`type: node-bg`**, **`network: host`** (host process, not a container → doctor check 16 N/A; no bridge-exempt label), `port: 8787`, `phase: "29"`, `health: http://127.0.0.1:8787/health`, with a `help:` block (+ `_gen`).
- `vz-ai-stack.sh` — add 29 to the opt-in extras help strings (lines ~268, ~566) — and fix the pre-existing omission of 28 there while at it; start/stop/help dispatch is generic (service-name → `bin/start-openwork.sh` / services.yml), so no per-service code. (29 is opt-in by being ABSENT from `install_all_phase_order()` — no edit there.)
- LiteLLM virtual-key mint (scoped) — Phase 28 mint pattern, distinct minimal scope.
- `doc/TUTORIAL.md` (+ regen `TUTORIAL.html`, `--check` drift guard green) — add OpenWork to the L29 opt-in-extras lesson + the install block (like aionui was added).
- `doc/EXPLORE.html` — SERVICES array entry (tier `extras`; count self-audits via `SERVICES.length`) + the hardcoded `"All 41 installed services"` subtitle bump.
- Doc sweep — services 42→43, doctor count 51→52 (auto-bumps dynamically; sweep human-readable prose only), opt-in extras 7→8. **Exact current counts verified by file-count at impl, not trusting prose.**
- `CHANGELOG.md` / `CHANGELOG.d/`.

`installer/models.yml` — untouched (OpenWork consumes LiteLLM; no new models).

## 6. Service model (how OpenWork maps to the stack CLI)

OpenWork has two faces, exposed through one service entry:
- **Headless orchestrator (`openwork serve`)** — the managed daemon (the service). `start openwork` ensures it's running + opens the browser URL (health-gated, single funnel). `stop openwork` tears it down. `doctor` health-checks `:8787/health`. `help openwork` surfaces both faces + the LiteLLM/opencode.json wiring.
- **Desktop app** — a documented alternate UI (download from Releases), not installed/managed by the phase.

So `services.yml` has **one** `openwork` entry whose daemon/health is the orchestrator on `:8787`.

## 7. Security requirements (NON-NEGOTIABLE)

1. **Scoped-minimal LiteLLM key.** Mint a key limited to the models OpenWork needs. Never reuse the master or the `hermes-fleet` key. Store via `set_env` (0600 `.env`); never rm the key on teardown (never-rm-env rule). The key reaches OpenCode only via `{env:OPENWORK_LITELLM_KEY}` in `opencode.json` + the daemon env — it is **not** written literally into any config file.
2. **`openwork serve` binds `127.0.0.1` only.** Never `--remote-access` / `0.0.0.0`. `--openwork-host 127.0.0.1` + `--opencode-host 127.0.0.1` explicit.
3. **Tokens via env, never argv/stdout.** `--openwork-token` / `--openwork-host-token` generated with `openssl rand`, persisted to `.env` 0600, passed as **env vars** to the daemon (never as CLI flags → not in `ps`), never printed to stdout / logs / shell history. Do not pass `--json` in the daemon (it would print live secrets).
4. **`--approval manual` on the host.** No `--approval auto` for a host daemon — agentic file/shell actions require explicit approval (the orchestrator exposes `openwork approvals list/reply`). `--sandbox docker|container` is a documented future hardening, not v1.
5. **SHA / integrity for the binary (fail-closed).** The npm path is integrity-checked by npm (`dist.integrity` sha512 + provenance signatures); we additionally fail-closed if the installed `openwork --version` does not run/match the pin. If a future raw-binary fallback is added, it must SHA256-verify against the upstream sidecar manifest before use.
6. **No secrets to stdout/argv/logs.** Daemon log at `installer/state/openwork.launchd.log` 0600. Mint/token generation never echo the secret.

## 8. Resource budget (M4 / 24GB)

Affordable with guards. `openwork serve` runs `openwork-server` + `opencode` (Node/Bun-class resident) — comparable to Meridian/AionUi-web plus an idle OpenCode. First run downloads ~tens of MB of sidecars (one-time, cached under `--sidecar-dir`). The desktop app is NOT installed (no Electron/Tauri resident). Doctor emits a RAM advisory (not red) if LM Studio holds a big model AND OpenWork is active. The phase does not pull any LLM model (OpenWork consumes LiteLLM).

## 9. Pre-build verification gate (verify-first; each gates a plank) — STATUS

Run BEFORE / during building the corresponding plank; any failure auto-defers that plank (and is reported honestly):

1. **orchestrator binary runs on M4** — `openwork --help` / `serve --help` / `--version` exit 0. **PASS — verified live** (Mach-O arm64, exit 0, full help; `--version` = `0.17.1`). *(gates a)*
2. **`openwork serve` brings up a reachable loopback server + a clean health endpoint** — **PASS — verified live**: `serve --check` spawned opencode (`:62722` Healthy) + openwork-server (`:8799`), `GET /health 200`, `Checks: ok`, `rc=0`, clean auto-shutdown. Health-gate = `:8787/health` → `200`. *(gates c)*
3. **`opencode.json` LiteLLM provider** — the `@ai-sdk/openai-compatible` block with `baseURL`/`apiKey {env:..}` format is **verified from OpenCode docs**; end-to-end "model appears in the orchestrator UI" is a live-test item (needs the daemon up + the seeded config). *(gates b — low risk; format is documented)*
4. **npm install resolves the prebuilt binary on M4** — the platform package (`openwork-orchestrator-darwin-arm64`, 63 MB, runnable) + npm metadata + the postinstall GitHub fallback are **verified**; the actual `npm i -g` global install is a **live-test item** (touches host npm global; do from main). *(gates a)*

## 10. Acceptance criteria (testable) & DoD

- **AC-1:** `vz-ai-stack.sh install 29` (alias `install openwork`) is idempotent and, on success, leaves `openwork` installed + the daemon healthy on `:8787/health`. Smoke `installer/smoke/29.sh` asserts: `openwork` resolves + `--version` runs; the OpenWork LiteLLM virtual key exists in `/key/list` and performs a **real 1-token chat completion** against `http://127.0.0.1:4000/v1` (the actual OpenWork→OpenCode→LiteLLM path); `:8787/health` returns `200`; `opencode.json` is present + valid JSON with the LiteLLM provider; `build_tutorial_html.py --check` exits 0. Stamp written only AFTER smoke passes.
- **AC-2:** `vz-ai-stack.sh doctor` is green from **main** — the new `51_openwork.sh` passes (green advisory when OpenWork absent/disabled; red only when enabled-and-unhealthy). Doctor count reflects the new check (verified by file-count).
- **AC-3:** `vz-ai-stack.sh help openwork` returns what/why/usage/config; `start openwork` / `stop openwork` work as a single funnel (opens the URL gated on health).
- **AC-4 (live E2E, SOUL §5):** from a browser at `http://127.0.0.1:8787`, with the seeded LiteLLM provider, **get a reply from a stack model** through OpenWork→OpenCode→LiteLLM. Verified from the app, not a green log. (Live-test by the orchestrator from main.)
- **AC-5 (security):** the minted key is scoped-minimal and not the master/fleet key; `openwork serve` binds loopback only; tokens generated + env-passed, never printed/in-argv; `--approval manual`; no `--remote-access`; daemon log 0600.
- **AC-6 (docs cohesion):** tutorial lesson present + `--check` green; EXPLORE.html + all count-bearing docs swept and consistent (file-count verified); CHANGELOG updated.

**DoD:** all ACs met; §24 merge-review council sign-off; merged to main + pushed + branch cleaned; durable memory residue written. The agent/skill bridge (d) is explicitly v1-deferred (Phase 29b) — that is an acceptable v1 outcome; (a)(b)(c) satisfy the DoD.

## 11. Risks & mitigations

- **`serve` first-run sidecar download slow/offline** → the daemon health-gate polls with a generous window; the phase smoke is **leaf-safe** (a slow/blocked external download must not hang or hard-fail the opt-in phase — it warns + does not stamp). `--sidecar-dir`/`--sidecar-base-url` documented for mirrors/offline.
- **npm global install fragility** → pinned version; integrity via npm; fail-closed `--version` assertion; the GitHub-release postinstall fallback covers the optionalDep-skip case.
- **Host agent with creds = blast radius** → loopback-only, `--approval manual`, scoped key, `{env:}` indirection, documented trade-off (§7); `--sandbox` as a future lever.
- **No Homebrew cask for the desktop app** → desktop is documented-only (download from Releases); the managed service is the headless orchestrator (which is the right shape anyway).
- **Parallel-session git collisions** → all edits in this worktree; live stack operated only from main ([[feedback_worktree_breaks_live_stack]], [[feedback_always_use_worktrees]]).

## 12. Out of scope / follow-ups

- **Phase 29b** — the agent/skill/MCP bridge (wire the Hermes fleet + stack MCP servers into OpenWork via `opencode.json` plugins/MCP), and optionally `--sandbox docker|container` hardening.
- **Desktop app management** (cask if one appears upstream; `.dmg` automation).
- **Keychain storage** for secrets (beyond 0600 `.env`).

## 13. Open questions (resolve during live-test, not blockers)

First-run sidecar-download time on a cold M4; whether the seeded `opencode.json` provider surfaces models without any UI step in the orchestrator web UI (model wiring is documented either way); current exact service/doctor/opt-in counts (file-count at impl — 43/52/8 expected).
