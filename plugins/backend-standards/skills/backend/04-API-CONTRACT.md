# 04 — API Contract

> All services speak the same contract. The frontend should not have to learn a different
> shape, a different error body, or different pagination for every service. This file is
> not a list of preferences, it is a **contract**.

---

## 1. Path naming

```
GET    /<resource>?page=&limit=      → paginated list + meta
GET    /<resource>/:id               → single record
POST   /<resource>                   → create (201)
PUT    /<resource>/:id               → partial update (200)
DELETE /<resource>/:id               → delete (200)
GET    /health                       → health (no auth)
GET    /ready                        → readiness (no auth)
```

**[API-01] MUST:** Resource name is **plural and hyphenated**, lower case:
`district-parkings`, `market-places`, `stall-debts`. Not `MarketPlaces`, `market_places`,
`marketPlace`.

**[API-01b] MUST:** The list endpoint lives at the resource **root** — `GET /parkings`, not
`/parkings/list`. Filtering and pagination are supplied as query parameters.
> **Why:** Two reasons. (1) It is the correct REST shape: the collection itself is already
> the list. (2) Making a fixed path like `/list` a sibling of `/:id` opens a region of
> ambiguity in the router. Gin has supported this since v1.7, but trailing-slash redirection
> is an area with historically panic-producing edge cases. It is safest to never create the
> ambiguity in the first place ([STR-21]).

**[API-02] MUST:** `:id` is always a **UUID**. A resource's own numeric id, such as
`original_id`, never becomes a path parameter.
> **Why:** A sequential int id turns straight into IDOR the moment authorization checking
> weakens, and an attacker can enumerate every record. It also reveals your record count
> externally.

**[API-03] MUST:** The service path carries **no** `api/v1` prefix. The gateway owns the
platform/version prefix (`/api/web/v1`).
> **Why:** Spreading the prefix across every service means changing 30 services at once
> when the version changes. Keeping it in one place stops that.

**[API-04] MUST:** Verbs do not belong in the path. `POST /parkings` is correct;
`POST /createParking` is not. Exception: operations that are genuinely not CRUD are written
as a sub-resource — `POST /parkings/:id/reservations`.

**[API-05] SHOULD:** Nested resources do not go past two levels. Use `/c?b_id=...` instead
of `/a/:id/b/:id/c/:id`.

---

## 2. DTO rules — three types

Every module defines **three** DTOs:

| Type | When | Field shape |
|---|---|---|
| `X` | GET response | Value types; fields that may be unknown are **pointers** |
| `XRequest` | POST body | Every field whose absence must be noticeable is a **pointer** |
| `XUpdateRequest` | PUT body | **All fields are pointers** |

```go
// Response
type Parking struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	// NULL = unknown. Do not confuse with a genuine 0: the source data has real 0 values too.
	FloorCount *int `json:"floor_count"`
	// GENERATED in the DB. Read-only; has NO counterpart in the request DTO.
	EmptyCapacity int       `json:"empty_capacity"`
	CreatedAt     time.Time `json:"created_at"`
	UpdatedAt     time.Time `json:"updated_at"`
}

// POST
type ParkingRequest struct {
	Name string `json:"name"`
	// REQUIRED on POST but still a pointer: a missing submission must not silently fall to 0.
	Latitude  *float64 `json:"latitude"`
	Longitude *float64 `json:"longitude"`
	FloorCount *int    `json:"floor_count"`
}

// PUT — every field is a pointer, no exceptions
type ParkingUpdateRequest struct {
	Name       *string  `json:"name"`
	Latitude   *float64 `json:"latitude"`
	Longitude  *float64 `json:"longitude"`
	FloorCount *int     `json:"floor_count"`
}
```

**[API-06] MUST:** **All fields are pointers** in a PUT DTO.
> `nil` = "not sent, keep the current value" · `&""` = "clear it".
> Using a value type means a single-field update resets every other field to zero, and it
> does so without producing any error.

**[API-07] MUST:** A field whose absence must be noticeable is a pointer **even when it is
required**.
> **Case:** Because `Latitude` was `float64`, `{"name":"X","latitude":41.19}` (no longitude)
> was accepted, `longitude` silently became `0`, and the point dropped into the Gulf of
> Guinea.

**[API-08] MUST NOT:** Put a field that is `GENERATED` in the DB, or derived server-side,
into the request DTO. The client must not be able to write a computed value; if it does, it
conflicts with the computation and it becomes unclear which one is correct.

**[API-09] MUST:** JSON field names are `snake_case`. A Go field `FloorCount` is
`floor_count` in JSON. Inconsistent naming has to be relearned by the frontend every time.

**[API-10] MUST:** A date field that is a **calendar date** is carried as the **string**
`"2006-01-02"`, not `time.Time`.
> **Why:** `time.Time` adds a time zone to the JSON (`"2023-01-09T00:00:00Z"`) and the date
> shifts by a day in the client's time zone. A timestamp (`created_at`), on the other hand,
> is correctly a `time.Time`.

### Dates in a partial update: three states

`*string` cannot distinguish these three states:

```
field absent from the body           -> leave untouched
"suspension_date": null              -> set to NULL (undo the suspension)
"suspension_date": "2024-01-05"      -> update
```

**[API-11] MUST:** Fields that need three states use a type carrying a `Set` flag, embedded
as a **value type**, not a pointer:

```go
type NullableDate struct {
	Value string // "2006-01-02", validated
	Null  bool   // client explicitly sent null
	Set   bool   // the field WAS present in the body
}
```

> **Trap:** when `null` arrives for a *pointer* field, `encoding/json` sets the pointer to
> `nil` and **never calls** `UnmarshalJSON` — the three states collapse back to two and a
> user can never clear a date that was entered wrong. For a value type, `UnmarshalJSON` is
> still called for `null`. Only a test catches this, so write one:
> ```go
> var b struct{ D NullableDate `json:"d"` }
> _ = json.Unmarshal([]byte(`{"d":null}`), &b)
> if !b.D.Set { t.Fatal("UnmarshalJSON was not called for an explicit null") }
> ```

---

## 3. Binding the body with Gin

```go
func (h *ParkingHandler) Create(c *gin.Context) {
	var req dto.ParkingRequest
	// ShouldBindJSON — NOT Bind/BindJSON: the Bind* family writes its own 400 on error
	// and we can't use our own error body ([API-13]) after that.
	if err := c.ShouldBindJSON(&req); err != nil {
		badRequest(c, "could not read request body")
		return
	}
	if strings.TrimSpace(req.Name) == "" {
		badRequest(c, "name is required")
		return
	}
	if req.Latitude == nil || req.Longitude == nil {
		badRequest(c, "latitude and longitude are required")
		return
	}
	if err := pkg.ValidateCoordinates(*req.Latitude, *req.Longitude); err != nil {
		badRequest(c, err.Error())
		return
	}
	// The request's real context is passed, NOT gin.Context [STR-10].
	result, err := h.svc.Create(c.Request.Context(), &req)
	if err != nil {
		writeError(c, err)
		return
	}
	c.JSON(http.StatusCreated, result)
}
```

**[API-12] MUST:** Binding is done with `c.ShouldBindJSON(&req)`.
> **Why not `Bind`/`BindJSON`:** on error, the `Bind*` family terminates the request itself
> with `400` and also overwrites the `Content-Type` header, returning Gin's own shape
> instead of our standard error body (`{"error":true,"message":...}`). The `Should*` family
> hands you the error and lets you write the response yourself.

**[API-12b] MUST:** A Gin handler does not return an `error`; it **writes the error and
`return`s**. Forgetting the `return` lets execution continue and a second response gets
written — this is the single most common mistake made when moving to Gin.

---

## 4. Response shapes

### 4.1 Error body (no exceptions)

```json
{ "error": true, "message": "Access denied: missing required permission" }
```

**[API-13] MUST:** Every error in every service returns this body. `{"err": "..."}`,
`{"detail": ...}`, a plain string — none of these are acceptable.

**[API-14] SHOULD:** Add a machine-readable code for errors the client needs to branch on:
```json
{ "error": true, "code": "DUPLICATE_ORIGINAL_ID", "message": "This record already exists" }
```
`message` is for humans and can change; `code` is the contract and does not change.

**[API-15] MUST:** `message` must be **safe to show the client**. Internal error detail,
table/constraint names, SQL, stack traces, or internal service URLs must never go into it
([GEN-15]).

### 4.2 List response

```json
{
  "data": [ ... ],
  "meta": { "page": 1, "limit": 50, "total_items": 81, "total_pages": 2 }
}
```

**[API-16] MUST NOT:** Double-wrap the response (`data.data`). A list is `data` + `meta`; a
single record is the object directly.

**[API-17] MUST:** `total_items` is the total **after filters are applied**, not the total
row count of the table.

**[API-18] MUST:** `limit` is bounded to **1..200**, default **50**. A value over the limit
is **clamped**, not reset to the default ([STR-18]).

**[API-19] MUST NOT:** An unpaginated list endpoint. "There are only 40 records for now" is
not a justification — record counts grow, and one day the endpoint returns 200 MB.

### 4.3 Single record

```json
{ "id": "…", "name": "…", "floor_count": null, "created_at": "…" }
```
Not wrapped.

---

## 5. Status codes

| Situation | Code |
|---|---|
| Successful read / update / delete | **200** |
| Created | **201** |
| Accepted, will be processed asynchronously | **202** |
| Input error / business rule violation | **400** |
| No identity or invalid identity (access without the gateway, bad API key) | **401** |
| Identity known but no permission | **403** |
| Record not found | **404** |
| Uniqueness conflict | **409** |
| Well-formed but unprocessable content (rare; prefer 400) | **422** |
| Rate limit exceeded | **429** |
| Internal error (masked) | **500** |
| Upstream dependency not responding | **503** |
| Upstream timeout | **504** |

**[API-20] MUST:** 401 and 403 are not confused. 401 = "I don't know who you are",
403 = "I know who you are but you have no permission".

**[API-21] MUST:** A client error never returns 5xx. The most common cause of this is
unvalidated input reaching the DB and producing a driver error — see the error-translation
table in [07-DATABASE.md](07-DATABASE.md).

### Error message contract (across layers)

The repository returns a sentinel error, and the handler translates it to a status code:

```go
var (
	ErrNotFound     = errors.New("not found")     // -> 404
	ErrConflict     = errors.New("conflict")      // -> 409
	ErrInvalidInput = errors.New("invalid input") // -> 400
	ErrInternal     = errors.New("internal")      // -> 500, masked
)

func writeError(c *gin.Context, err error) {
	switch {
	case errors.Is(err, postgres.ErrNotFound):
		c.AbortWithStatusJSON(http.StatusNotFound, pkg.ErrorBody("record not found"))
	case errors.Is(err, postgres.ErrConflict):
		c.AbortWithStatusJSON(http.StatusConflict, pkg.ErrorBody(err.Error()))
	case errors.Is(err, postgres.ErrInvalidInput):
		c.AbortWithStatusJSON(http.StatusBadRequest, pkg.ErrorBody(err.Error()))
	default:
		// Internal error: masked to the client, logged with the FULL detail.
		pkg.Log.Error("unexpected error",
			"path", c.FullPath(), "request_id", requestid.Get(c), "err", err)
		c.AbortWithStatusJSON(http.StatusInternalServerError,
			pkg.ErrorBody("the operation could not be completed"))
	}
}
```

**[API-22] MUST:** Error classification is done with `errors.Is`, never by comparing the
error **message**. Classification tied to message text breaks with the first translation
change.

---

## 6. Idempotency and side effects

**[API-23] MUST:** `GET`, `PUT`, `DELETE` are idempotent. Sending the same request twice
does not move the system into a different state.

**[API-24] MUST:** `GET` **never changes any state.** This includes incrementing a counter
or writing a "last viewed" timestamp. If that's needed, emit an async event instead
([11](11-ASYNC-KAFKA-TEMPORAL.md)).

**[API-25] SHOULD:** For non-repeatable `POST` operations such as payments or stock moves,
support an `Idempotency-Key` header: the key and its result are stored in Redis with a TTL,
and a second request with the same key returns the first result **without doing the
operation again**.
> **Why:** the client retries after a network error. If you don't protect the retry, you
> double-charge, and usually only the customer notices.

---

## 7. Filtering, sorting, field selection

**[API-26] MUST:** Filters are query parameters and are validated against a **whitelist**:
```go
var allowedSort = map[string]string{
	"name":       "name",
	"created_at": "created_at",
}
col, ok := allowedSort[c.Query("sort", "created_at")]
if !ok {
	return badRequest(c, "invalid sort field")
}
```
> Without a whitelist, a `sort` parameter that goes straight into SQL is an injection door.

**[API-27] MUST:** Sorting includes a **unique tie-break**: `ORDER BY created_at DESC, id ASC`.
> **Case:** 1,244 debt records had the same `created_at` from the seed run; because the
> order was unstable, records were both repeated and skipped across pages. A client that
> paged through all of them undercounted the total by 4,800 TL.

**[API-28] SHOULD:** For very large, constantly changing lists, use a **cursor** instead of
`LIMIT/OFFSET`: `?after=<last_id>&limit=50`. `OFFSET` is both slow on deep pages and shifts
when records are inserted in between.

---

## 8. Versioning

**[API-29] MUST:** No breaking changes; new fields are **added**, old fields are **not
removed**. If removal is needed:
1. Add the new field, return both together.
2. Document the old field as `deprecated` and give it a date.
3. **Measure** (log/metric) that clients have moved over, then remove it.

**[API-30] MUST:** If a genuinely breaking change is needed, open a new version prefix at
the gateway (`/api/web/v2`); do not branch on version inside the service.
> **Why:** branching on `if version == 2` inside a service keeps two contracts in one
> codebase, and both end up half tested.

---

## 9. Documentation

**[API-31] MUST:** Every service carries:
- `docs/README.md` — what the service does, its endpoint list, its permission list
- `docs/ui-integration.md` — how the frontend builds its typical flows, with sample
  request/response
- `docs/<Name>.postman_collection.json` — a working collection

**[API-32] MUST:** If an endpoint changes, change the documentation in the same PR.
Documentation that "I'll update later" never gets updated, and wrong documentation is
worse than no documentation.
