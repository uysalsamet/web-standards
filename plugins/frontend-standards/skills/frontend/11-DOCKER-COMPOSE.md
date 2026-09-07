# 11 — Docker and Compose

> How the bundle becomes a running container. One image for every environment
> ([GEN-09]), built in two stages, running as a non-root nginx that reads its configuration
> from the environment at start. Read this when you create a deployment, change a build
> argument, add an upstream, or a container will not start.
>
> The nginx **configuration** is owned by [12-NGINX.md](12-NGINX.md); this file owns the
> image, the compose files, the environment layering and the deploy procedure.

---

## 1. The Dockerfile

Two stages. The builder has Node and the source; the runtime has nginx, `dist/` and the
templates. Nothing else ([GEN-13]).

**[OPS-01] MUST:** The Dockerfile has exactly two stages, `builder` (`node:24-alpine`) and a
runtime stage from `nginxinc/nginx-unprivileged:1.30-alpine`. No third "deps" stage, no
`FROM ... AS test`.
> **Why:** Every extra stage is another cache key that can go stale independently and
> another place where `COPY --from` can point at the wrong thing. Two stages fit in one
> screen and the build graph is obvious.

**[OPS-02] MUST NOT:** A Node process serves the static bundle in the runtime image
(`serve`, `http-server`, `vite preview`, `express.static`).
> **Why:** The reference deployment ran `serve -s dist` behind a second nginx container:
> two proxy hops per request, no `gzip_static` (so precompressed `.br`/`.gz` assets were
> never used), cache control expressible only through `serve.json`'s two-rule format, no
> per-path proxying, and a 150 MB runtime image because Node stays in it. nginx does all of
> it in 25 MB. Detail: [ADR-0013](adr/0013-static-serving.md).

**[OPS-03] MUST:** The runtime stage is `nginxinc/nginx-unprivileged`, listening on 8080.
`USER root` never appears, and no `chown`/`chmod` of `/usr/share/nginx/html` is needed.
> **Why:** A container that starts as root to bind port 80 and then drops privileges still
> runs its entrypoint as root. The unprivileged image binds a high port as uid 101 from the
> first instruction. The cost is that `/usr/share/nginx/html` is not writable, which is why
> `/config.js` is rendered into a tmpfs ([OPS-20]).

**[OPS-13] MUST:** `npm ci` runs in its own layer, before `COPY . .`, with only
`package.json` and `package-lock.json` copied in.
> **Why:** Reversing the order reinstalls every package on every source change. Measured on
> the reference repo: 60 to 125 seconds per build, on every build.

**[OPS-04] MUST:** The Dockerfile declares `ARG BUILD_ID` **after** the `npm ci` layer and
before `RUN npm run build`, and the deploy passes `BUILD_ID=$(git rev-parse --short HEAD)`.
> **Why:** Without a cache-buster, `vite build` is served from the layer cache and a new
> commit ships the previous bundle. With one, `npm ci` stays cached and only the build
> re-runs. Verify: two builds of the same commit reuse the build layer; a new commit does not.

**[OPS-10] MUST NOT:** `docker build --no-cache` / `docker compose build --no-cache` is used
as the routine way to get a fresh build.
> **Why:** On the reference host this practice grew the BuildKit cache to **168 GB**. The
> automatic garbage collector then ran during builds and produced intermittent
> `COPY --from=builder /app/dist: not found` failures that looked like a Dockerfile bug and
> cost days. `BUILD_ID` ([OPS-04]) gives the same freshness for one layer instead of all of
> them. `--no-cache` is for debugging the cache itself, once, by hand.

**[OPS-14] MUST NOT:** Any build `ARG` starting with `VITE_` other than `VITE_BUILD_ID`.
> **Why:** A `VITE_API_BASE_URL` build argument bakes the environment into the artefact, so
> staging and production are different images and the image you tested is not the image you
> deployed ([GEN-09]). The reference deployment had five of them plus `VITE_MQTT_PASSWORD`,
> which put a broker credential into the public bundle ([GEN-10]). Everything an environment
> can change is a runtime value in `/config.js` ([OPS-21]).
> `check-standards.sh` fails the build on this.

**[OPS-15] MUST:** The build emits `dist/__version.json` containing the release sha and the
build timestamp, and the Dockerfile asserts it exists before the runtime stage.
> **Why:** "Is the new version live?" must be answerable with one `curl`, including from a
> deploy script's assertion step. Producing side: the `versionFile` Vite plugin in
> [17-ERRORS-OBSERVABILITY.md](17-ERRORS-OBSERVABILITY.md) [OBS-18]; serving side:
> [12-NGINX.md](12-NGINX.md) [NGX-18].

```dockerfile
# deployments/main/Dockerfile (the complete file). Copy from templates/docker/Dockerfile.
# syntax=docker/dockerfile:1.7

# ---------- stage 1: build ---------------------------------------------------
FROM node:24-alpine AS builder
WORKDIR /app

# Dependencies in their own layer, BEFORE the source is copied.
COPY package.json package-lock.json ./
RUN npm ci

COPY . .

# Cache-bust. Invalidates the layers below while `npm ci` above stays cached.
ARG BUILD_ID=dev
ENV BUILD_ID=$BUILD_ID

# The ONLY VITE_* build argument allowed ([GEN-09], [OPS-14]).
ARG VITE_BUILD_ID=dev
ENV VITE_BUILD_ID=$VITE_BUILD_ID

# Full commit sha for the release id ([OBS-05]).
ARG GIT_SHA=unknown
ENV GIT_SHA=$GIT_SHA

RUN npm run build

# Cheaper to fail here than to discover after the deploy that /__version.json 404s.
RUN test -s dist/index.html \
 && test -s dist/__version.json \
 && echo "build ok: $(wc -c < dist/index.html) bytes of index.html"

# ---------- stage 2: runtime -------------------------------------------------
FROM nginxinc/nginx-unprivileged:1.30-alpine

LABEL org.opencontainers.image.title="example-app" \
      org.opencontainers.image.description="React + Vite SPA served by nginx" \
      org.opencontainers.image.licenses="UNLICENSED" \
      org.opencontainers.image.base.name="nginxinc/nginx-unprivileged:1.30-alpine"

ARG GIT_SHA=unknown
ARG BUILD_ID=dev
LABEL org.opencontainers.image.revision="$GIT_SHA" \
      org.opencontainers.image.version="$BUILD_ID"

ENV NGINX_ENVSUBST_OUTPUT_DIR=/tmp/nginx
ENV NGINX_ENVSUBST_FILTER='^(NGINX|APP)_'
RUN mkdir -p /tmp/nginx

COPY --from=builder /app/dist /usr/share/nginx/html

COPY deployments/main/nginx/nginx.conf              /etc/nginx/nginx.conf
COPY deployments/main/nginx/default.conf.template   /etc/nginx/templates/default.conf.template
COPY deployments/main/nginx/security-headers.conf   /etc/nginx/snippets/security-headers.conf
COPY deployments/main/config.js.template            /etc/nginx/app-config/config.js.template
COPY --chmod=0755 deployments/main/docker-entrypoint.d/20-render-config.sh \
                                                    /docker-entrypoint.d/20-render-config.sh

EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1
```

### How the entrypoint chain actually works

This is the part that produces the most confusing failures, so it is worth spelling out.
The official image's `/docker-entrypoint.sh` runs every executable file in
`/docker-entrypoint.d/` in `sort -V` order, then `exec nginx`. Three of those files matter:

| Script | What it does | Trap |
|---|---|---|
| `15-local-resolvers.envsh` | Exports `NGINX_LOCAL_RESOLVERS` from `/etc/resolv.conf`, only if `NGINX_ENTRYPOINT_LOCAL_RESOLVERS` is set | Off by default; this standard hardcodes `127.0.0.11` instead ([NGX-17]) |
| `20-envsubst-on-templates.sh` | Renders `/etc/nginx/templates/*.template` into `$NGINX_ENVSUBST_OUTPUT_DIR` | If that directory does not exist or is not writable it logs `ERROR: ... is not writable`, renders **nothing**, and exits 0. nginx then starts with an empty config and every request 404s |
| `20-render-config.sh` (ours) | Validates the environment and renders `config.js` | Sorts *after* the stock script, so a failure here happens with the nginx config already rendered |

**[OPS-05] MUST:** The image declares a `HEALTHCHECK` that requests `/healthz` on
`127.0.0.1:8080` with `--start-period` at least 5 s.
> **Why:** `depends_on: condition: service_healthy` in other compose projects reads this.
> Without a start period the first two probes fail while the entrypoint renders templates
> and an orchestrator restarts a container that was about to be fine.

**[OPS-06] MUST:** A `.dockerignore` exists at the **repository root** (the build context)
and excludes at minimum `node_modules`, `dist`, `.git`, every `.env*` except `.env.example`,
and any tile/data directory under `deployments/`.
> **Why:** Two failures. `COPY . .` without it puts `.env.prod` into an image layer, and
> deleting the file in a later instruction does not remove it from the layer: anyone with
> the image can `docker save` and read the credentials. And the daemon uploads the whole
> context first, so a 40 GB `deployments/map/` directory makes every build slow even when
> nothing changed. Verify: `docker build` prints the context size on the first line.

```
# .dockerignore (repository root). Full file in templates/docker/.dockerignore.
node_modules
*/node_modules
dist
build
.vite
coverage

.env
.env.*
!.env.example
deployments/**/.env
deployments/**/.env.*
!deployments/**/.env.example
*.pem
*.key

.git
.github
deployments/map
deployments/**/data
**/*.mbtiles
**/*.pmtiles
docs
*.md
!README.md
```

---

## 2. Image hygiene

**[OPS-16] MUST:** Base images are pinned to a minor line, never `latest`, in both stages
([VER-02]). The digest is not required; the minor tag is, so a rebuild does not silently
jump a major.

**[OPS-17] MUST NOT:** A secret exists in any layer of the image, even if a later
instruction deletes it. This covers `.env*` files, private keys, `.npmrc` with a token, and
`ARG` values that are secrets.
> **Why:** Layers are immutable and independently readable. `docker history` and
> `docker save | tar x` recover a deleted file in seconds. If a private registry token is
> genuinely needed, use a BuildKit secret mount (`RUN --mount=type=secret,id=npmrc`), which
> never lands in a layer. Verify: `docker history --no-trunc <image> | grep -i -E 'env|secret|token'`
> and `docker run --rm --entrypoint sh <image> -c 'ls -a /usr/share/nginx/html'`.

**[OPS-18] MUST:** The runtime stage sets OCI labels including
`org.opencontainers.image.revision` (the full git sha) and `org.opencontainers.image.version`
(the short sha used as the tag).
> **Why:** `docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' <image>`
> answers "which commit is running on this host" without starting the container or trusting
> the tag. Tags get moved; labels are baked in.

**[OPS-19] SHOULD:** The runtime image stays at or below **60 MB** compressed.
> **Why:** `nginxinc/nginx-unprivileged:1.30-alpine` is about 22 MB and a bundle within the
> [PERF-02] budgets adds 3 to 8 MB, plus fonts. Anything much above 60 MB means Node, a
> package manager or `node_modules` leaked into the runtime stage, which is [OPS-02] or a
> `.dockerignore` gap. Verify: `docker images --format '{{.Size}}' <image>`.

---

## 3. Runtime configuration

This is the mechanism that makes [GEN-09] real. Read [03-PROJECT-STRUCTURE.md](03-PROJECT-STRUCTURE.md)
§5 [STR-20] for the consuming side (`runtimeConfig.ts`) first; this section is the producing side.

**[OPS-07] MUST:** `deployments/main/config.js.template` exists and is the only source of
environment-specific values reaching the browser.

**[OPS-21] MUST:** The runtime configuration is exactly these variables, no more:

| Variable | Example | Notes |
|---|---|---|
| `APP_API_BASE_URL` | `/api` | Same-origin path, not an absolute URL ([GEN-22]) |
| `APP_TILE_BASE_URL` | `/tiles` | |
| `APP_MAP_STYLE_URL` | `/map/styles/basic/style.json` | |
| `APP_MQTT_WS_URL` | `/mqtt` | Path; the scheme is derived from `location.protocol` |
| `APP_ENVIRONMENT` | `production` | `local` \| `staging` \| `production` |
| `APP_RELEASE` | full git sha | Same value as `GIT_SHA` ([OBS-05]) |
| `APP_SITE_URL` | `https://gis.example.gov.tr` | Public origin, for canonical links |
| `APP_FEATURES_JSON` | `{"heatmap":false}` | Single-line JSON object, injected unquoted |

> **Why a fixed list:** the entrypoint validates it, `check-standards.sh` looks for it, and
> `runtimeConfig.ts` parses it with a zod schema. Adding a variable is three coordinated
> edits; the list makes the third one impossible to forget. Anything not on this list is
> either a build-constant (`VITE_BUILD_ID`) or belongs to nginx (`NGINX_*`).

```javascript
// deployments/main/config.js.template -> /config.js
window.__APP_CONFIG__ = {
  apiBaseUrl: "${APP_API_BASE_URL}",
  tileBaseUrl: "${APP_TILE_BASE_URL}",
  mapStyleUrl: "${APP_MAP_STYLE_URL}",
  mqttWsUrl: "${APP_MQTT_WS_URL}",
  environment: "${APP_ENVIRONMENT}",
  release: "${APP_RELEASE}",
  siteUrl: "${APP_SITE_URL}",
  features: ${APP_FEATURES_JSON},
};
Object.freeze(window.__APP_CONFIG__);
```

**[OPS-20] MUST:** The container **fails to start**, with a message naming the variable,
when any required variable is empty or unset. Silently rendering an empty value is
forbidden.
> **Why:** This is the single most expensive failure class in the reference deployment.
> An unset `PANO_UPSTREAM` rendered `proxy_pass http:///;` and nginx died with
> `invalid URL prefix`, naming no variable. An unset API base URL rendered
> `apiBaseUrl: ""`, the app booted normally and every request 404'd against itself, which
> looks like a routing bug. Exiting 1 with the variable name turns both into a one-line log.

```sh
#!/bin/sh
# deployments/main/docker-entrypoint.d/20-render-config.sh (excerpt; full file in templates/)
set -eu
ME="$(basename "$0")"
TEMPLATE="${APP_CONFIG_TEMPLATE:-/etc/nginx/app-config/config.js.template}"
OUTPUT_DIR="${NGINX_ENVSUBST_OUTPUT_DIR:-/tmp/nginx}"

REQUIRED="APP_API_BASE_URL APP_TILE_BASE_URL APP_MAP_STYLE_URL APP_MQTT_WS_URL
APP_ENVIRONMENT APP_RELEASE APP_SITE_URL APP_FEATURES_JSON
NGINX_PUBLIC_HOST NGINX_ROBOTS_POLICY
NGINX_UPSTREAM_API NGINX_UPSTREAM_TILES NGINX_UPSTREAM_MAP NGINX_UPSTREAM_MQTT NGINX_UPSTREAM_MEDIA"

missing=''
for name in $REQUIRED; do
    eval "value=\${$name:-}"          # `set -u` would abort before we could report
    [ -z "$value" ] && missing="$missing $name"
done
if [ -n "$missing" ]; then
    echo "$ME: FATAL: required environment variable(s) empty or unset:$missing" >&2
    exit 1
fi

# Upstreams are host:port. A scheme or path here yields a proxy_pass nginx accepts
# and that then fails at request time with an unexplained 502.
for name in NGINX_UPSTREAM_API NGINX_UPSTREAM_TILES NGINX_UPSTREAM_MAP NGINX_UPSTREAM_MQTT NGINX_UPSTREAM_MEDIA; do
    eval "value=\$$name"
    case "$value" in *://*|*/*)
        echo "$ME: FATAL: $name must be host:port, got: $value" >&2; exit 1 ;;
    esac
done

mkdir -p "$OUTPUT_DIR"
# Only the names this template uses. Without a list, ANY environment variable
# could replace a matching $NAME in the file.
envsubst '${APP_API_BASE_URL} ${APP_TILE_BASE_URL} ${APP_MAP_STYLE_URL} ${APP_MQTT_WS_URL}
          ${APP_ENVIRONMENT} ${APP_RELEASE} ${APP_SITE_URL} ${APP_FEATURES_JSON}' \
    < "$TEMPLATE" > "$OUTPUT_DIR/config.js"
echo "$ME: rendered $TEMPLATE -> $OUTPUT_DIR/config.js (release=$APP_RELEASE, env=$APP_ENVIRONMENT)"
```

Observed output of the fail-fast path, run against the real image:

```
20-render-config.sh: FATAL: required environment variable(s) empty or unset: APP_API_BASE_URL ...
20-render-config.sh: the container will not start. Set them in the --env-file used by compose.
exit=1
```

**[OPS-22] MUST:** `config.js.template` is stored **outside** `/etc/nginx/templates/`
(the standard puts it in `/etc/nginx/app-config/`).
> **Why:** The stock `20-envsubst-on-templates.sh` renders every `*.template` in that
> directory with the loose `NGINX_ENVSUBST_FILTER` allow-list. Leaving `config.js.template`
> there renders it twice, the first time with a wider variable set than intended.

**[OPS-08] MUST:** `index.html` loads `/config.js` with a plain classic script tag, before
the module script.
> **Why:** A module script is deferred; a classic script without `defer` executes
> immediately. If `config.js` were `type="module"` or `defer`, `main.tsx` could read
> `window.__APP_CONFIG__` before it exists, and the failure is intermittent because it
> depends on network timing.

```html
<!-- index.html (excerpt) -->
  <body>
    <div id="root"></div>
    <!-- Classic script, no defer: must run before the module bundle ([OPS-08]). -->
    <script src="/config.js"></script>
    <script type="module" src="/src/main.tsx"></script>
  </body>
```

**[OPS-23] MUST:** `/config.js` is served with `Cache-Control: no-store` and rendered into a
writable tmpfs path, not into the document root.
> **Why:** `no-store` because this file decides which API the browser talks to; a
> revalidation answered from an intermediate cache points a production browser at a staging
> gateway ([SEC-13]). The tmpfs because `/usr/share/nginx/html` is root-owned in the
> unprivileged image and the container runs `read_only: true`. Delivery: [NGX-05].

---

## 4. Compose files

### Production

**[OPS-11] MUST:** Every service declares `restart: unless-stopped`.
> **Why:** `always` also restarts containers a human deliberately stopped, which fights the
> operator during an incident. `no` (the default) means a host reboot leaves the site down.

**[OPS-12] MUST:** Every service declares json-file log rotation, `max-size: 10m` and
`max-file: "3"`.
> **Why:** Docker's default json-file driver has **no** rotation. On the reference host a
> single chatty container filled the disk, which took down every other container on it.
> 30 MB per container is roughly a week of traffic for an internal app.

**[OPS-24] MUST:** Every service declares a memory limit under `deploy.resources.limits`.
The frontend container's limit is **128m**.
> **Why:** nginx serving static files plus a 50 MB `keys_zone` sits at 25 to 40 MB RSS.
> 128m leaves headroom for a burst and converts a runaway into one restarted container
> instead of an OOM-killed host. `deploy.resources` is honoured by `docker compose up`
> since Compose v2; it is not Swarm-only.

**[OPS-25] MUST:** The frontend service runs `read_only: true`, with tmpfs mounts for
`/tmp`, `/tmp/nginx` and `/run`, and `security_opt: [no-new-privileges:true]`.
> **Why:** The image writes nothing at runtime except its pid file, its temp paths and the
> rendered configs. Making that explicit means a template injection or a path-traversal bug
> cannot persist anything. Two traps: `/tmp/nginx` needs its **own** tmpfs entry because it
> must already exist when the stock entrypoint renders into it, and a tmpfs at
> `/var/cache/nginx` must carry `uid=101,gid=101` or nginx cannot create its cache
> subdirectory and exits with `[emerg] mkdir() ... failed (13: Permission denied)`.

**[OPS-26] MUST:** The compose file declares its own `healthcheck` in addition to the
image's `HEALTHCHECK`, and other projects depend on it with
`depends_on: { condition: service_healthy }`.

**[OPS-27] MUST:** Cross-project networks are `external: true` with an explicit `name`.
> **Why:** A network created implicitly by one compose project disappears when that project
> is torn down, taking every other project's DNS with it. An external network has a
> lifecycle nobody's `down` command owns.

```yaml
# deployments/main/docker-compose.yml (excerpt; full file in templates/docker/)
services:
  web:
    build:
      context: ../../
      dockerfile: deployments/main/Dockerfile
      args:
        BUILD_ID: ${BUILD_ID}
        VITE_BUILD_ID: ${BUILD_ID}
        GIT_SHA: ${GIT_SHA}
    image: ${COMPOSE_PROJECT_NAME}-web:${BUILD_ID}
    restart: unless-stopped
    ports:
      - "${NGINX_PORT}:8080"
    environment:
      APP_API_BASE_URL: ${APP_API_BASE_URL}
      # ... the rest of the APP_* and NGINX_* list, no `:-` defaults ([OPS-09])
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://127.0.0.1:8080/healthz || exit 1"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 10s
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
    deploy:
      resources:
        limits: { memory: 128m }
        reservations: { memory: 32m }
    read_only: true
    tmpfs:
      - /tmp:mode=1777,size=16m
      - /tmp/nginx:mode=1777,size=4m      # must exist before the entrypoint renders into it
      - /run:mode=0755,size=4m
    volumes:
      - nginx-cache:/var/cache/nginx      # persistent: a tile cache must survive a deploy
    security_opt: [no-new-privileges:true]
    cap_drop: [ALL]
    networks: [shared]

volumes:
  nginx-cache:

networks:
  shared:
    external: true
    name: clavus_shared_network
```

### Development

**[OPS-28] MUST:** The dev compose runs the Vite dev server with the source bind-mounted and
an **anonymous volume shadowing `node_modules`**.
> **Why:** The host's `node_modules` is built for win32 or darwin. Native binaries (esbuild,
> the Rolldown binding) fail immediately inside alpine with
> `Error: Cannot find module '@esbuild/linux-x64'`. The anonymous volume hides the host tree
> so the container keeps the one `npm ci` produced inside it.

**[OPS-29] MUST:** File watching uses polling when the source comes from a Windows or macOS
bind mount, enabled by an environment variable rather than hardcoded.
> **Why:** Docker Desktop delivers no inotify events across the host filesystem boundary.
> Without polling, saving a file changes nothing on screen and looks like broken HMR.
> Polling costs measurable CPU on a large tree, so it must not be the default for Linux
> developers who do not need it.

**[OPS-30] MUST:** `server.watch.ignored` excludes `deployments/**`.
> **Why:** Tile servers hold `.mbtiles` files open under `deployments/`. On Windows, chokidar
> watching a locked file throws `EBUSY`/`EPERM` as an `FSWatcher` `error` event; with no
> listener attached, the Node process dies. In the reference repo `npm run dev` crashed every
> time the map compose project restarted. The guard plugin in §7 handles the residual cases.

**[OPS-31] MUST:** The dev proxy prefixes and the production nginx prefixes are the **same
strings**: `/api/`, `/tiles/`, `/map/`, `/mqtt`, `/media/`.
> **Why:** Application code must never branch on environment. If dev used `/dev-api/` and
> production used `/api/`, every fetch would need a conditional, and the conditional would
> be wrong somewhere. This is what makes "works locally" mean something.

```yaml
# deployments/main/docker-compose.dev.yml (excerpt; full file in templates/docker/)
services:
  vite:
    image: node:24-alpine
    working_dir: /app
    command: sh -c "npm ci && npm run dev -- --host 0.0.0.0 --port 5173"
    environment:
      VITE_WATCH_POLLING: "1"            # Docker Desktop bind mounts emit no inotify events
      VITE_HMR_CLIENT_PORT: ${NGINX_PORT}  # the browser talks to the edge, not to 5173
    volumes:
      - ../../:/app
      - /app/node_modules                # shadow the host tree (wrong platform)
    expose: ["5173"]

  edge:
    image: nginxinc/nginx-unprivileged:1.30-alpine
    ports: ["${NGINX_PORT}:8080"]
    environment:
      NGINX_ENVSUBST_OUTPUT_DIR: /tmp/nginx
      NGINX_UPSTREAM_VITE: vite:5173
      # ... the same NGINX_UPSTREAM_* names as production
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro                    # identical to prod
      - ./nginx/security-headers.conf:/etc/nginx/snippets/security-headers.conf:ro
      - ./nginx/dev.conf.template:/etc/nginx/templates/default.conf.template:ro
    tmpfs:
      - /tmp/nginx:mode=1777,size=4m
    depends_on: [vite]
```

---

## 5. Environment layering

**[OPS-32] MUST:** `.env.example` is committed and lists **every** variable with a
placeholder value that is safe to publish (loopback address, `example.test`). Real values
live in `.env.local` and `.env.prod`, both git-ignored.
> **Why:** It is the only machine-readable list of what a deploy needs, it is what
> `nginx-smoke.sh` renders in CI, and `diff <(cut -d= -f1 .env.example | sort) <(cut -d= -f1 .env.prod | sort)`
> is the review step when someone adds a variable. A placeholder value, not an empty one, so
> the CI render actually produces a valid config.

**[OPS-09] MUST NOT:** An upstream host has a default value anywhere:
not `${API_UPSTREAM:-localhost:7000}` in compose, not `${X:-...}` in an nginx template.
> **Why:** A default turns a missing variable into a working container that proxies to the
> wrong place. In production that is a site pointed at a machine that does not exist, failing
> at request time with a 502 instead of at start time with a message. Fail loudly ([OPS-20]).
> `check-standards.sh` fails on `${*UPSTREAM*:-`.

**[OPS-33] MUST:** The env file is passed explicitly with `--env-file`; the implicit
`deployments/main/.env` holds `COMPOSE_PROJECT_NAME` only.
> **Why:** Compose auto-loads `.env` from the project directory. With three env files in one
> folder, "which one is live" becomes a guess, and someone will `up` production values from
> a shell that had `.env.local` sourced. Being explicit makes the command self-documenting:
> `docker compose -f ... --env-file deployments/main/.env.prod up -d`.

**[OPS-34] MUST:** `COMPOSE_PROJECT_NAME` is set and used as the prefix of container, volume
and image names.
> **Why:** Two apps on one host both define a service called `web` and a volume called
> `nginx-cache`. Without the project name they collide, and `docker compose down -v` in one
> repo deletes the other's cache.

**[OPS-35] MUST:** Variable names follow the prefix convention: `APP_*` is browser runtime
config, `NGINX_*` is nginx template substitution, `*_UPSTREAM*` is a `host:port` inside the
Docker network (no scheme, no path, no trailing slash), `DEV_*` is a Vite dev proxy target
(a full URL).
> **Why:** The prefix is what `NGINX_ENVSUBST_FILTER='^(NGINX|APP)_'` matches, so a name
> outside the convention is silently not substituted. It also makes the security review
> trivial: everything `APP_*` is public by definition ([GEN-10]), everything else is not
> shipped to the browser at all.

---

## 6. Deploy procedure

```bash
# 1. Build and start. BUILD_ID busts the vite build layer; GIT_SHA becomes the release id.
export BUILD_ID=$(git rev-parse --short HEAD)
export GIT_SHA=$(git rev-parse HEAD)
docker compose -f deployments/main/docker-compose.yml \
               --env-file deployments/main/.env.prod \
               up -d --build

# 2. Verify the release that is actually serving, not the one you think you pushed.
curl -s https://gis.example.gov.tr/__version.json
# {"release":"9b718b2d...","builtAt":"2026-09-07T09:14:02.113Z"}

# 3. Verify headers and caching ([SEC-11], [NGX-48]).
bash frontend-standards/tools/nginx-smoke.sh \
     deployments/main/nginx/default.conf.template \
     deployments/main/.env.example \
     --url https://gis.example.gov.tr
```

**[OPS-36] MUST:** Every image is tagged with the short git sha and never with `latest`.

**[OPS-37] MUST:** Rollback is redeploying a previous tag, never rebuilding an old commit.
```bash
BUILD_ID=<previous-short-sha> GIT_SHA=<previous-full-sha> \
docker compose -f deployments/main/docker-compose.yml --env-file deployments/main/.env.prod up -d
```
> **Why:** Rebuilding resolves dependency ranges again; `npm ci` pins the tree but a base
> image tag can have moved. The artefact that worked is the artefact you roll back to.

Single-container compose has a visible gap while the old container stops and the new one
starts, typically under two seconds. That is accepted for internal applications. For a
public portal, run two replicas behind the shared edge proxy and stop the old one only after
the new one reports healthy; `depends_on: condition: service_healthy` plus a manual
`docker compose up -d --no-deps --scale web=2` is the current manual procedure. A managed
rolling update is out of scope for compose and is an open question below.

**[OPS-38] MUST:** Build cache hygiene runs weekly on every build host:
```bash
docker builder prune --keep-storage 20GB -f
docker image prune -f --filter "until=336h"
```
> **Why:** See [OPS-10]. 20 GB is enough to keep the `npm ci` layers of several apps warm and
> small enough that the GC never runs mid-build. Verify with `docker system df`.

---

## 7. Local development without Docker

The fastest loop on Windows is Vite's own dev server on the host, with Vite's proxy standing
in for nginx. The prefixes are identical ([OPS-31]), so nothing in `src/` knows the difference.

```bash
cp deployments/main/.env.example .env.local   # then fill in DEV_* targets
npm ci
npm run dev            # http://localhost:5173
```

**[OPS-39] MUST:** Vite dev proxy targets come from `DEV_*_TARGET` variables read with
`loadEnv`, and the code has no hardcoded LAN address.

**[OPS-40] MUST:** Every proxy entry that talks to a service on another host uses a
`keepAlive` HTTP agent.
> **Why:** Node's `http-proxy` opens a **new TCP connection per request** by default.
> Measured on the reference project against a LAN target (192.168.1.113): about 250 to 300 ms
> of handshake per request, while the gateway, worker and database together answered in under
> 3 ms. A map viewport requesting 24 tiles paid six seconds of pure handshake. With a pool,
> the same viewport is one connection setup.

```ts
// vite.config.ts (server block; see 07-PERFORMANCE.md [PERF-09] for the build block)
import http from 'node:http'
import { defineConfig, loadEnv, type PluginOption } from 'vite'
import react from '@vitejs/plugin-react'
import tailwindcss from '@tailwindcss/vite'

// One pooled agent for every proxied upstream ([OPS-40]).
const keepAliveAgent = new http.Agent({
  keepAlive: true,
  keepAliveMsecs: 30_000,
  maxSockets: 100,
  maxFreeSockets: 20,
  timeout: 60_000,
})

// chokidar reports a locked file as an FSWatcher 'error' event. With no listener,
// Node exits. Tile servers keep .mbtiles open under deployments/ ([OPS-30]).
const RECOVERABLE_WATCH_ERRORS = new Set(['EBUSY', 'EPERM', 'EACCES', 'ENOENT'])
const watcherErrorGuard = (): PluginOption => ({
  name: 'watcher-error-guard',
  apply: 'serve',
  configureServer(server) {
    server.watcher.on('error', (error: NodeJS.ErrnoException) => {
      const where = error.path ? ` (${error.path})` : ''
      if (error.code && RECOVERABLE_WATCH_ERRORS.has(error.code)) {
        server.config.logger.warn(`[watcher] ${error.code}${where}: file locked, skipped`)
        return
      }
      // Not swallowed ([GEN-17]): logged in full, but it must not kill the dev server.
      server.config.logger.error(`[watcher] unexpected${where}: ${error.stack ?? error.message}`)
    })
  },
})

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, process.cwd(), '')
  const target = (name: string, fallbackPort: number) =>
    env[name] || `http://localhost:${fallbackPort}`

  return {
    plugins: [react(), tailwindcss(), watcherErrorGuard()],
    server: {
      host: '0.0.0.0',
      port: 5173,
      // Vite merges this with its defaults (node_modules, .git).
      watch: {
        ignored: ['**/deployments/**'],
        usePolling: process.env.VITE_WATCH_POLLING === '1',
      },
      hmr: {
        // When the browser reaches the app through the nginx edge container,
        // the HMR client must be told that port; otherwise it dials 5173.
        clientPort: Number(process.env.VITE_HMR_CLIENT_PORT ?? 5173),
      },
      proxy: {
        // Prefixes are byte-identical to the nginx locations ([OPS-31]).
        '/api/': {
          target: target('DEV_API_TARGET', 7000),
          changeOrigin: true,
          agent: keepAliveAgent,
          // The gateway parses the /api prefix itself; do NOT strip it.
          cookiePathRewrite: { '/api': '/' },
        },
        '/tiles/': {
          target: target('DEV_TILE_TARGET', 3040),
          changeOrigin: true,
          agent: keepAliveAgent,
          // nginx strips /tiles via `proxy_pass http://tile_backend/`; match it.
          rewrite: (p) => p.replace(/^\/tiles/, ''),
        },
        // Trailing slash matters: '/map' would also swallow the SPA route
        // '/map-data' and forward "/-data" to the tile server ([RTE-16]).
        '/map/': {
          target: target('DEV_MAP_TARGET', 7211),
          changeOrigin: true,
          agent: keepAliveAgent,
          rewrite: (p) => p.replace(/^\/map/, ''),
        },
        '/mqtt': {
          target: target('DEV_MQTT_TARGET', 8083),
          ws: true,
          changeOrigin: true,
        },
        '/media/': {
          target: target('DEV_MEDIA_TARGET', 8889),
          changeOrigin: true,
          rewrite: (p) => p.replace(/^\/media/, ''),
        },
      },
    },
  }
})
```

`npm run dev` does not serve `/config.js`. `index.html` requests it, gets the SPA fallback
(HTML), and the classic script tag fails silently. Two supported answers, pick one per repo:
put a static `public/config.js` with local values (git-ignored, listed in `.env.example`'s
comments), or have `runtimeConfig.ts` fall back to `import.meta.env.DEV` defaults. The
standard prefers the static `public/config.js`, because it exercises the same code path as
production instead of a second branch.

---

## 8. Several apps on one edge

**[OPS-41] MUST:** Multiple applications on one host are separated by **host name**, not by
path prefix, unless there is a written reason.
> **Why:** A path prefix has to be known at build time (Vite's `base`), which reintroduces
> the per-environment artefact that [GEN-09] removes, and it collides with the SPA fallback:
> every asset request from `/app-b/` that misses falls through to app A's `index.html`.
> Host-based routing needs no build-time knowledge at all.

```nginx
# The shared edge proxy compose project (NOT the app's own nginx).
server { server_name gis.example.gov.tr;    location / { proxy_pass http://gis-web:8080;  } }
server { server_name portal.example.gov.tr; location / { proxy_pass http://portal-web:8080; } }
```

**[OPS-42] SHOULD:** When a path prefix is unavoidable (one certificate, one host name),
`base` in `vite.config.ts` and the nginx prefix are set from the **same** variable, the
router gets a matching `basename`, and the prefix is stripped by nginx with a trailing-slash
`proxy_pass`. The accepted cost is one image per prefix, documented in the deploy README.

---

## 9. Ops checklist

Run through this before calling a deployment done. Twelve items, each verifiable.

1. `docker images` shows the runtime image at or below 60 MB ([OPS-19]).
2. `docker inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}'`
   returns the sha you deployed ([OPS-18]).
3. `docker history --no-trunc <image>` contains no env file, key or token ([OPS-17]).
4. `docker run --rm --entrypoint id <image>` prints uid 101, not 0 ([OPS-03]).
5. `docker compose ps` shows the container **healthy**, not just running ([OPS-05]).
6. `curl -s https://<host>/__version.json` matches the pushed sha ([OPS-15]).
7. `curl -s https://<host>/config.js` shows the right environment's values, and
   `curl -sI` shows `cache-control: no-store` ([OPS-23]).
8. Starting the container with one required variable removed exits 1 and names it ([OPS-20]).
9. `docker inspect --format '{{.HostConfig.ReadonlyRootfs}}'` is `true` ([OPS-25]).
10. `docker inspect --format '{{.HostConfig.Memory}}'` is 134217728 ([OPS-24]).
11. `docker compose config` shows no `${VAR:-default}` on an upstream ([OPS-09]).
12. `bash tools/nginx-smoke.sh <template> <env> --url https://<host>` exits 0 ([NGX-48]).

## 10. Troubleshooting

| Symptom | First thing to check |
|---|---|
| Blank page, no network errors, console `Cannot read properties of undefined` | `/config.js`. `curl -s <host>/config.js`: if it returns HTML, the entrypoint did not render it (read the container's first 20 log lines) or `location = /config.js` is missing and the SPA fallback answered ([OPS-20], [NGX-05]) |
| Blank page, console `Unexpected token` in config.js | `APP_FEATURES_JSON` is not valid JSON. It is injected unquoted ([OPS-21]) |
| `502` on `/api/` only, rest of the site fine | The upstream variable. `docker compose exec web env \| grep UPSTREAM`, then `docker compose exec web wget -qO- http://$NGINX_UPSTREAM_API/health`. A wrong service name resolves to nothing through the Docker resolver ([NGX-17]) |
| nginx will not start, `[emerg] invalid URL prefix` or `host not found in upstream` | An empty template variable (`proxy_pass http:///`) or a static `upstream{}` whose host is down. Reproduce with `bash tools/nginx-smoke.sh <template> <envfile>` ([OPS-20], [NGX-17]) |
| nginx will not start, `[emerg] mkdir() "/var/cache/nginx/tiles" failed (13)` | The cache path is a root-owned tmpfs. Use a named volume, or add `uid=101,gid=101` ([OPS-25]) |
| Container starts but every path 404s | `20-envsubst-on-templates.sh: ERROR: ... is not writable` in the logs: `/tmp/nginx` did not exist. Add its own tmpfs entry ([OPS-25]) |
| Assets 404 after a deploy, old tab | Expected: hashed files changed. The app reloads once on a chunk-load error ([OBS-06]). If a **fresh** tab 404s, `index.html` was cached; check `Cache-Control: no-cache` ([NGX-05]) |
| `npm run dev` dies on Windows with `EBUSY`/`EPERM` | The watcher hit a file a tile server holds open. `server.watch.ignored` must include `deployments/**`, and the guard plugin must be installed ([OPS-30]) |
| HMR never fires in the dev container | Polling is off (`VITE_WATCH_POLLING`) or the HMR client is dialling 5173 instead of the edge port ([OPS-29]) |
| Build fails intermittently with `COPY --from ... not found` | BuildKit cache pressure. `docker system df`, then `docker builder prune --keep-storage 20GB`. Stop using `--no-cache` ([OPS-10], [OPS-38]) |

---

## Open questions

- **Zero-downtime deploys with plain compose.** The current procedure has a sub-two-second
  gap. Deciding condition: the first public, SEO-indexed portal on this stack, or an SLA
  that names an availability number. The alternatives to compare then are two replicas
  behind the shared edge with a health-gated cutover, or moving the edge to a proxy with
  native rolling reload.
- **Brotli in the runtime image.** `nginxinc/nginx-unprivileged` has no brotli module, so
  [PERF-10]'s `.br` files are currently unused ([NGX-20]). Deciding condition: whether the
  organisation accepts maintaining a custom image build. Owned by [12-NGINX.md](12-NGINX.md) §3.
- **Registry.** The standard assumes images are built on the host that runs them. A shared
  registry would make [OPS-37] rollback instant across hosts and allow signing. Deciding
  condition: a second deployment host for the same app.
