# ADR-0001 — HTTP Framework: Gin

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [GEN-01], [GEN-02], [VER-05]

## Context

All HTTP services must use a single framework. Different frameworks mean: a different
middleware set, a different error body, a different test pattern, a different security
surface, and the shared `pkg/` package behaving differently in each service.

The deciding factor is not the speed difference between candidate frameworks, it is
**which HTTP core they sit on**. Gin, Echo and chi are built on Go's `net/http`; Fiber sits
on a separate implementation, `fasthttp`.

## Options

### A) Gin v1.12.0 — `net/http` (CHOSEN)
**Strengths:**
- `net/http` compatibility means the entire Go ecosystem works: `otelhttp`/`otelgin`,
  `httptest`, `pprof`, every library that accepts an `http.Handler`, every middleware.
- HTTP/2 comes free from stdlib.
- The API has not broken in years (v1 line). The slow release cadence is an
  **advantage** here: no upgrade surprises.
- The largest Go framework community, meaning the most examples, the most developers who
  know it, and **the framework AI produces the most reliable code for**.
- Timeouts live on `http.Server`, i.e. in stdlib's well-known place ([RES-07]).

**Weaknesses:**
- `*gin.Context` creates some lock-in (chi has none).
- No built-in rate limiter; we write our own ([RES-04]).
- Static/parameter sibling routes in its router have historically been a source of
  panics (supported since v1.7, but we never create the ambiguity in the first place —
  [API-01b]).

### B) Fiber v3.4.0 — `fasthttp`
**Strengths:**
- Fastest in synthetic benchmarks; low allocation.
- Express-like API, familiar to a team coming from JS.
- v3 is very actively developed; it also accepts `net/http` handler signatures.

**Weaknesses:**
- **No HTTP/2.** `fasthttp`'s architecture is incompatible with HTTP/2; official support
  is still "under construction". For services the browser talks to directly (tiles,
  static assets), this is a real gap.
- The ecosystem is thinner; friction with libraries that expect `net/http`.
- The breaking v2 → v3 migration happened in February 2026 (`*fiber.Ctx` → `fiber.Ctx`,
  `BodyParser` → `Bind().Body()`). Since most training data is still v2, **AI keeps
  generating v2 syntax**, needing correction every time.
- `fasthttp`'s buffer reuse creates a trap class of bugs requiring copies whenever a
  value escapes the handler.

**The performance gap does not apply to us:** 95%+ of a request's duration is spent in the
DB query (5-50 ms). The framework's share is on the order of microseconds; unmeasurable.

### C) chi v5.3.1 — `net/http`
**Strengths:** Zero lock-in (pure `http.Handler`), the longest-lived technical choice,
closest to stdlib idioms, minimal.
**Weaknesses:** Binding, error handling, response helpers, you build all of it yourself.
This increases the number of rules the standard must write, and each team produces its own
solution, which works against the goal of "one standard".

### D) Echo v5.3.1 — `net/http`
**Strengths:** Very close to Gin, `net/http`-based, batteries-included.
**Weaknesses:** No clear edge over Gin; smaller community and example pool. Choosing the
more common of two similar options is a sufficient tie-break.

## Decision

**Gin v1.12.0.** Three deciding reasons:

1. **`net/http` compatibility** removes ecosystem friction and gets HTTP/2 for free.
2. **API stability** means upgrades do not produce surprises; the standard's code examples
   stay valid for years.
3. **AI reliability** matters because this standard will be applied by AI agents. Gin's
   huge and consistent corpus noticeably raises the odds that generated code is correct
   the first time.

Performance played **no** role in this decision, nor should it have.

## Accepted costs

- We gave up Fiber's synthetic benchmark edge. (Unmeasurable at our load.)
- We accepted `*gin.Context` lock-in and gave up chi's zero-lock-in advantage. In return we
  got one ready-made path for binding, errors and responses.
- We write the rate-limit middleware ourselves (~40 lines, [RES-04]).
- **The biggest cost:** existing services written in Fiber will remain in place for a
  while, meaning the repositories will be **mixed** during the transition. This is a
  deliberate decision ([VER-17], [VER-18]): every service written from now on is Gin;
  older ones are migrated one by one when they are touched. There is no bulk migration
  project, converting 34 services at once would stop the whole team for weeks and produce
  no user value. The cost of the mix is limited to copy-paste risk and is managed by the
  countermeasures in [VER-18].

## What would change this decision

- If `fasthttp` ships real, stable HTTP/2 support, Fiber's biggest gap closes.
- If Gin's development stalls (no commits for over 12 months), a move to chi is evaluated.
- If the project develops a real gRPC/HTTP2-heavy need, this is revisited together with
  [ADR-0013](0013-api-protocol.md).
- If a measured, real workload **shows** the framework is the bottleneck, this has not
  happened in any CRUD service to date, but if it does, the record is reopened.
