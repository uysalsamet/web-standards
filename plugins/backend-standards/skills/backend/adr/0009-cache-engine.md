# ADR-0009 — Cache engine: Valkey

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [VER-10], [VER-12], [CACHE-01], [CACHE-23]

## Context

We need an in-memory data store for caching, distributed locks, and rate-limit counters
([08](../08-CACHE-REDIS.md)).

This is not a purely technical decision, it is a **license** decision. Brief history:

- March 2024: Redis moved away from the BSD license it had used for years (to RSALv2 +
  SSPLv1).
- In response, the **Valkey** fork was born under the Linux Foundation, continuing from
  Redis 7.2.4 (the last BSD release) and staying on **BSD-3**.
- Redis 8 added **AGPLv3** as a third license option.

Our own standard's rule ([02](../02-TECH-VERSIONS.md) §4) says GPL/AGPL-licensed
dependencies **require approval**, so this decision could not be skipped.

## Options

### A) Valkey 9.1.1 (CHOSEN)
**Strengths:**
- **BSD-3**, permissive; needs no legal review, disclosure, or exception.
- **Linux Foundation governance**, no dependency on a single company's licensing
  decisions. We have already been through this problem once; not repeating it is a
  concrete gain.
- **Wire-compatible**: `go-redis` works unchanged. Commands, Lua scripts, the
  `SETNX`+TTL lock pattern ([CACHE-19]), the `INCR`+`EXPIRE` counter ([RES-04]), all the
  same. **The migration cost is practically just changing the image name.**
- The default cache package in major Linux distributions; the default on AWS
  ElastiCache/MemoryDB and cheaper than Redis OSS there. Published benchmarks report
  better ops/sec, lower p99 latency, and lower memory use.

**Weaknesses:**
- Not as brand-recognized as Redis; the "Redis" reflex is entrenched in the team.
- No Redis Stack modules (RedisJSON, RediSearch, TimeSeries), Valkey's own module
  ecosystem is developing separately.

### B) Redis 8.x
**Strengths:** The most common, the most examples, the largest mindshare. Official
`go-redis` client. Redis Stack modules available.
**Weaknesses:** **AGPLv3.** Running it internally as a cache is not a problem in most
interpretations (no distribution or service offering), but many corporate legal
departments ban AGPL categorically and require disclosure on audit. **"Probably fine" is
not a licensing strategy.**

### C) Dragonfly
**Strengths:** Redis-compatible, multi-core architecture, very high single-node
throughput.
**Weaknesses:** Young; a source-available license (BSL), still needs legal review. The
problem it solves (single-node throughput ceiling) is not one we have.

### D) memcached
**Strengths:** Simple, fast, permissive license.
**Weaknesses:** Plain key-value only. Lacks the `SETNX`/Lua/`INCR` semantics needed for
atomic locks ([CACHE-19], [CACHE-20]) and the rate-limit counter ([RES-04]).

### E) In-process cache (ristretto etc.)
**Strengths:** No network round trip, the fastest option, no dependency.
**Weaknesses:** Not shared across replicas, triples the rate-limit counter across 3
replicas ([RES-04]) and makes a distributed lock impossible. Can be considered as an
**additional** layer for genuinely static reference data, though.

## Decision

**Valkey 9.1.1** (`valkey/valkey:9.1.1-alpine`), client `go-redis v9`.

Technically there is **no difference** between Redis and Valkey for our use, they are
wire-compatible, so not a single line of code changes. The difference is entirely license
and governance, and there Valkey is clearly ahead:

- BSD-3 fits our standard's own license rule; no approval or exception process needed.
- Foundation governance removes dependency on a single company's licensing decisions.
- Since the migration cost is near zero, "stay on Redis and revisit later" had no upside.

## Accepted costs

- Redis Stack modules (RedisJSON/RediSearch) are off the table. Not currently used;
  search needs are met by a separate component. This can be reopened later if needed.
- The team's "Redis" reflex needs to become "Valkey". The cost is low since the code and
  commands are identical; wherever documentation says `Redis` it means the **protocol**
  (noted in the [08](../08-CACHE-REDIS.md) heading).
- Redis's huge pool of examples/StackOverflow answers still applies directly, but for
  Valkey-specific issues there are fewer resources.

## What would change this decision

- **If a real need for a module like RedisJSON/RediSearch appears**, the balance shifts
  toward Redis (or Valkey's module ecosystem is evaluated).
- If Redis makes its license permissive again, the decision becomes moot; a return could
  then be discussed on grounds of ubiquity.
- If Valkey's development stalls or its governance changes, this decision is reopened.
