# ADR-0017 — Service boundaries: start with a modular monolith

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [GEN-06], [STR-04], [ASYNC-25], [DB-03]

## Context

This standard assumes a microservice architecture ([GEN-08], gateway + services). But
**how many services** is a separate question, and this is where the most expensive
mistakes get made: service boundaries drawn before the business domain is understood well
enough cannot be fixed later.

## Options

### A) Start a new project as a modular monolith (CHOSEN)
One deployable unit, but with clear module boundaries inside it: each module owns its own
`handler → service → repository` chain and its own tables; modules **never** call another
module's repository directly, they go through its service interface.
**Strengths:** If a boundary is drawn wrong, fixing it is a refactor, not a migration
project. One deploy, one log stream, one DB connection budget ([DB-03] stays comfortable),
no distributed-transaction problem, local calls mean no network errors or latency.
**Weaknesses:** A single failure domain; a panic in one module affects all of them
(partially bounded by [RES-18]). Modules cannot scale independently. Boundary discipline
is enforced by **code review**, not the compiler (Go's `internal/` enforces it partially).

### B) Start with microservices from day one
**Strengths:** Independent deploy and scaling, technology freedom, clear team ownership.
**Weaknesses:** Boundaries get drawn before the domain is understood, and **drawn wrong**.
The result: changing three services at once for a single feature, distributed
transactions, eventual consistency showing up everywhere ([ASYNC-25]), monitoring becoming
impossible without tracing ([OBS-14]), and the Postgres connection budget exploding with N
services × M connections ([DB-03]). These costs start on day one; the payoff only comes at
scale.

### C) Coarse-grained, domain-based services
Example: 3-5 services like "transport", "infrastructure", "social services", each modular
internally.
**Strengths:** A reasonable middle ground between the two extremes; aligns with team
ownership.
**Weaknesses:** Where the boundary falls is still a guess, just fewer guesses.

## Decision

**Start new projects as a modular monolith; require a concrete reason to split a module
into a service.**

Reasons that justify splitting into a service:
- The module's **scaling profile** differs (e.g. map/tile traffic is 100x the rest).
- The module's **rate of change** and ownership belong to a different team.
- The module's **failure isolation** is critical (its crash must not affect others).
- The module needs a different **runtime** (e.g. GPU, a different language).

"We'll grow into it eventually" is **not** one of these reasons.

This standard's rules apply either way; in a modular monolith, read "module" wherever it
says "service". [GEN-06] (owns its own schema) applies at the module level too, so that the
day it is split out, the work becomes mechanical.

> **Note:** Existing microservice repositories are out of scope for this ADR. This
> decision targets **new projects** and is not a reason to merge a working system.

## Accepted costs

- We give up independent scaling and independent deploy from the start.
- Maintaining module boundaries depends on discipline; violations are caught by code
  review, not the compiler ([CI-11] step 6).
- The day a module is split out, a refactor task appears, but because the boundaries were
  drawn correctly, it is a **known** task.

## What would change this decision

- If one of the four reasons above becomes concrete, that module is split off.
- If the number of teams grows and collisions in the same codebase become a real
  slowdown, domain-based splitting is evaluated.
