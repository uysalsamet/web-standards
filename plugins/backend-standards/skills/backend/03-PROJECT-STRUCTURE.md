# 03 — Project and Service Structure

> Clean Architecture. Goal: separate business rules from infrastructure details, be able
> to write tests without a DB, and let whoever opens a file know what they'll find.
> Code examples are for **Gin v1.12** (`*gin.Context`, explicit timeouts via `http.Server`).

---

## 1. Repo structure

```
<project>/
├── deployments/
│   ├── docker-compose.yml            # the whole ecosystem
│   ├── database-compose.yml          # heavy dependencies in a separate file
│   ├── .env.example                  # variable NAMES only, no values — goes into git
│   ├── .env.local / .env.prod        # real values — do NOT go into git
│   └── .env                          # COMPOSE_PROJECT_NAME only
├── docs/
│   ├── README.md                     # what the system does, service map, port list
│   └── <project>.postman_collection.json
├── services/
│   ├── api-gateway/
│   └── <name>-service/
├── backend-standards/             # this document set
├── go.work
└── go.work.sum
```

**[STR-01] MUST:** Service names follow the `<name>-service` pattern — lower case,
hyphenated. The Go module name matches. `name` is **singular and the domain name**:
`parking-service`, not `parkings-service` or `ParkingSvc`.

**[STR-02] MUST:** Every service has its own `go.mod` and is added to `go.work`. A
service not added there is invisible to the IDE and to `go build ./...` — it silently
does not get built.

---

## 2. Internal service structure

```
services/<name>-service/
├── cmd/
│   └── main.go                       # wiring ONLY
├── deployments/
│   └── Dockerfile
├── docs/
│   ├── README.md                     # what the service does + endpoint list
│   ├── ui-integration.md             # how the frontend should use it
│   └── <Name>Service.postman_collection.json
├── internal/
│   ├── config/
│   │   └── config.go                 # reads env. NOTHING ELSE.
│   ├── dto/
│   │   ├── common.go                 # PaginationMeta, shared types
│   │   └── <module>.go               # per module: Response + Request + UpdateRequest
│   ├── handler/
│   │   ├── common.go                 # Health, Ready, recordID, badRequest, writeError, clampPagination
│   │   └── <module>_handler.go
│   ├── middleware/
│   │   ├── gateway.go                # SetupGlobal + GatewayAuth
│   │   ├── permission.go             # RequirePermission / RequireAny / RequireAll
│   │   └── rbac_log.go               # permission-denial logging
│   ├── repository/
│   │   └── postgres/
│   │       ├── pool.go               # pgxpool setup + settings
│   │       ├── errors.go             # PgError code → client error
│   │       ├── <module>_repository.go # interface + implementation
│   │       └── migrations/           # goose: 00001_x.sql, 00002_y.sql
│   ├── routes/
│   │   ├── routes.go                 # a single Setup function
│   │   └── routes_test.go            # routing + RBAC + validation tests
│   └── service/
│       └── <module>_service.go       # interface + implementation
├── pkg/
│   ├── logger.go                     # slog setup
│   ├── response.go                   # error/success body
│   └── validator.go                  # ValidateUUID, required, maxLen, nonNegative
├── go.mod
└── go.sum
```

**[STR-03] MUST:** Business logic lives under `internal/`. `pkg/` is only for truly
generic helpers that carry no domain knowledge.
> **Why:** `internal/` is enforced by Go — no other module can import it. A business
> rule placed in `pkg/` unknowingly becomes a dependency of other services.

**[STR-04] MUST:** One module = one table = one dto + one repository + one service +
one handler file.

**[STR-05] MUST:** A single file does not exceed **500 lines**. If it does, split the
module.
> **Why:** Whoever (or whichever AI) edits a 500-line file cannot hold the whole file in
> context and ends up breaking an unrelated part. This is not a style preference, it is
> a matter of error rate.

**[STR-06] MUST:** The `repository/postgres/` subdirectory is used; files do not sit
flat directly under `repository/`. If Redis/Mongo is added later, it sits side by side.

---

## 3. Layer contract

```
        HTTP request
             │
    ┌────────▼────────┐
    │    handler      │  Knows HTTP. Validates input, produces status/JSON.
    │                 │  NO BUSINESS RULES. NO SQL.
    └────────┬────────┘
             │  DTO + context.Context
    ┌────────▼────────┐
    │    service      │  Applies business rules, transforms data, computes pagination meta.
    │   (interface)   │  Does NOT KNOW gin.Context. Does NOT KNOW SQL.
    └────────┬────────┘
             │  DTO / domain type
    ┌────────▼────────┐
    │   repository    │  Data access. Parameterised SQL, scan, error translation.
    │   (interface)   │  Does NOT KNOW HTTP. Does NOT KNOW BUSINESS RULES.
    └────────┬────────┘
             │
        Postgres / Redis
```

**[STR-07] MUST:** Dependencies flow in one direction only. An import in the reverse
direction does not fail the build, but it destroys the architecture — this is caught in
code review.

**[STR-08] MUST:** `service` and `repository` are defined as **interfaces**, with the
implementation unexported:

```go
type ParkingService interface {
	List(ctx context.Context, p Page) (*dto.ParkingList, error)
	GetByID(ctx context.Context, id string) (*dto.Parking, error)
	Create(ctx context.Context, req *dto.ParkingRequest) (*dto.Parking, error)
	Update(ctx context.Context, id string, req *dto.ParkingUpdateRequest) (*dto.Parking, error)
	Delete(ctx context.Context, id string) error
}

type parkingService struct{ repo postgres.ParkingRepository }

func NewParkingService(repo postgres.ParkingRepository) ParkingService {
	return &parkingService{repo: repo}
}
```

> **Why an interface:** it's the only way to write tests without a DB. A constructor
> that returns a concrete struct makes every test depend on Postgres and stretches the
> test suite out to minutes.

**[STR-09] MUST:** Every layer function has **`context.Context` as its first
parameter**. The only exception is pure transformation functions that do no IO.

**[STR-10] MUST:** The handler does not **pass** `*gin.Context` down to the layer below;
it extracts `c.Request.Context()` from it and passes that instead.
```go
// CORRECT — the service doesn't know about HTTP, it gets the real request context
result, err := h.svc.Create(c.Request.Context(), &req)

// FORBIDDEN — passing gin.Context to the service is a layer violation
result, err := h.svc.Create(c, &req)
```
> **Why:** `*gin.Context` is an HTTP transport object; the actual cancellation/timeout
> information lives in `c.Request.Context()`. Also, if passed into the service layer,
> the service becomes coupled to Gin and can no longer be tested without a DB.

---

## 4. `cmd/main.go` — wiring only

**Belongs here:** logger → config → DB → migration → repo/service/handler setup → router →
routes → listen → graceful shutdown.
**Does not belong here:** SQL, business rules, handler bodies, middleware definitions.

```go
package main

import (
	"context"
	"errors"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/gin-gonic/gin"

	"<name>-service/internal/config"
	"<name>-service/internal/handler"
	"<name>-service/internal/repository/postgres"
	"<name>-service/internal/routes"
	"<name>-service/internal/service"
	"<name>-service/pkg"
)

// Filled in at build time via -ldflags [OPS-01].
var (
	version = "dev"
	commit  = "unknown"
)

func main() {
	log := pkg.InitLogger(os.Getenv("LOG_LEVEL"), "<name>-service", version)
	cfg := config.Load()

	// A separate context for startup work: if it can't connect within 30s, don't start.
	bootCtx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	pool, err := postgres.NewPool(bootCtx, cfg)
	if err != nil {
		log.Error("failed to connect to the database", "err", err)
		os.Exit(1)
	}
	defer pool.Close()

	// Migration failure is FATAL: if the schema isn't there, the service can't run anyway [DB-15].
	if err := postgres.Migrate(bootCtx, cfg.DSN()); err != nil {
		log.Error("migration failed", "err", err)
		os.Exit(1)
	}

	parkingRepo := postgres.NewParkingRepository(pool)
	parkingSvc := service.NewParkingService(parkingRepo)
	parkingH := handler.NewParkingHandler(parkingSvc)

	// ReleaseMode: debug logs and colored output are disabled in production.
	gin.SetMode(gin.ReleaseMode)
	// gin.New() — NOT gin.Default(): Default adds its own Logger, we use slog.
	r := gin.New()
	// Let c.Done()/c.Err()/c.Value() calls defer to Request.Context().
	// When this is off, c.Done() returns nil and the cancellation signal is silently lost.
	r.ContextWithFallback = true

	routes.Setup(r, cfg, parkingH)

	// Timeouts live on http.Server: Gin has no listener configuration of its own,
	// and that's fine — the settings live in one known place [RES-07].
	srv := &http.Server{
		Addr:              ":" + cfg.ServerPort,
		Handler:           r,
		ReadHeaderTimeout: 5 * time.Second,  // first line of defence against slowloris
		ReadTimeout:       15 * time.Second,
		WriteTimeout:      30 * time.Second,
		IdleTimeout:       60 * time.Second,
		MaxHeaderBytes:    1 << 20, // 1 MB
	}

	go func() {
		log.Info("service listening", "port", cfg.ServerPort, "version", version, "commit", commit)
		// ErrServerClosed is a normal shutdown, not an error.
		if err := srv.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
			log.Error("listen failed", "err", err)
			os.Exit(1)
		}
	}()

	quit := make(chan os.Signal, 1)
	signal.Notify(quit, os.Interrupt, syscall.SIGTERM)
	<-quit

	log.Info("shutting down, waiting for open requests")
	// Order matters [RES-20]: new requests stop being accepted first, and open ones finish...
	shutdownCtx, shutdownCancel := context.WithTimeout(context.Background(), cfg.ShutdownGrace)
	defer shutdownCancel()
	if err := srv.Shutdown(shutdownCtx); err != nil {
		log.Error("graceful shutdown did not complete", "err", err)
	}
	// ...and only AFTER that are dependencies closed (defer pool.Close() applies here).
	log.Info("shut down")
}
```

**[STR-11] MUST:** `main.go` does not exceed 150 lines. If it does, it's doing something
beyond wiring.

**[STR-12] MUST:** On startup errors, use `os.Exit(1)`. Do not exit via `panic` — the
stack trace noise makes diagnosis harder; a meaningful message is enough.

**[STR-13] MUST:** `gin.New()` is used, `gin.Default()` is **not**.
> **Why:** `gin.Default()` adds its own `Logger()` middleware; combined with our
> structured slog logging this produces double logging ([OBS-08]). We add Recovery
> explicitly ourselves ([RES-18]).

**[STR-14] MUST:** `r.ContextWithFallback = true` is set.
> **Why:** When this is off, `c.Done()` returns `nil`; a `select { case <-c.Done(): }`
> never fires, and the work silently continues after the client has closed the
> connection ([GEN-17]).

---

## 5. `internal/config/config.go` — reads env only

```go
package config

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

type Config struct {
	ServiceName    string
	ServerPort     string
	DBHost         string
	DBPort         string
	DBUser         string
	DBPassword     string
	DBName         string
	DBSSLMode      string
	DBMaxConns     int32
	APISecurityKey string        // shared secret with the gateway
	LogLevel       string
	ShutdownGrace  time.Duration
}

func Load() *Config {
	return &Config{
		ServiceName:    getEnv("SERVICE_NAME", "<name>-service"),
		ServerPort:     getEnv("<NAME>_SERVICE_PORT", "3300"),
		DBHost:         getEnv("DB_HOST", "localhost"),
		DBPort:         getEnv("DB_PORT", "5432"),
		DBUser:         getEnv("DB_USER", "postgres"),
		DBPassword:     getEnv("DB_PASSWORD", ""),   // the default is NEVER a real secret
		DBName:         getEnv("DB_NAME", "app_db"),
		DBSSLMode:      getEnv("DB_SSLMODE", "disable"),
		DBMaxConns:     int32(getEnvInt("DB_MAX_CONNS", 10)),
		APISecurityKey: getEnv("API_SECURITY_KEY", ""),
		LogLevel:       getEnv("LOG_LEVEL", "info"),
		ShutdownGrace:  time.Duration(getEnvInt("SHUTDOWN_GRACE_SEC", 20)) * time.Second,
	}
}

// The DSN is the single source. Do not build a DSN by hand elsewhere: otherwise an env
// var like DB_SSLMODE can silently have no effect and "I set it but it's not working"
// gets debugged for hours.
func (c *Config) DSN() string {
	return fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=%s",
		c.DBUser, c.DBPassword, c.DBHost, c.DBPort, c.DBName, c.DBSSLMode)
}

func getEnv(key, def string) string {
	if v, ok := os.LookupEnv(key); ok {
		return v
	}
	return def
}

func getEnvInt(key string, def int) int {
	if v, ok := os.LookupEnv(key); ok {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
		// Don't silently swallow a malformed value: a mistyped env var falling back to
		// the default creates the illusion that "the setting is in effect."
		panic(fmt.Sprintf("config: %s must be a number, got: %q", key, v))
	}
	return def
}
```

**[STR-15] MUST:** The `config` package does not connect to a DB, does not write logs,
and does not validate. It only reads env.

**[STR-16] MUST:** In-code defaults are **only for local development**. Secret fields
default to an empty string, and the service refuses to start in production if it is
empty:

```go
// A missing secret in production must never silently mean "checks are off."
if cfg.APISecurityKey == "" && os.Getenv("APP_ENV") == "production" {
	log.Error("API_SECURITY_KEY is required"); os.Exit(1)
}
```

**[STR-17] MUST NOT:** Log the config struct with `%+v` — it dumps the password into the
log.

---

## 6. `internal/handler/common.go` — shared helpers

```go
package handler

import (
	"net/http"
	"strconv"

	"github.com/gin-gonic/gin"

	"<name>-service/pkg"
)

// recordID — is :id really a UUID? If not, write 400 and return handled=true.
// A fabricated id must not go straight to Postgres and produce a 500: that would be a
// client error.
func recordID(c *gin.Context, param string) (id string, handled bool) {
	id, err := pkg.ValidateUUID(c.Param(param))
	if err != nil {
		badRequest(c, "invalid record ID")
		return "", true
	}
	return id, false
}

// AbortWithStatusJSON: subsequent handlers should NOT run. A plain c.JSON lets the
// chain continue and a second response ends up being attempted.
func badRequest(c *gin.Context, msg string) {
	c.AbortWithStatusJSON(http.StatusBadRequest, pkg.ErrorBody(msg))
}

// clampPagination — the SINGLE source for the pagination rule. Both the repository and
// the meta use this. An out-of-range limit is CLAMPED, not reset to the default: if it
// were reset, the returned record count and the meta would diverge, and a client paging
// through all pages would collect incomplete data.
func clampPagination(c *gin.Context) (page, limit, offset int) {
	page, _ = strconv.Atoi(c.DefaultQuery("page", "1"))
	limit, _ = strconv.Atoi(c.DefaultQuery("limit", "50"))
	if page < 1 {
		page = 1
	}
	if limit < 1 {
		limit = 50
	}
	if limit > 200 {
		limit = 200
	}
	return page, limit, (page - 1) * limit
}
```

**[STR-18] MUST:** The pagination rule lives in **a single function**. Both the
repository and the meta calculation call the same function.
> **Case:** The repository said "if out of range, fall back to the default," the DTO
> said "if out of range, clamp." For `?limit=500`, the query returned 50 records but the
> meta reported `limit=200, total_pages=7`. A client trusting the `meta` and collecting
> all pages saw only **a quarter** of 1,246 records, and KPI totals were off by that same
> proportion.

**[STR-19] MUST:** Use `c.AbortWithStatusJSON` when writing an error, not `c.JSON`.
> **Why:** In Gin, `c.JSON` does not stop the chain; the next middleware/handler keeps
> running and a second response gets attempted, producing a "headers already written"
> warning.

---

## 7. `internal/routes/routes.go`

```go
func Setup(r *gin.Engine, cfg *config.Config, parkingH *handler.ParkingHandler) {
	middleware.SetupGlobal(r, cfg)   // recover + requestid + slog + metrics + body limit

	// /health and /ready are unauthenticated: called by the gateway and container healthchecks.
	r.GET("/health", handler.Health)
	r.GET("/ready", handler.Ready)

	// No api/v1 prefix — the platform/version prefix is managed by the gateway [API-03].
	// The group middleware is taken EXPLICITLY.
	p := r.Group("/parkings", middleware.GatewayAuth(cfg))
	{
		// The list endpoint is NOT a separate path, it's at the resource root: /parkings?page=&limit= [API-01].
		p.GET("", middleware.RequirePermission("parking.view"), parkingH.List)
		p.GET("/:id", middleware.RequirePermission("parking.view"), parkingH.GetByID)
		p.POST("", middleware.RequirePermission("parking.create"), parkingH.Create)
		p.PUT("/:id", middleware.RequirePermission("parking.update"), parkingH.Update)
		p.DELETE("/:id", middleware.RequirePermission("parking.delete"), parkingH.Delete)
	}
}
```

**[STR-20] MUST:** A single `Setup` function. Route definitions are not scattered across
handler files — the question "does this endpoint have a permission check" must be
answerable by looking at one file.

**[STR-21] MUST:** The list endpoint sits at the resource root (`GET /parkings`), not
`/parkings/list`. If a fixed path is needed (`/export`, `/map`), it is defined as a
**sibling** of `/:id`, with the static one written **first**.
> **Why:** Gin's radix router has supported static + parameter sibling routes since
> v1.7, meaning `/parkings/export` and `/parkings/:id` work together. But this was
> historically an area that produced panics, and there are still corner cases in
> trailing-slash redirection. The safest path is to use the resource root for the list
> and never create the ambiguity in the first place. Bonus: `GET /parkings` is also more
> correct REST.

**[STR-22] MUST:** Each group takes its own middleware explicitly in its own
definition. Setups that are order-sensitive, assuming "I already called `Use` above,"
are not allowed — the next person who adds a route in between silently opens an
unprotected endpoint.

---

## 8. Comment-writing rule

**[STR-23] MUST:** A comment explains **"why," not "what."** If what the code does isn't
clear from reading it, the fix is not a comment, it's a better name.

Good:
```go
// floor_count is deliberately not COALESCE'd: NULL means "unknown," and the source also
// has genuine 0 values, and the two must not be confused.

// (0,0) is rejected: Null Island is in the Gulf of Guinea, never a valid value in our
// dataset. If accepted, the record silently gets moved outside the map.
```

Bad:
```go
// validates id
func validateID(id string) error
```

**[STR-24] SHOULD:** If you deliberately did not choose an alternative, write that down.
Six months from now, this comment is the only thing that will stop someone from
"improving" the code back to that alternative. For major decisions, write a decision
record under `adr/` instead of a comment.
