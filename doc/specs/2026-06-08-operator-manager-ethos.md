# Operator-Manager + shared Ethos + methodology gap-fill — design (2026-06-08)

Source: a 3-voice brainstorm council (Persona/Voice architect · Systems/DRY architect · orchestrator),
synthesizing Mayssam's older general-purpose **SOUL** (autonomous operator / thought-partner) + his
**operating-methodology "constitution"** into the existing 3-fleet agent system. User decisions are
LOCKED (below); this spec is the approved design pending the written-spec review gate.

## Goal
Incorporate the genuinely-additive parts of the SOUL + constitution into the fleet WITHOUT creating a
second/third source of truth, by (1) extracting the SOUL's universal *attitude* as a shared **Ethos**,
(2) making the **manager** the fleet's high-agency **operator**, (3) closing the few real methodology
**gaps** in existing skills, and (4) making the already-triplicated skill library safe to edit.

## Locked decisions (do not re-litigate)
1. **The operator IS the `manager` role** (not a new top-level agent, not a team-wide identity).
2. **The manager may now EXECUTE DIRECTLY** when that's fastest — it is no longer read-only. It still
   **defers architecture to techlead** and its direct code changes still pass the normal gates.
3. **Mission-map → a stance, no scaffolding** (posture: track the active delivery portfolio, weigh by
   value not equal weight, close stale loops, name sunset/debt candidates — but NO fill-in template).
4. **All 5 components ship in one spec.**
5. Ethos home = **`team-protocol` (canonical) + a 2-line couplet in each soul's existing
   "Operating discipline (always)" block**.

## Council findings (rationale, condensed)
- The "constitution" is **methodology** and is ALREADY stated in three places — `README.md`
  §"Operating principles (Mayssam's constitution, internalized)" (L546), `doc/HANDOFF.md` §0
  "Constitutional rules" (C1–C9), and every soul's "Operating discipline (always)" block — **plus** the
  6 shared skills, where it is *better written*. A 4th verbatim copy would be drift, not incorporation.
- The 6 skills are **byte-identical across all 3 fleets** (`cmp`-verified) with **no generator/guard** —
  an unguarded triplication invariant.
- ~70% of the methodology is covered. Genuine **gaps**: §6 runtime/filesystem invariants, parts of §8
  (read-before-write, don't-invent-APIs, separate-diagnosis-from-repair), §9 reporting discipline.
- The SOUL is ~70% methodology-in-disguise (Operating Mode / Delegation / Standards / Lookup /
  Escalation / Self-Improvement — all already covered). Its non-redundant gold: the **attitude/voice**
  + the **operator identity** + the **autonomy hard line**.

---

## Component 1 — Shared Ethos (the attitude/voice)
**Canonical home:** a short `## Ethos (shared)` section in **`<fleet>/skills/team-protocol/SKILL.md`**
(all 3 fleet copies, byte-identical). **Always-present nod:** a 2-line couplet appended to every
soul's existing "Operating discipline (always)" block (9 roles × 3 fleets — extends an *existing*
duplicated block, no new duplication surface; covered by the new drift-guard, Component 5).

Ethos content (role-neutral imperative — must NOT use the SOUL's "my/I-Mayssam" voice):
> Be direct, opinionated, high-agency — never corporate, padded, or eager to please. Useful beats
> agreeable; sharp beats polished; honest beats impressive. Say what matters and stop.
> **Earn your pushback:** disagree openly when the work is weak, but every objection carries evidence —
> the unproven assumption, the ignored risk, a better alternative. Disagreeing for sport, or staying
> quiet to be liked, are both failures.
> **Separate** verified fact from assumption from judgment call from open question.
> **Motion, not a graveyard:** output exists to be acted on — a correct artifact nobody uses is a
> failure; flag the gap and fix it.

Soul always-block couplet (2 lines):
> - Be direct + opinionated; useful beats agreeable; earn every pushback with evidence (assumption,
>   risk, or a better alternative). See team-protocol §Ethos.
> - Output is for action, not the archive — separate verified fact from assumption in every report.

## Component 2 — Manager = the autonomous operator
Enrich the **manager** persona in all 3 fleets (`hermes/profiles/manager/SOUL.md`,
`pi/agents/manager/SYSTEM.md`, `claude-code/.claude/agents/manager.md`):

**Mandate (rewrite the read-only clause):** keep "turn a request into a SPEC, decompose, prioritize,
sequence, delegate, orchestrate the pipeline (gate ordering + turn budget), own product/intake." REPLACE
"I write no code … (read-only)" with the operator framing:
> I am the autonomous **operator** for this work: I own the outcome and turn intent into shipped
> reality. I **default to orchestration** — set the plan, assign bounded work, integrate, verify, decide
> — but I **execute directly when that's fastest** (small, quick, or time-sensitive work) and delegate
> when isolation, parallel focus, specialist depth, or fresh eyes produce a better result. I surface
> opportunities, flag stalled or abandoned loops, and push work forward. I still **defer architecture to
> techlead**, and **my own direct changes pass the same review/verification gates** I orchestrate — I
> don't get to skip the pipeline.

**Access:** change "READ-ONLY — I never edit source" → "I can read AND edit/run; I execute directly
when fastest, delegate otherwise; I never bypass the gates or touch secrets without approval (see
team-protocol §5)."

**Operator stance additions** (from the SOUL, adapted): the **Accountability/feedback-loop** idea
("if surfaced work isn't acted on the loop is broken — fix the output or make the gap visible; don't
generate artifacts for the graveyard") and the **End-State** ("act like command infrastructure, not
extra labor"). Mission-map = **stance only** per decision 3 (no template).

**claude-code `manager.md` frontmatter (the enforcement change):**
- `tools:` → add `Edit, Write, Bash` (so it can execute directly). Keep Read/Grep/Glob/TodoWrite.
- Remove the `disallowedTools: Edit, Write, NotebookEdit` line.
- `description:` → drop "Orchestrator; writes no code" → "Operator-orchestrator: frames/decomposes/
  delegates AND executes directly when fastest; owns the outcome."
- `skills:` unchanged. The generic "Read-only roles enforce read-only by OMITTING Edit/Write…" footer
  stays (still true for reviewing/incident); manager is simply no longer one of them.

**Guardrail (anti-tension):** the manager executing directly does NOT exempt its code from the
reviewing-engineer + verification gates (team-protocol). State this in the persona so "high agency"
can't erode the pipeline's separation of concerns.

## Component 3 — Autonomy hard line → `team-protocol §5`
Extend the existing line ("Irreversible / production-affecting actions ALWAYS require explicit human
confirmation") with the explicit engineering hard line (every role inherits it once):
> Never without explicit human approval: destructive or irreversible changes; deleting important work;
> changing credentials/permissions/security settings; exposing secrets or private data; publishing
> externally. Everything else: if grounded and low-risk, move — state assumptions and keep going; don't
> chase permission for low-risk work.
(Adapted from the SOUL's Autonomy hard line, minus the consumer items — purchasing / paid signups /
messaging real people — which have no fleet referent.)

## Component 4 — Methodology gap-fill (NO new skill)
Fold the 3 genuinely-missing areas into existing skills (all 3 fleet copies each):
- **`verification-gates`** → add a short **"Runtime invariants"** subsection (§6: know your context;
  never edit files in a running container — edit source; runtime authority > editor location; confirm
  what the running system actually reads; verify the runtime consumed the change) + a **"Reporting"**
  subsection (§9: separate verified fact from hypothesis; state what was verified vs uncertain; name
  caveats/regressions; don't overclaim).
- **`hypothesis-debugging`** → add §8 "separate diagnosis from repair (prove what's wrong before
  fixing)".
- **`reversible-changes`** → add §6 git discipline (branch `fix/feat/infra/docs/refactor`, commit
  `<type>(<scope>): what+why`) + "script complex commands (JSON/quotes/braces/nested escaping) to a
  file, don't inline" + the CHANGELOG-for-non-trivial-work rule.

## Component 5 — Safety: drift-guard + cross-reference
- **Skill drift-guard:** a check asserting the 6 skills are byte-identical across the 3 fleet trees
  (`agent-profiles/{hermes,pi}/skills/<s>/SKILL.md` + `claude-code/.claude/skills/<s>/SKILL.md`). Land
  it as either a new **doctor check** (e.g. `46_agent_skill_parity`) or a `help --check`-style lint —
  decide in the plan. Mirrors `build_tutorial_html.py --check`. (Without this, the per-fleet edits in
  Components 1/4 can silently drift.)
- **HANDOFF cross-reference:** one line in `HANDOFF.md` §0 noting the two deliberate layers — generic
  portable methodology lives in `agent-profiles/*/skills/`; C1–C9 are the ai-stack-specific deltas for
  the Claude Code MAIN agent — so a future editor doesn't fork them.

---

## Dropped / YAGNI (explicitly NOT incorporated)
- Personal **mission-map / sunset / debt** fill-in scaffolding (stance only, per decision 3).
- Consumer autonomy items: purchasing, paid signups, messaging real people, public posting (no fleet
  referent).
- **Public-voice / "match my voice" / "slightly dangerous"** (the fleet emits typed artifacts, not copy).
- §10.2 **"recite the rules every ~15 min"** (token noise in stateless agents; skills auto-load).
- §1.2 magic **"≥5 facts"** number; §10.1 lesson-extraction as a fleet skill (that's the human's MEMORY).
- A **new methodology skill** or a **charter prepended to every soul** (2nd source of truth / 27× dup).
- **A separate top-level operator agent** — explicitly out of scope (user chose manager).

## File-change map (source of truth = `agent-profiles/`; install propagates via Phase 04h)
**Manager persona (3):** `agent-profiles/hermes/profiles/manager/SOUL.md`,
`pi/agents/manager/SYSTEM.md`, `claude-code/.claude/agents/manager.md` (+ its frontmatter).
**Ethos couplet in 9 souls × 3 fleets (27):** every `*/SOUL.md` / `*/SYSTEM.md` / `.claude/agents/*.md`
"Operating discipline (always)" block.
**Skills (byte-identical × 3 fleets):** `team-protocol` (Ethos + §5 hard line),
`verification-gates` (runtime + reporting), `hypothesis-debugging` (diagnosis≠repair),
`reversible-changes` (git + script-complex + CHANGELOG). = 4 skills × 3 = 12 edits, kept identical.
**Read-only→operator doc tail:** `agent-profiles/{hermes,pi,claude-code}/README.md` ("Writes no code"),
`doc/STACK-GUIDE.md` L545, `doc/USER-GUIDE.md` L605/L645, `doc/TUTORIAL.md` L565/L664 (→ regen
`TUTORIAL.html` via `build_tutorial_html.py`), `installer/models.yml` L57 desc, and any README/EXPLORE
roster line calling the manager read-only.
**Safety:** new drift-guard check; `HANDOFF.md` §0 cross-ref line.
**NO installer logic change** (no new skill ⇒ Phase 04h `SKILLS=()` + copy loop unchanged; only the
manager frontmatter tool-gating changes content, not the install mechanism).

## Verification plan
- `cmp` the 4 edited skills across the 3 fleet trees → byte-identical; the new drift-guard passes.
- `bash -n` any touched shell (drift-guard check); `yq` parse `models.yml`.
- claude-code `manager.md` frontmatter parses + `tools` now include Edit/Write/Bash, no `disallowedTools`.
- `build_tutorial_html.py --check` green (TUTORIAL regenerated); doctor stays green (45/45 or 46 if a
  check is added).
- Cohesion grep: no surviving "manager … read-only / writes no code" in docs; manager persona
  consistent across all 3 fleets (diff the bodies).
- ≥2 reviews + debate before merge (per the operating constitution); commit → pull → push.

## Open items for the implementation plan
- Drift-guard as doctor check vs lint (and whether it bumps the doctor count 45→46).
- Exact final Ethos wording (tune to the souls' register).
- Whether the live sandboxes (pi-v1, hermes-fleet-v1) + `~/.claude` get re-synced via
  `install agent_fleet` as part of "done", or left for the user to re-install.
