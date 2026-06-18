# AI Software Team — Agent Fleet

Nine role-shaped agents, realized across three frameworks (Claude Code, Hermes, Pi), plus a shared
discipline-skill pack and a **team operating protocol**. Architecture: **one canonical persona per role + a
portable skill library**, wrapped per framework. Specialist depth (React, Postgres, Terraform, security…)
lives in *skills* attached on demand, not as extra standing agents.

## Roster
- **manager** — Chief of Staff / Operator / Second Brain — the operator's single entrance to the fleet. Runs
  all of an EM's job (people, process & execution, information/knowledge & memory, decisions, communication,
  triage) and turns intent into shipped reality in whatever shape the task needs — a spec, a decision, a status
  read, a memory update, a drafted message, a direct fix, or a fanned-out delivery. Defers architecture to
  techlead and production to sre-engineer; its own direct changes still pass the gates; owns the outcome. (Opus)
- **techlead** — Tech Lead / Architect. Direction, ADRs, interface contracts, design review, standards;
  co-designs ML work with ml-engineer. (Opus)
- **frontend-engineer** — accessible, performant UI against the contract. (Opus)
- **backend-engineer** — APIs, services, data, security basics. (Opus)
- **ml-engineer** — model selection, evals, data/feature pipelines, finetuning, RAG/prompt design, inference
  integration; metric-driven, guards against overkill models. (Opus)
- **qa-test-engineer** — test strategy + automation; the green-bar quality gate. (Opus)
- **reviewing-engineer** — independent adversarial review **+ the security pass** (authz, secrets, injection,
  PII, crypto); READ-ONLY. (Opus)
- **sre-engineer** — reliability, IaC, observability, safe deploys; PROD-credentialed. (Opus)
- **incident-manager** — incident command + postmortems; coordinates, READ-ONLY on systems; activates
  out-of-band. (Opus)

## Shared skills (attached to every role)
**team-protocol** · hypothesis-debugging · verification-gates · reversible-changes · tdd · brainstorming.
A 7th skill, **memory-management** (the second-brain retrieve/write protocol), is **manager-only** — its
SKILL.md ships byte-identical across all three frameworks so parity holds, but only the manager profile
references it.
`team-protocol` is the keystone — it encodes the **definition-of-done, typed handoff contract, review-gate
ordering, escalation/dissent format, and turn budget** so the roster behaves as a team, not eight monologues.
The rest encode the operating discipline centrally, edited in one place.

## The team protocol (how work flows)
```
INTAKE(manager → SPEC w/ acceptance criteria) → DESIGN(techlead → ADR + contracts)
  → IMPLEMENT(frontend | backend | ml-engineer → DIFF) → SELF-VERIFY
  → QA(qa-test → green-bar gate) → REVIEW(reviewing-engineer → review + security gate)
  → MERGE → DEPLOY(sre-engineer)        (incident-manager activates out-of-band if prod breaks)
```
Every handoff is a typed artifact; executors don't self-delegate; a global turn budget + max-2-back-edges
per gate prevent infinite loops. See `skills/team-protocol/SKILL.md`.

## Key safety decisions (baked in)
- **reviewing-engineer** and **incident-manager** are read-only; **manager** is the single-entrance operator — it routes and executes directly when fastest, and its own direct changes still pass the gates.
- **reviewing-engineer** owns the security pass (no separate security role); a security hole = BLOCK.
- **sre-engineer** is the only prod-credentialed role; incident-manager coordinates but never touches prod.
- Risky/irreversible actions (deploys, broadcasts) require explicit confirmation; mark their skills
  `disable-model-invocation: true` where the platform supports it.

## Install (via ai-stack)
- **Hermes** — `vz-ai-stack.sh install agent_fleet` rebuilds the `hermes-fleet-v1` fleet to these 9 roles
  (one credential-isolated profile per role; models from `installer/models.yml`, routed through LiteLLM).
- **Pi** — phase-1 personas uploaded into the `pi-v1` sandbox; switch with `bin/pi-as <role>`.
- **Claude Code** — the manager installs as the **main agent** (a clobber-safe `~/.claude/CLAUDE.md` @-import of
  `~/ai-stack/fleet/manager.md` — the repo canonical, imported directly; it's frontmatter-free — a Claude Code
  subagent can't dispatch subagents, so the single-entrance orchestrator must be the main session); the other 8
  roles + 7 skills are copied into `~/.claude/{agents,skills}/` (global).

## Review & edit (Fleet Studio)
Open **`vz-ai-stack.sh fleet-studio`** (serves `doc/FLEET.html` on `127.0.0.1`) to review and edit every
file here — all 9 personas × 3 frameworks, the shared skill pack, and these docs — live on disk via the
browser's File System Access API. Chrome/Edge get read+write; Safari/Firefox open read-only. Saves go
straight to the real files (`agent-profiles/` is git-tracked, so git is your undo).

## Honest caveats (verify before you ship)
- **Pi has no native subagents** — its personas are per-project `SYSTEM.md`; a *live* fleet is a phase-2 Pi-SDK build.
- **Claude Code:** a subagent's `permissionMode` isn't reliably honored — read-only roles omit Edit/Write from `tools`.
- **Hermes:** tool IDs and spawn syntax shift between versions — run `hermes skills inspect` / `hermes tools` against your installed version before freezing toolsets.
- Role-specific specialist skills (e.g. `iac-terraform`, `code-review`) are **general-knowledge fallback** unless installed — the personas say so explicitly rather than overpromising.
