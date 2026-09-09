# 20 — Bulk Data, Scheduled Jobs, Notifications, Webhooks and Live Streaming

> Common theme: **in none of these does a user sit in front of a screen waiting.** If
> something goes wrong, nobody notices immediately. That is why they all share the same
> requirement: **be idempotent, record the result, make failure visible.**

---

## 1. Bulk data import (ETL)

Moving municipal/institutional data from a file into the system. It is usually assumed to
be a one-off, but in reality it runs many times, and every run risks corrupting the
previous one.

**[ETL-01] MUST:** Every import run is **recorded**:

```sql
CREATE TABLE import_runs (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    source        TEXT NOT NULL,          -- file name / source system
    source_hash   TEXT,                   -- SHA-256 of the source file
    started_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    finished_at   TIMESTAMPTZ,
    status        TEXT NOT NULL,          -- running | success | failed | partial
    rows_total    INT,
    rows_inserted INT,
    rows_updated  INT,
    rows_skipped  INT,
    rows_failed   INT,
    error_report  JSONB,                  -- failed rows: row number + reason
    triggered_by  UUID                    -- who started it
);
```
> **Why `source_hash`:** it is the definitive answer to "have we already loaded this
> file." The file name alone is not enough; the same name can carry different content.

**[ETL-02] MUST — Import is idempotent.** Running the same source twice does not create
duplicate records. Upsert is done on the natural key:

```sql
INSERT INTO parkings (original_id, name, total_capacity, ...)
VALUES ($1, $2, $3, ...)
ON CONFLICT (original_id) DO UPDATE SET
    name           = EXCLUDED.name,
    total_capacity = EXCLUDED.total_capacity,
    updated_at     = now()
-- Don't update updated_at for nothing when nothing changed: you lose the information
-- of "when did this actually change" and it produces unnecessary WAL.
WHERE parkings.* IS DISTINCT FROM EXCLUDED.*;
```
> The natural key (`original_id`) must be `UNIQUE` ([DB-08]) — otherwise `ON CONFLICT`
> does not work and every run duplicates the data.

**[ETL-03] MUST — The partial-failure policy is decided in advance and written down:**

| Policy | When | How |
|---|---|---|
| **All or nothing** | Data integrity is critical, records depend on each other | Single transaction; if one row fails, everything is rolled back |
| **Row by row + report** | Independent records, partial loading is acceptable | Each row in its own transaction; failures are reported |

**The decision is written as a comment in the code.** Silently switching between the two
is the worst option.

**[ETL-04] MUST:** Validation happens **before hitting the database** ([SEC-12] list). A
bad row is not sent to the DB expecting a driver error, since the error message becomes
unreadable and performance collapses.

**[ETL-05] MUST — Skipped and failed rows are COUNTED and REPORTED.** Silently skipping a
row is forbidden.
> **Grounded in a real case:** this is exactly why [GEN-09]'s "100 % real data and
> complete seeding" rule exists. Without a count check like `1,245/1,245`, data that
> imported incompletely goes unnoticed for months, and once noticed, nobody knows which
> records are missing.

**[ETL-06] MUST:** A **count check** is done after import:
```
source row count == inserted + updated + skipped + failed
target table count == expected
```
If it doesn't reconcile, `status = 'partial'` and alarm.

**[ETL-07] MUST:** Large data is processed **in batches** (default 1,000 rows), and
`pgx.CopyFrom` ([DB-29]) is preferred. Do not load the whole file into memory ([FILE-02]).

**[ETL-08] MUST:** The progress of a long-running import is observable: the
`import_runs` row is updated periodically and a metric is published ([OBS-12]).

**[ETL-09] MUST:** The source file is kept (in object storage, [FILE-09]) — it is the
only later answer to "what did the source actually say."

**[ETL-10] MUST:** Import produces an **audit trail** ([AUDIT-01] bulk operations), and if
it contains personal data, the rules in [16 §2](16-MONEY-AND-SENSITIVE-DATA.md) apply.

**[ETL-11] MUST:** The import endpoint is in the heavy-endpoint class ([RES-01]: 10
requests/min), and **concurrent runs for the same source are blocked** (distributed lock
— [CACHE-19]).

---

## 2. Scheduled jobs (cron)

**[JOB-01] MUST — In a multi-replica deployment, a job runs ONLY ONCE.**

> **This is the most common mistake.** An in-process scheduler (`time.Ticker`, a cron
> library) runs **on every replica**. 3 replicas = a debt calculation that runs 3 times at
> midnight = 3x the notifications, 3x the records.

```go
// Deduplicate with a distributed lock. TTL must exceed the job's worst-case duration [CACHE-21].
func (w *Worker) runDaily(ctx context.Context) {
	token := uuid.NewString()
	ok, err := w.rdb.SetNX(ctx, "job:daily-debt-calc", token, 10*time.Minute).Result()
	if err != nil || !ok {
		return // another replica is already running it — this is normal, not an error
	}
	defer releaseLock(ctx, w.rdb, "job:daily-debt-calc", token)
	...
}
```
Alternative: a Postgres advisory lock (`pg_try_advisory_lock`) if you don't want a
dependency on Redis.

**[JOB-02] MUST:** The job is **idempotent**. Even with the lock held, the process can die
mid-run and the job runs again; running twice must not cause harm.

**[JOB-03] MUST:** The missed-run policy is defined: if the system was down for 6 hours,
does it **catch up** on the missed history when it comes back, or **skip** it? The
decision is written down; the default is **skip**, because catch-up usually produces
unwanted bulk notifications.

**[JOB-04] MUST:** Every job has a **duration limit** (`context.WithTimeout`). A job that
runs forever holds the lock and blocks the next run.

**[JOB-05] MUST — Failure is made visible.** A scheduled job that fails silently is the
sneakiest kind of failure: it can go unnoticed for months.
- Every run's result is logged and written to a metric
- **Time of last successful run** is tracked; an alarm fires if it exceeds 2x the expected
  interval ([OBS-21]) — this catches not just "the job errored" but also "the job never
  ran at all"

**[JOB-06] MUST:** Jobs run in a separate worker component rather than in `main`, or are
at least included in graceful shutdown ([RES-19], [RES-21]).

**[JOB-07] MUST:** The time zone is stated explicitly. Does "every night at 03:00" mean
UTC or Europe/Istanbul? During a DST transition, 03:00 can happen **twice** or **not at
all**.
> Default: job definitions are in UTC ([TIME-01]). If depending on local time is a
> **business requirement** (e.g. start of a work shift), that is written explicitly and a
> DST test is done.

---

## 3. Notifications (email / SMS / push)

**[NOTIF-01] MUST — Sending is idempotent.** A retry does not send a second SMS:

```sql
CREATE TABLE notifications (
    id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    -- A second record for the same event cannot be opened: "debt-9f3c-reminder-2026-08"
    idempotency_key TEXT NOT NULL UNIQUE,
    channel        TEXT NOT NULL,     -- email | sms | push
    recipient_ref  UUID NOT NULL,     -- the user's id (NOT the address — [KVKK-09])
    template       TEXT NOT NULL,
    status         TEXT NOT NULL,     -- pending | sent | failed | cancelled
    attempts       INT NOT NULL DEFAULT 0,
    sent_at        TIMESTAMPTZ,
    last_error     TEXT
);
```
> **Why this matters so much:** an SMS cannot be unsent. Sending "you have a debt" to a
> user 3 times is more of a reputation problem than a technical one.

**[NOTIF-02] MUST:** Notifications are sent **asynchronously** ([ASYNC-02]); the provider
is not waited on in the request path. A user should not wait because the SMS provider is
slow.

**[NOTIF-03] MUST:** A provider error does not **fail** the underlying operation. The
record is created; if the notification doesn't go out, the record stands and the
notification stays in the retry queue ([RES-11]…[RES-14]), landing in the DLQ after N
attempts ([ASYNC-07]).

**[NOTIF-04] MUST:** Content is generated **from a template**; templates are not shipped
as text embedded in code. User data going into a template is escaped (XSS in HTML email).

**[NOTIF-05] MUST:** The send record stores the **user reference, not the recipient
address**. If the address is needed, it is read from the user record at send time; the
notification table must not become a second copy of personal data ([KVKK-02],
[AUDIT-05]).

**[NOTIF-06] MUST:** There is a **quota and rate limit** per user and in total. Code stuck
in a loop can send thousands of SMS per second, burning both money and reputation.

**[NOTIF-07] MUST — Real sending from a test/development environment is FORBIDDEN.** The
provider runs in sandbox mode, or recipients are restricted to a whitelist.
> This rule is from the same family as [KVKK-10]: the most visible form of testing with
> production data is sending a test SMS to a real citizen.

**[NOTIF-08] MUST:** A user's notification preferences (opt-in/opt-out) are stored and
checked before sending. For commercial messages, consent management is additionally
subject to regulation.

---

## 4. Outgoing webhooks

**[HOOK-01] MUST — Every request is signed** (HMAC-SHA256), and the signature **includes
a timestamp**:

```
X-Signature-Timestamp: 1754899200
X-Signature: sha256=<hmac(secret, timestamp + "." + body)>
```
> **Why a timestamp:** if only the body is signed, an attacker can replay an old request
> unchanged. The receiver must reject a timestamp older than 5 minutes.

**[HOOK-02] MUST:** The recipient URL is **validated** — this is an SSRF surface
([FILE-18]). A subscriber cannot supply an internal network address.

**[HOOK-03] MUST:** A short timeout (**5s**, [RES-07]), retry with exponential backoff and
jitter for at most a few attempts ([RES-13]), then the DLQ ([ASYNC-07]).
> A slow receiver must not slow down your system. A webhook is never sent in the request
> path.

**[HOOK-04] MUST:** Delivery is **at least once**; the receiver is expected to be
idempotent, and this is **written into the documentation**. A unique `event_id` is sent
with every event ([ASYNC-06] body format).

**[HOOK-05] MUST:** There is **no ordering guarantee**, and this too is documented. The
receiver establishes order using `occurred_at`.

**[HOOK-06] MUST:** Every delivery attempt is recorded: target, status code, duration,
attempt count. Subscriptions that keep failing are automatically suspended and their owner
is notified.

**[HOOK-07] MUST:** No personal data travels in the webhook body; an identifier and
reference are sent, and the receiver fetches the detail from the API using its own
authorization ([KVKK-12]).

---

## 5. Live streaming (WebSocket / SSE)

**[STREAM-01] SHOULD — For a one-way stream, prefer SSE**, not WebSocket.
> SSE is plain HTTP: it passes through the gateway, the authorization mechanism is the
> same, and the browser handles reconnection itself. WebSocket is used only when
> **bidirectional** communication is genuinely required, otherwise you acquire a second
> protocol and a second security surface for free.

**[STREAM-02] MUST:** Authorization is checked when the connection is established
([GEN-10]) **and** re-checked **periodically** for long-lived connections.
> A connection opened by a user whose permission was later revoked keeps receiving data
> until you close it. The connection is closed once the access token's lifetime
> ([AUTH-14]) expires.

**[STREAM-03] MUST:** Connection count is bounded: per user (default **5**) and in total.
Every connection means a goroutine and a buffer ([RES-22]).

**[STREAM-04] MUST — Backpressure.** A slow client must not block the server:
```go
// The write channel is BOUNDED. If it's full, the client isn't consuming messages:
// close the connection. An unbounded queue lets a single slow client exhaust memory.
select {
case client.send <- msg:
default:
    close(client.send)   // slow client is dropped
}
```

**[STREAM-05] MUST:** A heartbeat/ping is sent (default 30s), and a connection that
doesn't respond is closed. Accumulated dead connections are a resource leak.

**[STREAM-06] MUST:** On graceful shutdown, open connections are closed cleanly (a close
frame is sent), not cut off abruptly ([RES-19]).

**[STREAM-07] MUST:** **Media streams do not pass through the application server.** A
dedicated component (MediaMTX etc.) is used for video/camera streaming; the Go service
only handles authorization and generating the stream address.
> Proxying media bytes through the application fills the container's resource limit
> ([PERF-04]) with a single viewer.

**[STREAM-08] MUST:** Streaming endpoints are metered: active connection count, dropped
connection count, average connection lifetime ([OBS-12]).

---

## 6. NEVER DO THIS

**Import**
- ❌ A non-idempotent import (a second run duplicates data)
- ❌ Silently passing over a skipped/failed row
- ❌ Not doing a count check
- ❌ Not writing down the partial-failure policy
- ❌ Loading the entire file into memory
- ❌ Not keeping the source file
- ❌ Allowing two concurrent imports of the same source

**Scheduled jobs**
- ❌ Unlocked cron in a multi-replica setup (a job runs N times)
- ❌ A job with no duration limit
- ❌ Monitoring that doesn't catch "it never ran at all"
- ❌ Not specifying a time zone

**Notifications**
- ❌ Sending without an idempotency key (duplicate SMS)
- ❌ Synchronous sending in the request path
- ❌ Failing the underlying operation on a provider error
- ❌ Storing an email/phone number in the notification table
- ❌ Sending without a quota/rate limit
- ❌ Sending to a real recipient from a test environment

**Webhooks**
- ❌ An unsigned webhook
- ❌ A timestamp not included in the signature (replay)
- ❌ Not validating the recipient URL (SSRF)
- ❌ A synchronous webhook in the request path
- ❌ Behaving as if there is an ordering guarantee
- ❌ Personal data in the webhook body

**Live streaming**
- ❌ Not re-checking authorization after the connection is established
- ❌ No cap on connection count
- ❌ An unbounded write queue (a slow client exhausts memory)
- ❌ A long-lived connection without a heartbeat
- ❌ Proxying media bytes through the application server
