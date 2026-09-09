# 09 — Performance and Cost

> Two principles: **Do not optimise without measuring. Do not call it "fast" without
> measuring, either.**
> The targets in this file are binding; if they are not met, either the code gets
> fixed or the target changes with a stated reason — it is never silently ignored.

---

## 1. Targets (SLO)

**[PERF-01] MUST — default targets:**

| Metric | Target | Why this |
|---|---|---|
| Simple read (single record) p95 | **< 100ms** | The user perceives it as instant |
| List/page p95 | **< 200ms** | Anything past 200ms "feels" slow for a list |
| Write p95 | **< 300ms** | Includes the cost of validation + the transaction |
| Heavy report/export p95 | **< 3s** | Above this it must be asynchronous ([ASYNC-02]) |
| Error rate (5xx) | **< 0.1%** | More than 1 internal error in 1,000 requests is unacceptable |
| Availability | **99.9%** | About 43 minutes of downtime budget per month |

**[PERF-02] MUST:** Measurement is done via **p95/p99, not p50**. An average hides the
worst experience; the user lives their own request, not the average.

**[PERF-03] MUST:** Targets are tracked with metrics ([OBS-10]) and trigger an alert
when exceeded. An untracked target is not a target.

---

## 2. Resource budget

**[PERF-04] MUST — default container limits per service:**

| Resource | Reservation (request) | Limit | Note |
|---|---|---|---|
| RAM | 128 MB | **256 MB** | A typical Go CRUD service uses 30-80 MB |
| CPU | 0.1 | **0.5** | |
| DB connections | — | **10** | `MaxConns` ([DB-01]) |

Heavy services (tiles, export, image processing) get their own limit, and it is
**written into the compose file with a reason**.

**[PERF-05] MUST:** Every container has a memory limit.
> **Why:** an unlimited container consumes all of the host's memory in the event of a
> leak and **kills every other service** on the host. A limited container only kills
> itself and restarts.

**[PERF-06] MUST:** With Go 1.19+, `GOMEMLIMIT` is set to **80%** of the container
limit:
```yaml
environment:
  GOMEMLIMIT: 200MiB      # limit is 256 MB
  GOGC: 100
```
> **Why:** Go's GC does not know the container limit by default; it delays collection
> without regard to the limit and can get OOM-killed. `GOMEMLIMIT` makes the GC
> compact before it reaches the limit.

**[PERF-07] MUST:** OOM-kill and restart counts are monitored. "The service recovers
on its own" is not a fix, it is a hidden error.

---

## 3. Payload and network

**[PERF-08] MUST:** The response body does not carry unnecessary data. A list endpoint
does not have to return every field of the detail endpoint.

**[PERF-09] MUST:** The same information is never present **twice** in a response.
> **Case in point:** in GeoJSON responses, the location existed both in `geometry` and
> in `properties.latitude/longitude`. The payload bloated and the two sources drifted
> apart over time.

**[PERF-10] MUST:** gzip/br compression is enabled at the gateway. It gives a 70-90%
gain on JSON; this is the cheapest performance improvement there is.

**[PERF-11] SHOULD:** Provide `ETag` / `If-None-Match` support on resources that do not
change; a 304 response carries no body.

**[PERF-12] MUST:** The page size upper bound is 200 ([API-18]). There is no "get
everything" endpoint; if bulk data is needed, the export endpoint runs asynchronously.

---

## 4. Cost on the Go side

**[PERF-13] MUST:** Allocations are reduced on the hot path (code that runs on every
request):
- A slice/map of known length is pre-allocated with `make([]T, 0, n)`.
- String concatenation in a loop uses `strings.Builder`, not `+`.
- `sync.Pool` is considered for reused large buffers (**after measuring**).

**[PERF-14] MUST:** Shared clients (HTTP, DB, Redis) are created **once** and reused.
Creating a new `http.Client` per request neutralises the connection pool.

**[PERF-15] MUST:** Do not use `defer` inside a loop at a known scale:
```go
// WRONG: defer accumulates until the function returns, 10,000 open resources for 10,000 rows
for _, f := range files { fh, _ := os.Open(f); defer fh.Close() }

// RIGHT: scope it to a function
for _, f := range files {
	func() { fh, _ := os.Open(f); defer fh.Close(); process(fh) }()
}
```

**[PERF-16] MUST:** Do not skip `rows.Close()` and resource release via `defer`. In
`pgx`, if `rows` is not closed the connection does not return to the pool, and the
pool silently runs dry.

**[PERF-17] MUST NOT:** Premature optimisation. Any optimisation that hurts
readability is justified by a **measurement output**, and the reason is written into a
code comment:
```go
// pprof: this loop was 38% of total CPU (PR #211). Pre-allocation brought it down to 6%.
buf := make([]byte, 0, 4096)
```

---

## 5. Profiling — how to measure

**[PERF-18] MUST:** A slowness complaint is resolved by profiling, not by **guessing**.
The order:

```
1. Look at the metrics  → which endpoint, what time, how slow? [OBS-10]
2. Look at the trace     → where is the time going: DB, upstream, or our own code?
3. If it's the DB        → EXPLAIN (ANALYZE, BUFFERS), the slow query log [DB-27]
4. If it's our own code  → pprof (CPU + heap)
5. Fix it, MEASURE AGAIN → revert the change if it did not improve things
```

**[PERF-19] SHOULD:** `net/http/pprof` is only exposed on the **internal network** and
a separate port, never through the gateway to the outside.
> **Why:** pprof endpoints expose memory contents and goroutine stacks; taking a
> profile also consumes CPU — it is a DoS vector if it can be triggered from outside.

**[PERF-20] SHOULD:** Write benchmarks for critical paths and measure regressions:
```bash
go test -bench=. -benchmem -count=5 ./internal/service/...
```

**[PERF-21] MUST:** Do not claim "it can handle this many requests" without a load
test. A simple `k6`/`vegeta` scenario is enough; it is far better than not measuring at
all.

---

## 6. Cost

**[PERF-22] MUST:** The cheapest work is **work not done**. In order:
1. Do not make the request at all (cache, ETag, remove unnecessary polling)
2. Move less data (field selection, pagination, compression)
3. Make fewer queries (remove N+1, batch)
4. Only then scale up hardware

**[PERF-23] MUST:** Event/webhook is preferred over polling. 100 clients polling every
5 seconds produce 1.7 million idle requests a day.

**[PERF-24] SHOULD:** Heavy and infrequent jobs (reports, exports, bulk import) are put
on an async queue ([11-ASYNC-KAFKA-TEMPORAL.md](11-ASYNC-KAFKA-TEMPORAL.md)); they do
not tie up the API process, and they do not dictate how the API scales.

**[PERF-25] MUST:** Log level in production is `info`. `debug` logging costs disk,
CPU, and money; it is turned on via env only when needed ([OBS-03]).

**[PERF-26] MUST:** Log and metric retention periods are defined (e.g. logs 14 days,
metrics 90 days). Unbounded retention eventually becomes the single largest
infrastructure cost.

**[PERF-27] SHOULD:** Keep the Docker image small (multi-stage + alpine, ~20 MB). A
small image means faster deploys, faster scaling, lower registry cost, and a smaller
attack surface.

**[PERF-28] SHOULD:** Turn off what is unused. A dead service, an unused index, an
idle replica, a dashboard nobody looks at — all of these cost money. Review every
quarter.

---

## 7. Scaling

**[PERF-29] MUST:** Services are **stateless**. Sessions, counters, temporary files are
not kept in process memory; they are kept in Redis/DB/the object store.
> **Why:** a service holding state in memory cannot scale horizontally — a second
> replica does not see the first one's data, and the failure shows up as "it happens
> sometimes."

**[PERF-30] MUST:** Scale **vertically first, then horizontally**. If a single service
is maxing out 256 MB, look for a leak or unnecessary allocation first; adding replicas
just hides the problem and multiplies the cost.

**[PERF-31] MUST:** In horizontal scaling, the DB is not scaled just **once** — 10
replicas × 10 connections = 100 connections ([DB-03]). Horizontal scaling without
PgBouncer brings the DB down.

---

## 8. Load testing and measurement validity

[PERF-01] sets the targets, and [PERF-02] says they are judged over p95/p99. But there
was no step that **verified** the target: [PERF-21] recommended a load test in a single
sentence, with nothing actually running one. This section closes that gap.

**[PERF-32] MUST:** Running the Postman collection ([TEST-23]) is **not** a load test
and does not make an SLO decision. `tools/run-collection.sh` reports durations, but it
does not compute p95 and does not say "target met."
> **Why:** p95 cannot be computed from three samples per endpoint; presenting it as if
> it were computed violates [PERF-02]. The collection run's job is correctness and a
> rough sense of duration. Reading "green" out of three samples manufactures a
> guarantee that does not exist.

**[PERF-33] MUST:** A new service, and any change that affects performance, is
measured with `tools/load-test.sh` and the result is compared against the [PERF-01]
targets ([CI-29]). Threshold by endpoint class:

| Class | p95 target |
|---|---|
| Single-record read | < 100ms |
| List | < 200ms |
| Write | < 300ms |
| Heavy report / export | < 3s |
| 5xx rate | < 0.1% |

> **Why:** "it feels fast" is not a measurement. The target was already written down;
> without a step that checks it regularly, the target stays a statement of good
> intentions.

**[PERF-34] MUST:** A measurement passes through a **validity gate** before it is
interpreted. Under the following conditions the tool says "this measurement cannot be
interpreted" and **does not** render a pass/fail verdict:

| Gate | Why |
|---|---|
| Total requests < 100 | p95 is not statistically meaningful |
| Duration < 10s | Warm-up effect dominates; not JIT, but the connection pool and cache have not filled |
| Error rate > 50% | What is being measured is the error path, not the service |
| p95 / p50 > 10 | The environment is noisy or the queue is saturated; the number does not describe the service |
| All responses take the same duration | Suspicious: a cache or a fake response is likely what's being measured |
| Target is `localhost` and VU > 50 | The client is saturating its own machine and corrupting its own measurement |

> **Why:** a decision made from an invalid measurement is **worse** than not measuring
> at all: it manufactures false confidence and kills the motivation to look for the
> real problem. A tool has to be able to say "I don't know."

**[PERF-35] MUST:** A load test result is interpreted **not as an absolute number, but
by comparison with a previous run in the same environment.** The measurement depends on
the machine, the network, and the load at that moment.
> **Why:** an endpoint measured at 80ms on a laptop can give 300ms on a shared runner;
> both are correct, and neither says anything on its own. The meaning is in the
> difference: if something that was 90ms yesterday in the same environment is 240ms
> today, that is worth looking at.

---

## 9. NEVER DO THIS — performance

- ❌ Optimising without measuring
- ❌ Calling something "fast/slow" without measuring
- ❌ A container with no memory limit
- ❌ Setting a tight memory limit without setting `GOMEMLIMIT`
- ❌ An unpaginated / unbounded list endpoint
- ❌ Carrying the same data twice in a response
- ❌ Creating a new `http.Client` per request
- ❌ Skipping resource release via `rows.Close()` / `defer`
- ❌ `defer` accumulating inside a loop
- ❌ Exposing pprof externally
- ❌ `debug` log level in production
- ❌ Holding state in process memory while scaling horizontally
- ❌ An "improvement" commit with no stated reason and no measurement
