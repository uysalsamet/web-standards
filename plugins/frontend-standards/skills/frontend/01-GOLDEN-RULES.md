# 01 — Golden Rules

> The 24 items in this file are **not open for discussion**. Everything else in the standard
> derives from them. Each item links to the file with the details; if unsure, go there.
> Read alone, this file is enough to build a frontend correctly.

---

## A. Stack and versions

**[GEN-01] MUST: One stack.** Every web frontend is React 19 + Vite + TypeScript (strict),
built to a static bundle and served by nginx. No Next.js, Remix, CRA, Angular, Vue or
"just one page in plain HTML" inside the same organisation.
> **Why:** Two stacks means two build pipelines, two Docker recipes, two nginx configs, two
> sets of lint rules and two bodies of AI-generated code with different failure modes. The
> second stack never gets the same attention as the first. Detail: [02](02-TECH-VERSIONS.md), [ADR-0001](adr/0001-build-tool.md), [ADR-0002](adr/0002-ui-framework.md).

**[GEN-02] MUST: One version line.** All apps in a repo pin the same major versions from
the table in `02`. Upgrades are done for all apps together, in one PR, with the table updated.
> **Why:** A shared component library compiled against React 19.2 and consumed by an app on
> 19.0 fails at runtime in a way that looks like a bug in your code. Version drift is
> invisible until it is expensive.

**[GEN-03] MUST: Adding a dependency requires approval.** A package not in `02`'s table is
not installed. If it is approved, the table is updated in the same PR.
> **Why:** Every package is an attack surface (npm supply chain), a licence, a bundle-size
> cost and an upgrade debt. Half the "utility" packages replace ten lines of code.
> Detail: [02](02-TECH-VERSIONS.md) §3, [06](06-SECURITY.md) §7.

---

## B. Architecture

**[GEN-04] MUST: Feature-based structure with one-way imports.** `app → features → shared`.
A feature never imports another feature's internals; only its public `index.ts`. `shared`
never imports from `features`.
> **Why:** Cross-feature imports turn the codebase into one big module where nothing can be
> removed, lazy-loaded or tested alone. The direction is enforced by lint, not by good will.
> Detail: [03](03-PROJECT-STRUCTURE.md) §3.

**[GEN-05] MUST: Four kinds of state, four homes.** Server data lives in TanStack Query.
URL-addressable state (selected id, filters, map view) lives in the URL. Cross-feature
client state lives in Redux Toolkit. Everything else is local `useState`/`useReducer`.
Copying server data into Redux is forbidden.
> **Why:** Server data in a client store is a second cache with no invalidation policy. It
> goes stale, it duplicates memory, and every "refresh" bug traces back to it.
> Detail: [05](05-STATE-AND-DATA.md), [ADR-0004](adr/0004-server-state.md), [ADR-0005](adr/0005-client-state.md).

**[GEN-06] MUST: One API client.** All HTTP goes through `src/shared/api/client.ts`: base
URL from runtime config, credentials, timeout, error normalisation, request id. No bare
`fetch()` in features, no `axios`.
> **Why:** Timeout, auth and error-shape handling written in forty places is wrong in
> thirty of them. Detail: [04](04-API-CLIENT.md) §1.

**[GEN-07] MUST: API responses are untrusted input.** Every response body is parsed with a
schema (zod) at the client boundary. `as SomeType` on a response is forbidden.
> **Why:** The backend changes a field from `string` to `null` and the UI crashes three
> screens later with `Cannot read properties of null`. A schema fails at the boundary with
> the endpoint name and the field. Detail: [04](04-API-CLIENT.md) §3.

**[GEN-08] MUST: Files stay under 400 lines; components under 250.** Beyond that, split.
> **Why:** A person (and an AI) editing a 900-line file cannot hold it in context and breaks
> the part they did not read. This is an error-rate rule, not a style rule.

---

## C. Build and configuration

**[GEN-09] MUST: One image for all environments.** The build artefact is environment
agnostic. URLs, feature flags and public keys are injected at container start via
`/config.js` (runtime config), never baked in with `VITE_*` at build time. `VITE_*` is
reserved for values that are constant across all environments.
> **Why:** A build-time value means a separate image per environment, which means the image
> you tested is not the image you deployed. Detail: [11](11-DOCKER-COMPOSE.md) §3, [ADR-0014](adr/0014-runtime-config.md).

**[GEN-10] MUST NOT: Secrets in the frontend.** Nothing that must stay private goes into a
`VITE_` variable, `config.js`, source code or the bundle. Everything shipped to the browser
is public. Third-party keys that must be restricted are proxied through the backend.
> **Why:** `VITE_MQTT_PASSWORD` is readable by anyone who opens DevTools. It is not a
> credential, it is a published string. Detail: [06](06-SECURITY.md) §4.

**[GEN-11] MUST NOT: Time-sensitive content in the build artefact.** SEO meta for dynamic
pages, sitemaps, robots rules, feature-flag values and any API data are not fetched at
build time and frozen into `dist/`. They are served at request time or regenerated on a
schedule with an explicit maximum staleness.
> **Why:** A build made last Tuesday keeps advertising last Tuesday's content to Google
> until someone remembers to rebuild. Search engines index the stale version and penalise
> the mismatch. Detail: [10](10-SEO-RENDERING.md) §2, [ADR-0012](adr/0012-seo-strategy.md).

**[GEN-12] MUST: nginx serves the bundle with correct caching.** `index.html` and
`config.js` are `no-cache`; hashed assets under `/assets/` are `immutable, max-age=1y`.
Unknown SPA paths fall back to `index.html` with status 200 only outside SEO-indexed
prefixes.
> **Why:** Wrong caching on `index.html` means users run last week's app against this
> week's API; wrong caching on assets means every deploy re-downloads 3 MB. A 200 for a
> missing public page is a soft-404 in Google's eyes. Detail: [12](12-NGINX.md) §2, [ADR-0013](adr/0013-static-serving.md).

**[GEN-13] MUST: Docker images are multi-stage, pinned, non-root, health-checked.** The
runtime stage contains nginx and `dist/`, nothing else.
> Detail: [11](11-DOCKER-COMPOSE.md) §1.

---

## D. User-facing behaviour

**[GEN-14] MUST: No literal user-visible strings.** Every string a user can see goes
through i18n. Every locale file has **exactly the same key set**; CI fails otherwise.
Dates, numbers and currencies are formatted with `Intl` for the active locale.
> **Why:** "We'll translate it later" is how a Turkish app ships with five untranslated
> English buttons, and how the English version has 40 keys the Turkish one lacks.
> Detail: [09](09-I18N.md), [tools/check-i18n.mjs](tools/check-i18n.mjs).

**[GEN-15] MUST: Every asynchronous UI has loading, empty, error and success states.**
An error state shows a human message and a retry; it never shows a raw exception.
> Detail: [16](16-ACCESSIBILITY-UX.md) §5, [17](17-ERRORS-OBSERVABILITY.md) §2.

**[GEN-16] MUST: Keyboard and screen-reader baseline.** Interactive elements are real
`<button>`/`<a>`/inputs, focus is visible and managed in modals, contrast meets WCAG AA,
and `eslint-plugin-jsx-a11y` runs in CI.
> Detail: [16](16-ACCESSIBILITY-UX.md).

**[GEN-17] MUST: Errors are never swallowed.** No empty `catch`. Every route has an error
boundary; the map has its own. Unhandled errors and rejections are reported to the error
tracker with a release id. Chunk-load failures after a deploy trigger one reload, not a
white screen.
> Detail: [17](17-ERRORS-OBSERVABILITY.md).

---

## E. Map

**[GEN-18] MUST: Data is rendered by the GPU, not the DOM.** Points, lines and polygons
are MapLibre sources and layers (`circle`, `symbol`, `line`, `fill`). `maplibregl.Marker`
(a DOM element) is allowed only for a handful of rich interactive widgets (a draggable
picker, a live video badge), never for datasets. Hover and selection use `feature-state`,
not `setData`.
> **Why:** 2,000 DOM markers is 2,000 absolutely-positioned elements re-laid-out on every
> frame of every pan; the map drops to 10 fps. The same 2,000 points in a `circle` layer
> cost nothing measurable. Detail: [08](08-MAP-MAPLIBRE.md), [ADR-0009](adr/0009-marker-rendering.md).

**[GEN-19] MUST: Large data becomes tiles.** A GeoJSON source is allowed up to 5,000
features or 2 MB. Beyond that the data is served as vector tiles (MVT) from the tile
service. The browser never downloads a 40 MB GeoJSON.
> Detail: [08](08-MAP-MAPLIBRE.md), [APPENDIX-GIS-DATA.md](APPENDIX-GIS-DATA.md) §4, [ADR-0010](adr/0010-geodata-delivery.md).

**[GEN-20] MUST: One map instance, owned by context, cleaned up completely.** Every layer,
source, image, event listener and popup a feature adds is removed when the feature
unmounts, in the right order (layers before sources), guarded against a map whose style is
not loaded yet.
> Detail: [08](08-MAP-MAPLIBRE.md), §7.

---

## F. Engineering discipline

**[GEN-21] MUST: Cleanup for everything you subscribe to.** Every `addEventListener`,
timer, MQTT subscription, `ResizeObserver`, WebSocket and map listener has a matching
removal in the effect cleanup. StrictMode double-invocation must be survivable.
> **Why:** React 19 mounts, unmounts and remounts effects in development. Code that leaks
> under StrictMode leaks in production on every navigation. Detail: [21](21-TYPESCRIPT-REACT-STYLE.md) §5, [20](20-REALTIME-MEDIA.md) §2.

**[GEN-22] MUST: Same-origin by design.** The browser talks only to its own origin; nginx
proxies `/api/`, `/tiles/`, `/mqtt` etc. to the services. No CORS configuration in the
frontend, no cross-origin `fetch` in application code.
> **Why:** CORS is a symptom of a missing proxy. Cookies, CSP and error handling are all
> simpler on one origin. Detail: [12](12-NGINX.md) §5, [06](06-SECURITY.md) §2.

**[GEN-23] MUST: CI is the gate.** A PR merges only when lint, typecheck, i18n parity,
unit tests, build, bundle-size budget, `nginx -t` on the rendered template and
`check-standards.sh` are all green. Nothing is "fixed after merge".
> Detail: [14](14-GIT-CI.md) §4.

**[GEN-24] MUST: The standard wins for new code; working code is not rewritten to match.**
When existing code conflicts with the standard, write the new code correctly, leave the old
code alone, and tell the user about the conflict.
> **Why:** A migration PR that touches 300 files "for consistency" ships no user value and
> hides real changes. Old code moves to the standard when it is touched for a real reason.
