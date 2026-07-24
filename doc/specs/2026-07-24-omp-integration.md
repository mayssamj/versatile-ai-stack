# omp (oh-my-pi) Integration — Phase 42 (v1)

- **Date:** 2026-07-24
- **Status:** council-reviewed plan (§24 two-round, 4-lens, APPROVE_WITH_CHANGES — all changes
  folded in below); operator-approved scope 2026-07-24. Implemented in worktree
  `feat/omp-phase42`; merge-review + live install from MAIN follow.
- **Owner:** manager (orchestrator). Companion intake research + council record: session
  scratchpad + memory `project-openworker-omp-intake`.
- **Scope:** omp ONLY. The companion OpenWorker feature was **deferred by the operator**
  (option C — 4-day-old upstream, redundant against openwork/aionui once hardened; revisit
  when it matures). Precedents followed: Phase 29 (openwork, opt-in leaf + scoped key),
  Phase 37 (concordia, host tool + wrapper + registry row).

## 1. Problem & goal

Add first-class, opt-in ai-stack support for **omp / oh-my-pi** (`can1357/oh-my-pi`, MIT,
19.6k★, v17.1.2) — a terminal AI coding agent that is a **hard fork of badlogic/pi-mono**,
the same upstream as the stack's sandboxed phase-15 `pi`. Operator requirements: usable with
**local Ollama AND cloud models** (satisfied via LiteLLM — single-hub rule, Ollama through the
`local` route); **no role defaults to `local`** (default = `claude-opus-sub-xhigh`); host-run
alongside phase-15 pi (which is untouched); prebuilt binary accepted **SHA256-pinned**.

## 2. Verified facts the design rests on (sources: repo clone @ v17.1.2 + release API)

- Binary: `omp-darwin-arm64` release asset, 125,501,568 bytes,
  sha256 `3b0fd8c1a22066cae07d853ba2676737cd86bf3c7beb9c86dd406359edf079d7` (GitHub release
  digest AND an independent download hash — two-source verified; runs on this M4: `omp/17.1.2`).
- Config universe is omp's own `~/.omp` (never reads `~/.pi`; inherits `.claude` at prio 80).
  `OMP_PROFILE=<name>` relocates ALL state to `~/.omp/profiles/<name>/agent/` — full isolation
  from any personal `~/.omp`, rollback = `rm -rf` that dir (docs/config-usage.md).
- `models.yml`: LiteLLM is a first-class provider (`baseUrl`, `apiKey: <ENV-NAME>`,
  `api: openai-completions`, `discovery: {type: litellm}`; scoped keys that 403 the metadata
  routes fall back to plain `GET /models` — documented). Implicit zero-config discovery of
  direct ollama/:1234/:8080 exists and must be disabled (`disabledProviders`).
- `config.yml`: `modelRoles` (default/smol/plan/…), `tools.approvalMode` — **shipped default
  is `yolo` (auto-approves exec)**; `startup.checkUpdate` default true (npm phone-home);
  `dev.autoqa` grievance push consent-gated. Project-local `<repo>/.omp/config.yml`
  deep-merges OVER the global/profile config. CORRECTED at merge-review (the plan-council's
  weaker statement was wrong): a project config that flips `approvalMode: yolo` silently
  auto-approves EVERYTHING — in yolo even omp's critical-destructive-pattern guard does NOT
  prompt (upstream docs/approval-mode.md:42,55). Mitigation: the profile pins an explicit
  `tools.approval.bash: prompt` policy, which yolo honors, so bash still prompts under a
  yolo flip unless the repo config overrides that key too. **Accepted operator risk,
  trusted-repos-only**, surfaced as a doctor advisory (council C2; operator Q4 "default
  ok" — re-flagged to the operator in the ship report since the risk statement changed).

## 3. Design (council-amended)

Host CLI, **opt-in leaf Phase 42** (NOT in `install_all_phase_order()`), type `cli-only`,
`network: none`, **no port, no aliases.tsv row, no open_url** (council C6). Phase-15 pi is
untouched (divergent fork, separate config universes — clean coexistence).

- **(a) Binary install:** fetch the pinned release asset to `$AI_STACK/omp/` (gitignored),
  **SHA256-verified fail-closed** (council C7 — verify, not log), `--version` asserted.
  NO `curl | sh`, NO `bun -g` (no-global-pollution). `OMP_VERSION`/`OMP_SHA256` env overrides
  (both or neither).
- **(b) LiteLLM wiring:** mint model-scoped `OMP_LITELLM_KEY` (never master/fleet), allowlist
  `["claude-opus-sub-xhigh","claude-opus-sub-high","claude-sonnet-sub-high","local"]`
  (`local` allowlisted for explicit selection — registry invariant b0 requires it — but NO
  role defaults to it, per operator). Key registered in `scoped_key_registry()`
  (**registry-only — deliberately NOT models.yml `kinds`**, council C3: a kinds entry has no
  renderer case-arm and would put the key under two conflicting reconcilers). Registry
  regression test extended 7→8 (council C4).
- **(c) Profile config render (idempotent, content-compared):**
  `~/.omp/profiles/ai-stack/agent/models.yml` → single `litellm` provider, key via env-NAME
  indirection (literal key never on disk outside `.env` 0600);
  `.../config.yml` → `modelRoles: {default: litellm/claude-opus-sub-xhigh, smol:
  litellm/claude-sonnet-sub-high, plan: litellm/claude-opus-sub-xhigh}`,
  `disabledProviders: [ollama, lm-studio, llama.cpp]` (single hub — direct-local discovery
  killed), `tools.approvalMode: write` (yolo killed), `startup.checkUpdate: false`,
  `dev.autoqa: false`.
- **(d) `bin/omp` wrapper** (gitignored, regenerated by the phase): exports
  `OMP_PROFILE=ai-stack` + `OMP_LITELLM_KEY` (read from `.env` at runtime) and execs the
  pinned binary.

## 4. Acceptance criteria

- **AC-1** `install 42` idempotent; on success: verified binary + wrapper + rendered profile
  configs + valid scoped key; in-phase gate (binary/config/key + a bounded 1-token completion
  on `claude-sonnet-sub-high` — SUB route, never `local`, council C5) passes BEFORE
  `stamp_mark`. Skipped under `AI_STACK_UPGRADE=1` (metered), like Phase 37.
- **AC-2** `doctor` green from MAIN; new check `84_omp.sh` is 3-state pass-as-skip,
  wiring-only (no inference, no local model load), asserts the hardening posture
  (approvalMode/disabledProviders/checkUpdate) and the key allowlist; count 84→85.
- **AC-3** `test 42` proves the REAL path: `bin/omp -p` returns a sentinel reply through
  LiteLLM on the stack profile (bounded by perl-alarm; macOS has no `timeout`).
- **AC-4** Live E2E from MAIN after merge: `bin/omp -p` answers via LiteLLM; visible in
  Phoenix; `help omp` renders; full doctor 85/85.
- **AC-5** Security: scoped-minimal key; yolo disabled; single-hub enforced
  (disabledProviders); no phone-home (checkUpdate/autoqa off); binary SHA-pinned fail-closed;
  trusted-repos boundary surfaced in doctor + help.
- **AC-6** Doc sweep in the SAME change (counts 53→54 services / 84→85 checks / 20→21 opt-in):
  README (all spots incl. badges), doc/COMPONENTS.md (:9 counts + :81 pass-as-skip roster),
  doc/AGENT-ONBOARDING.md counts, EXPLORE.html card + subtitle, TUTORIAL.md + regen + --check,
  PORTS.md, ATTRIBUTION.md, DEPENDENCIES.md opt-in node, `cmd_help` opt-in heredoc,
  CHANGELOG. Registry test + comment 7→8.

## 5. Risks & mitigations

- **Upstream churn** (17 majors/7 months): hard pin + sha; `upgrade:` block is metadata-only
  (pin + bump recipe) — honest, no fake auto-upgrade.
- **Scoped key vs discovery metadata routes:** documented fallback to `GET /models`; if the
  live E2E shows models missing, switch the rendered `models.yml` to an explicit `models:`
  list generated from the allowlist (the proven phase-15 pattern) — recorded as the fallback.
- **Project-local config escalation:** accepted (trusted repos only) + doctor advisory +
  the explicit `tools.approval.bash: prompt` backstop (survives a yolo flip unless that key
  is also overridden; the critical-command guard alone does NOT prompt in yolo).
- **125 MB binary in repo dir:** `$AI_STACK/omp/` + `bin/omp` gitignored (mirrors
  `/concordia/` + `/bin/concordia`).

## 6. Out of scope / follow-ups

Stats dashboard (:3847), /collab relay, extensions/marketplace, ACP editor wiring, MCP
bridging into omp (candidate Phase 42b: hand omp the stack's MCP servers via `mcp.json`),
`local` removal from the allowlist (operator may narrow later; registry invariant requires a
test change too).
