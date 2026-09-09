# Rule Map — "Nerve Endings"

> **What this file is for:** no one can memorize 476 rules, and reading all 19 files every
> time wastes context. This map looks at **the code in front of you** and tells you which
> rules apply.
>
> The logic: every rule is tied to a **signal**. If that signal appears in your code or
> schema, the matching rule **triggers** and must be read. If the signal isn't there, don't
> even open that file.
>
> **[MAP-01] MUST:** Scan the signal table in §1 before writing code. For every signal
> that appears in the code you write or change, read the rules listed next to it.

---

## 1. Signal table — if you see THIS in your code, read THAT

### 1.1 Data types and schema

| Signal (what you see in code/schema) | Rule triggered | Why it's urgent |
|---|---|---|
| `float64` / `REAL` with an amount, price, debt, fee, balance | **[MONEY-01]** → [16 §1](16-MONEY-AND-SENSITIVE-DATA.md) | Cents drift silently, reconciliation won't balance |
| New `CREATE TABLE` | [DB-05]…[DB-10] | UUID PK, TIMESTAMPTZ, CHECK, comment |
| `SERIAL` / `BIGSERIAL` primary key | [DB-05], [API-02] | IDOR — sequential ids leak out |
| `TIMESTAMP` (without tz) | [DB-06] | Data drifts when the server's clock changes |
| Nullable `FOREIGN KEY` | [DB-07] | Produces orphaned records |
| First name, last name, TCKN (the Turkish national identity number), phone, email, address column | **[KVKK-01]…[KVKK-12]** → [16 §2](16-MONEY-AND-SENSITIVE-DATA.md) | Inventory, retention period, deletion |
| `GEOMETRY` / coordinate column | [APPENDIX-GIS](APPENDIX-GIS-POSTGIS.md) in full | Type measurement, GIST index, ST_IsValid |
| `deleted_at` (soft delete) | [DB-33], **[KVKK-05]** | Does not count as deletion for personal data |
| Computable column (total minus occupied, etc.) | [DB-09], [API-08] | Must be `GENERATED`, never taken from the client |

### 1.2 Query

| Signal | Rule triggered | Why it's urgent |
|---|---|---|
| `ORDER BY` + `LIMIT`/`OFFSET` | **[DB-19]**, [API-27] | Without a tie-break, records repeat or get skipped across pages |
| `SELECT *` | [DB-18] | Scan order shifts when a column is added |
| Building SQL with `fmt.Sprintf` | **[SEC-15]** | SQL injection |
| Query inside a loop | **[DB-28]** | N+1 |
| Client-supplied column/sort name inside `WHERE` | [API-26], [SEC-16] | A whitelist is mandatory |
| `LOWER()`, `UPPER()`, `ILIKE` (Turkish text) | **[TR-02]**, [TR-03] → [18 §2](18-CONCURRENCY-AND-TURKISH-DATA.md) | `İ`/`ı` conversion doesn't behave as expected; the search finds no results |
| Work that changes multiple tables | [DB-22], [DB-23] | Single transaction + `defer Rollback` |
| Reading a money column | [MONEY-06] | Must be selected with `::text` |

### 1.3 HTTP layer

| Signal | Rule triggered | Why it's urgent |
|---|---|---|
| New endpoint definition | **[GEN-10]**, [STR-20] | Every endpoint must require a permission |
| `PUT` handler | **[API-06]** | All fields must be pointers, otherwise the other fields get zeroed |
| Required numeric/coordinate field in a `POST` DTO | **[API-07]** | Value type → a missing field silently becomes `0` |
| Date field + partial update | **[API-11]** | Three states: leave untouched / null / value |
| Endpoint that returns a list | [API-18], [API-19], [STR-18] | Pagination + `clampPagination` |
| Returning an error with `c.JSON(...)` | [STR-19] | Must be `AbortWithStatusJSON`, the chain must stop |
| No `return` after `c.ShouldBindJSON` | **[API-12b]** | A second response gets written |
| `h.svc.X(c, ...)` — passing gin.Context to a lower layer | **[STR-10]** | Layer violation + untestability |
| `binding:"required"` tag | [SEC-12b], [VER-09] | Treats a zero value as "missing" |
| Path: `/resource/list` | [API-01b], [STR-21] | The list must live at the resource's root |

### 1.4 Anything exposed to the outside world

| Signal | Rule triggered | Why it's urgent |
|---|---|---|
| `multipart`, `FormFile`, file upload | **[17](17-FILE-UPLOAD.md) in full** | The surface attackers control the most |
| Making a request to a user-supplied URL | **[FILE-18]** | SSRF — you become a proxy into the internal network |
| Creating an `http.Client{}` | **[RES-08]**, [PERF-14] | The default timeout is **infinite** |
| Serving an uploaded file | **[FILE-11]** | Serving it from the main domain = stored XSS |
| External API call | [RES-07], [RES-11]…[RES-14] | Timeout, retry, jitter, single layer |
| Adding a new dependency | **[GEN-03]**, [VER-07] | Requires approval + an ADR |

### 1.5 Concurrency and resources

| Signal | Rule triggered | Why it's urgent |
|---|---|---|
| `go func(...)` | [RES-21], [RES-22] | Termination condition + bound |
| Opening `rows`, a file, a connection | [PERF-16] | The pool runs dry if it isn't closed |
| `defer` inside a loop | [PERF-15] | Resources pile up until the function returns |
| Keeping state in process memory | [PERF-29] | Can't scale horizontally |
| Two users can edit the same record | **[CONC-01]**, [CONC-02] → [18 §1](18-CONCURRENCY-AND-TURKISH-DATA.md) | Silent overwrite (lost update) |
| Read-modify-write instead of `count = count + 1` | **[CONC-09]** | The counter loses updates under concurrent requests |
| `ORDER BY` + a Turkish name | [TR-02] | Ç/Ğ/İ/Ö/Ş/Ü sort incorrectly |
| `strings.ToLower` + Turkish text in Go | **[TR-05]** | The locale-independent rule is wrong for Turkish |
| Cache/lock/counter | [08](08-CACHE-REDIS.md), [CACHE-08], [CACHE-19] | TTL is mandatory, lock ownership must be verified |

### 1.6 Sensitive operations

| Signal | Rule triggered | Why it's urgent |
|---|---|---|
| Operation that changes money | **[MONEY-12]**, [MONEY-13], [API-25] | Transaction + idempotency + audit trail |
| `DELETE` endpoint | **[AUDIT-01]**, [AUDIT-08], [KVKK-04] | A trace must remain, personal data must actually be deleted |
| Operation that changes a permission/role | [AUDIT-01], [SEC-09] | An audit trail is mandatory |
| Bulk update/delete | [DB-34], [AUDIT-01] | Run `COUNT(*)` first, then execute |
| Special-category data (health, biometric) | **[KVKK-07]** | Separate permission + every access logged |
| Secret/key/password | [GEN-13], [SEC-18]…[SEC-24] | Never goes into code, compose, or git |
| Password storage | **[AUTH-01]** → [19](19-IDENTITY-AND-SESSION.md) | argon2id + OWASP parameters |
| Login / token / session | [AUTH-10]…[AUTH-21] | Enumeration, lockout, refresh rotation |
| Bulk import | **[ETL-02]**, [ETL-05] → [20 §1](20-INTEGRATION-AND-BULK-DATA.md) | Idempotency + skipped-row report |
| `time.Ticker` / cron / scheduled job | **[JOB-01]** | The job runs N times across multiple replicas |
| Email / SMS sending | **[NOTIF-01]** | Duplicate notification on retry |
| Outgoing webhook | **[HOOK-01]** | Signing + replay protection |
| WebSocket / SSE connection | [STREAM-02], [STREAM-04] | Permission refresh + backpressure |

### 1.7 Infrastructure

| Signal | Rule triggered |
|---|---|
| New `Dockerfile` | [OPS-01]…[OPS-08] |
| Editing `docker-compose.yml` | [OPS-09]…[OPS-13], [PERF-04] |
| New service (end to end) | [15](15-NEW-SERVICE-CHECKLIST.md) in full |
| New migration | [DB-12]…[DB-16] |
| New event/queue | [ASYNC-04], [ASYNC-07], [ASYNC-17] |
| New Temporal workflow | [ASYNC-20]…[ASYNC-24] |
| Adding a log line | [OBS-01], [OBS-06], [SEC-25] |
| New metric | [OBS-10], **[OBS-11]** (no UUID/IP in the label) |
| Touching a `.env`, `*.pem`, `*.key` file | [SEC-20], [SEC-21], **[SEC-38]** (secret scan) |
| New endpoint (also gets added to the collection) | [TEST-23], [TEST-24], [TEST-25] |
| Writing a function that parses external input | [TEST-08], [TEST-26] (fuzz target) |
| Changing a version in `go.mod` | [VER-01] (FAIL), [VER-21] (advisory) — **these are two different things** |
| Change that touches performance | [PERF-33] (load test), [PERF-34] (measurement validity) |

---

## 2. Reading list by task

Beyond the signal scan, read these upfront depending on the kind of work:

| What you're doing | Read | Skip |
|---|---|---|
| Starting a new project | 01, 02, 03, 13, [adr/](adr/README.md) | 08, 11, 16, 17 (if not needed) |
| Adding a new service | 02, 03, 13, 15 | — |
| Adding an endpoint | 04, 05, 12 + §1 signal scan | 13, 14 |
| Changing a schema/table | 07, 16 §2 (if there's personal data) | — |
| There's money/payment/debt work | **16 §1 (mandatory)**, 07, 12 | — |
| Doing file uploads | **17 (mandatory)**, 05 | — |
| Slowness/cost problem | 09 → 07 → 08 | — |
| Queue/worker/scheduled job | 11, 06 | — |
| Adding a cache | 08, 09 | — |
| Setting up deploy/CI | 13, 14, 10 | — |
| Turkish text search/sorting | **18 §2 (mandatory)** | — |
| More than one person edits the same record | **18 §1 (mandatory)** | — |
| Writing password/login/token code | **19 (mandatory)**, 05 | — |
| Data transfer / cron / notification / webhook | **20 (mandatory)**, 11 | — |
| Security review | 05, 16, 17, 19 | — |
| Map/geometry data | [APPENDIX-GIS](APPENDIX-GIS-POSTGIS.md), 07 | — |
| "Why do we use X?" | [adr/](adr/README.md) | everything else |

---

## 3. Topic → file quick index

```
API contract, DTO, error body, pagination ........... 04
Notification (email/SMS) ............................ 20 §3
Audit / audit trail .................................. 16 §3
Adding a dependency, choosing a version ............. 02 + adr/
Cache, TTL, invalidation, distributed lock .......... 08
Live stream (WebSocket/SSE) ......................... 20 §5
CI, lint, PR, commit ................................ 14
Circuit breaker, retry, backoff ..................... 06 §3-4
Docker, compose, env layers .......................... 13
Concurrent editing, optimistic locking .............. 18 §1
File upload, download, SSRF ......................... 17
Geometry, GeoJSON, PostGIS ........................... APPENDIX-GIS
Graceful shutdown, panic, health .................... 06 §5, §7
Input validation ..................................... 05 §3
Layers, folder structure, main.go ................... 03
Identity, password, token, session .................. 19
Personal data, KVKK, 72 hours ........................ 16 §2
Log, metric, trace, alarm ............................ 10
Migration, goose, index, transaction ................ 07
Money, decimals, rounding ............................ 16 §1
Performance targets, profiling, resource limits ..... 09
Rate limit, timeout, body limit ...................... 06 §1-2
Test, stub, testcontainers ........................... 12
Bulk import (ETL), scheduled job ..................... 20 §1-2
Turkish text, collation, encoding, time .............. 18 §2-3
Webhook (outgoing) ................................... 20 §4
Permissions, gateway, secret management, CORS ....... 05
New service checklist ................................ 15
```

---

## 4. ⚠️ Known coverage gaps

> **The honesty section.** There are **no rules yet** for these topics. If you run into
> one of them while scanning the signal table, don't rely on the standard — proceed
> carefully and raise closing the gap. This list is a maturity indicator for the standard:
> the shorter it gets, the stronger the standard becomes.

| Gap | Risk | Status |
|---|---|---|
| **Incident response process** | There's a runbook rule ([OBS-22]), but the flow for "the alarm went off, who does what" isn't written down | Open |
| **Local development setup** | A new developer's first-day flow isn't written down | Open |
| **Capacity planning** | There's no threshold for "when should we scale up" | Open |
| **Search infrastructure** | Postgres FTS or a separate search engine — no decision has been made | Open |
| **API versioning** | The routes in `04` start with `/v1`, but what happens when a breaking change is needed isn't written down: whether `/v2` gets opened, how long the old version stays alive, how clients are notified. Since the frontend and backend deploy separately, this will be needed sooner or later | Open |
| **Backup and rollback** | `07` has a single rule; there's no backup frequency, retention period, **tested restore**, or RPO/RTO target. An untested backup is not a backup | Open |
| Multi-tenancy | Not needed in a single-institution project | Out of scope (deliberate) |
| Feature flags | The need hasn't come up | Out of scope (deliberate) |

> **Closed (2026-08-12):** concurrent editing → [18 §1](18-CONCURRENCY-AND-TURKISH-DATA.md) ·
> Turkish collation → [18 §2](18-CONCURRENCY-AND-TURKISH-DATA.md) · password storage,
> sessions, account lockout → [19](19-IDENTITY-AND-SESSION.md) · bulk import, cron,
> notification, outgoing webhook, live stream → [20](20-INTEGRATION-AND-BULK-DATA.md)

**[MAP-02] MUST:** Adding a new gap to this table is as valuable as writing a rule.
If you wrote code for something the standard doesn't cover, **add a line here** — so the
next person is at least forewarned.

**[MAP-03] MUST:** When a gap is closed, remove it from this table and add its
counterpart to the signal table in §1. A stale gap list creates false confidence.

---

## 4b. Which rules are checked automatically?

Five tools run machine audits in CI — you don't need to search for these separately,
if you violate one the build breaks: [tools/README.md](tools/README.md)

| Tool | What it checks | Does it FAIL |
|---|---|---|
| `check-standards.sh` | 29 language-agnostic rules: SQL, Dockerfile, compose, route permissions, money type | Yes |
| `golangci.yml` | Go AST-based rules | Yes |
| `check-secrets.sh` | Tracked secret files, embedded secrets, missing `.gitignore` entries ([SEC-38]) | Yes, on a critical finding |
| `run-collection.sh` | Whether the collection runs, whether assertions exist, rough duration ([TEST-23], [TEST-24]) | Yes |
| `load-test.sh` | [PERF-01] targets + measurement validity ([PERF-33], [PERF-34]) | Yes, if the measurement is valid |
| `version-advice.sh` | Whether a newer upstream version exists ([VER-21]) | **No, never** |

The remaining ~550 rules are **still your responsibility.** A clean automated check
does not mean "compliant with the standard" ([TOOL-04]).

---

## 5. Usage for an AI agent

```
1. Read the task → work out the reading list from §2
2. Think about the code you are about to write/change → scan the §1 signal table
3. READ every triggered rule from its file (do not assume from memory)
4. If you are stepping into one of the gaps in §4: WARN the user, write your own
   decision with its rationale, and report the gap
5. Run `tools/check-standards.sh` → then 15-NEW-SERVICE-CHECKLIST.md
```

**[MAP-04] MUST (AI):** Do not say "this change is small, no signal scan needed."
Most entries in the signal table are bugs born from **one-line changes** — an `ORDER BY`,
a `float64`, a missing `return`.
