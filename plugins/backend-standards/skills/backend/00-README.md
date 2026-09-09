# Backend Development Standard — Index

> **What this set is for:** the **binding baseline** to follow when starting a backend
> project or adding a service to an existing one. The goal is single: 30 services should
> not be written 30 different ways. Whoever writes it, human or AI, uses the same
> framework, the same version, the same folder layout, the same error body, the same limits.
>
> **Scope:** Go + Gin, single stack. Microservices running behind a gateway.
> Rules specific to digital twin / GIS projects are in a separate appendix
> (`APPENDIX-GIS-POSTGIS.md`), read only on a project that carries map data.
>
> **Last updated:** 2026-08-12, the version table was verified on this date.

---

## Files

| # | File | When to read it |
|---|---|---|
| 🚀 | [START.md](START.md) | **Do this first.** Wiring the standard into a project: `templates/` setup, the opening prompt, task-specific entry points |
| 📁 | [templates/](templates/) | Agent files to copy in: `AGENTS.md` (shared) plus pointers for Claude/Cursor/Antigravity/Copilot/Windsurf |
| 01 | [01-GOLDEN-RULES.md](01-GOLDEN-RULES.md) | **Always.** The non-negotiable items. |
| 02 | [02-TECH-VERSIONS.md](02-TECH-VERSIONS.md) | When starting a project, adding a dependency, writing `go.mod` / Dockerfile / compose |
| 03 | [03-PROJECT-STRUCTURE.md](03-PROJECT-STRUCTURE.md) | When setting up a project/service skeleton |
| 04 | [04-API-CONTRACT.md](04-API-CONTRACT.md) | When designing endpoints, writing DTOs, returning errors |
| 05 | [05-SECURITY.md](05-SECURITY.md) | Auth, permissions, input validation, secret management |
| 06 | [06-RATE-LIMIT-RESILIENCE.md](06-RATE-LIMIT-RESILIENCE.md) | Limits, timeouts, retries, circuit breakers, shutdown |
| 07 | [07-DATABASE.md](07-DATABASE.md) | Schema, migrations, queries, pooling, indexes |
| 08 | [08-CACHE-REDIS.md](08-CACHE-REDIS.md) | The moment you add a cache |
| 09 | [09-PERFORMANCE-COST.md](09-PERFORMANCE-COST.md) | When setting targets, or facing a slowness/cost problem |
| 10 | [10-OBSERVABILITY.md](10-OBSERVABILITY.md) | Logs, metrics, traces, health |
| 11 | [11-ASYNC-KAFKA-TEMPORAL.md](11-ASYNC-KAFKA-TEMPORAL.md) | When a synchronous request is no longer enough |
| 12 | [12-TESTING.md](12-TESTING.md) | Before writing code |
| 13 | [13-DOCKER-DEPLOY.md](13-DOCKER-DEPLOY.md) | Dockerfile, compose, env, deploy |
| 14 | [14-GIT-CI.md](14-GIT-CI.md) | Branches, commits, PRs, pipelines |
| 15 | [15-NEW-SERVICE-CHECKLIST.md](15-NEW-SERVICE-CHECKLIST.md) | Before declaring the work done |
| 16 | [16-MONEY-AND-SENSITIVE-DATA.md](16-MONEY-AND-SENSITIVE-DATA.md) | **Any project with money/amounts, personal data (KVKK) or an audit trail** |
| 17 | [17-FILE-UPLOAD.md](17-FILE-UPLOAD.md) | If there is file upload, download, or fetching content from an external URL |
| 18 | [18-CONCURRENCY-AND-TURKISH-DATA.md](18-CONCURRENCY-AND-TURKISH-DATA.md) | **Any project working with Turkish text.** Also: when more than one person can edit the same record |
| 19 | [19-IDENTITY-AND-SESSION.md](19-IDENTITY-AND-SESSION.md) | A service that manages passwords, login, tokens, sessions (auth) |
| 20 | [20-INTEGRATION-AND-BULK-DATA.md](20-INTEGRATION-AND-BULK-DATA.md) | Imports, scheduled jobs, notifications, outbound webhooks, live streams |
| APP | [APPENDIX-GIS-POSTGIS.md](APPENDIX-GIS-POSTGIS.md) | **Only** if there is map/geometry data |
| 🧭 | [RULE-MAP.md](RULE-MAP.md) | **Every time, before writing code.** Looks at the code ahead of you and says which rules it triggers, plus known coverage gaps |
| 🔧 | [tools/](tools/README.md) | Seven automated checks: standards, secrets, Postman collection, load test, version advice, reference and language consistency, plus `golangci.yml`. 35 rules handed to the machine |
| ADR | [adr/](adr/README.md) | **Before arguing about a choice.** 18 decision records: what we chose and why, what the alternatives were, what would change the decision |

---

## Rule ID prefixes

| Prefix | File | Prefix | File |
|---|---|---|---|
| API | 04 | ASYNC | 11 |
| AUDIT | 16 | AUTH | 19 |
| CACHE | 08 | CI | 14 |
| CONC | 18 | DB | 07 |
| ETL | 20 | FILE | 17 |
| GEN | 00 | GIS | APPENDIX-GIS-POSTGIS |
| HOOK | 20 | JOB | 20 |
| KVKK | 16 | MAP | RULE-MAP |
| MONEY | 16 | NOTIF | 20 |
| OBS | 10 | OPS | 13 |
| PERF | 09 | RES | 06 |
| SEC | 05 | STR | 03 |
| STREAM | 20 | TEST | 12 |
| TIME | 18 | TR | 18 |
| TOOL | tools/ | | |
| VER | 02 |  |  |

Severity words: **MUST** (binding), **MUST NOT** (forbidden), **SHOULD** (default;
deviating requires a written reason in the PR).

---

## Rule format

Every rule is written like this and **its id never changes**:

```
[SEC-04] MUST: The service does not trust the JWT the gateway validated; it does its
own X-Gateway-Source + X-API-Key check.

  Why: Someone who bypasses the gateway and hits the service directly from the internal
  network has bypassed every gateway check. A single layer of defence is not enough.
```

| Level | Meaning |
|---|---|
| **MUST** | Code is not merged without this. No exception without a reason. |
| **MUST NOT** | If this is done, the code is not merged. |
| **SHOULD** | This is the default behaviour. If you deviate, write **why** in a code comment. |

**Exception procedure:** if you need to deviate from a MUST/MUST NOT rule, put this
comment at the top of the deviating file and write the reason in the PR description:

```go
// STANDARD EXCEPTION [DB-07]: This table uses a BIGSERIAL PK instead of a UUID PK
// because it writes 200k rows per second and UUID index bloat was measured and
// confirmed (see PR #142).
```

A deviation without a reason is not an "exception," it is a bug.

---

## How an AI agent uses this set

If you are having an AI agent (Claude Code, Copilot, Cursor, etc.) apply this standard:

### 1. Reading order

```
On every task:  00-README (this file) → 01-GOLDEN-RULES → RULE-MAP (signal scan)
Then, depending on the task, only the relevant files:
  "open a new service"        → 02, 03, 13, 15
  "add an endpoint"           → 04, 05, 12
  "it's running slow"         → 09, 07, 08
  "need a queue/worker"       → 11, 06
  "deploy"                    → 13, 14, 10
  "there's an amount/payment/debt" → 16 §1  (MUST, float for money is the most
                                              expensive silent bug there is)
  "there's personal data"     → 16 §2, §3
  "there's file upload"       → 17
  "Turkish text search"       → 18 §2  (the ı/İ problem, search silently fails to find
                                        a record)
  "two people edit the same record" → 18 §1  (lost update)
  "password/login/token"      → 19
  "data transfer/cron/notification/webhook/live stream" → 20
```

Do not read every file at once, it wastes context and irrelevant rules muddy the decision.

### 2. Protocol to follow

- **[GEN-00a] MUST:** Before writing code, scan the [RULE-MAP.md](RULE-MAP.md) §1
  signal table: every signal present in the code you are about to write triggers a rule.
  If you're heading into one of the **known gaps** in §4, warn the user.
- **[GEN-00] MUST:** Read the relevant standard file before writing code. Do not write
  from a version/rule you think you remember; whatever the file says is what holds.
- **[GEN-00b] MUST:** If you need to pick a version, check the `02-TECH-VERSIONS.md`
  table. Adding a dependency that is not in the table **requires approval**, ask the
  user, do not add it on your own.
- **[GEN-00c] MUST:** Before declaring the work done, run `tools/check-standards.sh`,
  then go through `15-NEW-SERVICE-CHECKLIST.md` item by item and state clearly which
  item was skipped and why. **A clean automated check is not enough** — tooling covers
  about 6 % of the rules ([TOOL-04]).
- **[GEN-00d] MUST:** If the standard conflicts with existing code, **the standard
  wins** — but do not touch the working existing code; write the new code to the
  standard and report the conflict. Even if you see services in the repo written with
  an old framework, **write the new service in Gin** ([VER-17]); do not copy from a
  neighbouring service, start from the skeleton in [03](03-PROJECT-STRUCTURE.md).
- **[GEN-00e] MUST NOT:** Say "this is a small change, no need to check the standard."
  The standard is always broken through a small change.
- **[GEN-00f] MUST:** Before answering "why do we use X, isn't Y better," read the
  relevant decision record under [adr/](adr/README.md). The decision has already been
  made and justified. If you have new information (a new version, a new measurement, a
  changed licence), check the record's **"What would change this decision"** section;
  if the condition stated there has occurred, propose reopening the record, do not
  change it yourself.

### 3. A short prompt for an agent

If you want to give an agent context in a single line:

```
On this project we follow the standard under backend-standards/. Go 1.25.12 + Gin
v1.12 + pgx/v5, single stack. Before writing code, read 01-GOLDEN-RULES.md and the
file that matches the task at hand. Before writing code, scan the RULE-MAP.md §1
signal table.
Pick versions from 02-TECH-VERSIONS.md; ask me before adding a dependency that isn't
in the table. Go through 15-NEW-SERVICE-CHECKLIST.md before finishing.
```

---

## How this standard is updated

- Every decision that changes the standard is written **with a reason**. "This is
  better" is not a reason; "this measurement/this incident showed X" is a reason.
- When a real incident turns into a rule, write the **short case** under the rule. A
  rule whose reason is unknown gets deleted at the first opportunity.
- The version table (`02`) is reviewed every three months. The review date goes at the
  top of the file, "last checked 8 months ago" is worth more than a wrong version.
- If a rule has been broken in three projects in a row, the rule is wrong, not the
  team. Fix the rule.
