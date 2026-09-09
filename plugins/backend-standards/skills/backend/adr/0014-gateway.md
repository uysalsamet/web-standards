# ADR-0014 — Gateway: our own Go gateway

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [GEN-08], [SEC-03], [SEC-10], [RES-01], [OPS-18]

## Context

We need a single external door: TLS termination, JWT validation, rate limiting, CORS,
routing, and **most critically**, stripping any `X-User-*` headers coming from the client
and rewriting them with validated values ([SEC-10]).

## Options

### A) Our own Go gateway (CHOSEN)
**Strengths:** The header-rewriting in [SEC-10] and the authorization model in [SEC-05]
are **specific to us**, in an off-the-shelf gateway this logic would have to be written in
a plugin language (Lua/WASM). Writing it in Go means the same language, the same test
tooling, the same logging standard ([OBS-01]), and it is **tested like ordinary code**.
The authorization fallback logic and the service route table are readable in one place.
**Weaknesses:** We own the maintenance. We write rate limiting, circuit breaking, and
retry ourselves. Security patches are our responsibility.

### B) Traefik
**Strengths:** Automatic service discovery via Docker labels, automatic TLS (Let's
Encrypt), a mature middleware set. Works very well with Compose.
**Weaknesses:** Custom authorization logic needs a separate service via ForwardAuth,
adding a network round trip to every request. Header manipulation is written in a
configuration language and becomes unreadable as it grows.

### C) Kong
**Strengths:** A rich plugin ecosystem, API management features, mature.
**Weaknesses:** Heavy (may require a database). Writing a plugin means learning Lua or the
Go PDK. Far more tool than we need.

### D) Envoy
**Strengths:** An industry-standard proxy; the most advanced traffic management, circuit
breaking, observability.
**Weaknesses:** Its configuration (xDS) has a steep learning curve. Hard to manage by hand
without a control plane. Overkill unless we are running a service mesh.

### E) nginx
**Strengths:** Familiar to everyone, very fast, reliable.
**Weaknesses:** JWT validation and dynamic authorization need Lua (OpenResty).
Configuration cannot be tested; errors only appear at runtime.

## Decision

**Our own Go gateway.**

The deciding reason: the most critical part of what the gateway does ([SEC-10]'s
header rewriting plus [SEC-05]'s authorization model) is our own business logic, not
infrastructure configuration. Writing that in a configuration language would produce an
untestable, unreviewable security control, and that control is the **single most
critical point** in the architecture.

Writing it in Go means ordinary code, ordinary tests (the [TEST-04] pattern applies to the
gateway too), ordinary logs, ordinary code review.

## Accepted costs

- We write and maintain rate limiting ([RES-04]), circuit breaking ([RES-15]), and retries
  ([RES-13]) ourselves.
- No automatic TLS certificate management, a reverse proxy (nginx/Caddy/a cloud LB) sits
  in front, or it is managed by hand.
- No automatic service discovery; a new service is wired in manually in four steps
  ([OPS-18]...[OPS-22]). Forgetting one of those steps produces a 404 that takes time to
  diagnose, which is why [OPS-20] carries an extra warning about it.

## What would change this decision

- If the number of services makes manual route management error-prone (repeated mistakes
  in manual wiring), **Traefik + ForwardAuth** is evaluated: routing and TLS go to it,
  authorization logic stays with us.
- If we move to Kubernetes ([ADR-0015](0015-orchestration.md)), an ingress controller
  already handles routing and this decision is reopened.
