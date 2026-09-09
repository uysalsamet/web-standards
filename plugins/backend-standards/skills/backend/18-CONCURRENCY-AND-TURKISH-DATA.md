# 18 — Concurrency, Turkish Text and Time

> The three topics in this file share one trait: **they do not produce an error
> message.** The record saves, the search runs, the date displays, but the result is
> wrong, and only the user ever notices.

---

# 1. Concurrent editing (lost update)

## 1.1 The problem

```
10:00  Ayşe opens the parking record    → capacity: 100, floors: 3
10:01  Mehmet opens the same record     → capacity: 100, floors: 3
10:02  Ayşe sets capacity to 150        → saved
10:03  Mehmet sets floor count to 4     → saved
       Result: capacity is 100 again.  Ayşe's change is GONE.
```

Ayşe saw no error. Mehmet saw no error. The record is not corrupted. One change just
silently disappeared, and no one will notice.

> **Note:** The [API-06] rule ("all fields are pointers in PUT") **reduces** this risk
> (Mehmet only sends `floor_count`, so he does not touch capacity) but does **not**
> solve it: if both edit the same field, the last writer still wins and the first is
> never warned.

## 1.2 Solution — optimistic locking

**[CONC-01] MUST:** Any table that multiple users can edit concurrently has a
**version column**:

```sql
CREATE TABLE parkings (
    id      UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    ...
    -- Increments on every update. The client states which version it edited;
    -- if someone else has written in the meantime, the version no longer matches
    -- and the update is rejected.
    version BIGINT NOT NULL DEFAULT 1
);
```

**[CONC-02] MUST:** The update checks the version inside `WHERE` and **checks the
number of affected rows**:

```go
tag, err := r.pool.Exec(ctx, `
    UPDATE parkings SET
        name       = COALESCE($1, name),
        version    = version + 1,
        updated_at = now()
    WHERE id = $2 AND version = $3`,
    req.Name, id, req.Version)
if err != nil {
    return translate(err)
}
// 0 rows: either the record does not exist, or SOMEONE ELSE UPDATED IT IN THE
// MEANTIME. To tell the two apart — and give the client the right error — check
// whether the record still exists.
if tag.RowsAffected() == 0 {
    exists, _ := r.Exists(ctx, id)
    if !exists {
        return ErrNotFound
    }
    return fmt.Errorf("%w: the record was changed by someone else after you viewed it",
        ErrConflict)
}
```

**[CONC-03] MUST:** The `version` field is returned in the response DTO and is
**required** in the update request:

```go
type Parking struct {
    ID      string `json:"id"`
    Version int64  `json:"version"`   // the client MUST send this back
    ...
}

type ParkingUpdateRequest struct {
    // Other fields are pointers per [API-06], but version is NOT: sending it is mandatory.
    Version int64   `json:"version"`
    Name    *string `json:"name"`
}
```

**[CONC-04] MUST:** A version conflict returns **409 Conflict** (per the [API-19]
table), and the message tells the client **what to do**:
```json
{ "error": true, "code": "VERSION_CONFLICT",
  "message": "The record was changed after you viewed it. Please refresh and try again." }
```
> The `code` field ([API-14]) is genuinely needed here: the frontend may want to
> auto-refresh in this case, so it has to be able to tell this apart from a generic 409.

**[CONC-05] SHOULD:** An HTTP `ETag` + `If-Match` pair can be used as an alternative.
The rule is the same; carrying `version` in the body is the default because it is
simpler and less easily misunderstood.

**[CONC-06] MUST:** The version column **cannot be written by the client** — the
server increments it ([API-08]). No client-supplied `version = $n` assignment; it is
only ever compared inside `WHERE`.

## 1.3 When to use pessimistic locking

**[CONC-07] MUST:** Where **absolute correctness** is required, such as money
movements and stock, use `SELECT ... FOR UPDATE` ([CACHE-22]):

```sql
BEGIN;
SELECT paid_amount::text FROM stall_debts WHERE id = $1 FOR UPDATE;  -- row locked
UPDATE stall_debts SET paid_amount = $2 WHERE id = $1;
COMMIT;
```
> The lock holds for the duration of the transaction, so the transaction must be
> **short** ([DB-23]).

**[CONC-08] MUST:** If multiple rows are to be locked, lock them in a **fixed order**
(e.g. `ORDER BY id`) — otherwise two operations can wait on each other and deadlock
([DB-25]).

## 1.4 Counters and accumulated values

**[CONC-09] MUST NOT — the read-modify-write pattern:**

```go
// WRONG: the counter gets lost between two concurrent requests
p, _ := repo.GetByID(ctx, id)
p.OccupiedCapacity++
repo.Update(ctx, p)

// RIGHT: the increment is done atomically in the database
UPDATE parkings SET occupied_capacity = occupied_capacity + 1
 WHERE id = $1 AND occupied_capacity < total_capacity
RETURNING occupied_capacity;
```
> The bound check inside `WHERE` is just as critical: checking in the application and
> writing afterwards lets capacity be exceeded between two requests. The `CHECK`
> constraint in the schema ([DB-08]) is the last line of defence.

**[CONC-10] MUST:** If the same operation must not run twice, use an
`Idempotency-Key` ([API-25]) — concurrency protection does not replace duplicate
protection.

## 1.5 Testing

**[CONC-11] MUST:** Write an optimistic locking test:
```
□ Two consecutive updates with the same version → the second gets 409
□ Update with the correct version                → 200 and the version incremented
□ Request that sends no version                   → 400
□ Non-existent record                              → 404 (not 409)
```

---

# 2. Turkish text

## 2.1 The problem: `i` and `İ`

Turkish is one of the few languages that does **not** follow Unicode's default
case-conversion rules:

| Correct in Turkish | Default (language-independent) behaviour |
|---|---|
| `I` → `ı` | `I` → `i` ❌ |
| `i` → `İ` | `i` → `I` ❌ |
| `İ` → `i` | `İ` → `i` + a combining dot (**two code points**) ❌ |

Turkish has two i/dotless-i pairs (`I`/`ı` and `İ`/`i`), and neither maps the way most
programming-language default case rules assume. The consequences are silent and
annoying:
- `LOWER('İSTANBUL')` does not give you the expected `istanbul` → the search finds
  nothing
- Lowercasing `'ISPARTA'` gives `isparta`, not `ısparta` → a wrong match
- `WHERE LOWER(name) = LOWER($1)` can produce different results on the two sides

**[TR-01] MUST:** Postgres's `lower()`/`upper()` behaviour depends on the database
locale and the **operating system**. Development (Windows) and production (Linux
Alpine) can produce different results. For this reason, OS locale is **never**
trusted.

## 2.2 The fix

**[TR-02] MUST:** Case conversion of Turkish text is done **explicitly with ICU
collation**:

```sql
SELECT lower(name COLLATE "tr-TR-x-icu") FROM districts;
ORDER BY name COLLATE "tr-TR-x-icu";   -- Ç, Ğ, İ, Ö, Ş, Ü sort in the right place
```
> Sorting matters too: under the default collation, `Şişli` can sort **before**
> `Sarıyer`. The user reports the list as "not alphabetical," and no one can figure out
> why.

**[TR-03] SHOULD — a normalised column for search.** The most robust and portable
approach is to keep a column dedicated to search:

```sql
-- Searchable form: lowercase (Turkish rules) + accent folding.
-- Being GENERATED means there is no manual sync to worry about [DB-09].
search_name TEXT GENERATED ALWAYS AS (
    lower(unaccent(name) COLLATE "tr-TR-x-icu")
) STORED;

CREATE INDEX idx_districts_search ON districts (search_name text_pattern_ops);
```
```sql
-- Query: the input goes through the SAME transform. It must be defined in one place only.
WHERE search_name LIKE lower(unaccent($1) COLLATE "tr-TR-x-icu") || '%';
```
> **Why an indexed normalised column:** writing `LOWER(name) LIKE ...` prevents index
> use and scans the table ([DB-26]). A normalised column is both correct and fast.
> Requires the `unaccent` extension: `CREATE EXTENSION IF NOT EXISTS unaccent;`

**[TR-04] SHOULD:** For small datasets, a **nondeterministic ICU collation** can be
used as an alternative:
```sql
CREATE COLLATION turkish_ci (
    provider = icu, deterministic = false, locale = 'tr-TR-u-ks-level2'
);
-- With a column defined under this collation, "İstanbul" = "istanbul" matches directly.
```
> **Caution:** columns with a nondeterministic collation do not support some index
> types and `LIKE`. This is why [TR-03] is the default.

**[TR-05] MUST — on the Go side, `strings.ToLower`/`ToUpper` is not used for
Turkish text.** Go applies language-independent Unicode rules; every error described
above also applies in Go.

```go
import (
    "golang.org/x/text/cases"
    "golang.org/x/text/language"
)

// Lowercasing with Turkish rules. strings.ToLower("İSTANBUL") gives the WRONG result.
var trLower = cases.Lower(language.Turkish)

normalized := trLower.String(input)
```
> `golang.org/x/text` is maintained by the Go team; it does not count as "third party"
> in the sense of [VER-07], but it still needs to be added to `go.mod` and recorded in
> the [02](02-TECH-VERSIONS.md) table.

**[TR-06] MUST:** Normalisation logic lives in **a single function**
(`pkg/textnorm.go`). Both the query side and the write side call that same function —
writing it separately in two places will eventually drift apart, and the search will
silently stop finding records.

## 2.3 Character encoding

**[TR-07] MUST:** The database and the connection encoding are **UTF-8**.
`WIN1254`/`ISO-8859-9` (Latin-5) is not used.

**[TR-08] MUST:** Incoming input is validated as valid UTF-8 ([SEC-12]):
```go
if !utf8.ValidString(q) {
    badRequest(c, "invalid character encoding")
    return
}
```
> **Why:** if a query parameter encoded in Latin-5 goes straight to Postgres, it
> produces `invalid byte sequence for encoding "UTF8"` and a **500** — even though this
> is a client error ([API-21]).

**[TR-09] MUST:** Text length limits are measured with `[]rune`, not bytes ([SEC-13])
— the characters `ğüşiöçİ` are 2 bytes each in UTF-8, and valid input would otherwise
be rejected by mistake.

**[TR-10] MUST:** A Turkish character test is written:
```
□ Does searching "İSTANBUL" find the "istanbul" record
□ Does searching "ISPARTA" find the "ısparta" record
□ Do Ç/Ğ/İ/Ö/Ş/Ü sort in the right place
□ Is a 255-character Turkish string accepted (not tripped up by the byte limit)
□ A query parameter encoded in Latin-5 → 400 (not 500)
```

---

# 3. Time

**[TIME-01] MUST:** All timestamps are `TIMESTAMPTZ` ([DB-06]), and the application
works in **UTC** internally. Conversion to local time happens only at **display**
time.

**[TIME-02] MUST:** Servers and containers are set to UTC; do not set
`TZ=Europe/Istanbul` or similar via env. Display time zone is the client's or the
report's problem.

**[TIME-03] MUST:** A calendar date (date of birth, debt due date) is not conflated
with an instant (creation time) ([API-10]): a date is `DATE` + the string
`"2006-01-02"`; an instant is `TIMESTAMPTZ` + `time.Time`.

**[TIME-04] SHOULD:** Business logic does not call `time.Now()` directly; the clock is
supplied from outside:
```go
type Clock interface{ Now() time.Time }
// Real clock in production, fixed clock in tests. This is the only way to test
// rules like "the last day of the month."
```

**[TIME-05] MUST:** Token lifetimes and time-based checks tolerate **clock skew**
(typically ±60 s). Different servers' clocks are never perfectly in sync.

**[TIME-06] MUST:** Scheduled jobs state their time zone explicitly and account for
**daylight-saving transitions** — see [20](20-INTEGRATION-AND-BULK-DATA.md) [JOB-07].

---

## 4. NEVER DO THIS

**Concurrency**
- ❌ No version column on a multi-user editable record
- ❌ Not checking the number of affected rows after an `UPDATE`
- ❌ Papering over a version conflict with 200 (should be 409)
- ❌ Letting the client write `version`
- ❌ Updating a counter with read-modify-write
- ❌ Enforcing a bound only in the application (the schema also needs a `CHECK`)
- ❌ Locking multiple rows in a random order (deadlock)

**Turkish text**
- ❌ Using `LOWER()`/`UPPER()` on Turkish text without stating a collation
- ❌ Lowercasing Turkish text in Go with `strings.ToLower`
- ❌ Writing the normalisation logic in two separate places
- ❌ Disabling the index with `LOWER(column) LIKE ...`
- ❌ Measuring text length in bytes
- ❌ Sending input to the DB without a UTF-8 check
- ❌ Not writing a Turkish sorting test

**Time**
- ❌ Using `TIMESTAMP` (no tz)
- ❌ Working with local time inside the application
- ❌ Carrying a calendar date in a `time.Time`
- ❌ A duration check with no clock-skew tolerance
