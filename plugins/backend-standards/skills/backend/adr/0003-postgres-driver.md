# ADR-0003 — Postgres access: pgx v5, no ORM

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [VER-05], [VER-06], [DB-01], [DB-18], [DB-20]

## Context

Two separate decisions: (1) which driver, and (2) do we write queries by hand or use an
abstraction.

## Options — driver

### A) pgx v5.10.0 (CHOSEN)
**Strengths:** The de facto standard since `lib/pq` went into maintenance mode. Native
connection pool (`pgxpool`), context support, fast bulk loading via `CopyFrom`, `Batch`,
correct handling of Postgres-specific types (jsonb, array, geometry), a clear speed
advantage on large result sets. The error object exposes the SQLSTATE code **and the
constraint name** via `*pgconn.PgError`, and [DB-20]'s error translation is built exactly
on that.
**Weaknesses:** A different API from `database/sql`; `lib/pq` code does not port over
directly.

### B) lib/pq v1.10.9
**Strengths:** `database/sql`-compatible, familiar to everyone, already present in
existing legacy code.
**Weaknesses:** **In maintenance mode**, no new features. No pool of its own. Slower on
large result sets.

### C) sqlx
**Strengths:** A thin layer over `database/sql`; makes scanning into structs easier.
**Weaknesses:** Not a driver but a wrapper, still needs a driver underneath. What it gives
us we already get from column constants plus a shared `scanX` helper.

## Options — abstraction

### D) Manual SQL (CHOSEN)
**Strengths:** The generated SQL is exactly what is written; it can be `EXPLAIN`ed, read,
and tuned to the index. Problems like N+1 and ordering without a tie-break are **visible
on sight**.
**Weaknesses:** Repetitive scan/column code. Bounded by column constants plus `scanX`
([DB-17]).

### E) GORM
**Strengths:** Fast to start, automatic migrations, relationship management.
**Weaknesses:** Hides the SQL it generates and **makes N+1 easy**. Performance problems
surface under production load; diagnosing them means looking inside the ORM. Automatic
migration generation is dangerous in production. "Helpful" behaviors (like soft delete)
silently alter queries.

### F) sqlc
**Strengths:** You write SQL, it generates type-safe Go code. The control of manual SQL
plus the convenience of code generation. **A genuinely good option**, and it came close to
being chosen.
**Weaknesses:** Adds code generation to the build flow. Dynamic queries (optional filters,
dynamic `WHERE`) still have to be written by hand, and most of our list endpoints have
dynamic filters.

### G) ent
**Strengths:** Schema-first, strong type safety, graph queries.
**Weaknesses:** Its own world; steep learning curve, high exit cost.

## Decision

**pgx v5 + hand-written SQL.**

For the driver, pgx is the only sensible choice since `lib/pq` is in maintenance mode.

For the abstraction, manual SQL, because most of this standard's database rules, the
[DB-19] tie-break, the [DB-28] ban on N+1, the [DB-27] `EXPLAIN` requirement, assume the
**ability to see the generated SQL**. An ORM closes off that visibility and makes the
rules unenforceable.

## Accepted costs

- Scan/column code repeats in every module; bounded but not eliminated.
- Type safety comes from tests, not the compiler, so a repository integration test is
  **mandatory** ([TEST-12]).
- Legacy code written with `lib/pq` must be translated by hand when it is migrated to
  this standard.

## What would change this decision

- If the need for dynamic filters drops and queries stabilize, **sqlc** is reconsidered.
- If pgx's maintenance stalls (12+ months without commits), the driver decision is
  reopened.
- If repository duplication turns into a measurable maintenance burden, a separate ADR is
  written for a move to sqlc.
