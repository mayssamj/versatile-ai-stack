# Docker-Engine Selection — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Make Docker-engine choice (OrbStack | Docker Desktop | Colima | Podman) explicit and intentional at install time, derive one `DOCKER_HOST` for the *entire* stack (main containers AND the OpenShell gateway) from a single `.env` key `AI_STACK_DOCKER_ENGINE`, and add doctor checks that detect/fix engine mismatch, split-brain, and missing selection — never auto-destroying data.

**Architecture:** A new data-driven registry module `installer/lib/docker-engine.sh` is the single source of truth for per-engine probes/sockets/add-host flags and the selection/pin/ensure functions. The selected engine is persisted to `.env`, exported as `DOCKER_HOST` centrally (right after `env.sh` loads) AND re-exported at `docker.sh` source-time (so standalone `bin/start-*.sh` runs inherit it without process-inheritance), and written into `~/.config/openshell/gateway.env`. The OpenShell durability bin scripts (checkpoint/watchdog/state-restore/token-refresh) are made engine-aware so they never operate on a different engine than the gateway. Wiring changes touch `common.sh`, `env.sh`/`docker.sh` (source-time export), `deps.sh`, `docker.sh`, `00_host.sh` preflight, `04_openshell.sh`, the openshell-* bin scripts, `mayssam-ai-stack.sh` (global `--engine` plumbing + new `docker-engine` subcommand). Doctor gains checks **47/48** and expands 01 + makes 02 engine-aware.

> **DOCTOR-COUNT BASELINE (re-baselined, see Task 0):** the live tree ALREADY has **46** check files (`ls installer/doctor/checks/*.sh | wc -l == 46`; highest is `46_agent_fleet_parity.sh`, added after the spec/memory were written — README already reads `doctor-46%2F46` / "46 checks"; `project_doctor_count.md` still says 45 and is STALE). The two new checks are therefore **`47_docker_engine_consistency.sh`** and **`48_docker_engine_selection.sh`** (NOT 46/47 — 46 is taken). Final count = **48**. Every count edit below is **46→48** (badge `46%2F46`→`48%2F48`). Task 0 re-derives the count from the live tree before any file is created.

> **⚠️ AS-BUILT RECONCILIATION:** As built on the post-fleet-parity main: ordinals **47/48**, count **48** — matching this plan's original numbering (the earlier 45-baseline 46/47 was reconciled to 47/48 when fleet-parity's check 46 merged to main first).

**Tech Stack:** Bash (`set -Eeuo pipefail`, `shopt -s inherit_errexit`), the `env.sh` atomic `.env` helpers (`get_env`/`set_env`/`require_env`), the doctor check-file contract (`CHECKS+=`/`CHECK_TITLE[]`/`<name>_diagnose`/`<name>_fix`), plain-bash smoke tests in `installer/smoke/`, macOS Apple-Silicon `docker`/`docker context`/`brew`/`colima`/`podman machine` CLIs. No new test framework.

**Follow-up to:** `doc/specs/2026-06-17-docker-engine-selection.md` (approved design — source of truth for WHAT to build; record this plan as its implementation follow-up).

---

## Naming contract (consistent across ALL tasks)

| name | meaning |
|---|---|
| `AI_STACK_DOCKER_ENGINE` | `.env` key; value space = `orbstack` \| `docker-desktop` \| `colima` \| `podman` (logical id, NOT a raw URL — see open question Q1, resolved: logical id). |
| `ENGINE_IDS` | space-list of the 4 valid ids, in priority order `orbstack docker-desktop colima podman`. |
| `engine_display <id>` | human label (e.g. `OrbStack`). |
| `engine_installed <id>` | exit 0 if app/binary present. |
| `engine_detect_installed` | echo ids whose app/binary is present, one per line. |
| `engine_running <id>` | exit 0 if that engine's daemon answers `docker -H <socket> info` (timeout-bounded). |
| `engine_detect_running` | echo running ids, one per line. |
| `engine_socket <id>` | echo the resolved `DOCKER_HOST` value (`unix://…`); empty + return 1 if unresolvable. |
| `engine_addhost_args <id>` | echo `--add-host=host.docker.internal:host-gateway` for colima/podman, nothing for orbstack/docker-desktop. |
| `engine_start <id>` | start that engine's daemon (`open -a …` / `colima start` / `podman machine …`). |
| `engine_install <id>` | `brew install …` for that engine (+ `docker` CLI formula for colima/podman). |
| `engine_select` | resolve id by precedence: `--engine <id>` env-var `AI_STACK_ENGINE_FLAG` → `AI_STACK_DOCKER_ENGINE` (.env) → single running → prompt → NO_PROMPT priority. Echoes id to stdout; logs reason to stderr. |
| `engine_ensure <id>` | install-if-missing (consent/NO_PROMPT) + start + bounded-wait on that socket. |
| `engine_pin <id>` | `set_env AI_STACK_DOCKER_ENGINE`, `export DOCKER_HOST=$(engine_socket id)`, rewrite gateway.env, offer `docker context use`. |
| check files | `47_docker_engine_consistency.sh`, `48_docker_engine_selection.sh` (check names `docker_engine_consistency`, `docker_engine_selection`). 46 is the EXISTING `46_agent_fleet_parity.sh` — do NOT collide with it. |
| `engine_write_gateway_env <id> [gw_file]` | the single gateway.env author (heredoc + idempotent grep-guard + chmod 600); returns 0 if changed, 1 if unchanged. Called by BOTH `engine_pin` and Phase 04 — no duplicated writer. |
| `AI_STACK_ENGINE_FLAG` | env var the CLI arg-parser sets from a global `--engine <id>` argv. The ONLY translation site is the top-level parser in `mayssam-ai-stack.sh` (Task 11a), so `install`/`deps`/phase-04 all honor `--engine` through the single `engine_select` path. |

---

## File Structure

| File | Create/Modify | Single responsibility |
|---|---|---|
| `installer/lib/docker-engine.sh` | **Create** | Engine registry table + all `engine_*` functions (the single source of truth). |
| `installer/smoke/engine.sh` | **Create** | Unit tests for the registry: socket-format, addhost gating, `engine_select` precedence (incl the running-singleton rung via a stub), NO_PROMPT priority, unknown-id rejection, failure paths, the openshell-bin engine-awareness, and the start-script add-host. Run with `bash installer/smoke/engine.sh` (matches `00n.sh`/`01.sh` idiom). NOTE: do NOT use `mayssam-ai-stack.sh test engine` — `cmd_test` only resolves PHASE names; there is no `engine` phase. |
| `installer/lib/common.sh` | **Modify** (line 58) | Fix `ENV_FILE` to honor an override (`${ENV_FILE:-…}`) so throwaway-ENV_FILE tests work and never touch the real `.env`. |
| `installer/lib/env.sh` OR `installer/lib/docker.sh` | **Modify** (source-time export block) | Re-export `DOCKER_HOST` from `AI_STACK_DOCKER_ENGINE` at `docker.sh` source-time so standalone `bin/start-*.sh` (which source `docker.sh` but NOT `mayssam-ai-stack.sh`) inherit the right socket without relying on process-inheritance. (Task 8b.) |
| `mayssam-ai-stack.sh` | **Modify** (101→add export; 105 global `--engine` arg-parse → `AI_STACK_ENGINE_FLAG`; 246-248 allowlist; 581-583 handler; 1037-1040 dispatch; 170-183 usage heredoc) | Source `docker-engine.sh` + central `DOCKER_HOST` export after `env.sh`; translate a global `--engine <id>` argv into `AI_STACK_ENGINE_FLAG`; register `docker-engine` subcommand; usage prose. |
| `installer/lib/deps.sh` | **Modify** (162-177) | `ensure_orbstack` becomes a thin alias over `engine_ensure "$(engine_select)"`; `deps_report` prints selected engine + socket triple-equality (with a UNIQUE sentinel label so the test is non-tautological). |
| `installer/lib/docker.sh` | **Modify** (source-time DOCKER_HOST export; 92-102 `docker_run_managed`; 177-185 `probe_host_docker_internal`) | Append `engine_addhost_args` for the selected engine; export `DOCKER_HOST` at source-time (Task 8b). |
| `installer/phases/00_host.sh` | **Modify** (preflight) | Run `engine_select`+`engine_pin` BEFORE any docker use / before Phase 04, so `AI_STACK_DOCKER_ENGINE` is always set by the time any container or gateway is touched (spec Wiring: "run selection before any docker use"). (Task 8c.) |
| `installer/phases/04_openshell.sh` | **Modify** (220-244 socket derivation + 250-271 restart branch) | REQUIRE selection already happened (read-only error if unset) instead of a hidden global pin; replace OrbStack hardcode with `engine_socket "$selected"` via `engine_write_gateway_env`; checkpoint every Ready sandbox + identity-backup, then restart gateway when the gateway.env `DOCKER_HOST` actually changed (split-brain guarded with the CANONICAL `_others` helper). |
| `bin/openshell-checkpoint.sh`, `bin/openshell-state-restore.sh`, `bin/openshell-watchdog.sh`, `bin/openshell-token-refresh.sh` | **Modify** (the `DOCKER=$(_find …)` block + watchdog plist PATH) | Make engine-aware: source `docker-engine.sh` (guarded) + `export DOCKER_HOST` from `AI_STACK_DOCKER_ENGINE` (or read `gateway.env`'s `DOCKER_HOST`) before invoking docker, and derive the watchdog plist PATH/`_find` candidates from the selected engine — so the highest-stakes data-loss path never operates on the wrong engine on a non-OrbStack box. (Task 12b.) |
| `installer/doctor/checks/01_orbstack_running.sh` | **Modify** | Probe the *selected* engine's socket, not just any `docker info`. (TDD'd in Task 13.) |
| `installer/doctor/checks/02_host_docker_internal.sh` | **Modify** | Engine-aware probe: add `engine_addhost_args` on colima/podman. (TDD'd in Task 13.) |
| `installer/doctor/checks/47_docker_engine_consistency.sh` | **Create** | Detect engine mismatch / split-brain (compares the AMBIENT/global context, not the doctor-exported `DOCKER_HOST`; enumerates OTHER engines for stranded managed containers); fix = re-pin (never auto-destroy). |
| `installer/doctor/checks/48_docker_engine_selection.sh` | **Create** | Assert `AI_STACK_DOCKER_ENGINE` set + still installed; fix = `engine_select`+`engine_pin`. |
| docs: `README.md`, `doc/PREREQUISITES.md`, `doc/DOCTOR.md`, `doc/ARCHITECTURE.md`, `doc/TUTORIAL.md` (+ regen `.html`), `doc/ONBOARDING.md`, `doc/INSTALL.md`, `doc/HANDOFF.md`, `doc/EXPLORE.html`, `.env.example`, `services.yml`, memory files | **Modify** | Cohesion sweep: doctor count **46→48**, engine naming, new subcommand. Reconcile the STALE `project_doctor_count.md` (says 45) → 48 and preserve the `46=agent_fleet_parity` entry alongside the new 47/48. |

---

## Resolved design decisions (from recon open_questions)

- **Q1 (value space):** `AI_STACK_DOCKER_ENGINE` stores a **logical id** (`orbstack`/…), NOT a raw URL. `engine_socket <id>` maps id→`unix://…` at export/write time. Rationale: ids are stable, sockets are user/version-specific and must be probed.
- **Q2 (common.sh:58 clobber):** Fix `common.sh:58` to `ENV_FILE="${ENV_FILE:-$AI_STACK/.env}"` (Task 2). This is load-bearing: it makes the throwaway-ENV_FILE test pattern (MEMORY: never mutate the real `.env`) actually work, and lets `--engine`/pin honor a custom env file.
- **Q3 (central export site):** Add the `DOCKER_HOST` export in `mayssam-ai-stack.sh` immediately **after** `source "$LIB/env.sh"` (line 101) and after sourcing `docker-engine.sh` — because `engine_socket` needs `get_env` (env.sh) and the registry. This is the one path every *subcommand* runs. **BUT** `mayssam-ai-stack.sh` is NOT in the process chain for the documented standalone path `bash bin/start-litellm.sh --recreate` (recreate_guard's own remediation, phase 01) — those scripts source `common.sh`/`env.sh`/`docker.sh` but never `mayssam-ai-stack.sh`, so process-inheritance does NOT reach them. Therefore the export is ALSO emitted at **`docker.sh` source-time** (Task 8b) so every `start-*.sh` that sources `docker.sh` inherits the selected socket unconditionally. (INFRA-critical finding.)
- **Q4 (default seed):** Do **NOT** seed a default into `env_ensure_baseline`/`_DEFAULTS`. Keep `.env` clean for local-only users; the engine is materialized only when selection runs (`engine_pin`). The central export is a no-op when the key is empty. To stop the no-op from masking split-brain, the Phase-00 preflight (Task 8c) runs selection+pin BEFORE any docker use, so by the time a container/gateway is touched the engine is always pinned; doctor check 01's legacy ambient fallback then becomes a hard **warn** ("no engine pinned — split-brain risk"), not a silent green.
- **Selection-before-use ordering (Q3/Q4 corollary):** the spec Wiring section requires "run selection before any docker use." A new **Task 8c** installs that hook in `installer/phases/00_host.sh` (preflight). Phase 04 is then **read-only** about selection (Task 12): it ERRORS with "run `mayssam-ai-stack.sh docker-engine select` first" if `AI_STACK_DOCKER_ENGINE` is unset rather than performing a hidden global pin deep inside one phase.
- **Global `--engine` plumbing:** `--engine <id>` is the top-precedence input per spec. The ONLY argv→`AI_STACK_ENGINE_FLAG` translation site is the top-level arg parser in `mayssam-ai-stack.sh` (Task 11a), so `install`/`deps`/phase-04 all honor `--engine` via the single `engine_select` path. `docker-engine set <id>` is the explicit-bypass alias (still goes through `engine_pin`'s validation); everything else flows flag→env→running→prompt→priority.
- **gateway.env author (single writer):** the gateway.env heredoc + idempotent grep-guard + chmod 600 is extracted into ONE helper `engine_write_gateway_env <id> [gw_file]` in `docker-engine.sh` (Task 7), called by BOTH `engine_pin` and Phase 04 (Task 12) — no byte-for-byte duplication to drift. It returns 0-if-changed / 1-if-unchanged so Phase 04 can gate its restart.
- **gateway.env throwaway override:** `engine_write_gateway_env` (and therefore `engine_pin` and Phase 04) honor `ENGINE_GATEWAY_ENV_FILE`. Phase 04 sets `GATEWAY_ENV_FILE` from a single overridable var that the helper also reads, so a test injecting `ENGINE_GATEWAY_ENV_FILE=$(mktemp)` NEVER clobbers the real `~/.config/openshell/gateway.env`. The MEMORY "never touch real config" rule is extended from `.env` to `gateway.env`.
- **Split-brain (04 restart):** Phase 04 hard-blocks the `DOCKER_HOST` change when other sandboxes are `Ready` unless `OPENSHELL_FORCE_GATEWAY_RESTART=1`, reusing the **CANONICAL `lib/openshell.sh` `_others` guard** (sourced — NOT re-implemented with a weaker awk) which strips ANSI (`_osh_strip_ansi`) and self-excludes (`$1!=n`). Before the restart it **checkpoints every Ready sandbox** (`bin/openshell-checkpoint.sh`, fail-closed) in addition to the identity-backup, mirroring the fleet-durability HALT-by-default contract. Default is NOT to restart inline during an install run — surface a doctor warning that a restart is pending.
- **engine_* return code under `inherit_errexit`:** the registry functions return **1** (not 2) for caller-recoverable conditions, because under `set -Eeuo pipefail; shopt -s inherit_errexit` a bare `x=$(engine_*)` assignment that returns non-zero ABORTS the whole script (it is not a conditional context). A grep-lint in the smoke test fails on any bare `=$(engine_` assignment, and every one of the wiring call sites is guarded `|| { … }`.

---

## Residual open questions (called out — NOT papered over)

- **Podman socket field** (`{{.ConnectionInfo.PodmanSocket.Path}}`): documented for podman 5.x but NOT runtime-verified (no machine on the box). `engine_socket podman` therefore wraps the field read in a fallback chain and `log`s "assumed (unverified on this host)". Confirm against a live `podman machine` before relying on rootful vs rootless path.
- **Colima socket path / host.docker.internal threshold:** `$HOME/.colima/<profile>/docker.sock` and the colima `host.docker.internal` wiring version threshold are documented, not verified (Colima not installed). We emit the `--add-host` flag as the portable safe default and `log` it as assumed.
- **Docker Desktop socket:** `$HOME/.docker/run/docker.sock` (per-user) vs `/var/run/docker.sock` depends on the "default socket" setting/version; `engine_socket docker-desktop` prefers the `desktop-linux` context endpoint, then probes both paths.
- **brew cask name churn:** Docker Desktop cask was `docker`, renamed `docker-desktop`. `engine_install docker-desktop` RESOLVES the cask token (`brew info --cask docker-desktop` → else `docker`) **before** printing the consent prompt (so the user approves the exact command that runs — INFRA minor), and falls back to `docker`. The cask-churn fallback itself is interactive-only and stays untested (requires brew network); noted, not papered over.
- **`docker context` switch vs exported `DOCKER_HOST` (reversibility):** _**Superseded 2026-06-21** — the consented prompt below was replaced by a non-interactive persisted preference `AI_STACK_DOCKER_CONTEXT` (default `switch`); `engine_pin` no longer prompts. See [`2026-06-21-docker-context-policy.md`](2026-06-21-docker-context-policy.md)._ `engine_pin`'s consented `docker context use ai-stack-<id>` switches the user's GLOBAL context — invasive, affects every other shell/tool. Because `DOCKER_HOST` (exported by Task 8) OVERRIDES `docker context`, the context switch is effectively cosmetic inside ai-stack processes while still changing the user's ambient world. `engine_pin` therefore RECORDS the prior context (`docker context show`) before switching and prints the exact undo (`docker context use <prior>`); the rollback recipe is documented in Task 7 + the new Task 17 rollback section. Doctor 47 compares the AMBIENT context (not the doctor-exported `DOCKER_HOST`) so the check measures the real-world state other shells see.

---

# Tasks

> **Worktree first.** Before Task 1, create the feature branch + worktree (superpowers:using-git-worktrees). Branch: `feat/docker-engine-selection`. ALL `.env`-touching tests run with a throwaway `ENV_FILE` (Task 1+), NEVER the real `~/ai-stack/.env`.

```bash
git -C /Users/mayssam.sayyadian/ai-stack worktree add -b feat/docker-engine-selection /Users/mayssam.sayyadian/ai-stack-wt/docker-engine main
# cd target for all subsequent commands:
cd /Users/mayssam.sayyadian/ai-stack-wt/docker-engine
```

---

## Task 0 — Preflight: re-derive the LIVE doctor-check baseline from the tree (do NOT trust the stale 45)

**Files:** none (recon gate). Establishes the real numbering BEFORE any check file is created, so the new files never collide with the existing `46_agent_fleet_parity.sh`.

**Steps:**

- [ ] Derive the live count from disk (NOT from the spec/memory — both say 45 and are stale; the code is the source of truth):
  ```bash
  ls installer/doctor/checks/*.sh | wc -l          # EXPECT 46 (highest is 46_agent_fleet_parity.sh)
  ls installer/doctor/checks/*.sh | sort | tail -3  # confirm 44/45/46 names; 46_agent_fleet_parity.sh present
  grep -rc 'CHECKS+=' installer/doctor/checks/*.sh | awk -F: '{s+=$2} END{print s" CHECKS+= registrations"}'  # EXPECT 46
  ```
- [ ] Confirm the runtime count agrees (derived from `${#CHECKS[@]}`):
  ```bash
  bash mayssam-ai-stack.sh doctor 2>&1 | grep -iE 'doctor done|/46|46 checks' | tail -2   # EXPECT a 46-total line
  ```
- [ ] Record the verified baseline. If `wc -l` returns anything OTHER than 46, STOP and re-derive every numbered reference in Tasks 14/15 and this header before proceeding (the plan was written assuming 46; if the tree has moved again, new files are `(N+1)` and `(N+2)`, count is `N+2`, badge `N%2FN`→`(N+2)%2F(N+2)`).
- [ ] Confirm the two free ordinals: with baseline 46 the new files are **`47_docker_engine_consistency.sh`** and **`48_docker_engine_selection.sh`**, final total **48**, badge **`46%2F46`→`48%2F48`**. Verify `46` is NOT free:
  ```bash
  [[ -f installer/doctor/checks/46_agent_fleet_parity.sh ]] && echo "46 TAKEN by agent_fleet_parity → new files are 47/48" || echo "RE-DERIVE: 46 unexpectedly free"
  ```

> No commit (recon only). This gate exists because the spec + `project_doctor_count.md` memory both still say **45**, but commit `83a4c45` already promoted fleet-parity to check **46**. Every count edit in this plan is **46→48**.

---

## Task 1 — Registry skeleton + table + `engine_display`/`engine_addhost_args` (pure, no daemon)

**Files:**
- Create: `installer/lib/docker-engine.sh`
- Create (test): `installer/smoke/engine.sh`

**Steps:**

- [ ] Write the failing test `installer/smoke/engine.sh` covering the pure table accessors and the throwaway-ENV_FILE harness:
  ```bash
  #!/usr/bin/env bash
  # Unit tests for installer/lib/docker-engine.sh — engine registry.
  # Runs entirely offline (no daemon). .env writes go to a THROWAWAY file.
  set -Eeuo pipefail
  AI_STACK="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  source "$AI_STACK/installer/lib/common.sh"
  source "$AI_STACK/installer/lib/env.sh"
  # MUST reassign AFTER sourcing common.sh+env.sh (common.sh:58 hardcodes it until Task 2;
  # after Task 2 the pre-export also works, but reassign is the belt-and-suspenders rule).
  ENV_FILE="$(mktemp -t aistack-test-env.XXXXXX)"
  trap 'rm -f "$ENV_FILE"' EXIT
  source "$AI_STACK/installer/lib/docker-engine.sh"

  hdr "Smoke engine — registry (pure)"

  # --- ids + display ---
  log "ENGINE_IDS in priority order"
  [[ "$ENGINE_IDS" == "orbstack docker-desktop colima podman" ]] \
    || { err "ENGINE_IDS wrong: '$ENGINE_IDS'"; exit 1; }
  [[ "$(engine_display orbstack)" == "OrbStack" ]] || { err "display orbstack"; exit 1; }
  [[ "$(engine_display docker-desktop)" == "Docker Desktop" ]] || { err "display dd"; exit 1; }
  [[ "$(engine_display colima)" == "Colima" ]] || { err "display colima"; exit 1; }
  [[ "$(engine_display podman)" == "Podman" ]] || { err "display podman"; exit 1; }
  ok "display names correct"

  # --- addhost gating (the per-engine variance) ---
  log "engine_addhost_args gating"
  [[ -z "$(engine_addhost_args orbstack)" ]] || { err "orbstack should NOT add-host"; exit 1; }
  [[ -z "$(engine_addhost_args docker-desktop)" ]] || { err "dd should NOT add-host"; exit 1; }
  [[ "$(engine_addhost_args colima)" == "--add-host=host.docker.internal:host-gateway" ]] \
    || { err "colima MUST add-host"; exit 1; }
  [[ "$(engine_addhost_args podman)" == "--add-host=host.docker.internal:host-gateway" ]] \
    || { err "podman MUST add-host"; exit 1; }
  ok "add-host gating correct"

  # --- unknown id rejected everywhere ---
  log "unknown id rejection"
  engine_display bogus >/dev/null 2>&1 && { err "engine_display accepted bogus"; exit 1; }
  engine_addhost_args bogus >/dev/null 2>&1 && { err "engine_addhost_args accepted bogus"; exit 1; }
  ok "unknown id rejected"

  # --- inherit_errexit safety lint: NO bare `=$(engine_…)` assignments anywhere ---
  # (Under set -Eeuo pipefail + inherit_errexit a bare assignment from a function that
  #  returns non-zero ABORTS the whole script — every call MUST be guarded `|| {…}`.)
  log "lint: no bare =\$(engine_…) command-substitution assignments"
  if grep -rnE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=\"?\$\(engine_' \
       "$AI_STACK/installer/lib/docker-engine.sh" "$AI_STACK/installer/lib/deps.sh" \
       "$AI_STACK/installer/lib/docker.sh" "$AI_STACK/installer/phases/04_openshell.sh" \
       "$AI_STACK/mayssam-ai-stack.sh" 2>/dev/null | grep -vE '\|\||;[[:space:]]*\}|\bif\b|\bfor\b'; then
    err "found a bare =\$(engine_…) assignment (must be guarded under inherit_errexit)"; exit 1
  fi
  ok "no unguarded engine_* command substitutions"

  ok "Task 1 registry-pure tests passed"
  ```
  > The lint is intentionally added in Task 1 even though some scanned files (deps.sh/docker.sh/04) gain `engine_*` calls in later tasks — it stays green now (no matches) and becomes load-bearing as those calls land. The contract: every `engine_*` call is either in an `if`/`||`-guarded context or assigned with a trailing `|| { … }`; never a bare `x=$(engine_…)`. `engine_display`/`engine_addhost_args`/`engine_socket` keep `return 2` for the *programming-error* unknown-id case (callers always pre-validate with `_engine_valid`), while `engine_select`/`engine_pin`/`engine_ensure` return **1** for caller-recoverable conditions.
- [ ] Run it — expect FAIL (file does not exist yet):
  ```bash
  bash installer/smoke/engine.sh   # expect: source: docker-engine.sh: No such file → non-zero
  ```
- [ ] Create `installer/lib/docker-engine.sh` with the header, table, and the two pure functions (complete code):
  ```bash
  # docker-engine.sh — the Docker-engine registry: single source of truth for
  # per-engine probes, sockets, and host.docker.internal handling.
  # Sourced after common.sh + env.sh (engine_socket/engine_select need get_env/set_env).
  #
  # Value space of AI_STACK_DOCKER_ENGINE (.env): orbstack | docker-desktop | colima | podman
  # All `docker -H … info` probes are timeout-bounded so a wedged daemon never hangs us.

  [[ -z "${AI_STACK:-}" ]] && { echo "docker-engine.sh: AI_STACK unset" >&2; exit 2; }

  # Priority order is also the NO_PROMPT tie-break order (spec §key-decisions 3).
  ENGINE_IDS="orbstack docker-desktop colima podman"

  # _engine_valid <id> — exit 0 if id is one of ENGINE_IDS.
  _engine_valid() {
    local id="$1" e
    for e in $ENGINE_IDS; do [[ "$e" == "$id" ]] && return 0; done
    return 1
  }

  # engine_display <id> — human label.
  engine_display() {
    case "$1" in
      orbstack)       printf '%s' "OrbStack" ;;
      docker-desktop) printf '%s' "Docker Desktop" ;;
      colima)         printf '%s' "Colima" ;;
      podman)         printf '%s' "Podman" ;;
      *) err "engine_display: unknown engine id: $1"; return 2 ;;
    esac
  }

  # engine_addhost_args <id> — emit the host.docker.internal flag ONLY for engines
  # that do not auto-inject it (Colima, Podman). OrbStack/Docker Desktop: nothing.
  engine_addhost_args() {
    case "$1" in
      orbstack|docker-desktop) : ;;   # auto-injected; emit nothing
      colima|podman)           printf '%s' "--add-host=host.docker.internal:host-gateway" ;;
      *) err "engine_addhost_args: unknown engine id: $1"; return 2 ;;
    esac
  }
  ```
- [ ] Run it — expect PASS:
  ```bash
  bash installer/smoke/engine.sh   # expect: "Task 1 registry-pure tests passed", exit 0
  ```
- [ ] Commit:
  ```bash
  git add installer/lib/docker-engine.sh installer/smoke/engine.sh
  git commit -m "feat(engine): registry skeleton + display/add-host table (TDD)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 2 — Fix `common.sh:58` ENV_FILE clobber (prerequisite for safe tests)

**Files:**
- Modify: `installer/lib/common.sh` (line 58)
- Test: extend `installer/smoke/engine.sh` (add a pre-source override assertion)

**Steps:**

- [ ] Add a failing assertion to the TOP of `installer/smoke/engine.sh` (just after the `trap`, before sourcing docker-engine.sh) proving `export ENV_FILE` is honored pre-source:
  ```bash
  # Regression: a PRE-exported ENV_FILE must survive sourcing common.sh+env.sh.
  ( set -Eeuo pipefail
    tmp="$(mktemp -t aistack-presrc.XXXXXX)"; trap 'rm -f "$tmp"' EXIT
    AI_STACK_X="$AI_STACK" ENV_FILE="$tmp" bash -c '
      set -Eeuo pipefail
      AI_STACK="$AI_STACK_X"
      source "$AI_STACK/installer/lib/common.sh"
      source "$AI_STACK/installer/lib/env.sh"
      [[ "$ENV_FILE" == "'"$tmp"'" ]] || { echo "ENV_FILE clobbered to $ENV_FILE" >&2; exit 1; }
    ' ) || { err "pre-exported ENV_FILE was clobbered by common.sh:58"; exit 1; }
  ok "pre-exported ENV_FILE honored"
  ```
- [ ] Run it — expect FAIL (common.sh:58 hardcodes `ENV_FILE="$AI_STACK/.env"`):
  ```bash
  bash installer/smoke/engine.sh   # expect: "pre-exported ENV_FILE was clobbered" → exit 1
  ```
- [ ] Apply the one-line fix in `installer/lib/common.sh` (line 58): change
  ```bash
  ENV_FILE="$AI_STACK/.env"
  ```
  to
  ```bash
  ENV_FILE="${ENV_FILE:-$AI_STACK/.env}"
  ```
- [ ] Run it — expect PASS:
  ```bash
  bash installer/smoke/engine.sh   # expect: "pre-exported ENV_FILE honored", exit 0
  ```
- [ ] Add a grep GATE proving NO other lib re-hardcodes `ENV_FILE` unconditionally (so the throwaway override cannot be silently lost on the full-stack path). Add to `installer/smoke/engine.sh` right after the pre-source assertion:
  ```bash
  log "no lib re-hardcodes ENV_FILE unconditionally (only the :- idiom allowed)"
  bad="$(grep -rnE '^[[:space:]]*ENV_FILE=' "$AI_STACK"/installer/lib/*.sh | grep -vE 'ENV_FILE=\"?\$\{ENV_FILE:-' || true)"
  [[ -z "$bad" ]] || { err "unconditional ENV_FILE= assignment(s) found:\n$bad"; exit 1; }
  ok "all ENV_FILE= assignments honor the override"

  # Full source-chain survival: a pre-exported throwaway ENV_FILE must survive
  # common→env→docker→litellm→deps→setup (NOT just common+env).
  ( set -Eeuo pipefail
    tmp="$(mktemp -t aistack-chain.XXXXXX)"; trap 'rm -f "$tmp"' EXIT
    AI_STACK_X="$AI_STACK" ENV_FILE="$tmp" bash -c '
      set -Eeuo pipefail; AI_STACK="$AI_STACK_X"; L="$AI_STACK/installer/lib"
      for f in common env docker litellm deps setup; do
        [[ -f "$L/$f.sh" ]] && source "$L/$f.sh"
      done
      [[ "$ENV_FILE" == "'"$tmp"'" ]] || { echo "ENV_FILE clobbered to $ENV_FILE by the source chain" >&2; exit 1; }
    ' ) || { err "throwaway ENV_FILE did not survive the full source chain"; exit 1; }
  ok "throwaway ENV_FILE survives full source chain"
  ```
- [ ] Run the broader env smoke to confirm no regression (env.sh:15 already used `${ENV_FILE:-…}`; the real `.env` still wins when nothing is pre-exported):
  ```bash
  bash installer/smoke/00n.sh 2>&1 | tail -5 || true   # sanity; no ENV_FILE behavior change for normal runs
  ```
  > If the grep gate or the source-chain test fails, fix the offending `ENV_FILE=` line(s) in the named lib to the `${ENV_FILE:-…}` idiom in THIS task before proceeding — the MEMORY rule (never mutate the real `.env`) must be airtight across the whole chain, not just common+env.
- [ ] Commit:
  ```bash
  git add installer/lib/common.sh installer/smoke/engine.sh
  git commit -m "fix(env): honor pre-exported ENV_FILE in common.sh (${ENV_FILE:-...})

Makes throwaway-ENV_FILE tests safe; lets engine pin honor a custom env file.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 3 — `engine_socket <id>` (probed/derived, timeout-bounded)

**Files:**
- Modify: `installer/lib/docker-engine.sh`
- Test: extend `installer/smoke/engine.sh`

**Steps:**

- [ ] Add failing assertions to `installer/smoke/engine.sh` (the socket format contract — OrbStack is deterministic on this box, others assert "starts with `unix://` OR returns 1 cleanly"):
  ```bash
  log "engine_socket format contract"
  # orbstack: literal, stable path on this host.
  orb="$(engine_socket orbstack)" || true
  [[ "$orb" == "unix://$HOME/.orbstack/run/docker.sock" ]] \
    || { err "orbstack socket wrong: '$orb'"; exit 1; }
  # all resolvable sockets are unix:// (or tcp://); unknown id returns non-zero + empty.
  engine_socket bogus >/dev/null 2>&1 && { err "engine_socket accepted bogus"; exit 1; }
  # docker-desktop / colima / podman: either resolve to a unix:// string OR fail cleanly (1),
  # NEVER hang and NEVER print a non-uri. (They are not installed on this box.)
  for e in docker-desktop colima podman; do
    if s="$(engine_socket "$e" 2>/dev/null)"; then
      [[ "$s" == unix://* || "$s" == tcp://* ]] || { err "$e socket not a uri: '$s'"; exit 1; }
    fi
  done
  ok "engine_socket format contract holds"
  ```
- [ ] Run it — expect FAIL (`engine_socket` undefined):
  ```bash
  bash installer/smoke/engine.sh   # expect: engine_socket: command not found / wrong → exit 1
  ```
- [ ] Add `_engine_docker_timeout` + `engine_socket` to `installer/lib/docker-engine.sh` (complete code):
  ```bash
  # _engine_docker_timeout <secs> -- <cmd...> — run a docker probe with a hard cap.
  # macOS ships no coreutils `timeout`; use a background pid + kill fallback.
  _engine_docker_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
      timeout "$secs" "$@"; return $?
    fi
    "$@" &
    local pid=$!
    ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null ) &
    local killer=$!
    local rc=0
    wait "$pid" 2>/dev/null || rc=$?
    kill -TERM "$killer" 2>/dev/null || true
    wait "$killer" 2>/dev/null || true
    return $rc
  }

  # engine_socket <id> — echo the resolved DOCKER_HOST value (unix://… or tcp://…).
  # Probed/derived, never blindly assumed. Returns 1 (empty) if unresolvable.
  engine_socket() {
    local id="$1"
    _engine_valid "$id" || { err "engine_socket: unknown engine id: $id"; return 2; }
    case "$id" in
      orbstack)
        printf '%s' "unix://$HOME/.orbstack/run/docker.sock"
        ;;
      docker-desktop)
        # Prefer Docker Desktop's own context endpoint as source of truth.
        # WRAPPED in the timeout so a wedged docker CLI cannot hang the central export.
        local ep
        ep="$(_engine_docker_timeout 6 docker context inspect desktop-linux \
                --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || true)"
        if [[ -n "$ep" ]]; then printf '%s' "$ep"; return 0; fi
        if [[ -S "$HOME/.docker/run/docker.sock" ]]; then
          printf '%s' "unix://$HOME/.docker/run/docker.sock"; return 0
        fi
        if [[ -S /var/run/docker.sock ]]; then
          printf '%s' "unix:///var/run/docker.sock"; return 0
        fi
        return 1
        ;;
      colima)
        # `colima status` prints a `socket:` line; fall back to the conventional path.
        # WRAPPED in the timeout — a wedged colima CLI must not hang the export.
        local sock
        sock="$(_engine_docker_timeout 6 colima status 2>&1 | awk -F': *' '/[Ss]ocket:/{print $2; exit}' || true)"
        if [[ "$sock" == unix://* ]]; then printf '%s' "$sock"; return 0; fi
        local conv="$HOME/.colima/${COLIMA_PROFILE:-default}/docker.sock"
        if [[ -S "$conv" ]]; then printf '%s' "unix://$conv"; return 0; fi
        log "engine_socket colima: socket path ASSUMED ($conv) — unverified on this host"
        return 1
        ;;
      podman)
        # PodmanSocket.Path speaks the Docker API (podman 5.x). UNVERIFIED on this box.
        # WRAPPED in the timeout — podman machine inspect can hang on a wedged VM.
        local p
        p="$(_engine_docker_timeout 6 podman machine inspect \
               --format '{{.ConnectionInfo.PodmanSocket.Path}}' 2>/dev/null || true)"
        if [[ -n "$p" && -S "$p" ]]; then printf '%s' "unix://$p"; return 0; fi
        log "engine_socket podman: socket path ASSUMED via 'podman machine inspect' — unverified on this host"
        return 1
        ;;
    esac
  }
  ```
  > **inherit_errexit note:** `engine_socket` returns **2** ONLY for the unknown-id programming error (callers pre-validate). For a valid-but-unresolvable engine it returns **1**. Every caller guards the substitution (`|| { … }`) — verified by the Task 1 lint and re-checked per call site in Task 16.
- [ ] Run it — expect PASS:
  ```bash
  bash installer/smoke/engine.sh   # expect: "engine_socket format contract holds", exit 0
  ```
- [ ] Commit:
  ```bash
  git add installer/lib/docker-engine.sh installer/smoke/engine.sh
  git commit -m "feat(engine): engine_socket — probed/derived DOCKER_HOST per engine (TDD)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 4 — Detection: `engine_installed` / `engine_detect_installed` / `engine_running` / `engine_detect_running`

**Files:**
- Modify: `installer/lib/docker-engine.sh`
- Test: extend `installer/smoke/engine.sh`

**Steps:**

- [ ] Add failing assertions to `installer/smoke/engine.sh`. PORTABLE: gate every host-reality assertion on ACTUAL detection (not a hardcoded inventory) so the suite passes on any reviewer/CI box — incl. one WITH Docker Desktop (the very scenario being designed for) or one WITHOUT podman:
  ```bash
  log "engine_installed / engine_detect_installed (self-consistent, host-agnostic)"
  # engine_installed and engine_detect_installed must AGREE for every id (no fixed inventory).
  inst="$(engine_detect_installed)"
  for e in $ENGINE_IDS; do
    if engine_installed "$e"; then
      grep -qx "$e" <<<"$inst" || { err "detect_installed missing $e though engine_installed $e is true"; exit 1; }
    else
      grep -qx "$e" <<<"$inst" && { err "detect_installed wrongly listed $e"; exit 1; } || true
    fi
  done
  # At least one engine must be installed on a real dev box (sanity, not inventory).
  [[ -n "$inst" ]] || { err "no docker engine installed at all"; exit 1; }
  ok "install detection self-consistent for all ids"

  log "engine_running is timeout-bounded (must not hang) — assert against a NOT-running engine"
  # Find an installed-but-not-running engine to time; if none, use a known-absent path:
  bounded_target=""
  for e in $ENGINE_IDS; do engine_installed "$e" && ! engine_running "$e" && { bounded_target="$e"; break; }; done
  [[ -n "$bounded_target" ]] || bounded_target=podman   # podman path is safe to time even if absent
  start=$(date +%s)
  engine_running "$bounded_target" && true   # don't care about result, only the wall-clock
  end=$(date +%s)
  (( end - start <= 8 )) || { err "engine_running not timeout-bounded ($((end-start))s for $bounded_target)"; exit 1; }
  ok "engine_running bounded (<=8s, target=$bounded_target)"
  ```
- [ ] Run it — expect FAIL (`engine_installed` undefined):
  ```bash
  bash installer/smoke/engine.sh   # expect: engine_installed: command not found → exit 1
  ```
- [ ] Add the detection functions to `installer/lib/docker-engine.sh` (complete code):
  ```bash
  # engine_installed <id> — exit 0 if the engine's app/binary is present.
  engine_installed() {
    local id="$1"
    _engine_valid "$id" || { err "engine_installed: unknown engine id: $id"; return 2; }
    case "$id" in
      orbstack)
        [[ -d /Applications/OrbStack.app ]] && return 0
        brew list --cask orbstack >/dev/null 2>&1 && return 0
        command -v orb >/dev/null 2>&1 && return 0
        return 1 ;;
      docker-desktop)
        [[ -d /Applications/Docker.app ]] && return 0
        brew list --cask docker-desktop >/dev/null 2>&1 && return 0
        brew list --cask docker >/dev/null 2>&1 && return 0   # legacy cask name
        return 1 ;;
      colima)
        command -v colima >/dev/null 2>&1 ;;
      podman)
        command -v podman >/dev/null 2>&1 ;;
    esac
  }

  # engine_detect_installed — echo installed engine ids, one per line, priority order.
  engine_detect_installed() {
    local e
    for e in $ENGINE_IDS; do engine_installed "$e" && printf '%s\n' "$e"; done
  }

  # engine_running <id> — exit 0 if THAT engine's daemon answers (timeout-bounded).
  engine_running() {
    local id="$1" sock
    _engine_valid "$id" || { err "engine_running: unknown engine id: $id"; return 2; }
    sock="$(engine_socket "$id" 2>/dev/null)" || return 1
    [[ -n "$sock" ]] || return 1
    _engine_docker_timeout 6 docker -H "$sock" info >/dev/null 2>&1
  }

  # engine_detect_running — echo running engine ids, one per line, priority order.
  engine_detect_running() {
    local e
    for e in $ENGINE_IDS; do engine_running "$e" && printf '%s\n' "$e"; done
  }
  ```
- [ ] Run it — expect PASS:
  ```bash
  bash installer/smoke/engine.sh   # expect: "engine_running bounded", exit 0
  ```
- [ ] Commit:
  ```bash
  git add installer/lib/docker-engine.sh installer/smoke/engine.sh
  git commit -m "feat(engine): installed/running detection (timeout-bounded probes) (TDD)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 5 — `engine_select` precedence (FAILURE PATHS FIRST: unknown id, NO_PROMPT priority, env over running)

**Files:**
- Modify: `installer/lib/docker-engine.sh`
- Test: extend `installer/smoke/engine.sh`

**Steps:**

- [ ] Add failing assertions to `installer/smoke/engine.sh` (precedence + failure paths; all use the throwaway `ENV_FILE`):
  ```bash
  log "engine_select precedence (failure paths first)"
  # 1) Unknown --engine flag must be rejected hard.
  ( AI_STACK_ENGINE_FLAG=bogus NO_PROMPT=1 engine_select ) >/dev/null 2>&1 \
    && { err "engine_select accepted bogus flag"; exit 1; } || true
  # 2) Flag beats everything (even a different .env value).
  set_env AI_STACK_DOCKER_ENGINE colima
  sel="$(AI_STACK_ENGINE_FLAG=podman NO_PROMPT=1 engine_select 2>/dev/null)"
  [[ "$sel" == podman ]] || { err "flag did not win: '$sel'"; exit 1; }
  # 3) .env beats running-singleton + priority when no flag.
  sel="$(NO_PROMPT=1 engine_select 2>/dev/null)"
  [[ "$sel" == colima ]] || { err ".env did not win: '$sel'"; exit 1; }
  # 4) RUNNING-SINGLETON rung (the subtlest one — MUST be unambiguous, so STUB
  #    engine_detect_running to return exactly ONE id that DIFFERS from the
  #    priority-fallback winner, with empty .env and NO flag. This proves
  #    "single running engine" beats the orbstack priority fallback. Without the
  #    stub this rung is physically untestable on a single-engine box.
  set_env AI_STACK_DOCKER_ENGINE ""
  sel="$(
    set -Eeuo pipefail
    AI_STACK="$AI_STACK"; ENV_FILE="$ENV_FILE"
    source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
    source "$AI_STACK/installer/lib/docker-engine.sh"
    engine_detect_running() { printf 'colima\n'; }   # exactly one, != orbstack priority winner
    NO_PROMPT=1 engine_select 2>/dev/null
  )"
  [[ "$sel" == colima ]] || { err "running-singleton rung failed (want colima, got '$sel')"; exit 1; }
  ok "running-singleton beats priority fallback"
  # 5) No flag, empty .env, NO_PROMPT, ZERO/MULTIPLE running → fixed priority (first INSTALLED, else first id).
  sel="$(NO_PROMPT=1 engine_select 2>/dev/null)"
  # orbstack is installed on this box → must win the priority fallback.
  [[ "$sel" == orbstack ]] || { err "NO_PROMPT priority did not pick orbstack: '$sel'"; exit 1; }
  ok "engine_select precedence correct (incl running-singleton)"
  ```
  > The running-singleton stub re-sources the registry in a subshell so the stub `engine_detect_running` shadows the real one without polluting later assertions. The outer assertion #5 must run AFTER #4 so the real `engine_detect_running` is back in scope.
- [ ] Run it — expect FAIL (`engine_select` undefined):
  ```bash
  bash installer/smoke/engine.sh   # expect: engine_select: command not found → exit 1
  ```
- [ ] Add `engine_select` to `installer/lib/docker-engine.sh` (complete code — note: prompt uses the deps.sh NO_PROMPT idiom, prints to stderr, echoes the id to stdout):
  ```bash
  # engine_select — resolve the engine id by precedence and echo it to STDOUT.
  #   1. --engine flag (passed as env var AI_STACK_ENGINE_FLAG by the caller)
  #   2. AI_STACK_DOCKER_ENGINE in .env
  #   3. the single RUNNING engine (if exactly one runs)
  #   4. interactive prompt (skipped under NO_PROMPT / non-TTY)
  #   5. NO_PROMPT fallback: first INSTALLED engine in ENGINE_IDS priority order,
  #      else the first id in ENGINE_IDS. Logged loudly.
  # Reasons go to STDERR; only the chosen id goes to STDOUT.
  # Returns 1 (NOT 2) for caller-recoverable bad input (bad flag / bad .env / bad
  # interactive choice) so a guarded `sel="$(engine_select)" || {…}` caller can
  # recover under inherit_errexit. (2 is reserved for the _engine_valid programming
  # error in the pure accessors, which callers always pre-validate.)
  engine_select() {
    local flag="${AI_STACK_ENGINE_FLAG:-}"
    if [[ -n "$flag" ]]; then
      _engine_valid "$flag" || { err "engine_select: unknown --engine id '$flag' (want: $ENGINE_IDS)"; return 1; }
      log "engine: $flag (from --engine flag)"
      printf '%s' "$flag"; return 0
    fi

    local pinned; pinned="$(get_env AI_STACK_DOCKER_ENGINE "")"
    if [[ -n "$pinned" ]]; then
      if ! _engine_valid "$pinned"; then
        err "engine_select: .env AI_STACK_DOCKER_ENGINE='$pinned' is invalid (want: $ENGINE_IDS)"; return 1
      fi
      log "engine: $pinned (from AI_STACK_DOCKER_ENGINE in .env)"
      printf '%s' "$pinned"; return 0
    fi

    local running; running="$(engine_detect_running)"
    local n; n="$(printf '%s' "$running" | grep -c . || true)"
    if [[ "$n" == "1" ]]; then
      log "engine: $running (the single running engine)"
      printf '%s' "$running"; return 0
    fi

    # Interactive prompt — skipped under NO_PROMPT or no TTY.
    if [[ "${NO_PROMPT:-0}" != "1" && -t 0 ]]; then
      local installed; installed="$(engine_detect_installed)"
      printf '  Multiple/zero engines detected. Choose a Docker engine:\n' >&2
      local e
      for e in $ENGINE_IDS; do
        local mark=""
        grep -qx "$e" <<<"$installed" && mark=" [installed]"
        grep -qx "$e" <<<"$running"   && mark="$mark [running]"
        printf '    - %s (%s)%s\n' "$e" "$(engine_display "$e")" "$mark" >&2
      done
      printf '  engine id [orbstack]: ' >&2
      local ans; read -r ans || true
      ans="${ans:-orbstack}"
      _engine_valid "$ans" || { err "engine_select: invalid choice '$ans'"; return 1; }
      log "engine: $ans (interactive choice)"
      printf '%s' "$ans"; return 0
    fi

    # NO_PROMPT / non-TTY fallback: fixed priority, prefer installed.
    local e
    for e in $ENGINE_IDS; do
      if engine_installed "$e"; then
        warn "engine: $e (NO_PROMPT fixed-priority fallback — first INSTALLED of: $ENGINE_IDS)"
        printf '%s' "$e"; return 0
      fi
    done
    e="${ENGINE_IDS%% *}"
    warn "engine: $e (NO_PROMPT fixed-priority fallback — none installed; first of: $ENGINE_IDS)"
    printf '%s' "$e"
  }
  ```
- [ ] Run it — expect PASS:
  ```bash
  bash installer/smoke/engine.sh   # expect: "engine_select precedence correct", exit 0
  ```
- [ ] Commit:
  ```bash
  git add installer/lib/docker-engine.sh installer/smoke/engine.sh
  git commit -m "feat(engine): engine_select precedence (flag>env>running>prompt>priority) (TDD)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 6 — `engine_start` / `engine_install` / `engine_ensure` (consent, NO_PROMPT hard-fail, bounded wait)

**Files:**
- Modify: `installer/lib/docker-engine.sh`
- Test: extend `installer/smoke/engine.sh`

**Steps:**

- [ ] Add failing assertions to `installer/smoke/engine.sh` (FAILURE PATH: NO_PROMPT + not-installed must hard-fail with the exact `brew` remediation; do NOT actually install/start anything in the test — only assert the not-installed-under-NO_PROMPT path and that functions are defined):
  ```bash
  log "engine_ensure failure path: not installed + NO_PROMPT → hard fail with brew remedy"
  # Pick an engine that is NOT installed on this box (docker-desktop).
  engine_installed docker-desktop && { err "test assumes docker-desktop NOT installed"; exit 1; } || true
  out="$(NO_PROMPT=1 engine_ensure docker-desktop 2>&1)" && { err "engine_ensure should fail (not installed, NO_PROMPT)"; exit 1; } || true
  grep -q 'brew install' <<<"$out" || { err "engine_ensure must print 'brew install' remedy; got: $out"; exit 1; }
  ok "engine_ensure NO_PROMPT-not-installed hard-fails with brew remedy"

  log "engine_install_cmd exact brew strings for ALL 4 ids (pure, no brew needed)"
  [[ "$(engine_install_cmd orbstack)"       == "brew install --cask orbstack" ]]       || { err "install_cmd orbstack";       exit 1; }
  [[ "$(engine_install_cmd docker-desktop)" == "brew install --cask docker-desktop" ]] || { err "install_cmd docker-desktop"; exit 1; }
  [[ "$(engine_install_cmd colima)"         == "brew install colima docker" ]]         || { err "install_cmd colima";         exit 1; }
  [[ "$(engine_install_cmd podman)"         == "brew install podman docker" ]]         || { err "install_cmd podman";         exit 1; }
  engine_install_cmd bogus >/dev/null 2>&1 && { err "install_cmd accepted bogus"; exit 1; } || true
  ok "engine_install_cmd strings correct for all 4 ids"

  log "engine_install / engine_start are defined (no-op assert)"
  declare -F engine_install >/dev/null || { err "engine_install undefined"; exit 1; }
  declare -F engine_start   >/dev/null || { err "engine_start undefined"; exit 1; }
  ok "engine_install/engine_start defined"
  ```
  > NOTE (residual, documented not papered-over): the docker-desktop **cask-name-churn fallback** (`brew info --cask docker-desktop` → `docker`) is interactive-only and requires brew network, so it ships UNTESTED. The pure `engine_install_cmd` assertion above covers the strings; the churn branch is verified manually in the matrix (Task 17).
- [ ] Run it — expect FAIL (`engine_ensure` undefined):
  ```bash
  bash installer/smoke/engine.sh   # expect: engine_ensure: command not found → exit 1
  ```
- [ ] Add `engine_install`, `engine_start`, `engine_ensure` to `installer/lib/docker-engine.sh` (complete code):
  ```bash
  # engine_install <id> — the brew remediation string + (if interactive) run it.
  # Echoes the exact command on the err path so NO_PROMPT callers can copy it.
  engine_install_cmd() {
    case "$1" in
      orbstack)       printf '%s' "brew install --cask orbstack" ;;
      docker-desktop) printf '%s' "brew install --cask docker-desktop" ;;
      colima)         printf '%s' "brew install colima docker" ;;
      podman)         printf '%s' "brew install podman docker" ;;
      *) return 2 ;;
    esac
  }

  engine_install() {
    local id="$1"
    _engine_valid "$id" || { err "engine_install: unknown engine id: $id"; return 2; }
    # Resolve the docker-desktop cask token BEFORE the prompt so the user consents
    # to the EXACT command that runs (cask churned docker → docker-desktop).
    local -a cmd
    case "$id" in
      orbstack)       cmd=(brew install --cask orbstack) ;;
      docker-desktop)
        if brew info --cask docker-desktop >/dev/null 2>&1; then cmd=(brew install --cask docker-desktop)
        else cmd=(brew install --cask docker); fi ;;
      colima)         cmd=(brew install colima docker) ;;
      podman)         cmd=(brew install podman docker) ;;
    esac
    if [[ "${NO_PROMPT:-0}" == "1" ]]; then
      err "$(engine_display "$id") not installed. Install it and re-run:"
      err "    ${cmd[*]}"
      return 1
    fi
    printf '  Install %s now via: %s ? [Y/n] ' "$(engine_display "$id")" "${cmd[*]}" >&2
    local ans; read -r ans || true
    case "${ans:-Y}" in
      [Nn]*) err "declined; install manually: ${cmd[*]}"; return 1 ;;
    esac
    log "Running: ${cmd[*]}"
    # Array invocation — no eval. Pipe through tail without losing the install rc.
    if ! "${cmd[@]}" 2>&1 | tail -8; then err "install failed: ${cmd[*]}"; return 1; fi
  }

  # engine_start <id> — start that engine's daemon (does not wait).
  engine_start() {
    local id="$1"
    _engine_valid "$id" || { err "engine_start: unknown engine id: $id"; return 2; }
    case "$id" in
      orbstack)       open -a OrbStack 2>/dev/null || true ;;
      docker-desktop) open -a Docker 2>/dev/null || true ;;
      colima)         colima start 2>&1 | tail -4 || true ;;
      podman)
        # Init the machine on first run, else start it.
        if podman machine inspect >/dev/null 2>&1; then
          podman machine start 2>&1 | tail -4 || true
        else
          podman machine init --now 2>&1 | tail -6 || true
        fi
        ;;
    esac
  }

  # engine_ensure <id> — install-if-missing (consent/NO_PROMPT) + start + bounded wait.
  engine_ensure() {
    local id="$1"
    _engine_valid "$id" || { err "engine_ensure: unknown engine id: $id"; return 2; }
    if ! engine_installed "$id"; then
      engine_install "$id" || return 1
    fi
    if engine_running "$id"; then
      ok "$(engine_display "$id") daemon ready"
      return 0
    fi
    log "Starting $(engine_display "$id")..."
    engine_start "$id"
    local i=0
    until engine_running "$id"; do
      sleep 2
      (( ++i > 45 )) && {
        err "$(engine_display "$id") did not answer on its socket within 90s."
        err "Start it manually and re-run. (socket: $(engine_socket "$id" 2>/dev/null || echo '?'))"
        return 1
      }
    done
    ok "$(engine_display "$id") daemon ready"
  }
  ```
- [ ] Run it — expect PASS:
  ```bash
  bash installer/smoke/engine.sh   # expect: "engine_install/engine_start defined", exit 0
  ```
- [ ] Commit:
  ```bash
  git add installer/lib/docker-engine.sh installer/smoke/engine.sh
  git commit -m "feat(engine): engine_install/start/ensure (consent + NO_PROMPT brew-remedy) (TDD)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 7 — `engine_pin <id>` (persist .env, export DOCKER_HOST, rewrite gateway.env, offer docker context)

> **Superseded 2026-06-21** — the `offer docker context` / `[y/N]` prompt shown in the
> `engine_pin` code block below was replaced by a non-interactive persisted preference
> (`AI_STACK_DOCKER_CONTEXT`, default `switch`) handled by a new `engine_apply_context`;
> `engine_pin` no longer prompts. The code quoted here is the *original* design, kept for
> history. See [`2026-06-21-docker-context-policy.md`](2026-06-21-docker-context-policy.md).

**Files:**
- Modify: `installer/lib/docker-engine.sh`
- Test: extend `installer/smoke/engine.sh`

**Steps:**

- [ ] Add failing assertions to `installer/smoke/engine.sh` (use the throwaway `ENV_FILE` AND a throwaway `GATEWAY_ENV_FILE` so we never touch the real gateway.env; pin to orbstack — the one engine resolvable on this box):
  ```bash
  log "engine_pin: persists .env, rewrites gateway.env, exports DOCKER_HOST"
  GW="$(mktemp -t aistack-gw.XXXXXX)"; trap 'rm -f "$ENV_FILE" "$GW"' EXIT
  # engine_pin must honor an injected GATEWAY_ENV_FILE override + skip docker context under NO_PROMPT.
  ( NO_PROMPT=1 ENGINE_GATEWAY_ENV_FILE="$GW" engine_pin orbstack ) >/dev/null 2>&1 \
    || { err "engine_pin orbstack failed"; exit 1; }
  [[ "$(get_env AI_STACK_DOCKER_ENGINE "")" == orbstack ]] || { err ".env not pinned"; exit 1; }
  grep -qx "OPENSHELL_DRIVERS=docker" "$GW" || { err "gateway.env missing drivers line"; exit 1; }
  grep -qx "DOCKER_HOST=unix://$HOME/.orbstack/run/docker.sock" "$GW" \
    || { err "gateway.env DOCKER_HOST wrong: $(cat "$GW")"; exit 1; }
  ok "engine_pin persisted + rewrote gateway.env"

  log "engine_write_gateway_env is the SINGLE writer + idempotent (no-op on 2nd call)"
  declare -F engine_write_gateway_env >/dev/null || { err "engine_write_gateway_env undefined (single-writer not extracted)"; exit 1; }
  # First call already happened via engine_pin → file matches → second call must be a NO-OP (return 1=unchanged).
  if ENGINE_GATEWAY_ENV_FILE="$GW" engine_write_gateway_env orbstack; then
    err "engine_write_gateway_env reported CHANGED on an already-current gateway.env (not idempotent)"; exit 1
  fi
  ok "engine_write_gateway_env idempotent (unchanged → return 1)"
  ```
- [ ] Run it — expect FAIL (`engine_pin` undefined):
  ```bash
  bash installer/smoke/engine.sh   # expect: engine_pin: command not found → exit 1
  ```
- [ ] Add `engine_write_gateway_env` (the SINGLE gateway.env author) + `engine_pin` to `installer/lib/docker-engine.sh` (complete code — gateway path is overridable via `ENGINE_GATEWAY_ENV_FILE` for tests, defaults to the real XDG path). Phase 04 (Task 12) calls the SAME helper — no duplicated writer:
  ```bash
  # engine_write_gateway_env <id> [gw_file] — the ONE place that authors gateway.env.
  # Idempotent: returns 0 if it (re)wrote the file, 1 if it was already current.
  # Honors ENGINE_GATEWAY_ENV_FILE (test override) when no explicit gw_file is given.
  engine_write_gateway_env() {
    local id="$1"
    local gw="${2:-${ENGINE_GATEWAY_ENV_FILE:-$HOME/.config/openshell/gateway.env}}"
    _engine_valid "$id" || { err "engine_write_gateway_env: unknown engine id: $id"; return 2; }
    local sock; sock="$(engine_socket "$id")" || {
      err "engine_write_gateway_env: cannot resolve socket for $id"; return 2; }
    mkdir -p "$(dirname "$gw")"
    if grep -qxF "OPENSHELL_DRIVERS=docker" "$gw" 2>/dev/null \
       && grep -qxF "DOCKER_HOST=$sock" "$gw" 2>/dev/null; then
      return 1   # already current — no change
    fi
    cat > "$gw" <<EOF
# Written by ai-stack docker-engine (engine: $id).
# Sourced by /opt/homebrew/opt/openshell/libexec/openshell-gateway-homebrew-service
# before the gateway binary exec'es.
OPENSHELL_DRIVERS=docker
DOCKER_HOST=$sock
EOF
    chmod 600 "$gw"
    return 0   # wrote/changed
  }

  # engine_pin <id> — persist + propagate the selected engine everywhere.
  #   - set_env AI_STACK_DOCKER_ENGINE
  #   - export DOCKER_HOST (so the current process + children inherit it)
  #   - rewrite gateway.env via engine_write_gateway_env (single writer)
  #   - offer (consented; skipped under NO_PROMPT) `docker context use ai-stack-<id>`,
  #     RECORDING the prior context first so the user has an undo.
  # Returns 1 (caller-recoverable) on socket/persist failure.
  engine_pin() {
    local id="$1"
    _engine_valid "$id" || { err "engine_pin: unknown engine id: $id"; return 2; }
    local sock; sock="$(engine_socket "$id")" || {
      err "engine_pin: cannot resolve socket for $id — is the daemon up?"; return 1; }

    set_env AI_STACK_DOCKER_ENGINE "$id" || return 1
    export DOCKER_HOST="$sock"
    ok "pinned AI_STACK_DOCKER_ENGINE=$id (DOCKER_HOST=$sock)"

    if engine_write_gateway_env "$id"; then
      ok "wrote gateway.env (DOCKER_HOST=$sock) — restart the gateway for it to take effect"
    fi

    # Offer to switch the global docker context (invasive; consented). Record the
    # PRIOR context first and print the exact undo (reversibility).
    if [[ "${NO_PROMPT:-0}" != "1" && -t 0 ]] && command -v docker >/dev/null 2>&1; then
      local ctx="ai-stack-$id" prior
      prior="$(docker context show 2>/dev/null || echo default)"
      printf '  Also point your global `docker context` at %s (ctx: %s)? [y/N]\n' "$(engine_display "$id")" "$ctx" >&2
      printf '    (your current context is "%s"; undo later with: docker context use %s) ' "$prior" "$prior" >&2
      local ans; read -r ans || true
      case "${ans:-N}" in
        [Yy]*)
          docker context inspect "$ctx" >/dev/null 2>&1 \
            || docker context create "$ctx" --docker "host=$sock" --description "ai-stack $id" >/dev/null 2>&1 \
            || docker context update "$ctx" --docker "host=$sock" >/dev/null 2>&1 || true
          if docker context use "$ctx" >/dev/null 2>&1; then
            ok "docker context → $ctx (previous: $prior; undo: docker context use $prior)"
          else
            warn "could not switch docker context"
          fi
          ;;
      esac
    fi
  }
  ```
  > The `docker context use` branch is NO_PROMPT-skipped and TTY-gated, so it is not exercised by the (NO_PROMPT) smoke test — flagged as untested in Task 17's manual matrix. Because the exported `DOCKER_HOST` overrides `docker context` inside ai-stack processes, this switch only changes the user's AMBIENT world; the recorded-prior + printed undo is the reversibility contract.
- [ ] Run it — expect PASS:
  ```bash
  bash installer/smoke/engine.sh   # expect: "engine_pin persisted + rewrote gateway.env", exit 0
  ```
- [ ] Commit:
  ```bash
  git add installer/lib/docker-engine.sh installer/smoke/engine.sh
  git commit -m "feat(engine): engine_pin — persist .env + rewrite gateway.env + offer context (TDD)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 8 — Central wiring: source `docker-engine.sh` + export `DOCKER_HOST` after env.sh

**Files:**
- Modify: `mayssam-ai-stack.sh` (after line 101)
- Test: extend `installer/smoke/engine.sh` (assert the export against the REAL load path, not a re-implemented snippet)

**Steps:**

- [ ] Add a debug verb to make the test exercise the REAL `mayssam-ai-stack.sh` export (NOT a re-implemented snippet). Append to the dispatch (alongside Task 11's `docker-engine`): a hidden `--print-docker-host` that runs the real top-of-file export and echoes `$DOCKER_HOST`. Add the handler near the `docker-engine)` arm:
  ```bash
      __print-docker-host) printf '%s\n' "DOCKER_HOST=${DOCKER_HOST:-<unset>}"; exit 0 ;;
  ```
  (Place it in the `case "$cmd"` block; it is undocumented — a test seam that runs the genuine sourced export.)
- [ ] Add the failing assertion to `installer/smoke/engine.sh` that calls the REAL load path with a throwaway pinned `.env`:
  ```bash
  log "central export: pinned .env → DOCKER_HOST exported by the REAL mayssam-ai-stack.sh load path"
  tmpenv="$(mktemp -t aistack-export.XXXXXX)"
  printf 'AI_STACK_DOCKER_ENGINE=orbstack\n' > "$tmpenv"
  got="$(ENV_FILE="$tmpenv" bash "$AI_STACK/mayssam-ai-stack.sh" __print-docker-host 2>/dev/null || true)"
  rm -f "$tmpenv"
  grep -q "DOCKER_HOST=unix://$HOME/.orbstack/run/docker.sock" <<<"$got" \
    || { err "central export not wired (real load path did not export DOCKER_HOST): $got"; exit 1; }
  # Empty-engine case: unset .env → export is a no-op (DOCKER_HOST stays unset/ambient).
  tmpe2="$(mktemp)"; printf 'AI_STACK_DOCKER_ENGINE=\n' > "$tmpe2"
  got2="$(env -u DOCKER_HOST ENV_FILE="$tmpe2" bash "$AI_STACK/mayssam-ai-stack.sh" __print-docker-host 2>/dev/null || true)"
  rm -f "$tmpe2"
  grep -q 'DOCKER_HOST=<unset>' <<<"$got2" || { err "empty engine should be a no-op export: $got2"; exit 1; }
  ok "central DOCKER_HOST export wired (real path; no-op when unset)"
  ```
  > This asserts against the genuine sourced `mayssam-ai-stack.sh` export via the `__print-docker-host` seam — NOT a copy of the logic. It is red until BOTH this export edit AND the `__print-docker-host` arm exist; both land in this task, so it goes red→green within Task 8 (no cross-task dependency).
- [ ] Run it — expect FAIL (no export / no seam yet):
  ```bash
  bash installer/smoke/engine.sh   # expect: "central export not wired" → exit 1
  ```
- [ ] Edit `mayssam-ai-stack.sh` — insert AFTER `source "$LIB/env.sh"` (line 101) and BEFORE `source "$LIB/docker.sh"`:
  ```bash
  source "$LIB/docker-engine.sh"
  # Central DOCKER_HOST export: derive the one socket the WHOLE stack uses from the
  # single source of truth (AI_STACK_DOCKER_ENGINE in .env). No-op when unset (a
  # local-only user who never selected an engine keeps the ambient docker context).
  _ai_stack_engine="$(get_env AI_STACK_DOCKER_ENGINE "")"
  if [[ -n "$_ai_stack_engine" ]] && _engine_valid "$_ai_stack_engine"; then
    _ai_stack_sock="$(engine_socket "$_ai_stack_engine" 2>/dev/null || true)"
    [[ -n "$_ai_stack_sock" ]] && export DOCKER_HOST="$_ai_stack_sock"
  fi
  unset _ai_stack_engine _ai_stack_sock
  ```
- [ ] Run it — expect PASS:
  ```bash
  bash installer/smoke/engine.sh   # expect: "central DOCKER_HOST export wired (real path…)", exit 0
  ```
- [ ] Commit:
  ```bash
  git add mayssam-ai-stack.sh installer/smoke/engine.sh
  git commit -m "feat(engine): source docker-engine.sh + export DOCKER_HOST centrally after env.sh

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 8b — `docker.sh` source-time `DOCKER_HOST` export (so standalone `bin/start-*.sh` inherit it)

> **Why (INFRA-critical):** `mayssam-ai-stack.sh` is NOT in the process chain for `bash bin/start-litellm.sh --recreate` (recreate_guard's own remediation, phase 01) — those scripts source `common.sh`/`env.sh`/`docker.sh` directly. The Task 8 export never reaches them, so on a Docker-Desktop-present box those containers silently land on the ambient socket — the exact split-brain. Fix: re-export at `docker.sh` source-time so EVERY `start-*.sh` inherits the selected socket unconditionally.

**Files:**
- Modify: `installer/lib/docker.sh` (top, after it sources its deps)
- Test: extend `installer/smoke/engine.sh`

**Steps:**

- [ ] Add a failing assertion to `installer/smoke/engine.sh` that proves a clean-env `start-*.sh`-style chain (common→env→docker-engine→docker, NO mayssam-ai-stack.sh) resolves the selected socket onto a stubbed `docker run`:
  ```bash
  log "8b: standalone docker.sh source chain exports the selected DOCKER_HOST"
  tmpenv="$(mktemp -t aistack-8b.XXXXXX)"
  printf 'AI_STACK_DOCKER_ENGINE=orbstack\n' > "$tmpenv"
  got="$(env -u DOCKER_HOST ENV_FILE="$tmpenv" bash -c '
    set -Eeuo pipefail; AI_STACK="'"$AI_STACK"'"; L="$AI_STACK/installer/lib"
    source "$L/common.sh"; source "$L/env.sh"; source "$L/docker-engine.sh"; source "$L/docker.sh"
    echo "DOCKER_HOST=${DOCKER_HOST:-<unset>}"
  ' 2>/dev/null || true)"
  rm -f "$tmpenv"
  grep -q "DOCKER_HOST=unix://$HOME/.orbstack/run/docker.sock" <<<"$got" \
    || { err "docker.sh source-time export not wired: $got"; exit 1; }
  ok "8b: standalone docker.sh chain exports DOCKER_HOST"
  ```
- [ ] Run it — expect FAIL:
  ```bash
  bash installer/smoke/engine.sh   # expect: "docker.sh source-time export not wired" → exit 1
  ```
- [ ] Edit `installer/lib/docker.sh` — add at the END of the file (after `docker.sh` has its functions and `docker-engine.sh` is available in scope). Guard so it is a no-op if `docker-engine.sh` was not sourced (don't hard-require it for callers that only want `docker_run_managed`'s other helpers):
  ```bash
  # Source-time DOCKER_HOST export so STANDALONE bin/start-*.sh (which source this
  # file but NOT mayssam-ai-stack.sh) talk to the SELECTED engine, not the ambient socket.
  # Idempotent + no-op when AI_STACK_DOCKER_ENGINE is empty/unset.
  if declare -F engine_socket >/dev/null 2>&1 && declare -F _engine_valid >/dev/null 2>&1; then
    _ds_eng="$(get_env AI_STACK_DOCKER_ENGINE "" 2>/dev/null || true)"
    if [[ -n "${_ds_eng:-}" ]] && _engine_valid "$_ds_eng" 2>/dev/null; then
      _ds_sock="$(engine_socket "$_ds_eng" 2>/dev/null || true)"
      [[ -n "${_ds_sock:-}" ]] && export DOCKER_HOST="$_ds_sock"
    fi
    unset _ds_eng _ds_sock
  fi
  ```
  > `bin/start-*.sh` already source `docker.sh`; they do NOT currently source `docker-engine.sh`. Add `source "$AI_STACK/installer/lib/docker-engine.sh"` to the shared bootstrap each `start-*.sh` uses (verify with `grep -n 'docker-engine\|docker\.sh' bin/start-litellm.sh`), OR have `docker.sh` itself source `docker-engine.sh` at its top (guarded: `[[ -f "$LIB/docker-engine.sh" ]] && source …`). Prefer the latter (one edit, every start script benefits). Confirm no source cycle (`docker-engine.sh` does NOT source `docker.sh`).
- [ ] Run it — expect PASS:
  ```bash
  bash installer/smoke/engine.sh   # expect: "8b: standalone docker.sh chain exports DOCKER_HOST", exit 0
  # And prove it reaches a real start script's docker run line under a stub:
  tmpenv="$(mktemp)"; printf 'AI_STACK_DOCKER_ENGINE=orbstack\n' > "$tmpenv"
  env -u DOCKER_HOST ENV_FILE="$tmpenv" bash -c '
    set -Eeuo pipefail; export PATH="/tmp/none:$PATH"
    # stub docker to echo DOCKER_HOST it would use, then bail before real work
    d=$(mktemp -d); printf "#!/usr/bin/env bash\necho DOCKER_HOST=\$DOCKER_HOST; exit 0\n" >"$d/docker"; chmod +x "$d/docker"
    PATH="$d:$PATH" bash "'"$AI_STACK"'/bin/start-litellm.sh" 2>&1 | grep -m1 "DOCKER_HOST=unix://" \
      || { echo "start-litellm did not inherit DOCKER_HOST" >&2; exit 1; }
  ' && echo "start-litellm inherits selected DOCKER_HOST" || true
  rm -f "$tmpenv"
  ```
- [ ] Commit:
  ```bash
  git add installer/lib/docker.sh installer/smoke/engine.sh
  git commit -m "fix(engine): export DOCKER_HOST at docker.sh source-time for standalone start-*.sh

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 8c — Phase-00 preflight: run selection+pin BEFORE any docker use

> **Why (spec Wiring + ARCH minor):** the spec requires "run selection before any docker use." Without it, a flow that runs Phase 04 (or a container) but not global selection first re-introduces the independent-choice split-brain, and doctor 01's ambient fallback reports a misleading green. This hook makes `AI_STACK_DOCKER_ENGINE` ALWAYS set before the first container/gateway touch.

**Files:**
- Modify: `installer/phases/00_host.sh` (preflight)
- Test: extend `installer/smoke/engine.sh`

**Steps:**

- [ ] Add a failing assertion that Phase 00 pins an engine into a throwaway `.env` when unset (NO_PROMPT → priority fallback), without touching docker:
  ```bash
  log "8c: phase 00 preflight selects + pins the engine when unset"
  grep -qE 'engine_select|ensure_docker_engine' "$AI_STACK/installer/phases/00_host.sh" \
    || { err "00_host.sh does not run engine selection in preflight"; exit 1; }
  ok "8c: phase 00 wires selection-before-use"
  ```
- [ ] Run it — expect FAIL (no selection hook in 00_host.sh yet):
  ```bash
  bash installer/smoke/engine.sh   # expect: "00_host.sh does not run engine selection in preflight" → exit 1
  ```
- [ ] Edit `installer/phases/00_host.sh` — after it sources env.sh + docker-engine.sh and BEFORE any `docker`/`ensure_*` call, add the selection+pin (idempotent: skips the prompt if `.env` already pins an installed engine):
  ```bash
  # Selection-before-use: pin the Docker engine before any docker call or Phase 04.
  # Idempotent — if .env already pins an installed engine, engine_select returns it
  # with no prompt. Honors a global --engine via AI_STACK_ENGINE_FLAG (Task 11a).
  if declare -F engine_select >/dev/null 2>&1; then
    _pf_sel="$(engine_select)" || { err "Phase 00: could not select a Docker engine"; exit 1; }
    engine_pin "$_pf_sel" || { err "Phase 00: could not pin engine '$_pf_sel'"; exit 1; }
    unset _pf_sel
  fi
  ```
  > This is the ONE place the global pin happens during install. Phase 04 (Task 12) is then read-only about selection. Confirm 00_host.sh sources docker-engine.sh (add `source "$AI_STACK/installer/lib/docker-engine.sh"` after its env.sh source if absent).
- [ ] Run it — expect PASS:
  ```bash
  bash installer/smoke/engine.sh   # expect: "8c: phase 00 wires selection-before-use", exit 0
  bash -n installer/phases/00_host.sh
  ```
- [ ] Commit:
  ```bash
  git add installer/phases/00_host.sh installer/smoke/engine.sh
  git commit -m "feat(engine): phase 00 preflight selects+pins the engine before any docker use

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 9 — `deps.sh`: `ensure_orbstack` → thin alias over `engine_ensure "$(engine_select)"` + `deps_report` socket triple

**Files:**
- Modify: `installer/lib/deps.sh` (162-177 `ensure_orbstack`; `deps_report` ~252-255)
- Test: extend `installer/smoke/engine.sh`

**Steps:**

- [ ] Add a failing assertion to `installer/smoke/engine.sh` (assert `ensure_orbstack` still exists as a callable name AND that `deps_report` mentions the selected engine — guarded so it doesn't actually install anything; we just grep the report text via a dry path):
  ```bash
  log "deps wiring: ensure_orbstack is an alias + deps_report shows engine"
  source "$AI_STACK/installer/lib/deps.sh"
  declare -F ensure_orbstack >/dev/null || { err "ensure_orbstack name removed (callers depend on it)"; exit 1; }
  declare -F ensure_docker_engine >/dev/null || { err "ensure_docker_engine undefined"; exit 1; }
  # Non-tautological: assert the UNIQUE sentinel the NEW block emits, NOT a broad
  # 'engine|socket' grep that the existing deps_report already satisfies. First
  # confirm the sentinel is absent on current main (so the test is genuinely red):
  #   grep -q 'Docker engine: orbstack' <(deps_report)  # must be EMPTY before the edit
  rep="$(AI_STACK_DOCKER_ENGINE=orbstack ENV_FILE="$ENV_FILE" bash -c '
    set -Eeuo pipefail; AI_STACK="'"$AI_STACK"'"
    source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
    source "$AI_STACK/installer/lib/docker-engine.sh"; source "$AI_STACK/installer/lib/deps.sh"
    set_env AI_STACK_DOCKER_ENGINE orbstack
    deps_report 2>&1 || true
  ')"
  grep -q "Docker engine: orbstack" <<<"$rep" \
    || { err "deps_report missing the 'Docker engine: orbstack' sentinel line"; exit 1; }
  grep -qE 'gateway\.env socket (==|!=) selected' <<<"$rep" \
    || { err "deps_report missing the gateway.env socket comparison line"; exit 1; }
  ok "deps wiring present (unique sentinels)"
  ```
- [ ] Run it — expect FAIL (`ensure_docker_engine` undefined AND the sentinel lines absent on current main):
  ```bash
  bash installer/smoke/engine.sh   # expect: ensure_docker_engine undefined / sentinel missing → exit 1
  ```
  > Confirm the chosen sentinel `Docker engine: orbstack` does NOT already appear in `deps_report` on current main (run the inline `deps_report` grep against main first). The deps_report block below prints `note "Docker engine: $_sel ..."` and `... "gateway.env socket == selected"` / `... != selected ...` — match those exact labels.
- [ ] Edit `installer/lib/deps.sh`: replace the body of `ensure_orbstack` (162-177) with the engine-aware version and add the alias. Replace lines 160-177 with:
  ```bash
  # ensure_docker_engine — select + ensure the intentional Docker engine.
  # Selection precedence handled by engine_select (flag/env/running/prompt/priority);
  # engine_ensure installs (consent/NO_PROMPT) + starts + bounded-waits on the socket;
  # engine_pin persists AI_STACK_DOCKER_ENGINE + exports DOCKER_HOST + rewrites gateway.env.
  ensure_docker_engine() {
    ensure_homebrew || return 1
    local sel; sel="$(engine_select)" || return 1
    engine_ensure "$sel" || return 1
    engine_pin "$sel" || return 1
    return 0
  }

  # ensure_orbstack — retained name for back-compat with existing callers
  # (phases 00/01, etc.). Now a thin wrapper that honors the selected engine.
  ensure_orbstack() { ensure_docker_engine "$@"; }
  ```
  > `engine_select`/`engine_ensure`/`engine_pin` are in scope: `deps.sh` is sourced by the same `mayssam-ai-stack.sh` path that sources `docker-engine.sh` (Task 8). For the standalone `deps`/phase entrypoints, add `source "$AI_STACK/installer/lib/docker-engine.sh"` near the top of `deps.sh` if it is not already transitively sourced — verify with `grep -n docker-engine installer/lib/deps.sh` and add if absent.
- [ ] Edit `deps_report` (find it: `grep -n 'deps_report()' installer/lib/deps.sh`) to print the selected engine + socket triple-equality. Append, just before its final summary/return, this block:
  ```bash
    # --- Docker engine selection ---------------------------------------------
    local _sel _sock _gw_host _ctx_host
    _sel="$(get_env AI_STACK_DOCKER_ENGINE "")"
    if [[ -n "$_sel" ]] && _engine_valid "$_sel"; then
      _sock="$(engine_socket "$_sel" 2>/dev/null || echo '?')"
      _ctx_host="$(docker context inspect "$(docker context show 2>/dev/null)" \
                     --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || echo '?')"
      _gw_host="$(grep -E '^DOCKER_HOST=' "$HOME/.config/openshell/gateway.env" 2>/dev/null | tail -1 | cut -d= -f2- || echo '?')"
      note "Docker engine: $_sel ($(engine_display "$_sel"))   socket: $_sock"
      [[ "$_ctx_host" == "$_sock" ]] && ok "  CLI context socket == selected" || warn "  CLI context socket ($_ctx_host) != selected ($_sock)"
      [[ "$_gw_host"  == "$_sock" ]] && ok "  gateway.env socket == selected" || warn "  gateway.env socket != selected ($_gw_host vs $_sock) — run: mayssam-ai-stack.sh doctor (check 47)"
    else
      warn "Docker engine: not selected — run: mayssam-ai-stack.sh docker-engine select"
    fi
  ```
- [ ] Run it — expect PASS:
  ```bash
  bash installer/smoke/engine.sh   # expect: "deps wiring present", exit 0
  ```
- [ ] Commit:
  ```bash
  git add installer/lib/deps.sh installer/smoke/engine.sh
  git commit -m "feat(engine): deps.sh — ensure_orbstack=alias over engine_ensure; deps_report socket triple

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 10 — `docker.sh`: append `engine_addhost_args` in `docker_run_managed` + make `probe_host_docker_internal` engine-aware

**Files:**
- Modify: `installer/lib/docker.sh` (92-102 `docker_run_managed`; 177-185 `probe_host_docker_internal`)
- Test: extend `installer/smoke/engine.sh` (assert the flag is present in the emitted command via a dry-run capture)

**Steps:**

- [ ] Add a failing assertion to `installer/smoke/engine.sh` that calls `docker_run_managed` with a stubbed `docker` to capture the args, asserting the add-host flag is engine-conditional:
  ```bash
  log "docker_run_managed appends engine_addhost_args for the selected engine"
  source "$AI_STACK/installer/lib/docker.sh"
  # Stub `docker` to echo its args instead of running.
  docker() { printf '%s\n' "$*"; }
  export -f docker 2>/dev/null || true
  # colima → MUST include host.docker.internal add-host
  out="$(AI_STACK_DOCKER_ENGINE=colima ENV_FILE="$ENV_FILE" bash -c '
    set -Eeuo pipefail; AI_STACK="'"$AI_STACK"'"
    source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
    source "$AI_STACK/installer/lib/docker-engine.sh"; source "$AI_STACK/installer/lib/docker.sh"
    docker() { printf "%s\n" "$*"; }
    set_env AI_STACK_DOCKER_ENGINE colima
    docker_run_managed t 99 alpine -- true
  ')"
  grep -q -- '--add-host=host.docker.internal:host-gateway' <<<"$out" \
    || { err "colima docker_run_managed missing host.docker.internal add-host: $out"; exit 1; }
  # orbstack → MUST NOT include it
  out="$(AI_STACK_DOCKER_ENGINE=orbstack bash -c '
    set -Eeuo pipefail; AI_STACK="'"$AI_STACK"'"
    e="$(mktemp)"; export ENV_FILE="$e"
    source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
    source "$AI_STACK/installer/lib/docker-engine.sh"; source "$AI_STACK/installer/lib/docker.sh"
    docker() { printf "%s\n" "$*"; }
    set_env AI_STACK_DOCKER_ENGINE orbstack
    docker_run_managed t 99 alpine -- true; rm -f "$e"
  ')"
  grep -q -- '--add-host=host.docker.internal' <<<"$out" \
    && { err "orbstack docker_run_managed should NOT add host.docker.internal: $out"; exit 1; } || true
  ok "docker_run_managed add-host is engine-conditional"
  ```
- [ ] Run it — expect FAIL (no add-host injected today):
  ```bash
  bash installer/smoke/engine.sh   # expect: "colima docker_run_managed missing host.docker.internal" → exit 1
  ```
- [ ] Edit `installer/lib/docker.sh` `docker_run_managed` (92-102) — compute the add-host args from the selected engine and inject between `--restart unless-stopped` and `"${env_args[@]}"`. Replace the `docker run -d \ … "${cmd_args[@]}"` block (92-102) with:
  ```bash
    # Engine-conditional host.docker.internal (Colima/Podman need it explicitly).
    local _eng _addhost=()
    _eng="$(get_env AI_STACK_DOCKER_ENGINE "")"
    if [[ -n "$_eng" ]] && declare -F engine_addhost_args >/dev/null 2>&1 && _engine_valid "$_eng" 2>/dev/null; then
      local _ah; _ah="$(engine_addhost_args "$_eng" 2>/dev/null || true)"
      [[ -n "$_ah" ]] && _addhost=("$_ah")
    fi

    docker run -d \
      --name "$name" \
      --label "ai-stack.managed=true" \
      --label "ai-stack.phase=$phase" \
      --label "ai-stack.partial=true" \
      --restart unless-stopped \
      "${_addhost[@]}" \
      "${env_args[@]}" \
      "${port_args[@]}" \
      "${vol_args[@]}" \
      "$image" \
      "${cmd_args[@]}"
  ```
  > `engine_addhost_args`/`_engine_valid`/`get_env` are in scope when `docker.sh` is sourced by `mayssam-ai-stack.sh` (after docker-engine.sh, Task 8). The `declare -F` guard keeps `docker_run_managed` safe if `docker.sh` is sourced standalone without docker-engine.sh.
- [ ] Edit `probe_host_docker_internal` (177-185) to be engine-aware. Replace its body with:
  ```bash
  probe_host_docker_internal() {
    local _eng _addhost=()
    _eng="$(get_env AI_STACK_DOCKER_ENGINE "")"
    if [[ -n "$_eng" ]] && declare -F engine_addhost_args >/dev/null 2>&1 && _engine_valid "$_eng" 2>/dev/null; then
      local _ah; _ah="$(engine_addhost_args "$_eng" 2>/dev/null || true)"
      [[ -n "$_ah" ]] && _addhost=("$_ah")
    fi
    if ! docker run --rm "${_addhost[@]}" alpine getent hosts host.docker.internal >/dev/null 2>&1; then
      err "host.docker.internal does not resolve from inside containers."
      err "This is required for LiteLLM → host Postgres/Phoenix and other paths."
      err "If you're on OrbStack/Docker Desktop: Settings → Network → ensure host networking is enabled."
      err "If you're on Colima/Podman: the host-dialing service (LiteLLM) injects"
      err "  --add-host=host.docker.internal:host-gateway from the engine registry."
      err "  Any OTHER container that needs it must add that flag to its own 'docker run'."
      return 1
    fi
    return 0
  }
  ```
- [ ] Run it — expect PASS:
  ```bash
  bash installer/smoke/engine.sh   # expect: "docker_run_managed add-host is engine-conditional", exit 0
  ```
- [ ] **Promote the live-path fix to first-class (was deferred — ARCH/INFRA major).** `docker_run_managed` is DEAD CODE (recon confirms zero callers; live services start via `bin/start-*.sh` with raw `docker run`). So the `docker_run_managed`/`probe` edits above are FORWARD-LOOKING — they do NOT reach a running container. SCOPE DECIDED NOW (verified by recon, not deferred to review):
  - Only services that dial `host.docker.internal` at runtime need the flag. **Recon result:** the ONLY start script that reaches `host.docker.internal` is `bin/start-litellm.sh` (Postgres at `host.docker.internal:5432`, lines 56/64/80) — and it **already** carries `--add-host=host.docker.internal:host-gateway` (line 167). The other five (`start-falkordb.sh:40`, `start-openwebui.sh:48`, `start-phoenix.sh:75`, `start-qdrant.sh:36`, `start-llm_guard.sh:40`) dial only `ollama` (via `--add-host=ollama:host-gateway`), NOT `host.docker.internal`, so they do NOT need it.
  - **Action:** make `bin/start-litellm.sh`'s add-host engine-derived rather than hardcoded, so it is correct on ALL engines (it currently always emits the flag, which is harmless on OrbStack/DD but should be sourced from the registry for honesty + future services). Source `docker-engine.sh` in start-litellm.sh and inject `$(engine_addhost_args "$(get_env AI_STACK_DOCKER_ENGINE orbstack)")`. Add a smoke assertion that greps the emitted `docker run` line of `start-litellm.sh` under a stubbed docker for the flag on colima and its ABSENCE-as-redundant-but-present on orbstack (the literal token is fine either way; assert the flag is present for colima):
  ```bash
  log "10b: start-litellm.sh carries host.docker.internal add-host on colima (live path)"
  d=$(mktemp -d); printf '#!/usr/bin/env bash\necho "$@"\nexit 0\n' >"$d/docker"; chmod +x "$d/docker"
  tmpenv="$(mktemp)"; printf 'AI_STACK_DOCKER_ENGINE=colima\n' > "$tmpenv"
  out="$(PATH="$d:$PATH" ENV_FILE="$tmpenv" bash "$AI_STACK/bin/start-litellm.sh" 2>&1 || true)"
  rm -f "$tmpenv"; rm -rf "$d"
  grep -q -- '--add-host=host.docker.internal:host-gateway' <<<"$out" \
    || { err "start-litellm.sh missing host.docker.internal add-host on colima"; exit 1; }
  ok "10b: live start-litellm.sh carries the engine add-host"
  ```
  > The five `ollama`-only start scripts are explicitly OUT of scope (they do not dial `host.docker.internal`). If a future service starts dialing it, route it through `engine_addhost_args` at that time. The `docker_run_managed`/`probe` edits remain as forward-looking correctness for any future managed run, but the LIVE guarantee is carried by start-litellm.sh. This sub-step is NOT deferred — it lands in Task 10.
- [ ] Commit:
  ```bash
  git add installer/lib/docker.sh bin/start-litellm.sh installer/smoke/engine.sh
  git commit -m "feat(engine): docker.sh engine-conditional add-host + start-litellm.sh live add-host (TDD)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 11a — Global `--engine <id>` argv plumbing (top-precedence input)

> **Why (ARCH major):** the spec lists `--engine <id>` as the top precedence input, but `engine_select` only reads `AI_STACK_ENGINE_FLAG`. Without a single argv→env translation site, `mayssam-ai-stack.sh install --engine colima` has no path from argv to the flag. Wire it ONCE in the top-level parser so install/deps/phase-04/00 all honor it via the single `engine_select` path.

**Files:**
- Modify: `mayssam-ai-stack.sh` (top-level arg parse, ~line 105)
- Test: extend `installer/smoke/engine.sh`

**Steps:**

- [ ] Add a failing assertion that a global `--engine <id>` reaches `engine_select` via `AI_STACK_ENGINE_FLAG` (use the `__print-docker-host` seam with an empty `.env`, so ONLY the flag can resolve the socket):
  ```bash
  log "11a: global --engine <id> argv → AI_STACK_ENGINE_FLAG → engine_select"
  tmpenv="$(mktemp)"; printf 'AI_STACK_DOCKER_ENGINE=\n' > "$tmpenv"
  got="$(env -u DOCKER_HOST ENV_FILE="$tmpenv" bash "$AI_STACK/mayssam-ai-stack.sh" --engine orbstack __print-docker-host 2>/dev/null || true)"
  rm -f "$tmpenv"
  grep -q "DOCKER_HOST=unix://$HOME/.orbstack/run/docker.sock" <<<"$got" \
    || { err "global --engine flag not plumbed to AI_STACK_ENGINE_FLAG/engine_select: $got"; exit 1; }
  ok "11a: global --engine argv plumbed"
  ```
  > For the seam to honor the flag, the central export (Task 8) must consult `AI_STACK_ENGINE_FLAG` first when `AI_STACK_DOCKER_ENGINE` is empty — i.e. it should derive its engine via `engine_select` (flag-aware) rather than `get_env` alone. Adjust the Task 8 export block to: `_ai_stack_engine="${AI_STACK_ENGINE_FLAG:-$(get_env AI_STACK_DOCKER_ENGINE "")}"` (still no-op when both empty). Make that one-line adjustment as part of 11a and re-run Task 8's assertion to confirm no regression.
- [ ] Run it — expect FAIL (`--engine` not parsed):
  ```bash
  bash installer/smoke/engine.sh   # expect: "global --engine flag not plumbed" → exit 1
  ```
- [ ] Edit `mayssam-ai-stack.sh` top-level arg parse (before the subcommand dispatch, ~line 105). Add a pre-scan that extracts a global `--engine <id>` / `--engine=<id>` from `"$@"`, exports `AI_STACK_ENGINE_FLAG`, and strips it from the args so the subcommand dispatch is unaffected:
  ```bash
  # Global --engine <id> → AI_STACK_ENGINE_FLAG (single argv→env translation site).
  # Honored by install/deps/phase-00/04 through the one engine_select path.
  _vz_args=(); while (( $# )); do
    case "$1" in
      --engine) shift; export AI_STACK_ENGINE_FLAG="${1:-}";;
      --engine=*) export AI_STACK_ENGINE_FLAG="${1#--engine=}";;
      *) _vz_args+=("$1");;
    esac
    shift
  done
  set -- "${_vz_args[@]:-}"
  ```
  > Place this AFTER the central export block ONLY IF the export reads the flag (it does, per the adjustment above) — actually place it BEFORE the central export so the flag is set when the export's `engine_select` runs. Verify ordering: arg-parse `--engine` → export `AI_STACK_ENGINE_FLAG` → central `DOCKER_HOST` export (Task 8). The `${_vz_args[@]:-}` guard keeps `set -u` happy on an empty arg list.
- [ ] Run it — expect PASS:
  ```bash
  bash installer/smoke/engine.sh   # expect: "11a: global --engine argv plumbed", exit 0
  bash mayssam-ai-stack.sh --engine orbstack doctor 2>&1 | tail -3   # flag accepted, doctor still runs
  ```
- [ ] Commit:
  ```bash
  git add mayssam-ai-stack.sh installer/smoke/engine.sh
  git commit -m "feat(engine): global --engine <id> argv → AI_STACK_ENGINE_FLAG (single plumbing site)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 11 — `mayssam-ai-stack.sh` subcommand `docker-engine [status|select|set <id>]` + help

**Files:**
- Modify: `mayssam-ai-stack.sh` (246-248 `is_subcommand`; ~583 handler; 1037-1040 dispatch; 170-183 usage heredoc)
- Test: extend `installer/smoke/engine.sh` (the deferred Task 8 assertion now turns green)

**Steps:**

- [ ] The deferred assertion from Task 8 (`docker-engine status` prints resolved `DOCKER_HOST`) is the failing test. Run the whole smoke — expect FAIL (`Unknown command: docker-engine`):
  ```bash
  bash installer/smoke/engine.sh   # expect: "central export not wired" or "Unknown command: docker-engine" → exit 1
  ```
- [ ] Add the `docker-engine` sub-verb dispatcher to the END of `installer/lib/docker-engine.sh` (so the same file is both library and CLI entrypoint — matches fleet.sh shape). Append:
  ```bash
  # --- CLI entrypoint: docker-engine [status|select|set <id>] -----------------
  _engine_usage() {
    cat >&2 <<'EOF'
docker-engine — intentional Docker engine selection (orbstack|docker-desktop|colima|podman)
  mayssam-ai-stack.sh docker-engine status            show selected engine, resolved socket, CLI/gateway consistency
  mayssam-ai-stack.sh docker-engine select [--engine <id>]   (re-)select + ensure + pin the engine
  mayssam-ai-stack.sh docker-engine set <id>          set the engine to <id> explicitly (ensure + pin)
EOF
  }

  _engine_status() {
    local sel; sel="$(get_env AI_STACK_DOCKER_ENGINE "")"
    if [[ -z "$sel" ]]; then
      warn "no engine selected (AI_STACK_DOCKER_ENGINE unset). Run: mayssam-ai-stack.sh docker-engine select"
      return 1
    fi
    _engine_valid "$sel" || { err "AI_STACK_DOCKER_ENGINE='$sel' is invalid (want: $ENGINE_IDS)"; return 1; }
    local sock; sock="$(engine_socket "$sel" 2>/dev/null || echo '?')"
    note "engine:      $sel ($(engine_display "$sel"))"
    note "DOCKER_HOST: $sock"
    engine_running "$sel" && ok "daemon:      reachable" || warn "daemon:      NOT reachable (run: mayssam-ai-stack.sh docker-engine select)"
    local gw; gw="$(grep -E '^DOCKER_HOST=' "$HOME/.config/openshell/gateway.env" 2>/dev/null | tail -1 | cut -d= -f2- || echo '?')"
    [[ "$gw" == "$sock" ]] && ok "gateway.env: == selected" || warn "gateway.env: $gw (!= $sock)"
    return 0
  }

  # Only run the CLI dispatch when executed directly (bash docker-engine.sh ...),
  # NOT when sourced by mayssam-ai-stack.sh.
  if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    _de_main() {
      local sub="${1:-}"; shift || true
      case "$sub" in
        status) _engine_status ;;
        select)
          # Accept BOTH `--engine <id>` (space) and `--engine=<id>`, plus a bare
          # positional <id>. Implement the shift-latch for the space form.
          local flag="" expect_engine=0
          for a in "$@"; do
            if (( expect_engine )); then flag="$a"; expect_engine=0; continue; fi
            case "$a" in
              --engine)   expect_engine=1 ;;             # next token is the value
              --engine=*) flag="${a#--engine=}" ;;
              -*) err "docker-engine select: unknown flag: $a"; exit 2 ;;
              *) [[ -z "$flag" ]] && flag="$a" || { err "docker-engine select: too many args"; exit 2; } ;;
            esac
          done
          (( expect_engine )) && { err "docker-engine select: --engine needs an <id>"; exit 2; }
          local sel; sel="$(AI_STACK_ENGINE_FLAG="$flag" engine_select)" || exit $?
          engine_ensure "$sel" || exit $?
          engine_pin "$sel" || exit $?
          ;;
        set)
          local id="${1:-}"
          [[ -n "$id" ]] || { err "docker-engine set: missing <id> (want: $ENGINE_IDS)"; exit 2; }
          _engine_valid "$id" || { err "docker-engine set: invalid id '$id' (want: $ENGINE_IDS)"; exit 2; }
          engine_ensure "$id" || exit $?
          engine_pin "$id" || exit $?
          ;;
        ""|-h|--help|help) _engine_usage ;;
        *) err "docker-engine: unknown subcommand '$sub' (want status|select|set)"; exit 2 ;;
      esac
    }
    _de_main "$@"
  fi
  ```
- [ ] Add the handler in `mayssam-ai-stack.sh` near line 582 (after `cmd_fleet`):
  ```bash
  cmd_docker_engine() { bash "$AI_STACK/installer/lib/docker-engine.sh" "$@"; }
  ```
- [ ] Add the dispatch arm in the `case "$cmd"` block (after `fleet)` at line 1038):
  ```bash
      docker-engine)     cmd_docker_engine "$@" ;;
  ```
- [ ] Add `docker-engine` to `is_subcommand` (line 248) — extend the allowlist line:
  ```bash
      tutorial-serve|fleet-studio|reset|start|run|enable|stop|disable|docker-engine|help) return 0 ;;
  ```
- [ ] Add usage prose to the `usage()` heredoc (after the `fleet destroy` block, before `doctor` at line 184), indented exactly 4 spaces:
  ```
    mayssam-ai-stack.sh docker-engine status     show the selected Docker engine + resolved socket
                                        + CLI/gateway consistency
    mayssam-ai-stack.sh docker-engine select [--engine <id>]   (re-)select + ensure + pin the engine
                                        (orbstack|docker-desktop|colima|podman); idempotent
    mayssam-ai-stack.sh docker-engine set <id>   pin the engine explicitly to <id> (ensure + pin)
  ```
- [ ] Add smoke assertions for BOTH `--engine` forms + the `help docker-engine` routing (real assertions, not eyeballed). First read `installer/lib/help.sh` to confirm how `help <verb>` dispatches (Task 15 claims no help.sh change is needed — make that claim evidence-based here):
  ```bash
  log "11: docker-engine select accepts --engine colima AND --engine=colima (no daemon: assert parse, not pin)"
  # Parse-only: feed an UNINSTALLED engine so engine_ensure fails fast under NO_PROMPT,
  # but the flag must have been parsed (error mentions the engine, not 'needs an <id>').
  for form in "--engine colima" "--engine=colima"; do
    out="$(NO_PROMPT=1 bash "$AI_STACK/installer/lib/docker-engine.sh" select $form 2>&1 || true)"
    grep -q 'needs an <id>' <<<"$out" && { err "select misparsed '$form' (treated --engine as no-op)"; exit 1; }
  done
  ok "11: both --engine forms parse"

  log "11: help docker-engine routes to usage (not services.yml service-help)"
  out="$(bash "$AI_STACK/mayssam-ai-stack.sh" help docker-engine 2>&1 || true)"
  grep -q 'docker-engine select' <<<"$out" \
    || { err "help docker-engine did not route to docker-engine usage: $out"; exit 1; }
  ok "11: help docker-engine routes correctly"
  ```
- [ ] Run it — expect PASS (the Task 8 deferred assertion + the new subcommand both green):
  ```bash
  bash installer/smoke/engine.sh                 # expect exit 0 (all assertions)
  bash mayssam-ai-stack.sh docker-engine --help       # expect the 3-line usage to STDERR
  bash mayssam-ai-stack.sh help docker-engine         # expect the docker-engine usage (verified by the assertion above)
  ```
  > If `help docker-engine` falls through to a services.yml lookup that errors instead of routing to usage, add the routing in `installer/lib/help.sh` in THIS task (not Task 15) and update Task 15's "no help.sh change" claim accordingly. The assertion above makes the routing a hard gate.
- [ ] Commit:
  ```bash
  git add mayssam-ai-stack.sh installer/lib/docker-engine.sh installer/smoke/engine.sh
  git commit -m "feat(engine): mayssam-ai-stack.sh docker-engine [status|select|set] subcommand + help

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 12 — Phase 04: replace OrbStack hardcode with `engine_socket "$selected"` + split-brain-guarded gateway restart

**Files:**
- Modify: `installer/phases/04_openshell.sh` (220-244 socket derivation; 250-271 restart branch)
- Test: extend `installer/smoke/engine.sh` (assert the gateway.env DOCKER_HOST is derived from the selected engine; guard the restart behind the `_others` Ready check)

**Steps:**

- [ ] Add failing assertions to `installer/smoke/engine.sh`. TWO assertions: (1) grep-proof the hardcode is gone + helper is used; (2) BEHAVIORAL — extract the write to a callable and prove it writes the SELECTED engine's socket into a THROWAWAY gateway file (honoring `ENGINE_GATEWAY_ENV_FILE`), not just that the source text changed:
  ```bash
  log "phase 04: hardcode gone, engine registry + single gateway writer used"
  grep -q 'engine_write_gateway_env\|engine_socket' "$AI_STACK/installer/phases/04_openshell.sh" \
    || { err "04_openshell.sh does not call engine_socket/engine_write_gateway_env"; exit 1; }
  grep -q 'ORB_SOCK="\$HOME/.orbstack/run/docker.sock"' "$AI_STACK/installer/phases/04_openshell.sh" \
    && { err "04_openshell.sh still hardcodes ORB_SOCK"; exit 1; } || true
  # Read-only selection: phase must NOT perform a hidden global pin; it errors if unset.
  grep -qE 'docker-engine select first|run .*docker-engine select' "$AI_STACK/installer/phases/04_openshell.sh" \
    || { err "04_openshell.sh should ERROR (not hidden-pin) when engine unset"; exit 1; }
  ok "phase 04 uses engine registry + read-only selection"

  log "phase 04 BEHAVIORAL: engine_write_gateway_env writes selected socket to throwaway gateway.env"
  GW2="$(mktemp -t aistack-gw04.XXXXXX)"; trap 'rm -f "$ENV_FILE" "$GW" "$GW2"' EXIT
  # The phase's writer is the shared helper — prove the contract directly + against a throwaway file.
  ENGINE_GATEWAY_ENV_FILE="$GW2" engine_write_gateway_env orbstack || true
  grep -qx "DOCKER_HOST=unix://$HOME/.orbstack/run/docker.sock" "$GW2" \
    || { err "phase-04 gateway writer did not write selected socket: $(cat "$GW2")"; exit 1; }
  ok "phase 04 gateway.env derivation behavioral-verified (throwaway file)"
  ```
- [ ] Run it — expect FAIL (hardcode still present, no read-only guard):
  ```bash
  bash installer/smoke/engine.sh   # expect: "04_openshell.sh does not call engine_socket/engine_write_gateway_env" → exit 1
  ```
- [ ] Edit `installer/phases/04_openshell.sh`: ensure the registry is sourced (add `source "$AI_STACK/installer/lib/docker-engine.sh"` after its env.sh source if not already). Set `GATEWAY_ENV_FILE` from a single overridable var that the helper also honors so tests never touch the real file:
  ```bash
  # Throwaway-safe gateway path: one overridable var shared with engine_write_gateway_env.
  GATEWAY_ENV_FILE="${ENGINE_GATEWAY_ENV_FILE:-${GATEWAY_ENV_FILE:-$HOME/.config/openshell/gateway.env}}"
  export ENGINE_GATEWAY_ENV_FILE="$GATEWAY_ENV_FILE"   # so engine_write_gateway_env writes the same file
  ```
  Then replace lines ~220-244 (the `ORB_SOCK` … gateway.env write) with a **read-only selection** + the SINGLE writer (no second heredoc):
  ```bash
  # Read-only about selection: Phase 00 preflight (Task 8c) already selected+pinned.
  # Do NOT perform a hidden global pin deep inside this phase.
  _selected="$(get_env AI_STACK_DOCKER_ENGINE "")"
  if [[ -z "$_selected" ]] || ! _engine_valid "$_selected"; then
    err "Phase 04: no Docker engine selected. Run: mayssam-ai-stack.sh docker-engine select first"
    exit 1
  fi
  DESIRED_DOCKER_HOST="$(engine_socket "$_selected")" || {
    err "Phase 04: could not resolve socket for engine '$_selected' — is the daemon up?"; exit 1; }

  # SINGLE writer (shared with engine_pin) — returns 0 if it changed gateway.env, 1 if not.
  _gw_changed=0
  if engine_write_gateway_env "$_selected" "$GATEWAY_ENV_FILE"; then
    _gw_changed=1
    ok "wrote $GATEWAY_ENV_FILE (engine=$_selected, host=$DESIRED_DOCKER_HOST)"
  else
    ok "gateway env file already configured: $GATEWAY_ENV_FILE"
  fi
  ```
  > NOTE (completeness): the OLD `ORB_SOCK`/`/var/run/docker.sock` ambient-`DOCKER_HOST` fallback is INTENTIONALLY removed — selection is now explicit (Phase 00). A cold/un-pinned box errors with the `docker-engine select` guidance instead of silently using `/var/run/docker.sock`. This is a deliberate behavior change; the adversarial reviewer (Task 16) must check the cold/un-pinned phase-04 path. Confirm the exact range against the LIVE file — `ORB_SOCK` block + fallback ≈ L220-230 and the gateway-write block ≈ L231-244; do NOT blindly delete adjacent logic.
- [ ] Edit the restart branch (250-271): force a restart when `_gw_changed=1`, split-brain-guarded by REUSING the CANONICAL `lib/openshell.sh` `_others` guard (sourced — NOT a weaker re-implemented awk that drops `_osh_strip_ansi`/`$1!=n`) AND checkpointing every Ready sandbox before restart. Replace the `started|scheduled)` arm with:
  ```bash
      started|scheduled)
        if [[ "${_gw_changed:-0}" == "1" ]]; then
          # DOCKER_HOST changed under a running gateway — it only re-reads gateway.env
          # at launch, so a restart is REQUIRED. A restart errors ALL sandboxes
          # (rotates signing kid). Reuse the CANONICAL guard (ANSI-strip + self-exclude).
          source "$AI_STACK/installer/lib/openshell.sh"   # canonical _osh_strip_ansi + Ready guard
          local _others
          _others="$("$OSH" sandbox list 2>/dev/null | _osh_strip_ansi \
                      | awk 'NR>1 && $NF=="Ready"{print $1}' | tr '\n' ' ' || true)"
          if [[ -n "${_others// }" && "${OPENSHELL_FORCE_GATEWAY_RESTART:-0}" != "1" ]]; then
            warn "gateway DOCKER_HOST changed but Ready sandbox(es) exist: ${_others% }"
            warn "NOT restarting (would error them ALL). A restart is PENDING — doctor will surface it."
            warn "Apply intentionally with: OPENSHELL_FORCE_GATEWAY_RESTART=1 mayssam-ai-stack.sh install 04"
          else
            warn "gateway DOCKER_HOST changed → restarting openshell (all sandboxes will re-auth)."
            # Checkpoint EVERY Ready sandbox (fail-closed) BEFORE the auth-rotating restart,
            # in addition to the identity-backup — fleet-durability HALT-by-default contract.
            if [[ -x "$AI_STACK/bin/openshell-checkpoint.sh" ]]; then
              local _s
              for _s in ${_others}; do
                bash "$AI_STACK/bin/openshell-checkpoint.sh" "$_s" >/dev/null 2>&1 \
                  || { err "checkpoint of sandbox '$_s' FAILED — aborting restart (fail-closed)."; exit 1; }
              done
            fi
            [[ -x "$AI_STACK/bin/openshell-identity-backup.sh" ]] \
              && bash "$AI_STACK/bin/openshell-identity-backup.sh" backup >/dev/null 2>&1 || true
            brew services stop openshell 2>&1 | tail -2 || true
            launchctl bootout "gui/$(id -u)/homebrew.mxcl.openshell" 2>/dev/null || true
            sleep 1
            brew services start openshell 2>&1 | tail -3 || warn "brew services start openshell failed"
            local _i=0; while (( _i < 60 )); do gateway_listening && break; sleep 1; _i=$((_i+1)); done
            # Verify the wrapper (which re-sources gateway.env) is the launched program.
            ps -Ao command 2>/dev/null | grep -q 'openshell-gateway-homebrew-service' \
              && ok "gateway wrapper relaunched (will have re-sourced gateway.env)" \
              || warn "could not confirm gateway wrapper is the launched program — verify gateway picked up the new DOCKER_HOST"
          fi
        else
          ok "openshell brew service is $state"
        fi
        ;;
  ```
  > `$OSH` is the brew binary path used elsewhere in the phase; confirm with `grep -n 'OSH=' installer/phases/04_openshell.sh` and reuse the existing var. `bin/openshell-checkpoint.sh <name>` arg form: confirm the script's invocation signature with `grep -n 'usage\|"\$1"' bin/openshell-checkpoint.sh` and match it (it checkpoints a named sandbox; fail-closed if the arg form differs). The `ps`-confirm addresses the INFRA finding that a `brew services` restart must be empirically shown to relaunch the wrapper that re-sources gateway.env (per the Ollama plist-regen gotcha).
- [ ] Add an INTEGRATION smoke that simulates a Ready sandbox to prove the guard REFUSES (QA missing coverage). This stubs `$OSH sandbox list` to emit a colorized `Ready` row and asserts NO restart fires without the override:
  ```bash
  log "phase 04 guard: colorized Ready sandbox → restart REFUSED (not the destroy-both bug)"
  # Feed a colorized fixture to the canonical guard and assert it DETECTS Ready.
  source "$AI_STACK/installer/lib/openshell.sh"
  fixture=$'NAME   PHASE\nsbx-1  \x1b[32mReady\x1b[0m\n'
  det="$(printf '%s' "$fixture" | _osh_strip_ansi | awk 'NR>1 && $NF=="Ready"{print $1}')"
  [[ "$det" == "sbx-1" ]] || { err "canonical guard failed to detect colorized Ready (det='$det')"; exit 1; }
  ok "phase 04 guard detects colorized Ready sandbox"
  ```
- [ ] Run it — expect PASS:
  ```bash
  bash installer/smoke/engine.sh   # expect: phase 04 assertions green
  bash -n installer/phases/04_openshell.sh   # syntax check the phase
  ```
- [ ] Commit:
  ```bash
  git add installer/phases/04_openshell.sh installer/smoke/engine.sh
  git commit -m "feat(engine): phase 04 read-only-select + single gateway writer + canonical Ready guard + checkpoint-before-restart

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 12b — Make the OpenShell durability bin scripts engine-aware (highest data-loss path)

> **Why (ARCH/INFRA critical):** `bin/openshell-checkpoint.sh`, `-state-restore.sh`, `-watchdog.sh`, `-token-refresh.sh` self-resolve `DOCKER="$(_find /opt/homebrew/bin/docker "$HOME/.orbstack/bin/docker" /usr/local/bin/docker)"` and bake the OrbStack socket into the watchdog launchd plist PATH. They run via launchd / standalone and do NOT source `mayssam-ai-stack.sh`, so the central export never reaches them. On a Docker-Desktop/Colima/Podman box they would operate on a DIFFERENT engine than the gateway was pinned to — split-brain in the checkpoint/restore data-loss path. (Confirmed: lines `checkpoint:41`, `state-restore:43`, `watchdog:59`, `token-refresh:59`; watchdog plist PATH at `watchdog:87`.)

**Files:**
- Modify: `bin/openshell-checkpoint.sh`, `bin/openshell-state-restore.sh`, `bin/openshell-watchdog.sh`, `bin/openshell-token-refresh.sh`
- Test: extend `installer/smoke/engine.sh`

**Steps:**

- [ ] Add a failing assertion that each script exports `DOCKER_HOST` from the selected engine (or from gateway.env) before invoking docker:
  ```bash
  log "12b: openshell-* bin scripts are engine-aware (export DOCKER_HOST from selection/gateway.env)"
  for s in openshell-checkpoint openshell-state-restore openshell-watchdog openshell-token-refresh; do
    grep -qE 'AI_STACK_DOCKER_ENGINE|engine_socket|gateway\.env.*DOCKER_HOST|DOCKER_HOST=.*gateway' \
      "$AI_STACK/bin/$s.sh" \
      || { err "$s.sh is NOT engine-aware (still assumes OrbStack socket/binary)"; exit 1; }
  done
  ok "12b: openshell durability scripts derive DOCKER_HOST from the selected engine"
  ```
- [ ] Run it — expect FAIL (scripts still hardcode OrbStack):
  ```bash
  bash installer/smoke/engine.sh   # expect: "openshell-checkpoint.sh is NOT engine-aware" → exit 1
  ```
- [ ] In EACH of the four scripts, immediately AFTER the `DOCKER="$(_find …)"` line, add an engine-aware `DOCKER_HOST` resolution (no source cycle: prefer reading the gateway.env they already depend on; fall back to the registry if `AI_STACK` is set and the lib is present). Add:
  ```bash
  # Engine-aware: do NOT assume OrbStack. Prefer the gateway.env DOCKER_HOST (the
  # gateway's own source of truth); fall back to the registry from AI_STACK_DOCKER_ENGINE.
  if [[ -z "${DOCKER_HOST:-}" ]]; then
    _gw_dh="$(grep -E '^DOCKER_HOST=' "$HOME/.config/openshell/gateway.env" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
    if [[ -n "${_gw_dh:-}" ]]; then
      export DOCKER_HOST="$_gw_dh"
    elif [[ -n "${AI_STACK:-}" && -f "$AI_STACK/installer/lib/docker-engine.sh" ]]; then
      # shellcheck disable=SC1090
      source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
      source "$AI_STACK/installer/lib/docker-engine.sh"
      _eng="$(get_env AI_STACK_DOCKER_ENGINE "" 2>/dev/null || true)"
      if [[ -n "${_eng:-}" ]] && _engine_valid "$_eng" 2>/dev/null; then
        _dh="$(engine_socket "$_eng" 2>/dev/null || true)"; [[ -n "${_dh:-}" ]] && export DOCKER_HOST="$_dh"
      fi
    fi
    unset _gw_dh _eng _dh 2>/dev/null || true
  fi
  ```
  > gateway.env is the right primary source here precisely because these scripts manage the GATEWAY's sandboxes — they must talk to the SAME engine the gateway uses, which is exactly what gateway.env's `DOCKER_HOST` records. The registry fallback covers the case where gateway.env is absent but `.env` is pinned.
- [ ] For `bin/openshell-watchdog.sh` ALSO derive the launchd plist PATH candidate from the selected engine instead of hardcoding `~/.orbstack/bin`. Where the plist PATH is built (line ~87, the `${DOCKER:+$(dirname "$DOCKER"):}…` string), ensure `_find` includes the selected engine's CLI dir; since `DOCKER` is already resolved via `_find` over `/opt/homebrew/bin` first (engine-agnostic — Docker Desktop/Colima/Podman all install the `docker` CLI to `/opt/homebrew/bin`), confirm `/opt/homebrew/bin` precedes `~/.orbstack/bin` in the `_find` list (it does) and add a comment that the CLI is engine-agnostic while DOCKER_HOST (above) selects the engine. No behavior change needed beyond the comment IF `/opt/homebrew/bin/docker` exists on all four engines — verify and note.
- [ ] Run it — expect PASS:
  ```bash
  bash installer/smoke/engine.sh   # expect: "12b: openshell durability scripts derive DOCKER_HOST…", exit 0
  for s in checkpoint state-restore watchdog token-refresh; do bash -n "$AI_STACK/bin/openshell-$s.sh"; done
  ```
- [ ] Commit:
  ```bash
  git add bin/openshell-checkpoint.sh bin/openshell-state-restore.sh bin/openshell-watchdog.sh bin/openshell-token-refresh.sh installer/smoke/engine.sh
  git commit -m "fix(engine): make openshell durability scripts engine-aware (DOCKER_HOST from gateway.env/registry)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 13 — Doctor check 01 (selected engine reachable) + check 02 (engine-aware host.docker.internal)

**Files:**
- Modify: `installer/doctor/checks/01_orbstack_running.sh`
- Modify: `installer/doctor/checks/02_host_docker_internal.sh`

**Steps:**

- [ ] FAILING-TEST-FIRST (TDD — the user's prompt requires 01/02 to be TDD'd). Add assertions to `installer/smoke/engine.sh` that source each rewritten check file and drive its `*_diagnose` with CONTROLLED state. Run these RED before the rewrite (the current checks have no `engine_*` awareness so they fail these specific contracts):
  ```bash
  log "13: doctor check 01 — pinned-but-unreachable engine → non-zero + message"
  ( set -Eeuo pipefail; AI_STACK="$AI_STACK"; ENV_FILE="$(mktemp)"
    source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
    source "$AI_STACK/installer/lib/docker.sh"
    declare -a CHECKS; declare -A CHECK_TITLE
    source "$AI_STACK/installer/doctor/checks/01_orbstack_running.sh"
    # Pin a valid engine and stub engine_running to fail → diagnose must return non-zero.
    set_env AI_STACK_DOCKER_ENGINE orbstack
    engine_running() { return 1; }
    out="$(orbstack_running_diagnose 2>&1)"; rc=$?
    [[ $rc -ne 0 ]] || { echo "01 diagnose should fail when selected engine unreachable" >&2; exit 1; }
    grep -qi 'not reachable\|selected engine' <<<"$out" || { echo "01 message missing: $out" >&2; exit 1; }
    rm -f "$ENV_FILE"
  ) || { err "doctor 01 pinned-unreachable path failed"; exit 1; }
  ok "13: doctor 01 pinned-unreachable path correct"

  log "13: doctor check 01 — no engine pinned → legacy ambient fallback returns 0 when docker info works"
  ( set -Eeuo pipefail; AI_STACK="$AI_STACK"; ENV_FILE="$(mktemp)"
    source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"; source "$AI_STACK/installer/lib/docker.sh"
    declare -a CHECKS; declare -A CHECK_TITLE
    source "$AI_STACK/installer/doctor/checks/01_orbstack_running.sh"
    set_env AI_STACK_DOCKER_ENGINE ""
    docker() { [[ "$1" == info ]] && return 0; command docker "$@"; }
    orbstack_running_diagnose >/dev/null 2>&1 || { echo "01 legacy fallback should be green when docker info works" >&2; exit 1; }
    rm -f "$ENV_FILE"
  ) || { err "doctor 01 no-engine legacy fallback failed"; exit 1; }
  ok "13: doctor 01 legacy fallback correct"

  log "13: doctor check 02 — colima diagnose builds the --add-host arg (capture via docker stub)"
  ( set -Eeuo pipefail; AI_STACK="$AI_STACK"; ENV_FILE="$(mktemp)"
    source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"; source "$AI_STACK/installer/lib/docker.sh"
    declare -a CHECKS; declare -A CHECK_TITLE
    source "$AI_STACK/installer/doctor/checks/02_host_docker_internal.sh"
    set_env AI_STACK_DOCKER_ENGINE colima
    captured=""; docker() { captured="$*"; echo "$captured" >"$ENV_FILE.args"; return 0; }
    host_docker_internal_diagnose >/dev/null 2>&1 || true
    grep -q -- '--add-host=host.docker.internal:host-gateway' "$ENV_FILE.args" \
      || { echo "02 colima diagnose did not pass the add-host flag to docker" >&2; exit 1; }
    rm -f "$ENV_FILE" "$ENV_FILE.args"
  ) || { err "doctor 02 colima add-host path failed"; exit 1; }
  ok "13: doctor 02 engine-aware add-host path correct"
  ```
- [ ] Run it — expect FAIL (current 01/02 are not engine-aware):
  ```bash
  bash installer/smoke/engine.sh   # expect: "doctor 01 pinned-unreachable path failed" → exit 1
  ```
- [ ] Rewrite `installer/doctor/checks/01_orbstack_running.sh` to probe the *selected* engine's socket (complete file — the check files are sourced by doctor.sh which already sourced common.sh + env.sh + docker.sh; source docker-engine.sh lazily inside the function via `$AI_STACK`):
  ```bash
  # Selected Docker engine reachable.
  CHECKS+=(orbstack_running)
  CHECK_TITLE[orbstack_running]="Selected Docker engine reachable"

  orbstack_running_diagnose() {
    source "$AI_STACK/installer/lib/docker-engine.sh"
    local sel; sel="$(get_env AI_STACK_DOCKER_ENGINE "")"
    if [[ -z "$sel" ]]; then
      # No selection yet: fall back to the legacy any-daemon probe so a
      # fresh/local-only box is not red before first selection — but WARN loudly
      # that an unpinned engine is a split-brain risk (selection should have run
      # in Phase 00 preflight). Not a hard failure (return 0) so a brand-new box
      # is not red, but the message is a hard warn, not a silent green.
      docker info >/dev/null 2>&1 || { echo "no engine selected and docker info failed (run: mayssam-ai-stack.sh docker-engine select)"; return 1; }
      echo "WARN: no engine pinned (AI_STACK_DOCKER_ENGINE empty) — split-brain risk; ambient docker reachable. Pin: mayssam-ai-stack.sh docker-engine select"
      return 0
    fi
    _engine_valid "$sel" || { echo "AI_STACK_DOCKER_ENGINE='$sel' invalid"; return 1; }
    if ! engine_running "$sel"; then
      echo "selected engine '$sel' ($(engine_display "$sel")) not reachable on $(engine_socket "$sel" 2>/dev/null || echo '?')"
      return 1
    fi
  }

  orbstack_running_fix() {
    source "$AI_STACK/installer/lib/docker-engine.sh"
    local sel; sel="$(get_env AI_STACK_DOCKER_ENGINE "")"
    [[ -n "$sel" ]] || sel="$(engine_select)" || return 1
    engine_ensure "$sel" || return 1
    engine_pin "$sel" || return 1
  }
  ```
- [ ] Rewrite `installer/doctor/checks/02_host_docker_internal.sh` to be engine-aware (complete file):
  ```bash
  # host.docker.internal resolves from inside containers (engine-aware).
  CHECKS+=(host_docker_internal)
  CHECK_TITLE[host_docker_internal]="host.docker.internal resolves inside containers"

  host_docker_internal_diagnose() {
    source "$AI_STACK/installer/lib/docker-engine.sh"
    local sel addhost=()
    sel="$(get_env AI_STACK_DOCKER_ENGINE "")"
    if [[ -n "$sel" ]] && _engine_valid "$sel"; then
      local ah; ah="$(engine_addhost_args "$sel" 2>/dev/null || true)"
      [[ -n "$ah" ]] && addhost=("$ah")
    fi
    docker run --rm "${addhost[@]}" alpine getent hosts host.docker.internal >/dev/null 2>&1 \
      || { echo "host.docker.internal does not resolve (engine: ${sel:-<none>})"; return 1; }
  }

  host_docker_internal_fix() {
    source "$AI_STACK/installer/lib/docker-engine.sh"
    local sel; sel="$(get_env AI_STACK_DOCKER_ENGINE "")"
    if [[ -n "$sel" ]] && [[ "$(engine_addhost_args "$sel" 2>/dev/null || true)" == --add-host* ]]; then
      err "On $(engine_display "$sel"), managed runs apply --add-host=host.docker.internal:host-gateway automatically."
      err "If a raw container still cannot resolve it, add that flag to its 'docker run'."
      return 1
    fi
    err "Cannot auto-fix — OrbStack/Docker Desktop networking issue."
    err "Check the engine's Settings → Network → enable host networking."
    return 1
  }
  ```
- [ ] Run doctor to confirm checks 01 and 02 still run + pass on this OrbStack box (no engine pinned in the real `.env` → 01 takes the legacy fallback green):
  ```bash
  bash mayssam-ai-stack.sh doctor 2>&1 | grep -E 'Selected Docker engine|host.docker.internal'   # expect both ✓
  ```
- [ ] Commit:
  ```bash
  git add installer/doctor/checks/01_orbstack_running.sh installer/doctor/checks/02_host_docker_internal.sh
  git commit -m "feat(engine): doctor 01 probes selected engine; 02 engine-aware host.docker.internal

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 14 — New doctor checks 47 (consistency / split-brain) + 48 (selection present)

> **Baseline = 46 (Task 0).** 46 is the EXISTING `46_agent_fleet_parity.sh`; the new files are **47** and **48**. Final total **48**.

**Files:**
- Create: `installer/doctor/checks/47_docker_engine_consistency.sh`
- Create: `installer/doctor/checks/48_docker_engine_selection.sh`

**Steps:**

- [ ] Write a failing assertion in `installer/smoke/engine.sh` proving both files exist, register their checks, the count is **48**, AND the existing `46_agent_fleet_parity.sh` is UNTOUCHED (guards against a filename-collision silently overwriting fleet-parity and keeping the count at a false 47):
  ```bash
  log "doctor: 47 + 48 present, count == 48, 46_agent_fleet_parity intact"
  [[ -f "$AI_STACK/installer/doctor/checks/46_agent_fleet_parity.sh" ]] \
    || { err "46_agent_fleet_parity.sh missing/overwritten — collision!"; exit 1; }
  [[ -f "$AI_STACK/installer/doctor/checks/47_docker_engine_consistency.sh" ]] || { err "47 missing"; exit 1; }
  [[ -f "$AI_STACK/installer/doctor/checks/48_docker_engine_selection.sh" ]] || { err "48 missing"; exit 1; }
  # No duplicate ordinal 46 (would mean a collision).
  [[ "$(ls "$AI_STACK"/installer/doctor/checks/46_*.sh | wc -l | tr -d ' ')" == 1 ]] \
    || { err "duplicate 46_ ordinal — collision with agent_fleet_parity"; exit 1; }
  n="$(ls "$AI_STACK"/installer/doctor/checks/*.sh | wc -l | tr -d ' ')"
  [[ "$n" == 48 ]] || { err "expected 48 check files, found $n"; exit 1; }
  # Both new check NAMES register (the check name, distinct from the agent_fleet_parity name).
  grep -q 'CHECKS+=(docker_engine_consistency)' "$AI_STACK/installer/doctor/checks/47_docker_engine_consistency.sh" || { err "47 check not registered"; exit 1; }
  grep -q 'CHECKS+=(docker_engine_selection)'  "$AI_STACK/installer/doctor/checks/48_docker_engine_selection.sh"  || { err "48 check not registered"; exit 1; }
  ok "doctor 47/48 present, 48 checks total, 46 intact"
  ```
- [ ] Run it — expect FAIL (files absent, count 46):
  ```bash
  bash installer/smoke/engine.sh   # expect: "47 missing" → exit 1
  ```
- [ ] Create `installer/doctor/checks/47_docker_engine_consistency.sh` (split-brain detector; fix re-pins, NEVER auto-destroys — complete file):
  ```bash
  # Engine consistency / no split-brain: AMBIENT CLI context, gateway.env, and every
  # ai-stack.managed container all live on the SELECTED engine.
  CHECKS+=(docker_engine_consistency)
  CHECK_TITLE[docker_engine_consistency]="Docker engine consistency (no split-brain)"

  docker_engine_consistency_diagnose() {
    source "$AI_STACK/installer/lib/docker-engine.sh"
    local sel; sel="$(get_env AI_STACK_DOCKER_ENGINE "")"
    # No selection → check 48 owns that; pass-as-skip here.
    if [[ -z "$sel" ]] || ! _engine_valid "$sel"; then
      echo "(no engine selected — see check 48)"; return 0
    fi
    local sock; sock="$(engine_socket "$sel" 2>/dev/null || echo '')"
    [[ -n "$sock" ]] || { echo "cannot resolve socket for selected engine '$sel'"; return 1; }

    local bad=0
    # (a) The USER'S AMBIENT context (what their OTHER shells see) resolves to the
    # selected engine. Measure with env -u DOCKER_HOST so we do NOT just validate the
    # var doctor itself exported (which would always equal $sock — a self-defeating check).
    local ctx_host
    ctx_host="$(env -u DOCKER_HOST docker context inspect "$(env -u DOCKER_HOST docker context show 2>/dev/null)" \
                  --format '{{(index .Endpoints "docker").Host}}' 2>/dev/null || echo '')"
    if [[ -n "$ctx_host" && "$ctx_host" != "$sock" ]]; then
      echo "ambient docker context socket ($ctx_host) != selected ($sock) — other shells use a different engine"; bad=1
    fi
    # (b) gateway.env DOCKER_HOST == selected socket.
    local gw; gw="$(grep -E '^DOCKER_HOST=' "$HOME/.config/openshell/gateway.env" 2>/dev/null | tail -1 | cut -d= -f2- || echo '')"
    if [[ -n "$gw" && "$gw" != "$sock" ]]; then
      echo "gateway.env DOCKER_HOST ($gw) != selected ($sock)"; bad=1
    fi
    # (c) REAL stranded-container detection: enumerate every OTHER installed+running
    # engine's socket and look for ai-stack.managed containers living there. If any
    # are found on a NON-selected engine, that is split-brain → fail with guidance.
    local other osock stranded=""
    for other in $ENGINE_IDS; do
      [[ "$other" == "$sel" ]] && continue
      engine_installed "$other" || continue
      engine_running "$other"   || continue
      osock="$(engine_socket "$other" 2>/dev/null || echo '')"; [[ -n "$osock" ]] || continue
      local found
      found="$(_engine_docker_timeout 6 docker -H "$osock" ps -a \
                --filter label=ai-stack.managed=true --format '{{.Names}}' 2>/dev/null | tr '\n' ' ' || true)"
      [[ -n "${found// }" ]] && stranded+="  on $other ($(engine_display "$other")): ${found% }"$'\n'
    done
    if [[ -n "$stranded" ]]; then
      echo "ai-stack.managed container(s) STRANDED on a non-selected engine:"; printf '%s' "$stranded"; bad=1
    fi
    return $bad
  }

  docker_engine_consistency_fix() {
    source "$AI_STACK/installer/lib/docker-engine.sh"
    local sel; sel="$(get_env AI_STACK_DOCKER_ENGINE "")"
    [[ -n "$sel" ]] && _engine_valid "$sel" || { err "no valid engine selected — run check 48 fix"; return 1; }
    # Re-pin: rewrites gateway.env + exports DOCKER_HOST. Does NOT touch containers.
    engine_pin "$sel" || return 1
    warn "Re-pinned gateway.env + DOCKER_HOST to '$sel'."
    warn "If managed containers are stranded in ANOTHER engine, this does NOT move them:"
    warn "  - re-pin to where they live (mayssam-ai-stack.sh docker-engine set <that-engine>), OR"
    warn "  - guided recreate on the selected engine (re-run the relevant install phase)."
    warn "Never auto-destroyed (conservative recreate_guard philosophy)."
    return 0
  }
  ```
- [ ] Create `installer/doctor/checks/48_docker_engine_selection.sh` (complete file):
  ```bash
  # Engine selection present & valid: AI_STACK_DOCKER_ENGINE set + still installed.
  CHECKS+=(docker_engine_selection)
  CHECK_TITLE[docker_engine_selection]="Docker engine selection present & valid"

  docker_engine_selection_diagnose() {
    source "$AI_STACK/installer/lib/docker-engine.sh"
    local sel; sel="$(get_env AI_STACK_DOCKER_ENGINE "")"
    if [[ -z "$sel" ]]; then
      echo "AI_STACK_DOCKER_ENGINE not set (run: mayssam-ai-stack.sh docker-engine select)"; return 1
    fi
    if ! _engine_valid "$sel"; then
      echo "AI_STACK_DOCKER_ENGINE='$sel' is not a valid id (want: $ENGINE_IDS)"; return 1
    fi
    if ! engine_installed "$sel"; then
      echo "selected engine '$sel' ($(engine_display "$sel")) is no longer installed"; return 1
    fi
  }

  docker_engine_selection_fix() {
    source "$AI_STACK/installer/lib/docker-engine.sh"
    local sel; sel="$(engine_select)" || return 1
    engine_ensure "$sel" || return 1
    engine_pin "$sel" || return 1
  }
  ```
- [ ] Run it + verify doctor discovers all 48:
  ```bash
  bash installer/smoke/engine.sh   # expect: "doctor 47/48 present, 48 checks total, 46 intact", exit 0
  bash mayssam-ai-stack.sh doctor 2>&1 | grep -E 'consistency|selection'   # expect both checks to appear
  bash mayssam-ai-stack.sh doctor 2>&1 | grep -iE '/48|48 checks|doctor done'   # runtime total is 48
  ```
- [ ] **VALIDATION GATE** — run the full doctor on this OrbStack box and confirm it is green end-to-end (no engine pinned → 47 pass-as-skip, 48 fails-with-fix-offer is EXPECTED on an unpinned box; pin once to confirm green):
  ```bash
  bash mayssam-ai-stack.sh doctor 2>&1 | tail -20
  # Then pin + re-run to confirm 01/47/48 go green:
  bash mayssam-ai-stack.sh docker-engine set orbstack
  bash mayssam-ai-stack.sh doctor 2>&1 | grep -E 'Selected Docker engine|consistency|selection'   # expect 3× ✓
  ```
  > NOTE: pinning writes the REAL `.env` AI_STACK_DOCKER_ENGINE=orbstack — this is the intended product behavior on the real box (orbstack is the box's engine), so it is safe. It does NOT delete or rewrite secret keys.
- [ ] Commit:
  ```bash
  git add installer/doctor/checks/47_docker_engine_consistency.sh installer/doctor/checks/48_docker_engine_selection.sh installer/smoke/engine.sh
  git commit -m "feat(engine): doctor checks 47 (consistency/split-brain) + 48 (selection present) (TDD)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 15 — Docs cohesion sweep: doctor count 46→48, engine naming, new subcommand, memory

> **Baseline = 46 (Task 0), not 45.** README ALREADY reads `doctor-46%2F46` / "46 checks" / "46/46" (verified L5/L18/L209/L585) because fleet-parity check 46 landed in `83a4c45`. So this sweep is **46→48**, badge **`46%2F46`→`48%2F48`**. The pre-recorded "45" line numbers from the earlier recon are STALE — RE-GREP fresh in the worktree and treat any line number as a hint only.

**Files (re-grep fresh; line numbers are hints):**
- Modify: `README.md` (badge `doctor-46%2F46`→`48%2F48`; "46 checks"→"48 checks" L18/L585; "46/46"→"48/48" L209; add a `docker-engine` mention near the command table)
- Modify: `doc/DOCTOR.md` (count + add 47/48 entries)
- Modify: `doc/ARCHITECTURE.md` (count)
- Modify: `doc/TUTORIAL.md` (count) — then regenerate `doc/TUTORIAL.html`
- Modify: `doc/ONBOARDING.md` (count)
- Modify: `doc/INSTALL.md` (count)
- Modify: `doc/HANDOFF.md` (count, possibly multiple)
- Modify: `CHANGELOG.d/` (new entry)
- Modify: `doc/PREREQUISITES.md` (engine naming: OrbStack is the *default* of four selectable engines)
- Modify: `.env.example` (add `AI_STACK_DOCKER_ENGINE` documentation comment + key)
- Modify: `doc/EXPLORE.html` (RLM gotcha — generalize "Docker/OrbStack" to "the selected Docker engine")
- Modify: memory file `~/.claude/projects/-Users-mayssam-sayyadian-ai-stack/memory/project_doctor_count.md` (reconcile **45→48**, preserve the 46=agent_fleet_parity entry) + add a new `project_docker_engine_selection.md`

**Steps:**

- [ ] Re-derive the LIVE counts FRESH (do NOT trust the stale "45" recon line numbers). Search for BOTH 46 and any lingering 45:
  ```bash
  grep -rn -- 'doctor-4[5-8]%2F4[5-8]\|4[5-8]/4[5-8]\|4[5-8] checks\|doctor-4[5-8]' README.md doc/ CHANGELOG.md 2>/dev/null
  # Distinguish the COUNT (46→48) from the literal "check 45"=tutorial / "check 46"=agent_fleet_parity
  # references — bump COUNTS only; do NOT renumber the existing checks 45/46 prose.
  ```
- [ ] Bump every surfaced COUNT `46→48` (badge `46%2F46`→`48%2F48`, "46 checks"→"48 checks", "46/46"→"48/48") at the FRESHLY-greped lines. Do NOT touch `installer/lib/check_fleet_parity.sh` (it asserts FLEET parity numbers — 6 skills / 9 roles / 10 bullets / 27 souls — never the doctor count) and do NOT touch the runner (count is derived from `${#CHECKS[@]}`). Do NOT renumber the doc references to "check 45 (tutorial)" or "check 46 (agent_fleet_parity)" — those are check IDENTITIES, not the total.
- [ ] Edit `doc/TUTORIAL.md` only (source), then regenerate the HTML (NEVER hand-edit `doc/TUTORIAL.html` — doctor check 45=tutorial drift-guards it):
  ```bash
  python3 installer/lib/build_tutorial_html.py
  python3 installer/lib/build_tutorial_html.py --check   # expect: no drift
  ```
- [ ] Update `doc/PREREQUISITES.md`: reframe OrbStack from "the Docker runtime" to "the default of four selectable engines (OrbStack | Docker Desktop | Colima | Podman); choose via `mayssam-ai-stack.sh docker-engine select`". Keep `ensure_orbstack` reference accurate (now an alias). Note the global `--engine <id>` flag and `docker-engine set <id>`.
- [ ] Add to `.env.example` (NO secret; documents the new key — it stays empty until selection):
  ```
  # Docker engine the WHOLE stack uses (main containers + OpenShell gateway).
  # One of: orbstack | docker-desktop | colima | podman. Empty = not yet selected;
  # set it intentionally with:  mayssam-ai-stack.sh docker-engine select
  AI_STACK_DOCKER_ENGINE=
  ```
- [ ] `services.yml` / `installer/lib/help.sh` decision: `docker-engine` is a pure CLI control verb (like `deps`/`verify`), NOT a services.yml service — so add NO services.yml `help:` block. Its help lives in the `usage()` heredoc (Task 11). **EVIDENCE-BASED claim:** Task 11 already verified (via the `help docker-engine` routing assertion) whether `help.sh` needs a routing arm. IF Task 11 found a routing change was needed, it landed THERE and this step is a no-op note; if not, confirm `help.sh` renders from services.yml with no hardcoded OrbStack-runtime prose — no edit.
- [ ] `doc/EXPLORE.html`: change the RLM card gotcha string from "Docker/OrbStack must be up" to "the selected Docker engine must be up". Do NOT churn the incidental `docker ps`/`docker exec` CLI lines. Re-grep for the exact string first (line ~459 is a hint).
- [ ] Add a `CHANGELOG.d/` entry summarizing the feature (engine selection, single source of truth, doctor 47/48, count 46→48).
- [ ] Update the memory files (the USER applies/edits these; the plan lists exact edits):
  - `project_doctor_count.md`: reconcile the STALE `45 → 48`; KEEP "46=agent_fleet_parity" and ADD "47=docker_engine_consistency (split-brain), 48=docker_engine_selection (present+installed)". Note the doc-vs-code drift that the memory was at 45 while the code was already at 46.
  - New `project_docker_engine_selection.md`: AI_STACK_DOCKER_ENGINE single source of truth; `installer/lib/docker-engine.sh` registry; central DOCKER_HOST export after env.sh + docker.sh source-time export for standalone start-*.sh; Phase 00 selection-before-use; gateway.env derived via single `engine_write_gateway_env` writer; openshell-* durability scripts made engine-aware; checks 47/48; common.sh:58 ENV_FILE clobber fixed; global `--engine` plumbing; podman/colima/docker-desktop sockets UNVERIFIED (open questions).
- [ ] **VALIDATION GATE** — re-run doctor + the tutorial drift check + the smoke test, and confirm the runtime total is 48:
  ```bash
  bash mayssam-ai-stack.sh doctor 2>&1 | grep -iE '/48|48 checks|doctor done' | tail -2   # EXPECT 48
  python3 installer/lib/build_tutorial_html.py --check
  bash installer/smoke/engine.sh
  ```
- [ ] Commit:
  ```bash
  git add README.md doc/ .env.example CHANGELOG.d/ 2>/dev/null || git add -A
  git commit -m "docs(engine): cohesion sweep — doctor 46→48, engine selection, AI_STACK_DOCKER_ENGINE

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Task 16 — Review gate (doc/SOUL.md §24) + finish-the-branch (pull → commit → merge → push)

**Files:** none (process task)

**Steps:**

> **ORDER:** complete Task 17 (rollback recipe + matrix + NO_PROMPT-no-engine test) BEFORE the finish-the-branch step below — its smoke assertion is part of the green gate.

- [ ] Run the FULL smoke + doctor one more time and capture evidence (verification-before-completion):
  ```bash
  bash installer/smoke/engine.sh
  bash -n installer/lib/docker-engine.sh installer/phases/00_host.sh installer/phases/04_openshell.sh mayssam-ai-stack.sh \
        installer/lib/docker.sh installer/lib/deps.sh \
        bin/start-litellm.sh bin/openshell-checkpoint.sh bin/openshell-state-restore.sh \
        bin/openshell-watchdog.sh bin/openshell-token-refresh.sh
  bash mayssam-ai-stack.sh docker-engine status
  bash mayssam-ai-stack.sh doctor 2>&1 | grep -iE '/48|48 checks|doctor done' | tail -2   # EXPECT 48
  bash mayssam-ai-stack.sh doctor 2>&1 | tail -10
  python3 installer/lib/build_tutorial_html.py --check
  ```
- [ ] Per `doc/SOUL.md` §24.2/24.4 — dispatch ≥2 INDEPENDENT reviewers + a PM (this is design+infra), then debate-to-consensus. Reviewers MUST test the FAILURE paths, not the happy OrbStack path:
  - **Adversarial reviewer:** attack the split-brain restart guard (does it really REFUSE when a colorized `Ready` sandbox exists? — the canonical `_osh_strip_ansi`+`$1!=n` guard, NOT a weaker awk); the cold/un-pinned phase-04 path (errors with `docker-engine select` guidance, no hidden pin, no silent `/var/run/docker.sock`); the `engine_select` precedence table incl the running-singleton rung (stubbed); the NO_PROMPT hard-fail brew remedy; and that NO bare `=$(engine_…)` assignment can abort under `inherit_errexit`.
  - **Domain/infra reviewer:** validate the `docker context inspect desktop-linux` endpoint choice, the colima `socket:` parse, the podman `PodmanSocket.Path` field, that `--add-host=host.docker.internal:host-gateway` is the portable token, and that `engine_socket` for colima/podman is timeout-bounded. CONFIRM the THREE export sites are consistent and not re-clobbered: (1) central in mayssam-ai-stack.sh after env.sh, (2) docker.sh source-time for standalone start-*.sh, (3) the openshell-* bin scripts reading gateway.env/registry. Verify empirically (ps/launchctl) that a brew-services restart relaunches the WRAPPER that re-sources gateway.env (Ollama plist-regen gotcha). Verify the openshell-* durability scripts no longer assume OrbStack (the highest data-loss path).
  - **PM reviewer:** confirm the 4-engine scope, the "never auto-destroy" guarantee in check 47 (incl REAL cross-engine stranded detection in part c), the reversibility (recorded prior docker context + printed undo; documented rollback in Task 17), and the docs-cohesion completeness (count **46→48** everywhere it is surfaced; `project_doctor_count.md` reconciled from the stale 45).
  - Each reviewer's FINAL MESSAGE MUST be the complete findings (instruct brevity; re-run if truncated to a teaser). Verify any single flagged claim directly.
- [ ] Address review findings. Confirm specifically: the live-path add-host is carried by `start-litellm.sh` (Task 10b) and the five `ollama`-only start scripts are correctly out of scope; the `docker context` switch does not break the DOCKER_HOST precedence (DOCKER_HOST overrides context — note this is intentional and the context switch is ambient-only). Commit any fixes.
- [ ] Finish the branch (superpowers:finishing-a-development-branch) — pull → commit → merge → push (standing rule):
  ```bash
  git -C /Users/mayssam.sayyadian/ai-stack fetch origin
  git -C /Users/mayssam.sayyadian/ai-stack checkout main && git -C /Users/mayssam.sayyadian/ai-stack pull --ff-only origin main
  git -C /Users/mayssam.sayyadian/ai-stack merge --no-ff feat/docker-engine-selection -m "merge: intentional Docker-engine selection + single-engine guarantee + doctor 47/48 (count 46→48) (reviewed: 2 reviews + PM + debate)"
  git -C /Users/mayssam.sayyadian/ai-stack push origin main
  git -C /Users/mayssam.sayyadian/ai-stack worktree remove /Users/mayssam.sayyadian/ai-stack-wt/docker-engine
  ```
- [ ] Final report: task count, mapping spec→tasks, residual open questions (the podman/colima/docker-desktop socket UNVERIFIED items), and that `install 04h`-style real-`~/.claude` blast-radius steps are NOT touched by this change.

---

## Task 17 — Rollback recipe + manual verification matrix + NO_PROMPT-no-engine end-to-end

> Reversibility (reversible-changes skill) + the residual UNVERIFIED engines. These are first-class, not afterthoughts: an engine switch on an existing install must have a documented undo, and the un-installable-here engines need a manual matrix.

**Files:**
- Create/append: `doc/PREREQUISITES.md` (or `doc/DOCTOR.md`) rollback + matrix section
- Test: extend `installer/smoke/engine.sh`

**Steps:**

- [ ] Add a NO_PROMPT-no-engine-installed END-TO-END assertion (QA/INFRA missing coverage) — prove `install` under NO_PROMPT with ZERO engines exits cleanly with the brew remedy and does NOT proceed to docker calls. Simulate "zero engines" by stubbing detection in a subshell:
  ```bash
  log "17: NO_PROMPT + zero engines installed → clean hard-fail with brew remedy (no docker calls)"
  out="$(
    set +e
    AI_STACK="$AI_STACK"; ENV_FILE="$(mktemp)"
    NO_PROMPT=1 bash -c '
      set -Eeuo pipefail; AI_STACK="'"$AI_STACK"'"
      source "$AI_STACK/installer/lib/common.sh"; source "$AI_STACK/installer/lib/env.sh"
      source "$AI_STACK/installer/lib/docker-engine.sh"
      engine_installed() { return 1; }            # pretend nothing is installed
      engine_detect_installed() { :; }            # empty
      sel="$(NO_PROMPT=1 engine_select 2>/dev/null)" || true
      engine_ensure "$sel" 2>&1                    # must hard-fail with brew remedy
    '
  )"
  grep -q 'brew install' <<<"$out" || { err "NO_PROMPT zero-engine path did not print brew remedy: $out"; exit 1; }
  ok "17: NO_PROMPT zero-engine path hard-fails with remedy"
  ```
- [ ] Run it — expect this assertion green once Tasks 5/6 are in (it composes existing functions; if red, fix the composition):
  ```bash
  bash installer/smoke/engine.sh   # expect: "17: NO_PROMPT zero-engine path hard-fails with remedy"
  ```
- [ ] Document the ROLLBACK recipe (engine switch on an existing install) in `doc/PREREQUISITES.md`:
  ```
  ## Undo an engine switch
  If you switched engines (e.g. `docker-engine set colima`) but your managed
  containers live on the previous engine (doctor check 47 will say so):
    1. Re-pin to where the containers actually live:
         mayssam-ai-stack.sh docker-engine set <previous-engine>   # e.g. orbstack
    2. Restart the OpenShell gateway to re-read gateway.env (only if no Ready
       sandbox, else: OPENSHELL_FORCE_GATEWAY_RESTART=1 mayssam-ai-stack.sh install 04):
    3. Restore your global docker context if you let pin switch it:
         docker context use <prior>     # engine_pin printed <prior> when it switched
    4. Confirm: mayssam-ai-stack.sh doctor   # checks 01/47/48 green
  Nothing is auto-destroyed at any step.
  ```
- [ ] Document the MANUAL verification matrix for the engines that cannot be exercised here (residual open questions — log-as-assumed, not papered over). Append to the same doc:
  ```
  ## Engine verification matrix (manual — UNVERIFIED on the build box)
  | engine        | socket resolution to confirm                                   | host.docker.internal |
  |---------------|----------------------------------------------------------------|----------------------|
  | docker-desktop| `docker context inspect desktop-linux` endpoint, else .docker/run | auto (no flag)    |
  | colima        | `colima status` `socket:` line, else ~/.colima/<profile>/docker.sock | needs --add-host |
  | podman        | `podman machine inspect {{.ConnectionInfo.PodmanSocket.Path}}`  | needs --add-host     |
  | docker-desktop cask churn | `brew info --cask docker-desktop` → else `docker`  | n/a                  |
  Run `mayssam-ai-stack.sh docker-engine set <engine>` on a box with that engine and
  confirm `docker-engine status` + doctor 01/47/48 are green before relying on it.
  ```
- [ ] Commit:
  ```bash
  git add doc/PREREQUISITES.md installer/smoke/engine.sh
  git commit -m "docs(engine): rollback recipe + manual verification matrix + NO_PROMPT-no-engine test

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
  ```

---

## Spec requirement → task map

| Spec requirement | Task(s) |
|---|---|
| Re-derive LIVE doctor baseline (46, not 45) before any numbering | 0 |
| `AI_STACK_DOCKER_ENGINE` single source of truth (.env) | 1, 5, 7, 8 |
| Registry module `docker-engine.sh` + functions | 1, 3, 4, 5, 6, 7 |
| `engine_socket` probed/derived per engine (timeout-bounded sub-cmds) | 3 |
| `engine_addhost_args` gating | 1, 10 |
| `engine_detect_installed`/`engine_detect_running` (timeout-bounded) | 4 |
| `engine_select` precedence (flag>env>running-singleton>prompt>NO_PROMPT priority) | 5 |
| `engine_ensure` (install consent + start + bounded wait + NO_PROMPT hard-fail) | 6 |
| `engine_pin` + single `engine_write_gateway_env` writer + recorded-prior docker context | 7 |
| Central DOCKER_HOST export for all stack docker calls (subcommand path) | 8 |
| `docker.sh` source-time DOCKER_HOST export (standalone `start-*.sh` path) | 8b |
| Phase-00 selection-before-any-docker-use preflight | 8c |
| `deps.sh` ensure_orbstack=alias; deps_report socket triple (unique sentinel) | 9 |
| `docker.sh` add-host (docker_run_managed/probe) + LIVE start-litellm.sh add-host | 10 |
| Global `--engine <id>` argv → AI_STACK_ENGINE_FLAG (single plumbing site) | 11a |
| `mayssam-ai-stack.sh docker-engine [status\|select\|set]` + help + `--engine` latch | 11 |
| Phase 04 read-only-select + single writer + canonical Ready guard + checkpoint-before-restart | 12 |
| OpenShell durability bin scripts engine-aware (checkpoint/restore/watchdog/token) | 12b |
| Doctor check 01 selected-engine (TDD) + 02 engine-aware (TDD) | 13 |
| Doctor **47** consistency/split-brain (real cross-engine stranded detection) + **48** selection-present | 14 |
| Doctor count **46→48** + docs cohesion + memory (reconcile stale 45) | 15 |
| Review gate (≥2 reviews + PM + debate, failure paths) + merge | 16 |
| Rollback recipe + manual verification matrix + NO_PROMPT-no-engine e2e | 17 |
| common.sh:58 ENV_FILE clobber fix + full-chain grep gate (test-safety prerequisite) | 2 |

---

## Debate resolutions (where reviewers conflicted or a minor was deliberately handled a certain way)

All four reviewers agreed on the criticals/majors; the calls below are where a minor needed a judgment that touches the spec's load-bearing "keep the `docker` CLI everywhere; only `DOCKER_HOST` + `--add-host` vary" decision, or where two reviewers nudged in slightly different directions.

- **`docker_run_managed` is dead code — keep it or drop it? (ARCH major vs INFRA/QA minor "test-free dead code").** Resolved: **keep** the `docker_run_managed`/`probe_host_docker_internal` add-host edits as *forward-looking correctness* AND land the **live-path** fix in `bin/start-litellm.sh` (Task 10/10b), because recon proves start-litellm.sh is the *only* live script that dials `host.docker.internal`. This honors the spec's "engine works for the WHOLE stack" goal at runtime without a speculative mass-migration of the five `ollama`-only start scripts (explicitly scoped OUT, with a documented rule to route any future host-dialing service through `engine_addhost_args`). Preserves "keep docker CLI everywhere" — the only per-engine variance remains `engine_addhost_args`.

- **`engine_*` return code: `1` vs `2` under `inherit_errexit` (INFRA major).** Resolved: caller-recoverable functions (`engine_select`/`engine_ensure`/`engine_pin`) return **1**; the pure accessors (`engine_display`/`engine_addhost_args`/`engine_socket`) keep **2** for the *programming-error* unknown-id case (callers always pre-validate with `_engine_valid`). Plus a Task-1 grep-lint that fails on any bare `=$(engine_…)` assignment. This satisfies the inherit_errexit safety concern without forcing every accessor to a single code, and every wiring call site is `|| {…}`-guarded.

- **`docker context use` global switch vs exported `DOCKER_HOST` (INFRA reversibility, ARCH missing-coverage).** Resolved per spec key-decision 2 (offer the context switch *with consent*): keep it, but make it honest — `DOCKER_HOST` (exported) OVERRIDES `docker context` inside ai-stack processes, so the switch only changes the user's AMBIENT world. `engine_pin` now RECORDS the prior context and PRINTS the exact undo; doctor 47 compares the AMBIENT context (via `env -u DOCKER_HOST docker context inspect`), not the doctor-exported `DOCKER_HOST`, so the consistency check measures what other shells actually see rather than self-validating the var it just set. Documented rollback in Task 17.

- **Phase 04 auto-pin vs read-only selection (ARCH minor + INFRA "start-of-install intent").** Resolved: Phase 04 is made **read-only** about selection (errors with `docker-engine select` guidance if unset); the single global pin moves to the **Phase-00 preflight** (Task 8c). This keeps "explicit, intentional selection at the START of install" intact and removes the surprising deep-in-a-phase global `.env` write.

- **Task 11 `--engine` arg latch (ARCH minor).** Resolved by *implementing* the shift-latch (`expect_engine` state machine in the `select` arm) so BOTH `--engine <id>` and `--engine=<id>` parse, with smoke cases for both — rather than dropping the bare-`--engine` arm. Matches the spec's "--engine flag is the top precedence input."

- **Task 6 `eval` + cask-churn ordering (INFRA minor).** Resolved: replaced `eval "$cmd"` with an **array invocation** (`cmd=(brew …); "${cmd[@]}"`) and resolve the docker-desktop cask token (`docker-desktop` → fallback `docker`) BEFORE printing the consent prompt, so the user approves the exact command that runs.

---

## Review & debate log

**Panel:** 4 lenses — architecture (approve-with-changes), INFRA/SRE/reversibility (**reject**), QA/TDD (**reject**), completeness (approve-with-changes). Two rejects + two conditional approvals → this revision resolves every critical and major and the applicable minors before the plan is fit to execute.

**Highest-severity findings fixed (criticals & majors):**

- **CRITICAL ×4 — stale doctor-count baseline / 46-collision.** All four lenses flagged that the tree already has **46** check files (`46_agent_fleet_parity.sh`), so creating `46_docker_engine_consistency.sh` would collide and the `== 47` smoke assertion was wrong. Fixed: re-baselined the entire plan to **46→48**; new files are **`47_docker_engine_consistency.sh`** + **`48_docker_engine_selection.sh`**; added **Task 0** (a preflight that re-derives the live count from `ls checks/*.sh | wc -l` before any file is created); Task 14 asserts `== 48` AND that `46_agent_fleet_parity.sh` is untouched (no silent-overwrite); Task 15 sweep is `46→48`/badge `46%2F46`→`48%2F48` with a fresh re-grep; `project_doctor_count.md` reconciled **45→48** preserving the 46 entry. Verified against the live tree (46 files, README already `46%2F46`).
- **CRITICAL (INFRA) — central export never reaches standalone `start-*.sh`.** `mayssam-ai-stack.sh` is not in the process chain for `bash bin/start-litellm.sh --recreate`. Fixed with **Task 8b**: re-export `DOCKER_HOST` at `docker.sh` source-time so every start script inherits the selected socket, plus a stubbed-docker assertion that the socket reaches the real start-litellm.sh command line.
- **CRITICAL (INFRA) — gateway restart data-loss + unverified wrapper relaunch.** Fixed in **Task 12**: checkpoint EVERY Ready sandbox (fail-closed) before the restart in addition to identity-backup; default to NOT restarting inline (pending-restart doctor warning); empirically confirm via `ps` that the gateway *wrapper* (which re-sources gateway.env) is the relaunched program (Ollama plist-regen gotcha).
- **CRITICAL/ARCH — openshell durability scripts operate on the wrong engine.** Fixed with **Task 12b**: checkpoint/state-restore/watchdog/token-refresh now derive `DOCKER_HOST` from gateway.env (primary) or the registry (fallback) before invoking docker — the highest data-loss path is no longer OrbStack-hardcoded.
- **MAJOR — `_others` guard weaker than canonical.** Fixed: Task 12 **sources `lib/openshell.sh`** and reuses `_osh_strip_ansi` (verified at openshell.sh:39/258), with a colorized-`Ready` fixture smoke test, instead of a re-implemented awk that would miss colorized tokens (the watchdog destroy-both incident class).
- **MAJOR — global `--engine` argv never plumbed for `install`.** Fixed with **Task 11a**: one argv→`AI_STACK_ENGINE_FLAG` translation site in the top-level parser; the central export derives via flag-aware `engine_select`; smoke proves `--engine orbstack` resolves with an empty `.env`.
- **MAJOR — selection-before-use not enforced; Phase 04 hidden pin.** Fixed with **Task 8c** (Phase-00 preflight select+pin) and a read-only Phase 04; doctor 01's ambient fallback is a hard **warn**, not silent green.
- **MAJOR — gateway.env writer duplicated / not throwaway-safe.** Fixed: single `engine_write_gateway_env` helper (Task 7) called by both `engine_pin` and Phase 04, honoring `ENGINE_GATEWAY_ENV_FILE` so tests never touch the real `~/.config/openshell/gateway.env` (MEMORY rule extended from `.env` to gateway.env).
- **MAJOR — checks 01/02 not TDD'd; deps_report test tautological; Task 8 tested a re-implemented snippet; phase-04 grep-only.** Fixed: Task 13 drives `*_diagnose` with controlled state (pinned-unreachable, no-engine fallback, colima add-host capture) red-first; Task 9 asserts a UNIQUE sentinel (`Docker engine: orbstack` + `gateway.env socket == selected`); Task 8 asserts the real load path via a `__print-docker-host` seam (red→green within the task); Task 12 adds a behavioral throwaway-file write test.
- **MAJOR — running-singleton precedence rung untested.** Fixed: Task 5 stubs `engine_detect_running() { printf 'colima\n'; }` in a subshell to prove running beats the orbstack priority fallback unambiguously.
- **MAJOR — common.sh:58 chain safety.** Fixed: Task 2 adds a grep gate (no unconditional `ENV_FILE=` in any lib) + a full common→env→docker→litellm→deps→setup source-chain survival test.
- **MAJOR — check 47 stranded-container (c) was a no-op + self-defeating DOCKER_HOST compare.** Fixed: Task 14 enumerates every OTHER installed+running engine's socket for `ai-stack.managed` containers and compares the AMBIENT context (`env -u DOCKER_HOST`), not the doctor-exported var.

**Minors applied:** Task 6 array-invocation + cask-token-before-prompt; Task 11 `--engine` shift-latch with both-forms smoke; Task 11 `help docker-engine` routing as a real assertion (evidence-based, not eyeballed); Task 4 host-reality assertions gated on actual detection (portable across CI/Desktop/no-podman boxes); File-Structure note corrected to drop the bogus `mayssam-ai-stack.sh test engine` verb (no `engine` phase exists). `engine_socket` colima/podman sub-commands wrapped in `_engine_docker_timeout` (wedged-daemon hang). NO_PROMPT-zero-engine end-to-end added (Task 17). Rollback recipe + manual matrix added (Task 17).

**Residual risks / open questions implementation MUST watch:**

1. **Podman / Colima / Docker-Desktop sockets are UNVERIFIED on the build box** (no machines installed). `engine_socket` emits the assumed path with a `log "… ASSUMED (unverified on this host)"` and falls back; confirm against a live `podman machine` / `colima status` / Docker Desktop `desktop-linux` context before relying on those engines (Task 17 matrix). Do not silently cap.
2. **brew-services gateway restart wrapper relaunch** is asserted via `ps` but the empirical proof can only be captured on a box that actually restarts the gateway — Task 16's domain/infra reviewer must capture `ps`/launchctl evidence, not assume (Ollama plist-regen gotcha).
3. **`docker context` switch is ambient-only** (DOCKER_HOST overrides it inside ai-stack). The recorded-prior + printed undo is the reversibility contract; the consent branch is NO_PROMPT/TTY-gated and therefore unit-untested — verified manually in the Task 17 matrix.
4. **docker-desktop cask-churn fallback** (`brew info --cask docker-desktop` → `docker`) is interactive + requires brew network → ships untested; the pure `engine_install_cmd` strings ARE asserted, and the churn branch is in the Task 17 manual matrix.
5. **`engine_pin` docker-context branch** and the **phase-04 split-brain refuse-when-Ready** path are exercised by the colorized-fixture guard test, but a full live-Ready-sandbox refusal is a manual/reviewer check (Task 16 adversarial).
6. **`install 04h`-style real-`~/.claude` blast-radius** is NOT touched by this change; live `install 04` (which writes the real `.env`/gateway.env) remains the user's intentional step — tests use throwaway `ENV_FILE` + `ENGINE_GATEWAY_ENV_FILE` exclusively.
7. **Phase-04 cold/un-pinned behavior change**: the old ambient-`DOCKER_HOST`/`/var/run/docker.sock` fallback is intentionally removed (selection is now explicit). A cold box errors with `docker-engine select` guidance — the adversarial reviewer must confirm this is the desired behavior and that Phase-00 preflight always runs first in the real install order.
