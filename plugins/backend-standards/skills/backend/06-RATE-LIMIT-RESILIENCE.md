# 06 — Rate Limit and Resilience

> The numbers in this file are **defaults and are binding.** If you change one, base it on
> measurement and write the reasoning in a code comment or the PR. A sentence like "there
> should be a rate limit" cannot be audited; a number can.

---

## 1. Rate limit layers

Limits are applied **at the gateway**. Services do not implement their own general rate
limiting.

**[RES-01] MUST — Default limits (gateway):**

| Who | Limit | Window | Rationale |
|---|---|---|---|
| Anonymous (per IP) | **100 requests** | 1 min | Stops simple scanning/scraping without affecting normal users |
| Authenticated user | **1,000 requests** | 1 min | Even a heavy dashboard fires ~50-100 requests on load; leaves 10x headroom |
| Login / password reset | **5 requests** | 15 min | Brute force. Counted separately by IP **and** by account |
| Write endpoints (POST/PUT/DELETE) | **60 requests** | 1 min | Brakes a client that has accidentally entered a loop |
| Heavy endpoints (export, report, bulk query) | **10 requests** | 1 min | A single request can take seconds; unprotected, it drains the DB |
| Service to service (internal network) | **no limit** | — | Internal traffic is trusted; a limit here only amplifies a cascading failure |

**[RES-02] MUST:** A 429 response carries a `Retry-After` header. If the client doesn't
know when to retry, it retries immediately and makes things worse.

**[RES-03] MUST:** For an authenticated user, the limit key is the **user id**, not the
IP. A 200-person office behind NAT comes from a single IP; an IP-based limit cuts off all
of them at once.

**[RES-04] MUST:** In a multi-instance (replica) deployment, the limit counter is kept
**in Redis**. An in-memory counter silently multiplies the limit by 3 with 3 replicas.

```go
// Gin has no built-in rate limiter and there is no well-maintained community package
// either (ulule/limiter was last updated in 2023). A Redis-backed fixed window is ~40 lines:
func RateLimit(rdb *redis.Client, max int64, window time.Duration) gin.HandlerFunc {
	return func(c *gin.Context) {
		// Count an authenticated user by their own key; a 200-person office behind NAT
		// comes from one IP, so IP-based counting would cut all of them off at once [RES-03].
		key := "rl:ip:" + c.ClientIP()
		if uid := c.GetHeader("X-User-ID"); uid != "" {
			key = "rl:u:" + uid
		}

		ctx, cancel := context.WithTimeout(c.Request.Context(), 500*time.Millisecond)
		defer cancel()

		n, err := rdb.Incr(ctx, key).Result()
		if err != nil {
			// Rate limiting is a CORRECTNESS mechanism, not a cache: it does not fail
			// open if Redis is down [CACHE-10]. If we can't count, we don't accept the request.
			pkg.Log.Error("could not read rate limit counter", "err", err)
			c.AbortWithStatusJSON(http.StatusServiceUnavailable,
				pkg.ErrorBody("service temporarily unavailable"))
			return
		}
		if n == 1 {
			// TTL is set only on the first increment; setting it every request means the window never expires.
			rdb.Expire(ctx, key, window)
		}
		if n > max {
			c.Header("Retry-After", strconv.Itoa(int(window.Seconds())))
			c.AbortWithStatusJSON(http.StatusTooManyRequests,
				pkg.ErrorBody("too many requests, please wait"))
			return
		}
		c.Next()
	}
}
```

> **Note:** this is a fixed-window implementation, and at the window boundary it allows up
> to 2x the limit in the worst case. That is enough for our purpose (braking abuse); move
> to a sliding-window log if exact accuracy is required.

**[RES-05] MUST — Body size limit: 4 MB.** Gin has no configuration field for this; it is
added as global middleware using stdlib:
```go
func BodyLimit(max int64) gin.HandlerFunc {
	return func(c *gin.Context) {
		// MaxBytesReader cuts reading short with an error once the body exceeds the
		// limit; reading an unbounded body is the easiest way to exhaust memory with one request.
		c.Request.Body = http.MaxBytesReader(c.Writer, c.Request.Body, max)
		c.Next()
	}
}
// r.Use(middleware.BodyLimit(4 << 20))
```
If there is a file upload endpoint, it is raised separately and **explicitly** for that
endpoint only; the general limit is not raised.

**[RES-06] MUST:** Every size the client can set is bounded: page `limit` ≤ 200
([API-18]), bulk operation body ≤ 1,000 records, search query ≤ 256 characters.
> **Why:** an unbounded parameter is a DoS vector, and it gets triggered without an
> attacker too, just by a single misconfigured client.

---

## 2. Timeout matrix

**[RES-07] MUST:** Every network call has a timeout. Defaults:

| Where | Setting | Value | Rationale |
|---|---|---|---|
| HTTP server | `ReadHeaderTimeout` | **5s** | First line of defense against Slowloris |
| HTTP server | `ReadTimeout` | **15s** | Time to read the whole request, body included |
| HTTP server | `WriteTimeout` | **30s** | Clearly above the longest normal response |
| HTTP server | `IdleTimeout` | **60s** | A keep-alive connection must not sit idle forever |
| HTTP client (upstream) | `Timeout` | **5s** | The user is waiting; anything past 5s already counts as a failure |
| DB query (read) | context | **3s** | Longer than this and the query or index is wrong |
| DB query (write) | context | **5s** | |
| DB connection setup | context | **5s** | |
| Redis | context | **500ms** | A cache that is slow stops being a cache; skip it and go to the DB |
| Graceful shutdown | — | **20s** | Enough to finish open requests, without blocking the deploy |

> Server timeouts are set on the `http.Server` struct, not in Gin
> ([03](03-PROJECT-STRUCTURE.md) §4). Gin is only the `Handler`; that is a good thing,
> since these settings stay in stdlib's well-known place.

**[RES-08] MUST NOT:** `http.Client{}` without a timeout. Its default is **infinite**, and
when an upstream hangs it silently drains the entire goroutine pool.

```go
// REQUIRED: a shared, timeout-bound, pooled client. Do NOT create a new client per
// request — each one opens its own connection pool and TIME_WAIT sockets pile up.
var httpClient = &http.Client{
	Timeout: 5 * time.Second,
	Transport: &http.Transport{
		MaxIdleConns:        100,
		MaxIdleConnsPerHost: 10,
		IdleConnTimeout:     90 * time.Second,
	},
}
```

**[RES-09] MUST:** Timeouts **decrease going down the stack**. If the gateway waits 10s,
the service should wait 5s, and the DB query 3s. If a lower layer waits longer than the
layer above it, the upper layer has already given up while the work continues for nothing.

**[RES-10] MUST:** `context` is carried end to end ([GEN-17]). In Gin the source is
`c.Request.Context()` ([STR-10]):
```go
ctx, cancel := context.WithTimeout(c.Request.Context(), 3*time.Second)
defer cancel()
rows, err := r.pool.Query(ctx, sql, args...)
```
> If `r.ContextWithFallback = true` is set, `c` also behaves like a `context.Context`
> ([STR-14]); even so, `c.Request.Context()` is what gets passed down, not `c`.

---

## 3. Retry and backoff

**[RES-11] MUST:** Only **transient** errors are retried: connection error, timeout,
502/503/504, `429` (honoring Retry-After). `400`, `401`, `403`, `404`, `409` are **not
retried** — retrying produces the same answer and only adds load.

**[RES-12] MUST:** Retry is done **only for idempotent** operations. If a `POST` is going
to be retried, it must be protected with an `Idempotency-Key` ([API-25]).

**[RES-13] MUST:** At most **3** retries, with exponential backoff plus jitter:

```go
// Jitter is REQUIRED: with fixed backoff, every client wakes up at the same instant
// and knocks the upstream down again just as it's recovering (thundering herd).
func retryDelay(attempt int) time.Duration {
	base := time.Duration(1<<attempt) * 100 * time.Millisecond // 100ms, 200ms, 400ms
	jitter := time.Duration(rand.Int63n(int64(base / 2)))
	return base + jitter
}
```

**[RES-14] MUST NOT:** Layered retry. If the gateway retries 3 times, the service 3 times,
and the client 3 times, the upstream gets **27 requests**. Retry happens **in a single
layer** only, preferably the outermost one in the call chain.

---

## 4. Circuit breaker

**[RES-15] SHOULD:** If calls to an upstream keep failing, the circuit opens and no calls
are attempted for a while.

```
closed  →  N consecutive failures (default 5)  →  open
open    →  no attempts, immediate 503          →  after 30s  →  half-open
half-open → closed if the single trial succeeds, open again otherwise
```

**[RES-16] MUST:** While the circuit is open, **503** is returned with `Retry-After`; the
request is not queued and held.
> **Why:** waiting on an upstream that isn't responding piles up goroutines and
> connections in the calling service. Its failure becomes your failure within seconds
> (cascading failure). Failing fast is better than failing slowly.

**[RES-17] MUST:** When one dependency goes down, the service does not go down
**entirely**; endpoints that don't need that dependency keep working. Example: if Redis is
down, skip the cache and go to the DB — but this applies **only to caching**, never to
permission checks ([SEC-08]).

---

## 5. Panic, shutdown, health

**[RES-18] MUST:** A `recover` middleware is first in line in every service:

```go
// We add Recovery EXPLICITLY because gin.New() is used [STR-13].
r.Use(gin.CustomRecoveryWithWriter(nil, func(c *gin.Context, recovered any) {
	// The stack trace goes to the log, NEVER to the client [SEC-28].
	pkg.Log.Error("panic recovered",
		"panic", recovered, "path", c.FullPath(), "stack", string(debug.Stack()))
	c.AbortWithStatusJSON(http.StatusInternalServerError,
		pkg.ErrorBody("the operation could not be completed"))
}))
```
> Plain `gin.Recovery()` is also acceptable, but it prints the panic text to stdout as
> plain text, which doesn't match our structured-logging standard ([OBS-01]).

**[RES-19] MUST:** Graceful shutdown (as in the [03](03-PROJECT-STRUCTURE.md) §4 example):
on SIGTERM, new requests stop being accepted, open requests are given up to 20s to finish,
then dependencies are closed.
> **Why:** if the container is killed hard during a deploy, an in-flight request returns
> 502 to the client, and a write may be left half-done.

**[RES-20] MUST:** Shutdown order: **first** stop accepting new requests → **then** let
open requests finish → **last** close DB/Redis/Kafka connections. In practice:
`pool.Close()` **after** `srv.Shutdown(ctx)` returns. The reverse order causes requests
that are still running to get a "connection closed" error.

**[RES-21] MUST:** No goroutine leaks. Every goroutine you start must have an exit
condition: either it listens on `ctx.Done()` or it is waited on with a `WaitGroup`. An
infinite `for {}` loop contains a `select { case <-ctx.Done(): return ... }`.

**[RES-22] MUST:** Spawning unbounded goroutines is forbidden. A fan-out that opens a
goroutine per request is bounded with `errgroup.SetLimit` or a worker pool.

---

## 6. Backpressure and overload

**[RES-23] MUST:** The DB connection pool is bounded ([DB-01], [DB-03]). When the pool is
full, a request waits **in the queue up to the context timeout**; it does not wait
forever.

**[RES-24] MUST:** In queue/worker systems, if the consumer is slower than the producer
the queue grows. Queue depth is a metric ([OBS-12]) and fires an alert once a threshold is
crossed.

**[RES-25] SHOULD:** Under overload, **shed load**: once a threshold is crossed, return a
cheap `503`. Rejecting some requests quickly is better than slowly disappointing everyone.

**[RES-26] MUST:** If a request has already been cancelled (`ctx.Err() != nil`), don't
continue the work. Check at the start of long loops:
```go
for _, item := range items {
	if err := ctx.Err(); err != nil {
		return err   // client is gone, don't work for nothing
	}
	...
}
```

---

## 7. Health endpoints

**[RES-27] MUST:** There are two separate endpoints and **both are unauthenticated**:

| Endpoint | Meaning | Checks dependencies |
|---|---|---|
| `/health` (liveness) | "The process is up" | **No** |
| `/ready` (readiness) | "I can take requests" | **Yes** — DB ping etc. |

```go
func Health(c *gin.Context) {
	// Does NOT check dependencies: if the DB is down, the orchestrator must not
	// restart the container — restarting doesn't fix the DB, it only makes things worse.
	c.JSON(http.StatusOK, gin.H{"status": "healthy", "service": serviceName})
}

func Ready(pool *pgxpool.Pool) gin.HandlerFunc {
	return func(c *gin.Context) {
		ctx, cancel := context.WithTimeout(c.Request.Context(), 2*time.Second)
		defer cancel()
		if err := pool.Ping(ctx); err != nil {
			c.JSON(http.StatusServiceUnavailable,
				gin.H{"status": "unready", "reason": "database"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "ready"})
	}
}
```

**[RES-28] MUST:** The `/health` response shape is identical across all services:
`{"status": "healthy", "service": "<service-name>"}`. Not `ok`, `up`, `alive` — **`healthy`**.

**[RES-29] MUST NOT:** Checking dependencies inside `/health`.
> **Why:** if the DB fails to respond briefly, liveness fails, the orchestrator restarts
> every replica, caches empty out, and the DB takes a sudden spike in load: a
> self-amplifying failure.

---

## 8. NEVER DO THIS — resilience

- ❌ `http.Server{}` or `http.Client{}` without a timeout
- ❌ A call chain that does not pass `context`
- ❌ A service without a `recover` middleware
- ❌ `ListenAndServe` without graceful shutdown
- ❌ Layered retry (3x3x3 = 27 requests)
- ❌ Fixed backoff without jitter
- ❌ Retrying a non-idempotent operation
- ❌ Retrying permanent errors like `400`/`404`
- ❌ Using an in-memory rate limit counter in a multi-replica deployment
- ❌ Unbounded goroutines / a goroutine with no exit condition
- ❌ A DB check inside `/health`
- ❌ An unbounded client-supplied `limit`, body, or batch size
- ❌ Swallowing errors (`if err != nil { }`)
