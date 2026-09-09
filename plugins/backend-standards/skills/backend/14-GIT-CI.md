# 14 — Git, Code Review and CI

---

## 1. Branch and commit

**[CI-01] MUST:** `main` is always in a deployable state. No direct push to `main`;
every change comes through a branch + PR.

**Branch naming:**
```
feat/<short-description>      new feature
fix/<short-description>       bug fix
chore/<short-description>     dependency, configuration, cleanup
docs/<short-description>      documentation
```

**[CI-02] MUST — Commit message format** (Conventional Commits):
```
<type>(<scope>): <what was done, imperative mood, under 72 characters>

<why it was done — this is the actually valuable part>
<if applicable: which alternative was not chosen, and why>
```
Example:
```
fix(parking): add id tie-break to paginated query

created_at values were written identically during seeding, so ordering
was unstable; records were both duplicated and skipped across pages.
A client walking all pages computed an incorrect total.
```

**[CI-03] MUST:** A commit does **one thing**. Formatting + refactor + feature don't
belong in the same commit; it can't be decomposed when it needs to be reverted.

**[CI-04] MUST NOT:** Commit `.env*`, `*.pem`, `*.key`, a production backup, or a large
binary file. If a secret got committed, rotate it ([SEC-22]).

**[CI-05] MUST:** `go.sum` is committed; `vendor/` is not used (if it will be, decide
this project-wide and upfront).

---

## 2. Pull request

**[CI-06] MUST:** Keep a PR **small**. A diff exceeding 400 lines is not accepted
without justification.
> **Why:** Review quality is inversely proportional to diff size. A 1,500-line PR
> gets "LGTM"; a 200-line PR actually gets read.

**[CI-07] MUST:** The PR description includes:
```
## What
<summary of the change>

## Why
<which problem, which measurement/request>

## How it was verified
<tests run + manual verification, 12-TESTING §6 checklist>

## Risks / rollback
<what it could break, how to roll it back>
```

**[CI-08] MUST:** If there is a deviation from the standard, it is stated **explicitly**
in the PR and a `// STANDARD EXCEPTION [RULE-ID]: <rationale>` comment is left in the
code ([00-README] §Rule format).

**[CI-09] MUST:** No merge without at least one approval. The approver must have
**actually read** the code; a rubber-stamp approval hides the fact that no review happened.

**[CI-10] MUST:** Dependency upgrades and large refactors are **separate PRs**; they
are not mixed into a feature PR.

---

## 3. Code review

**[CI-11] MUST — Order the reviewer follows:**

```
1. Security       → is there authorisation, is input validated, does a secret leak, is SQL parameterised
2. Correctness    → edge cases (nil, 0, empty, boundary), error paths, concurrency
3. Contract       → does the API/error/pagination shape match the standard
4. Resilience     → timeout, context, resource leaks
5. Tests          → happy path + authorisation + bad input covered, do tests actually verify something
6. Readability    → names, layer violations, file size
7. Style          → the linter's job; a human does not debate this
```

**[CI-12] MUST:** No style debates; formatting is `gofmt`/`golangci-lint`'s job.
Human time is spent on 1-6.

**[CI-13] SHOULD:** A comment states **what** should change and why, and preferably
suggests an alternative. Not "this is wrong", but "the `limit` bound isn't checked here;
`?limit=100000` can return the whole table, use `clampPagination`".

**[CI-14] MUST:** If you technically disagree with a review you received, **say so
before implementing it**. A suggestion applied without justification can turn into a
bug that the review itself failed to catch.

---

## 4. CI pipeline

**[CI-15] MUST — Steps that run on every PR (in order):**

```yaml
1. go mod download && go mod tidy    → FAIL if there is a diff after tidy (unused/missing dependency)
2. gofmt -l .                        → FAIL if output is non-empty
3. ./backend-standards/tools/check-standards.sh .   → no merge on FAIL
4. golangci-lint run                 → no merge on FAIL
5. go build ./...                    → no merge on FAIL
6. go test -race ./...               → no merge on FAIL
7. go test -tags=integration ./...   → against a real Postgres
8. govulncheck ./...                 → FAIL if there is a known vulnerability
9. docker build                      → does the image actually build
10. (recommended) image scan (Trivy) → FAIL on HIGH/CRITICAL
11. ./backend-standards/tools/check-secrets.sh .        → FAIL on a critical finding [CI-26]
12. go test -run=Fuzz -fuzz=Fuzz -fuzztime=30s ./...   → FAIL on a crash [CI-28]
13. ./backend-standards/tools/run-collection.sh <collection>  → FAIL if an assertion breaks [CI-27]
14. ./backend-standards/tools/version-advice.sh .     → report only, NEVER FAILs [VER-21]
```

Step 13 requires the service to be running; it runs against an environment brought up
with compose. Step 14 deliberately never fails; its output is written to the PR comment.

**[CI-26] MUST:** Secret scanning ([SEC-38]) runs on every PR and the pipeline breaks
on a critical finding. The tool does not fix anything; closing the finding is a human's job.

**[CI-27] MUST:** The Postman collection ([TEST-23]) runs in CI. A service without a
collection, or one whose collection has no assertions, cannot pass this step ([TEST-24]).

**[CI-28] MUST:** If a fuzz target exists, it runs in CI with `-fuzztime=30s` ([TEST-28]);
corpus inputs already run as ordinary tests in step 6.

**[CI-29] SHOULD:** The load test ([PERF-33]) does not run on every PR; it runs on the
**nightly run** and on PRs that touch performance. If a measurement hits the validity
gate, the result is not interpreted ([PERF-34]).
> **Why:** A load test takes minutes and by itself exceeds [CI-20]'s 10-minute pipeline
> target. Running it on every PR pushes the team toward disabling it.

**[CI-16] MUST:** No merge if CI is red. A red build merged with "I'll fix it later"
breaks everyone's build the next day.

**[CI-17] MUST:** CI runs with `-mod=readonly` ([VER-04]) so the pipeline never
silently pulls in a dependency.

**[CI-18] MUST:** For build reproducibility, the version and commit are embedded in
the binary ([OPS-01] `-ldflags`).

**[CI-19] MUST:** In CI, a secret comes **from CI's secret store**; it is not written
into the pipeline file and is not printed to logs.

**[CI-20] SHOULD:** The pipeline should stay **under 10 minutes**. A long pipeline
starts getting skipped and bypassed.

---

## 5. `.golangci.yml`

**[CI-24] MUST:** The service root's `.golangci.yml` is copied from
[tools/golangci.yml](tools/golangci.yml). In it, the standard's Go rules (forbidden
dependency, `gin.Default()`, `c.BindJSON`, `fmt.Print*`, `md5`, `math/rand`…) are
delegated to the linter via `forbidigo` and `depguard`.

**[CI-25] MUST:** Non-language rules (SQL, Dockerfile, compose, route authorisation,
money type) are checked with [tools/check-standards.sh](tools/check-standards.sh) and
run in CI. The tools' coverage and **limitations** are in [tools/README.md](tools/README.md).

### The block below is an abbreviated example of the full configuration

```yaml
version: "2"

linters:
  enable:
    - errcheck        # ignoring a returned error [GEN-19]
    - govet
    - staticcheck
    - ineffassign
    - unused
    - bodyclose       # HTTP response body not closed -> connection leak
    - rowserrcheck    # rows.Err() not checked -> silent missing data
    - sqlclosecheck   # rows/stmt not closed -> pool exhaustion [PERF-16]
    - contextcheck    # context not propagated [GEN-17]
    - noctx           # HTTP request without context
    - errorlint       # == comparison instead of errors.Is/As [API-22]
    - gosec           # common security mistakes
    - misspell

  settings:
    gosec:
      excludes:
        - G104        # overlaps with errcheck

  exclusions:
    rules:
      # Some checks produce unnecessary noise in tests.
      - path: _test\.go
        linters: [errcheck, gosec]
```

**[CI-21] MUST:** If a linter warning is to be silenced with `//nolint`, **a rationale
is written**: `//nolint:errcheck // error at close isn't meaningful, the process is
already terminating`. A `//nolint` without a rationale is rejected.

---

## 6. Versioning and tagging

**[CI-22] SHOULD:** Semantic versioning (`v1.4.2`) is used; every change merged into
`main` produces an image tag (`<service>:<commit-sha>`, [OPS-24]).

**[CI-23] MUST:** A record showing what changed is kept for every version that goes to
production (a CHANGELOG or release note). The question "what did we deploy yesterday"
is not answered by guessing.

---

## 7. NEVER DO THIS — git & CI

- ❌ Direct push to `main`
- ❌ Merge with red CI
- ❌ A PR over 400 lines that doesn't focus on a single topic
- ❌ Mixing formatting + refactor + feature into one commit
- ❌ Committing `.env` / a key / a secret
- ❌ `//nolint` without a rationale
- ❌ Approving without reading
- ❌ Skipping tests in CI, or removing `-race`
- ❌ Writing a secret into the pipeline file, or logging it
- ❌ An image that carries no version/commit information
- ❌ Both upgrading a dependency and adding a feature in the same PR
