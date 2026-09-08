---
name: backend
description: Binding backend engineering standard (documents in Turkish) for Go + Gin microservices behind an API gateway. Use whenever writing, reviewing or scaffolding a Go service, an endpoint, a migration, a Dockerfile/compose for a backend, or when asked "what is our backend standard". Loads only the rule files relevant to the task.
---

# Backend Standard (Go + Gin)

> **Language note:** the rule documents in this skill are written in **Turkish**. This
> SKILL.md is in English so the skill is discoverable; when you read a rule file, keep its
> Turkish terms (ZORUNLU = MUST, YASAK = MUST NOT, ÖNERİ = SHOULD) and answer the user in
> the language they use.

This skill is a **contract, not a suggestion**: one stack (Go 1.25 + Gin v1.12 + pgx/v5 +
Valkey + goose + `log/slog` + Prometheus/OTel), one folder layout, one error body, one set
of limits. Whoever writes it, human or AI. All documents live next to this file.
**Do not read all of them at once.** Read what the task needs.

## Always read first

1. [01-ALTIN-KURALLAR.md](01-ALTIN-KURALLAR.md) — the 24 golden rules. Every task.
2. [KURAL-HARITASI.md](KURAL-HARITASI.md) §1 — the **signal scan**. Scan the code you are
   about to write for the listed signals (`float64` + an amount, `ORDER BY` + `LIMIT`, a
   `PUT` handler, `http.Client{}`, a user-supplied URL, a `DELETE` endpoint,
   `strings.ToLower`, cron/`time.Ticker`, file upload, name/TCKN/phone columns,
   `go func(...)`, a new table…). Each signal points to a rule. **Read that rule from its
   file.** Do not write from memory.
3. The document(s) for the task, from the table below or `KURAL-HARITASI.md` §2.

## Documents

| # | File | Read when |
|---|---|---|
| 🚀 | [BASLANGIC.md](BASLANGIC.md) | Wiring the standard into a repo: `sablon/` agent files, opening prompt, task-specific openers |
| 📁 | [sablon/](sablon/) | Copyable agent instruction files: `AGENTS.md` + Claude/Cursor/Copilot/Windsurf/Gemini pointers |
| 🔧 | [arac/](arac/README.md) | Six audit tools: standards, secrets, collection, load test, version advisory, linter config |
| 🗺 | [KURAL-HARITASI.md](KURAL-HARITASI.md) | Signal → rule table; task → reading list; known gaps |
| 01 | [01-ALTIN-KURALLAR.md](01-ALTIN-KURALLAR.md) | **Always** |
| 02 | [02-TEKNOLOJI-SURUMLERI.md](02-TEKNOLOJI-SURUMLERI.md) | Starting a service, adding a dependency, `go.mod`/Dockerfile/compose |
| 03 | [03-PROJE-YAPISI.md](03-PROJE-YAPISI.md) | Service skeleton, layers, `main.go` wiring |
| 04 | [04-API-SOZLESMESI.md](04-API-SOZLESMESI.md) | Endpoints, DTOs, error body, pagination |
| 05 | [05-GUVENLIK.md](05-GUVENLIK.md) | Gateway auth, permissions, input validation, secrets |
| 06 | [06-RATE-LIMIT-DAYANIKLILIK.md](06-RATE-LIMIT-DAYANIKLILIK.md) | Limits, timeouts, retry, circuit breaker, graceful shutdown |
| 07 | [07-VERITABANI.md](07-VERITABANI.md) | Schema, migrations, queries, pool, indexes |
| 08 | [08-CACHE-REDIS.md](08-CACHE-REDIS.md) | Adding a cache |
| 09 | [09-PERFORMANS-MALIYET.md](09-PERFORMANS-MALIYET.md) | Targets, slowness, cost |
| 10 | [10-GOZLEMLENEBILIRLIK.md](10-GOZLEMLENEBILIRLIK.md) | Logs, metrics, traces, health |
| 11 | [11-ASENKRON-KAFKA-TEMPORAL.md](11-ASENKRON-KAFKA-TEMPORAL.md) | Queues, jobs, workflows |
| 12 | [12-TEST.md](12-TEST.md) | Writing or reviewing tests |
| 13 | [13-DOCKER-DEPLOY.md](13-DOCKER-DEPLOY.md) | Dockerfile, compose, deploy |
| 14 | [14-GIT-CI.md](14-GIT-CI.md) | Branching, commits, pipeline |
| 15 | [15-YENI-SERVIS-CHECKLIST.md](15-YENI-SERVIS-CHECKLIST.md) | **Before saying "done"** on a new service |
| 16 | [16-PARA-VE-HASSAS-VERI.md](16-PARA-VE-HASSAS-VERI.md) | Money (never float), KVKK/PII |
| 17 | [17-DOSYA-YUKLEME.md](17-DOSYA-YUKLEME.md) | File uploads |
| 18 | [18-ESZAMANLILIK-VE-TURKCE-VERI.md](18-ESZAMANLILIK-VE-TURKCE-VERI.md) | Concurrency, Turkish text (ı/İ), sorting |
| 19 | [19-KIMLIK-VE-OTURUM.md](19-KIMLIK-VE-OTURUM.md) | Identity, sessions, JWT at the gateway |
| 20 | [20-ENTEGRASYON-VE-TOPLU-VERI.md](20-ENTEGRASYON-VE-TOPLU-VERI.md) | Integrations, bulk data, ETL |
| GIS | [EK-GIS-POSTGIS.md](EK-GIS-POSTGIS.md) | PostGIS, geometry columns, tiles. Only for map-data projects |
| 📜 | [adr/](adr/README.md) | "Why Gin and not Fiber?" Every stack decision with alternatives and costs |

## How to work with this standard

- **Versions and dependencies** come from `02-TEKNOLOJI-SURUMLERI.md`. A package not in the
  table is not added without asking the user.
- **"Why X, isn't Y better?"** Read the ADR first. Reopen only if its "Kararı ne değiştirir"
  (what would change this decision) condition holds.
- **Standard vs existing code:** the standard wins for new code. Do not rewrite working
  code; write the new code correctly and tell the user about the conflict. Even next to
  services written with an older framework, a new service is Gin ([VER-17]).
- **Known gaps** are in `KURAL-HARITASI.md` §4. Warn the user and write your decision with
  its reason into the code.

## Before saying "done"

```bash
bash <skill-dir>/arac/standart-kontrol.sh .    # exit code must be 0
bash <skill-dir>/arac/sir-tarama.sh .          # exit code must be 0 (secret leak scan)
golangci-lint run                               # clean (config: arac/golangci.yml → .golangci.yml)
go test -race ./...                             # clean

# When the service is up (needs a running gateway):
bash <skill-dir>/arac/koleksiyon-kosum.sh docs/<Service>.postman_collection.json
bash <skill-dir>/arac/yuk-testi.sh <url> --sinif liste      # verifies the PERF-01 targets

# Advisory only, never fails:
bash <skill-dir>/arac/surum-onerisi.sh .
```

`sir-tarama.sh` only reports; it never edits, deletes or rotates anything. Closing a finding
is a human decision. `surum-onerisi.sh` always exits 0 by design: a newer upstream version is
information, not a violation.

Then walk `15-YENI-SERVIS-CHECKLIST.md` item by item. Say explicitly which items were
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
