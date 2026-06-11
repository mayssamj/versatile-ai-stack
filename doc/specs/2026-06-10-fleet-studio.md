# Fleet Studio — interactive review & edit tool for the agent fleet

- **Date:** 2026-06-10
- **Status:** Approved design → ready for implementation plan
- **Artifact:** `doc/FLEET.html` (single self-contained file; no server, no build step, no generator)
- **Spec author:** brainstormed with the human; quality gate = 2 reviews (adversarial + AI-expert) + 3-way debate **before** commit/merge.

## Problem

The agent fleet lives in `agent-profiles/` as **9 role personas × 3 frameworks + a shared skill pack + per-fleet docs = 51 markdown files**. There is no single place to *review* what each agent does and how its identity/skills are wired, and no convenient way to *edit* those files together. Today you open them one by one in an editor, with no cross-framework view (the same persona is wrapped three ways) and no at-a-glance metadata (model, tools, skills).

## Goals

1. **Review** every fleet file in one interactive page: a parsed summary card (role, framework, model, tools, skills, mandate) + the full rendered markdown.
2. **Edit & save** any file back to disk directly, with no server and no manual copy-paste round-trip.
3. **Compare** the same role across the three frameworks side-by-side (the personas are near-identical bodies wrapped per framework).
4. **Never go stale** — always reflect the live files on disk.
5. **Never lose data** — writes are explicit, reversible, and git-backed.

## Non-goals (YAGNI)

- Creating, renaming, or deleting files (edit-only — smaller blast radius).
- "Edit once → sync the change to all 3 frameworks" (risky; future work).
- Syntax highlighting / a full code editor (plain monospace textarea is enough).
- A server, a generator (`build_*.py`), a `--check` drift guard, or a doctor check — **none are needed** because nothing is embedded; the tool reads live files.
- Editing files outside `agent-profiles/`.

## Decisions (locked with the human)

| Decision | Choice | Rationale |
|---|---|---|
| **Save mechanism** | File System Access API — live read + write, no server | True single file; writes the real files directly; never stale; zero build step. |
| **Scope** | All 51 files (3 fleets × {9 personas, 6 skills} + 3 BOOTSTRAP + 3 README) | "Review all my fleet files" — nothing hidden. |
| **Location** | `doc/FLEET.html` | Matches `EXPLORE/TUTORIAL/DIAGRAMS/USER-GUIDE.html`. FSA folder-pick makes location functionally irrelevant → convention decides. |
| **Editability** | Edit existing only; no create/delete | Reduces data-loss surface; matches the request ("review and edit/update"). |
| **Undo model** | git working tree | `agent-profiles/` is tracked; a bad save is `git checkout`-recoverable. No in-app backup files. |

## Architecture

A single static `doc/FLEET.html` — all HTML/CSS/JS inline, no network fetches. Three **pure, independently-testable** units sit behind one thin impure I/O shell:

```
fleet-studio.html (all inline)
   │  showDirectoryPicker()                 ← human grants agent-profiles/ once (user gesture)
   ▼
DirectoryHandle ── walk() ──► FileEntry[]    (recursive crawl of *.md)
                      │
                      ├─ classify(relPath)  → { fleet, category, role|skill|doc }   [PURE]
                      ├─ extractMeta(text)  → { title, model, tools[], skills[], mandate, … } [PURE]
                      └─ renderMarkdown(txt)→ safe HTML for the Read view            [PURE]
                      │
                      ▼
        left nav tree            center pane: meta card + Read/Edit toggle
                                       │
                                  [Save] → handle.createWritable() → write real file  [IMPURE shell]
```

- **`walk(dirHandle)`** — recursively yields every `.md` file with its relative path + `FileSystemFileHandle`.
- **`classify(relPath)`** — pure path → `{ fleet, category, name }`. Rules below.
- **`extractMeta(category, framework, text)`** — pure text → summary fields for the card. Heuristic; the Read view always shows full markdown, so a missed field loses nothing.
- **`renderMarkdown(text)`** — pure, HTML-escaped-first minimal markdown renderer (headings, lists, fenced/inline code, bold/italic, links, blockquote, hr, tables). No external lib → offline + single-file + no supply chain.
- **I/O shell** — `showDirectoryPicker`, read on demand, write only on explicit Save.

### File discovery & classification (the load-bearing logic)

Generic walk, then classify by relative path — **no per-fleet hardcoding beyond these rules**, so new roles/skills appear automatically:

```
fleet      = first path segment            (claude-code | hermes | pi | <any new top dir>)
basename   = last path segment

if basename == "SKILL.md"                     → category=skill,   name = parent folder
elif basename in ("BOOTSTRAP.md","README.md") → category=doc,     name = basename
elif basename in ("SOUL.md","SYSTEM.md")      → category=persona, role = parent folder
elif parentFolder endsWith "agents" and ext==".md"   (claude-code flat agents)
                                              → category=persona, role = basename w/o ".md"
else                                          → category=other   (still shown, ungrouped)
```

This resolves all three layouts:
- `claude-code/.claude/agents/<role>.md` → persona (flat-file branch)
- `claude-code/.claude/skills/<skill>/SKILL.md` → skill
- `hermes/profiles/<role>/SOUL.md` → persona
- `hermes/skills/<skill>/SKILL.md` → skill
- `pi/agents/<role>/SYSTEM.md` → persona
- `pi/skills/<skill>/SKILL.md` → skill
- `<fleet>/{BOOTSTRAP,README}.md` → doc

### Metadata extraction (per framework)

- **claude-code persona** — parse YAML frontmatter (`--- … ---`): `name`, `description`, `model`, `tools` (comma list), `skills` (yaml list).
- **hermes `SOUL.md` / pi `SYSTEM.md`** — no frontmatter; extract by convention:
  - **title**: first H1 line whose text does **not** contain `.md` — skips the `# SOUL.md — …` / `# SYSTEM.md — …` file-banner heading and lands on the real role title `# Manager — …`.
  - **mandate / access / invoke**: text following the `**Mandate.**`, `**Access.**`, `**Invoke when**` markers up to the next blank line.
  - **model**: first `id: "…"` inside a fenced config block (e.g. `claude-opus-4.8-sub-xhigh`).
  - **skills**: the `**Shipped (load these):**` line under "Recommended skills".
- **`SKILL.md`** — parse frontmatter `name`, `description`.

All extraction is best-effort and non-fatal; the full rendered/raw body is always available regardless.

## UI / layout

```
┌───────────────────────────────────────────────────────────────────────┐
│ Fleet Studio   [Connect folder ✓]   group:(• by fleet ○ by role)  🔍___ │
├──────────────────────┬────────────────────────────────────────────────┤
│ ▾ claude-code         │  manager · hermes/profiles/manager/SOUL.md      │
│    ▾ personas (9)      │  ┌──────────────────────────────────────────┐   │
│       manager      ●  │  │ ROLE manager   MODEL opus-4.8-sub-xhigh   │   │
│       techlead        │  │ ACCESS read+write+run  SKILLS team-proto… │   │
│       …               │  │ MANDATE Turn a raw request into a SPEC…   │   │
│    ▸ skills (6)        │  └──────────────────────────────────────────┘   │
│    ▸ docs (2)          │  [ Read ⟷ Edit ]              ● unsaved          │
│ ▸ hermes               │  ┌──────────────────────────────────────────┐   │
│ ▸ pi                   │  │ (rendered markdown, or raw <textarea>)    │   │
│                        │  └──────────────────────────────────────────┘   │
│ 51 files · 2 dirty     │  [Save]  [Save all]  [Revert]                    │
└──────────────────────┴────────────────────────────────────────────────┘
```

- **Group toggle** — *by fleet* (claude-code/hermes/pi → personas/skills/docs) **or** *by role* (manager → its 3 framework files together). The "by role" pivot is the core review payoff.
- **Search** filters the tree by filename / role / content substring.
- **Dirty `●`** marks unsaved files in tree + footer.
- **Read/Edit** per file: Read = rendered markdown; Edit = monospace textarea.

## Edit, save & data-loss safety (non-negotiable)

- Writes happen **only** on explicit **Save** / **Save all** — never auto-save, never on selection change or navigation.
- Each opened file caches its **loaded-original** in memory → **dirty detection + Revert**.
- `beforeunload` warns if any file is dirty.
- First save shows a one-time note: *"git is your undo — `agent-profiles/` is tracked."*
- No create/rename/delete. No writes outside the granted directory handle.

## Browser support & graceful fallback

- **Chrome / Edge** — full live read + write (`file://` is a secure context; `window.isSecureContext === true`).
- **Safari / Firefox** (no FSA write) — auto-detect and fall back to: **read** via `<input type=file webkitdirectory>` (directory upload) + **save** via per-file Download / Copy-to-clipboard. A banner states the active mode honestly — no silent breakage, no fake "Saved".

## Verification plan (Definition of Done)

**Gate 0 (must pass before anything else):** in real Chrome, open `file://…/doc/FLEET.html` → Connect `agent-profiles/` → edit a throwaway change in one file → **Save** → confirm the on-disk file changed via `git diff`, then `git checkout` to revert. If `file://` + FSA ever fails on this machine's Chrome, fall back to a tiny localhost `fleet-edit` server (re-decide with the human at that point).

**Automated (Playwright, headless):**
1. Page loads from `file://` with **zero console errors**.
2. Pure units exercised via `browser_evaluate` against **all 51 real files**: `classify` assigns every file to the right fleet/category (51/51, 0 "other"); `extractMeta` returns a non-empty title for every persona and a model for every claude-code persona; `renderMarkdown` output contains no unescaped `<script`.
3. UI smoke: tree renders 3 fleets, group-toggle pivots to 27 personas under 9 roles, search narrows the list.

**Review gate (before merge):** 2 subagent reviews (adversarial + AI-expert/frontend) + 3-way debate; then pull → commit → merge → push.

## Risks & mitigations

| Risk | Mitigation |
|---|---|
| `file://` blocks FSA on some Chrome build | Gate 0 catches it first; documented localhost-server fallback. |
| Accidental bad save | Explicit-save-only + Revert + `beforeunload` + git undo. |
| Markdown XSS from file content | HTML-escape before render; own files but escaped regardless. |
| Classification misses a future file shape | `else → "other"` keeps it visible/editable rather than dropping it. |
| Metadata heuristic misses a field | Non-fatal; full body always shown in Read/Edit. |

## Definition of Done

- [ ] `doc/FLEET.html` exists, opens from `file://`, zero console errors.
- [ ] Connects `agent-profiles/`, lists all 51 files, classified 51/51.
- [ ] Cards populate for all 3 frameworks; group toggle + search work.
- [ ] Gate 0 save round-trip proven on disk (then reverted).
- [ ] Safari/Firefox fall back honestly (read + download/copy).
- [ ] 2 reviews + debate passed; merged to `main` and pushed.
