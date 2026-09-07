# ADR-0014 — Environment configuration: `/config.js` rendered at container start

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-09], [GEN-10], [STR-20], [OPS-07], [OPS-08], [OPS-14], [OPS-20], [OPS-21], [OPS-23], [NGX-05], [SEC-13], [OBS-05]

## Context

A frontend needs values that differ per environment: the API base path, the tile base path,
the map style URL, the MQTT WebSocket path, the environment name, the release id, the public
site URL and a feature-flag set. None of them are secret ([GEN-10]); everything shipped to a
browser is public by definition.

Vite's native answer is `import.meta.env.VITE_*`, resolved at **build** time and inlined
into the bundle as string literals. The reference deployment used it: five `VITE_*` build
arguments in the Dockerfile, passed through compose from `.env.prod`, plus
`VITE_MQTT_USERNAME` and `VITE_MQTT_PASSWORD`, which put a broker credential into a file any
visitor can read.

The consequence that matters more than the credential leak: a build-time value means the
image is environment-specific. Staging and production are different artefacts. The image
that passed the staging smoke test is not the image that goes to production, so the test
proves less than it appears to. Rolling back means rebuilding rather than redeploying a tag
([OPS-37]).

The constraint that shapes the answer: `index.html` is a static file served by nginx with
`sendfile` and `gzip_static` ([ADR-0013](0013-static-serving.md)), and the module bundle
must be able to read the configuration synchronously, before React mounts.

## Options

### A) `/config.js` setting `window.__APP_CONFIG__`, rendered by envsubst at container start (CHOSEN)

`config.js.template` lives in the image. A `/docker-entrypoint.d/` script validates the
required environment variables, exits 1 naming any that is empty, and renders the template
into a tmpfs path that nginx serves at `/config.js` with `Cache-Control: no-store`.
`index.html` loads it with a plain classic `<script src="/config.js">` before the module
script. `runtimeConfig.ts` parses `window.__APP_CONFIG__` with a zod schema and exports a
frozen object ([STR-20]).

**Strengths:** one image for every environment, which is [GEN-09]. Deploying to a new
environment is an env file, not a build. A classic script is executed synchronously in
document order, so the value is present before the module bundle runs, with no race and no
extra round trip. The validating entrypoint turns a missing variable into a container that
refuses to start with the variable's name in the log, instead of an app that boots and
fails obscurely later. Rollback is redeploying a tag. The same mechanism carries the release
id ([OBS-05]), which is what makes `/__version.json` and error-report symbolication line up.

**Weaknesses (accepted, not hidden):** the configuration is a **global on `window`**, which
is exactly the mutable global state the standard discourages elsewhere; the mitigation is
that exactly one module reads it and it is frozen. It cannot be tree-shaken or type-checked
at build time, so `runtimeConfig.ts` must validate at runtime and every consumer goes through
that module. It adds one small blocking request before the module bundle (about 400 bytes,
same connection, no DNS, measured under 3 ms locally) which is on the critical path for LCP.
There are now two places a value can be wrong (the env file and the schema) instead of one.
And `npm run dev` does not serve `/config.js` at all, so local development needs a
`public/config.js` or a development fallback ([11-DOCKER-COMPOSE.md](../11-DOCKER-COMPOSE.md) §7).

### B) `VITE_*` build arguments

**Strengths:** fully type-checked through `vite-env.d.ts`. Dead code behind a false flag is
eliminated by the bundler. Zero runtime cost, zero extra request. No `window` global. It is
what Vite's documentation shows, so an AI or a new engineer reaches for it first.

**Weaknesses:** one image per environment. The tested artefact is not the deployed artefact.
A URL change requires a full rebuild (60 to 125 s of `npm ci` plus the build, or a
cache-busted build at minimum) rather than a container restart. Values are inlined as string
literals scattered through the bundle, so "what is this build pointing at" is answered by
grepping minified JavaScript. It invites secrets, because a build argument feels private:
the reference project's `VITE_MQTT_PASSWORD` is the proof. Rollback means rebuilding an old
commit, which re-resolves whatever the lockfile does not pin.

`VITE_*` is retained for exactly one thing, the build id ([OPS-14]), because it is a
property of the artefact rather than of the environment.

### C) `fetch('/config.json')` at boot

**Strengths:** the configuration is data, not code, so it can be validated with a JSON schema
by anything, cached deliberately, and served by any static host. No `window` global, no
inline script. A CSP with `script-src 'self'` is unaffected.

**Weaknesses:** an extra round trip before the app can render anything, on the critical path.
Worse, it races with the module graph: `main.tsx` may execute before the fetch resolves, so
every consumer becomes asynchronous or the whole app waits behind a promise, and a module
that reads config at import time (a MapLibre style URL, the API client's base URL) has to be
restructured. That restructuring is not local: it reaches into `client.ts`, the map
initialisation and the i18n setup. The failure mode is also worse: a 404 on `/config.json`
produces an app that renders a shell and then fails per feature, instead of a container that
does not start.

### D) nginx `sub_filter` injecting values into `index.html`

**Strengths:** no extra request at all, and the values arrive in the document itself. nginx
already has the environment variables, so no template file is needed beyond `index.html`.
It is the only option here that can also inject a per-request CSP nonce.

**Weaknesses:** `sub_filter` operates on the response body, which disables `gzip_static` and
`sendfile` for `index.html` (nginx cannot rewrite a precompressed file). It requires
`sub_filter_once off` and a placeholder in `index.html`, so the built artefact contains a
marker that must survive minification. Every value needs its own `sub_filter` line, and a
value containing the placeholder text corrupts the output. Debugging is unpleasant: the file
on disk and the file served differ. It is the right tool when `index.html` must be
per-request anyway ([SEC-09]), and the wrong tool for eight static strings.

## Decision

Runtime configuration is `/config.js` setting `window.__APP_CONFIG__`, rendered from
`config.js.template` by `/docker-entrypoint.d/20-render-config.sh` at container start, served
`no-store`, loaded by a classic script before the module bundle, and parsed by a zod schema in
`src/app/config/runtimeConfig.ts`.

The variable set is fixed and closed ([OPS-21]): `APP_API_BASE_URL`, `APP_TILE_BASE_URL`,
`APP_MAP_STYLE_URL`, `APP_MQTT_WS_URL`, `APP_ENVIRONMENT`, `APP_RELEASE`, `APP_SITE_URL`,
`APP_FEATURES_JSON`. Adding one is three coordinated edits: the template, the entrypoint's
required list, and the zod schema.

`VITE_*` build arguments are limited to `VITE_BUILD_ID` and `check-standards.sh` fails the
build on any other.

Migration for the reference project: replace the five `VITE_*` build args with the `APP_*`
runtime set in the same PR that adopts [ADR-0013](0013-static-serving.md), and delete
`VITE_MQTT_USERNAME` / `VITE_MQTT_PASSWORD` outright. A broker credential in the bundle is
not a configuration problem, it is a published credential: the broker must be reachable
through the same-origin `/mqtt` proxy with a short-lived, per-session credential ([SEC-19]).

## Accepted costs

- **A mutable global.** `window.__APP_CONFIG__` is exactly the pattern the standard
  discourages. It is frozen, read by one module, and typed only through a runtime schema.
- **One blocking request** (about 400 bytes) ahead of the module bundle, on the LCP path.
- **No build-time type safety.** A typo in the template is caught by the zod parse at boot,
  not by `tsc`. The compensation is that the failure names the field ([STR-20]).
- **Development divergence.** `npm run dev` does not run the entrypoint, so local
  development uses a git-ignored `public/config.js`. That file can drift from the template,
  and nothing checks it.
- **Two sources of truth for the same value.** `APP_RELEASE` (runtime) and `__APP_RELEASE__`
  (compile-time `define`) must agree; [OBS-05] compares them and warns once when they do not.
- **Feature flags are a deploy, not a toggle.** Changing `APP_FEATURES_JSON` restarts the
  container. Anything that needs to change without a restart belongs to a backend-served
  flag endpoint, not here.

## What would change this decision

- `index.html` becomes per-request (request-time meta injection or SSR,
  [10-SEO-RENDERING.md] tier 2 or 3). Then option D is nearly free and also supplies the CSP
  nonce that [SEC-09] currently forbids, so the config would move into the document.
- Feature flags need to change without a container restart, or need per-user targeting. Then
  the flag subset moves to a backend endpoint read through TanStack Query, and `/config.js`
  keeps only the bootstrap values (base URLs, environment, release).
- The bundle grows a genuine need for build-time dead-code elimination based on an
  environment value (a whole feature that must not ship to one deployment at all). That
  argues for a `VITE_*` flag for that one case, and the ADR would record the exception with
  the reason, not reopen the general rule.
- The app is ever served from object storage with no container start hook ([ADR-0013](0013-static-serving.md)
  option D). Then option C is the only one that still works and its asynchronous cost has to
  be paid.
