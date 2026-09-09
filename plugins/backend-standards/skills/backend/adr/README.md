# Decision Records (ADR)

> **ADR = Architecture Decision Record.** For every important technical choice: what we
> chose, what the alternatives were, the strengths/weaknesses of each, why we chose this
> one, and **what would change this decision**.
>
> **Why this exists:** A rule without a rationale gets deleted by the first person who
> dislikes it. "Why Gin, what if it had been Fiber?" gets asked again with every new
> developer. The records here settle that argument once, and say where to look if the
> decision **turns out to be wrong**.

---

## How to read this

- Read the relevant ADR before arguing about a choice. It has probably already been
  discussed.
- If you have new information not listed in the ADR (a new version, a new measurement, a
  license change), reopen the decision. "I think this is better" on its own is not enough.
- Every ADR ends with a **"What would change this decision"** section. If what it
  describes has actually happened, it is time to review the decision.

## Status labels

| Status | Meaning |
|---|---|
| **Accepted** | In force. Applied in the standard. |
| **Under review** | New information has surfaced; the decision is being reassessed. |
| **Superseded** | Replaced by another ADR; which one is recorded. |
| **Rejected** | Evaluated, not adopted. Why it was not adopted stays in the record. |

An ADR is **never deleted**. If it turns out to be wrong, its status becomes "Superseded"
and a new one is written. The record of the wrong decision is as valuable as the record
of the right one.

---

## Records

### Language and HTTP layer
| # | Decision | Chosen | Status |
|---|---|---|---|
| [0001](0001-http-framework.md) | HTTP framework | **Gin** | Accepted |
| [0002](0002-go-version.md) | Go version line | **1.25.12** | Accepted |
| [0013](0013-api-protocol.md) | API protocol | **REST/JSON** | Accepted |
| [0014](0014-gateway.md) | Gateway | **Our own Go gateway** | Accepted |

### Data
| # | Decision | Chosen | Status |
|---|---|---|---|
| [0003](0003-postgres-driver.md) | Postgres driver / ORM | **pgx v5, no ORM** | Accepted |
| [0004](0004-migration-tool.md) | Migration tool | **goose** | Accepted |
| [0009](0009-cache-engine.md) | Cache engine | **Valkey** | Accepted |
| [0016](0016-database.md) | Primary database | **PostgreSQL** | Accepted |

### Application layer
| # | Decision | Chosen | Status |
|---|---|---|---|
| [0005](0005-logging.md) | Logging | **log/slog** | Accepted |
| [0006](0006-configuration.md) | Configuration | **os.LookupEnv** | Accepted |
| [0007](0007-input-validation.md) | Input validation | **Manual, in the handler** | Accepted |
| [0011](0011-testing-approach.md) | Testing approach | **stdlib + stub + testcontainers** | Accepted |
| [0012](0012-metrics-and-tracing.md) | Metrics and tracing | **Prometheus + OTel** | Accepted |
| [0018](0018-authentication.md) | Authentication | **JWT at the gateway** | Accepted |

### Async and operations
| # | Decision | Chosen | Status |
|---|---|---|---|
| [0008](0008-messaging.md) | Messaging | **Postgres queue → Kafka (franz-go)** | Accepted |
| [0010](0010-workflow-engine.md) | Workflow engine | **Temporal (only when needed)** | Accepted |
| [0015](0015-orchestration.md) | Orchestration | **Docker Compose** | Accepted |
| [0017](0017-service-boundaries.md) | Service boundaries | **Start with a modular monolith** | Accepted |

---

## Writing a new ADR

File name: `NNNN-short-topic.md` (number always increasing, never reused).

```markdown
# ADR-NNNN — <Topic>: <Chosen>

- **Status:** Accepted
- **Date:** YYYY-MM-DD
- **Related rules:** [XXX-NN], [YYY-NN]

## Context
What problem are we solving? Why do we have to make a decision at all?

## Options

### A) <Option>
**Strengths:** …
**Weaknesses:** …

### B) <Option>
…

## Decision
What we chose and **why**. The rationale must rest on a measurement, a constraint or a
concrete risk; "more modern" or "everyone uses it" is not a rationale.

## Accepted costs
What this choice costs us. Every decision means giving something up; if nothing given up
is written down, the decision is not honest.

## What would change this decision
What concrete development would make us reopen this record?
```

**Rule:** The "Accepted costs" section must never be left empty. If you wrote a decision
with no cost at all, either you did not examine the alternatives closely enough, or the
decision was never really contentious, in which case it does not need an ADR.
