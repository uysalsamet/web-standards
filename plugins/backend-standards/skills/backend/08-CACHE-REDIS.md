# 08 — Cache (Valkey / Redis protocol)

> **Engine: Valkey** ([ADR-0009](adr/0009-cache-engine.md)), BSD-3 licensed, wire-compatible
> with Redis. The client is `go-redis`; the code and commands are identical. Below, every
> mention of "Redis" refers to the **Redis protocol**, not the product.
>
> Cache is an **optimisation, not a source of truth.** When you turn the cache off, the
> system should slow down but **must keep working**. Any usage that violates this is wrong.

---

## 1. When to add a cache

**[CACHE-01] MUST:** Cache is never added **without measurement**. First show that
something is slow (`EXPLAIN`, p95 metric), then try fixing the index/query, and only add
a cache if that is not enough.
> **Why:** Cache is buying speed by buying a correctness problem. Caching a query that is
> slow because of a missing index hides the real issue and adds a staleness problem on top.

**[CACHE-02] SHOULD — Data suited to caching:**

| Suited | Not suited |
|---|---|
| Reference data that rarely changes (province/district, category, permission list) | Consistency-critical data such as money, stock, reservations |
| Expensive to compute, small result (aggregation, report) | Data that is per-user and one-off |
| High read / low write ratio | Data that changes on every request |
| Staleness is tolerable | Staleness has legal or financial consequences |

**[CACHE-03] MUST:** For every piece of cached data, an **accepted staleness window**
is written down. If there is no answer to "this data can be at most 5 minutes stale," no
cache is added.

---

## 2. Key design

**[CACHE-04] MUST:** Key format: `<service>:<entity>:<version>:<id>`

```
parking:item:v1:9f3c...          single record
parking:list:v1:page=1&limit=50  list (parameters sorted and normalised)
auth:perms:v1:user:9f3c...       user permissions
```

**[CACHE-05] MUST:** The key carries a **version** (`v1`). When the schema of the cached
structure changes, the version is bumped, and old records die off on their own via TTL.
> **Why:** Without a version, records in the old format cannot be parsed by the new code
> after a deploy and produce an error on every request. The alternative, "wipe the whole
> cache," dumps an instant spike of load onto the DB.

**[CACHE-06] MUST:** Parameters in list keys are **normalised**: alphabetical order,
defaults written out explicitly. `?limit=50&page=1` and `?page=1&limit=50` must produce
the same key; if they don't, the cache hit rate is cut in half.

**[CACHE-07] MUST:** A key for per-user data contains the **user id**.
> **Why:** Caching a list that has been filtered by permission under a key without the
> user means showing user A's data to user B. This is not a performance bug, it is a
> **data leak**.

**[CACHE-08] MUST:** Every key has a TTL. `SET` without a TTL is forbidden.
> **Why:** A key without a TTL stays stale **forever** if the invalidation is forgotten,
> and it leaks Redis memory. TTL is the last line of defence against a forgotten
> invalidation.

**Default TTLs:**

| Data | TTL |
|---|---|
| Reference/constant list | 1 hour |
| User permissions | 5 minutes |
| List/page result | 60 seconds |
| Heavy aggregation/report | 5 minutes |
| Idempotency record | 24 hours |
| Distributed lock | job duration × 2, at most 30 seconds |

---

## 3. Read and write pattern

**[CACHE-09] MUST — Cache-aside** is the default pattern:

```go
func (s *parkingService) GetByID(ctx context.Context, id string) (*dto.Parking, error) {
	key := "parking:item:v1:" + id

	if b, err := s.cache.Get(ctx, key).Bytes(); err == nil {
		var p dto.Parking
		if json.Unmarshal(b, &p) == nil {
			return &p, nil
		}
		// Corrupt record: delete it and continue from the DB. A cache error does NOT drop the request.
		s.cache.Del(ctx, key)
	} else if !errors.Is(err, redis.Nil) {
		// Redis unreachable: log it and go to the DB. Cache is optional [CACHE-10].
		pkg.Log.Warn("cache read failed", "key", key, "err", err)
	}

	p, err := s.repo.GetByID(ctx, id)
	if err != nil {
		return nil, err
	}
	if b, err := json.Marshal(p); err == nil {
		// A write failure is ignored: failing to write to cache must not fail the request.
		s.cache.Set(ctx, key, b, 5*time.Minute)
	}
	return p, nil
}
```

**[CACHE-10] MUST:** A Redis error must **not drop** the request. If the cache can't be
read, go to the DB; if it can't be written, ignore the failure.
> **The one exception:** the rate limit counter and the distributed lock. These are not
> a cache, they are a **correctness mechanism**; if Redis is down there is no fail-open
> ([SEC-08]), the request is rejected.

**[CACHE-11] MUST:** The context timeout on Redis calls is **500 ms** ([RES-07]). The
moment a cache is slower than the DB, it has stopped being a cache.

**[CACHE-12] MUST NOT:** Write to the cache on the write path and defer the DB write
(write-behind). If the process dies, the data is lost and nobody notices.

---

## 4. Invalidation

> "There are two hard problems in computer science: cache invalidation and naming."
> That is why **a short TTL beats complex invalidation.**

**[CACHE-13] MUST:** After a write, the related keys are **deleted**, not updated:

```go
func (s *parkingService) Update(ctx context.Context, id string, req *dto.ParkingUpdateRequest) (*dto.Parking, error) {
	p, err := s.repo.Update(ctx, id, req)
	if err != nil {
		return nil, err
	}
	// Delete, NOT update: if we write the new value into the cache, a concurrent
	// update racing against it makes the last writer undefined, and the cache drifts from the DB.
	s.cache.Del(ctx, "parking:item:v1:"+id)
	s.invalidateLists(ctx)
	return p, nil
}
```

**[CACHE-14] MUST:** List caches are invalidated with a **version counter**, not by
deleting keys one by one:

```go
// List key: parking:list:v1:<gen>:page=1&limit=50
// After a write, just bump the counter — all list keys become invalid at once
// and are cleaned up by TTL. No need to delete by pattern with KEYS/SCAN.
gen, _ := s.cache.Incr(ctx, "parking:list:gen").Result()
```

**[CACHE-15] MUST NOT:** The `KEYS` command in production. It scans the entire key
space and blocks Redis because it is **single-threaded**. Use `SCAN` if you must, but
prefer not using either.

**[CACHE-16] MUST NOT:** `FLUSHALL` / `FLUSHDB` (in production). It also wipes rate
limit counters, locks, and idempotency records.

---

## 5. Cache stampede

The instant a popular key's TTL expires, hundreds of requests hit the DB at once.

**[CACHE-17] MUST:** Caches for expensive computations have stampede protection. The
simplest and sufficient fix is a **jittered TTL**:

```go
// Don't let 1,000 keys written at the same time die at the same time: add ±20% randomness to the TTL.
func ttlWithJitter(base time.Duration) time.Duration {
	j := time.Duration(rand.Int63n(int64(base / 5)))
	return base - base/10 + j
}
```

**[CACHE-18] SHOULD:** For very expensive computations (a report that takes seconds),
use the **single-flight** pattern: only one computation runs for a given key at a time,
and the rest wait for its result. `golang.org/x/sync/singleflight` exists for this.

---

## 6. Distributed lock

**[CACHE-19] MUST:** A lock is acquired with `SET key value NX PX <ttl>`, and the **TTL
is mandatory**:

```go
token := uuid.NewString()
ok, err := rdb.SetNX(ctx, "lock:import:daily", token, 30*time.Second).Result()
if err != nil || !ok {
	return ErrLocked   // lock not acquired: NO fail-open, don't do the work
}
defer releaseLock(ctx, rdb, "lock:import:daily", token)
```

**[CACHE-20] MUST:** A lock is released **by its owner**. A plain `DEL` is not enough:
if the TTL expired and the lock passed to someone else, `DEL` deletes someone else's lock:

```go
// Atomic via Lua: delete only if the value is mine, otherwise don't touch it.
var releaseScript = redis.NewScript(`
	if redis.call("get", KEYS[1]) == ARGV[1] then
		return redis.call("del", KEYS[1])
	end
	return 0`)
```

**[CACHE-21] MUST:** The lock TTL must be **longer than the worst-case duration** of the
protected job; if the job runs long, the lock is extended periodically (heartbeat).

**[CACHE-22] SHOULD:** A Redis lock is **best-effort**; where absolute correctness is
required, such as money or stock, use a Postgres transaction with `SELECT ... FOR UPDATE`.

---

## 7. Redis setup and operations

**[CACHE-23] MUST:** Valkey is given `maxmemory` and `maxmemory-policy`:
```
maxmemory 512mb
maxmemory-policy allkeys-lru
```
> **Why:** Without a policy (`noeviction`), the server **refuses writes** once memory is
> full, and the cache layer suddenly turns into a source of errors. `allkeys-lru` evicts
> the least recently used entry.
> **Caution:** If the same instance is used for both cache and locks/rate limiting,
> `allkeys-lru` can also evict locks, use a **separate DB index or a separate instance**.

**[CACHE-24] MUST:** Persistence (RDB/AOF) is **not needed** for cache data and can be
turned off; if lock/idempotency data is stored there, AOF must be on.

**[CACHE-25] MUST:** Values placed in the cache are **small**. A value over 1 MB is not
cached, fetching it over the network can be more expensive than a DB query.

**[CACHE-26] SHOULD:** Serialisation is done with `encoding/json`. A faster format is
only considered once the hot path has been **measured** to be a bottleneck; no premature
optimisation.

**[CACHE-27] MUST:** Metrics to track ([10-OBSERVABILITY.md](10-OBSERVABILITY.md)): hit
rate, eviction count, memory usage, command latency.
> If the hit rate is **below 80%**, the cache is probably misplaced: either the key is
> too fragmented or the TTL is too short. Don't claim "cache exists, so it's fast"
> without measuring it.

**[CACHE-28] MUST:** The connection pool is tuned (`PoolSize`, the default `10 ×
GOMAXPROCS` is excessive for most services), with `DialTimeout` / `ReadTimeout` /
`WriteTimeout` set.

---

## 8. NEVER DO THIS — cache

- ❌ Write a key without a TTL
- ❌ Use the cache as a source of truth (data that only exists in the cache)
- ❌ Drop the request on a cache error (except for rate limiting and locks)
- ❌ Cache per-user data under a key without the user
- ❌ `KEYS` / `FLUSHALL` in production
- ❌ Run a cache server without setting `maxmemory-policy`
- ❌ Hold locks on the same instance with `allkeys-lru`
- ❌ Update the cache (instead of deleting it)
- ❌ A distributed lock without a TTL, or released without verifying its owner
- ❌ Add a cache without measuring
- ❌ Leave a key without a version
