# Spec: nemotron-only local models + exhaustive `upgrade all` (2026-07-01)

Two operator directives, both approved to implement. This spec captures the full blast-radius
map (from two read-only Explore audits) so execution needs no re-investigation. Branch:
`feat/nemotron-only-local` (off main). Embeddings decision: **keep** the ollama embedding models
(`nomic-embed-text`, `ordis/jina-embeddings-v2-base-code`) — nemotron is the only local *chat* model.

---

## PART A — `nemotron-3-nano:4b` is the ONLY local Ollama chat model (remove gemma4)

### Naming decision (implement this)
- Ollama chat model universe = **`nemotron-3-nano:4b` ONLY**. Keep ollama EMBEDDING models
  (`nomic-embed-text`, `jina-embeddings-v2-base-code`) — separate plane, features depend on them.
- `local` and `local-heavy` both resolve to `nemotron-3-nano:4b` (user's explicit ask).
- Canonical alias: make `local` the primary nemotron-backed alias; `local-heavy` → same.
- REMOVE the model-specific ollama aliases (`local-gemma4`, `local-qwen3`) and repoint everything.
- SUB-DECISION (recommend: remove): the LM Studio (MLX, opt-in, default-down) aliases
  `local-nemotron3-nano-4b-mlx`, `local-gemma4-12b`, `local-nemotron3-heavy`,
  `local-qwen-heavy-fast`. User said "remove all other local models" → recommend removing all
  non-nemotron LM Studio chat rows too (keep LM Studio wiring itself for future opt-in).
- `default:` → the nemotron alias.

### CRITICAL correctness warnings (from the audit)
1. **Two naming systems diverge.** `litellm/config.yaml` has NO rows for `local`, `local-heavy`,
   `local-lfm2`, `local-qwen3.6`, `local-qwen3-coder` — yet docs, `LEGACY_SUPERSET`, DeerFlow
   render, and ~15 scoped-key mints reference them. A superset entry with no config row is a silent
   403, not an error. To make "every local-* alias resolves to nemotron," each must get a real
   nemotron-backed config row OR be deleted from superset+docs. DECIDE PER ALIAS.
2. `installer/lib/common.sh:231` (`want="local-gemma4"`) and `installer/lib/models.sh:55,501,512`
   HARDCODE the alias — they do NOT follow a `default:` edit. Must change explicitly or doctor
   checks 57–61 + `preflight_superset_in_config` break.
3. Embeddings are a separate plane — only swap the `gemma4:e4b` CHAT entry to `nemotron-3-nano:4b`;
   KEEP `nomic-embed-text` (01_inference + check 08) and `jina` (phase 16 + check 27) pulls.
4. `installer/lib/models.sh:94-133` seed template + `01_inference.sh:166-167` fallback are the
   partial-checkout paths — update them too or a fresh/partial install re-declares gemma4.

### LOAD-BEARING code edits (must be atomic — partial = broken routing/keys)
- `installer/models.yml`: repoint `local-gemma4`(16-20)→ `local` served `nemotron-3-nano:4b`; add
  `local-heavy`→ nemotron; `default:`(123)→ the nemotron alias; remove `local-qwen3`(21-25) +
  the LM Studio gemma/qwen/heavy rows (36-50) per sub-decision; keep embeddings block (88-112).
- `litellm/config.yaml`: `local`/`local-heavy` rows → `ollama_chat/nemotron-3-nano:4b`; remove
  `local-gemma4`(13-16), `local-qwen3`(17-20), `local-gemma4-12b`(365-369), heavy rows
  (370-379) per sub-decision; keep `local-nemotron3-nano-4b`(356-359) as the base ollama route;
  keep embed routes (164-181). Clean dead gemma4 comments (42,211-213,287-301,352-355,399-401).
- `installer/lib/common.sh:231` — `want` default → `local` (nemotron) or read `.default`.
- `installer/lib/models.sh:55` (`LEGACY_SUPERSET`), `66` (`superset_members`), `94-133` (seed
  template), `501,512` (`preflight_superset_in_config`), `694,703,710,806,1126,1279` (DeerFlow
  two-tier + `model add` reserved names) → nemotron aliases.
- `installer/phases/01_inference.sh:33-36` `REQUIRED_MODELS=( gemma4:e4b nomic-embed-text )` →
  `( nemotron-3-nano:4b nomic-embed-text )`; `:166-167` fallback register → nemotron.
- `installer/doctor/checks/08_ollama_models.sh:11-14` `_OLLAMA_REQUIRED` → `( nemotron-3-nano:4b
  nomic-embed-text )`; CHECK_TITLE(9) + comments(3-4). Update `doctor.sh:92` comment.
  `installer/tests/test_doctor_noninteractive_guard.sh:4,29` mention `ollama pull gemma4:e4b` in
  strings — update to nemotron.
- `installer/doctor/checks/40_models_binding.sh` — follows config; will now require
  `nemotron-3-nano:4b` pulled (correct) and flag removed aliases (expected).
- Scoped-key mints (superset lists include `local-gemma4`): `04f`(433,448), `15_pi`(112,116),
  `17_ace`(129,133), `18_rlm`(87,90), `11_halo`(70,73), `28_aionui`(42), `29_openwork`(45),
  `32_metagpt`(126), `33_agentscope`(153), `34_oasis`(112), `35_chatdev`(180), `36_aitown`(256),
  `37_concordia`(149), `26_mempalace`(163) + `04h_agent_fleet`(169,172) +
  `26_pi_litellm_key_allowlist.sh`(7,9,26,33,42). Repoint superset to the new alias set.
- Bound-model fallback args (literal `local-gemma4`): `26_mempalace`(201), `32`(146), `33`(173),
  `34`(132), `35`(201), `36`(279), `37`(167), `04f`(504).
- Smoke: `28.sh`(42), `29.sh`(50), `32.sh`(38), `35.sh`(68), `36.sh`(36),
  `models-fallback.sh`(15 refs), `models-console.sh`(6 refs), `config_validate.sh`(35-58 fixtures).
- `bin/audit.sh:55` + `installer/phases/04g_security.sh:114` (injection-test POST — model must
  EXIST in live config). `installer/lib/models-serve.sh:40`, `tutorial-serve.sh:38-39`,
  `tutorial_proxy.py:49`, `bin/pi:62`, `bin/start-lmstudio.sh:81`, `installer/lib/lmstudio.sh`
  (291,355-356), `installer/lib/fleet.sh`(18,183,533,562), `deps.sh:250`.

### DOC sweep (not routing-breaking; do after code): EXPLORE.html, TUTORIAL.md+html (picker
`<option>` + `DEFAULT_MODEL`), COMPONENTS.md, models.md, OPERATIONS.md, ARCHITECTURE.md,
DIAGRAMS.md+html, DOCTOR.md, USER-GUIDE.md+html (JS picker default 1238), AGENT-ONBOARDING.md,
CLAUDE-CODE-MODELS.md, INSTALL.md, HERMES-HANDSON.md, GPT5.md, TROUBLESHOOTING.md, ONBOARDING.md,
STACK-GUIDE.md, DEPENDENCIES.md, ALTERNATIVES.md, HANDOFF.md, ATTRIBUTION.md (Gemma license —
decide keep/remove), setting-up-gpt-login.txt. TUTORIAL/DIAGRAMS/USER-GUIDE HTML are GENERATED —
edit the .md + regen (build_tutorial_html.py, build_diagrams_html.py). Bump any local-model counts.

### Verify: `bash installer/smoke/config_validate.sh`; `model sync`; a real route test
`curl litellm:4000 -d '{"model":"local",...}'` → 200 via nemotron; doctor 08/40 green; full
offline suite; check no `gemma4` remains in code (`grep -rn gemma4 installer/ litellm/ bin/`).

---

## PART B — make `upgrade all` EXHAUSTIVE (nothing left manual)

### Current gap (confirmed by audit of installer/lib/upgrade.sh)
- `--all`/`-a` is INERT except `--check` verbosity; `upgrade --all` alone errors. The real verb is
  bare `upgrade all`. `--outdated` only ever acts on unpinned docker + brew(ollama).
- `upgrade all` truly upgrades only: docker(`up_docker`), compose(`up_compose`),
  brew(`up_brew`, ollama only), openshell/sandbox(`up_openshell`, by name).
- ~30 services typed `cli-only/npm-global/pip-package/clone-only/python-bg/node-bg/agent-pattern/
  litellm-*/paperclip-plugin` hit `up_manual_note` (upgrade.sh:622-632) = **no-op note**.
- Meridian/Codex/Claude-Code are NOT services → not modeled at all.

### Design (implement)
1. Add a structured `upgrade:` block per service in services.yml, e.g.
   `upgrade: {method: npm-global|pip-venv|git-pull|uv-tool|rebuild|phase-rerun, target: <pkg|dir|venv>, restart: <svc?>}`.
   The install method is currently prose-only (`help.config_notes`) — this makes it machine-driven.
2. New `upgrade.sh` handlers keyed on `upgrade.method`:
   - `npm-global` → `npm i -g <pkg>@latest` (byterover_cli; + Meridian `@rynfar/meridian`, Codex,
     Claude-Code as pseudo-services or a dedicated `host-npm-globals` upgrade target).
   - `pip-venv` → `<venv>/bin/pip install -U <pkg>` (remnic_hermes, metagpt/agentscope/oasis/
     concordia uv/pip venvs) + restart the daemon if any.
   - `git-pull` → `git -C <dir> pull --ff-only` (autoreason clone-only; sourcegraph-style clones).
   - `uv-tool` → `uv tool upgrade <name>` (uv tool installs).
   - `rebuild` → re-run `bin/start-<svc>.sh --recreate`/build (derived images, bg daemons).
   - `phase-rerun` (fallback) → re-run `install <phase>` with a new `AI_STACK_UPGRADE=1` that
     phases honor to force-latest (git pull / pip -U / npm @latest) instead of install-if-absent.
3. Wire these into BOTH the `upgrade all` loop AND `--outdated` (so `check_one` can report
   `update-available` for npm/pip/git by comparing installed vs latest where cheap).
4. Model Meridian/Codex/Claude-Code (npm globals not in services.yml) in the upgrade universe.
5. Keep pinned-docker prompt + `AI_STACK_ASSUME_YES=1`; keep worktree guard.

### Acceptance
- After `upgrade all`, NOTHING typed npm/pip/git/uv/bg remains at "manual note" — each is actually
  upgraded (or explicitly reports up-to-date). `--check --all` shows no `manual` rows that mutate.
- Meridian/Codex/Claude-Code upgradeable via the command.
- Tests: an offline test that every enabled service resolves to a real `upgrade.method` (no
  service silently falls through to a no-op), + per-mechanism dry-run assertions.

---

## Execution order
1. PART A code (atomic) → verify (config_validate + route test + doctor 08/40 + offline suite).
2. PART A doc sweep + regen HTML.
3. PART B (services.yml `upgrade:` annotations + handlers + tests).
4. §24 review (adversarial + architect + qa) of both.
5. `model sync` if needed; sync GitHub (push, branch cleanup); worktree tidy.

NOTE: neither part touches the corporate-CA / resilience work already on main. Do NOT pull local
models during any of this (no-local-model policy) — nemotron-3-nano:4b + the embedders are the
only ollama models; the operator pulls nemotron once manually if absent.
