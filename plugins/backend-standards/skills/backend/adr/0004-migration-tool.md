# ADR-0004 — Migration tool: goose

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [DB-12], [DB-13], [DB-14], [DB-15]

## Context

Schema changes must be versioned, applied in order, reversible, and must not break old
code during a rolling deploy ([DB-13]).

Our starting point was bad: some existing services globbed `tables/*.sql` files and ran
`CREATE TABLE IF NOT EXISTS`. This approach **cannot add a column to an existing table**
and is not reversible, it requires manual intervention on the first schema change.

## Options

### A) goose v3.27.3 (CHOSEN)
**Strengths:** `-- +goose Up` / `-- +goose Down` blocks live **in the same file**, making
it harder to write one and forget the other. As a Go library it can be **embedded in the
binary**: the service runs its own migration on startup, with no extra container or step
in the deploy flow ([DB-15]). `-- +goose NO TRANSACTION` supports `CREATE INDEX
CONCURRENTLY` ([DB-14]). Data transformations can also be written as Go migrations.
**Weaknesses:** Describes the schema as a step-by-step change rather than "what it should
look like"; does not detect schema drift on its own.

### B) golang-migrate v4.19.1
**Strengths:** Very widely used, supports many databases, a mature CLI.
**Weaknesses:** Up/down live in **separate files**, one can be updated and the other
forgotten. Last release November 2025; development pace slower than goose's.

### C) Atlas
**Strengths:** **Declarative**, you write the schema you want and it computes the diff.
Drift detection, dangerous-migration linting, CI integration. The most technically
advanced option.
**Weaknesses:** A separate tool, a separate mental model; some features are commercial.
For a small/medium team, the setup and learning cost outweighs the gain.

### D) Manual glob + `CREATE TABLE IF NOT EXISTS` (the legacy state)
**Strengths:** Zero dependencies.
**Weaknesses:** Unversioned, not reversible, cannot add columns, does not guarantee order.
**This is not a solution, it is deferred debt.**

## Decision

**goose.** The deciding factor is being **embeddable as a Go library**: the service runs
its own migration on startup, simplifying the deploy flow. Keeping Up/Down in the same
file also reduces the "forgot to write the down" mistake in practice.

## Accepted costs

- We gave up Atlas's drift detection and migration linting. In return we enforced
  dangerous migrations manually as rules ([DB-13], [DB-14]) and run them in integration
  tests ([TEST-14]).
- Glob-based legacy services' migrations must be ported, a separate piece of work.

## What would change this decision

- If the number of services grows and schema drift becomes a real problem, Atlas is
  reconsidered.
- If goose's maintenance stalls, we move to golang-migrate (the file format conversion is
  mechanical).
