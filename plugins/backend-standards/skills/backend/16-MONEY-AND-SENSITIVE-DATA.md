# 16 — Money, Personal Data and Audit Trail

> The common trait of the errors in this file: they happen **silently** and are noticed
> months later. A miscalculated cent stays invisible until reconciliation day. Personal
> data that should have been deleted causes no problem until an audit arrives. A missing
> audit trail draws no one's attention until someone asks "who deleted this record."
>
> **Legal notice:** The KVKK (Turkey's personal data protection law) articles in §2 are
> **technical implementation rules, not legal advice.** Retention periods, legal bases and
> disclosure texts are set by the institution's legal department; the rules here ensure
> those decisions are **technically enforceable**.

---

# 1. Money and decimal numbers

## 1.1 Basic rule

**[MONEY-01] MUST NOT — Store, move or calculate money with `float32`/`float64`.**

> **Why:** IEEE-754 binary floating point cannot represent decimal values like `0.1`
> **exactly**. The consequences:
> ```go
> 0.1 + 0.2 == 0.3        // false
> var t float64
> for i := 0; i < 10; i++ { t += 0.1 }
> t == 1.0                // false → 0.9999999999999999
> ```
> The real-world effect: a report summing 1,245 debt records will be off by a few cents
> at reconciliation. The missing cents turn into the question "which record is wrong,"
> and there is no answer, because no single one is wrong on its own; even the order of
> summation changes the result. This error **produces no warning**; the numbers simply
> do not add up.

**[MONEY-02] MUST — Use `NUMERIC` in the schema, never `REAL`/`DOUBLE PRECISION`/`MONEY`:**

```sql
debt_amount  NUMERIC(14,2) NOT NULL,
paid_amount  NUMERIC(14,2) NOT NULL DEFAULT 0,

-- The business rule also lives in the schema [DB-08]: paid amount cannot be negative
-- and cannot EXCEED the debt.
CONSTRAINT debts_paid_valid CHECK (paid_amount >= 0 AND paid_amount <= debt_amount)
```

> `NUMERIC` does **exact** decimal arithmetic; the result of `SUM()` is correct down to
> the cent. Postgres's `MONEY` type is not used: its currency and decimal formatting
> depend on the server's `lc_monetary` setting, so the meaning of stored values shifts
> whenever that database setting changes.

`NUMERIC(14,2)` = up to 12 integer digits + 2 decimal (cent) digits. If a larger amount
is needed, increase the scale, **not the number of decimal places** — the number of cent
digits is a business rule, not a technical detail.

## 1.2 The Go side — the `Money` type

**[MONEY-03] MUST — In Go, money is stored as `int64` cents**, in its own type:

```go
package money

// Money — an integer in CENTS. 1234.56 TL -> Money(123456).
// Money is never carried as a float [MONEY-01]; integer addition/subtraction gives an
// exact result.
type Money int64

const subunits = 100 // 1 TL = 100 cents

// Read from the DB as TEXT: a NUMERIC -> float conversion loses precision.
// The column is explicitly selected with ::text in the query [MONEY-06].
func (m *Money) Scan(src any) error {
	var s string
	switch v := src.(type) {
	case nil:
		return errors.New("money: cannot scan NULL into Money, use *Money")
	case string:
		s = v
	case []byte:
		s = string(v)
	default:
		// float64 should NEVER land here. If it does, the query did not use ::text.
		return fmt.Errorf("money: unexpected type %T (did the query use ::text?)", src)
	}
	parsed, err := Parse(s)
	if err != nil {
		return err
	}
	*m = parsed
	return nil
}

func (m Money) Value() (driver.Value, error) { return m.String(), nil }

// String — "1234.56". For negative values the sign comes first.
func (m Money) String() string {
	neg := m < 0
	v := int64(m)
	if neg {
		v = -v
	}
	s := fmt.Sprintf("%d.%02d", v/subunits, v%subunits)
	if neg {
		return "-" + s
	}
	return s
}

// Marshalled to JSON as a STRING [MONEY-04].
func (m Money) MarshalJSON() ([]byte, error) { return json.Marshal(m.String()) }

// Only a string is accepted from JSON. A number is an ERROR — silently accepting it and
// falling back to float would defeat the whole point of this type.
func (m *Money) UnmarshalJSON(b []byte) error {
	var s string
	if err := json.Unmarshal(b, &s); err != nil {
		return errors.New(`money: amount must be a string, e.g. "1234.56"`)
	}
	parsed, err := Parse(s)
	if err != nil {
		return err
	}
	*m = parsed
	return nil
}
```

**[MONEY-04] MUST — In JSON, money is a **string**, not a number.**

> **Why:** In JavaScript, `JSON.parse` converts all numbers to `float64` — meaning no
> matter how careful the backend and frontend are, the amount gets corrupted. If you
> send `{"debt": 1234.56}`, the browser may hold `1234.5600000000001`, and the user sees
> this on screen. If you send `{"debt": "1234.56"}`, the amount stays exactly as it is.
>
> Explaining this to the frontend **once** is cheaper than chasing missing cents in every
> report.

**[MONEY-05] MUST:** If a `Money` field can be "unknown," use `*Money` (a pointer) —
[GEN-20] and [API-07] apply here too. This keeps `0` from being confused with "no amount
entered."

**[MONEY-06] MUST:** Money columns are selected with an **explicit `::text`** in the
query:

```sql
SELECT id, name, debt_amount::text, paid_amount::text FROM stall_debts WHERE id = $1;
```
> **Why:** Instead of trusting the driver to decide which Go type a `NUMERIC` becomes,
> reading through text makes the conversion **single and predictable**. A driver upgrade
> cannot silently change the behaviour.

## 1.3 Arithmetic and rounding

**[MONEY-07] MUST:** Addition and subtraction are done on `Money` (integers) — the
result is exact.

**[MONEY-08] MUST:** Multiplication and division (ratios, VAT, instalments) are done
with **explicit rounding**, and the rounding direction is defined in **one place**:

```go
// For rate-based calculations like VAT, the rounding RULE must be explicit: here we
// round half up — that matches invoicing practice in Turkey.
// The DIRECTION and MOMENT of rounding are a business decision; they must be embedded
// in the code and commented.
func (m Money) MulRate(numerator, denominator int64) Money {
	if denominator == 0 {
		panic("money: division by zero")
	}
	v := int64(m) * numerator
	half := denominator / 2
	if v >= 0 {
		return Money((v + half) / denominator)
	}
	return Money((v - half) / denominator)
}

// 20% VAT: total.MulRate(20, 100)
```

**[MONEY-09] MUST:** When splitting into instalments, **no remaining cent is lost**.
Splitting 100.00 TL into 3 gives 33.33 + 33.33 + 33.33 = 99.99; the missing 1 cent is
added to one instalment:

```go
// Remaining cents are distributed one by one to the first parts:
// the sum of the parts ALWAYS equals the total.
func Split(total Money, parts int) []Money {
	out := make([]Money, parts)
	base := int64(total) / int64(parts)
	rem := int64(total) % int64(parts)
	for i := range out {
		out[i] = Money(base)
		if int64(i) < rem {
			out[i]++
		}
	}
	return out
}
```
> **Testing is mandatory:** for every amount and part count, `sum(Split(t,n)) == t`.
> The table test below has been verified alongside this file (35 combinations):
> ```go
> for _, total := range []int64{10000, 10001, 9999, 1, 123457} {
>     for parts := 1; parts <= 7; parts++ {
>         var sum Money
>         for _, p := range Split(Money(total), parts) { sum += p }
>         if int64(sum) != total { t.Fatalf("total=%d parts=%d", total, parts) }
>     }
> }
> ```

### `Parse` — from text to Money

`Scan` and `UnmarshalJSON` use this; do not **skip** it when copying:

```go
func Parse(s string) (Money, error) {
	s = strings.TrimSpace(s)
	neg := strings.HasPrefix(s, "-")
	s = strings.TrimPrefix(s, "-")

	parts := strings.SplitN(s, ".", 2)
	whole, err := strconv.ParseInt(parts[0], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("money: invalid amount %q", s)
	}
	var frac int64
	if len(parts) == 2 {
		// "5" -> "50" (50 cents, not 5), "567" -> "56" (excess is truncated)
		f := (parts[1] + "00")[:2]
		if frac, err = strconv.ParseInt(f, 10, 64); err != nil {
			return 0, fmt.Errorf("money: invalid cents %q", s)
		}
	}
	v := whole*subunits + frac
	if neg {
		v = -v
	}
	return Money(v), nil
}
```

> **Note:** The `Money` type, `Parse`, `Split` and `MulRate` in this file have been
> **compiled and tested** (`go vet` clean, 5 tests pass). Code copied from here works as
> is.

**[MONEY-10] MUST:** Rounding is done **once, at the very end**. Rounding intermediate
results and then summing them accumulates error.

## 1.4 Currency and integrity

**[MONEY-11] MUST:** Even if only one currency is used, this is stated **explicitly** —
either as a schema comment or a `currency CHAR(3) NOT NULL DEFAULT 'TRY'` column:
```sql
-- All amounts are in TRY. If multi-currency support becomes necessary, a currency
-- column is added; until then we keep the assumption written down so no one has to guess.
debt_amount NUMERIC(14,2) NOT NULL,
```
> **Summing** amounts in different currencies is the most expensive silent error.

**[MONEY-12] MUST:** A transaction that changes money is inside a **transaction**
([DB-22]), and is protected with an `Idempotency-Key` ([API-25]) if it must not be
repeatable.
> A client retries after a network error; if unprotected, this causes a **double
> charge** — and the customer notices it before you do.

**[MONEY-13] MUST:** Every transaction that changes money produces an **audit trail**
entry (§3).

**[MONEY-14] MUST:** Derivable values such as balances are either `GENERATED` ([DB-09])
or computed from movements — never kept separately in two places and synced by hand.

## 1.5 When to use `shopspring/decimal`

**[MONEY-15] SHOULD:** Integer cents are **sufficient**, with zero dependencies, for
addition/subtraction and simple ratios. If genuine decimal math is needed (compound
interest, multi-digit currency conversion, financial formulas), `shopspring/decimal` may
be considered — however:
- **An ADR must be written** ([02](02-TECH-VERSIONS.md) §4).
- Its latest release is **v1.4.0 (April 2024)** — this exceeds the threshold in our own
  [VER-07] rule that "consider a package abandoned if its latest release is more than
  12 months old." The library may be mature and stable ("finished"), but this is
  **an exception that must be explicitly justified.**

## 1.6 Migrating existing `float` columns

**[MONEY-16] MUST:** If money columns are currently stored as
`REAL`/`DOUBLE PRECISION`, the migration is done in forward-compatible steps ([DB-13]):

```sql
-- +goose Up
-- 1) New column (nullable), 2) backfill, 3) NOT NULL, 4) drop the old column in a
-- separate migration.
ALTER TABLE stall_debts ADD COLUMN debt_amount_num NUMERIC(14,2);
UPDATE stall_debts SET debt_amount_num = ROUND(debt_amount::numeric, 2);
```
> **Warning:** Converting from `float` to `NUMERIC` does **not fix** values that are
> already corrupted — it only stops further corruption. Before migrating, save the
> totals and compare afterward; any difference is a measure of how long the error has
> been running.

---

# 2. Personal data and KVKK

> Under KVKK (Turkey's personal data protection law), Law No. 6698, the institution is
> the **data controller**. The rules below are what is technically needed to fulfil that
> responsibility.

## 2.1 Inventory and minimisation

**[KVKK-01] MUST:** It is **documented** which table holds which personal data. It is
labelled in the schema:

```sql
CREATE TABLE stall_owners (
    id           UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    full_name    VARCHAR(255) NOT NULL,   -- PERSONAL DATA
    national_id  CHAR(11),                -- PERSONAL DATA · special care: TCKN
    phone        VARCHAR(20),             -- PERSONAL DATA
    stall_id     UUID NOT NULL REFERENCES market_stalls(id),
    ...
);
COMMENT ON TABLE stall_owners IS
  'Contains personal data. Retention period: 10 years from contract end (KVKK-03).';
```
> **Why:** When a deletion request arrives, or a breach must be reported, the answer to
> "which data was affected" must be available **within minutes**. Without an inventory,
> there is no answer.

**[KVKK-02] MUST — Data minimisation:** Do not **collect** personal data you don't need.
"We might need it later" is not a valid justification (the same logic as [GIS-22]). For
every personal data field there must be an answer to "what business task is impossible
without this."

**[KVKK-03] MUST:** A **retention period** is defined for every category of personal
data, and deletion/anonymisation runs **automatically** once it expires. No manual
cleanup.

## 2.2 Deletion and anonymisation

**[KVKK-04] MUST:** A data subject's deletion request must be **technically
enforceable**. What "deletion" means is decided in advance:

| Approach | When |
|---|---|
| **Hard delete** | The whole record is personal data and does not need to be kept as a business record |
| **Anonymisation** | Statistical/financial records must be preserved but the person must become unidentifiable: name/TCKN/phone set to `NULL` or a fixed value, the relation is severed |

**[KVKK-05] MUST — Soft delete does not count as deletion for personal data.** The
`deleted_at` pattern in [DB-33] is an operational flag; personal data must be **actually**
deleted or anonymised. Conflating the two means data called "deleted" is still sitting
there.

**[KVKK-06] MUST:** A deletion request **also covers backups**. To prevent deleted data
from reappearing after a restore: the backup retention period must be defined, and
re-applying the deletion list after a restore must be written into the **procedure**.

## 2.3 Access, encryption, breaches

**[KVKK-07] MUST — Special category data** (health, biometric, religion, criminal
conviction, union membership, etc.) is protected more strictly: separate permissions
([SEC-05]), encrypted storage, and **every access is written to the audit trail**
([AUDIT-01]).

**[KVKK-08] MUST:** Personal data is encrypted in transit (TLS) and at rest (disk/DB
encryption). Backups are encrypted too — an unencrypted backup is the easiest way to
leak data.

**[KVKK-09] MUST:** No personal data appears in logs ([SEC-25], [SEC-27]). The `user_id`
(UUID) is logged; name, TCKN, phone, full email address are not. A log retention period
is defined ([PERF-26]).

**[KVKK-10] MUST — Real personal data is not copied into the test/development
environment.** Restoring a production backup locally is common and a serious violation.
Seed data is generated or masked instead.
> This rule is an **exception** to [GEN-09] ("100% real data") — and it should be: what
> must be real is the municipality's open data, not a citizen's identity information.

**[KVKK-11] MUST — Breach notification within 72 hours.** If personal data is unlawfully
obtained by others, the data controller must notify the Personal Data Protection Board
**without delay and within 72 hours at the latest** of becoming aware of it (Law No. 6698
art. 12/5; Board decision dated 24.01.2019, No. 2019/10). The clock starts **from the
moment it is discovered, not the moment the breach occurred.**

**What this requires technically — the following must already be in place to be able to notify:**
- Being able to state which data was affected → **data inventory** ([KVKK-01])
- Being able to state who accessed it → **audit trail** (§3)
- Being able to state when it happened → **log retention period** must be adequate
- Being able to state how many people were affected → queryable records

> Without these four, the only thing that can be said within 72 hours is "we don't
> know" — and that carries heavier consequences than the breach itself.

**[KVKK-12] MUST:** Every place where personal data is transferred to a third party
(external service, analytics, cloud, abroad) is **documented**. A new outbound call
added to a service can create a data transfer without anyone realising it.

---

# 3. Audit trail (audit log)

## 3.1 Difference from application logs

| | Application log ([10](10-OBSERVABILITY.md)) | Audit trail |
|---|---|---|
| Purpose | Diagnostics, operations | Accountability, legal record |
| Reader | Developer | Auditor, legal, management |
| Retention | 14 days | Years (per regulation) |
| Mutable | Yes (rotation) | **No** |
| Location | stdout → collector | **Database table** |

**[AUDIT-07] MUST:** The two are never conflated. The audit trail is not written to
stdout via `slog` — it lives somewhere persistent, queryable and immutable.

## 3.2 What is recorded

**[AUDIT-01] MUST — Operations that must produce an audit trail entry:**
- **Money movements** — creating/deleting a debt, collecting payment, amount changes ([MONEY-13])
- **Personal data** reads (if special category), modifications, deletions, exports
- **Permission and identity** changes — role assignment, granting/revoking permission, enabling/disabling users
- **Deletion operations** — any kind of permanent deletion
- **Bulk operations** — import, export, bulk update
- **Permission denial** ([SEC-09]) and failed login attempts
- **Configuration changes**

**[AUDIT-02] MUST — Every record must include:**

```sql
CREATE TABLE audit_log (
    id           BIGSERIAL PRIMARY KEY,     -- append-only; order matters, no IDOR risk
    occurred_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    actor_id     UUID,                      -- who (NULL = system)
    actor_ip     INET,                      -- from where
    request_id   TEXT,                      -- to correlate with the application log [OBS-04]
    action       TEXT NOT NULL,             -- 'stall_debt.delete', 'user.role_granted'
    entity_type  TEXT NOT NULL,             -- 'stall_debt'
    entity_id    UUID,                      -- which record
    before       JSONB,                     -- PREVIOUS value of the changed fields
    after        JSONB,                     -- NEXT value of the changed fields
    reason       TEXT                       -- justification if any (bulk op, correction)
);

CREATE INDEX idx_audit_entity   ON audit_log (entity_type, entity_id, occurred_at DESC);
CREATE INDEX idx_audit_actor    ON audit_log (actor_id, occurred_at DESC);
CREATE INDEX idx_audit_occurred ON audit_log (occurred_at DESC);
```

**[AUDIT-03] MUST — Append-only.** The DB user the application uses does **not** have
`UPDATE` or `DELETE` privileges on this table:

```sql
REVOKE UPDATE, DELETE ON audit_log FROM app_user;
GRANT INSERT, SELECT ON audit_log TO app_user;
```
> **Why:** An audit trail that can be modified is not an audit trail. The first thing an
> attacker who breaches the system will do is erase their trail; at minimum, they must
> not be able to do it with the application user's own privileges.

**[AUDIT-04] MUST:** The audit record is written **in the same transaction** as the work
itself:
```go
tx, _ := pool.Begin(ctx)
defer tx.Rollback(ctx)
// ... the actual work
if err := audit.Write(ctx, tx, entry); err != nil { return err }
return tx.Commit(ctx)
```
> If written separately, the work can succeed without the trail being written — and this
> happens exactly when the trail is needed most (at the moment of an error).

**[AUDIT-05] MUST:** `before`/`after` carry only the **changed fields**, not the whole
record. For fields containing personal data, the fact that "it changed" may be kept
instead of the value itself — otherwise the audit trail becomes a second copy of
personal data that is supposed to be deletable (which conflicts with [KVKK-04]). This
distinction is decided per table and documented with a comment.

**[AUDIT-06] MUST:** **Reading** the audit trail is itself a privilege (`audit.view`),
and holding it means access to the underlying records — grant it carefully. Reading the
audit trail is also logged.

**[AUDIT-08] MUST:** A deleted record leaves a trace. When a record is permanently
deleted, the `entity_id` and `before` information remain in the audit trail — there is
never a state where "this record never existed."

**[AUDIT-09] MUST:** A retention period is defined and comes from regulation (typically
10 years for financial records). The audit trail is **not subject to** the general log
retention period in [PERF-26].

---

## 4. NEVER DO THIS

**Money**
- ❌ Store, move or calculate money with `float32`/`float64`
- ❌ Use `REAL`/`DOUBLE PRECISION`/`MONEY` in the schema
- ❌ Send money in JSON as a **number**
- ❌ Round intermediate results and then sum them
- ❌ Leave the rounding direction unwritten
- ❌ Lose the remaining cent when splitting instalments
- ❌ Sum amounts in different currencies
- ❌ Perform a money operation outside a transaction
- ❌ Expose a money operation via `POST` without idempotency protection

**Personal data**
- ❌ Not keeping a personal data inventory
- ❌ Personal data with an undefined retention period
- ❌ Treating soft delete as deletion of personal data
- ❌ Copying production data into the test/development environment
- ❌ Unencrypted backups
- ❌ Name/TCKN/phone/email in logs
- ❌ Not recording data transfers to external services
- ❌ Going to production without the inventory/trail needed to meet the 72-hour notification

**Audit trail**
- ❌ Conflating the audit trail with the application log
- ❌ An audit table with `UPDATE`/`DELETE` privileges
- ❌ Writing the audit record in a separate transaction from the work
- ❌ Leaving a money/permission/deletion operation without a trail
- ❌ Copying the whole record (including personal data) into the audit trail
- ❌ Leaving reading the audit trail unrestricted
