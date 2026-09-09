# 07 — Database

> Postgres + `pgx/v5`. Migrations are versioned with `goose`. Queries are written by hand,
> no ORM ([VER-06]). Code examples use `pgxpool`.

---

## 1. Connection and pool

```go
package postgres

func NewPool(ctx context.Context, cfg *config.Config) (*pgxpool.Pool, error) {
	pc, err := pgxpool.ParseConfig(cfg.DSN())   // DSN is the single source [STR-12]
	if err != nil {
		return nil, fmt.Errorf("could not parse dsn: %w", err)
	}

	pc.MaxConns = cfg.DBMaxConns                 // default 10
	pc.MinConns = 2                              // so the first request doesn't wait to open a connection
	// Connections die silently behind NAT/pgbouncer; refresh them periodically.
	pc.MaxConnLifetime = 30 * time.Minute
	pc.MaxConnIdleTime = 5 * time.Minute
	pc.HealthCheckPeriod = 1 * time.Minute

	pool, err := pgxpool.NewWithConfig(ctx, pc)
	if err != nil {
		return nil, fmt.Errorf("could not create pool: %w", err)
	}
	// Ping is MANDATORY: pgxpool.New is lazy and returns no error even with a wrong
	// password, so the problem only surfaces on the first request, in production.
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("cannot reach the database: %w", err)
	}
	return pool, nil
}
```

**[DB-01] MUST:** Pool settings are set explicitly; never left at their defaults.

**[DB-02] MUST:** The service does not start if `Ping` fails.

**[DB-03] MUST — Pool budget:** `number of services × MaxConns × replicas < Postgres max_connections`.
> Postgres's default is **100**. 30 services × 10 connections = 300 → Postgres rejects
> connections and the error looks like "the database is down." In a multi-service setup,
> **PgBouncer is mandatory** (transaction pooling mode).

**[DB-04] MUST:** If PgBouncer transaction pooling is in use, disable the prepared
statement cache: `pc.ConnConfig.DefaultQueryExecMode = pgx.QueryExecModeSimpleProtocol`,
or set `max_prepared_statements` in PgBouncer. Otherwise you get random
"prepared statement does not exist" errors.

---

## 2. Schema rules

```sql
-- +goose Up
CREATE TABLE IF NOT EXISTS parkings (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    original_id   INT UNIQUE,                     -- source system id, for traceability only
    name          VARCHAR(255) NOT NULL,
    neighborhood  VARCHAR(100),
    -- NULL = unknown. NO DEFAULT: the source also has real 0 values, and if the two
    -- get mixed up, "a parking lot with capacity 0" can't be told apart from "capacity unknown".
    floor_count   INT,
    total_capacity    INT NOT NULL,
    occupied_capacity INT NOT NULL DEFAULT 0,
    -- DERIVED: the client cannot write this, it updates automatically when the sources change.
    empty_capacity INT GENERATED ALWAYS AS (total_capacity - occupied_capacity) STORED,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at    TIMESTAMPTZ NOT NULL DEFAULT now(),

    -- The business rule also lives in the schema: the application check can be bypassed,
    -- this one cannot.
    CONSTRAINT parkings_capacity_valid
        CHECK (total_capacity >= 0 AND occupied_capacity BETWEEN 0 AND total_capacity)
);

CREATE INDEX IF NOT EXISTS idx_parkings_neighborhood ON parkings (neighborhood);
CREATE INDEX IF NOT EXISTS idx_parkings_created_id   ON parkings (created_at DESC, id ASC);

-- +goose Down
DROP TABLE IF EXISTS parkings;
```

**[DB-05] MUST:** The PK is always `UUID DEFAULT gen_random_uuid()`. Sequential int PKs
are forbidden ([API-02] — IDOR).

**[DB-06] MUST:** Every table has `created_at` and `updated_at`, typed **`TIMESTAMPTZ`**.
`TIMESTAMP` (without tz) is never used — data silently drifts when the server's timezone
changes.

**[DB-07] MUST:** FKs are **`NOT NULL`** on mandatory relations.
> **Case:** because `stall_debts.stall_id` was nullable, debt records could be created
> that weren't linked to any stall; it was unclear which merchant they belonged to, and
> they were left out of reports. Enforcing this at the application layer isn't enough —
> it can still be broken with raw SQL.

**[DB-08] MUST:** Business rules are also written as `CHECK`/`UNIQUE`/`NOT NULL` ([GEN-22]).

**[DB-09] MUST:** A derivable value is `GENERATED ALWAYS AS ... STORED` or computed
server-side; **never accepted from the client** ([API-08]).

**[DB-10] MUST:** Decisions are justified with a comment: why there's no DEFAULT, why
NULL is allowed, why there's a UNIQUE. The schema is the longest-lived document.

### Denormalization

**[DB-11] SHOULD:** Don't keep the same information in two tables. If you do, make sure
the copy is **not writable** — derive it from the source:

```sql
-- Copied fields are NOT ACCEPTED from the client, they are derived from the source.
-- If the stall doesn't exist, 0 rows get inserted -> the handler returns 404.
INSERT INTO stall_debts (stall_id, market_place_id, market_name, debt_amount)
SELECT s.id, s.market_place_id, s.market_name, $2
FROM market_stalls s WHERE s.id = $1;
```
> **Case:** `market_place_id` and `market_name` existed both in the debt table and in
> the stall table, and the client could send different values for each — a debt record
> could say "linked to a stall in market A" while also carrying "market B" as the market
> name. It was unclear which one was correct.

---

## 3. Migrations

**[DB-12] MUST:** Migrations use `goose`, are versioned, and **include a `Down` block**.
No hand-rolled migration that runs `*.sql` files by globbing.
> **Why:** the `CREATE TABLE IF NOT EXISTS` glob approach can't add a column to an
> existing table and can't be rolled back. The first schema change requires manual
> intervention.

```
internal/repository/postgres/migrations/
├── 00001_create_parkings.sql
├── 00002_add_parkings_operator_column.sql
└── 00003_backfill_operator.sql
```

**[DB-13] MUST:** Migrations are written to be **forward-compatible**. Dropping/renaming
a column is never a single step:
```
1. Add the new column (nullable)        → old code keeps working
2. Update the code to write both columns, deploy
3. Backfill the old data
4. Update the code to use only the new column, deploy
5. Drop the old column
```
> **Why:** during a rolling deploy, old and new code run **at the same time**. A
> migration that drops a column in a single step instantly breaks the old replicas.

**[DB-14] MUST:** Long-running migrations must not lock the table in production:
- Indexes are added with `CREATE INDEX CONCURRENTLY` (outside a transaction — in goose,
  `-- +goose NO TRANSACTION`).
- When adding a `NOT NULL` column: add it nullable first, backfill, then `SET NOT NULL`.
- Large backfills are done **in batches**, never as a single `UPDATE`.

**[DB-15] MUST:** Migrations run at service startup and **a failure is fatal**. Seed/sample
data loading is separate and **idempotent**; its failure is a warning.

**[DB-16] MUST:** Migration and seed **must produce the same result**. If the two setup
paths (seeding from scratch vs. migrating an existing DB) produce different data, the
same version is effectively two different systems.

---

## 4. Writing queries

```go
// The column list lives in ONE place: SELECT / INSERT RETURNING / UPDATE RETURNING all
// use it. This way, adding a column updates all three at once, none get forgotten.
const parkingColumns = `
	id, original_id, name,
	COALESCE(neighborhood, '') AS neighborhood,
	floor_count,
	total_capacity, occupied_capacity, empty_capacity,
	created_at, updated_at`

func (r *parkingRepository) GetByID(ctx context.Context, id string) (*dto.Parking, error) {
	row := r.pool.QueryRow(ctx,
		`SELECT `+parkingColumns+` FROM parkings WHERE id = $1`, id)

	p, err := scanParking(row)
	if err != nil {
		if errors.Is(err, pgx.ErrNoRows) {
			return nil, ErrNotFound
		}
		pkg.Log.Error("failed to read parking", "id", id, "err", err)
		return nil, fmt.Errorf("%w: could not read record", ErrInternal)
	}
	return &p, nil
}
```

**[DB-17] MUST:** Nullable text columns are wrapped in `COALESCE` — otherwise scanning
into a `string` panics. Columns that are **deliberately not** wrapped in `COALESCE` are
ones where `NULL` means "unknown", and this is documented in a comment.

**[DB-18] MUST:** `SELECT *` is never used. Adding a column shifts the scan order and
the error only shows up at runtime.

**[DB-19] MUST:** A paginated query's `ORDER BY` includes a **unique tie-break** ([API-27]):
```sql
-- WRONG: if the seed wrote all rows at the same instant, created_at ties and the
-- order is unstable.
ORDER BY created_at DESC
-- CORRECT
ORDER BY created_at DESC, id ASC
```
If sorting on a nullable column, add `NULLS LAST`.

### Partial update

```sql
UPDATE parkings SET
	name         = COALESCE($1, name),
	neighborhood = COALESCE($2, neighborhood),
	floor_count  = COALESCE($3, floor_count),
	updated_at   = now()
WHERE id = $4
RETURNING <columns>;
```
> `COALESCE` is only for "not sent → keep as is." If you also need to be able to
> **clear a field to NULL**, use the three-state type ([API-11]) and write
> `CASE WHEN $n_set THEN $n_val ELSE column END`.

---

## 5. Error translation (pgx)

`internal/repository/postgres/errors.go`:

```go
const (
	pgUniqueViolation     = "23505" // record already exists      -> 409
	pgForeignKeyViolation = "23503" // reference to nonexistent row -> 404
	pgNotNullViolation    = "23502" // NULL into a NOT NULL column -> 400
	pgCheckViolation      = "23514" // value outside CHECK          -> 400
	pgStringTruncated     = "22001" // VARCHAR limit exceeded       -> 400
	pgInvalidTextRepr     = "22P02" // malformed UUID/number format -> 400
	pgInvalidDatetime     = "22008" // invalid date                 -> 400
	pgNumericOutOfRange   = "22003" // number out of range          -> 400
)

// Constraint name -> message to show the client. The raw error is NEVER exposed [SEC-17].
var constraintMessages = map[string]string{
	"parkings_original_id_key":  "a record with this original_id already exists",
	"parkings_capacity_valid":   "occupied capacity cannot exceed total capacity",
	"stall_debts_stall_id_fkey": "stall not found",
}

func translate(err error) error {
	var pgErr *pgconn.PgError
	if !errors.As(err, &pgErr) {
		return err
	}
	if msg, ok := constraintMessages[pgErr.ConstraintName]; ok {
		switch pgErr.Code {
		case pgUniqueViolation:
			return fmt.Errorf("%w: %s", ErrConflict, msg)
		case pgForeignKeyViolation:
			return fmt.Errorf("%w: %s", ErrNotFound, msg)
		default:
			return fmt.Errorf("%w: %s", ErrInvalidInput, msg)
		}
	}
	switch pgErr.Code {
	case pgUniqueViolation:
		return fmt.Errorf("%w: record already exists", ErrConflict)
	case pgForeignKeyViolation:
		return fmt.Errorf("%w: related record not found", ErrNotFound)
	case pgNotNullViolation, pgCheckViolation, pgStringTruncated,
		pgInvalidTextRepr, pgInvalidDatetime, pgNumericOutOfRange:
		return fmt.Errorf("%w: the submitted data is invalid", ErrInvalidInput)
	}
	// Unknown code: treat as an internal error, log it IN FULL, mask it for the client.
	pkg.Log.Error("unexpected postgres error", "code", pgErr.Code, "err", pgErr)
	return ErrInternal
}
```

**[DB-20] MUST:** **All eight** of the codes above are translated.
> **Measurement:** in five services only `23503` and `23514` were translated, so a
> second POST with the same `original_id` and a 300-character name both returned
> **500**. Both are client errors.

**[DB-21] MUST:** Sentinel errors (`ErrNotFound`, `ErrConflict`, `ErrInvalidInput`,
`ErrInternal`) are exported; the handler matches them with `errors.Is` ([API-22]).

---

## 6. Transactions

**[DB-22] MUST:** Work that changes more than one table runs in a **single transaction**:

```go
func (r *repo) TransferStall(ctx context.Context, from, to string) error {
	tx, err := r.pool.Begin(ctx)
	if err != nil {
		return fmt.Errorf("%w: could not open transaction", ErrInternal)
	}
	// Rollback via defer is MANDATORY: on an early return or panic, no open
	// transaction should be left behind. Rollback after Commit is a no-op, safe.
	defer tx.Rollback(ctx)

	if _, err := tx.Exec(ctx, `UPDATE ... WHERE id = $1`, from); err != nil {
		return translate(err)
	}
	if _, err := tx.Exec(ctx, `UPDATE ... WHERE id = $1`, to); err != nil {
		return translate(err)
	}
	return tx.Commit(ctx)
}
```

**[DB-23] MUST:** Transactions are kept **short**. No HTTP calls, file IO, or long
computation inside one.
> **Why:** an open transaction holds row locks and blocks `VACUUM`. If an HTTP call
> inside it takes 5s, that lock blocks other requests for 5s.

**[DB-24] MUST:** The transaction has a `context`, and its timeout comes from the
calling layer.

**[DB-25] SHOULD:** Where deadlock risk exists, fix the lock order — always lock records
in the same order (e.g. `id ASC`).

---

## 7. Indexes and query performance

**[DB-26] MUST:** Frequently filtered columns get an index. Column combinations that
appear in `WHERE` and `ORDER BY` get a **composite index** (`(created_at DESC, id ASC)`).

**[DB-27] MUST:** New or changed list queries are checked with `EXPLAIN (ANALYZE, BUFFERS)`.
A `Seq Scan` on a large table is not acceptable.

**[DB-28] MUST NOT:** N+1 queries. Don't run a separate query per record in a list; use
`JOIN` or `WHERE id = ANY($1)`.
```go
// WRONG: 50 records = 51 queries
for _, p := range parkings { p.Owner, _ = r.GetOwner(ctx, p.OwnerID) }

// CORRECT: 2 queries
owners, _ := r.GetOwnersByIDs(ctx, ownerIDs)   // WHERE id = ANY($1)
```

**[DB-29] SHOULD:** Bulk inserts use `pgx.CopyFrom` — many times faster than individual
`INSERT`s. `pgx.Batch` is enough at moderate scale.

**[DB-30] SHOULD:** Don't overdo the number of indexes. Every index raises write cost
and consumes disk. Find and drop unused indexes with `pg_stat_user_indexes`.

**[DB-31] MUST:** Slow query logging is on (`log_min_duration_statement = 500ms`) and
its output is reviewed regularly. Unmeasured slowness is only discovered through user
complaints.

---

## 8. Backup and data safety

**[DB-32] MUST:** Production has an automatic backup, and **restoring it has been
tested**. An untested backup is not a backup.

**[DB-33] MUST:** Deletions are treated as irreversible. On critical tables, use
**soft delete** (`deleted_at TIMESTAMPTZ`) and add `WHERE deleted_at IS NULL` to every
query — forgetting this filter is the most common mistake, so put it in a shared
`WHERE` constant.

**[DB-34] MUST:** Running a bulk `UPDATE`/`DELETE` in production requires approval.
Run `SELECT COUNT(*)` with the same `WHERE` first and verify the count.

---

## 9. NEVER DO THIS — database

- ❌ Running SQL directly from a handler
- ❌ Business rules inside the repository
- ❌ Querying another service's table directly
- ❌ `SELECT *`
- ❌ Sequential int PKs
- ❌ Using `TIMESTAMP` (without tz)
- ❌ Pagination with an `ORDER BY` that has no tie-break
- ❌ A mandatory relation backed by a nullable FK
- ❌ Letting the client write a copied/derived field
- ❌ Using `0` / `""` to mean "unknown"
- ❌ Putting a `GENERATED` column into a Request DTO
- ❌ An irreversible migration with no `Down` block
- ❌ A migration that drops/renames a column in a single step
- ❌ `CREATE INDEX` in production (without CONCURRENTLY)
- ❌ An HTTP call inside a transaction
- ❌ Forgetting `defer tx.Rollback(ctx)`
- ❌ N+1 queries
- ❌ Exceeding the pool budget (services × MaxConns > max_connections)
- ❌ Translating only some of the eight error codes and leaving the rest as 500
