# ADR-0011 — Testing: stdlib testing + stub + testcontainers

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [TEST-01], [TEST-05], [TEST-12], [VER-05]

## Context

Three separate decisions: (1) do we use an assertion library, (2) do we mock or stub
dependencies, and (3) what do we test the repository against.

## Options — assertions

### A) stdlib `testing` (CHOSEN)
**Strengths:** Zero dependencies. You write the error message yourself, so it is
**meaningful** (`expected 403, got %d`). The path recommended by the Go team.
**Weaknesses:** More verbose; repeats `if got != want { t.Fatalf(...) }`.

### B) testify
**Strengths:** `assert.Equal(t, want, got)` is short and readable; a rich set of matchers;
a mock package.
**Weaknesses:** A dependency. The distinction between `assert` (continues) and `require`
(stops) is constantly confused; a test using `assert` often produces a nil-pointer panic
right after the first failure.

## Options — test double strategy

### C) Hand-written stubs (CHOSEN)
**Strengths:** Since the service/repository is already an interface ([GEN-07]), a stub is
a few lines. Test-only fields like `reached bool` can be added, which is how [TEST-06]'s
"did the rejected request even reach the service" check becomes possible.
**Weaknesses:** When the interface changes, stubs are updated by hand.

### D) Mocks generated with mockgen / testify mock
**Strengths:** Regenerated automatically when the interface changes; call verification
(times, order) built in.
**Weaknesses:** Adds a code-generation step; generated mocks are not read or reviewed.
Over-specified mocks (verifying every call) make tests brittle, a refactor breaks the test
even when behavior is unchanged.

## Options — repository testing

### E) testcontainers-go + a real Postgres (CHOSEN)
**Strengths:** Verifies the SQL **actually** works: column names, constraints, type
mismatches, `ON CONFLICT` behavior, the migration itself. None of this is caught by a
mock DB.
**Weaknesses:** Slow (container startup) and requires Docker, so it is split off with a
build tag ([TEST-13]).

### F) sqlmock (a mock DB)
**Strengths:** Fast, no Docker needed.
**Weaknesses:** Verifies that **the mock was written correctly**, not that the SQL is
correct. A wrong column name still passes the test and breaks production. Produces false
confidence.

## Decision

**stdlib `testing` + hand-written stubs + testcontainers.**

The common theme: **it must never be unclear what a test verifies.** testify's brevity,
mockgen's automation, and sqlmock's speed all come at the cost of some ambiguity or false
confidence. Hand-written stubs and a real DB hide nothing about what they verify.

## Accepted costs

- Tests are longer (repeated assertions).
- Stubs are updated by hand when interfaces change. The compiler catches this, so it is
  not a silent cost.
- Integration tests need Docker and are slow, so they run under a separate command
  ([TEST-13]).

## What would change this decision

- If stub maintenance becomes a measurable burden (interfaces changing frequently),
  mockgen is evaluated.
- If the team is already using testify everywhere, this can be revisited for consistency,
  but then `require` usage must be mandated.
