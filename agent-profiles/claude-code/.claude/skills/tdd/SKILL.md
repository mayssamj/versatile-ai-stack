---
name: tdd
description: Test-driven development: write the test first, then the code to pass it. Use when implementing or changing behavior.
---

## When to use
When adding or changing functionality where behavior can be expressed as tests.

## Procedure
1. Match the project's existing test framework, imports and conventions.
2. Write failing tests first: happy path, edge cases (empty/null/zero/max), and error cases.
3. Implement the minimum code to make them pass.
4. Refactor with the tests green.
5. Run the full suite before returning.

## Pitfalls
- Writing tests after the fact that only confirm what you already wrote.
- Skipping edge and error cases.
- Changing source instead of tests to make a failing test pass spuriously.

## Verification
- Tests existed and failed before the implementation.
- Happy, edge and error paths are covered.
- The full suite passes.
