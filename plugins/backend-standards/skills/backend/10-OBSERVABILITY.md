# 10 — Observability

> Three pillars: **log** (what happened), **metric** (how much/how often), **trace**
> (where time went).
> Without all three, you end up guessing at a production problem; a guess is not a fix.

---

## 1. Logging

**[OBS-01] MUST:** Logs are written **structurally (JSON)** with `log/slog`.
`fmt.Println`, `log.Printf` and free-text logging are forbidden.
> **Why:** Plain-text logs are not searchable. "Show yesterday's 500s for this user"
> can only be answered by a log with fields.

```go
package pkg

var Log *slog.Logger

func InitLogger(level, service, version string) *slog.Logger {
	var lv slog.Level
	if err := lv.UnmarshalText([]byte(level)); err != nil {
		lv = slog.LevelInfo
	}
	h := slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{
		Level: lv,
		// Source location only in debug: computing file/line on every line is costly.
		AddSource: lv == slog.LevelDebug,
	})
	Log = slog.New(h).With(
		slog.String("service", service),
		slog.String("version", version),
	)
	slog.SetDefault(Log)
	return Log
}
```

**[OBS-02] MUST:** Logs are written to **stdout**, not to a file. Collection is the
job of the container runtime and the log collector.
> **Why:** A container that writes to a file fills up its disk, creates rotation
> problems, and loses its logs the moment the container dies.

**[OBS-03] MUST:** The level is set via env (`LOG_LEVEL`), and is **`info`** in
production.

| Level | When |
|---|---|
| `Debug` | Development/diagnostics. Off in production, enabled when needed |
| `Info` | Normal business events: service started, job completed |
| `Warn` | Unexpected but handled situation: cache read failed, retry performed |
| `Error` | An operation failed, intervention may be needed |

> **There is no `Fatal`.** The decision to shut down belongs to `main`; a library or
> handler never kills the process.

**[OBS-04] MUST:** Every log line must contain:

| Field | Why |
|---|---|
| `time`, `level`, `msg` | Added automatically by slog |
| `service`, `version` | Which service, which version |
| `request_id` | Ties together all lines from the same request |
| `user_id` (if present) | Per-user diagnostics |
| `err` (on error) | The **full** error |

```go
// A request id is generated/propagated on every request and placed in the context.
import "github.com/gin-contrib/requestid"

r.Use(requestid.New())

// In the handler:
log := pkg.Log.With("request_id", requestid.Get(c))
log.Info("parking updated", "parking_id", id)
```

**[OBS-05] MUST:** An incoming `X-Request-ID` header is **preserved** if present,
otherwise generated, and returned in the response. Overwriting the upstream system's
id makes it impossible to correlate the two systems' logs.

**[OBS-06] MUST:** The log message is **constant**, variables are **fields**:
```go
// WRONG: every message is unique, cannot be grouped, no alert can be built on it
Log.Error(fmt.Sprintf("query failed for user %s: %v", id, err))
// RIGHT
Log.Error("user query failed", "user_id", id, "err", err)
```

**[OBS-07] MUST:** Logging is subject to the security section: no password, token, or
personal data is logged ([SEC-25]); config is not printed with `%+v` ([SEC-26]); the
error log is full while the error response is masked ([SEC-28]).

**[OBS-08] MUST:** The access log (one line per request) is produced at the gateway;
it is not additionally produced in each service.
> **Why:** Otherwise the same request is logged 2-3 times, disk and cost multiply,
> and counts become wrong.

---

## 2. Metrics

**[OBS-09] MUST:** Every service exposes metrics in Prometheus format on `/metrics`.
This endpoint is **never exposed externally**; it is reachable only from the internal
network.

**[OBS-10] MUST — Metrics required in every service (RED):**

| Metric | Type | Labels |
|---|---|---|
| `http_requests_total` | counter | `method`, `route`, `status` |
| `http_request_duration_seconds` | histogram | `method`, `route` |
| `http_requests_in_flight` | gauge | — |
| `db_query_duration_seconds` | histogram | `operation` |
| `db_pool_connections` | gauge | `state` (idle/used) |
| `cache_operations_total` | counter | `result` (hit/miss/error) |

**[OBS-11] MUST:** Label values come from a **bounded set**. The `route` label is the
**route template** (`/parkings/:id`), not the actual path.
> **Why:** Every UUID creates a separate time series. 100,000 records = 100,000
> series = Prometheus falling over. This is called "cardinality explosion" and is
> hard to reverse. For the same reason, `user_id`, `email`, and `ip` are **never**
> labels; they belong in the **log** as fields.

**[OBS-12] MUST:** Business metrics are also defined: `orders_created_total`,
`import_records_failed_total`, and similar. Technical metrics answer "is the system
up," business metrics answer "is the system doing the right thing." Without the
latter, silent breakage goes unnoticed.

**[OBS-13] MUST:** Authorisation denials ([SEC-09]), rate limit triggers, and retry
counts are metrics. Sudden spikes should generate an alert.

---

## 3. Trace

**[OBS-14] SHOULD:** For flows that chain through three or more services, distributed
tracing is set up with OpenTelemetry.
> **Why:** "The request took 4 seconds" is useless on its own. A trace shows which
> service and which call the time went into; without it, every team blames another.

**[OBS-15] MUST:** The trace context (`traceparent`) is **propagated** between
services. The gateway starts it, each service picks it up and forwards it to its
upstream calls. If one link in the chain fails to propagate it, the trace breaks
there.

**[OBS-16] MUST:** `request_id` and `trace_id` are **linked** to each other; both
appear in the log line. This lets you move from trace to log and from log to trace.

**[OBS-17] SHOULD:** Sampling is used in production (1-10 %), but **failed requests
are always** sampled. The trace you need most is the one for the failure.

---

## 4. Health and readiness

**[OBS-18] MUST:** The `/health` and `/ready` endpoints follow the contract in
[06-RATE-LIMIT-RESILIENCE.md](06-RATE-LIMIT-RESILIENCE.md) §7. `/health` does not
check dependencies ([RES-29]).

**[OBS-19] SHOULD:** The `/version` endpoint returns build info: commit sha, build
time, Go version. It answers "what code is running in production" without guessing.

---

## 5. Alerts

**[OBS-20] MUST:** Alerts are built on **symptoms** (what the user is experiencing),
not on causes. A "CPU 90 %" alert wakes someone up at night even though users may not
be affected at all.

**[OBS-21] MUST — Default alert thresholds:**

| Alert | Threshold | Duration | Urgency |
|---|---|---|---|
| 5xx rate | > 1 % | 5 min | Urgent |
| p95 latency | > 2 × target | 10 min | Urgent |
| `/ready` failing | any replica | 2 min | Urgent |
| DB pool saturation | > 80 % | 10 min | Warning |
| OOM-kill / restart | > 2 times | 15 min | Warning |
| Queue depth | rising trend | 15 min | Warning |
| Disk usage | > 80 % | — | Warning |
| Cache hit rate | < 50 % | 30 min | Info |
| Certificate expiry | < 14 days | — | Warning |

**[OBS-22] MUST:** Every alert has an **owner** and a **runbook**: what are the first
three steps when it fires? An alert without a runbook means panic at 3 a.m.

**[OBS-23] MUST:** A false positive alert is fixed or removed.
> **Why:** An alert that keeps firing starts being ignored, and the real alert gets
> ignored along with it that day. A noisy alert is more dangerous than no alert.

---

## 6. What is logged, what is not

**Logged:**
- Service start/stop, version, which config profile
- Business events: record created/updated/deleted (with id)
- All `Error` and `Warn` cases, with the full error chain (wrapped with `%w`)
- Authorisation denial, rate limit, validation rejection (with reason)
- External system calls: target, duration, result code

**Not logged:**
- Secrets, tokens, passwords, personal data ([SEC-25])
- A separate service log per request (the gateway already writes one — [OBS-08])
- Successful `GET` bodies
- Line-by-line progress inside a loop (use a counter metric instead)
- Development leftovers like "got here", "here"

---

## 7. NEVER DO THIS — observability

- ❌ Logging with `fmt.Println` / `log.Printf`
- ❌ Plain-text (unstructured) logging
- ❌ Writing logs to a file
- ❌ Embedding variables inside the message (cannot be grouped)
- ❌ Making `user_id` / `email` / `ip` / a UUID a metric **label**
- ❌ Making the actual path (`/parkings/9f3c...`) the route label
- ❌ Logging secrets or personal data
- ❌ Failing to propagate the trace context upstream
- ❌ Setting up an alert without a runbook
- ❌ Ignoring a persistently firing false alert
- ❌ Exposing `/metrics` and `/debug/pprof` externally
- ❌ Declaring "the system is healthy" without a business metric
