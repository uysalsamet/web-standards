# ADR-0012 — Metrics and tracing: Prometheus + OpenTelemetry

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [OBS-09], [OBS-10], [OBS-14], [OBS-15]

## Context

Metrics (how much/how often) and traces (where the time went) are separate problems and
can be solved with separate tools, or unified under a single standard (OTel).

## Options — metrics

### A) prometheus/client_golang + Prometheus (CHOSEN)
**Strengths:** The de facto standard. Pull model, if a service goes down it shows up as
"scrape failed". PromQL is powerful and widely known. Integrates naturally with Grafana.
Alert rules ([OBS-21]) live in the same place.
**Weaknesses:** The pull model is awkward for short-lived jobs (batch jobs); needs a
Pushgateway. Long-term retention needs an extra component (Thanos/Mimir/VictoriaMetrics).

### B) OTel metrics (a single standard)
**Strengths:** Metrics + traces + logs in one SDK, one configuration. Vendor-neutral.
**Weaknesses:** The metrics side is not as mature as the tracing side, and the ecosystem
still converts back to the Prometheus format. Adds an extra layer of complexity (OTel →
Prometheus exporter).

### C) VictoriaMetrics
**Strengths:** Prometheus-compatible, uses fewer resources, built-in long retention.
**Weaknesses:** A smaller community than Prometheus. Our scale does not require it.

## Options — tracing

### D) OpenTelemetry v1.45.0 (CHOSEN)
**Strengths:** A vendor-neutral standard; the backend (Jaeger, Tempo, a commercial APM)
can be swapped later. `otelgin` gives ready-made Gin integration. Context propagation
(`traceparent`) is standardized ([OBS-15]).
**Weaknesses:** SDK setup is detailed on first configuration. Sampling strategy requires
a deliberate decision ([OBS-17]).

### E) A direct Jaeger client
**Strengths:** Less abstraction.
**Weaknesses:** Jaeger deprecated its own clients in favor of OTel. Not preferred for new
projects.

## Decision

**Prometheus for metrics, OpenTelemetry for tracing.**

We use the mature standard in each area on its own terms. Using OTel for metrics too, to
get "one SDK", is tempting but today means an extra conversion layer with no real gain.

Per [OBS-14], tracing is **recommended, not mandatory**, setting it up before flows chained
across three or more services actually appear is premature optimization.

## Accepted costs

- Two separate SDKs and two separate configurations.
- Prometheus's limited long-term retention; an extra component will be needed if the need
  arises ([PERF-26]'s retention-period rule defers this).

## What would change this decision

- If the OTel metrics ecosystem matures and its Prometheus exporter becomes unnecessary,
  we move to a single SDK.
- If metric volume overloads a single Prometheus node, VictoriaMetrics/Mimir is evaluated.
