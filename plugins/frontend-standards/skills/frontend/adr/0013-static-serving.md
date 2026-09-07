# ADR-0013 — Serving the static bundle: nginx inside the application image

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-12], [GEN-13], [OPS-02], [OPS-19], [NGX-03], [NGX-04], [NGX-05], [NGX-07], [NGX-11], [PERF-10]

## Context

A Vite build produces `dist/`: one `index.html`, a set of content-hashed assets under
`assets/`, and copied `public/` files. Something has to serve it over HTTP with correct
cache headers, a SPA fallback, compression, security headers, and a reverse proxy to the
backend services so the browser stays same-origin ([GEN-22]).

The reference deployment answered this with `npm install -g serve` in the runtime stage,
`serve -s dist -l 5173 -c serve.json`, and a **second** container running stock nginx in
front of it for the proxying. That arrangement is what this decision replaces, so its
measured costs are the evidence:

- Two proxy hops for every request, including every tile.
- No `gzip_static`. `vite-plugin-compression2` emitted `.br` and `.gz` siblings that were
  never served; every response was compressed at request time or not at all.
- Cache control limited to `serve.json`'s source/headers pairs: `/assets/**` immutable and
  `**` no-store. `index.html` therefore got `no-store` instead of `no-cache`, and there was
  no way to give `/config.js` a different policy from a `.geojson` in `public/data/`.
- No security headers at all, on any response.
- Runtime image around 150 MB, because Node and a global npm package stay in it.
- No per-path proxying, no proxy cache, no rate limiting, no request-id propagation:
  everything the second nginx did, and nothing the first container could see.

The frontend also has to serve vector tiles through a proxy cache, terminate or forward
WebSockets, and expose an operational health endpoint. The choice is really "which server
do we become expert in", because whichever it is, the team will debug it at 2 a.m.

## Options

### A) nginx inside the application image, serving `dist/` directly (CHOSEN)

One container: `nginxinc/nginx-unprivileged:1.30-alpine` with `dist/` at
`/usr/share/nginx/html`, the server block rendered from a template at start.

**Strengths:** one hop. `gzip_static` makes the build-time compression [PERF-10] already
pays for actually useful. Per-location cache policy, so `index.html` is `no-cache`,
`/config.js` is `no-store` and `/assets/` is `immutable`, which is [GEN-12] verbatim.
Security headers, proxy cache for tiles, `limit_req`, WebSocket upgrade, request-id
propagation and structured JSON logging are all directives that already exist. Runtime
image about 25 MB plus the bundle. The same config file is used locally
([NGX-46]), so it is exercised before it ships. `nginx -t` is a two-second CI gate
([NGX-15]).

**Weaknesses (accepted, not hidden):** nginx configuration is genuinely difficult, and the
failure modes are unforgiving. The `add_header` inheritance rule ([NGX-10]) silently strips
headers. `proxy_pass` trailing-slash semantics are not guessable ([NGX-25]). A static
`upstream{}` whose host does not resolve prevents nginx from starting at all ([NGX-27]).
There is no hot reload of the config: a change means restarting the container. The whole of
[12-NGINX.md](../12-NGINX.md) exists because of this weakness; the mitigation is that the
configuration is written once, kept in templates, and machine-checked.

### B) Node static server (`serve`, `http-server`, `express.static`) behind an nginx proxy

**Strengths:** the same language as the build, so no new syntax. `serve.json` is JSON, which
an AI or a junior engineer edits without fear. Slightly easier to embed request-time logic
(a header computed in JavaScript).

**Weaknesses:** every item in the Context section. Two containers to run, two to keep
healthy, two sets of logs to correlate. `serve` has no precompressed-file support, no proxy
cache, no rate limiting, and a cache-header model with two levels of granularity. Node uses
roughly 60 MB of RSS to do what nginx does in 12 MB, and the image is six times larger. And
the nginx in front still exists, so the team does not escape learning nginx; it just learns
it while also maintaining a second server.

### C) Caddy

**Strengths:** the smallest correct config of the three. Automatic HTTPS with ACME, sane
defaults, `file_server` plus `try_files` plus `reverse_proxy` in about ten lines. Static
Go binary, small image. `encode zstd gzip` at request time is built in.

**Weaknesses:** it is a second web server in an organisation whose backend standard, tile
services and shared edge proxy are already nginx, which violates the spirit of [GEN-01] at
the infrastructure layer. Precompressed-file serving needs the third-party
`caddy-precompressed` module (so a custom build), which is exactly the maintenance burden
[NGX-17] refuses for brotli. Its proxy cache needs `souin`, another third-party module.
Automatic HTTPS, its main advantage, is not usable here because TLS terminates at a shared
edge proxy or a municipal load balancer. The operational knowledge in the team, and the
existing `nginx.conf.template` with its hard-won resolver and keepalive tricks, would be
thrown away for a config file that is nicer to read.

### D) Object storage plus a CDN (S3-compatible bucket, CloudFront/Cloudflare)

**Strengths:** no server to run, no container to restart, per-file cache control, global
edge caching, and it scales to any traffic without thought.

**Weaknesses:** the deployment target is a municipal data centre on a private network
(`172.22.x.x` upstreams), often air-gapped from the public internet, so a public CDN is not
reachable and frequently not permitted by procurement. The SPA fallback needs a CDN error-page
rule per distribution. The proxy to `/api/`, `/tiles/` and `/mqtt` would have to move
somewhere else, reintroducing a reverse proxy and CORS ([GEN-22] forbids the cross-origin
version). And the tile proxy cache, which is the single highest-value nginx feature here,
has no equivalent.

## Decision

Serve `dist/` with nginx from inside the application image, as a single container. Remove
the Node static server and the separate nginx proxy container; their responsibilities merge
into one server block rendered from `default.conf.template` ([NGX-01]).

Migration for the reference project, in order:

1. Copy `templates/nginx/*` into `deployments/main/nginx/` and
   `templates/docker/Dockerfile` over the existing one.
2. Move each `location` from the existing `nginx.conf.template` into the new template,
   keeping the resolver, keepalive, `absolute_redirect off` and masking-map patterns, which
   are already correct and are now [NGX-27], [NGX-26], [NGX-30] and [NGX-42].
3. Rename the upstream variables to the `NGINX_UPSTREAM_*` convention ([OPS-35]) and remove
   the `VITE_*` build args in the same PR, replacing them with `/config.js` ([ADR-0014](0014-runtime-config.md)).
4. Delete `serve.json`, the `npm install -g serve` line and the second nginx service.
5. `bash tools/nginx-smoke.sh ... --url http://localhost:<port>` must pass before the PR
   is opened ([NGX-48]).

The reference project's `/bi`, `/pano`, `/geology`, `/martin` and `/planning/tiles/`
locations move across unchanged; they are a good example of [NGX-27], not a problem.

## Accepted costs

- **nginx expertise is now mandatory.** Every frontend engineer must understand location
  precedence, `add_header` inheritance and `proxy_pass` slash semantics. That is a real
  training cost, paid for with [12-NGINX.md](../12-NGINX.md), the review checklist in §12
  and `check-standards.sh` §E.
- **A config change requires a container restart.** `nginx -s reload` is not available
  through the standard entrypoint because the template is rendered at start. Restarting the
  frontend container is a sub-two-second gap ([OPS-37]).
- **Brotli is unavailable** in the unprivileged alpine image, so [PERF-10]'s `.br` files go
  unused until the open question in [12-NGINX.md](../12-NGINX.md) is resolved. gzip_static
  still applies, so the loss is 15 to 20 % of the compressed transfer, not all of it.
- **No request-time logic.** Anything that needs to compute a header per request (a CSP
  nonce, request-time SEO meta) cannot be done here without `sub_filter`, which disables
  `gzip_static` and `sendfile` for that file. This is the boundary that
  [10-SEO-RENDERING.md] tier 2 crosses, and crossing it revisits this ADR.
- **The tile cache is stateful.** A named volume now has to be managed, backed up (or
  explicitly not backed up) and purged by deleting files ([NGX-37]).

## What would change this decision

- The application needs per-request HTML (a CSP nonce, request-time meta injection, SSR).
  At that point a Node server in front of, or instead of, the static serving is back on the
  table, and [SEC-09] flips with it.
- A public, internet-facing portal with traffic that a single container cannot serve, on
  infrastructure where a CDN is reachable and permitted. Then option D for `dist/` plus a
  small nginx for the proxy paths becomes cheaper than scaling containers.
- nginx ships brotli in the official alpine image, or the organisation adopts a maintained
  custom image. That removes one accepted cost but does not change the decision.
- The organisation standardises its edge on something other than nginx (Traefik, Envoy) for
  reasons that come from the backend side. Then option C's "second web server" objection
  disappears and Caddy or the new edge should be re-evaluated for this layer too.
