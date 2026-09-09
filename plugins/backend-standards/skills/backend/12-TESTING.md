# 12 — Testing

> Tests are the **only** valid justification for saying "it works." Trying it once by hand
> is not proof; it does not stop you from making the same mistake a second time.

---

## 1. Test pyramid

```
        ▲  E2E (few)          real service + real DB, one critical flow
       ███ Integration        repository ↔ real Postgres (testcontainers)
     ██████ Unit/routing      with stubs, no DB, in milliseconds
```

**[TEST-01] MUST:** The majority of tests run **without a DB**. Because service and
repository are interfaces ([GEN-07]), writing a stub is easy.
> **Why:** If every test hits Postgres, the suite takes minutes; as it gets slower,
> developers stop running it, and writing the tests in the first place stops meaning
> anything.

**[TEST-02] MUST:** Tests are **independent of each other** and order-free. No test may
rely on data produced by another. A test that breaks when `t.Parallel()` is added is one
with a hidden dependency.

**[TEST-03] MUST:** Test names state what they verify:
`TestCreate_MissingLongitude_Returns400`, not `TestCreate2`.

---

## 2. `routes_test.go` — required in every service

**[TEST-04] MUST:** Every service has `internal/routes/routes_test.go`, verifying **at
least**:

| # | What is verified |
|---|---|
| 1 | **Routing:** is every endpoint defined (does it not return 404) |
| 2 | **Is `/health` reachable without auth**, is its shape `{"status":"healthy",...}` |
| 3 | **Do `api/v1` paths return 404** (the prefix is the gateway's job — [API-03]) |
| 3b | **Is the list endpoint at the resource root** (`GET /parkings`), does `/parkings/list` return 404 — [API-01b] |
| 4 | **Is bypassing the gateway rejected:** no header → 403, forged source → 403, wrong API key → 401 |
| 5 | **Is permission enforced:** POST with `view` → 403, POST with `create` → 201 |
| 6 | **Is the wildcard correct:** `module.*` works, superadmin `*` works |
| 7 | **No leakage between modules:** `a_module.*` against `b_module` endpoints → 403 |
| 8 | **Input validation:** empty name, invalid UUID, negative number, out-of-range value, excessively long text, invalid UTF-8 → all **400** |
| 9 | **A rejected request does NOT REACH the service** |
| 10 | **Partial update:** does a field not sent pass as `nil` to the service; does a field explicitly sent as `0` not collapse to `nil` |
| 11 | **Response contract:** is a list `data`+`meta`, does `meta.limit` match the returned record count |

**[TEST-05] MUST:** The test gives `routes.Setup` a **stub** handler/service and calls it
with `httptest.NewRecorder()` + `router.ServeHTTP(w, req)`. No DB is touched. Gin needs no
extra test helper; `net/http/httptest` is enough, one of the concrete benefits of being
built on `net/http`.

**[TEST-06] MUST:** The stub keeps a `reached bool`; this is how you verify "did a request
that should have been rejected reach the service layer" ([SEC-14]).

```go
type stubParkingService struct {
	reached  bool
	lastReq  *dto.ParkingUpdateRequest
	response *dto.Parking
	err      error
}

func (s *stubParkingService) Update(_ context.Context, _ string, req *dto.ParkingUpdateRequest) (*dto.Parking, error) {
	s.reached = true
	s.lastReq = req
	return s.response, s.err
}

func newTestRouter(svc service.ParkingService) *gin.Engine {
	// TestMode: gin's debug output must not pollute the test log.
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.ContextWithFallback = true
	routes.Setup(r, testConfig(), handler.NewParkingHandler(svc))
	return r
}

func authed(method, path, body, perms string) *http.Request {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	req.Header.Set("X-Gateway-Source", "api-gateway")
	req.Header.Set("X-API-Key", testAPIKey)
	req.Header.Set("X-User-Permissions", perms)
	return req
}

func TestCreate_WithOnlyViewPermission_Returns403AndDoesNotReachService(t *testing.T) {
	stub := &stubParkingService{}
	r := newTestRouter(stub)

	w := httptest.NewRecorder()
	r.ServeHTTP(w, authed(http.MethodPost, "/parkings", `{"name":"X"}`, "parking.view"))

	if w.Code != http.StatusForbidden {
		t.Fatalf("expected 403, got %d", w.Code)
	}
	// The real check that matters: an unauthorized request must NEVER reach the business layer.
	if stub.reached {
		t.Fatal("unauthorized request reached the service layer")
	}
}
```

---

## 3. What gets tested

**[TEST-07] MUST:** At least three tests per new endpoint: **happy path**, **permission
denial**, **bad input**.

**[TEST-08] MUST:** Boundary values are tested: empty, `nil`, `0`, negative, max + 1, very
long text, very large page, coordinate `(0,0)`, invalid UTF-8.
> Most bugs surface not in the middle but at the boundary.

**[TEST-09] MUST:** For every bug fixed, **write the test first** (red), then fix it
(green). A fix without a test does not stop the same bug from coming back six months
later.

**[TEST-10] MUST:** The "traps" in this standard each get a test:
- Three-state date type: is `UnmarshalJSON` called on an explicit `null` ([API-11])
- Does the returned record count match `meta.limit` ([API-18])
- Does a paginated query repeat or skip records across pages ([API-27])
- Are fields not sent in a partial update `nil` ([API-06])

**[TEST-11] SHOULD:** Use table-driven tests for complex pure logic:

```go
tests := []struct {
	name    string
	lat     float64
	lon     float64
	wantErr bool
}{
	{"valid", 41.19, 28.73, false},
	{"null island", 0, 0, true},
	{"latitude out of range", 91, 28.73, true},
	{"longitude out of range", 41.19, 181, true},
}
for _, tt := range tests {
	t.Run(tt.name, func(t *testing.T) { ... })
}
```

---

## 4. Integration testing

**[TEST-12] SHOULD:** The repository layer is tested against a **real Postgres**; a mock
DB is not used.
> **Why:** A mock DB verifies that the mock was written correctly, not that your SQL is
> correct. A wrong column name, a constraint violation, a type mismatch only surface
> against a real DB.

```go
//go:build integration

func TestParkingRepository_Create_DuplicateOriginalID_ReturnsConflict(t *testing.T) {
	ctx := context.Background()
	pg, err := postgres.Run(ctx, "postgis/postgis:18-3.6")   // testcontainers
	...
}
```

**[TEST-13] MUST:** Integration tests are separated by a build tag (`//go:build
integration`) and run with a separate command. They must not slow down the daily
development loop:
```bash
go test ./...                      # fast, no DB
go test -tags=integration ./...    # in CI and before merge
```

**[TEST-14] MUST:** Migrations are run inside the integration test — a broken migration
must be caught in CI, not in production.

---

## 5. Running and coverage

**[TEST-15] MUST:** CI runs `go test -race ./...`.
> **Why:** Race conditions cannot be caught any other way; most of the bugs hunted for
> months in production because they "happen sometimes" are exactly this.

**[TEST-16] MUST:** Test coverage is a **target, not a rule**. Critical paths
(permissions, validation, money/data integrity) should be **close to 100 %**; writing
tests for coverage of getters/setters is wasted time.
> Default floor: **70 %** for `internal/service` and `internal/handler`.

**[TEST-17] MUST NOT:** A weak test. A test that only checks "no error was returned" does
not break when the code changes and protects nothing. Verify the returned **value**.

**[TEST-18] MUST NOT:** A brittle test. An assertion tied to the exact text of an error
message breaks with the first text fix; verify the status code and the sentinel error
(`errors.Is`).

**[TEST-19] MUST NOT:** Silencing a constantly failing test with `t.Skip`. Either fix it
or delete it; a skipped test produces a false sense of security.

**[TEST-20] MUST:** Use a channel/`Eventually` pattern instead of waiting with
`time.Sleep` in a test. A test with a sleep is slow and breaks randomly (flaky) on a slow
machine.

---

## 6. End-to-end verification (before merge)

**[TEST-21] MUST:** For a new service/endpoint, the following are tried by hand once and
the result written into the PR:

```
□ Comes up with Compose, /health and /ready return 200
□ CRUD flow works THROUGH the gateway (not directly against the service)
□ Second POST with the same unique value          → 409
□ Text over the limit                              → 400
□ Missing required field (e.g. a single coordinate) → 400
□ Invalid UUID                                     → 400
□ Unauthorized user                                → 403
□ Direct call without the gateway header           → 403
□ ?limit=500 → returned record count matches meta.limit
□ After paging through all pages, total = total_items (no repeats/skips)
```

**[TEST-22] MUST:** Things that can silently fail, such as permissions/seeding, are
verified by **querying the data source**, not by **looking at logs**:
```sql
SELECT module, COUNT(*) FROM permissions WHERE module = 'parking' GROUP BY module;
```
> **Why:** A single SQL error in a seed file rolls back the whole file; the service logs a
> "seed warning" and continues starting up normally, and the missing permissions are only
> noticed once a user hits 403.

---

## 7. Postman collection — a living contract

Per `03`, the collection lives in every service. But the file existing does not make it
correct; a collection that is never run is not even documentation, because no one ever
finds out it is wrong.

**Measurement (2026-09-08, reference repo):** **27** of 47 services have a collection, so
20 services do not meet `03`'s requirement at all. Those 27 collections contain **423**
requests in total, but only **9** of them have any test script at all. In other words, two
thirds of the collections verify nothing even when they are run.

**[TEST-23] MUST:** The collection runs in CI via `tools/run-collection.sh` ([CI-27]). A
collection that does not run is a dead artefact, and the "in working order" item in `15`
cannot be signed off for it.
> **Why:** The collection is the API's executable contract. An endpoint path changes, the
> collection stays stale, and whoever opens it first (usually a frontend developer) fights
> a request that doesn't work. This also violates the standard's own principle
> ([TOOL-03]): anything that can be checked mechanically is not left to code review.

**[TEST-24] MUST:** Every request in the collection contains at least one assertion. At
minimum, the status code and the response envelope ([API-01]) are verified:

```js
// Postman "Tests" tab — every request carries at least this much.
pm.test("status 200", () => pm.response.to.have.status(200));
pm.test("envelope is correct", () => {
  const b = pm.response.json();
  pm.expect(b).to.have.property("data");      // list endpoints also have b.meta
});
```
> **Why:** A run without assertions only tells you "the server returned something." The
> measurement shows this is not a theoretical concern: two thirds of collections are in
> exactly this state today. An endpoint that returns a `null` body still shows green
> without an assertion.

**[TEST-25] MUST:** The collection runs through the gateway, not directly against the
service (same reasoning as [TEST-21]). The base URL comes from an environment variable; a
fixed `localhost:PORT` is not hardcoded into the collection.
> **Why:** A collection that hits the service directly skips the gateway's permission and
> normalization layer; a call that would return 403 in production returns 200 in the test.

---

## 8. Fuzzing — the automated form of boundary values

[TEST-08] counts boundary values **by hand**. Fuzzing is its automated form and has been
in the standard library since Go 1.18, so it does not violate [ADR-0011]'s "stdlib + stub
+ testcontainers" decision and brings no new dependency.

**[TEST-26] SHOULD:** Write a fuzz target for every function that parses external input.
Natural targets:

| Target | Why here |
|---|---|
| GeoJSON / coordinate parsing | Unclosed ring, reversed winding, Null Island, NaN, out-of-range latitude ([GIS-01]) |
| Three-state date `UnmarshalJSON` ([API-11]) | `null`, field absent, empty string, invalid format: all four must behave differently |
| Turkish text normalization ([TR-05]) | ı/İ, combined Unicode, zero-width characters |
| `clampPagination` ([STR-18]) | Negative, zero, `MaxInt`, overflow |
| Filter/sort parsing ([API-26]) | Column name outside the whitelist, an SQL fragment slipped in between |

```go
// internal/dto/date_fuzz_test.go
func FuzzThreeStateDate(f *testing.F) {
    // Seed corpus: the known three states + one invalid format.
    f.Add(`{"date":"2026-09-08T00:00:00Z"}`)
    f.Add(`{"date":null}`)
    f.Add(`{}`)
    f.Add(`{"date":"08.09.2026"}`)

    f.Fuzz(func(t *testing.T, body string) {
        var d UpdateRequest
        // The only expectation: DO NOT PANIC. Returning an error is a valid outcome.
        _ = json.Unmarshal([]byte(body), &d)
    })
}
```

**[TEST-27] MUST:** If fuzzing is used, every crashing input it finds is committed under
`testdata/fuzz/`. That file is now a permanent regression test.
> **Why:** Fuzzing is random; there is no guarantee it finds the same crash a second time.
> A finding that doesn't make it into the corpus counts as never found.

**[TEST-28] MUST:** In CI, fuzzing runs for a **bounded time** (`-fuzztime=30s`), not
unbounded. The inputs already in the corpus already run as normal tests on every `go test`
run.
> **Why:** Unbounded fuzzing keeps CI busy forever. Thirty seconds is not much for finding
> new inputs, but it isn't needed to catch a regression, the corpus does that. Deep search
> is left to an overnight run.

---

## 9. NEVER DO THIS — testing

- ❌ Saying "it works" without writing a test
- ❌ Wiring every test to a real DB
- ❌ Testing the repository with a mock DB
- ❌ A test that only checks "no error was returned"
- ❌ An assertion tied to error message text
- ❌ Order/data dependency between tests
- ❌ Silencing a broken test with `t.Skip`
- ❌ Synchronizing with `time.Sleep`
- ❌ Testing only the happy path
- ❌ Closing out a fixed bug without a test
- ❌ Mistaking a coverage percentage for test quality
- ❌ Verifying seed/permission loading by looking at logs
- ❌ Counting a Postman collection with no assertions as "working"
- ❌ Fixing a crash fuzzing found without adding it to the corpus
