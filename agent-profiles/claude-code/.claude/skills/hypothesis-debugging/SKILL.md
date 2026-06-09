---
name: hypothesis-debugging
description: Systematic, hypothesis-first debugging. Use when a test fails, a build breaks, or behavior is unexpected.
---

## When to use
Any time something is broken or behaving unexpectedly and the cause is not obvious.

## Procedure
1. Reproduce the failure reliably and capture the exact error/behavior.
2. Localize: narrow to the smallest area that still shows the problem.
3. State a hypothesis: what you think is happening, why, and what evidence would confirm or falsify it.
4. Run the smallest safe test of that hypothesis; reflect on whether it matched.
5. Fix the root cause, then add a guard (test/assertion) so it cannot silently return.

## Pitfalls
- Changing several things at once so you can't tell what fixed it.
- Treating a symptom instead of the root cause.
- Thrashing: after ~4 failed attempts, stop and re-evaluate with a written summary.
- Repairing before the diagnosis is proven — **separate diagnosis from repair**: prove what's wrong first, then fix it; don't blend speculative diagnosis with broad edits.
- Inventing APIs, flags, or behavior — verify supported syntax from docs / `--help` / source / tests before relying on it.
- Editing code you haven't read — read enough surrounding context (callers, conventions, data flow) before changing it.
- Mistaking stale state (cached/compiled/old process/container/browser) for the real cause — rule it out before going deeper.

## Verification
- The original failure no longer reproduces.
- A regression test now covers the bug.
- You can explain the root cause, not just that it 'works now'.
