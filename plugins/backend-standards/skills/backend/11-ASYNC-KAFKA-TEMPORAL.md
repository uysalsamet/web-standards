# 11 — Asynchronous Work: Kafka and Temporal

> The default is synchronous. Asynchrony is **buying resilience and scale by paying with
> complexity**; it is not taken on until the need is proven.

---

## 1. Which tool, when

**[ASYNC-01] MUST:** Evaluate in order, use the first one that fits:

| Situation | Solution |
|---|---|
| Work takes < 300 ms and the client waits for the result | Do it **synchronously**. Do not add a queue. |
| Work is long but concerns a single service only, loss is not tolerable | **Postgres-based job queue** (`FOR UPDATE SKIP LOCKED`) |
| An event is (or will be) consumed by **more than one** service | **Kafka** |
| A multi-step process spanning hours to days, needing compensation | **Temporal** |

**[ASYNC-02] MUST:** Endpoints whose p95 exceeds 3 seconds become asynchronous ([PERF-01]):
the request returns **202 Accepted** plus a job id, the client polls a separate endpoint
for status.

**[ASYNC-03] SHOULD:** Do not reach for Kafka at small/medium scale. For a job with a
single consumer a Postgres queue is enough, and it is many times cheaper to operate:

```sql
-- SKIP LOCKED: two workers never take the same job, and neither waits on the other.
UPDATE jobs SET status = 'running', started_at = now()
WHERE id = (
    SELECT id FROM jobs
     WHERE status = 'pending' AND run_after <= now()
     ORDER BY run_after, id
     FOR UPDATE SKIP LOCKED
     LIMIT 1
)
RETURNING id, payload;
```

---

## 2. Common rules (for every asynchronous system)

**[ASYNC-04] MUST:** The consumer is **idempotent**. Processing the same message twice
must not change the result.
> **Why:** Kafka, Temporal, and HTTP retries all give **at-least-once** delivery.
> "Exactly once" is not achievable in practice; idempotency is the consumer's responsibility.

Implementation: every message carries an `event_id`, processed ids are kept in a table:
```sql
INSERT INTO processed_events (event_id, processed_at) VALUES ($1, now())
ON CONFLICT (event_id) DO NOTHING;   -- 0 rows affected: already processed, skip
```

**[ASYNC-05] MUST:** The message is **self-sufficient**. If the receiver needs to call the
producer over HTTP to fetch data back, that is tight coupling; when the producer is down,
the consumer goes down with it.

**[ASYNC-06] MUST:** The message schema is **versioned** and changes in a backward-compatible
way. Fields are added, never removed ([API-29]). A consumer **ignores** a field it does not
recognize; it does not error.

```json
{
  "event_id": "9f3c...",
  "event_type": "parking.updated",
  "version": 1,
  "occurred_at": "2026-08-12T10:00:00Z",
  "producer": "parking-service",
  "data": { "id": "…", "name": "…" }
}
```

**[ASYNC-07] MUST:** A message that permanently fails to process goes to the **DLQ**
(dead letter queue); it is not retried forever.
> **Why:** A "poison message" blocks the partition in an infinite retry loop, and every
> message behind it waits. One bad record halts the whole stream.

**[ASYNC-08] MUST:** The DLQ is **monitored** and its drain procedure is written down.
A DLQ nobody watches is data quietly lost.

**[ASYNC-09] MUST:** Queue depth and consumer lag are metrics ([OBS-12]); a rising
trend fires an alert ([RES-24]).

**[ASYNC-10] MUST:** Workers also perform graceful shutdown: on SIGTERM they **stop
accepting new messages**, finish what is in flight, then exit.

---

## 3. Kafka

**[ASYNC-11] MUST:** The client is `franz-go` ([02](02-TECH-VERSIONS.md)). Kafka runs
in KRaft mode; ZooKeeper is not used.

**[ASYNC-12] MUST — Topic naming:** `<domain>.<entity>.<event>`, lower case, dot-separated.
```
parking.occupancy.changed
market.stall.created
auth.user.deactivated
```
Environment separation is done via **separate cluster/namespace**, not in the topic name.

**[ASYNC-13] MUST:** The partition key is the unit that **requires ordering guarantees**,
typically the entity id.
> **Why:** Kafka only guarantees order within a partition. If no key is given, a given
> record's "created" and "updated" events can land in different partitions, and a
> consumer may see the update before the create.

**[ASYNC-14] MUST:** The offset commit happens **after processing succeeds**. With
auto-commit, the "received it, committed it, then crashed" scenario loses the message.

**[ASYNC-15] MUST:** Producer settings: `acks=all`, `enable.idempotence=true`,
compression on (`lz4`/`zstd`).
> `acks=1` loses messages on a leader crash; `acks=all` prevents that.

**[ASYNC-16] MUST:** A topic's `retention` and partition count are set **explicitly**.
Partition count can be **increased later but not decreased**, and increasing it disturbs
the existing key distribution; choose a sensible value up front.

**[ASYNC-17] MUST — Transactional Outbox.** The DB write and the event production
must happen in the **same transaction**:

```sql
BEGIN;
  UPDATE parkings SET occupied_capacity = $1 WHERE id = $2;
  INSERT INTO outbox (id, topic, key, payload) VALUES (...);
COMMIT;
-- A separate publisher process reads the outbox, pushes to Kafka, marks the row.
```
> **Why:** If you write to the DB and crash before writing to Kafka, the event is lost;
> if you write to Kafka and crash before writing to the DB, you have announced an event
> that never happened. Two systems cannot share one transaction; the outbox reduces the
> problem to a single transaction.

---

## 4. Temporal

**[ASYNC-18] SHOULD:** Use Temporal for:
- Multi-step, long-running processes whose steps span different services (approval
  flow, order, import)
- Processes that need **compensation** when a step fails (SAGA)
- Scheduled/delayed work ("remind in 3 days")
- Flows that wait on human approval and can run for days

**[ASYNC-19] MUST NOT:** Set up Temporal for a simple queue job. Temporal means a server,
a database, and workers; for a small job the operating cost outweighs the benefit.

**[ASYNC-20] MUST:** **Workflow code must be deterministic.** `time.Now()`, `rand`, direct
network calls, and unordered iteration over a map are **not used** inside it. All of these
belong in an **activity**.
> **Why:** Temporal rebuilds state by replaying the workflow. If determinism is broken,
> replay produces a different result and the workflow is permanently corrupted, and this
> tends to surface weeks later, on some future restart.

```go
// WRONG — inside a workflow
now := time.Now()

// RIGHT
now := workflow.Now(ctx)
workflow.Sleep(ctx, time.Hour)          // NOT time.Sleep
workflow.SideEffect(ctx, ...)           // for randomness/UUIDs
```

**[ASYNC-21] MUST:** All IO (DB, HTTP, file) happens inside an **activity**. Activities
are written idempotently ([ASYNC-04]); Temporal retries them.

**[ASYNC-22] MUST:** Every activity has an explicit `StartToCloseTimeout` and `RetryPolicy`.
The default retry policy is **infinite**; define `NonRetryableErrorTypes` for permanent errors.

**[ASYNC-23] MUST:** If a running workflow's code needs to change, use **versioning**
(`workflow.GetVersion`). Changing the code directly corrupts currently-running workflows
on replay.

**[ASYNC-24] MUST:** Do not pass large data into a workflow. Put a **reference** (id, S3
key) in the payload; let the activity fetch the data. Workflow history stores every step;
a large payload bloats the history and hits size limits.

---

## 5. Consistency

**[ASYNC-25] MUST:** An asynchronous system has **eventual consistency**, and this is
written into the API documentation. "Record was created but is not in the list yet"
must not come as a surprise.

**[ASYNC-26] MUST:** Distributed transactions (2PC) are not used. A multi-step process
is built with SAGA: every step has a **compensating step**, run in reverse order on
failure.

**[ASYNC-27] MUST:** Steps that cannot be compensated (sending an email, charging a
payment) are placed at the **very end** of the flow. Doing the irreversible work first
and then hitting an error leaves a state that cannot be corrected.

---

## 6. NEVER DO THIS — async

- ❌ Adding a queue/Kafka/Temporal before the need is proven
- ❌ A non-idempotent consumer
- ❌ Infinite retry (no DLQ)
- ❌ An unmonitored DLQ
- ❌ Doing the DB write and event production in separate transactions (no outbox)
- ❌ Skipping the partition key and expecting an ordering guarantee
- ❌ Committing the offset **before** processing
- ❌ Producing critical events with `acks=1`
- ❌ `time.Now()` / `rand` / direct IO inside a workflow
- ❌ An activity with no timeout or retry policy set
- ❌ Changing a running workflow's code without versioning
- ❌ Carrying large data in a workflow payload
- ❌ Placing a non-compensable step at the start of the flow
- ❌ A worker that does not perform graceful shutdown
