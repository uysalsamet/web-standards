# 02 — Technology and Version Standard

> **This file is binding.** When you need to pick a version, look here, not "whatever
> is newest." Adding a dependency that isn't in the table requires approval ([GEN-03]).
>
> **Versions verified as of: 2026-08-12.**
> **Next review: 2026-11-12** (quarterly).
> If the review hasn't happened, knowing that is better than using the wrong version —
> update the date.
>
> The **why** behind every choice, and why each alternative was rejected, is in the
> decision records under [adr/](adr/). Read the relevant ADR before arguing a choice —
> it has likely already been discussed.

---

## 1. Core stack (fixed)

| Layer | Choice | Pinned version | Why this one | ADR |
|---|---|---|---|---|
| Language | Go | **1.25.12** | Supported line (last two majors). Gin v1.12 requires `go 1.25.0`. | [0002](adr/0002-go-version.md) |
| HTTP framework | `github.com/gin-gonic/gin` | **v1.12.0** | Built on `net/http` → compatible with the whole ecosystem, HTTP/2 ready, API stable for years. | [0001](adr/0001-http-framework.md) |
| Postgres driver | `github.com/jackc/pgx/v5` | **v5.10.0** | `lib/pq` is in maintenance mode. Native pool (`pgxpool`), context, batch, `CopyFrom`. | [0003](adr/0003-postgres-driver.md) |
| Cache client | `github.com/redis/go-redis/v9` | **v9.22.0** | Wire-compatible with Valkey; no client-side changes needed. | [0009](adr/0009-cache-engine.md) |
| Kafka client | `github.com/twmb/franz-go` | **v1.21.6** | Active, full KRaft + transaction support, no cgo. | [0008](adr/0008-messaging.md) |
| Workflow | `go.temporal.io/sdk` | **v1.47.0** | For long-running/multi-step jobs. | [0010](adr/0010-workflow-engine.md) |
| Logging | `log/slog` | **stdlib** | No extra dependency needed for structured logging. | [0005](adr/0005-logging.md) |
| Metrics | `github.com/prometheus/client_golang` | **v1.24.1** | | [0012](adr/0012-metrics-and-tracing.md) |
| Tracing | `go.opentelemetry.io/otel` | **v1.45.0** | | [0012](adr/0012-metrics-and-tracing.md) |
| JWT | `github.com/golang-jwt/jwt/v5` | **v5.3.1** | **Gateway only.** Services do not parse JWTs. | — |
| UUID | `github.com/google/uuid` | **v1.6.0** | | — |
| Migration | `github.com/pressly/goose/v3` | **v3.27.3** | Versioned, has `Down` blocks, embeddable from Go. | [0004](adr/0004-migration-tool.md) |
| Test containers | `github.com/testcontainers/testcontainers-go` | **v0.44.0** | Integration tests only. | [0011](adr/0011-testing-approach.md) |
| Lint | `golangci-lint` | **v2.12.2** | Mandatory in CI ([CI-15]). | — |

### Gin helper packages (as needed)

| Package | Version | Where |
|---|---|---|
| `github.com/gin-contrib/requestid` | **v1.0.6** | Every service ([OBS-04]) |
| `github.com/gin-contrib/cors` | **v1.7.7** | **Only** in directly reachable services ([SEC-31]) |
| `github.com/gin-contrib/gzip` | **v1.2.6** | **Only** in the gateway ([PERF-10]) |
| `go.opentelemetry.io/contrib/.../otelgin` | **v1.45.0 line** | If tracing is set up ([OBS-14]) |

> **No package for rate limiting.** `ulule/limiter` was last updated in 2023 — consider
> it abandoned. A Redis-backed sliding window is ~40 lines and is written with
> `go-redis` ([RES-04], [VER-07]).

### Rules

**[VER-01] MUST:** The `go` directive in `go.mod` is **1.25.12**. In a monorepo, the
`go.work` version cannot be lower than the highest among the modules, and is never
lowered.

**[VER-02] MUST:** Table versions are written **in full** (`v1.12.0`), never `latest` or
an open-ended range — neither in `go.mod` nor in a Docker image.
> **Why:** `latest` can silently break today's working build tomorrow, and no one can
> tell which version they tested against. Reproduction becomes impossible.

**[VER-03] MUST:** A version upgrade is done **for all services together**, never tried
on a single service. An upgrade is its own PR; no feature changes are mixed into it.

**[VER-04] MUST:** `go.sum` is committed. Builds use `GOFLAGS=-mod=readonly` so CI never
silently fetches dependencies.

**[VER-05] MUST NOT:** A second library doing the same job. The rejected alternatives
and their justifications are in [adr/](adr/):
> - HTTP: Fiber / Echo / chi — **no**, we use Gin → [ADR-0001](adr/0001-http-framework.md)
> - Postgres: `lib/pq` / GORM / ent / sqlx — **no**, we use pgx → [ADR-0003](adr/0003-postgres-driver.md)
> - Logging: zap / zerolog / logrus — **no**, we use `log/slog` → [ADR-0005](adr/0005-logging.md)
> - Config: viper / koanf / envconfig — **no**, we use `os.LookupEnv` → [ADR-0006](adr/0006-configuration.md)
> - UUID: `gofrs/uuid` — **no**, we use `google/uuid`
> - Testing: testify — **no**, we use stdlib `testing` → [ADR-0011](adr/0011-testing-approach.md)

**[VER-06] MUST NOT:** ORM. Queries are written by hand → [ADR-0003](adr/0003-postgres-driver.md).

**[VER-07] SHOULD:** Don't pull in a package for something the standard library solves
in ~50 lines. A dependency's cost is: security surface + license + upgrade debt + build
time. A package that has stopped being maintained (latest release > 12 months old) is
**never** pulled in.

**[VER-08] MUST:** Config reading is done by hand with `os.LookupEnv` → [ADR-0006](adr/0006-configuration.md).

**[VER-09] MUST:** Input validation is done by hand in the handler; `binding:"..."` tags
are not used → [ADR-0007](adr/0007-input-validation.md).
> **Note:** `go-playground/validator` is a **transitive dependency** of Gin — i.e. it's
> already in the dependency tree. The decision not to use it is not based on "extra
> package" reasoning, but on it conflicting with our pointer/tri-state design
> ([API-06], [API-11]).

---

## 2. Docker images

**[VER-10] MUST:** Images are pinned to the tags below. `latest` is **forbidden**.

| Purpose | Image | Note |
|---|---|---|
| Go builder | `golang:1.25-alpine` | First stage of the multi-stage build |
| Runtime | `alpine:3.24` | Runs non-root ([OPS-03]) |
| Postgres (plain) | `postgres:18.4-alpine` | |
| Postgres (GIS) | `postgis/postgis:18-3.6` | Only if geometry data is used |
| Cache (Valkey) | `valkey/valkey:9.1.1-alpine` | Redis protocol; `go-redis` works unchanged. BSD-3 license — see [ADR-0009](adr/0009-cache-engine.md) |
| Kafka | `apache/kafka:4.3.1` | KRaft mode; **no** ZooKeeper |
| Temporal | `temporalio/server:1.31.2` | |
| Prometheus | `prom/prometheus:v3.13.2` | |
| Grafana | `grafana/grafana:13.1.3` | |

> **Note:** `postgres:18.4` was released in May 2026; Postgres minor releases come out
> in February/May/August/November. Bump the minor version at the quarterly review —
> minor releases are security patches, they are not skipped.

**[VER-11] SHOULD:** In critical environments, pin the image by digest:
`postgres:18.4-alpine@sha256:...`. A tag can be rewritten, a digest cannot.

**[VER-12] MUST:** An infrastructure component (Postgres, Valkey, Kafka) is on **one
version across the whole project**. One service cannot use Valkey 8 while another uses
Valkey 9.

---

## 3. `go.mod` template

```go
module <name>-service

go 1.25.12

require (
	github.com/gin-contrib/requestid v1.0.6
	github.com/gin-gonic/gin v1.12.0
	github.com/google/uuid v1.6.0
	github.com/jackc/pgx/v5 v5.10.0
	github.com/pressly/goose/v3 v3.27.3
	github.com/prometheus/client_golang v1.24.1
)
```

Added as needed (not all at once, only what is **actually used**):

```go
	github.com/redis/go-redis/v9 v9.22.0        // if there is cache/locking (connects to Valkey)
	github.com/twmb/franz-go v1.21.6            // if producing/consuming events
	go.temporal.io/sdk v1.47.0                  // if there is a workflow
	go.opentelemetry.io/otel v1.45.0            // if there is tracing
	github.com/gin-contrib/cors v1.7.7          // ONLY in a directly reachable service
```

**[VER-13] MUST NOT:** Leave an unused dependency in `go.mod`. `go mod tidy` runs on
every PR ([CI-15]).

---

## 4. If something not in the table is needed

In order:

1. **Is it genuinely needed?** Does the standard library solve it, or does an existing
   dependency already do it?
2. **Verify the version.** Don't write it from memory — confirm today's stable release
   from the official release page. If the latest release is more than 12 months old,
   consider it abandoned ([VER-07]).
3. **Check the license.** MIT / BSD / Apache-2.0 are fine. GPL/AGPL **require approval**.
4. **Get approval.** Ask the project owner. A PR with an unapproved dependency is
   rejected.
5. **Write a decision record.** Open a new file under `adr/`: alternatives, pros/cons,
   why this one, what would change the decision. Then add it to this table.

---

## 5. Upgrade procedure

**[VER-14] MUST:** Upgrade steps:

```bash
# 1. See what will change, first
go list -m -u all

# 2. One dependency, one PR
go get github.com/gin-gonic/gin@v1.13.0
go mod tidy

# 3. Verify
go build ./...
go test -race ./...
golangci-lint run

# 4. Bring it up with Compose, manually try /health and one CRUD flow
```

**[VER-15] MUST:** A major version jump (v1 → v2) requires approval — discuss first,
then act. If anything changes the reasoning, update the relevant ADR.

**[VER-16] MUST:** A dependency with a reported vulnerability is upgraded **without
delay**. `govulncheck` runs in CI ([CI-15]); a finding turns the build red.

---

## 5b. Dependency freshness — advisory, not enforced

**[VER-21] SHOULD:** `tools/version-advice.sh` runs regularly (monthly, or on every PR
that touches a dependency) and lists dependencies that have a newer upstream release.
The tool **never fails**; its exit code is always 0.
> **Why:** There are two different questions here, and conflating them makes both
> useless. [VER-01] asks "does this service match the standard's table," and fails the
> **build** if it doesn't. This rule asks "is there something newer upstream"; answering
> yes to that is not a violation, it's information. Breaking the pipeline just because a
> new version came out pushes the team to disable the tool, and then nothing ever gets
> updated.

**[VER-22] MUST:** Major version jumps are done one at a time, checking the "what this
decision would change" section of the relevant ADR ([VER-08] follows the same line).
The tool shows major jumps in a separate group.

**Measurement (2026-09-08, reference repo):** across 47 services, the `go` directive is
distributed as follows: **35** services on `1.23.6`, **10** on `1.24.0`, **2** on
`1.23.0`. The standard calls for `1.25.12`. Not a single service complies, and there are
three different versions among them. [VER-01] catches this and fails the build; [VER-21]
reports how far an upgrade could go. Version drift doesn't happen on its own, it happens
because no one is watching.

The same run turned up a second finding: **9 of the 47** modules could not be queried,
because of `missing go.sum entry for go.mod file`. That means those services are missing
a `go.sum` file, violating [VER-04]. The tool deliberately does **not** "fix" this: had
it run with `-mod=mod`, it would silently write the missing entries, meaning a reporting
command would have modified your `go.mod`/`go.sum` files. The tool runs with
`-mod=readonly` and **reports** the gap instead.
> **As a rule:** no tool that produces a report modifies the source files of the repo it
> is reporting on (the same line as [TOOL-01]). Auditing and fixing are separate
> commands.

---

## 6. Relationship to existing projects

**[VER-17] MUST — Every service written from now on is written with Gin.** No
exceptions. A new project, a new repo, or a new service added to an existing repo — all
of it is Gin.
Starting a new service with Fiber is **forbidden**.

**[VER-18] MUST — Existing running services are not migrated automatically.** Working
code is not touched "just to match the standard" ([GEN-00d]). Old Fiber services stay as
they are and keep running; only **new code** comes in Gin.

This is a deliberate decision to accept a transition period: the repo will stay mixed for
a while (old services on Fiber, new ones on Gin). The accepted cost and the countermeasures:

| Cost | Countermeasure |
|---|---|
| The two frameworks' middleware differ | Each service carries its own middleware; the shared `pkg/` stays **framework-independent** (logger, response body, validator) |
| Copy-pasting from the wrong service is possible | A new service **always** starts from the Gin skeleton in [03](03-PROJECT-STRUCTURE.md), never from a neighbouring service |
| `go.work` carries both frameworks at once | Not a problem; modules are independent |

**[VER-19] SHOULD — Migrate existing services opportunistically.** If a Fiber
service is already undergoing a substantial change (a new module, a large refactor),
that is the right moment to convert it to Gin. A bulk migration project is **not
required**; it happens service by service, whenever it's touched.

**[VER-20] MUST:** In services not yet migrated, this standard's
**framework-independent** rules still apply: API contract (04), security (05), database
(07), testing (12), observability (10). Only the HTTP layer syntax differs.

> **Concrete example — the Arnavutköy microservices repo:** 34 services are written with
> Fiber v2.52.8 + `lib/pq`. These services stay as they are, but **the 35th service added
> there is written with Gin.** Existing ones are migrated one by one as serious work is
> done on them.

---

## Sources (verified as of 2026-08-12)

- [Go Release History](https://go.dev/doc/devel/release) — 1.26.5 / 1.25.12, 7 Jul 2026
- [Gin releases](https://github.com/gin-gonic/gin/releases) — v1.12.0, 28 Feb 2026 · [go.mod](https://github.com/gin-gonic/gin/blob/master/go.mod) — `go 1.25.0`
- [gin-contrib/requestid](https://github.com/gin-contrib/requestid/releases) v1.0.6 · [cors](https://github.com/gin-contrib/cors/releases) v1.7.7 · [gzip](https://github.com/gin-contrib/gzip/releases) v1.2.6
- [pgx](https://github.com/jackc/pgx) — v5.10.0
- [go-redis](https://pkg.go.dev/github.com/redis/go-redis/v9) — v9.22.0, 3 Aug 2026
- [franz-go](https://github.com/twmb/franz-go) — v1.21.6
- [Temporal Go SDK](https://github.com/temporalio/sdk-go/releases) — v1.47.0, 28 Jul 2026
- [Temporal Server](https://github.com/temporalio/temporal/releases) — v1.31.2, 8 Jul 2026
- [OpenTelemetry Go](https://github.com/open-telemetry/opentelemetry-go/releases) — v1.45.0, 3 Aug 2026 · [contrib](https://github.com/open-telemetry/opentelemetry-go-contrib/releases) — v1.45.0, 4 Aug 2026
- [prometheus/client_golang](https://github.com/prometheus/client_golang/releases) — v1.24.1
- [Prometheus](https://github.com/prometheus/prometheus/releases) — v3.13.2 · [Grafana](https://github.com/grafana/grafana/releases) — v13.1.3
- [goose](https://github.com/pressly/goose/releases) — v3.27.3 · [testcontainers-go](https://github.com/testcontainers/testcontainers-go/releases) — v0.44.0
- [golangci-lint](https://github.com/golangci/golangci-lint/releases) — v2.12.2 · [golang-jwt](https://github.com/golang-jwt/jwt/releases) — v5.3.1
- [Apache Kafka Downloads](https://kafka.apache.org/community/downloads/) — 4.3.1 · [Alpine](https://alpinelinux.org/releases/) — 3.24.1
- [PostgreSQL Versioning](https://www.postgresql.org/support/versioning/) · [postgis/postgis](https://hub.docker.com/r/postgis/postgis)
- [Valkey releases](https://github.com/valkey-io/valkey/releases) — 9.1.1, 21 Jul 2026 · [valkey/valkey image](https://hub.docker.com/r/valkey/valkey/)
