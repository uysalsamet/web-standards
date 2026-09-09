# ADR-0010 — Workflow engine: Temporal, only when needed

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [ASYNC-18], [ASYNC-19], [ASYNC-20], [ASYNC-26]

## Context

Some work does not fit into a single request-response cycle: multi-step approval flows,
processes that can run for days, work that needs **compensation** when a step fails,
scheduled reminders.

Writing these by hand means writing a state machine plus retries plus a timer plus
persistence every single time, and that code ends up slightly different, and slightly
buggy, in every project.

## Options

### A) Temporal v1.47.0 SDK / Server 1.31.2 (CHOSEN — conditionally)
**Strengths:** The most mature option in its class for long-running workflows. State
persistence, retries, timeouts, compensation (SAGA), timers, waiting on human approval,
all come from the infrastructure. Workflow code is written as if it were ordinary Go code;
crashes and restarts are transparent. A visibility UI shows where a given workflow is
stuck.
**Weaknesses:** **Serious infrastructure**: a server plus its own database plus workers
plus monitoring. The determinism constraint ([ASYNC-20]) requires a new mental model, and
violating it produces a bug class that surfaces weeks later. Workflow versioning
([ASYNC-23]) demands discipline.

### B) river (a Postgres-based job queue)
**Strengths:** Built on Postgres; **no new infrastructure component**. Enqueues jobs in
the same transaction as the application data, resolving the outbox problem. Actively
developed, bulk insert via `CopyFrom`, scheduled-job support.
**Weaknesses:** A **job queue**, not a workflow engine. Multi-step flows, compensation,
and long-lived state management like "resume in 3 days" have to be built by hand.

### C) asynq (Redis-based)
**Strengths:** Simple, runs on Redis, has a good admin UI.
**Weaknesses:** Puts Redis in a critical, persistent role (tension with [CACHE-24]).
Development has slowed. Still a queue, not a workflow engine.

### D) A manual state machine + cron
**Strengths:** Zero extra infrastructure; full control.
**Weaknesses:** Retries, idempotency, scheduling, observability, compensation, you write
all of it, and each one is its own source of bugs. Regretted by the second flow.

### E) Cadence
**Strengths:** Temporal's predecessor; similar capabilities.
**Weaknesses:** The ecosystem and development effort have moved to Temporal. Not preferred
for new projects.

## Decision

**Temporal, but only if the conditions in [ASYNC-18] actually hold.**

Decision tree ([ASYNC-01]):
- Single-step background work that can tolerate loss → **Postgres queue** (the problem
  river solves; also solved with our own ~50 lines, [ASYNC-03]).
- Multi-step flow needing compensation and running for days → **Temporal**.
- Setting up Temporal for a simple queue job is **forbidden** ([ASYNC-19]).

Temporal is powerful but heavy; the decision to set it up depends on demonstrating that the
problem it solves genuinely exists.

## Accepted costs

- Once Temporal is set up, there is one more component to operate (server + DB + workers).
- The determinism constraint is a new rule set the team must learn; violating it produces
  silent, delayed bugs.
- Two different async mechanisms (Postgres queue + Temporal) can coexist; "which one when"
  is answered by [ASYNC-01], but it is still a decision burden.

## What would change this decision

- If only simple background jobs exist, Temporal is never set up; **river** is then
  evaluated as a replacement for our own queue code (reduces duplication).
- If Temporal's operating cost outweighs its benefit (monitored), the flows are simplified.
