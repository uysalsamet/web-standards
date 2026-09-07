# 12 — nginx

> The web server is not a detail you copy from a blog post. It decides caching, compression,
> which upstream a path reaches, whether a stopped service takes the whole site down, and
> whether a source map leaks. This file is the complete configuration, with the reason for
> every directive. Read it before touching anything under `deployments/main/nginx/`.
>
> Security **header values** are owned by [06-SECURITY.md](06-SECURITY.md) ([SEC-06],
> [SEC-10]); this file owns how they are delivered. The image, compose and environment are
> owned by [11-DOCKER-COMPOSE.md](11-DOCKER-COMPOSE.md).

---

## 1. File layout and the template mechanism

Three files, two levels, one rendered at container start.

| File | In the image at | Level | Rendered? |
|---|---|---|---|
| `nginx.conf` | `/etc/nginx/nginx.conf` | `http{}` | No. Static |
| `default.conf.template` | `/etc/nginx/templates/` | `upstream{}` + `server{}` | Yes, by envsubst into `/tmp/nginx/default.conf` |
| `security-headers.conf` | `/etc/nginx/snippets/` | fragment | No. Included per location |
| `dev.conf.template` | mounted over the production template in dev only | `server{}` | Yes |

**[NGX-01] MUST:** Anything that needs a value from the environment lives in a `*.template`
under `/etc/nginx/templates/`. `nginx.conf` is static and contains no `${VARIABLE}`.
> **Why:** The image entrypoint runs envsubst on `/etc/nginx/templates/*.template` only. A
> `${VAR}` in `nginx.conf` is never substituted; nginx then reads the literal `${VAR}` and
> either fails or, worse, treats it as a hostname.

**[NGX-02] MUST:** The following belong in `http{}` (`nginx.conf`) and nowhere else:
`log_format`, every `map`, `upstream` (see below), `proxy_cache_path`, `limit_req_zone`,
`gzip*`, `open_file_cache`, MIME `types` additions. Everything else is in the `server{}`
template.
> **Why:** These directives are only *valid* at http level; nginx rejects a `map` inside
> `server{}` with `"map" directive is not allowed here`. The split is not a style choice.
> `upstream{}` is the exception that also works from a rendered file, because
> `conf.d`-style includes are pulled in from inside `http{}`.

### envsubst: the five traps

**[NGX-14] MUST:** The container sets `NGINX_ENVSUBST_FILTER` so that only intended prefixes
are substituted. The standard uses `^(NGINX|APP)_`.
> **Why:** Without a filter, the entrypoint builds its allow-list from **every** environment
> variable. A variable named `host` or `uri` (a shell export, a CI runner's addition) would
> rewrite every `$host` and `$uri` in the template into that value, and the resulting config
> is valid nginx that proxies to the wrong place.

The other four, each of which has cost real time:

1. **nginx variables vs template variables.** `$http_host` is nginx's; `${NGINX_UPSTREAM_API}`
   is envsubst's. Use the braced `${NAME}` form for template variables and the prefix
   convention so the two are visually distinct.
2. **An empty variable renders empty.** `proxy_pass http://${X};` with `X` unset becomes
   `proxy_pass http:///;` and nginx exits with `invalid URL prefix in ...`, naming no
   variable. Prevented by the entrypoint's fail-fast check ([OPS-20]).
3. **A regex containing `{` must be quoted.** `map $request_uri $x { ~^(.*)([^&]{8})... }`
   without quotes makes the parser read `{` as a block opening and die with
   `unexpected "{"`. Quote the whole pattern.
4. **The output directory must exist and be writable** before the entrypoint runs, or it logs
   `ERROR: /etc/nginx/templates exists, but /tmp/nginx is not writable`, renders nothing and
   exits 0. nginx then starts with an empty include and every request 404s ([OPS-25]).

**[NGX-15] MUST:** An nginx change is verified with `nginx -t` on the **rendered** config
before it is merged. In CI this is `tools/nginx-smoke.sh` ([GEN-23]).
> **Why:** A syntax error in a template is not visible until the container starts, and a
> container that fails to start during a deploy is an outage. `nginx -t` inside the exact
> runtime image catches directive-not-allowed-here, unknown variables and quoting mistakes
> in under two seconds.

```bash
bash tools/nginx-smoke.sh deployments/main/nginx/default.conf.template \
                          deployments/main/.env.example
# nginx: the configuration file /etc/nginx/nginx.conf syntax is ok
# nginx: configuration file /etc/nginx/nginx.conf test is successful
```

---

## 2. Serving the static bundle

This section implements [GEN-12]. Two cache policies, one fallback, and a set of denials.

**[NGX-05] MUST:** `index.html` and `/config.js` have explicit `location =` blocks:
`index.html` is `Cache-Control: no-cache`, `/config.js` is `no-store`.
> **Why:** `no-cache` (revalidate, do not blindly reuse) is not `no-store` (never keep).
> `index.html` must revalidate so a deploy reaches users, but a 304 is 200 bytes while
> `no-store` re-downloads the document on every navigation. `/config.js` is `no-store`
> because it decides which API the browser talks to and a shared cache serving a stale copy
> points a production browser at a staging gateway ([SEC-13]). Verify:
> `curl -sI https://<host>/ | grep -i cache-control`.

**[NGX-04] MUST:** Hashed assets under `/assets/` are served
`Cache-Control: public, max-age=31536000, immutable` with `try_files $uri =404`.
> **Why:** `immutable` stops the browser sending even a conditional request for a year,
> which is correct because the filename changes when the content does. `try_files ... =404`
> matters more than it looks: without it a missing asset falls through to the SPA fallback
> and the browser receives HTML with `Content-Type: application/javascript`, reported as
> `Uncaught SyntaxError: Unexpected token '<'`, which sends people hunting a bundler bug.

**[NGX-08] MUST NOT:** `/assets/` uses the `^~` modifier.
> **Why:** `^~` tells nginx to stop and not evaluate regex locations. The `*.map` denial
> ([NGX-13]) is a regex location, so `^~ /assets/` would serve
> `/assets/index-Ab12Cd34.js.map` to anyone who asks. Use a plain prefix location.

**[NGX-03] MUST:** Unknown paths fall back to `index.html` with `try_files $uri $uri/ /index.html`,
placed in the **last** `location /` block. SEO-indexed prefixes are excluded ([NGX-43]).
> **Why:** A client-side router needs the document for any URL. `$uri/` before the fallback
> so a real directory still gets its index. Last, because a prefix location that appears
> after it can still win on length, but keeping the fallback last makes the file readable in
> match order.

**[NGX-09] MUST:** MIME types for the formats a GIS frontend serves are declared, without
repeating anything `mime.types` already maps.
> **Why:** An unmapped extension is served as `application/octet-stream`. MapLibre refuses a
> vector tile with the wrong type and the map is silently empty. And the reverse trap:
> `application/wasm wasm` and `font/woff2 woff2` are **already** in nginx 1.30's
> `mime.types`; redeclaring them is `[emerg] duplicate extension "wasm"`, not a warning.

```nginx
include /etc/nginx/mime.types;
types {
    application/vnd.mapbox-vector-tile  pbf mvt;
    application/geo+json                geojson;
    application/vnd.pmtiles             pmtiles;
}
default_type application/octet-stream;
```

**[NGX-10] MUST:** Every `location{}` that declares any `add_header` of its own also does
`include /etc/nginx/snippets/security-headers.conf;` first, and every `add_header` carries
`always`.
> **Why:** This is nginx's single most surprising rule. `add_header` is inherited from the
> enclosing block **only if the current level defines none of its own**. One
> `add_header Cache-Control ...` inside `location /assets/` therefore removes
> `X-Content-Type-Options`, `Referrer-Policy`, CSP and everything else from those responses,
> and nothing warns you. `always` is needed because otherwise nginx omits the header on
> 4xx/5xx responses, which is exactly where a sniffed content type or a framed error page
> matters. `check-standards.sh` flags an `add_header` in a location without the include.

```nginx
# WRONG: assets lose every security header
location /assets/ {
    add_header Cache-Control "public, max-age=31536000, immutable";
}

# RIGHT
location /assets/ {
    include /etc/nginx/snippets/security-headers.conf;
    add_header Cache-Control "public, max-age=31536000, immutable" always;
    try_files $uri =404;
}
```

**[NGX-16] MUST:** `etag on`, `sendfile on`, `tcp_nopush on`, `tcp_nodelay on` and
`open_file_cache` are enabled, with `open_file_cache_errors off`.
> **Why:** `sendfile` skips a user-space copy for static files; `tcp_nopush` fills a packet
> before sending, `tcp_nodelay` stops the *last* small packet waiting. `open_file_cache`
> caches the open descriptor, which is safe because hashed files never change in place.
> `open_file_cache_errors off` is the important one: with it on, a 404 for an asset that
> appears mid-deploy would stick for the cache validity window.

**[NGX-12] MUST:** `server_tokens off`.
> **Why:** The `Server: nginx/1.30.1` header tells a scanner exactly which CVE list to try.
> With it off the header is just `Server: nginx`. Verify: `curl -sI <host> | grep -i server`.

**[NGX-13] MUST:** `*.map` files and dotfiles are denied.
> **Why:** Source maps de-minify the whole application, including comments and internal
> endpoint names. They are uploaded to the error tracker, never served ([SEC-22]).
> Dotfiles catch a `.env` or `.git` that ends up in `dist/` through a `public/` mistake.
> Verify: `curl -o /dev/null -w '%{http_code}' <host>/assets/anything.js.map` returns 403.

**[NGX-06] MUST:** `location = /healthz` returns `200 ok` as `text/plain`, with
`access_log off`, and never reaches the SPA fallback.
> **Why:** It is polled every 10 s by the Docker healthcheck ([OPS-05]) and by any
> orchestrator waiting on `service_healthy`; logging it buries real traffic. It must be its
> own exact location so that a broken or missing `index.html` still reports the container as
> unhealthy instead of returning the fallback with status 200.

**[NGX-18] MUST:** `/__version.json` is served from `dist/` with `Cache-Control: no-cache`
and `Content-Type: application/json`.
> **Why:** It is how a deploy script asserts which release is live ([OBS-18], [OPS-15]).
> Caching it defeats the purpose: the answer would be the previous release's.

**[NGX-19] MUST:** `robots.txt` is selected by environment, not shipped as one file.
> **Why:** A staging host indexed by Google outranks production for its own content and
> leaks unreleased pages. The template picks `robots.deny.txt` unless the environment says
> otherwise, so the default is safe and only production opts in. Detail: [10-SEO-RENDERING.md].

```nginx
location = /robots.txt {
    include /etc/nginx/snippets/security-headers.conf;
    add_header Cache-Control "public, max-age=300" always;
    default_type text/plain;
    try_files /robots.${NGINX_ROBOTS_POLICY}.txt /robots.txt =404;
}
```

---

## 3. Compression

**[NGX-07] MUST:** `gzip_static on`, and `vite-plugin-compression2` emits `.gz` next to
every asset above 1 KB ([PERF-10]).
> **Why:** Compressing at request time costs CPU on every request and, under load,
> competes with the proxying work. A build-time gzip at maximum level is smaller *and* free
> at serve time. `gzip_static` serves `index-Ab12.js.gz` transparently when the client sends
> `Accept-Encoding: gzip`. Verify:
> `curl -H 'Accept-Encoding: gzip' -sI <host>/assets/index-*.js | grep -i content-encoding`.

**[NGX-20] SHOULD:** `brotli_static on` where the module is available.
> **Why, honestly:** it is not available in this standard's runtime image.
> `nginxinc/nginx-unprivileged:1.30-alpine` is built without `ngx_brotli`
> (`nginx -V` lists `--with-http_gzip_static_module` and no brotli). The options are the
> official `nginx` image plus the dynamic module package (`nginx-module-brotli`, available in
> the Debian-based `nginx:1.30` variant, not in `-alpine`), or building a custom image. Until
> that is decided ([Open questions]), the `.br` files [PERF-10] emits sit unused, costing
> about 1 s of build time and a few hundred kilobytes of image. The gain would be roughly
> 15 to 20 % over gzip on JS and CSS. Do not add `brotli on` (dynamic) as a substitute: it
> reintroduces per-request CPU.

**[NGX-21] MUST:** `gzip on` covers dynamic proxied JSON with `gzip_min_length 1024`, and
`gzip_types` never includes `application/vnd.mapbox-vector-tile`.
> **Why:** Proxied API responses have no precompressed sibling, so runtime gzip is the only
> option there; below ~1 KB the compression overhead exceeds the saving. MVT tiles arrive
> **already gzip-encoded** from the tile server. Re-compressing them burns CPU for
> approximately zero gain, and if nginx also strips and re-adds `Content-Encoding` the tile
> can arrive double-encoded and MapLibre throws `Unable to parse the tile`.

```nginx
gzip              on;
gzip_static       on;
gzip_vary         on;      # Vary: Accept-Encoding, so caches keep variants apart
gzip_proxied      any;
gzip_comp_level   5;       # 5 is the knee: level 9 costs ~3x CPU for ~2% size
gzip_min_length   1024;
gzip_types
    text/plain text/css text/xml
    application/json application/geo+json application/xml
    application/javascript application/x-javascript
    image/svg+xml;
```

---

## 4. Security header delivery

Values are [SEC-06] and [SEC-10]. Mechanism only here.

**[NGX-11] MUST:** Security headers live in one include, `security-headers.conf`, kept under
`/etc/nginx/snippets/` and **not** under `conf.d/` or the envsubst output directory.
> **Why:** `conf.d/*.conf` is included from inside `http{}`. A file of `add_header`
> directives placed there would apply at http level, which is inherited by every server and
> then silently replaced by any location that adds a header of its own. Keeping it out of
> the auto-included directories forces the explicit per-location include that [NGX-10]
> requires.

**[NGX-23] MUST:** A header whose value comes from the environment (the CSP's host) is
delivered through a server-level `set $var "..."`, on one line, referenced by the include.
> **Why:** The include is static, but the CSP needs the public host name for `connect-src`.
> nginx omits an `add_header` whose value evaluates to empty, so a server block that does not
> set `$csp` (the dev block) simply sends no CSP rather than a broken one. One line, because
> a quoted nginx string may span lines but the newlines end up inside the header value.

```nginx
# In default.conf.template, at server level:
set $csp "default-src 'self'; script-src 'self'; ...; report-uri /csp-report";
set $app_release "${APP_RELEASE}";
```
```nginx
# /etc/nginx/snippets/security-headers.conf
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header Permissions-Policy "geolocation=(self), camera=(), microphone=(), payment=(), usb=(), interest-cohort=()" always;
add_header X-Frame-Options "DENY" always;
add_header Cross-Origin-Opener-Policy "same-origin" always;
add_header Content-Security-Policy $csp always;
add_header X-App-Release $app_release always;
```

**[NGX-24] MUST NOT:** `Strict-Transport-Security` is set here when TLS terminates upstream
(an edge proxy, a load balancer).
> **Why:** Two HSTS headers with different `max-age` values is a configuration bug, and the
> browser's handling of duplicates is not something to rely on. It is set by exactly one
> component: the one holding the certificate ([SEC-10]).

---

## 5. Reverse proxy

Every service the browser needs is reached through this origin ([GEN-22]). One location per
upstream class, with a canonical prefix shared with the Vite dev proxy ([OPS-31]).

| Prefix | Upstream | Form | Timeouts |
|---|---|---|---|
| `/api/` | gateway | `upstream{}` + keepalive | connect 5s, send 30s, read 60s |
| `/api/uploads/` | gateway | same | read 300s, `client_max_body_size 50m` |
| `/tiles/` | tile server | `upstream{}` + keepalive + cache | connect 3s, read 10s |
| `/map/`, `/fonts/` | map server (styles, glyphs, sprites) | variable + resolver | read 10s |
| `/mqtt` | broker WebSocket | variable + resolver | read 3600s |
| `/media/` | WHEP / SSE signalling | variable + resolver, unbuffered | read 300s |

### 5.1 proxy_pass and the trailing slash

**[NGX-25] MUST:** The trailing-slash semantics of `proxy_pass` are stated in a comment on
every proxy location, because they are not guessable.

| Location | `proxy_pass` | Request `/api/v1/x` becomes |
|---|---|---|
| `/api/` | `http://up;` (no slash) | `http://up/api/v1/x` (full URI kept) |
| `/api/` | `http://up/;` (slash) | `http://up/v1/x` (prefix replaced by `/`) |
| `/api/` | `http://up/gw/;` | `http://up/gw/v1/x` |
| `/api/` | `http://$var;` (variable) | `http://up/api/v1/x`, and **no** URI rewriting is possible: with a variable, nginx passes the original URI unless you use `rewrite ... break` |

> **Why it matters:** the reference project's gateway parses the `/api` prefix itself, so
> the no-slash form is correct there; the tile server does not know about `/tiles`, so that
> one needs the slash. Getting it backwards produces `/api/api/v1/x` (404 from the gateway)
> or `Cannot GET /1/2/3.pbf`. With a variable upstream, the `rewrite ^/map/(.*)$ /$1 break;`
> form is the only way to strip a prefix.

### 5.2 Connection reuse

**[NGX-26] MUST:** A proxy location that carries many requests per page uses an
`upstream{}` block with `keepalive`, plus `proxy_http_version 1.1` and
`proxy_set_header Connection ""`.
> **Why:** All three are required together. `proxy_http_version 1.1` alone still sends
> `Connection: close` inherited from the client. Without the pool, nginx opened a **new TCP
> connection for every tile** on the reference deployment, and one map viewport requests 16
> to 32 tiles. `keepalive 32` is the number of idle connections kept per worker; it is a
> pool size, not a limit on concurrent requests.

**[NGX-27] MUST:** A proxy location for an **optional** service uses the variable form with
a `resolver`, and accepts that it has no keepalive.
> **Why, both directions:** an `upstream{}` block resolves its server name **once, at config
> load**. If that host is not up, nginx does not start at all:
> `[emerg] host not found in upstream "arnavutkoy-planning-tile"`. On the reference
> deployment a tile service that was mid-rebuild took the entire site offline this way,
> twice. `set $backend "..."; proxy_pass http://$backend;` defers resolution to request time,
> so only that path 502s. The honest cost: `proxy_pass` with a variable does not use an
> `upstream{}` block, therefore **no connection pool**. That is why the split above exists:
> tiles (thousands of requests) pay the startup dependency to get keepalive; styles and
> sprites (a handful per session) take the resilience instead.

```nginx
# Core, high volume: startup dependency accepted in exchange for a connection pool.
upstream tile_backend {
    server ${NGINX_UPSTREAM_TILES};
    keepalive 32;
}
location /tiles/ {
    proxy_pass http://tile_backend/;         # trailing slash strips /tiles
    proxy_http_version 1.1;
    proxy_set_header Connection "";          # required for keepalive
}

# Optional, low volume: resolved per request, no pool, cannot block startup.
location /map/ {
    set $map_backend "${NGINX_UPSTREAM_MAP}";
    rewrite ^/map/(.*)$ /$1 break;           # the only way to strip with a variable
    proxy_pass http://$map_backend;
    proxy_http_version 1.1;
    proxy_set_header X-Forwarded-Prefix /map;
}
```

**[NGX-17] MUST:** `resolver 127.0.0.11 valid=10s ipv6=off;` is declared at server level
whenever any location uses a variable `proxy_pass`.
> **Why:** `127.0.0.11` is Docker's embedded DNS. `valid=10s` bounds how long a stale
> address is used after a container is recreated with a new IP. `ipv6=off` because Docker's
> resolver returns an AAAA for names it cannot resolve in some configurations, and nginx then
> tries an unreachable address first, adding a timeout to every request.
> `check-standards.sh` fails a variable `proxy_pass` with no `resolver`.

### 5.3 Headers to the upstream

**[NGX-28] MUST:** `proxy_set_header Host $http_host;`, not `$host`.
> **Why:** `$host` is the host name **without the port**. When the container is published on
> a non-default port (`:90` on the reference deployment), an upstream that generates absolute
> links from the `Host` header emits `http://server/` instead of `http://server:90/`, and
> every redirect drops the user on a dead port. `$http_host` is the raw header, port included.

**[NGX-29] MUST:** `X-Real-IP`, `X-Forwarded-For` and `X-Forwarded-Proto` are set on every
proxy location, and `X-Forwarded-Prefix` is set wherever nginx strips a prefix from a service
that generates absolute links.
> **Why:** Without `X-Forwarded-Proto` the upstream believes the request was plain HTTP and
> issues `http://` redirects that a browser on an HTTPS page refuses. Without
> `X-Forwarded-Prefix` a service behind `/map/` emits `/styles/...` in its TileJSON, the
> browser requests it at the origin root, and every glyph 404s. This was the actual cause of
> a blank basemap on the reference deployment.

**[NGX-30] MUST:** `absolute_redirect off;` when the published host port differs from the
container's listen port.
> **Why:** nginx builds absolute redirects from its own `listen` port, which it does not know
> is mapped. On the reference deployment every directory redirect lost `:90` and landed the
> user on a host that answers nothing. Relative redirects make the browser keep the origin it
> already used.

**[NGX-31] MUST:** `proxy_cookie_path` rewrites a cookie path when the upstream sets one that
does not match the public prefix.
> **Why:** A gateway that sets `Set-Cookie: session=...; Path=/api/` produces a cookie the
> browser sends only to `/api/`, which is usually what you want, but a gateway setting
> `Path=/auth` under a `/api/` prefix produces a cookie that is never sent at all. The
> failure looks like "login succeeds, next request is 401".

### 5.4 Timeouts, bodies and buffering

**[NGX-32] MUST:** Timeouts are set per upstream class, not globally, using the table in §5.
> **Why:** One global `proxy_read_timeout` cannot be right for an API (a 60 s hang must fail)
> and a broker WebSocket (idle for an hour by design). The default 60 s silently kills MQTT
> connections and the client reconnect-loops, which looks like a broker problem.

**[NGX-22] MUST:** `client_max_body_size` is `1m` at server level and raised only inside
upload locations (`50m`).
> **Why:** The reference deployment had `client_max_body_size 1024M` at server level, which
> lets any unauthenticated client park a gigabyte in the container's `/tmp` on any path,
> including `/healthz`. Scope the large limit to the paths that need it.
> `check-standards.sh` flags a limit above 100 MB.

**[NGX-33] MUST:** `proxy_request_buffering off` on upload locations, and
`proxy_buffering off` on SSE, WHEP signalling and any streaming response.
> **Why:** With request buffering on, nginx writes the entire upload to disk before opening
> a connection to the upstream, so a 50 MB upload starts 20 s late and doubles the disk I/O.
> With response buffering on, an SSE stream is invisible until the buffer fills, which for a
> low-rate event stream can be minutes.

**[NGX-34] MUST:** WebSocket locations use the `$connection_upgrade` map, not a literal
`Connection 'upgrade'`.
> **Why:** Hard-coding `upgrade` sends it on ordinary requests too, which disables upstream
> keepalive and confuses HTTP/1.1 upstreams. The map sends `upgrade` only when the client
> asked for it.

```nginx
# http{} level
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      '';
}
# server{} level
location /mqtt {
    set $mqtt_backend "${NGINX_UPSTREAM_MQTT}";
    proxy_pass http://$mqtt_backend/mqtt;
    proxy_http_version 1.1;
    proxy_set_header Upgrade    $http_upgrade;
    proxy_set_header Connection $connection_upgrade;
    proxy_read_timeout 3600s;      # a broker connection is idle by design
    proxy_send_timeout 3600s;
    proxy_buffering    off;
}
```

**[NGX-35] MUST:** `proxy_intercept_errors on` on `/api/`, with a JSON error page whose shape
matches the backend error contract, and an HTML error page everywhere else.
> **Why:** An upstream 502 body is often an HTML stack trace or a Java exception page. The
> API client parses every error body as JSON ([API-05]); handing it HTML turns a clean
> "service unavailable" into a parse exception with no useful message, and shows internal
> hostnames to the user ([SEC-24]).

```nginx
location @api_error {
    include /etc/nginx/snippets/security-headers.conf;
    add_header Cache-Control "no-store" always;
    default_type application/json;
    return 502 '{"error":{"code":"upstream_unavailable","message":"Service temporarily unavailable","requestId":"$req_id"}}';
}
```
Observed against a stopped upstream:
```
$ curl -s -w ' [%{http_code}]' http://localhost:8080/api/x
{"error":{"code":"upstream_unavailable","message":"Service temporarily unavailable","requestId":"3ae572dc4eed78a6750c5a33bc44c268"}} [502]
```

---

## 6. Tile cache and rate limiting

**[NGX-36] MUST:** Tile responses are cached in nginx with `proxy_cache_path` on a
**persistent, writable** path.
> **Why:** A basemap pan re-requests the same tiles constantly. Caching them at the edge
> removes both the network hop and the tile server's disk read; on the reference deployment
> the tile server was the only component that ever showed queueing. `use_temp_path=off` keeps
> temp writes on the same filesystem so completing an entry is a rename, not a copy. The path
> must be a named volume (or a tmpfs with `uid=101,gid=101`), otherwise nginx exits with
> `[emerg] mkdir() "/var/cache/nginx/tiles" failed (13: Permission denied)` ([OPS-25]).

```nginx
# http{} level
proxy_cache_path /var/cache/nginx/tiles
                 levels=1:2 keys_zone=tiles:50m max_size=5g inactive=7d use_temp_path=off;
```
```nginx
# in location /tiles/
proxy_cache            tiles;
proxy_cache_key        "$scheme$request_method$host$request_uri";
proxy_cache_valid      200 206  7d;
proxy_cache_valid      404      1m;
proxy_cache_lock       on;            # one fill per key; the other 31 tiles wait
proxy_cache_lock_timeout 5s;
proxy_cache_use_stale  error timeout updating http_500 http_502 http_503 http_504;
proxy_cache_background_update on;
proxy_ignore_headers   Cache-Control Expires Set-Cookie X-Accel-Expires Vary;
include /etc/nginx/snippets/security-headers.conf;
add_header X-Cache-Status $upstream_cache_status always;
add_header Cache-Control "public, max-age=86400" always;
```

Sizing: `keys_zone=50m` holds roughly 400,000 keys (about 8 KB of zone per 1,000 keys);
`max_size=5g` at an average 12 KB MVT is about 400,000 tiles, which matches. `inactive=7d`
evicts what nobody asked for in a week.

**[NGX-37] MUST:** `X-Cache-Status: $upstream_cache_status` is returned, and cache
invalidation is by **key change**, not by purge.
> **Why:** `HIT`/`MISS`/`EXPIRED`/`STALE`/`UPDATING` in DevTools is the only cheap way to
> tell "the tile server is slow" from "the cache is not being used". Purging needs the
> commercial `proxy_cache_purge` module; the open-source answer is to include a version
> segment in the tile URL (`/tiles/parcels/v3/{z}/{x}/{y}.pbf`) so a data reload changes the
> key. The nuclear option, documented and accepted, is
> `docker compose exec web rm -rf /var/cache/nginx/tiles/*` followed by a reload.

**[NGX-38] MUST:** `/api/` is rate limited with `limit_req_zone` on
`$binary_remote_addr`, `burst=40 nodelay`, returning 429.
> **Why:** It exists to stop a runaway client retry loop or a scripted scrape, not to shape
> normal traffic: 20 r/s sustained is about ten times what a map dashboard generates.
> `nodelay` serves the burst immediately instead of queueing it, which is what an interactive
> UI needs. `$binary_remote_addr` rather than `$remote_addr` because it is 4 bytes instead of
> 15, so the same zone holds four times as many clients.

**[NGX-39] MUST:** Behind a load balancer or another proxy, `set_real_ip_from` and
`real_ip_header X-Forwarded-For` are configured before any rate limit or log uses the client
address.
> **Why:** Otherwise `$binary_remote_addr` is the load balancer's address for every request:
> the rate limit throttles the entire user base as one client, and every log line shows the
> same IP. `set_real_ip_from` must list the proxy's network, never `0.0.0.0/0`, or any client
> can forge its own address.

---

## 7. Logging

**[NGX-40] MUST:** Access logs are JSON with `escape=json`, written to `/dev/stdout`;
errors go to `/dev/stderr` at `warn`.
> **Why:** Container logs are the only logs; `/var/log/nginx` is not writable under
> `read_only: true` and nothing rotates it anyway ([OPS-12] handles rotation at the Docker
> level). `escape=json` is not optional: a user agent containing a quote otherwise produces a
> line the shipper cannot parse, and one bad line can break a whole batch.

**[NGX-41] MUST:** The log format includes `$request_id`, `$upstream_addr`,
`$upstream_status`, `$upstream_response_time`, `$request_time` and `$upstream_cache_status`.
> **Why:** These answer "which backend, how long, from cache?" in one line. Without
> `$upstream_addr` a 502 requires opening the error log to find out which of eight upstreams
> failed; with it, the answer is in the same line as the status.

**[NGX-42] MUST:** Sensitive query parameters are masked with `map` before they reach the log.
> **Why:** Tokens arrive in query strings from third-party callbacks and from `<img>`-style
> tile requests that cannot set a header. A token in a log file is a credential in a log
> file, shipped to wherever logs go, retained for as long as logs are retained ([SEC-25],
> [OBS-17]). The `token=` rule keeps the first 8 and last 6 characters so a support ticket
> can still be correlated; everything else is replaced whole. Note the quoting: the `{8}`
> makes the quotes mandatory ([NGX-14] trap 3).

```nginx
map $request_uri $uri_token_masked {
    "~*^(.*[?&]token=)([^&]{8})[^&]+([^&]{6})((&.*)?)$"  "$1$2...$3$4";
    "~*^(.*[?&]token=)[^&]+((&.*)?)$"                    "$1***$2";
    default $request_uri;
}
map $uri_token_masked $loggable_uri {
    "~*^(.*[?&](password|pwd|secret|api_key|apikey|access_token)=)[^&]*((&.*)?)$" "$1***$3";
    default $uri_token_masked;
}
map $request_uri $loggable_request { "~^/healthz" 0; default 1; }

log_format json escape=json
    '{"time":"$time_iso8601","remote_addr":"$remote_addr","request_id":"$req_id",'
    '"method":"$request_method","uri":"$loggable_uri","status":$status,'
    '"bytes_sent":$body_bytes_sent,"referer":"$http_referer","user_agent":"$http_user_agent",'
    '"request_time":$request_time,"upstream_addr":"$upstream_addr",'
    '"upstream_status":"$upstream_status","upstream_time":"$upstream_response_time",'
    '"cache_status":"$upstream_cache_status"}';

access_log /dev/stdout json if=$loggable_request;
error_log  /dev/stderr warn;
```

**[NGX-43] MUST:** An incoming `X-Request-Id` is preserved and forwarded; nginx generates one
only when the client did not send one. The header name matches [API-07].
> **Why:** The API client generates a request id per logical request and keeps it across
> retries. If nginx overwrote it, the browser's id and the backend's id would differ and the
> two log sets could not be joined, which is the entire point of having one.

```nginx
map $http_x_request_id $req_id {
    default $http_x_request_id;
    ''      $request_id;
}
# then, in every proxy location:
proxy_set_header X-Request-Id $req_id;
```

---

## 8. TLS

**[NGX-44] MUST:** When this nginx terminates TLS: TLSv1.2 and TLSv1.3 only, a shared session
cache, OCSP stapling, a 301 from port 80, and HSTS set here (and nowhere else).
> **Why:** TLS 1.0/1.1 are removed from browsers and fail PCI and public-sector audits.
> `ssl_session_cache shared:SSL:10m` holds roughly 40,000 sessions and removes a full
> handshake from every reconnect, which matters for a map that opens many connections.
> Stapling saves the browser an OCSP round trip on the first connection.

```nginx
server {
    listen 8443 ssl;
    http2 on;                       # nginx >= 1.25 form; http2 without TLS is not supported
                                    # by browsers, so this line belongs only in a TLS server
    server_name ${NGINX_PUBLIC_HOST};

    ssl_certificate     /etc/nginx/certs/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_prefer_server_ciphers off;   # TLS 1.3 picks its own; for 1.2 the client's order is fine
    ssl_ciphers         ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_session_cache   shared:SSL:10m;
    ssl_session_timeout 1d;
    ssl_session_tickets off;         # tickets without rotation weaken forward secrecy
    ssl_stapling        on;
    ssl_stapling_verify on;
    resolver 127.0.0.11 valid=10s ipv6=off;

    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    # ... the rest of the server block, identical to the plain-HTTP one
}

server {
    listen 8080;
    server_name ${NGINX_PUBLIC_HOST};
    return 301 https://$host$request_uri;
}
```

**[NGX-45] MUST:** When TLS terminates upstream, this nginx sets no HSTS, enables no
`http2`, and only reads `X-Forwarded-Proto` (it must be forwarded onward unchanged).
> **Why:** `http2 on` without `ssl` is h2c, which no browser speaks; the directive is
> accepted and does nothing except confuse the next reader. And see [NGX-24] for HSTS.

---

## 9. Local and production parity

**[NGX-46] MUST:** The same `nginx.conf` and `security-headers.conf` are used locally and in
production, and environment differences are expressed only through the env file.
> **Why:** A configuration that is only exercised in production is tested in production.
> Mounting the real files into the dev edge container means a broken `map` or a bad
> `add_header` fails on a laptop.

**[NGX-47] MUST:** The dev stack runs the real nginx in front of the Vite dev server, proxying
`/` to `vite:5173` with WebSocket upgrade for HMR.
> **Why:** Vite's own proxy and nginx do not behave identically on trailing slashes, prefix
> stripping or WebSocket upgrades. Running nginx locally is what makes a prefix collision
> (`/map/` versus the `/map-data` route) show up before the deploy. The dev server block is a
> separate 100-line file whose proxy locations mirror the production ones; the accepted cost
> is that it can drift, and checking it is item 20 of the review checklist below.

```nginx
# dev.conf.template (the part that differs). Everything above / is identical in shape.
location / {
    set $vite_backend "${NGINX_UPSTREAM_VITE}";
    proxy_pass http://$vite_backend;
    proxy_http_version 1.1;
    proxy_set_header Upgrade    $http_upgrade;      # HMR is a WebSocket on the same path
    proxy_set_header Connection $connection_upgrade;
    proxy_set_header Host $http_host;
    proxy_read_timeout 120s;      # a cold dep pre-bundle can take 20 s
    proxy_buffering off;          # the module graph is streamed
}
```

**[NGX-48] MUST:** Every nginx change is smoke-tested against a running container before the
PR is opened, and the output is pasted into the PR.

```bash
bash tools/nginx-smoke.sh deployments/main/nginx/default.conf.template \
                          deployments/main/.env.example \
                          --url http://localhost:8080
#   PASS  [NGX-06] GET /healthz -> 200 ok
#   PASS  [NGX-05] / -> Cache-Control: no-cache
#   PASS  [NGX-05] /config.js -> Cache-Control: no-store
#   PASS  [NGX-11] header present: x-content-type-options
#   PASS  [NGX-11] header present: referrer-policy
#   PASS  [NGX-11] header present: x-frame-options
#   PASS  [NGX-12] no nginx version in the Server header
#   PASS  [NGX-04] /assets/index-Ab12Cd34.js -> immutable
#   PASS  [NGX-13] *.map -> 403
```

---

## 10. SEO routing hooks

Details are owned by [10-SEO-RENDERING.md]; this is the nginx side.

**[NGX-49] MUST:** SEO-indexed prefixes have their own locations **before** the SPA fallback,
and a miss inside them returns a real 404, not `index.html` with status 200.
> **Why:** A 200 for a URL with no content is a soft-404. Google indexes it, then penalises
> the site for thin content, and the wrong page can outrank the right one ([GEN-11]).

```nginx
# Public, indexed section: a miss must 404, not fall through to the SPA.
location ^~ /haberler/ {
    include /etc/nginx/snippets/security-headers.conf;
    add_header Cache-Control "no-cache" always;
    try_files $uri /index.html;      # tier 1: the SPA renders it, but the route exists
}
```

**[NGX-50] MUST:** `sitemap.xml` and (for a tier 2 SEO app) `robots.txt` are proxied to the
backend, never served from `dist/`.
> **Why:** A sitemap built into the artefact freezes at build time and keeps advertising last
> Tuesday's content ([GEN-11]). The backend generates it from the database on request.

```nginx
location = /sitemap.xml {
    proxy_pass http://api_backend/public/sitemap.xml;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_set_header Host $http_host;
}
```

---

## 11. Location matching: the precedence rules

nginx does **not** match locations top to bottom. The order is:

1. Exact match `location = /path`: wins immediately, nothing else is evaluated.
2. Longest matching prefix with `^~`: wins, and **regex locations are skipped**.
3. Regex locations `~` (case-sensitive) and `~*` (case-insensitive), **in file order**,
   first match wins.
4. The longest matching prefix found in step 2 without `^~`.

Three worked examples from a real GIS application.

### `/fonts/*.pbf` to the tile server, `/fonts/*.ttf` to the static bundle

The map server serves glyph ranges at `/fonts/<fontstack>/<range>.pbf`; the PDF export loads
`/fonts/NotoSans-Regular.ttf` from `public/`. Same prefix, two destinations.

```nginx
# Regex beats any prefix location (rule 3 before rule 4), so this wins for .ttf/.woff2.
location ~ ^/fonts/.+\.(ttf|otf|woff2?)$ {
    include /etc/nginx/snippets/security-headers.conf;
    add_header Cache-Control "public, max-age=31536000, immutable" always;
    try_files $uri =404;
}
# Everything else under /fonts/ (the .pbf glyph ranges) goes to the map server.
location /fonts/ {
    set $map_backend_fonts "${NGINX_UPSTREAM_MAP}";
    proxy_pass http://$map_backend_fonts;
}
```
If the static rule were written as a prefix (`location /fonts/static/`) the app would have to
know two different font paths; the regex keeps one path and splits by extension.

### `/map/` versus the `/map-data` SPA route

`location /map/` (with the trailing slash) matches `/map/styles/basic.json` but **not**
`/map-data`. Written as `location /map`, it also matches `/map-data`, which is then rewritten
to `/-data` and forwarded to the map server, producing `Cannot GET /-data`. This exact bug
cost an afternoon on the reference project, in the Vite proxy first and then again in nginx.

**[NGX-51] MUST:** A proxy prefix that could also be the start of an SPA route ends with a
slash, in both the nginx config and the Vite dev proxy.
> **Why:** See above. `check-standards.sh` §F cross-checks router paths against dev-proxy
> prefixes for exactly this collision.

### `= /bi` and `= /bi/` versus `/bi/`

A wrapper page at `/bi` hosts an iframe; everything deeper belongs to the BI service.

```nginx
location = /bi   { proxy_pass http://api_backend; }   # exact: the wrapper page
location = /bi/  { proxy_pass http://api_backend; }   # exact: same, with the slash
location /bi/    {                                    # prefix: everything deeper
    set $bi_backend "${NGINX_UPSTREAM_BI}";
    rewrite ^/bi/(.*)$ /$1 break;
    proxy_pass http://$bi_backend;
    proxy_set_header X-Forwarded-Prefix /bi;
}
```
Without the two exact locations, `/bi/?p=dashboard` matched the prefix, reached the BI
service's root, and its redirect dropped the `:90` port ([NGX-30]).

---

## 12. Review checklist

Twenty items. Each is a `grep` or a `curl` away.

1. `nginx -t` passes on the rendered config, in the runtime image ([NGX-15]).
2. No `${VAR}` left unsubstituted in the rendered output ([NGX-14]).
3. No `proxy_pass http:///` in the rendered output ([NGX-14], [OPS-20]).
4. `index.html` is `no-cache`, `/config.js` is `no-store` ([NGX-05]).
5. `/assets/` is `immutable` and is a plain prefix, not `^~` ([NGX-04], [NGX-08]).
6. `try_files $uri =404` inside `/assets/` ([NGX-04]).
7. SPA fallback exists and is the last location ([NGX-03]).
8. Every location with an `add_header` includes `security-headers.conf` ([NGX-10]).
9. Every `add_header` has `always` ([NGX-10]).
10. `server_tokens off` ([NGX-12]).
11. `*.map` and dotfiles denied; verified with `curl` ([NGX-13]).
12. `/healthz` exists, returns `ok`, and is not logged ([NGX-06]).
13. `gzip_static on`; `.gz` siblings exist in `dist/` ([NGX-07]).
14. MVT is not in `gzip_types` ([NGX-21]).
15. Every variable `proxy_pass` has a `resolver` in scope ([NGX-17]).
16. `Host $http_host` (not `$host`) on every proxy location ([NGX-28]).
17. `client_max_body_size` is `1m` at server level ([NGX-22]).
18. Timeouts are set per class; no MQTT/SSE location on the 60 s default ([NGX-32]).
19. Query-parameter masking maps are present and quoted ([NGX-42]).
20. `dev.conf.template` has the same set of proxy prefixes as `default.conf.template`,
    with the same trailing slashes ([NGX-47]).

## 13. Troubleshooting

| Symptom | Directive to look at |
|---|---|
| nginx will not start: `host not found in upstream` | A static `upstream{}` for a service that is down. Convert to `set $var` + `resolver` ([NGX-27], [NGX-17]) |
| nginx will not start: `invalid URL prefix` | An empty template variable rendered `proxy_pass http:///` ([NGX-14]) |
| nginx will not start: `unexpected "{"` | An unquoted regex containing `{n}` in a `map` ([NGX-14]) |
| nginx will not start: `"map" directive is not allowed here` | A `map` in the server template instead of `nginx.conf` ([NGX-02]) |
| nginx will not start: `duplicate extension "wasm"` | A `types{}` entry that `mime.types` already defines ([NGX-09]) |
| nginx will not start: `mkdir() "/var/cache/nginx/..." failed (13)` | `proxy_cache_path` on a root-owned tmpfs ([NGX-36], [OPS-25]) |
| Security headers missing on some paths only | An `add_header` in that location replaced the inherited set ([NGX-10]) |
| Headers present on 200, missing on 404 | An `add_header` without `always` ([NGX-10]) |
| `Uncaught SyntaxError: Unexpected token '<'` for a JS file | A missing asset fell through to the SPA fallback; add `try_files $uri =404` ([NGX-04]) |
| Users on an old bundle after a deploy | `index.html` cached; check `location = /index.html` and `no-cache` ([NGX-05]) |
| Every deploy re-downloads the whole bundle | `/assets/` missing `immutable`, or hashing disabled in the build ([NGX-04]) |
| Redirect loses the `:90` port | `absolute_redirect off` missing, or `Host $host` instead of `$http_host` ([NGX-28], [NGX-30]) |
| Map is blank, glyphs 404 at the origin root | `X-Forwarded-Prefix` missing on the prefix-stripping location ([NGX-29]) |
| Tiles are slow, `netstat` shows many connections to the tile server | Missing `keepalive` / `proxy_http_version 1.1` / `Connection ""` ([NGX-26]) |
| MQTT reconnects every 60 s | `proxy_read_timeout` left at the default ([NGX-32]) |
| SSE events arrive in bursts or not at all | `proxy_buffering off` missing ([NGX-33]) |
| WebSocket upgrade fails with 400 | `$connection_upgrade` map missing, or `Connection` hard-coded ([NGX-34]) |
| Large upload returns 413 | `client_max_body_size` not raised in the upload location ([NGX-22]) |
| API returns an HTML error page to the client | `proxy_intercept_errors` / `@api_error` missing ([NGX-35]) |
| One IP is rate-limited for everyone | `real_ip_header` not configured behind the load balancer ([NGX-39]) |
| `/map-data` route forwards to the map server | Proxy prefix written without a trailing slash ([NGX-51]) |

---

## Open questions

- **Brotli.** [NGX-20] is a `SHOULD` that the current image cannot satisfy. Deciding
  condition: whether the organisation will maintain a custom nginx image (or move to the
  Debian-based `nginx:1.30` with `nginx-module-brotli`). Until then `vite-plugin-compression2`
  keeps emitting `.br` files that are never served; the alternative is to disable brotli
  output and save about a second of build time.
- **Cache purge.** Without the commercial module there is no selective purge ([NGX-37]).
  Deciding condition: a data pipeline that reloads tiles more often than weekly. The
  candidate answer is a version segment in the tile path, which needs a coordinated change
  in the tile service and [08-MAP-MAPLIBRE.md].
- **Sharing proxy locations between the production and dev server blocks.** They are
  duplicated today ([NGX-47]). Factoring them into an included fragment requires rendering a
  non-server template and an explicit (non-glob) include chain; that complexity has not yet
  been paid for by an actual drift incident.
