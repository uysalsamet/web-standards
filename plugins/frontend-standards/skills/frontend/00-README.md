# Frontend Engineering Standard — Index

> **What this set is for:** the binding line every frontend in the organisation follows,
> whether it is a public municipal portal with SEO, an internal GIS dashboard with a
> 100,000-feature map, or a five-page admin tool. One stack, one layout, one way to call
> an API, one way to handle errors, one way to ship. Whoever writes it, human or AI.
>
> **Scope:** React 19 + Vite + TypeScript single-page applications, built into a static
> bundle, served by nginx from a Docker image, sitting behind a reverse proxy that also
> fronts the backend (see the companion backend standard). Map-heavy applications use
> MapLibre GL. Server-side rendering is covered only as far as SEO requires it (file 10).
>
> **Out of scope:** React Native, Electron, Next.js/Remix full-stack apps, design systems
> as a product, and backend concerns (owned by the backend standard).
>
> **Last verified:** 2026-09-07. The version table in `02` was checked on this date.

---

## Files

| # | File | When to read |
|---|---|---|
| 🚀 | [START.md](START.md) | **First task in a repo.** Wiring the standard: agent files, tools, CI hooks, opening prompt |
| 📁 | [templates/](templates/) | Copyable artefacts: Dockerfile, compose, nginx templates, runtime config, agent instruction files |
| 🔧 | [tools/](tools/README.md) | `check-standards.sh`, `check-i18n.mjs`, `check-bundle-size.mjs`, `nginx-smoke.sh`, `check-refs.mjs`. The machine-checkable ~6 % |
| 🗺 | [RULE-MAP.md](RULE-MAP.md) | Signal → rule table. Task → reading list. Known gaps |
| 01 | [01-GOLDEN-RULES.md](01-GOLDEN-RULES.md) | **Always.** Non-negotiable items |
| 02 | [02-TECH-VERSIONS.md](02-TECH-VERSIONS.md) | Starting a project, adding a dependency, writing `package.json` / Dockerfile |
| 03 | [03-PROJECT-STRUCTURE.md](03-PROJECT-STRUCTURE.md) | Creating the skeleton, adding a feature, deciding where a file goes |
| 04 | [04-API-CLIENT.md](04-API-CLIENT.md) | Talking to the backend: client, DTOs, error body, pagination, timeouts |
| 05 | [05-STATE-AND-DATA.md](05-STATE-AND-DATA.md) | Server state (TanStack Query), client state (RTK), URL state, caching, invalidation |
| 06 | [06-SECURITY.md](06-SECURITY.md) | XSS, CSP, token handling, uploads, iframes, third-party code, supply chain |
| 07 | [07-PERFORMANCE.md](07-PERFORMANCE.md) | Bundle budgets, code splitting, rendering cost, images/fonts, Web Vitals, React Compiler |
| 08 | [08-MAP-MAPLIBRE.md](08-MAP-MAPLIBRE.md) | **Map core:** instance ownership, layers vs DOM markers, events, popups, lifecycle and cleanup |
| 08b | [08b-MAP-DATA.md](08b-MAP-DATA.md) | Map data: GeoJSON limits, vector tiles, terrain and raster, live datasets, map performance |
| 08c | [08c-MAP-TOOLING.md](08c-MAP-TOOLING.md) | Map drawing and editing, testing map code |
| 09 | [09-I18N.md](09-I18N.md) | Locale files with identical keys, typed keys, no literal strings, Intl formatting, Turkish casing |
| 10 | [10-SEO-RENDERING.md](10-SEO-RENDERING.md) | SEO tiers, prerender vs SSR vs request-time meta injection, the stale-build problem, sitemap, 404 |
| 11 | [11-DOCKER-COMPOSE.md](11-DOCKER-COMPOSE.md) | Multi-stage image, runtime config, env layering, dev vs prod compose, health, logging |
| 12 | [12-NGINX.md](12-NGINX.md) | Static serving, cache headers, compression, security headers, proxy blocks, templates, tile cache |
| 13 | [13-TESTING.md](13-TESTING.md) | Unit, component, network mocking, e2e, map testing, coverage targets |
| 14 | [14-GIT-CI.md](14-GIT-CI.md) | Branches, commits, PR gates, the pipeline, bundle-size and i18n gates |
| 15 | [15-NEW-FEATURE-CHECKLIST.md](15-NEW-FEATURE-CHECKLIST.md) | Before "done". Copy and tick |
| 16 | [16-ACCESSIBILITY-UX.md](16-ACCESSIBILITY-UX.md) | Semantics, keyboard, focus, contrast, motion, states (loading/empty/error), responsive |
| 17 | [17-ERRORS-OBSERVABILITY.md](17-ERRORS-OBSERVABILITY.md) | Error boundaries, chunk-load recovery, global handlers, tracking, Web Vitals reporting, logging policy |
| 18 | [18-FORMS-VALIDATION.md](18-FORMS-VALIDATION.md) | react-hook-form + zod, Turkish identifiers, number/date inputs, file inputs, submit UX |
| 19 | [19-AUTH-SESSION.md](19-AUTH-SESSION.md) | Cookie sessions, refresh, guards, permission-driven UI, logout, multi-tab |
| 20 | [20-REALTIME-MEDIA.md](20-REALTIME-MEDIA.md) | MQTT/WebSocket lifecycle, backpressure, video (HLS/WHEP), web workers |
| 21 | [21-TYPESCRIPT-REACT-STYLE.md](21-TYPESCRIPT-REACT-STYLE.md) | Strictness, types at boundaries, naming, hooks discipline, React 19 idioms, comments |
| 22 | [22-ROUTING.md](22-ROUTING.md) | Route tree, lazy pages, loaders vs queries, guards, URL as state, 404/redirects |
| GIS | [APPENDIX-GIS-DATA.md](APPENDIX-GIS-DATA.md) | GeoJSON hygiene, coordinate order/precision, projections, when data becomes tiles |
| 📜 | [adr/](adr/README.md) | Decision records: why this stack. Read before proposing an alternative |

---

## Rule ID prefixes

| Prefix | File | Prefix | File |
|---|---|---|---|
| GEN | 01 | I18N | 09 |
| VER | 02 | SEO | 10 |
| STR | 03 | OPS | 11 |
| API | 04 | NGX | 12 |
| STA | 05 | TEST | 13 |
| SEC | 06 | CI | 14 |
| PERF | 07 | A11Y | 16 |
| MAP | 08 | OBS | 17 |
| FORM | 18 | AUTH | 19 |
| RT | 20 | TS | 21 |
| RTE | 22 | GIS | Appendix |
| TOOL | tools/ | | |

Severity words: **MUST** (binding), **MUST NOT** (forbidden), **SHOULD** (default; deviating
requires a written reason in the PR).

---

## How the set is meant to be used

1. Wire it into the repo once (`START.md`): copy `templates/agents/` to the repo root,
   add `tools/` to CI.
2. Every task starts with `01` and a signal scan of `RULE-MAP.md` §1.
3. Read only the files the task needs. Reading all 25 files for a button change wastes
   context and blurs judgement.
4. Finish with the tools (exit 0) and the checklist (`15`). Skipped items are said out loud.

## Relationship to the backend standard

The backend standard (companion plugin) owns the API contract: error body shape, pagination
meta, permission key format `<module>.<action>`, header names. `04-API-CLIENT.md` and
`19-AUTH-SESSION.md` in this set **consume** that contract and do not redefine it. If the two
disagree, the backend standard wins for wire format and this standard wins for what the
browser does with it.
