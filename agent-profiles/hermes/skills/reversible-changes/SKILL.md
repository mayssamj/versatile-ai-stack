---
name: reversible-changes
description: Prefer reversible changes with a clear rollback path. Use before any risky or hard-to-undo change.
---

## When to use
Before edits to important files/config, schema changes, or anything hard to undo.

## Procedure
1. Back up or snapshot the important files/config first.
2. Make the smallest safe change that validates the goal; avoid stacking unrelated edits — one logical change at a time so a failure stays diagnosable.
3. Keep a clear, written rollback path.
4. Record non-trivial changes in the CHANGELOG (goal, files touched, outcome, rollback note).
5. Git discipline: work on a branch (`fix/ feat/ infra/ docs/ refactor/`), commit `<type>(<scope>): what & why`; never commit straight to `main` on shared repos.
6. Script complex commands (anything with JSON, nested quotes, braces/brackets, f-strings, or multi-layer shell escaping) to a file and run the file — don't inline them; treat shell boundaries as hostile.

## Pitfalls
- Large mixed diffs that can't be partially reverted.
- Destructive operations with no snapshot or backup.
- No documented way back if the change misbehaves.

## Verification
- A rollback path exists and is written down.
- The diff is minimal and scoped to the goal.
- Backups/snapshots were taken before the risky step.
