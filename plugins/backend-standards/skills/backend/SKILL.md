---
name: backend
description: Binding backend engineering standard for Go + Gin microservices behind an API gateway. Use whenever writing, reviewing or scaffolding a Go service, an endpoint, a migration, a Dockerfile/compose for a backend, or when asked "what is our backend standard". Loads only the rule files relevant to the task.
---

# Backend Standard (Go + Gin)

> **Scope note:** this standard was written for Turkish public-sector projects and
> keeps the rules that come with that: Turkish text casing and collation, national
> identity and tax numbers, and KVKK (Turkey's personal data protection law). The
> documents themselves are in English; where a rule exists because the data is
> Turkish, the reason is explained rather than assumed.

> **Language:** the rules are written in English so the set can be shared and reviewed by
> anyone. That is the source language, not the working language. **Answer the user in the
> language they write to you in**, and translate a rule when you quote it to them. What must
> not be translated is the rule itself: `MUST` stays a binding obligation and `SHOULD` stays
> a default, whatever language the conversation is in.

This skill is a **contract, not a suggestion**: one stack (Go 1.25 + Gin v1.12 + pgx/v5 +
Valkey + goose + `log/slog` + Prometheus/OTel), one folder layout, one error body, one set
of limits. Whoever writes it, human or AI. All documents live next to this file.
**Do not read all of them at once.** Read what the task needs.

## Always read first

1. [01-GOLDEN-RULES.md](01-GOLDEN-RULES.md) — the 24 golden rules. Every task.
2. [RULE-MAP.md](RULE-MAP.md) §1 — the **signal scan**. Scan the code you are
   about to write for the listed signals (`float64` + an amount, `ORDER BY` + `LIMIT`, a
   `PUT` handler, `http.Client{}`, a user-supplied URL, a `DELETE` endpoint,
   `strings.ToLower`, cron/`time.Ticker`, file upload, name/TCKN/phone columns,
   `go func(...)`, a new table…). Each signal points to a rule. **Read that rule from its
   file.** Do not write from memory.
3. The document(s) for the task, from the table below or `RULE-MAP.md` §2.

## Documents

| # | File | Read when |
|---|---|---|
| 🚀 | [START.md](START.md) | Wiring the standard into a repo: `templates/` agent files, opening prompt, task-specific openers |
| 📁 | [templates/](templates/) | Copyable agent instruction files: `AGENTS.md` + Claude/Cursor/Copilot/Windsurf/Gemini pointers |
| 🔧 | [tools/](tools/README.md) | Six audit tools: standards, secrets, collection, load test, version advisory, linter config |
| 🗺 | [RULE-MAP.md](RULE-MAP.md) | Signal → rule table; task → reading list; known gaps |
| 01 | [01-GOLDEN-RULES.md](01-GOLDEN-RULES.md) | **Always** |
| 02 | [02-TECH-VERSIONS.md](02-TECH-VERSIONS.md) | Starting a service, adding a dependency, `go.mod`/Dockerfile/compose |
| 03 | [03-PROJECT-STRUCTURE.md](03-PROJECT-STRUCTURE.md) | Service skeleton, layers, `main.go` wiring |
| 04 | [04-API-CONTRACT.md](04-API-CONTRACT.md) | Endpoints, DTOs, error body, pagination |
| 05 | [05-SECURITY.md](05-SECURITY.md) | Gateway auth, permissions, input validation, secrets |
| 06 | [06-RATE-LIMIT-RESILIENCE.md](06-RATE-LIMIT-RESILIENCE.md) | Limits, timeouts, retry, circuit breaker, graceful shutdown |
| 07 | [07-DATABASE.md](07-DATABASE.md) | Schema, migrations, queries, pool, indexes |
| 08 | [08-CACHE-REDIS.md](08-CACHE-REDIS.md) | Adding a cache |
| 09 | [09-PERFORMANCE-COST.md](09-PERFORMANCE-COST.md) | Targets, slowness, cost |
| 10 | [10-OBSERVABILITY.md](10-OBSERVABILITY.md) | Logs, metrics, traces, health |
| 11 | [11-ASYNC-KAFKA-TEMPORAL.md](11-ASYNC-KAFKA-TEMPORAL.md) | Queues, jobs, workflows |
| 12 | [12-TESTING.md](12-TESTING.md) | Writing or reviewing tests |
| 13 | [13-DOCKER-DEPLOY.md](13-DOCKER-DEPLOY.md) | Dockerfile, compose, deploy |
| 14 | [14-GIT-CI.md](14-GIT-CI.md) | Branching, commits, pipeline |
| 15 | [15-NEW-SERVICE-CHECKLIST.md](15-NEW-SERVICE-CHECKLIST.md) | **Before saying "done"** on a new service |
| 16 | [16-MONEY-AND-SENSITIVE-DATA.md](16-MONEY-AND-SENSITIVE-DATA.md) | Money (never float), KVKK/PII |
| 17 | [17-FILE-UPLOAD.md](17-FILE-UPLOAD.md) | File uploads |
| 18 | [18-CONCURRENCY-AND-TURKISH-DATA.md](18-CONCURRENCY-AND-TURKISH-DATA.md) | Concurrency, Turkish text (ı/İ), sorting |
| 19 | [19-IDENTITY-AND-SESSION.md](19-IDENTITY-AND-SESSION.md) | Identity, sessions, JWT at the gateway |
| 20 | [20-INTEGRATION-AND-BULK-DATA.md](20-INTEGRATION-AND-BULK-DATA.md) | Integrations, bulk data, ETL |
| GIS | [APPENDIX-GIS-POSTGIS.md](APPENDIX-GIS-POSTGIS.md) | PostGIS, geometry columns, tiles. Only for map-data projects |
| 📜 | [adr/](adr/README.md) | "Why Gin and not Fiber?" Every stack decision with alternatives and costs |

## How to work with this standard

- **Versions and dependencies** come from `02-TECH-VERSIONS.md`. A package not in the
  table is not added without asking the user.
- **"Why X, isn't Y better?"** Read the ADR first. Reopen only if its "What would change this decision"
  condition holds.
- **Standard vs existing code:** the standard wins for new code. Do not rewrite working
  code; write the new code correctly and tell the user about the conflict. Even next to
  services written with an older framework, a new service is Gin ([VER-17]).
- **Known gaps** are in `RULE-MAP.md` §4. Warn the user and write your decision with
  its reason into the code.

## Before saying "done"

```bash
bash <skill-dir>/tools/check-standards.sh .    # exit code must be 0
bash <skill-dir>/tools/check-secrets.sh .          # exit code must be 0 (secret leak scan)
golangci-lint run                               # clean (config: tools/golangci.yml → .golangci.yml)
go test -race ./...                             # clean

# When the service is up (needs a running gateway):
bash <skill-dir>/tools/run-collection.sh docs/<Service>.postman_collection.json
bash <skill-dir>/tools/load-test.sh <url> --sinif liste      # verifies the PERF-01 targets

# Advisory only, never fails:
bash <skill-dir>/tools/version-advice.sh .
```

`check-secrets.sh` only reports; it never edits, deletes or rotates anything. Closing a finding
is a human decision. `version-advice.sh` always exits 0 by design: a newer upstream version is
information, not a violation.

Then walk `15-NEW-SERVICE-CHECKLIST.md` item by item. Say explicitly which items were
skipped and why. A clean tool run is not "compliant"; tools see roughly 9 % of the rules.

## Never

- Say "works" without a test.
- Add a dependency without approval.
- Say "small change, no need to check the standard".
- Use `float` for money, `SELECT *`, `TIMESTAMP` without time zone, or `gin.Default()`.
- Treat a Postman collection without assertions as "working" ([TEST-24]).
- Fix a secret leak by deleting the file: removing it does not remove it from history, and
  without rotation it only hides the problem ([SEC-38]).
- Run git commands that change state (commit, push, reset, checkout, stash, branch/tag
  create or delete). Read-only git only.
