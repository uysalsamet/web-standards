# 07 — Performance

> Governs what the browser downloads, when it downloads it, and how much main-thread work
> a user interaction costs. The core principle: **every performance decision is a number**.
> A budget in CI, a Web Vital at p75, a before/after measurement in the PR. Read this file
> when touching `vite.config.ts`, adding a dependency, rendering a list, a chart, an image
> or a font, or when anything "feels slow". Map rendering cost (layers, tiles, markers,
> `feature-state`) is owned by [08](08-MAP-MAPLIBRE.md) and only cross-referenced here.

---

## 1. Measurement discipline

Performance work without a measurement is a guess, and guesses in this area are wrong
roughly half the time (the React Compiler makes `useMemo` slower in some cases; a "lazy"
chunk can add a waterfall that makes the page slower). The rule is simple and absolute.

**[PERF-01] MUST:** A PR that claims a performance effect (adds `useMemo`, splits a chunk,
changes a Vite option, virtualises a list, moves work to a worker) contains a before/after
number in its description: the metric, the tool, the device or CI runner, and both values.
> **Why:** Without a number the reviewer cannot tell an improvement from a regression, and
> the next engineer cannot tell whether the complexity is still earning its keep. Acceptable
> numbers: gzipped chunk size from `npm run analyze`, an INP or LCP value from the
> Performance panel, a `PerformanceObserver` long-task count, a Vitest benchmark. "It feels
> faster" is rejected. Detail: §9 for the tools, [14](14-GIT-CI.md) §3 for the PR template.

**[PERF-02] MUST:** The following gzipped size budgets apply to `dist/` and are enforced
in CI. They are ceilings, not targets.

| Chunk | Budget (gzip) | Notes |
|---|---|---|
| App shell: entry + `react-vendor` + shared code loaded on first paint | **250 KB** | Excludes `maplibre-gl`. Includes router, query, redux, i18n runtime, the first locale |
| `maplibre` chunk | **250 KB** | `maplibre-gl` 5.x alone is about 230 KB gz. Nothing else goes in this chunk |
| Any single route chunk | **150 KB** | A route above this lazy-loads its heavy parts (§2) |
| Total of all JS in `dist/assets` | **1.5 MB** | The sum of everything a user could ever download |
| Any single CSS file | **60 KB** | Tailwind 4 output for the reference app is 38 KB gz |

> **Why:** On the reference municipal deployment the p75 device is a mid-range Android on
> 4G; 250 KB gz of app shell is roughly 1.2 s of download plus 0.8 s of parse and execute
> there, which is what leaves room for LCP ≤ 2.5 s (§6). The map chunk is separated because
> it is the largest single dependency and is only needed on map routes. Detail: [ADR-0001](adr/0001-build-tool.md).

**[PERF-03] MUST:** CI runs `tools/check-bundle-size.mjs` after `vite build`. It reads
`dist/`, gzips every emitted asset, classifies each one as an entry asset (referenced from
`index.html`) or a route chunk, compares it against `budget.json` at the repo root, and
fails the job when any budget is exceeded. Raising a budget is a reviewed change to that
file with a reason in the PR. Cross-ref: [CI-06], [TOOL-01].

```bash
npm run build
node frontend-standards/tools/check-bundle-size.mjs dist budget.json
```

```jsonc
// budget.json at the repo root. Bytes, not kilobytes, so there is no rounding argument.
{
  "initial": 262144,        // sum of entry assets, 256 KB gz
  "chunk": 153600,          // any single route chunk, 150 KB gz
  "total": 1572864,         // every emitted asset, 1.5 MB gz
  "entries": {              // per-chunk overrides, matched by longest name prefix
    "react-vendor": 61440,  // 60 KB gz
    "maplibre": 262144      // 256 KB gz, the exception the table above allows
  }
}
```

`tools/budget.example.json` is the starting point; copy it and adjust to your app. The
script prints an aligned table of every asset with its gzipped size and its budget, and on
failure names each breach with the amount it went over. See
[tools/README.md](tools/README.md).

The script gzips because nginx serves the precompressed `.gz`/`.br` files ([PERF-10]) and
users pay for the compressed bytes. Brotli is 10 to 15 % smaller still; gzip is the budget
unit because it is deterministic and fast in CI.

---

## 2. Code splitting and chunking

**[PERF-04] MUST:** Every route component is loaded lazily through the router's `lazy`
property (React Router 7 data router). No page component is imported statically from
`router.tsx`. Cross-ref: [RTE-03].
> **Why:** A static import of one page pulls that page's feature, its charts and its
> exporters into the app shell. On the reference app one non-lazy admin page added 210 KB
> gz to first paint for every user, including the 95 % who never opened it.

**[PERF-05] MUST:** Heavy libraries (`xlsx-js-style`, `jspdf`, `jspdf-autotable`,
`@uiw/react-codemirror` and `@codemirror/*`, `recharts`, `mqtt`, `hls.js`,
`@mapbox/mapbox-gl-draw`) are never imported at module top level in application code.
They are loaded with a dynamic `import()` inside the event handler or effect that needs
them, through a memoising loader in `src/shared/lib/lazy/`.
> **Why:** A top-level import runs at chunk evaluation. Lazy routes do not help if the
> route's chunk itself carries 400 KB of SheetJS that only the "Export" button uses.
> Loading inside the handler means the user who never exports never downloads it.

```ts
// src/shared/lib/lazy/loadXlsx.ts
type XlsxModule = typeof import('xlsx-js-style')

let pending: Promise<XlsxModule> | undefined

// Memoised so ten clicks start one download. Reset on failure so a network blip
// does not poison every later attempt (the chunk-load recovery in 17 does not
// cover handler-time imports; this retry path does).
export function loadXlsx(): Promise<XlsxModule> {
  pending ??= import('xlsx-js-style').catch((error: unknown) => {
    pending = undefined
    throw error
  })
  return pending
}
```

```tsx
// src/features/Parking/components/ExportButton.tsx
import { useState } from 'react'
import { useTranslation } from 'react-i18next'

import { Button } from '@/shared/components'
import { loadXlsx } from '@/shared/lib/lazy/loadXlsx'

import type { ParkingRow } from '../types'

export function ExportButton({ rows }: { rows: readonly ParkingRow[] }) {
  const { t } = useTranslation('parking')
  const [busy, setBusy] = useState(false)

  async function handleExport() {
    setBusy(true)
    try {
      const xlsx = await loadXlsx()               // downloaded here, not at page load
      const sheet = xlsx.utils.json_to_sheet(rows as ParkingRow[])
      const book = xlsx.utils.book_new()
      xlsx.utils.book_append_sheet(book, sheet, 'Parking')
      xlsx.writeFile(book, `parking-${new Date().toISOString().slice(0, 10)}.xlsx`)
    } finally {
      setBusy(false)
    }
  }

  return <Button onClick={handleExport} loading={busy}>{t('export.excel')}</Button>
}
```

Same pattern for the others: `loadJspdf()`, `loadRecharts()` (wrapped in a `lazy()`
component boundary with a chart skeleton, since charts render rather than run),
`loadMqtt()` ([RT-01]), `loadHls()`, `loadDraw()` ([MAP-33]). Error handling for a failed
import is the caller's job: the export button shows the i18n error and stays clickable.

**[PERF-06] MUST:** Import individual `@turf/<fn>` packages (`@turf/area`, `@turf/bbox`,
`@turf/boolean-point-in-polygon`); `@turf/turf` is forbidden. The same rule generalises:
no meta-packages that re-export a library family, named ESM imports only, no
`import * as` from a package larger than 10 KB gz, and every new import of a package over
20 KB gz is verified in the bundle analyzer (§9) before the PR is opened.
> **Why:** `@turf/turf` 7.x is roughly 600 KB minified; tree-shaking recovers some of it
> but Rolldown cannot drop modules whose evaluation has side effects, and Turf's meta
> package has several. Measured on the reference app: switching three call sites from
> `@turf/turf` to `@turf/area` + `@turf/bbox` + `@turf/centroid` removed 180 KB gz from
> the map route chunk. `lodash` has the same shape ([VER-05]).

```ts
// WRONG
import * as turf from '@turf/turf'
const a = turf.area(polygon)

// RIGHT
import area from '@turf/area'
import bbox from '@turf/bbox'
const a = area(polygon)
const [minX, minY, maxX, maxY] = bbox(polygon)
```

(`@turf/*` packages ship a default export; this is the one place [STR-15]'s named-export
rule yields to the library's public API.)

**[PERF-07] MUST:** The React family (`react`, `react-dom`, `react-is`, `scheduler`,
`use-sync-external-store`) is forced into exactly one chunk named `react-vendor` via
`build.rollupOptions.output.advancedChunks.groups`, and `resolve.dedupe` lists `react` and
`react-dom`. Both settings are present in every `vite.config.ts`; neither is removed
"because the build works without it".
> **Why:** Vite 8's Rolldown-based splitting decides chunks by import graph, not by
> package. On the reference app it placed `react/jsx-runtime` and part of React's shared
> internals in one chunk and `react-dom`'s copy in another. Two copies of the internals
> means two dispatchers: the production build threw `Invalid hook call` and
> `Cannot read properties of null (reading 'useState')` on routes that dev mode never
> reproduced, because dev serves unbundled modules. Verified by grepping `dist/` for
> `__CLIENT_INTERNALS` and finding it in two files. `dedupe` fixes "two versions",
> `advancedChunks` fixes "one version copied into N chunks"; you need both.

**[PERF-08] MUST:** `optimizeDeps.include` lists every dependency that is loaded lazily
(§2) plus the React family, so the dev server pre-bundles them at startup instead of
discovering them on first navigation.
> **Why:** When Vite discovers a new dependency at runtime it re-optimises and forces a
> full reload over HMR. If HMR is disabled, or the reload is missed, the page keeps the old
> pre-bundled `react-dom` and the new `react`, and `useState` throws with a null
> dispatcher. The reference app hit this on the first visit to any charts page after
> `npm run dev`. Pre-including the lazy deps removes the runtime re-optimisation entirely.
> The cost is 2 to 4 s of extra cold start, once per lockfile change.

**[PERF-09] MUST:** `vite.config.ts` sets the build options below. Deviations are
commented with the reason and the measurement.

```ts
// vite.config.ts (build-relevant excerpt; proxy and plugins omitted)
import { fileURLToPath, URL } from 'node:url'

import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'
import { compression } from 'vite-plugin-compression2'

const REACT_FAMILY = /node_modules[\\/](react|react-dom|react-is|scheduler|use-sync-external-store)[\\/]/
const MAPLIBRE = /node_modules[\\/](maplibre-gl|@mapbox[\\/]mapbox-gl-draw|pmtiles|supercluster)[\\/]/

export default defineConfig({
  plugins: [
    // React Compiler is on for the whole app ([TS-12]); manual memoisation is the exception.
    react({ babel: { plugins: [['babel-plugin-react-compiler', {}]] } }),
    tailwindcss(),
    // Emits .br and .gz next to each asset so nginx serves them with *_static ([NGX-07]).
    compression({ algorithms: ['brotliCompress', 'gzip'], threshold: 1024, deleteOriginalAssets: false }),
  ],
  resolve: {
    alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
    dedupe: ['react', 'react-dom'],                       // [PERF-07], second shield
  },
  optimizeDeps: {
    include: [                                            // [PERF-08]
      'react', 'react-dom', 'react-dom/client', 'react/jsx-runtime', 'react/jsx-dev-runtime',
      'react-is', 'react-router-dom', 'react-i18next', 'i18next', 'lucide-react', 'react-hot-toast',
      'recharts', '@uiw/react-codemirror', '@tanstack/react-virtual', 'mqtt', 'hls.js',
      'xlsx-js-style', 'jspdf', 'jspdf-autotable', 'maplibre-gl', '@mapbox/mapbox-gl-draw',
    ],
  },
  define: {
    // Git sha of the build; read by errorTracking and chunk recovery ([OBS-05]).
    __APP_RELEASE__: JSON.stringify(process.env.GIT_SHA ?? 'dev'),
  },
  build: {
    target: 'baseline-widely-available',                  // [VER-12]; no legacy transforms
    sourcemap: 'hidden',                                  // uploaded to the tracker, never served ([OBS-15], [SEC-12])
    cssCodeSplit: true,                                   // route CSS ships with the route chunk
    assetsInlineLimit: 4096,                              // [PERF-18]: nothing above 4 KB becomes base64
    modulePreload: { polyfill: false },                   // every target browser supports <link rel=modulepreload>
    chunkSizeWarningLimit: 600,                           // warn in kB (minified); the real gate is [PERF-03]
    rollupOptions: {
      output: {
        advancedChunks: {
          groups: [
            { name: 'react-vendor', test: REACT_FAMILY, priority: 20 },   // [PERF-07]
            { name: 'maplibre', test: MAPLIBRE, priority: 10 },           // [PERF-02] row 2
          ],
        },
      },
    },
  },
})
```

`modulePreload.polyfill: false` relies on `<link rel="modulepreload">` support, which is in
every browser of the [VER-12] matrix; if the matrix is widened to older Safari the polyfill
goes back on. `chunkSizeWarningLimit` is a console warning for the developer; it does not
replace the CI gate.

**[PERF-10] MUST:** Every emitted JS, CSS, JSON, SVG and font asset above 1 KB has a
`.br` and a `.gz` sibling in `dist/`, produced by `vite-plugin-compression2` at build time,
and nginx serves them via `brotli_static on` / `gzip_static on` ([NGX-07]).
> **Why:** Compressing at request time costs nginx CPU per request and prevents
> `immutable` caching from being fully effective under load. Build-time Brotli at quality
> 11 is 15 to 20 % smaller than runtime gzip level 6 and costs nothing at serve time.
> Verify: `ls dist/assets | grep -c '\.br$'` equals the number of assets above the
> threshold, and `curl -H 'Accept-Encoding: br' -I /assets/index-*.js` returns
> `content-encoding: br`.

---

## 3. Rendering cost

The React Compiler (`babel-plugin-react-compiler`, enabled in [PERF-09]) memoises
components, hooks and JSX automatically when the code follows the Rules of React. The
consequence for this standard: **manual memoisation is a smell, not a default.**

**[PERF-11] MUST NOT:** `useMemo`, `useCallback` or `memo()` are added without an
adjacent comment that names the measurement (what was measured, before and after values)
and why the compiler could not do it (for example, the value flows into a non-compiled
library that compares by identity). Cross-ref: [TS-13].
> **Why:** With the compiler on, a hand-written `useMemo` is redundant in the common case
> and harmful in two: it hides a Rules-of-React violation that made the compiler skip the
> component (the `eslint-plugin-react-hooks` 7 rules flag these; fix the cause), and it
> adds dependency arrays that go stale on the next edit. The reference app carried 340
> `useCallback`s from the pre-compiler era; removing them changed no measured metric.

```tsx
// WRONG: the compiler already memoises this; the array is one more thing to keep correct
const sorted = useMemo(() => [...rows].sort(byName), [rows])

// RIGHT: plain code; the compiler caches `sorted` while `rows` is referentially stable
const sorted = [...rows].sort(byName)

// ALLOWED: identity matters to a library the compiler does not compile.
// Measured 2026-08-14: recharts re-laid-out 14 ms per parent render without this (React Profiler).
const chartData = useMemo(() => rows.map(toPoint), [rows])
```

**[PERF-12] MUST:** Any list, table or tree that can render more than 200 rows is
virtualised with `@tanstack/react-virtual` (`useVirtualizer`), with a fixed or measured row
height and an `overscan` of 5 to 10. Pagination from the API ([API-09]) does not exempt a
component that can show more than 200 rows on one screen.
> **Why:** 200 rows of a 6-column table is roughly 1,400 DOM nodes; at 2,000 rows a filter
> keystroke costs 120 to 250 ms of layout on a mid-range device, which fails the INP target
> (§6) on every keystroke. Virtualised, the same table renders about 30 rows regardless of
> data size. 200 is the point where the reference app's measured INP crossed 200 ms.

```tsx
// src/features/Parking/components/ParkingTable.tsx (virtualisation core; columns omitted)
import { useVirtualizer } from '@tanstack/react-virtual'
import { useRef } from 'react'

import type { ParkingRow } from '../types'

const ROW_HEIGHT_PX = 40
const OVERSCAN = 8

export function ParkingTable({ rows }: { rows: readonly ParkingRow[] }) {
  const scrollRef = useRef<HTMLDivElement>(null)
  const virtualizer = useVirtualizer({
    count: rows.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => ROW_HEIGHT_PX,
    overscan: OVERSCAN,
  })

  return (
    <div ref={scrollRef} className="h-full overflow-auto" role="grid" aria-rowcount={rows.length}>
      <div style={{ height: virtualizer.getTotalSize(), position: 'relative' }}>
        {virtualizer.getVirtualItems().map((item) => {
          const row = rows[item.index]!
          return (
            <div
              key={row.id}
              role="row"
              aria-rowindex={item.index + 1}
              className="absolute inset-x-0 flex items-center border-b"
              style={{ height: item.size, transform: `translateY(${item.start}px)` }}
            >
              {row.name}
            </div>
          )
        })}
      </div>
    </div>
  )
}
```

**[PERF-13] MUST NOT:** The render body of a component performs I/O, parses JSON, reads
`localStorage`, constructs a `Date` from `Date.now()`, or iterates over more than 1,000
items to derive a value from data that came from TanStack Query. Derived server data is
computed in the query's `select` option ([STA-06]); parsing is done once in the API layer
([API-05]) or in a worker (§7).
> **Why:** Render runs on every state change of the component and its parents, and the
> compiler can only cache work whose inputs it can see. `select` runs once per fetched
> result and is structurally shared; a 20,000-feature `.filter().map()` in render runs on
> every hover.

**[PERF-14] MUST:** Values passed to components the compiler does not cover (class
components, third-party `memo` components, imperative library options such as a MapLibre
`LayerSpecification` or a recharts `data` array) have stable identity: module-level
constants for static values, state or `select`-derived values for dynamic ones. Inline
object and array literals are not passed as such props.
> **Why:** The compiler memoises JSX inside compiled functions, but a fresh `{}` handed to
> a non-compiled `memo` child defeats that child's own bail-out, and a fresh layer spec
> handed to `map.addLayer` in an effect re-adds the layer on every render ([MAP-05]).

```tsx
// WRONG: new object every render; the map effect depends on it and re-runs
<ParkingLayer paint={{ 'circle-color': '#1d4ed8', 'circle-radius': 6 }} />

// RIGHT: hoisted; identity is stable for the life of the module
const PARKING_PAINT: CirclePaint = { 'circle-color': '#1d4ed8', 'circle-radius': 6 }
<ParkingLayer paint={PARKING_PAINT} />
```

**[PERF-15] MUST:** State updates that trigger a large re-render but are not the direct
visual response to the user's input (applying a filter to a table, toggling a set of map
layers, switching a dashboard tab, changing the locale) are wrapped in `startTransition`
or driven by `useTransition`, and the immediate input (the text field, the checkbox) is
updated outside the transition.
> **Why:** Without a transition the keystroke and the 2,000-row re-render are one task;
> the input feels frozen and INP records the whole thing. With a transition React commits
> the input first and renders the table interruptibly. Map layer toggles: the checkbox
> state updates synchronously, the `setLayoutProperty` calls happen in an effect that
> reads the transitioned state ([MAP-14]).

```tsx
import { startTransition, useState } from 'react'

export function useLayerToggles(initial: ReadonlySet<string>) {
  const [visible, setVisible] = useState(initial)          // consumed by the map effect
  function toggle(layerId: string) {
    startTransition(() => {
      setVisible((prev) => {
        const next = new Set(prev)
        next.has(layerId) ? next.delete(layerId) : next.add(layerId)
        return next
      })
    })
  }
  return { visible, toggle }
}
```

**[PERF-16] MUST:** Code that reads layout (`getBoundingClientRect`, `offsetWidth`,
`scrollTop`, `getComputedStyle`) and writes it in the same frame batches all reads before
all writes; element size changes are observed with `ResizeObserver`, never with a `resize`
listener plus a measurement. Map container resizing calls `map.resize()` from a
`ResizeObserver` callback ([MAP-08]).
> **Why:** Interleaved read/write forces synchronous layout on every write ("layout
> thrash"); a sidebar drag on the reference app cost 40 ms per frame until the panel width
> read was moved before the style writes. `resize` events fire only for the window, so a
> panel that changes width without a window resize is missed.

**[PERF-17] SHOULD:** Long scrolling panels that are not virtualised (a settings page, a
feature list under 200 items) declare `content-visibility: auto` with a `contain-intrinsic-size`
on their sections, and fixed-size widgets declare `contain: layout paint`.
> **Why:** `content-visibility: auto` skips rendering work for off-screen sections; on a
> 40-section settings page it cut initial layout from 90 ms to 25 ms. It is a SHOULD
> because it interacts with in-page search and anchor scrolling, which must be tested.

---

## 4. Images

**[PERF-18] MUST:** Raster images are served as WebP or AVIF with a JPEG/PNG fallback only
where the source is user-uploaded; every `<img>` has `width` and `height` attributes (or
`aspect-ratio` CSS); images below the fold carry `loading="lazy"` and `decoding="async"`;
images larger than 400 px wide provide a `srcset` with at least 1x and 2x candidates; no
image above 4 KB is inlined as base64 (`assetsInlineLimit: 4096` in [PERF-09]).
> **Why:** Missing dimensions are the leading cause of CLS above 0.1 in the reference
> app's field reports. A 3 MB PNG logo on the login page was its LCP element for 4.1 s on
> 4G; the same logo as a 40 KB WebP loaded in 0.3 s. Base64 above 4 KB inflates the
> CSS/JS chunk it lives in by 33 % and cannot be cached independently.

```tsx
// RIGHT
<img
  src="/images/hero-800.webp"
  srcSet="/images/hero-800.webp 1x, /images/hero-1600.webp 2x"
  width={800}
  height={450}
  alt={t('home.heroAlt')}
  loading="lazy"
  decoding="async"
/>
```

Icons are `lucide-react` named imports (SVG, tree-shaken) or inline SVG components, never
icon fonts and never an `<img>` per icon. The map sprite is owned by [08](08-MAP-MAPLIBRE.md).

---

## 5. Fonts

**[PERF-19] MUST:** Fonts are self-hosted as WOFF2 under `public/fonts/`, declared with
`@font-face` in `src/shared/styles/index.css` with `font-display: swap`, split into a
`latin` and a `latin-ext` subset with `unicode-range`, and the primary weight's `latin`
file is preloaded from `index.html`. No more than four weight files are shipped per family.
> **Why:** Turkish needs `ğ Ğ ı İ ş Ş` from Latin Extended-A (U+0100 to U+017F) in addition
> to `ç ö ü` from Latin-1. A font shipped with only the `latin` subset renders those six
> glyphs from the fallback font, which is visible on every "İşlem" and "Değiştir" button.
> Two subsets let Latin-only pages skip the second file. `swap` prevents invisible text
> (FOIT) on slow networks; preloading the primary weight removes the request waterfall
> (HTML → CSS → font) that otherwise delays LCP by one round trip.

```css
/* src/shared/styles/index.css (font section) */
@font-face {
  font-family: 'Inter';
  font-style: normal;
  font-weight: 400 700;                     /* variable font: one file covers the range */
  font-display: swap;
  src: url('/fonts/inter-latin.woff2') format('woff2');
  unicode-range: U+0000-00FF, U+0131, U+0152-0153, U+02BB-02BC, U+02C6, U+02DA, U+02DC,
                 U+2000-206F, U+2074, U+20AC, U+2122, U+2191, U+2193, U+2212, U+2215, U+FEFF, U+FFFD;
}
@font-face {
  font-family: 'Inter';
  font-style: normal;
  font-weight: 400 700;
  font-display: swap;
  src: url('/fonts/inter-latin-ext.woff2') format('woff2');
  /* Covers ğ Ğ İ ş Ş and the rest of Latin Extended-A/B. ı (U+0131) is in the latin file
     above because it is used in Turkish so often that a second request for it is not worth it. */
  unicode-range: U+0100-02BA, U+02BD-02C5, U+02C7-02CC, U+02CE-02D7, U+02DD-02FF, U+0304, U+0308,
                 U+0329, U+1E00-1E9F, U+1EF2-1EFF, U+2020, U+20A0-20AB, U+20AD-20C0, U+2113, U+2C60-2C7F, U+A720-A7FF;
}
```

```html
<!-- index.html: preload the primary file; crossorigin is required for fonts even same-origin -->
<link rel="preload" href="/fonts/inter-latin.woff2" as="font" type="font/woff2" crossorigin />
```

**[PERF-20] MUST NOT:** `index.html` or any stylesheet references `fonts.googleapis.com`,
`fonts.gstatic.com` or any other third-party font host in production.
> **Why:** Three reasons, any one sufficient. Privacy: every page view sends the user's IP
> to Google, which for a municipal service is a KVKK (Turkish data protection law) and GDPR
> exposure. CSP: the `font-src` and `style-src` allow-list has to open to a third-party
> origin ([SEC-03]). Latency: the CSS request and the font request are two extra DNS,
> TLS and round trips on the critical path; measured 380 ms on 4G on the reference app,
> whose `index.html` still carries the Google Fonts `<link>` and is corrected by this rule.
> Icon fonts (Material Symbols) are replaced by `lucide-react` ([PERF-18]).

---

## 6. Web Vitals targets

**[PERF-21] MUST:** Every application meets, at the 75th percentile of real users on
production, **LCP ≤ 2.5 s**, **INP ≤ 200 ms** and **CLS ≤ 0.1**, measured with the
`web-vitals` package and reported per route to the error tracker ([OBS-14]). A Lighthouse
CI run against the built image enforces the same thresholds on a throttled profile
(`4G`, 4x CPU slowdown) as a merge gate ([CI-07]); the Lighthouse budget file is owned by
[14](14-GIT-CI.md) §5.
> **Why:** These are the Google "good" thresholds and the ones search ranking uses for
> public pages ([10](10-SEO-RENDERING.md)). For internal dashboards they are still the
> right line: INP above 200 ms is where users start double-clicking, which on a form with a
> mutation means duplicate submissions. Lab numbers (Lighthouse) catch regressions before
> merge; field numbers (web-vitals) catch the devices the lab does not have.

Where each metric usually goes wrong in this stack, and the rule that owns the fix:

| Metric | Typical cause | Fix |
|---|---|---|
| LCP | Non-lazy route pulling maplibre into the shell; font waterfall; hero PNG | [PERF-04], [PERF-19], [PERF-18] |
| INP | Unvirtualised table; filter without transition; 3,000 DOM markers | [PERF-12], [PERF-15], [GEN-18] |
| CLS | Images without dimensions; toast pushing layout; late-loading font swap | [PERF-18], [A11Y-26], [PERF-19] |

During development use `import { onINP } from 'web-vitals/attribution'` in the debug
overlay ([OBS-19]) to see which element and which event handler produced the worst INP.

---

## 7. Long tasks and workers

**[PERF-22] MUST:** Parsing or transforming input above 1 MB (a GeoJSON file, a CSV
import, a large JSON export) runs in a Web Worker created with
`new Worker(new URL('./x.worker.ts', import.meta.url), { type: 'module' })`. Messages
in both directions are validated with a zod schema; large payloads are transferred as
`ArrayBuffer` (transferable), not copied. No RPC wrapper library is used (see Open
questions). Worker lifecycle rules (termination, StrictMode) are in [RT-12].
> **Why:** `JSON.parse` of a 10 MB GeoJSON blocks the main thread for 300 to 900 ms on a
> mid-range device: the map stops panning and INP records the freeze. Workers move the
> parse off-thread. The zod check exists because `postMessage` is an untyped boundary, and
> a shape mismatch between worker and caller is otherwise a silent `undefined` ([GEN-07]).

```ts
// src/features/Import/lib/geojsonParse.worker.ts
import { z } from 'zod'

export const ParseRequestSchema = z.object({
  id: z.string(),
  kind: z.literal('parse-geojson'),
  buffer: z.instanceof(ArrayBuffer),
})
export const ParseResponseSchema = z.discriminatedUnion('kind', [
  z.object({ id: z.string(), kind: z.literal('ok'), featureCount: z.number().int(), bbox: z.tuple([z.number(), z.number(), z.number(), z.number()]) }),
  z.object({ id: z.string(), kind: z.literal('error'), message: z.string() }),
])
export type ParseRequest = z.infer<typeof ParseRequestSchema>
export type ParseResponse = z.infer<typeof ParseResponseSchema>

self.onmessage = (event: MessageEvent<unknown>) => {
  const parsed = ParseRequestSchema.safeParse(event.data)
  if (!parsed.success) return                                     // not ours; ignore, never throw
  const { id, buffer } = parsed.data
  try {
    const text = new TextDecoder().decode(buffer)
    const fc = JSON.parse(text) as { features?: unknown[] }        // validated by the GIS schema in the caller
    const features = Array.isArray(fc.features) ? fc.features : []
    const reply: ParseResponse = { id, kind: 'ok', featureCount: features.length, bbox: computeBbox(features) }
    self.postMessage(reply)
  } catch (error: unknown) {
    const reply: ParseResponse = { id, kind: 'error', message: error instanceof Error ? error.message : String(error) }
    self.postMessage(reply)
  }
}
```

```ts
// src/features/Import/lib/parseGeojsonInWorker.ts
import { ParseResponseSchema, type ParseRequest } from './geojsonParse.worker'

export function parseGeojsonInWorker(file: File, signal: AbortSignal): Promise<{ featureCount: number }> {
  return new Promise((resolve, reject) => {
    const worker = new Worker(new URL('./geojsonParse.worker.ts', import.meta.url), { type: 'module' })
    const id = crypto.randomUUID()
    const done = () => worker.terminate()
    signal.addEventListener('abort', () => { done(); reject(signal.reason) }, { once: true })
    worker.onmessage = (event: MessageEvent<unknown>) => {
      const res = ParseResponseSchema.safeParse(event.data)
      if (!res.success || res.data.id !== id) return
      done()
      res.data.kind === 'ok' ? resolve(res.data) : reject(new Error(res.data.message))
    }
    worker.onerror = (e) => { done(); reject(new Error(`worker failed: ${e.message}`)) }
    file.arrayBuffer().then((buffer) => {
      const req: ParseRequest = { id, kind: 'parse-geojson', buffer }
      worker.postMessage(req, [buffer])                               // transfer, do not copy
    }, reject)
  })
}
```

**[PERF-23] MUST:** No task in the interaction path (from a user event to the resulting
paint) exceeds 50 ms of main-thread time, as observed by `PerformanceObserver` with
`entryTypes: ['longtask']` or the Performance panel. Work that legitimately takes longer
is chunked (`setTimeout(0)` between batches, or `scheduler.yield()` where available),
moved to a worker, or made interruptible with a transition.
> **Why:** 50 ms is the browser's long-task threshold and the point where the next input
> event queues behind the task. Two back-to-back 60 ms tasks produce an INP of 120 ms
> before any rendering has happened.

---

## 8. Memory

**[PERF-24] MUST:** Every `URL.createObjectURL` has a matching `URL.revokeObjectURL` in
the effect cleanup or after the download starts; every `fetch` started by a component is
tied to an `AbortController` aborted on unmount (TanStack Query does this for queries; do
it by hand for anything else); arrays or maps held in `useRef` for streaming data (MQTT
messages, telemetry samples, log lines) are bounded ring buffers with a documented
capacity, never `push()`-only.
> **Why:** An object URL holds its blob for the life of the document; the reference app's
> report preview leaked 8 MB per preview until the tab was closed. An unbounded `ref` array
> fed by a 10 Hz MQTT topic grows to 36,000 entries an hour, and the panel that renders
> it slows proportionally ([RT-06]).

```ts
// bounded ring buffer for a live telemetry panel
const MAX_SAMPLES = 600                              // 10 Hz × 60 s; the chart shows one minute
const samples = useRef<Sample[]>([])
function pushSample(s: Sample) {
  const buf = samples.current
  buf.push(s)
  if (buf.length > MAX_SAMPLES) buf.splice(0, buf.length - MAX_SAMPLES)
}
```

Map-specific leaks (sources, layers, images, popups) are covered by [GEN-20] and
[08](08-MAP-MAPLIBRE.md).

---

## 9. Tooling and review

**[PERF-25] MUST:** `package.json` has an `analyze` script that builds with
`rollup-plugin-visualizer` and opens the treemap, used before every PR that adds a
dependency or a lazy boundary ([PERF-06]). The visualizer is a dev dependency and is not
part of the CI build.

```jsonc
// package.json (scripts excerpt)
{
  "scripts": {
    "build": "tsc -b && vite build",
    "analyze": "ANALYZE=1 vite build && open dist/stats.html",   // Windows: use start
    "size:check": "node frontend-standards/tools/check-bundle-size.mjs dist budget.json"
  }
}
```

```ts
// vite.config.ts (plugins excerpt): only when ANALYZE=1 so CI builds stay fast
import { visualizer } from 'rollup-plugin-visualizer'
// ...
plugins: [
  // ...
  process.env.ANALYZE ? visualizer({ filename: 'dist/stats.html', gzipSize: true, brotliSize: true }) : undefined,
].filter(Boolean),
```

Tools and what each answers:

| Question | Tool | How |
|---|---|---|
| What is in this chunk and why? | `npm run analyze` | Treemap; hover a rectangle to see the import chain |
| Which component re-rendered and how long did it take? | React DevTools Profiler | Record an interaction; sort by "self time"; "Why did this render" needs the setting on |
| Where did the 300 ms go? | Chrome Performance panel | Record with 4x CPU throttle; look at the main-thread flame chart and the Long Tasks track |
| Which element is LCP? | Performance panel → Insights, or `web-vitals/attribution` | `onLCP(({ attribution }) => attribution.element)` |
| Is this chunk lazy? | Network panel | Filter JS; the chunk must appear only after the triggering interaction |
| Are the compressed files served? | `curl -I -H 'Accept-Encoding: br'` | `content-encoding: br`, `cache-control: immutable` |
| Did the map drop frames? | [08](08-MAP-MAPLIBRE.md) instrumentation | `?debug=1` overlay ([OBS-19]) shows FPS during pan |

### Performance review checklist (for PRs that touch the areas above)

1. `npm run build && npm run check:bundle` passes locally; numbers quoted in the PR.
2. New dependency: gzipped size from the analyzer is in the PR ([VER-06]); it is lazy if over 20 KB.
3. New route: appears in the router as `lazy`; its chunk is under 150 KB gz.
4. New list/table: row count can exceed 200 → virtualised.
5. New filter/toggle over a large render: wrapped in a transition.
6. New `useMemo`/`useCallback`/`memo`: has the measurement comment.
7. New image: WebP/AVIF, dimensions, `loading="lazy"` if below the fold.
8. New `@font-face` or font weight: self-hosted, subset, at most four files per family.
9. New parse of a large payload: worker, zod-checked messages.
10. New object URL / manual fetch / streaming ref: cleanup present and bounded.
11. Lighthouse CI result on the PR is green; no vitals regression above 10 % vs `main`.
12. Any "perf" claim in the description has a before and an after.

---

## Open questions

- **Worker RPC wrapper.** `comlink` (proxy-based RPC over `postMessage`, about 1.5 KB gz)
  would remove the hand-written id matching in §7. It is not in the `02` table. Adopt it
  when a third worker is added to any app; until then two hand-written workers are less
  code than a dependency plus its typing quirks.
- **`scheduler.yield()`.** Used in [PERF-23] as the preferred chunking primitive. It is
  Baseline as of 2025 in Chrome and Firefox but Safari support should be verified against
  the [VER-12] matrix at the time of writing code; fall back to `setTimeout(0)` behind a
  feature check.
- **Speculation Rules / prefetching routes.** Prefetching the next likely route chunk on
  hover (`<link rel="prefetch">` or React Router's `prefetch`) is not required by this
  file. Revisit when field LCP on secondary routes is measured above 2.5 s.
- **Image CDN / on-the-fly resizing.** User-uploaded images are served as stored. If
  uploads exceed 200 KB median, a resize step belongs in the backend standard, not here.
