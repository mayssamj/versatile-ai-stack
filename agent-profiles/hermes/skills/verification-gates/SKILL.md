---
name: verification-gates
description: End-to-end verification and definition-of-done before claiming success. Use before reporting any task complete.
---

## When to use
Before declaring any change done or successful.

## Procedure
1. Confirm the intended change exists in the correct place.
2. Confirm the real runtime/user path actually uses it (not just a build or green log).
3. Run the relevant tests/validation and read the results.
4. Check integration and regression risk around the change.
5. Update the CHANGELOG for non-trivial work.

## Pitfalls
- Reporting success from a passing build or running process alone.
- Validating only in the container/shell, not the real user perspective.
- Skipping the regression check because the change 'looks small'.

## Runtime invariants
- Know which context you're operating in (host vs container vs WSL/VM vs a bind-mount view) — they are not interchangeable.
- Edit the SOURCE, never files inside a running container. The running system's authority beats the editor's location: the question is not "where did I edit?" but "what file does the runtime actually read?"
- After writing, confirm the runtime/container actually consumes the updated file — verify what it reads, not just where you saved.
- Don't assume two similar-looking paths are the same effective file; verify from the relevant runtime.

## Reporting
- Separate verified fact from hypothesis; state what you directly verified vs what is still uncertain.
- Name caveats, regressions, and follow-up risks. Don't overclaim — "exit 0 / build green / a good-looking log" is not "verified end-to-end".

## Verification
- Verified from the actual user/runtime perspective, not just internally.
- Tests/validation pass and were read, not assumed.
- Report separates what was verified from what remains uncertain.
