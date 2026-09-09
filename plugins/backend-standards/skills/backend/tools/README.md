# Automated Audit Tools

> This is the **machine-checkable** part of the standard. The goal is to reduce the
> burden on humans (and AI): a rule that can be caught mechanically is not left to
> code review.
>
> **These tools do not replace the standard.** They check about 6 % of the 594 rules; the
> rest is left to human/AI via the [RULE-MAP.md](../RULE-MAP.md) §1 signal scan.

---

## Files

| File | What it does |
|---|---|
| `check-standards.sh` | Language-independent and cross-cutting rules: SQL, Dockerfile, compose, route authorisation, money type, repo hygiene |
| `golangci.yml` | Go-specific rules; copied into the service root as `.golangci.yml` |
| `check-secrets.sh` | Secret leaks: tracked `.env`/`.pem`, embedded secrets, missing `.gitignore` entries ([SEC-38]) |
| `run-collection.sh` | Runs the Postman collection, looks for assertions, gives a rough duration measurement ([TEST-23]) |
| `load-test.sh` | k6 load test + [PERF-01] comparison + measurement validity gate ([PERF-33]) |
| `version-advice.sh` | Upstream version advice ([VER-21]). **Never returns FAIL** |

The two Go-side tools **complement each other**: `golangci-lint` looks at the Go AST
(exact), the scripts look at text patterns (broad but heuristic).

---

## Usage

```bash
# Whole repo
./backend-standards/tools/check-standards.sh .

# Single service
./backend-standards/tools/check-standards.sh services/parking-service

# Go side
cp backend-standards/tools/golangci.yml services/parking-service/.golangci.yml
cd services/parking-service && golangci-lint run
```

Exit code: **0** = clean · **1** = a MUST/MUST NOT violation exists (breaks CI).
Warnings do not affect the exit code.

---

## CI integration

Added to the pipeline in [14-GIT-CI.md](../14-GIT-CI.md) §4:

```yaml
- name: Standards audit
  run: ./backend-standards/tools/check-standards.sh .

- name: Lint
  run: golangci-lint run
```

---

## Rules checked — `check-standards.sh` (29 + linter)

### `check-standards.sh`

| Rule | What it catches |
|---|---|
| [VER-01] | `go.mod` version differs from the standard |
| [VER-02] | `image: ...:latest` in compose |
| [VER-05] | Forbidden dependency (fiber, lib/pq, gorm, viper, zap, testify...) |
| [MONEY-01] | Money field defined as `float32/64` |
| [MONEY-02] | Money column in SQL is `REAL/DOUBLE PRECISION/MONEY` |
| [AUTH-05] | `crypto/md5`, `crypto/sha1` import |
| [SEC-25] | Password/token/secret in a log line |
| [DB-05] | `SERIAL PRIMARY KEY` |
| [DB-06] | `TIMESTAMP` (no tz) |
| [DB-12] | Missing goose `Down` block |
| [DB-18] | `SELECT *` |
| [DB-19] | `ORDER BY … LIMIT` without a tie-break |
| [GIS-05] | `GEOMETRY` column present, no GIST index |
| [SEC-15] | Embedding a value into SQL with `Sprintf` |
| [STR-05] | File > 500 lines |
| [STR-10] | `*gin.Context` passed down to a lower layer |
| [STR-11] | `main.go` > 150 lines |
| [STR-13] | `gin.Default()` |
| [STR-14] | `gin.New()` present, no `ContextWithFallback` |
| [STR-19] | `c.JSON` in an error response (instead of Abort) |
| [API-06] | `*UpdateRequest` field is not a pointer |
| [API-12] | `c.Bind*` / `BindJSON` |
| [API-01b] | `/list` in a path |
| [GEN-10] | Unauthorised endpoint |
| [GEN-19] | Empty error block (two forms) |
| [OBS-01] | `fmt.Print*` / `log.Print*` |
| [TR-05] | `strings.ToLower/ToUpper` |
| [RES-07] | `http.Server` without a timeout |
| [RES-08] | `http.Client{}` without a timeout |
| [OPS-02] | Dockerfile `FROM …:latest` |
| [OPS-03] | No `USER` in the Dockerfile |
| [OPS-04] | No `HEALTHCHECK` |
| [OPS-06] | No `.dockerignore` |
| [OPS-12] | No log rotation in compose |
| [SEC-01] | `ports:` in compose |
| [SEC-18] | Secret embedded in compose |
| [SEC-20] | `.env` missing from `.gitignore` |
| [PERF-05] | No memory limit in compose |

### `golangci.yml` adds

`errcheck`, `errorlint` ([API-22]), `bodyclose`, `rowserrcheck`, `sqlclosecheck`
([PERF-16]), `noctx`/`contextcheck` ([GEN-17]), `gosec`, and `forbidigo`/`depguard`
give the AST-based, i.e. exact, counterparts of the items above.

---

## Verification — these tools were tested

The tools were exercised against two fake services (`kotu-service` / `iyi-service`,
i.e. "bad-service" / "good-service"):

| Measurement | Result |
|---|---|
| Distinct rules caught in the deliberately broken service | **29** |
| Total findings (broken service) | 40 errors + 3 warnings |
| **False positives in the standard-compliant service** | **0** |
| Example violations inside comment lines | **not caught** (correct behaviour) |
| Exit code | broken → `1`, clean → `0` |

Defect found and fixed during testing: an empty error block of the form
`if err := f(); err != nil {}` slipped through the first version; it was rewritten as a
two-line `awk`-based pattern.

---

## New tools (2026-09-08)

Four tools were added. Three break CI, one **deliberately does not**.

| File | What it does | Breaks CI |
|---|---|---|
| `check-secrets.sh` | Secret leaks: tracked `.env`/`.pem`, embedded secrets, missing `.gitignore` entries ([SEC-38]) | Yes, on a critical finding |
| `run-collection.sh` | Runs the Postman collection, looks for assertions, gives a rough duration measurement ([TEST-23], [TEST-24]) | Yes |
| `load-test.sh` | k6 load test, compares against [PERF-01] targets, checks measurement validity ([PERF-33], [PERF-34]) | Yes, if the measurement is valid |
| `version-advice.sh` | Is a newer upstream version available ([VER-21]) | **No, never** |

```bash
# Secret scan — on every PR
bash tools/check-secrets.sh .

# Collection: static review is possible even while the service is down
bash tools/run-collection.sh docs/Servis.postman_collection.json --analyze-only
bash tools/run-collection.sh docs/Servis.postman_collection.json \
     --base-url http://localhost:9000 --repeat 3 --code-dir services/parking-service

# Load test — on a nightly run or a PR that touches performance
bash tools/load-test.sh http://localhost:9000/parkings --class list --duration 30s --vu 10
bash tools/load-test.sh --summary onceki-ozet.json --class list   # evaluate without k6
bash tools/load-test.sh <url> --class list --compare dun.json

# Version advice — monthly, or on a PR that touches a dependency
bash tools/version-advice.sh .
```

Exit codes: `0` clean · `1` violation · `2` tool missing, usage error, **or the
measurement cannot be interpreted**. `version-advice.sh` returns `0` on every run.

---

### Why `2` is a separate code

`1` means "a rule was violated"; `2` means "I cannot say anything." Tying the two to
the same code makes a case the tool does not know about look like a violation, and the
reverse also happens: a step that fails because k6 is not installed then reads as
"the performance target was missed." The distinction is required for [PERF-34]'s
measurement validity gate to work.

### `check-secrets.sh` — three design decisions

**It never prints the value.** A found secret is reported only as location, type, and
a four-character prefix plus length (`ca75... (32 characters)`). An audit report must
not publish the secret it found; that is this standard's own [SEC-25] rule, and the
tool follows its own rule.

**It does not fix anything.** No `git rm`, no history cleanup, no rotation. The reason
is technical: deleting a leaked secret from the file does not remove it from history,
and deleting it without rotating first hides the problem without solving it. The
close-out order belongs to a human: rotation first, then untracking, history cleanup
last and as a separate decision.

**It does not scan git history.** It only looks at the working tree and the output of
`git ls-files`. A secret that was deleted in history but still sits in a commit is
**invisible** to this tool. This is its biggest gap, and the script states this in its
own output on every run.

### `run-collection.sh` — why it does not print p95

p95 cannot be computed from three samples per endpoint. The tool gives min/median/max,
does **not** make an SLO decision, and marks this explicitly in its JSON output
(`p95_computed: false`, `slo_verdict: null`). The target-based decision is
[PERF-33]'s job, via `load-test.sh`.

`newman run -n 3` runs the whole collection three times, so the same endpoint is not
hit back to back; requests are naturally interleaved. This keeps the cache from
repeatedly warming the same endpoint, but it does not cancel the effect out, and the
tool says so.

Endpoint classification (single record / list / write / heavy) is a **heuristic**
derived from the method and path pattern. A `POST` whose path contains `search` is
counted as a read, not a write; this exception is flagged both in the code and in the
output. An innocuously named but expensive endpoint gets misclassified.

### `version-advice.sh` — why it never returns FAIL

There are two different questions, and conflating them makes both useless:

| Question | Rule | Outcome |
|---|---|---|
| Does this service match the standard's version table | [VER-01] | **FAIL** — `check-standards.sh`'s job |
| Is there a newer version upstream | [VER-21] | Information — this tool's job |

Breaking the pipeline because a new version came out pushes the team toward disabling
the tool, and eventually nothing gets updated. The tool runs with `-mod=readonly`: it
reports a missing `go.sum` entry but **does not write it**. A tool that produces
reports does not modify the source files of the repo it reports on.

---

## Verification — the new tools were tested too

Measurement date 2026-09-08, on real repositories.

| Tool | Run | Result |
|---|---|---|
| `check-secrets.sh` | frontend repo | 31 critical, 3 warnings, exit 1 |
| `check-secrets.sh` | microservices repo | 8 critical, 3 warnings, exit 1 |
| `check-secrets.sh` | clean sample repo | **0 findings, exit 0** |
| `run-collection.sh` | address-search collection, static | 9 requests, **0 assertions**, exit 1 |
| `run-collection.sh` | no newman / service down | clean message, exit 2 |
| `load-test.sh` | no k6 / no target given | clean message, exit 2 |
| `load-test.sh` | 7 validity gates, with fake summaries | 7/7 correct decision |
| `version-advice.sh` | 47 modules, networked | 47 non-standard, 1127 updates, **exit 0** |

The real findings that came out of these runs (tracked `.env` and private key files,
collections with no assertions, three different Go versions, missing `go.sum`) were
written into the rules' rationale sections as measurements. The standard's clauses were
derived from these repos' actual state, not from assumption.

Defects found and fixed in the tools during testing: a Windows drive letter (`C:`)
breaking line-number parsing, the UI translation string "Şifreniz" ("Your password")
being mistaken for a secret, an MQTT `token.Error()` call being mistaken for a [SEC-25]
violation, a fake column name being generated from the `ST_Intersects` pattern,
migration files producing an N+1 finding. All of these were fixed by **narrowing** the
rule, per [TOOL-02], not by turning the check off.

---

## Limits of the new tools

**[TOOL-05] MUST:** `check-secrets.sh` does not scan git history and does not compute
entropy. It misses a secret assigned to an unnamed variable (`k = "..."`) or one
embedded in base64. The extensions it scans are limited to
`.go .yml .yaml .json .sql Dockerfile*`. A clean run does not mean "no secret exists";
it means "none was found with these patterns."

**[TOOL-06] MUST:** `run-collection.sh`'s endpoint classification and code findings
are a text pattern, not proof. The measurement is client-side: network, gateway, and
machine load time are included in the durations. It requires `node`; without it, exit 2.

**[TOOL-07] MUST:** `version-advice.sh` requires network access and takes minutes
across 47 modules. Without network it still produces the `go` directive table and
states why the network-dependent part was skipped. `--scan-major` only checks **one**
major version up; when disabled, the report says "not scanned," not "none."

**[TOOL-08] MUST:** `load-test.sh`'s result is not an absolute verdict. The measurement
depends on the machine and the network ([PERF-35]); its meaning lies in comparison with
a previous run in the same environment. If one of the validity gates fails, the tool
does **not** make a decision and returns exit 2. This is not a failure, it means
"no verdict can be drawn from this number."

## Limits — the honesty section (check-standards.sh)

**[TOOL-01] MUST:** These tools are **heuristics, not proof.**
- Text-pattern-based checks can produce false positives/negatives.
- Comment lines are filtered out, but code **inside a string literal** is not.
- `GEN-10` (unauthorised endpoint) only looks at `routes*.go` files; if the route is
  defined elsewhere, it does not see it.
- `MONEY-01` looks at the field **name**; it misses a money field with a meaningless
  name, such as `X float64`.

**[TOOL-02] MUST:** If a check produces a false positive, **narrow the rule**, do not
silently turn the check off. If it must be turned off, the reason goes into the commit
message (same logic as [CI-21]).

**[TOOL-03] MUST:** If a new rule can be handed off to a machine, it is added here and
recorded in the table above. **After it is added, it is re-tested against the fake
services** — an untested check produces false confidence.

**[TOOL-04] MUST:** A clean audit run **does not mean the code conforms to the
standard.** The tools cover ~9% of the rules. For the rest, the
[RULE-MAP.md](../RULE-MAP.md) §1 signal scan and
[15-NEW-SERVICE-CHECKLIST.md](../15-NEW-SERVICE-CHECKLIST.md) are mandatory.
