# nginx templates

Copyable, verified configuration for a React + Vite SPA served by
`nginxinc/nginx-unprivileged:1.30-alpine`. The rules and the reasoning are in
[12-NGINX.md](../../12-NGINX.md); this file is the wiring instructions.

Everything here was rendered with `templates/docker/.env.example` and checked with
`nginx -t` inside the runtime image on 2026-09-07, and a container built from these files
was verified live for cache headers, security headers, the `*.map` denial and the `/api/`
error page.

---

## Files

| File | Goes to | Rendered by envsubst? |
|---|---|---|
| `nginx.conf` | `/etc/nginx/nginx.conf` | No. Static, `http{}` level |
| `default.conf.template` | `/etc/nginx/templates/default.conf.template` | Yes, into `/tmp/nginx/default.conf` |
| `security-headers.conf` | `/etc/nginx/snippets/security-headers.conf` | No. Included per location |
| `dev.conf.template` | mounted over the production template, **local only** | Yes |

In the repository they live at `deployments/main/nginx/`. Copy them there, then copy the
Docker artefacts from `../docker/` ([11-DOCKER-COMPOSE.md](../../11-DOCKER-COMPOSE.md) §1).

## Install

```bash
mkdir -p deployments/main/nginx deployments/main/docker-entrypoint.d
cp frontend-standards/templates/nginx/*.conf          deployments/main/nginx/
cp frontend-standards/templates/nginx/*.template      deployments/main/nginx/
cp frontend-standards/templates/docker/Dockerfile     deployments/main/
cp frontend-standards/templates/docker/docker-compose*.yml deployments/main/
cp frontend-standards/templates/docker/config.js.template  deployments/main/
cp frontend-standards/templates/docker/.env.example        deployments/main/
cp frontend-standards/templates/docker/docker-entrypoint.d/20-render-config.sh \
   deployments/main/docker-entrypoint.d/
cp frontend-standards/templates/docker/.dockerignore  .        # repository ROOT

cp deployments/main/.env.example deployments/main/.env.local   # then fill it in
echo 'COMPOSE_PROJECT_NAME=<app>' > deployments/main/.env
```

Then verify before you ever start a container:

```bash
bash frontend-standards/tools/nginx-smoke.sh \
     deployments/main/nginx/default.conf.template \
     deployments/main/.env.example
```

## Environment variables the templates consume

`NGINX_ENVSUBST_FILTER='^(NGINX|APP)_'` is set in the Dockerfile, so **only** names with
those prefixes are substituted. A variable outside the convention stays literal in the
rendered file, which `nginx-smoke.sh` reports.

| Variable | Used by | Shape |
|---|---|---|
| `NGINX_PUBLIC_HOST` | the CSP `connect-src` | host name, no scheme |
| `NGINX_ROBOTS_POLICY` | `location = /robots.txt` | `allow` or `deny` |
| `NGINX_UPSTREAM_API` | `upstream api_backend` | `host:port` |
| `NGINX_UPSTREAM_TILES` | `upstream tile_backend` | `host:port` |
| `NGINX_UPSTREAM_MAP` | `/map/`, `/fonts/` | `host:port` |
| `NGINX_UPSTREAM_MQTT` | `/mqtt` | `host:port` |
| `NGINX_UPSTREAM_MEDIA` | `/media/` | `host:port` |
| `NGINX_UPSTREAM_VITE` | `dev.conf.template` only | `host:port` |
| `APP_RELEASE` | the `X-App-Release` header | full git sha |

No variable has a default anywhere ([OPS-09]). The entrypoint exits 1 and names any that is
empty ([OPS-20]).

## What you are expected to change

1. **Upstream names and prefixes.** The template ships `/api/`, `/tiles/`, `/map/`,
   `/fonts/`, `/mqtt`, `/media/`. Add or remove locations to match the services, and keep
   the Vite dev proxy in `vite.config.ts` on the **same** prefixes ([OPS-31]).
2. **Which upstreams are `upstream{}` and which are variables.** `api` and `tiles` use
   `upstream{}` with `keepalive` because they carry most of the traffic and must be up
   anyway; the rest use `set $var` + `resolver` so a stopped service cannot prevent nginx
   from starting. Read [NGX-26] and [NGX-27] before moving one across.
3. **The CSP string** in `set $csp`, if the app connects to an origin it cannot proxy.
   The policy is owned by [06-SECURITY.md](../../06-SECURITY.md) [SEC-06].
4. **`proxy_cache_path`** in `nginx.conf`: drop it entirely if the deployment proxies no
   tiles, and then also remove `nginx-cache` from compose.

## What you should not change without reading first

- `location /assets/` is a plain prefix, not `^~`. Adding `^~` disables the `*.map` denial
  ([NGX-08]).
- Every location that adds a header includes `security-headers.conf` first. Removing the
  include silently strips the whole security header set from those responses ([NGX-10]).
- `types {}` adds only `pbf`, `mvt`, `geojson`, `pmtiles`. Adding `wasm` or `woff2` is
  `[emerg] duplicate extension` at startup ([NGX-09]).
- `include /tmp/nginx/*.conf;` at the end of `nginx.conf`, with
  `NGINX_ENVSUBST_OUTPUT_DIR=/tmp/nginx` and its own tmpfs mount. Pointing this back at
  `/etc/nginx/conf.d` breaks `read_only: true` ([OPS-25]).
- The masking `map` regexes are quoted because they contain `{8}`. Removing the quotes is
  `unexpected "{"` at startup ([NGX-42]).

## Local development

```bash
docker compose -f deployments/main/docker-compose.dev.yml \
               --env-file deployments/main/.env.local up
```

This runs the real nginx (same `nginx.conf`, same `security-headers.conf`) in front of the
Vite dev server, so a proxy-prefix or header mistake fails on a laptop rather than in
production ([NGX-47]). `dev.conf.template` intentionally differs from the production server
block in four ways only, listed in its header comment.
