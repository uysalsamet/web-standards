# ADR-0013 — API protocol: REST/JSON

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [API-01], [GEN-06], [GEN-08]

## Context

Services talk both to the outside world (browser, mobile) and to each other. Different
protocols could be chosen for each case.

## Options

### A) REST/JSON everywhere (CHOSEN)
**Strengths:** The browser speaks it natively, no intermediate layer needed. Can be tried
by hand with Postman/curl, a big convenience for debugging and for the [TEST-21] manual
verification flow. The frontend team learns no extra tooling. Routing, caching, and
logging at the gateway stay simple.
**Weaknesses:** The schema contract is not enforced by code, it is protected by
documentation and tests ([API-31]). JSON serializes larger and slower than protobuf.

### B) gRPC between services, REST outward
**Strengths:** A strong schema (protobuf), code generation, HTTP/2 multiplexing,
streaming, smaller payloads. Compile-time type safety for service-to-service calls.
**Weaknesses:** Two protocols, two tool sets, two error models, two observability paths.
The gateway needs gRPC↔REST translation. Manual testing gets harder (grpcurl). Our
service-to-service call volume is low, per [GEN-06] services already don't reach into each
other's databases, and most flows complete within a single service.

### C) Connect (connectrpc)
**Strengths:** gRPC-compatible but **callable directly from the browser**; the same
endpoint can speak both gRPC and HTTP/JSON. Removes gRPC's biggest drawback (browser
access). Built on `net/http`, works alongside Gin.
**Weaknesses:** Still means protobuf and a code-generation chain. Smaller ecosystem than
gRPC. Its benefit shows up in systems with high service-to-service call volume, which is
not us.

### D) GraphQL
**Strengths:** The client selects the fields it wants, no over-fetching. One endpoint,
many sources.
**Weaknesses:** Authorization drops to the field level and gets complicated (tension with
[GEN-10]). N+1 is the default behavior (a dataloader is mandatory). Caching is harder.
Rate limiting cannot be measured by "request count", query cost has to be computed
(tension with [RES-01]). Our workload (CRUD plus a map layer) does not carry the problem
GraphQL solves.

## Decision

**REST/JSON, everywhere.**

The deciding factor is not simplicity but **consistency cost**: a second protocol would
need a second version of everything the standard defines, the error body ([API-13]),
pagination ([API-18]), authorization ([SEC-05]), observability ([OBS-10]). The gain is
small for our usage profile, our service-to-service call volume is low.

## Accepted costs

- The schema contract is not enforced by code; tests and documentation catch breakage.
- JSON serialization cost and lack of type safety on service-to-service calls.
- Scenarios needing streaming will require a separate solution (SSE/WebSocket).

## What would change this decision

- If service-to-service call volume grows significantly and JSON serialization becomes a
  measurable cost, **Connect** is evaluated (before gRPC, its browser compatibility makes
  a second protocol a lighter burden).
- A need for real-time streaming (live location, telemetry) is a **separate decision** and
  does not cancel the REST decision.
