# 05 — Security

> Core principle: **every layer defends itself.** "The gateway already checks it" is not
> a security justification — find one path that bypasses the gateway and the whole system
> is open.

---

## 1. Security boundaries

```
  Browser / mobile
        │  HTTPS, JWT
  ┌─────▼──────────────────────────────────────────┐
  │  API GATEWAY  (the single external door)       │
  │  · TLS termination      · JWT validation       │
  │  · Rate limit           · CORS                 │
  │  · STRIPS incoming X-User-* headers and         │
  │    REWRITES them with its own verified values   │
  └─────┬──────────────────────────────────────────┘
        │  internal network · X-Gateway-Source + X-API-Key + X-User-Permissions
  ┌─────▼──────────┐  ┌────────────────┐  ┌────────────────┐
  │  service A     │  │  service B     │  │  service C     │
  │  own check     │  │  own check     │  │  own check     │
  └────────────────┘  └────────────────┘  └────────────────┘
```

**[SEC-01] MUST:** Services do not expose ports to the outside world. Compose uses
`expose:`, not `ports:`; the gateway is the only component with a `ports:` entry.

**[SEC-02] MUST:** TLS terminates at the gateway (or the reverse proxy in front of it).
Internal traffic can be plain HTTP, but the internal network is **not considered
trusted** ([SEC-04]).

**[SEC-03] MUST:** JWTs are parsed and validated **only by the gateway**. Services don't
even import a JWT library.
> **Why:** if JWT validation is duplicated in 30 places, one of them eventually skips the
> `alg=none` check or the expiry check. Keeping it in one, well-tested place prevents that.

---

## 2. Service-side identity and permissions

**[SEC-04] MUST:** A service assumes the gateway exists but does **not trust** it. It runs
its own check on every request:

```go
func GatewayAuth(cfg *config.Config) gin.HandlerFunc {
	return func(c *gin.Context) {
		if c.GetHeader("X-Gateway-Source") != "api-gateway" {
			// AbortWithStatusJSON: the chain MUST STOP. A plain c.JSON still lets the
			// handler run afterwards.
			c.AbortWithStatusJSON(http.StatusForbidden,
				pkg.ErrorBody("access denied: requests are only accepted through the gateway"))
			return
		}
		// Do NOT skip the check when the secret is empty — an empty secret in
		// production means "the door is open."
		if cfg.APISecurityKey == "" {
			pkg.Log.Error("API_SECURITY_KEY is undefined, request rejected")
			c.AbortWithStatusJSON(http.StatusUnauthorized,
				pkg.ErrorBody("service configuration is missing"))
			return
		}
		// Constant-time comparison: length/early-exit timing must not leak information.
		if subtle.ConstantTimeCompare(
			[]byte(c.GetHeader("X-API-Key")), []byte(cfg.APISecurityKey)) != 1 {
			c.AbortWithStatusJSON(http.StatusUnauthorized,
				pkg.ErrorBody("access denied: invalid API key"))
			return
		}
		c.Next()
	}
}
```

> **Watch out — a common mistake:** `if cfg.APISecurityKey != "" && c.Get(...) != key`.
> This form **completely disables** the check if the env var is forgotten, with no
> warning at all. If the check is ever meant to be skipped, that must be a deliberate,
> logged decision.

**[SEC-05] MUST:** Permission checks come from the `X-User-Permissions` header, and every
endpoint requires a permission ([GEN-10]):

```go
p.POST("", middleware.RequirePermission("parking.create"), h.Create)
```

**[SEC-06] MUST:** Permission key format is `<module>.<action>`, snake_case, a
**singular** module name: `parking.view`, `market_stall.create`. The string in the
service and the string in the permission definition are **identical**.

**[SEC-07] MUST:** Wildcard support: `*` = everything (superadmin), `module.*` = all of
that module. A wildcard **does not cross module boundaries** — `a_module.*` cannot reach
`b_module` endpoints. This is verified with a test ([TEST-04]).

**[SEC-08] MUST NOT:** Fail-open. When the permission source (Redis, permission service,
DB) goes down, access **narrows**:
```go
// WRONG — everyone becomes admin when the dependency goes down
perms, err := fetchPermissions(ctx, userID)
if err != nil { return c.Next() }

// CORRECT — reject when unknown
perms, err := fetchPermissions(ctx, userID)
if err != nil {
	pkg.Log.Error("could not fetch permissions, request rejected", "err", err)
	c.AbortWithStatusJSON(http.StatusServiceUnavailable, pkg.ErrorBody("permission check failed"))
	return
}
```

**[SEC-09] MUST:** Every permission denial is logged in structured form: `reason`,
`required`, `user_id`, `path`, `method`, `request_id`. The count of rejected requests is
a metric ([OBS-13]) — a sudden spike is either an attack or a broken deploy.

**[SEC-10] MUST:** The gateway **strips** any `X-User-*` and `X-Gateway-*` headers coming
from the client and rewrites them with its own verified values.
> **Why:** otherwise a client can send `X-User-Permissions: *` and become superadmin.
> This is the single most critical point in this architecture; testing it at the gateway
> is mandatory.

**[SEC-11] SHOULD:** Record ownership checks are **separate** from permissions. A user
with `parking.update` permission must not be able to update **someone else's** record;
narrow the query with `WHERE id = $1 AND owner_id = $2`.
> **Why:** role-based permission says "can update this kind of record," not "this
> specific record." Most IDOR vulnerabilities come from exactly this gap.

---

## 3. Input validation

**[SEC-12] MUST:** Validation happens in the handler, done by hand with shared helpers
(`pkg/validator.go`). No validation library is used ([VER-05]).

**Minimum checklist for every write endpoint:**

| Check | Why |
|---|---|
| Is a required string empty/whitespace | If `"   "` isn't treated as empty, meaningless rows enter the DB |
| Is the UUID parameter valid | A made-up id going straight to Postgres produces **500**, but this is a client error |
| Is a numeric field negative | A negative capacity/amount silently breaks a business rule |
| Does text exceed the `VARCHAR(n)` limit | Exceeding it causes a driver error → **500**, but it should be **400** |
| Is an enum/sort field on the whitelist | Otherwise: injection and unexpected branching |
| Is the query parameter valid UTF-8 | A client sending Latin-5 crashes Postgres with a 500 |
| Logical consistency | e.g. `occupied > total`, `end_date < start_date` |
| Is the coordinate within bounds, and not `(0,0)` | See [APPENDIX-GIS-POSTGIS.md](APPENDIX-GIS-POSTGIS.md) |

```go
// VARCHAR limits from the schema — MUST stay in sync with the migration file.
const (
	maxNameLen         = 255
	maxNeighborhoodLen = 100
)

func maxLen(c *gin.Context, field string, value *string, limit int) (handled bool) {
	// []rune: byte length is misleading for text containing "ğüşiöç" and rejects
	// valid input.
	if value != nil && len([]rune(*value)) > limit {
		badRequest(c, field+" cannot exceed "+strconv.Itoa(limit)+" characters")
		return true
	}
	return false
}
```

**[SEC-12b] MUST NOT:** Using struct tags like `binding:"required,max=255"` for
validation.
> **Why:** `go-playground/validator` already ships with Gin, so this isn't about an
> extra dependency. The issue is that `required` **treats a value type's zero value as
> "missing"** — meaning `latitude: 0` gets the same treatment as "latitude was not sent."
> This is the exact opposite of the standard's pointer/three-state design
> ([API-06], [API-07], [API-11]). Details:
> [adr/0007-input-validation.md](adr/0007-input-validation.md).

**[SEC-13] MUST:** The length limit is enforced at **two layers**: an explicit check in
the handler (layer 1), and `VARCHAR(n)` plus driver error translation in the schema
(layer 2). If one layer is bypassed, the other catches it.

**[SEC-14] MUST:** Validation guarantees that **a rejected request never reaches the
service layer**. In tests, the stub carries a `reached bool` and this is asserted
([TEST-06]).

---

## 4. SQL and injection

**[SEC-15] MUST:** Values are **always** passed as parameters.

```go
// CORRECT — only the $1/$2 PLACEHOLDER NUMBERS are computed, the value is a parameter
query := fmt.Sprintf(`SELECT %s FROM parkings %s ORDER BY name, id LIMIT $%d OFFSET $%d`,
	parkingColumns, where, len(args)+1, len(args)+2)
rows, err := r.pool.Query(ctx, query, append(args, limit, offset)...)

// FORBIDDEN — never do this
query := fmt.Sprintf(`SELECT * FROM parkings WHERE name = '%s'`, userInput)
```

**[SEC-16] MUST:** A dynamic column/table name comes from a **whitelist**, never from the
client ([API-26]). A parameter can only substitute for a value; a column name cannot be
parameterized.

**[SEC-17] MUST NOT:** Return a raw driver error to the client — table, column, and
constraint names leak and hand the attacker a schema map. Translation table:
[07-DATABASE.md](07-DATABASE.md).

---

## 5. Secret management

**[SEC-18] MUST NOT:** A secret ever goes into code, a Dockerfile, `docker-compose.yml`,
or git. Compose only knows the **variable name**:
```yaml
environment:
  DB_PASSWORD: ${DB_PASSWORD}     # no value, just a reference
```

**[SEC-19] MUST NOT:** `getEnv("DB_PASSWORD", "Secret123")` — a default is never a real
secret. Secret fields default to an empty string.

**[SEC-20] MUST:** `.gitignore` includes `.env`, `.env.local`, `.env.prod`, `*.pem`,
`*.key`. If the repo has no `.gitignore`, creating one is the **first task**.

**[SEC-21] MUST:** `.env.example` is committed to git: variable names are there, values
are placeholders. This is where a new developer learns which env vars are required.

**[SEC-22] MUST:** If a secret got into git, **rotate** it. Reverting the commit is not
enough — it stays in git history and possibly in several clones. Change the secret.

**[SEC-23] SHOULD:** Use Docker secrets / Vault / a cloud secret manager for production
secrets. An env variable can show up in `docker inspect` and the process list.

**[SEC-24] MUST:** The `API_SECURITY_KEY` shared between services is at least 32 random
bytes and **differs** across environments (dev ≠ staging ≠ prod).

---

## 6. Logging and data leakage

**[SEC-25] MUST NOT:** Log passwords, tokens, API keys, JWTs, credit card numbers, TCKN
(the Turkish national identity number), or full emails/phone numbers.

**[SEC-26] MUST NOT:** Log a config or request struct with `%+v` / `%#v` — it prints any
secrets inside it too.

**[SEC-27] MUST:** Mask personal data when it must be logged: log the `user_id` (UUID),
not the email. If logging it is unavoidable, mask it as `a***@example.com`.

**[SEC-28] MUST:** The error log is **full**, the error response is **masked**. Don't mix
the two:
```go
pkg.Log.Error("query failed", "table", "parkings", "err", err)   // log: full detail
return c.Status(500).JSON(pkg.ErrorBody("operation could not be completed"))  // response: masked
```

---

## 7. HTTP security headers

**[SEC-29] MUST:** The gateway adds these headers:

| Header | Value | What it's for |
|---|---|---|
| `Strict-Transport-Security` | `max-age=31536000; includeSubDomains` | Downgrade-to-HTTP attacks |
| `X-Content-Type-Options` | `nosniff` | MIME sniffing |
| `X-Frame-Options` | `DENY` | Clickjacking |
| `Referrer-Policy` | `strict-origin-when-cross-origin` | URL leakage |
| `Content-Security-Policy` | `default-src 'none'` for an API | No script execution in a JSON response |

**[SEC-30] MUST NOT:** Headers that reveal the server/framework version. Go's `net/http`
doesn't produce a `Server` header; **don't add one** by hand. At the gateway, strip any
`Server` and `X-Powered-By` headers coming from the upstream.

---

## 8. CORS — whose responsibility is it?

CORS is a **browser** mechanism: it only matters at the address the browser talks to
**directly**. The question isn't "should this service do CORS," it's **"does the browser
call this service directly."**

| | Service behind the gateway (default) | Directly accessed service (exception) |
|---|---|---|
| Example | All business services | Tile/static services, CDN-like endpoints |
| Does the browser call it directly? | **No** | **Yes** |
| **CORS** | **NONE** — the gateway handles it | **YES** — it sets its own origin |
| **GatewayAuth** | **YES** | **NO** — the request isn't coming from the gateway |

**[SEC-31] MUST NOT:** Put CORS middleware on a service that sits behind the gateway.
> **Why:** the browser never sees the service's address; the `access-control-*` headers
> it produces never reach the browser. It's dead code and creates the illusion that "a
> security check exists here." The middleware, the env variable, and the config field
> are **all part of the same decision** — leaving half of it in place is also dead code.

**[SEC-32] MUST NOT:** Put `GatewayAuth` on a directly accessed service — no request will
ever pass, because requests genuinely don't come from the gateway. These services are
protected at the network level (IP restriction, reverse proxy) or with their own token.

**[SEC-33] MUST NOT:** Combine `AllowOrigins: "*"` with `AllowCredentials: true`. This
combination is already invalid; use an explicit origin list
(`gin-contrib/cors` → `AllowOrigins []string`).

---

## 9. Dependency and supply chain security

**[SEC-34] MUST:** `govulncheck ./...` runs in CI; the build is red if a known
vulnerability is found ([CI-15]).

**[SEC-35] MUST:** `go.sum` is committed and the build uses `-mod=readonly`.

**[SEC-36] MUST:** Docker images are pinned ([VER-09]); `latest` is never used. The base
image is updated regularly — most container vulnerabilities come from outdated packages
in the base image.

**[SEC-37] SHOULD:** Image scanning (Trivy/Grype) runs in CI; HIGH/CRITICAL findings
block the merge.

**[SEC-38] MUST:** `tools/check-secrets.sh` runs in CI ([CI-26]). The pipeline breaks on
a critical finding. The tool **only detects**: it does not delete files, clean history,
or rotate secrets. Those are human decisions.
> **Why:** [SEC-20] requires `.gitignore`, [SEC-22] requires rotation, [CI-19] forbids
> writing secrets into the pipeline — but none of it was actually **checked**. That
> contradicts the standard's own principle ([TOOL-03]): a rule that can be caught
> mechanically must not be left to code review.
> Concrete evidence: in a frontend repo of the same organization, `.env` and `.env.prod`
> are currently **tracked** by git, meaning the values inside them are already in the
> commit history.
> The reason the tool doesn't auto-fix anything: deleting a leaked secret from a file
> doesn't remove it from history, and deleting it without rotating it just hides the
> problem instead of solving it.


---

## 10. NEVER DO THIS — security

- ❌ Exposing an endpoint without a permission check
- ❌ Fail-open permission logic
- ❌ Trusting a client-supplied `X-User-*` header
- ❌ Building SQL by concatenating a value with `fmt.Sprintf`
- ❌ Returning a raw driver error to the client
- ❌ An internal service URL, port, or stack trace in an error message
- ❌ Putting a secret in code / a Dockerfile / compose / git
- ❌ Logging a password, token, or personal data
- ❌ Putting CORS on a service behind the gateway, or GatewayAuth on a tile service
- ❌ `AllowOrigins: "*"` + `AllowCredentials: true`
- ❌ Sequential int PKs (IDOR)
- ❌ Silently skipping a check when the secret is empty
- ❌ Confusing ownership checks with role-based permissions
