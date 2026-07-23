# AionUi Integration — Phase 28 (v1)

- **Date:** 2026-06-20
- **Status:** DRAFT — awaiting user review of this spec, then `writing-plans`
- **Owner:** manager (orchestrator)
- **Scope of this spec:** **AionUi only.** OpenWork follows in its own spec → plan → build cycle (user decision: "AionUi first").
- **Review:** §24 council (architect + adversarial + QA/infra + PM) reviewed the architecture decision; consensus recorded in §13.

---

## 1. Problem & goal

Add first-class ai-stack support for **AionUi** (`iOfficeAI/AionUi`) — "everything from install, setup, usage, integrations, tutorial, documentation." AionUi is a free/local/open-source (Apache-2.0) desktop **Cowork** app: it chats with any OpenAI-compatible model and drives external CLI agents over **ACP (Agent Client Protocol)**. The goal is to make AionUi a managed, opt-in service of the stack: installed, wired to LiteLLM (so every stack model appears inside it), reachable in a browser, and able to surface the 9-role Hermes fleet as agents — with the same install / doctor / tutorial / docs treatment every other service gets.

**Integration philosophy (user decision):** *Hybrid — native + stack-wired.* Install natively (the intended UX), but the stack owns the integration (LiteLLM wiring, key mint, phase, doctor, help/start, tutorial, docs).

## 2. Background — verified facts about AionUi

(Each is verified from upstream docs / the Homebrew cask / live `--help`, not assumed. Items marked **VERIFY** are impl-time confirmations.)

- **Install:** `brew install --cask aionui` (Homebrew cask exists; macOS ≥ 11). The cask installs **only `AionUi.app`** (zap dirs `~/.aionui` + `~/Library/Application Support/AionUi`; `auto_updates true`). **There is NO `aionui-web` server binary in the cask** — the WebUI server lives in source (`packages/web-cli`) only.
- **LLM wiring:** AionUi supports a **Custom / OpenAI-compatible** provider: Settings → Models → Add Model → **Custom** → fields **Base URL** (e.g. `http://127.0.0.1:4000/v1`, includes `/v1`), **API Key**, **Model names** (entered manually). Models must support `function_calling` to appear in chat. Config lives in a **SQLite DB** under `~/Library/Application Support/AionUi/` and is UI-driven — **not documented as file-seedable** → setup is guided, not silently pre-seeded.
- **WebUI server (source only):** `aionui-web` CLI (entry `packages/web-cli/src/index.ts`); default port **25808** (`--port` / `AIONUI_PORT`); `--remote` / `AIONUI_ALLOW_REMOTE` exposes beyond loopback (default loopback-only); **admin password auto-generated on first launch**; data dir `~/.aionui-web` (`--data-dir` / `AIONUI_DATA_DIR`); shares the same `aioncore` backend + SQLite as desktop. **VERIFY**: exact flag names + that a Bun source build runs cleanly on M4.
- **ACP agent integration:** AionUi is a registered ACP client (zed.dev/acp/editor/aionui). It detects agents by **scanning host PATH** for a CLI binary and spawning it as a subprocess speaking **ACP = JSON-RPC 2.0 over stdio (NDJSON)**. Custom ACP agents (Settings → Agent Management → Custom Agents) take **`cliCommand`**, **`acpArgs`** (array), **`env`**, **`defaultCliPath`** — and a **wrapper script is an explicitly supported pattern** (`cliCommand: python3, acpArgs:[wrapper.py]`). **VERIFY**: exact schema + whether custom agents are file- or SQLite-configured.
- **Hermes ACP:** `hermes-agent` ships a native ACP server — `hermes acp` / `hermes-acp` / `python -m acp_adapter` (→ `acp_adapter.entry.main()`); **stdout reserved for ACP JSON-RPC, logs → stderr**. Install: `pip install hermes-agent[acp]` + `hermes postinstall`. Config reused from `~/.hermes/{.env,config.yaml}` (set via the `hermes model` wizard / `hermes config set`; can target an OpenAI-compatible endpoint). Profiles are first-class: `~/.hermes/profiles/<name>/`, `hermes profile import/use`. **The fleet pins `hermes-agent[mcp]==0.16.0` INSIDE the OpenShell sandbox → a host `[acp]` install is independent (zero blast radius on the running fleet).**
- **🔴 `hermes acp` has NO `--profile` flag** (verified live: flags are `--accept-hooks`, `--version`, `--check`, `--setup`, `--setup-browser`, `--yes`). Surfacing N roles therefore requires **per-profile-process isolation** — a per-role wrapper that sets `HERMES_HOME` (or runs `hermes profile use <role>`) then `exec`s `hermes acp`, registered as a distinct AionUi custom agent. **VERIFY**: the per-profile `HERMES_HOME` mechanism works and `hermes acp` runs cleanly without `--yolo`.

## 3. Architecture decision — Design X (host-native), Y rejected

The Hermes bridge could be built two ways:

- **Design X — host-native `hermes-acp`.** Install `hermes-agent[acp]` on the host (independent of the sandbox's 0.16.0), point its provider at LiteLLM, import the fleet souls as host profiles, register per-role wrapper(s) in AionUi as custom ACP agents. AionUi spawns `hermes-acp` directly over stdio — real ACP streaming, no relay in the loop.
- **Design Y — wrapper → containerized fleet.** A Python ACP server registered in AionUi that proxies each turn into `openshell sandbox exec -n hermes-fleet-v1 -- hermes -p <role> -z "<prompt>"` (claw3d-bridge pattern), reusing the literal sandbox.

**Decision: Design X. Y is rejected.** Unanimous council. Y is unsound because (1) the one-shot `hermes -z` call **cannot satisfy ACP's stateful conversational contract** — each turn cold-starts and loses in-agent memory; and (2) an interactive GUI session inherits the documented OpenShell fragility (1h non-refreshable JWT → mid-session hang; relay contention on rapid turns; idle `DeadlineExceeded`) — the exact P0 class from `doc/specs/2026-06-08-fleet-durability-hardening.md`. X is the upstream-intended, lower-blast-radius path. The only cost of X — the fleet *roles* run natively on the host rather than in the credential-isolated sandbox — is acceptable for a human-driven GUI and is mitigated by the security requirements in §7. If true sandbox isolation is later required, a Y-style backend can be added additively **only after** the upstream relay supports token refresh (today it cannot — the dealbreaker).

## 4. v1 design (the planks)

Phase **28**, **opt-in**, fail-isolated **leaf** — NOT in the core `install all` path (MemPalace-26 / Sourcegraph-27 precedent). Its failure must not regress the doctor count or any other phase.

- **(a) Install** — `brew install --cask aionui` (idempotent; skip if `brew list --cask aionui` present). The phase does NOT auto-launch the app (`open -a`).
- **(b) LiteLLM wiring** — mint a **separate, minimally-scoped** LiteLLM virtual key for AionUi (only the models AionUi needs; **never** the master key, **never** the fleet key). Provide a guided `help aionui` + tutorial checklist with the literal values to paste (Base URL `http://127.0.0.1:4000/v1`, the minted key, the model IDs). If the AionUi SQLite schema proves stable, *opportunistically* pre-seed it to shrink manual steps — but do **not** block v1 on reverse-engineering the DB.
- **(c) WebUI server** — **build `aionui-web` from source (Bun)** in the phase (user decision), run it as a **managed host background service** mirroring `bin/start-meridian.sh`: launchd job, **bind `127.0.0.1` only** (never `--remote`/`0.0.0.0`), health-gate before opening the browser, `run|install|uninstall|status|stop|restart` verbs, binaries resolved without a login shell. Browser at `http://127.0.0.1:25808`. **VERIFY-first:** if the Bun build does not run cleanly on M4, surface it honestly and fall back to desktop-app-only (do not ship a broken daemon).
- **(d) Hermes bridge (Design X, GATED)** — host `hermes-agent[acp]` (pinned version, **own `HERMES_HOME`** separate from anything the sandbox assumes), provider pointed at LiteLLM via the scoped key, **run WITHOUT `--yolo`/`--accept-hooks`**; fleet souls imported as per-profile profiles; per-role **wrapper scripts** (clean stdout — no shell-init/echo to stdout) registered as AionUi custom ACP agents. **Gated** on the §9 verification: if `hermes acp` per-profile operation, the AionUi custom-agent schema, or the host install cannot be verified, the bridge **auto-defers to Phase 28b** and v1 ships (a)(b)(c).

**Positioning (PM):** AionUi's non-redundant value is a **desktop parallel-agent Cowork workspace** (a Leader delegating to Teammates over ACP, with file/Office affordances) — *not* another model chat box (Open WebUI owns that) and *not* "a GUI for the roles" (claw3d already fronts them). The tutorial/docs lean into the agent-workspace + fleet-roles angle.

## 5. What gets built (platform contract)

**Create:**
- `installer/phases/28_aionui.sh` — opt-in, idempotent, **stamp-gated** (stamp AFTER smoke passes), sources `installer/lib/worktree.sh` before any docker/launchctl.
- `bin/start-aionui-web.sh` (+ `stop-aionui-web.sh` if needed) — Meridian-pattern managed daemon (loopback-only, secure admin password).
- `installer/doctor/checks/NN_aionui.sh` — **3-state pass-as-skip** (not installed → green advisory; installed-not-enabled → green advisory; enabled-unhealthy → red), modeled on checks 38/41/49. Health probe uses explicit `grep -q '^200$'` (avoid the `http_ok` `000000` false-healthy bug). LiteLLM sub-check gated on LiteLLM reachable.
- `installer/smoke/28.sh` — see §10.

**Edit:**
- `services.yml` — one entry, **`network: host`** (host process, not a container → doctor check 16 does not apply; no bridge-exempt label needed), with a `help:` block.
- `installer/lib/aliases.tsv` — open_url / doc entry for `127.0.0.1:25808`.
- LiteLLM virtual-key mint (scoped) — following the Phase 04f mint pattern but a distinct, minimal scope.
- `mayssam-ai-stack.sh` — start/stop/help dispatch + add Phase 28 to the opt-in order/resolution.
- `doc/TUTORIAL.md` (+ regen `TUTORIAL.html`, `--check` drift guard green) — one AionUi lesson.
- `doc/EXPLORE.html` — SERVICES array entry + the hardcoded count(s).
- Doc sweep — services 41→42, doctor count (auto-bumps, dynamic; sweep human-readable prose only), opt-in phase count. **Exact current counts verified by file-count at impl, not trusting prose.**
- `CHANGELOG.md` / `CHANGELOG.d/`.

`installer/models.yml` — untouched (AionUi consumes LiteLLM; no new models).

## 6. Service model (how AionUi maps to the stack CLI)

AionUi has two faces, exposed through one service entry:
- **Desktop app** (`AionUi.app`) — installed by the cask, **not** auto-launched by the phase; quit-when-done (LM Studio precedent). `start aionui` may `open -a AionUi` (gated), but the app is a UI tool, not a daemon.
- **WebUI server** (`aionui-web`, built from source) — the managed daemon. `start aionui` ensures it's running and opens the browser URL (health-gated, single funnel — [[project_service_run_cohesion]]); `stop aionui` tears down the daemon; doctor health-checks `:25808`; `help aionui` surfaces both faces + the LiteLLM/bridge setup checklist.

So `services.yml` has **one** `aionui` entry whose daemon/health is the WebUI server; the desktop app + the Hermes bridge are documented usage layered on top.

## 7. Security requirements (NON-NEGOTIABLE)

1. **No `--yolo` / `--accept-hooks` on the host `hermes-acp` process.** On the host there is no sandbox containment; `--yolo` would make it an autonomous agent with host shell/file access. Require the approval path; scope tools to read-only / allowlisted where possible.
2. **Scoped-minimal LiteLLM key.** Mint a key limited to the models AionUi needs. Never reuse the master or the `hermes-fleet` key. Store on our side via `set_env` (0600 `.env`); never rm the key on teardown (the never-rm-env rule). Note: AionUi necessarily stores the key in its own SQLite data dir (and `auto_updates true` means its bundle can change) — so **the minimal scope is the real blast-radius control**, and this is documented.
3. **`aionui-web` binds `127.0.0.1` only.** Never `--remote` / `AIONUI_ALLOW_REMOTE` / `0.0.0.0`. Admin password generated via `openssl rand`, persisted in `.env` 0600, **passed via env var (not a CLI flag — flags show in `ps`), never printed to stdout / logs / shell history.**
4. **stdout hygiene for ACP.** The hermes-acp launcher and any wrapper must guarantee a clean stdout (no shell-init / `brew shellenv` / `echo` to stdout corrupting the JSON-RPC stream) — e.g. clean env invocation; verify hermes-acp emits only protocol on stdout.

## 8. Resource budget (M4 / 24GB)

Affordable with guards. `aionui-web` ≈ Meridian-class resident (Node). The Electron desktop app is a UI tool → **quit-when-done** policy (like LM Studio), not auto-launched. A resident `hermes-acp` per AionUi session is spawned/killed by AionUi. Doctor emits a **RAM advisory** (not a red) if LM Studio holds a big model AND AionUi is active.

## 9. Pre-build verification gate (verify-first; each gates a plank)

Run BEFORE building the corresponding plank; any failure auto-defers that plank (and is reported honestly):

1. **aionui-web** — clone/build via Bun on M4; confirm the launch flag (`--port`?) + loopback bind + a `/` 200. *(gates c)*
2. **hermes acp per-profile** — confirm a per-role `HERMES_HOME` (or `profile use`) yields a working `hermes acp` server, and that it runs acceptably **without `--yolo`**. *(gates d)*
3. **AionUi custom-agent schema** — confirm a custom ACP agent can be registered (file vs SQLite); determines automation vs guided. *(gates d UX)*
4. **hermes-acp ↔ LiteLLM** — exact `~/.hermes/config.yaml` keys for base_url/api_key/model; host `pip/pipx install hermes-agent[acp]` + `hermes postinstall` clean on M4. *(gates d)*
5. **AionUi base-URL** — confirm the UI Custom provider accepts `http://127.0.0.1:4000/v1`. *(gates b — low risk)*

## 10. Acceptance criteria (testable) & DoD

- **AC-1:** `mayssam-ai-stack.sh install 28` is idempotent and, on success, leaves the cask installed and (if c ships) `aionui-web` healthy. Smoke `installer/smoke/28.sh` asserts: cask present (`brew list --cask aionui`); the AionUi LiteLLM virtual key exists in `/key/list`; the key performs a **real 1-token chat completion** against `http://127.0.0.1:4000/v1` (the actual AionUi→LiteLLM path); (if c) `:25808` returns `200`; `build_tutorial_html.py --check` exits 0. Stamp is written only AFTER smoke passes.
- **AC-2:** `mayssam-ai-stack.sh doctor` is green from **main** — the new `NN_aionui.sh` passes (green advisory when AionUi is absent/disabled; red only when enabled-and-unhealthy). Doctor count reflects the new check (verified by file-count).
- **AC-3:** `mayssam-ai-stack.sh help aionui` returns the what/why/usage/config; `start aionui` / `stop aionui` work as a single funnel (opens the WebUI URL gated on health).
- **AC-4 (live E2E, SOUL §5):** From a browser at `http://127.0.0.1:25808` (and/or the desktop app), add the LiteLLM Custom provider with the minted key and **get a reply from a stack model**; **and** (if the bridge ships) drive **one real turn through a Hermes fleet role over ACP** and get a coherent answer. Verified from the app, not a green log.
- **AC-5 (security):** no `--yolo` on host; the minted key is scoped-minimal and not the master/fleet key; `aionui-web` binds loopback only; admin password never printed/logged.
- **AC-6 (docs cohesion):** tutorial lesson present + `--check` green; EXPLORE.html + all count-bearing docs swept and consistent (file-count verified); CHANGELOG updated.

**DoD:** all ACs met; §24 merge-review council sign-off; merged to main + pushed + branch cleaned; durable memory residue written. The bridge (d) may ship as "deferred to 28b" if its §9 verifies fail — that is an acceptable v1 outcome (a)(b)(c) still satisfy the DoD.

## 11. Risks & mitigations

- **aionui-web source build fragile on M4** → verify-first (§9.1); fall back to desktop-only if it won't build cleanly.
- **`hermes acp` multi-role mechanism unproven** → verify-first (§9.2); auto-defer the bridge to 28b if unproven.
- **Host agent with creds = blast radius** → no `--yolo`, scoped key, own `HERMES_HOME`, documented trade-off (§7).
- **Guided (not automated) AionUi config** → `help aionui` + tutorial give literal copy-paste values; opportunistic SQLite seed only if stable.
- **Version skew (host `[acp]` vs sandbox 0.16.0)** → pin the host install explicitly; doctor asserts the host `hermes-acp` entry point + LiteLLM target.
- **Parallel-session git collisions** → all edits in this worktree; live stack operated only from main ([[feedback_worktree_breaks_live_stack]], [[feedback_always_use_worktrees]]).

## 12. Out of scope / follow-ups

- **OpenWork** — separate spec → plan → build cycle (same hybrid pattern).
- **Phase 28b** — Hermes bridge, if it auto-defers from v1; and/or a future Y-style true-sandbox backend once upstream relay supports token refresh.
- **Keychain storage** for secrets (hardening beyond 0600 `.env`).

## 13. Council record (§24)

Convened: architect (techlead), adversarial (reviewing-engineer), QA/infra (sre), PM. All read the repo to ground their views.

- **Architecture (unanimous):** Design X; **reject Y** (one-shot `-z` breaks ACP's stateful contract; interactive GUI inherits OpenShell 1h-token/relay fragility).
- **Bridge-in-v1 split:** architect + PM → include (as X); adversarial + QA → defer (X-as-specified had a `--yolo` security gap + unverified pieces). **Resolution:** include the bridge as Design X **gated** on §9 verification + §7 security; auto-defer to 28b on failure.
- **Live findings that reshaped the design:** (1) the cask ships **no `aionui-web`** → build from source (user decision); (2) **`hermes acp` has no `--profile`** → per-profile-process wrapper.
- **Security must-fixes (adversarial + QA, non-negotiable):** §7 (no `--yolo`; scoped-minimal key; loopback-only; secure admin password; stdout hygiene).
- **PM:** position as a parallel-agent Cowork *workspace*; verify from the app itself; guided-setup checklist is an acceptable v1 floor.

## 14. Open questions (resolve during §9, not blockers)

Exact `aionui-web` flags; AionUi custom-agent storage (file vs SQLite); `hermes acp` per-profile `HERMES_HOME` behavior + no-`--yolo` viability; exact `~/.hermes/config.yaml` LiteLLM keys; current exact service/doctor/opt-in counts (file-count at impl).
