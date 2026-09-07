# 02 — Technology and Versions

> This table is the single source for what is allowed in `package.json`, the Dockerfile and
> compose. **Pinned** means: the version line the standard was verified against, in
> production, on 2026-09-07. **Latest** is what npm reported on the same day, listed so
> the upgrade gap is visible. A newer major is not adopted because it exists; it is adopted
> when the ADR's "what would change this decision" condition is checked and the whole repo
> moves together ([GEN-02]).

---

## 1. Runtime and toolchain

| Component | Pinned line | Latest (2026-09-07) | Notes |
|---|---|---|---|
| Node.js | **24.x** (LTS) | 24.20 | `engines.node >= 24` in `package.json`. Build image `node:24-alpine` |
| npm | bundled with Node 24 | | Lockfile committed, `npm ci` everywhere ([VER-04]). See [ADR-0018](adr/0018-package-manager.md) |
| TypeScript | **6.0.x** | 7.0.2 | 7.x is the native (Go) compiler line; adopt only after `tsc -b` parity is verified on the repo. [ADR-0003](adr/0003-language.md) |
| Vite | **8.x** | 8.2 | Rolldown-based. `build.rollupOptions.output.advancedChunks` is the chunking API |
| @vitejs/plugin-react | 6.x | 6.1 | With `babel-plugin-react-compiler` 1.x enabled |
| nginx (runtime image) | **1.30-alpine** (stable line) | 1.31 mainline | Use `nginxinc/nginx-unprivileged:1.30-alpine` for non-root ([OPS-03]) |

**[VER-01] MUST:** `package.json` declares `"engines": { "node": ">=24.0.0" }` and the
Dockerfile uses the matching `node:24-alpine` tag. A `.nvmrc` with `24` sits at the repo root.

**[VER-02] MUST:** Base images are pinned to a minor line (`node:24-alpine`,
`nginxinc/nginx-unprivileged:1.30-alpine`). `latest` is forbidden everywhere (Dockerfile,
compose, CI).

**[VER-03] MUST:** The TypeScript major is upgraded only after `tsc -b` on the whole repo
passes with zero new errors on a branch, and `vite build` output is byte-compared for
unexpected diffs. TS 7 changes the compiler implementation, not just the language.

**[VER-04] MUST:** Installs use `npm ci`, never `npm install`, in CI and Docker. The lockfile
is committed. `--legacy-peer-deps` is allowed only with a comment naming the package that
needs it and an issue link; it is removed when that package updates.

---

## 2. Application dependencies

### Core

| Package | Pinned | Latest | Role |
|---|---|---|---|
| react, react-dom | **19.2.x** | 19.2.8 | [ADR-0002](adr/0002-ui-framework.md) |
| react-router-dom | **7.x** | 7.18 | Data router (`createBrowserRouter`), lazy routes. [ADR-0006](adr/0006-routing.md) |
| @tanstack/react-query | **5.x** | 5.102 | All server state. [ADR-0004](adr/0004-server-state.md) |
| @reduxjs/toolkit, react-redux | **2.x / 9.x** | 2.12 / 9.2 | Cross-feature client state only. [ADR-0005](adr/0005-client-state.md) |
| zod | **4.x** | 4.5 | Schemas at API boundary and forms |
| react-hook-form | **7.x** | 7.87 | With `@hookform/resolvers` for zod. [ADR-0015](adr/0015-forms.md) |
| i18next, react-i18next | **26.x / 17.x** | 26.4 / 17.0 | [ADR-0011](adr/0011-i18n.md) |
| i18next-browser-languagedetector | 8.x | 8.2 | Only for non-SEO apps; SEO apps use URL locale ([SEO-08]) |
| tailwindcss, @tailwindcss/vite | **4.x** | 4.3 | Utility-first styling. [ADR-0007](adr/0007-styling.md) |
| clsx | 2.x | | Conditional class names. `tailwind-merge` allowed when composing variants |
| lucide-react | 1.x | 1.42 | Icon set. Tree-shaken named imports only |
| react-hot-toast | 2.x | 2.6 | Toasts. One `<Toaster>` at app root |
| @tanstack/react-virtual | 3.x | 3.14 | Lists/tables above 200 rows ([PERF-12]) |
| dompurify | 3.x | 3.4 | The only permitted path to `dangerouslySetInnerHTML` ([SEC-01]) |
| web-vitals | 6.x | 6.2 | LCP/INP/CLS reporting ([OBS-14]) |
| @sentry/react | 10.x | 10.73 | Error tracking. Any Sentry-protocol-compatible backend (GlitchTip, self-hosted Sentry). [ADR-0020](adr/0020-error-tracking.md) |

### Map

| Package | Pinned | Latest | Role |
|---|---|---|---|
| maplibre-gl | **5.x** | 6.7 | [ADR-0008](adr/0008-map-library.md). 6.x is a major with style-spec and API changes; adopt as a repo-wide upgrade after the map checklist in `08` §10 passes |
| @mapbox/mapbox-gl-draw | 1.5.x | | Drawing/editing geometries. Compatible with MapLibre 5 with the `maplibre` style adapter in `08` §8 |
| supercluster | 8.x | | Only when MapLibre's built-in `cluster: true` is insufficient (custom cluster properties) |
| @turf/* (individual packages) | 7.x | | `@turf/turf` (the meta package) is forbidden; import `@turf/area`, `@turf/bbox`, etc. individually ([PERF-06]) |
| pmtiles | 4.x | | Static tile archives served from object storage without a tile server ([MAP-27]) |

### Realtime and media

| Package | Pinned | Latest | Role |
|---|---|---|---|
| mqtt | 5.x | 5.15 | MQTT over WebSocket, browser build. Lazy-loaded ([RT-01]) |
| hls.js | 1.6.x | | HLS playback where the browser lacks native support. Lazy-loaded |

### Data export and editors (lazy-loaded, never in the main chunk)

| Package | Pinned | Role |
|---|---|---|
| xlsx-js-style | 1.2.x | Excel export with styles. Replaces `xlsx` (do not ship both) |
| jspdf, jspdf-autotable | 4.x / 5.x | PDF export. Fonts self-hosted (`/fonts/*.ttf`) |
| @uiw/react-codemirror + @codemirror/* | 4.x / 6.x | JSON/code editing screens |
| recharts | 3.x | Charts. Lazy per page |

---

## 3. Development dependencies

| Package | Pinned | Latest | Role |
|---|---|---|---|
| eslint | **10.x** | 10.10 | Flat config only. [ADR-0019](adr/0019-linting.md) |
| typescript-eslint | 8.x | 8.69 | `strictTypeChecked` config |
| eslint-plugin-react-hooks | 7.x | 7.1 | `recommended` flat config (includes React Compiler rules) |
| eslint-plugin-react-refresh | 0.5.x | | Vite HMR safety |
| eslint-plugin-jsx-a11y | 6.x | 6.10 | [A11Y-01] |
| eslint-plugin-i18next | 6.x | 6.1 | `no-literal-string` in JSX ([I18N-03]) |
| eslint-plugin-import-x | 4.x | | Import direction enforcement ([STR-12]) and ordering |
| prettier | 3.x | 3.9 | Formatting. No style rules in ESLint that Prettier owns |
| vitest | **5.x** | 5.0 | Unit and component tests. [ADR-0016](adr/0016-testing.md) |
| @testing-library/react, @testing-library/user-event, @testing-library/jest-dom | 16.x / 14.x / 6.x | | Component tests |
| msw | 2.x | 2.15 | Network mocking in tests and offline dev ([TEST-09]) |
| @playwright/test | 1.6x | 1.63 | End-to-end smoke tests |
| jsdom | 26.x | | Vitest DOM environment |
| vite-plugin-compression2 | 2.x | 2.5 | Emits `.br` and `.gz` next to assets for `brotli_static`/`gzip_static` ([NGX-07]) |
| rollup-plugin-visualizer | 6.x | | Bundle analysis (`npm run analyze`), not in CI |
| @types/node, @types/react, @types/react-dom | matching majors | | |

---

## 4. Forbidden packages

**[VER-05] MUST NOT:** The following are not installed, regardless of the reason given.
The check script fails the build if they appear in `package.json`.

| Package | Why not | Use instead |
|---|---|---|
| `axios`, `ky`, `superagent` | Second HTTP client; breaks [GEN-06] | `src/shared/api/client.ts` over `fetch` |
| `moment`, `dayjs`, `luxon` | Bundle weight, or another API for what `Intl` does | `Intl.DateTimeFormat`, `Temporal` polyfill only if approved |
| `lodash` (full), `underscore` | 70 KB for `debounce` | Native array methods; `lodash-es/debounce` single import if approved |
| `styled-components`, `@emotion/*`, `stitches` | Runtime CSS-in-JS; conflicts with Tailwind, hurts INP | Tailwind + scoped CSS files ([ADR-0007](adr/0007-styling.md)) |
| `mapbox-gl` | Licence (proprietary since v2), token requirement | `maplibre-gl` |
| `react-map-gl`, `react-maplibre-gl` | Wrapper hides the imperative API the standard relies on; lifecycle bugs | Direct `maplibre-gl` via `MapContext` ([MAP-01]) |
| `leaflet`, `react-leaflet` | DOM/SVG rendering; fails [GEN-18] above a few hundred features | `maplibre-gl` |
| `@turf/turf` (meta) | Pulls all 100+ modules into the bundle | Individual `@turf/<fn>` packages |
| `xlsx` alongside `xlsx-js-style` | Two copies of SheetJS | `xlsx-js-style` only |
| `uuid` | Native `crypto.randomUUID()` exists | `crypto.randomUUID()` |
| `redux-thunk`, `redux-saga`, `redux-observable` | RTK includes thunk; async flows belong to TanStack Query | TanStack Query mutations |
| `react-helmet` (unmaintained) | Not React 19 compatible | React 19 native `<title>`/`<meta>` hoisting ([SEO-04]) |
| `create-react-app`, `react-scripts` | Dead toolchain | Vite |
| `next`, `remix`, `@remix-run/*` | Different stack ([GEN-01]) | SEO needs are solved in `10` without changing stack |
| Any package loaded from a CDN `<script>` | No integrity, no offline, CSP hole | npm + bundle ([SEC-14]) |

---

## 5. Dependency policy

**[VER-06] MUST:** A new dependency is proposed in the PR description with: what it replaces
(the code you would otherwise write), gzipped size from `bundlephobia`, weekly downloads,
last publish date, licence, and whether it is ESM. Packages with no publish in 18 months or
fewer than 10k weekly downloads need a written justification.

**[VER-07] MUST:** `npm audit --audit-level=high` runs in CI ([CI-08]). A high/critical
advisory without a fix blocks the merge unless an override with an expiry date is committed.

**[VER-08] MUST:** Dependencies are updated on a schedule (monthly) in a dedicated PR,
minors together, majors one at a time with the relevant ADR checked.

**[VER-09] MUST NOT:** Postinstall scripts from dependencies run in CI without review.
`.npmrc` contains `ignore-scripts=true` for CI installs; packages that genuinely need a
build step (none in the current table) are allow-listed explicitly.

**[VER-10] MUST:** Import only what you use. Named imports from ESM packages; no
`import * as` from a large library; no deep imports into `dist/` paths that are not public API.

**[VER-11] SHOULD:** Prefer the platform over a package: `fetch`, `AbortController`,
`Intl`, `URL`/`URLSearchParams`, `structuredClone`, `crypto.randomUUID`, CSS container
queries, `<dialog>`. A package is justified when the platform API is missing, not when it is
verbose.

---

## 6. Browser support

**[VER-12] MUST:** Target is the last 2 versions of Chrome, Edge, Firefox and Safari, plus
Safari iOS last 2. `build.target` in Vite is `'baseline-widely-available'` (Vite 8
default). No polyfills for Internet Explorer or pre-2023 browsers. WebGL 2 is required for
map pages; the map feature shows a capability message otherwise ([MAP-40]).

---

## Open questions

- **TypeScript 7 adoption date.** Blocked on `tsc -b` parity on the reference repo. Revisit
  when 7.1 ships or when Vite's `tsc` integration documents 7.x support.
- **MapLibre 6.** Blocked on the map checklist (`08` §10) passing on the reference repo,
  in particular terrain, `feature-state` on clustered sources and draw-plugin compatibility.
