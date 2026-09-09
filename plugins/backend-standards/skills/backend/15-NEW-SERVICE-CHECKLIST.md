# 15 — New Service Checklist

> Copy this, tick items one by one. **Every skipped item gets its reason written in the PR.**
> An item skipped with "I'll do it later" doesn't get done.

---

## A. Setup

- [ ] Service name is `<name>-service` (lowercase, hyphenated), the `go.mod` module name matches — [STR-01]
- [ ] Added to `go.work`; the `go.work` version was not downgraded — [STR-02]
- [ ] `go.mod`: `go 1.25.12`, Gin `v1.12.0`, pgx `v5.10.0` — [VER-01], [02](02-TECH-VERSIONS.md)
- [ ] No dependency was added that isn't in the table (if one was, approval was obtained and the table updated) — [GEN-03]
- [ ] Folder structure matches [03](03-PROJECT-STRUCTURE.md) §2; a `repository/postgres/` subdirectory exists — [STR-06]

## B. Code

- [ ] `main.go` is wiring only, under 150 lines — [STR-11]
- [ ] `config.go` only reads env; `DSN()` is the single source; secret defaults are empty — [STR-15], [STR-16]
- [ ] For every module: DTO (3 types) + repository (interface) + service (interface) + handler — [STR-04], [GEN-07]
- [ ] No file exceeds 500 lines — [STR-05]
- [ ] No layer violation: no SQL in the handler, no `*gin.Context` passed to the service — [GEN-04], [GEN-05], [STR-10]
- [ ] Every function's first parameter is `context.Context` — [STR-09]
- [ ] `handler/common.go`: `Health`, `Ready`, `recordID`, `badRequest`, `writeError`, `clampPagination`
- [ ] `clampPagination` is the single source; `meta.limit` matches the number of records returned — [STR-18]
- [ ] `routes.go`: a single `Setup`; `/health` + `/ready` are open; groups take `GatewayAuth`;
      every endpoint requires a permission — [STR-20], [GEN-10]
- [ ] The list endpoint sits at the resource's root (`GET /parkings`), no `/list` subpath — [API-01b], [STR-21]
- [ ] Every group explicitly takes its own middleware at its definition — [STR-22]
- [ ] All fields in the PUT DTO are pointers; required numeric/coordinate fields in POST are pointers too — [API-06], [API-07]
- [ ] No `GENERATED`/derived field in the Request DTO — [API-08]
- [ ] `gin.New()` + `ContextWithFallback`; binding via `ShouldBindJSON`; on error `AbortWithStatusJSON` + `return` — [STR-13], [STR-14], [STR-19], [API-12]
- [ ] Comments explain "why" — [STR-23]

## C. Security

- [ ] `GatewayAuth`: `X-Gateway-Source` + `X-API-Key`, constant-time comparison;
      the check is **not skipped** when the secret is empty — [SEC-04]
- [ ] Every endpoint requires a permission; open endpoints are justified with a comment — [GEN-10]
- [ ] Permission keys are in `<module>.<action>` format, exactly matching the seed data — [SEC-06]
- [ ] No fail-open — [SEC-08], [GEN-11]
- [ ] Permission denials are logged in structured form — [SEC-09]
- [ ] Ownership checks are enforced with a narrowed query where required — [SEC-11]
- [ ] Every check in the input validation table is implemented — [SEC-12]
- [ ] `VARCHAR` limits are hardcoded in the handler and match the DDL — [SEC-13]
- [ ] All SQL is parameterized; dynamic columns/sort come from a whitelist — [SEC-15], [API-26]
- [ ] No CORS on the service behind the gateway — [SEC-31]
- [ ] `.gitignore` contains `.env*`, `*.pem`, `*.key`; `.env.example` exists — [SEC-20], [SEC-21]
- [ ] No secret is logged; config is not printed with `%+v` — [SEC-25], [SEC-26]

## D. Resilience

- [ ] `http.Server`: `ReadHeaderTimeout` 5s, `ReadTimeout` 15s, `WriteTimeout` 30s, `IdleTimeout` 60s + `BodyLimit` middleware 4MB — [RES-07], [RES-05]
- [ ] The upstream HTTP client is shared and has a timeout — [RES-08], [PERF-14]
- [ ] A `recover` middleware exists, the stack trace goes only to the log — [RES-18]
- [ ] Graceful shutdown exists; the shutdown order is correct — [RES-19], [RES-20]
- [ ] If retries exist: a single layer, at most 3 attempts, jittered backoff, only transient errors — [RES-11]…[RES-14]
- [ ] Goroutines have a termination condition; no unbounded fan-out — [RES-21], [RES-22]
- [ ] `/health` does **not** check dependencies; `/ready` does — [RES-27], [RES-29]
- [ ] `/health` format is `{"status":"healthy","service":"<name>"}` — [RES-28]

## E. Database

- [ ] Pool is configured (`MaxConns`, `MaxConnLifetime`, `MaxConnIdleTime`); the service doesn't start if `Ping` fails — [DB-01], [DB-02]
- [ ] Pool budget calculated: services × MaxConns × replicas < `max_connections` — [DB-03]
- [ ] UUID PK; `created_at`/`updated_at` are `TIMESTAMPTZ` — [DB-05], [DB-06]
- [ ] FKs are `NOT NULL` for mandatory relations; business rules are also enforced with `CHECK`/`UNIQUE` — [DB-07], [DB-08]
- [ ] Derivable values are `GENERATED` or computed server-side — [DB-09]
- [ ] Schema decisions are documented with comments — [DB-10]
- [ ] Migrations use `goose`, have a `Down` block, are forward-compatible — [DB-12], [DB-13]
- [ ] Migration failure is fatal; seeding is idempotent and its failure is a warning — [DB-15]
- [ ] No `SELECT *`; the column list lives in a single constant — [DB-18]
- [ ] Paginated queries have a unique tie-break in `ORDER BY` — [DB-19]
- [ ] `errors.go`: **all** eight error codes are translated; sentinel errors are exported — [DB-20], [DB-21]
- [ ] Multi-table work runs in a transaction; `defer tx.Rollback` exists; transactions are short — [DB-22], [DB-23]
- [ ] Index on frequently filtered columns; the list query was checked with `EXPLAIN` — [DB-26], [DB-27]
- [ ] No N+1 — [DB-28]

## F1. Money / personal data / audit trail (if applicable — [16](16-MONEY-AND-SENSITIVE-DATA.md))

- [ ] Money fields are `NUMERIC(n,2)` in the schema; **no** `REAL`/`DOUBLE PRECISION`/`MONEY` — [MONEY-02]
- [ ] `Money` type on the Go side (int64 cents); no money handled as `float` anywhere — [MONEY-01], [MONEY-03]
- [ ] Amounts are **strings** in JSON — [MONEY-04]
- [ ] Money columns are selected with `::text` in queries — [MONEY-06]
- [ ] Rounding rule and direction live in one place, with a comment — [MONEY-08], [MONEY-10]
- [ ] No leftover cents lost on installments/splits (`sum(Split) == total` test) — [MONEY-09]
- [ ] Currency is explicitly specified — [MONEY-11]
- [ ] Money operations run inside a transaction + are idempotency-protected — [MONEY-12]
- [ ] Personal data columns are tagged in the schema; retention period is documented — [KVKK-01], [KVKK-03]
- [ ] Deletion requests are technically feasible (hard delete / anonymization decision made) — [KVKK-04]
- [ ] Soft delete does not count as deleting personal data — [KVKK-05]
- [ ] Production data is not copied into test/dev environments — [KVKK-10]
- [ ] An audit trail table exists, append-only (`REVOKE UPDATE, DELETE`) — [AUDIT-02], [AUDIT-03]
- [ ] Money/permission/deletion/personal-data operations produce audit trail entries — [AUDIT-01]
- [ ] The audit record is written in the **same transaction** as the operation — [AUDIT-04]

## F2. File upload (if applicable — [17](17-FILE-UPLOAD.md))

- [ ] Per-endpoint size limit; the global limit was not raised — [FILE-01]
- [ ] Files are processed as a stream, not buffered into memory — [FILE-02]
- [ ] Type is detected **from content**; the `Content-Type` header is not trusted — [FILE-03]
- [ ] Allowed types are a **whitelist** — [FILE-04]
- [ ] The object key is generated server-side; the client's filename is never used as a path — [FILE-07]
- [ ] Files live in object storage, not the container disk; the bucket is not public — [FILE-09], [FILE-10]
- [ ] Uploads are not served from the main domain, **or** `attachment` + `nosniff` + CSP are set — [FILE-11]
- [ ] Every download is permission-checked; presigned URLs are short-lived — [FILE-12], [FILE-13]
- [ ] Images are re-encoded (EXIF/location stripped) — [FILE-14]
- [ ] No direct request is made to a user-supplied URL (SSRF protection) — [FILE-18]
- [ ] Quota + rate limit exist; orphaned files are cleaned up — [FILE-21], [FILE-22]
- [ ] The 13-item rejection test in [17](17-FILE-UPLOAD.md) §7 was run — [FILE-25]

## F3. Concurrency / Turkish data ([18](18-CONCURRENCY-AND-TURKISH-DATA.md))

- [ ] Tables editable by multiple users have a `version` column — [CONC-01]
- [ ] `UPDATE ... WHERE version = $n` + affected-row check; 409 on conflict — [CONC-02], [CONC-04]
- [ ] Counters are incremented with atomic SQL (no read-modify-write) — [CONC-09]
- [ ] Turkish text search uses ICU collation or a normalized column — [TR-02], [TR-03]
- [ ] `cases.Lower(language.Turkish)` used instead of `strings.ToLower` in Go — [TR-05]
- [ ] Normalization logic lives in a single function — [TR-06]
- [ ] UTF-8 validation exists; length is measured with `[]rune` — [TR-08], [TR-09]
- [ ] The Turkish test list was run (İSTANBUL/ISPARTA/sorting) — [TR-10]

## F4. Identity / session (if this is the auth service — [19](19-IDENTITY-AND-SESSION.md))

- [ ] Passwords use argon2id with OWASP parameters; stored in PHC format — [AUTH-01], [AUTH-02]
- [ ] Rehashed on login if parameters are outdated — [AUTH-03]
- [ ] User enumeration is prevented; a hash is computed even when the user doesn't exist — [AUTH-10], [AUTH-11]
- [ ] Per-account lockout exists (beyond IP-based limiting) — [AUTH-12]
- [ ] Access token 15 min / refresh rotated; reuse detection exists — [AUTH-14], [AUTH-15], [AUTH-16]
- [ ] Refresh tokens are hashed in the DB — [AUTH-17]
- [ ] `alg` is verified, `none` is rejected — [AUTH-19]
- [ ] Reset tokens are single-use and short-lived — [AUTH-22]
- [ ] The test list in [19](19-IDENTITY-AND-SESSION.md) §5 was run — [AUTH-27]

## F5. Integration / bulk data ([20](20-INTEGRATION-AND-BULK-DATA.md))

- [ ] Import is idempotent (`ON CONFLICT`), an `import_runs` record is kept — [ETL-01], [ETL-02]
- [ ] Partial-failure policy is documented; skipped rows are reported — [ETL-03], [ETL-05]
- [ ] Count verification is done (source == destination) — [ETL-06]
- [ ] Scheduled jobs are deduplicated across replicas (distributed lock) — [JOB-01]
- [ ] A "the job never ran" condition triggers an alert — [JOB-05]
- [ ] Notification sending is idempotent; no real sends from the test environment — [NOTIF-01], [NOTIF-07]
- [ ] Outgoing webhooks are signed (timestamp included); the recipient URL is validated — [HOOK-01], [HOOK-02]
- [ ] Live streams refresh permissions + have backpressure — [STREAM-02], [STREAM-04]

## F. Cache / async (if applicable)

- [ ] Cache was added based on measurement; the accepted staleness window is documented — [CACHE-01], [CACHE-03]
- [ ] Key format is `<service>:<entity>:<version>:<id>`; no key without a TTL — [CACHE-04], [CACHE-08]
- [ ] User-specific data keys include the user id — [CACHE-07]
- [ ] A Redis failure does not drop the request (except rate limit/lock) — [CACHE-10]
- [ ] `KEYS`/`FLUSHALL` are not used; `maxmemory-policy` is configured — [CACHE-15], [CACHE-23]
- [ ] Consumers are idempotent; a DLQ exists and is monitored — [ASYNC-04], [ASYNC-07], [ASYNC-08]
- [ ] The DB write and event production happen in the same transaction via outbox — [ASYNC-17]
- [ ] Workflow code is deterministic; IO lives in activities — [ASYNC-20], [ASYNC-21]

## G. Observability

- [ ] JSON logs via `log/slog`, to stdout; level set via env — [OBS-01], [OBS-02], [OBS-03]
- [ ] Every log line has `service`, `version`, `request_id` — [OBS-04]
- [ ] An incoming `X-Request-ID` is preserved — [OBS-05]
- [ ] The log message is constant, variables are fields — [OBS-06]
- [ ] `/metrics` exists and is not exposed externally; RED metrics are defined — [OBS-09], [OBS-10]
- [ ] No UUID/email/IP in metric labels; `route` is templated — [OBS-11]
- [ ] At least one business metric is defined — [OBS-12]

## H. Docker & integration

- [ ] Dockerfile is multi-stage, non-root, has `HEALTHCHECK`, correct `EXPOSE` — [OPS-01]…[OPS-05]
- [ ] Migration SQL files are copied into the image — [OPS-01]
- [ ] `.dockerignore` exists — [OPS-06]
- [ ] Compose: `expose` (not `ports`), env references, resource limits, log rotation,
      `depends_on: service_healthy` — [OPS-09]…[OPS-12]
- [ ] `GOMEMLIMIT` set to 80% of the limit — [PERF-06]
- [ ] `.env.local` + `.env.prod` + `.env.example`: `<NAME>_SERVICE_PORT` and `<NAME>_SERVICE_URL` — [OPS-15]
- [ ] Port is unique across the repo; the port list in `docs/README.md` is updated — [OPS-16]
- [ ] Gateway: config field + route table + **router registration** (all four steps) — [OPS-18]…[OPS-22]
- [ ] Permission definitions were added and attached to the admin role — [OPS-21]

## I. Testing and verification

- [ ] `routes_test.go` covers the 11 items in [12](12-TESTING.md) §2 — [TEST-04]
- [ ] Rejected requests were verified to never reach the service — [TEST-06]
- [ ] Every endpoint has a happy-path + permission-denied + bad-input test — [TEST-07]
- [ ] Boundary values were tested — [TEST-08]
- [ ] Repository integration tests ran against a real Postgres — [TEST-12]
- [ ] `go build ./...` is clean
- [ ] `go test -race ./...` passes — [TEST-15]
- [ ] `tools/check-standards.sh` is clean (exit 0) — [CI-25]
- [ ] `.golangci.yml` was copied from `tools/golangci.yml`; `golangci-lint run` is clean — [CI-15], [CI-24]
- [ ] `govulncheck ./...` is clean — [SEC-34]
- [ ] The manual E2E list ([12](12-TESTING.md) §6) was run and its result written into the PR — [TEST-21]
- [ ] Permission loading was verified **by querying the DB**, not by reading logs — [TEST-22]
- [ ] The Postman collection **contains assertions** (not just a list of requests) — [TEST-24]
- [ ] `tools/run-collection.sh` ran the collection through the gateway, no broken requests — [TEST-23], [TEST-25]
- [ ] Functions that parse external input have a fuzz target; crash inputs are under `testdata/fuzz/` — [TEST-26], [TEST-27]
- [ ] `tools/check-secrets.sh` is clean (exit 0); any critical finding was written explicitly into the PR — [SEC-38]
- [ ] `tools/load-test.sh` was run, [PERF-01] targets were met **or** it's documented why the measurement couldn't be interpreted — [PERF-33], [PERF-34]
- [ ] `tools/version-advice.sh` output was reviewed (it never FAILs, the decision is yours) — [VER-21]

## J. Documentation

- [ ] `docs/README.md`: what the service does, endpoint list, permission list — [API-31]
- [ ] `docs/ui-integration.md`: frontend flows, example request/response
- [ ] The Postman collection works — verified **by running it**, not just by opening it — [TEST-23]
- [ ] If there's a deviation from the standard, it's written in the code as `// STANDARD EXCEPTION [ID]: rationale` and noted in the PR — [CI-08]

---

## Final check — three questions

1. **If someone else opened this service without me having written it, would they know
   what to expect?** (Folder layout, naming, error body, pagination — all consistent?)
2. **What happens when a dependency goes down?** DB, Redis, upstream, the permission
   source — do you have an answer for each, and is that answer never "access widens"?
3. **Where do I look when something goes wrong?** Is there a `request_id` in the log, is
   there a metric, is there an alert configured?

If you don't have an answer to all three, the work isn't done.
