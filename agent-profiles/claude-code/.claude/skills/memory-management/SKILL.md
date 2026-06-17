---
name: memory-management
description: The operator's second-brain protocol — which memory surface holds what, retrieve-before-external, write the durable residue back, never fabricate, dedupe/refine, and treat an overwrite/delete or PII as §5. Load when a task reads or updates memory (status, a decision, a correction, the operating picture).
---

## Why this exists

An operator that doesn't remember is just labor. Memory is what turns scattered sessions into one coherent operating picture — but only if reads come BEFORE external lookup and writes are disciplined. A wrong or fabricated write poisons every future retrieval (the same class as deleting a live `.env`), so memory is a first-class, gated duty, not a scratchpad.

## The surfaces (know which holds what)

Memory is layered; write each fact to the surface that matches its lifetime:
- **Rolling buffer** (`.remember/now.md`) — the live "what I'm doing right now" focus; short-lived, overwrite-y.
- **Daily / recent logs** (`.remember/today-*.md`, `recent.md`) — the append-only record of what happened.
- **Verbatim recall** (MemPalace) — searchable verbatim conversation memory; query it for "what did we actually say / decide about X".
- **Durable cross-session facts** (`MEMORY.md` + its memory index) — one fact per entry with a one-line index pointer; the things that must survive across sessions (decisions, corrections, gotchas, project state).

Don't invent surface paths or tool flags — inspect what exists before reading or writing (verify, don't assume).

## Retrieve first

Before any external lookup OR any new work, check local + memory: prior notes, the operating picture, session history, the durable index. The answer or a prior decision often already exists; only reach outward when the answer depends on current/external data or local context is missing or stale.
- **Never invent a fact.** State what's known, what's unknown, and what would verify it.
- Every retrieved claim carries its **provenance** (which surface, when) and is kept separate from assumption.

## Write the durable residue back

When a task changes the operating picture — a decision made, a loop closed, a correction received, a state change, a lesson — write it to the RIGHT surface so the second brain is left more current than you found it:
- **Pick the surface by lifetime** (buffer vs daily vs durable index).
- **Additive writes are free** — adding a new fact, log line, or index entry needs no approval.
- **An overwrite / supersede / delete of an existing durable fact is §5** (destructive to the second brain): explicit human approval, and the write must declare what it supersedes and why. Prefer append/refine over clobber.
- **One fact per durable entry**, with a one-line index pointer — don't bury content in the index.
- **Dedupe + refine** — before adding, check for an existing entry that already covers it and update that rather than duplicate; delete an entry only when it's proven wrong (and that delete is §5).
- **Never persist secrets or PII** (credentials, private data, personal communications) into shared memory — §5 regardless of reversibility.

## Capture corrections

When the human corrects you, preserve the correction where it'll be found again (the durable index, as feedback) with the *why* and *how to apply* — so the second brain mirrors them over time instead of repeating the friction. Turn repeated friction into a checklist or rule.

## Verification
- Did I retrieve from memory BEFORE reaching external / starting new work?
- Is every claim I report sourced (which surface) and separated from assumption — no fabrication?
- Did I write the durable residue to the right surface, additively (not clobbering)?
- If I'm overwriting/deleting a durable fact, or touching secrets/PII — did I stop and treat it as §5 (human approval)?
