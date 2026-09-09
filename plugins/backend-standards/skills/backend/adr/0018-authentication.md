# ADR-0018 — Authentication: JWT at the gateway, a shared secret and a permission header between services

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [SEC-03], [SEC-04], [SEC-05], [SEC-10], [GEN-09]

## Context

There are two separate problems here:
1. **User identity:** how does the client prove who it is?
2. **Service-to-service trust:** how does a service know a request genuinely came from the
   gateway?

## Options — user identity

### A) JWT, validated only at the gateway (CHOSEN)
**Strengths:** Stateless; the gateway validates on every request without hitting the DB.
Because validation happens in **one place**, critical checks like `alg=none`, expiry, and
signature verification are written once and written correctly ([SEC-03]). Services do not
even import a JWT library.
**Weaknesses:** Revocation is hard, a token stays valid until it expires. Mitigation: a
short-lived access token plus a refresh token plus a revocation list (Redis).

### B) JWT validated in every service
**Strengths:** Protection remains even if the gateway is bypassed.
**Weaknesses:** Security code repeated across 30 services; someone will inevitably skip a
check. The signing key gets distributed to 30 services, a 30x larger attack surface.

### C) Opaque token + introspection
**Strengths:** Instantly revocable; token content never leaks.
**Weaknesses:** Every request makes a call to the auth service, adding latency and a
single point of failure. Per [SEC-08], if the auth service goes down we fail closed,
meaning the whole system stops.

### D) Session cookie (server-side session)
**Strengths:** Instant revocation, a simple mental model.
**Weaknesses:** Holds state (tension with [PERF-29]); awkward for mobile and
service-to-service use.

## Options — service-to-service trust

### E) `X-Gateway-Source` + a shared `X-API-Key` + `X-User-Permissions` (CHOSEN)
**Strengths:** Simple, fast, no extra infrastructure. A service rejects any request that
bypassed the gateway ([SEC-04]), meaning the internal network is never assumed
"trusted" ([GEN-09]).
**Weaknesses:** The shared secret is a single value; if it leaks, every service is
affected. Rotation is manual. Anyone able to sniff the internal network can see the
headers if internal traffic is not TLS.

### F) mTLS (mutual certificates)
**Strengths:** Cryptographically strong; each service has its own identity. No single
secret to leak.
**Weaknesses:** Certificate issuance, distribution, and renewal, effectively running a
PKI. Managing this by hand without a service mesh is cumbersome.

### G) A per-service JWT (an internal token)
**Strengths:** Each service has its own identity; time-limited and revocable.
**Weaknesses:** Requires a token service and a distribution mechanism.

## Decision

**JWT at the gateway, plus `X-Gateway-Source`/`X-API-Key`/`X-User-Permissions` between
services.**

The **single most critical point** of this architecture is [SEC-10]: the gateway must
**strip** any `X-User-*` and `X-Gateway-*` headers coming from the client and rewrite them
with values it has validated itself. Failing to do so lets a client send
`X-User-Permissions: *` and become a superadmin. This is why testing this behavior at the
gateway is mandatory.

On the service side, the check must never be **skippable**: if the secret is empty, the
request is rejected ([SEC-04]); writing "if the secret is not set, skip the check" is
forbidden.

## Accepted costs

- The shared-secret model is not as strong as mTLS; a leak requires rotation across every
  service. Mitigations: a different secret per environment ([SEC-24]), at least 32 random
  bytes, mandatory rotation if it ever reaches git ([SEC-22]).
- JWT revocation is delayed; bounded by short-lived tokens and a revocation list.
- Services do not **verify** the user's identity themselves, they trust what the gateway
  hands them, and that trust is bounded by the check in [SEC-04].

## What would change this decision

- If the internal network's trust model changes (a multi-tenant environment, shared
  infrastructure), **mTLS** is evaluated.
- If we move to Kubernetes and a service mesh (Linkerd/Istio) comes into play, mTLS is
  nearly free, at which point the shared secret is removed.
- If instant revocation becomes a legal or functional requirement, opaque token +
  introspection is reconsidered.
