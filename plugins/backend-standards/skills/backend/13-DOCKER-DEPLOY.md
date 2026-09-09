# 13 — Docker and Deploy

---

## 1. Dockerfile

**[OPS-01] MUST:** Multi-stage build. The final image has no compiler, source code, or git.

```dockerfile
# ---------- build ----------
FROM golang:1.25-alpine AS builder

WORKDIR /app

# Dependencies in a separate layer: go mod download shouldn't rerun when source changes.
COPY services/<name>-service/go.mod services/<name>-service/go.sum ./
RUN go mod download

COPY services/<name>-service/cmd ./cmd
COPY services/<name>-service/internal ./internal
COPY services/<name>-service/pkg ./pkg

# CGO_ENABLED=0: static binary, no glibc dependency on alpine.
# -s -w: strip symbol and debug info, image shrinks by ~30 %.
# Version info is embedded in the binary; the /version endpoint returns it [OBS-19].
ARG VERSION=dev
ARG COMMIT=unknown
RUN CGO_ENABLED=0 GOOS=linux go build \
    -trimpath \
    -ldflags="-s -w -X main.version=${VERSION} -X main.commit=${COMMIT}" \
    -o /app/service ./cmd/main.go

# ---------- runtime ----------
FROM alpine:3.24

# ca-certificates: for outbound HTTPS calls. wget: for HEALTHCHECK.
RUN apk add --no-cache ca-certificates wget tzdata \
 && adduser -D -u 10001 appuser

WORKDIR /app

COPY --from=builder --chown=appuser:appuser /app/service ./service
# Migration SQL files MUST go into the image, otherwise the service can't set up the schema.
COPY --from=builder --chown=appuser:appuser /app/internal/repository/postgres/migrations ./migrations

USER appuser
EXPOSE 3300

HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://localhost:3300/health || exit 1

CMD ["./service"]
```

**[OPS-02] MUST:** Base images are pinned ([VER-09]); `latest` is forbidden.

**[OPS-03] MUST:** The container runs as **non-root** (`USER appuser`).
> **Why:** Container-escape exploits grant host access when the container runs as root.
> Non-root is the cheapest and most effective container hardening measure.

**[OPS-04] MUST:** `HEALTHCHECK` is defined and calls the `/health` endpoint. `start-period`
is set; otherwise a slowly starting service gets stamped "unhealthy" before it's even up.

**[OPS-05] MUST:** The `EXPOSE` value is the service's **actual** port. A port left stale
by copy-paste won't break anything, but it misleads the reader.

**[OPS-06] MUST:** A `.dockerignore` is present:
```
.git
.env*
**/*_test.go
docs/
*.md
```
> The smaller the build context, the faster the build; it also prevents the `.env` file
> from accidentally ending up in the image.

**[OPS-07] MUST NOT:** Copy secrets into the image. Even a secret passed via `ARG`
**stays in the image layers** and can be read with `docker history`.

**[OPS-08] SHOULD:** Target a final image size **< 30 MB**. If it's much bigger, source code
or unnecessary packages have probably ended up in it.

---

## 2. Compose

```yaml
services:
  <name>-service:
    build:
      context: ../
      dockerfile: services/<name>-service/deployments/Dockerfile
      args:
        VERSION: ${VERSION:-dev}
        COMMIT: ${COMMIT:-unknown}
    container_name: app-<name>-service
    restart: unless-stopped
    # expose, NOT ports: the service is not exposed externally, only reachable from the
    # internal network [SEC-01].
    expose:
      - "${<NAME>_SERVICE_PORT:-3300}"
    environment:
      SERVICE_NAME: <name>-service
      <NAME>_SERVICE_PORT: ${<NAME>_SERVICE_PORT:-3300}
      DB_HOST: ${DB_HOST}
      DB_PORT: ${DB_PORT}
      DB_USER: ${DB_USER}
      DB_PASSWORD: ${DB_PASSWORD}        # no value, only a reference [SEC-18]
      DB_NAME: ${DB_NAME}
      DB_MAX_CONNS: ${DB_MAX_CONNS:-10}
      API_SECURITY_KEY: ${API_SECURITY_KEY}
      LOG_LEVEL: ${LOG_LEVEL:-info}
      GOMEMLIMIT: 200MiB                 # ~80 % of the limit [PERF-06]
    depends_on:
      postgres:
        condition: service_healthy       # not just "started", but "ready"
    deploy:
      resources:
        limits:
          memory: 256M
          cpus: "0.5"
        reservations:
          memory: 128M
    logging:
      driver: json-file
      options:
        max-size: "10m"                  # so the disk doesn't fill up
        max-file: "3"
    networks:
      - app_network

networks:
  app_network:
    driver: bridge
```

**[OPS-09] MUST:** Only the gateway opens `ports:`. Every other service uses `expose:`.

**[OPS-10] MUST:** `depends_on` is used with **`condition: service_healthy`**. Plain
`depends_on` only means "the container has started"; Postgres may not yet be accepting connections.

**[OPS-11] MUST:** Every service gets a memory/CPU limit ([PERF-04]).

**[OPS-12] MUST:** Log rotation is configured (`max-size`, `max-file`). A json-file log
driver left unconfigured fills the disk and **takes down the whole host**.

**[OPS-13] SHOULD:** Heavy dependencies (Postgres, Kafka, Temporal, Grafana) are kept in a
separate compose file; a developer only brings up what they need.

---

## 3. Env management

**[OPS-14] MUST — Layers:**

| Layer | Location | Purpose |
|---|---|---|
| In-code default | `config.go` → `getEnv(key, default)` | **Local development only** |
| Compose variable | `docker-compose.yml` → `${VAR}` | Which env reaches the container |
| Actual value | `.env.local` / `.env.prod` | Supplied externally at run time |
| Compose identity | `deployments/.env` | Only `COMPOSE_PROJECT_NAME` |

```bash
# Development
docker compose --env-file .env.local -f docker-compose.yml up -d --build
# Production
docker compose --env-file .env.prod  -f docker-compose.yml up -d --build
```

**[OPS-15] MUST:** When adding a new service, two lines are added to **both**
`.env.local` **and** `.env.prod` **and** `.env.example`:
```bash
<NAME>_SERVICE_PORT=3300                                  # UNIQUE across the whole repo
<NAME>_SERVICE_URL=http://app-<name>-service:3300         # internal URL the gateway reaches
```

**[OPS-16] MUST:** Port collisions are forbidden. A new service takes the next free range
after checking the existing `.env.local`. The list of ports in use is kept in `docs/README.md`.

**[OPS-17] MUST:** `.env*` is not committed to git ([SEC-20]); `.env.example` is ([SEC-21]).

---

## 4. Gateway integration

A service is useless on its own. The gateway has **two layers**, and both are required:

**[OPS-18] MUST — Step 1:** Add a service URL field to the gateway config
(`XServiceURL`, env: `X_SERVICE_URL`).

**[OPS-19] MUST — Step 2:** Define the proxy target (route table). Specific
patterns come **before** wildcards; matching returns the first match.

**[OPS-20] MUST — Step 3:** Register the route with the gateway router
(`r.Any("/x-items/*path", gatewayService.Proxy())`).
> **Common mistake:** If only Step 2 is done, the request **never reaches** the gateway
> and returns **404**, but since the env is correct, the route definition is in the
> binary, and the service is up, diagnosis takes a long time. If you see a 404 on a new
> service, **check Step 3 first**.

**[OPS-21] MUST — Step 4:** Add permission definitions: at least four records per
module (`view`, `create`, `update`, `delete`) and add the new module to the admin role's
module list. Keys must match the service's `RequirePermission` calls **exactly** ([SEC-06]).
Loading is verified **by querying the DB** ([TEST-22]).

**[OPS-22] MUST:** The health endpoint is defined in the gateway **without auth** and with
a rewrite (`/x-items/health` → `/health`).

---

## 5. Deploy

**[OPS-23] MUST:** The deployed artefact is the **image**, not source code. Do not
run `git pull && go build` on the server.
> **Why:** What was tested and what runs must be the same thing. Building on the server
> can produce a different binary due to a different Go version or different dependencies.

**[OPS-24] MUST:** The image tag is **immutable**: `<service>:<commit-sha>`. Republishing
the same tag with different content is forbidden; never deploy to `latest`.

**[OPS-25] MUST:** During a rolling deploy, the old and new versions run **at the same
time**. Therefore:
- Migrations are forward-compatible ([DB-13])
- API changes are non-breaking ([API-29])
- Queue message schemas are backward-compatible ([ASYNC-06])

**[OPS-26] MUST:** A rollback plan exists and has been **tested**: reverting to the
previous image tag must be sufficient. If a migration can't be rolled back, split the
deploy into two stages.

**[OPS-27] MUST:** Post-deploy verification is performed: `/health`, `/ready`, error rate,
and p95 metric are monitored for the first 15 minutes ([OBS-21]).

**[OPS-28] SHOULD:** No production deploys on Friday afternoon or right before a holiday;
there's no one to respond if something breaks.

---

## 6. NEVER DO THIS — docker & deploy

- ❌ A single-stage (non-multi-stage) Dockerfile
- ❌ The `latest` image tag
- ❌ A container running as root
- ❌ An image without `HEALTHCHECK`
- ❌ Copying secrets / `.env` into the image
- ❌ Opening `ports:` on a business service
- ❌ A container with no resource limits
- ❌ Not configuring log rotation
- ❌ `depends_on` without `condition: service_healthy`
- ❌ Forgetting to put migration SQL files into the image
- ❌ Colliding ports
- ❌ Building on the server and deploying from there
- ❌ Republishing the same image tag with different content
- ❌ Updating only the route table in the gateway and forgetting the router registration
- ❌ Writing the service but skipping gateway/permission/env integration
