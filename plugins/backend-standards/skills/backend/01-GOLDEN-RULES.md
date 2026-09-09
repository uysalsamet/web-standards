# 01 — Golden Rules

> The 24 items in this file are **non-negotiable**. Everything else derives from them.
> Each item links to the file with its full detail; go there if you're unsure.
> Reading this file alone is also enough to set up a service correctly.

---

## A. Stack and version

**[GEN-01] MUST, single stack.** All HTTP services are written in Go + Gin. No mixing
in Fiber, Echo, chi, or a bare `net/http` router.
> **Why:** two frameworks means two middleware sets, two error bodies, two test
> patterns, two security surfaces. No gain, double the maintenance cost.
> Detail: [02-TECH-VERSIONS.md](02-TECH-VERSIONS.md)

**[GEN-02] MUST, single version.** Every service in the repo uses the same Go version
and the same Gin version. The version table is in `02`; version upgrades happen **for
all services together**.
> **Why:** if service A is on Gin v1.10 and service B on v1.12, the shared `pkg/`
> package behaves differently in each and the bug only shows up in one of them.
> Diagnosis takes hours.

**[GEN-03] MUST, adding a dependency requires approval.** Do not add a library that is
not in the table in `02` on your own. If it is added, it also goes into the table.
> **Why:** every dependency is a security surface, a licensing risk, and an upgrade
> debt. Nobody pulls a package for something the standard library solves in 30 lines.

---

## B. Architecture

**[GEN-04] MUST, dependencies flow one way:** `handler → service → repository`. No
imports in the reverse direction. The repository does not know about the handler, the
service does not know about Gin.
> Detail: [03-PROJECT-STRUCTURE.md](03-PROJECT-STRUCTURE.md)

**[GEN-05] MUST, each layer does one job.**
> - `handler` = HTTP. Input validation, status code, JSON. **No business logic.**
> - `service` = business logic and transformation. **No HTTP, no SQL.**
> - `repository` = data access. **No business logic, no HTTP.**

**[GEN-06] MUST, a service owns its own schema.** No direct `SELECT`/`INSERT` against
another service's table; call that service's API instead.
> **Why:** a direct query freezes that service's schema in place. When its owner
> renames a column, three services that have no idea it happened all break at once.

**[GEN-07] MUST, return an interface, not a struct.** The service and repository
layers are defined as interfaces, with the implementation unexported.
> **Why:** this is the only way to write tests without a database. A constructor that
> returns a concrete struct condemns the test to being an integration test.

**[GEN-08] MUST, services run behind a gateway.** Auth, rate limiting, CORS and public
routing are the gateway's job. The service sits on the internal network and does not
expose a port.
> Detail: [05-SECURITY.md](05-SECURITY.md), [06-RATE-LIMIT-RESILIENCE.md](06-RATE-LIMIT-RESILIENCE.md)

---

## C. Security

**[GEN-09] MUST, assume the gateway, don't trust the gateway.** The gateway validates
the JWT; the service still does its **own** `X-Gateway-Source` + `X-API-Key` +
permission check.
> **Why:** someone with access to the internal network (a misconfigured container, a
> compromised pod) bypasses the gateway. A single layer of defence is not a defence.

**[GEN-10] MUST, every endpoint has a permission.** "This endpoint is open to
everyone" is a deliberate decision, justified in a code comment. It cannot be an
oversight.

**[GEN-11] MUST NOT, fail-open.** When the permission service, Redis, or the database
goes down, access **narrows**, it does not widen. A permission function like
`if err != nil { return true }` is never written.

**[GEN-12] MUST, nothing from the outside world is trusted.** User input, another
service's response, a file, an env value, all of it goes through type and bounds
validation.
> Detail: [05-SECURITY.md](05-SECURITY.md)

**[GEN-13] MUST NOT, embed a secret in code.** Passwords, tokens, keys; none of them go
into code, a Dockerfile, a compose file, or git. A default like
`getEnv("DB_PASSWORD", "Secret123")` is also a secret.

**[GEN-14] MUST NOT, build SQL by string concatenation.** A value is **always** a
parameter. `fmt.Sprintf` is used in SQL only for a placeholder number (`$%d`).

**[GEN-15] MUST NOT, leak internal error detail to the client.** A raw driver error, a
table/constraint name, an internal service URL, a port, a stack trace, none of these go
into the response body. Log it, mask it.

---

## D. Resilience

**[GEN-16] MUST, every network call has a timeout.** The HTTP server, the HTTP client,
the DB query, Redis, Kafka. The default `http.Client{}` waits **forever**; it is never
used.
> Detail: [06-RATE-LIMIT-RESILIENCE.md](06-RATE-LIMIT-RESILIENCE.md)

**[GEN-17] MUST, `context` is carried through to the end of the call chain.** When the
client closes the connection, the work must stop too. In Gin the source is
`c.Request.Context()`; `*gin.Context` itself is not passed down into lower layers
([STR-10]).

**[GEN-18] MUST, `recover` middleware plus graceful shutdown.** A single panic does not
take the service down; SIGTERM does not cut off a request that's still in flight.

**[GEN-19] MUST NOT, swallow an error.** No `if err != nil { }` and no
`_ = doSomething()`. Either handle it meaningfully, propagate it upward, or write
**why you're ignoring it** in a comment.

---

## E. Data

**[GEN-20] MUST, "unknown" is `NULL`; it is not `0` or `""`.** This distinction is
preserved in the DTO with a pointer. In a PUT body, **every field is a pointer**.
> **Why:** if you use a value type, updating a single field silently zeroes out every
> other field. Detail: [04-API-CONTRACT.md](04-API-CONTRACT.md)

**[GEN-21] MUST, list endpoints are paginated and `ORDER BY` includes a unique
tie-break.**
> **Why:** without a tie-break, sorting repeats and skips records across pages; a
> client paging through all of them ends up with **incomplete data** and never notices.

**[GEN-22] MUST, business rules live in both the application and the schema.** An
application-level check can be skipped; `NOT NULL`, `CHECK`, `UNIQUE`, `FOREIGN KEY`
cannot.
> Detail: [07-DATABASE.md](07-DATABASE.md)

---

## F. Process

**[GEN-23] MUST, no "it works" without a test written.** At minimum: the happy path
plus permission denial plus bad input. CI runs `go test -race ./...`.
> Detail: [12-TESTING.md](12-TESTING.md)

**[GEN-24] MUST, writing the service is half the job.** The gateway route, the
permission definition, the env lines, the compose block, the documentation, none of it
done means the work is not finished.
> Detail: [15-NEW-SERVICE-CHECKLIST.md](15-NEW-SERVICE-CHECKLIST.md)

---

## One-page reminder

```
Single stack, single version         → 02
handler → service → repository       → 03
Don't trust the gateway, check it yourself → 05
Timeout + context + recover          → 06
NULL != 0, everything a pointer in PUT → 04
Paginate + sort with a tie-break     → 07
Rules belong in the schema too       → 07
No test means not done               → 12
Checklist not passed means not done  → 15
```
