# ADR-0005 — Logging: log/slog (stdlib)

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [OBS-01], [OBS-06], [VER-05], [VER-07]

## Context

Logs must be structured (JSON) so they are searchable ([OBS-01]). `log/slog` has been in
stdlib since Go 1.21; before that this was handled by third-party libraries.

## Options

### A) log/slog — stdlib (CHOSEN)
**Strengths:** **Zero dependencies.** Being stdlib means the ecosystem is moving toward
it; libraries integrate via `slog.Handler`. Context propagation via `With()`, level
management, and a JSON handler all come ready-made. No risk of abandonment.
**Weaknesses:** More allocations than zerolog/zap, a measurable difference in systems
writing tens of thousands of lines per second.

### B) zerolog
**Strengths:** Near-zero allocation, very fast, an elegant chained API.
**Weaknesses:** A dependency. Needs adapters for ecosystem integrations.

### C) zap (uber-go)
**Strengths:** Very fast, mature, widely used in enterprise settings.
**Weaknesses:** A two-tier API (`Logger` / `SugaredLogger`) that is unnecessarily complex.
A dependency.

### D) logrus
**Strengths:** Historically the most common; plenty of examples.
**Weaknesses:** In maintenance mode. Not used in new projects.

## Decision

**log/slog.** Logging speed is not our bottleneck, the overwhelming majority of a
request's duration is spent in the DB ([09](../09-PERFORMANCE-COST.md)); a few hundred
nanoseconds per log line does not show up in total latency. Against that, the dependency
saving is concrete: one less package to upgrade, security-scan, and carry abandonment risk
for.

[VER-07] ("if stdlib solves it, do not pull a package") applies here directly.

## Accepted costs

- We give up zerolog's allocation advantage in high-volume logging scenarios.
- Some third-party libraries expect their own logging interface; a bridge may be needed.

## What would change this decision

- If profiling **shows** log allocation taking a meaningful share of the hot path
  (measured through the [PERF-18] flow), zerolog is evaluated.
- Without that measurement, a change proposed on "it's faster" grounds is not accepted.
