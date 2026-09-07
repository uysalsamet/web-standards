# 03 — Project Structure

> Feature-based layout with a strict import direction. The goal: someone opening a folder
> knows what they will find, a feature can be deleted or lazy-loaded as a unit, and the map
> does not become a god object. Code examples target React 19 + Vite 8 + TypeScript 6.

---

## 1. Repository layout

```
<app>/
├── deployments/
│   ├── main/
│   │   ├── Dockerfile                  # multi-stage: node builder → nginx runtime
│   │   ├── docker-compose.yml          # prod shape (web + nginx edge)
│   │   ├── docker-compose.dev.yml      # vite dev server in a container (optional)
│   │   ├── nginx/
│   │   │   ├── nginx.conf              # http{} level: log format, maps, upstreams
│   │   │   └── default.conf.template   # server{}: envsubst-rendered at start
│   │   ├── config.js.template          # runtime config → /config.js (envsubst)
│   │   ├── .env.example                # variable NAMES, no values; committed
│   │   ├── .env.local / .env.prod      # real values; git-ignored
│   │   └── .env                        # COMPOSE_PROJECT_NAME only
│   └── map/                            # tile services compose, style JSON, sprites, fonts
├── docs/
│   ├── README.md                       # what the app is, page map, upstream list, ports
│   └── adr/                            # app-level decisions (the standard's ADRs live in the standard)
├── public/                             # copied verbatim: favicons, robots.txt (non-SEO apps), fonts/
├── src/
│   ├── app/                            # composition root
│   │   ├── providers/AppProviders.tsx  # QueryClient, Redux, i18n, Toaster, theme
│   │   ├── router/router.tsx           # createBrowserRouter, lazy routes
│   │   ├── router/RouteErrorBoundary.tsx
│   │   └── config/runtimeConfig.ts     # reads window.__APP_CONFIG__, validates with zod
│   ├── features/
│   │   └── <Name>/                     # PascalCase, singular domain noun
│   ├── shared/
│   │   ├── api/                        # client.ts, errors.ts, schemas/common.ts, queryKeys.ts
│   │   ├── components/                 # domain-free UI: Button, Modal, DataTable, Loading, EmptyState
│   │   ├── hooks/                      # useDebouncedValue, useMediaQuery, usePagination
│   │   ├── i18n/                       # config.ts, locales/<lng>/<namespace>.json, keys.d.ts
│   │   ├── lib/                        # wrappers around third-party libs: maplibre init, sentry init
│   │   ├── map/                        # MapContext, useMap, layer registry, layer id helpers
│   │   ├── styles/                     # index.css (tailwind import, tokens), maplibre overrides
│   │   ├── types/                      # global ambient types, branded ids
│   │   └── utils/                      # pure functions: format, geo, clipboard
│   ├── store/                          # store.ts, hooks.ts (typed useAppDispatch/useAppSelector)
│   ├── test/                           # setup.ts, msw handlers, render helpers
│   ├── main.tsx
│   └── vite-env.d.ts
├── index.html
├── vite.config.ts
├── tsconfig.json / tsconfig.app.json / tsconfig.node.json
├── eslint.config.js
├── .prettierrc
├── .nvmrc
├── .dockerignore
├── AGENTS.md                           # from templates/agents/ (see START.md)
└── package.json
```

**[STR-01] MUST:** The app is one Vite project with one `package.json`. Multiple apps in one
repo are separate top-level folders with their own `package.json` (no npm workspaces unless
approved; see Open questions).

**[STR-02] MUST:** `deployments/` holds everything about running the app; `src/` holds
everything about building it. Nothing under `src/` reads `deployments/` and vice versa.

**[STR-03] MUST:** `public/` contains only files that must be served under a fixed path
unchanged (favicons, `robots.txt` for non-SEO apps, PDF fonts, static GeoJSON under
`public/data/` up to the [GEN-19] limit). Everything else is imported so Vite hashes it.

---

## 2. Feature layout

```
src/features/Parking/
├── api/
│   ├── parkingApi.ts          # functions calling shared client; one per endpoint
│   ├── parkingSchemas.ts      # zod schemas + inferred types for DTOs
│   └── parkingQueries.ts      # queryOptions / mutation factories + key factory
├── components/
│   ├── ParkingList.tsx
│   ├── ParkingForm.tsx
│   └── ParkingLayer.tsx       # map layer component (registers source/layers, no UI)
├── hooks/
│   ├── useParkingSelection.ts
│   └── useParkingLayerToggles.ts
├── pages/
│   ├── ParkingPage.tsx        # route component; composes, does not compute
│   └── ParkingDetailPage.tsx
├── store/                     # only if the feature owns cross-feature client state
│   └── parkingSlice.ts
├── lib/                       # feature-specific pure logic (capacity math, colour scales)
├── types/
│   └── index.ts               # UI-only types (view models, props unions). DTOs live in api/
├── styles/
│   └── ParkingLayer.css       # only what Tailwind cannot express (keyframes, maplibre popups)
├── locales/                   # optional: feature namespace, merged by the i18n build step
│   ├── tr.json
│   └── en.json
├── README.md                  # what the feature does, routes, layers it adds, upstream endpoints
└── index.ts                   # PUBLIC API. The only file other code may import from
```

**[STR-04] MUST:** Feature folder name is PascalCase, a singular domain noun
(`Parking`, `WasteTruck`, `BuildingInspection`). Not `ParkingModule`, not `parkings`,
not `parking-feature`.

**[STR-05] MUST:** A feature exposes a public API through `index.ts`: its route objects,
its page components (lazy), its map layer component, and the hooks/types other features
genuinely need. Internal components, api functions and schemas are not exported.
> **Why:** The public API is the seam that lets you refactor internals, lazy-load the feature
> as a chunk, and see at a glance what the rest of the app depends on.

**[STR-06] MUST:** Every feature has a `README.md` stating: purpose, routes it owns, map
layers and source ids it registers, backend endpoints it calls, and any permissions it
checks. Twenty lines, kept current. The checklist ([15](15-NEW-FEATURE-CHECKLIST.md))
requires it.

**[STR-07] MUST:** Subfolders exist only when they have content. An empty `store/` or
`lib/` is deleted. A feature with one component does not need `components/`; the component
sits next to `index.ts`.

**[STR-08] MUST:** Page components live in `pages/` and are the only components referenced
from the router. A page composes hooks and components; it contains no data transformation
longer than a `map`. Logic goes to `hooks/` or `lib/`.

**[STR-09] MUST NOT:** `utils/` inside a feature. Pure logic is `lib/` (feature-specific)
or `src/shared/utils/` (domain-free). "utils" becomes the drawer where everything is thrown.

---

## 3. Import direction

```
        ┌──────────┐
        │   app    │   composition root. imports features' public API and shared.
        └────┬─────┘
             │
        ┌────▼─────┐
        │ features │   import shared. import OTHER features only via their index.ts,
        │          │   and only when a real dependency exists (see STR-11).
        └────┬─────┘
             │
        ┌────▼─────┐
        │  shared  │   imports nothing above. Domain-free. Could be a separate package.
        └──────────┘
```

**[STR-10] MUST:** `src/shared/**` never imports from `src/features/**` or `src/app/**`.
`src/features/**` never imports from `src/app/**`. Enforced by `eslint-plugin-import-x`
`no-restricted-paths` ([STR-12]).

**[STR-11] MUST:** A feature imports another feature only through `@/features/<Name>`
(its `index.ts`), never a deep path. If feature A needs feature B's *internals*, the shared
piece moves to `src/shared/` or the two features are one feature.
> **Why:** Deep imports across features create hidden coupling: B's refactor breaks A,
> and B can no longer be lazy-loaded without dragging A along.

**[STR-12] MUST:** The import direction is enforced in `eslint.config.js`:

```js
// eslint.config.js (excerpt)
import importX from 'eslint-plugin-import-x'

export default defineConfig([
  {
    files: ['src/**/*.{ts,tsx}'],
    plugins: { 'import-x': importX },
    rules: {
      'import-x/no-restricted-paths': ['error', {
        zones: [
          { target: './src/shared',   from: './src/features', message: 'shared must not import features' },
          { target: './src/shared',   from: './src/app',      message: 'shared must not import app' },
          { target: './src/features', from: './src/app',      message: 'features must not import app' },
          // Deep cross-feature imports: allow only <Feature>/index.ts
          { target: './src/features/*/!(index.ts)', from: './src/features/*/!(index.ts)',
            except: ['./index.ts'], message: 'import another feature only via its index.ts' },
        ],
      }],
      'import-x/no-cycle': ['error', { maxDepth: 4 }],
      'import-x/order': ['error', {
        groups: ['builtin', 'external', 'internal', 'parent', 'sibling', 'index', 'type'],
        pathGroups: [{ pattern: '@/**', group: 'internal' }],
        'newlines-between': 'always',
        alphabetize: { order: 'asc', caseInsensitive: true },
      }],
    },
  },
])
```

**[STR-13] MUST:** Path alias `@/` maps to `src/`. Relative imports are used only within the
same feature (max two levels: `../hooks/x`). Anything crossing a feature boundary uses `@/`.

```json
// tsconfig.app.json (excerpt)
{ "compilerOptions": { "baseUrl": ".", "paths": { "@/*": ["src/*"] } } }
```
```ts
// vite.config.ts (excerpt)
resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } }
```

**[STR-14] MUST NOT:** Barrel files (`index.ts` re-exporting everything) anywhere except a
feature's public API and `src/shared/components/index.ts`. Deep barrels defeat tree-shaking
and create import cycles.

---

## 4. Naming

| Thing | Convention | Example |
|---|---|---|
| Component file | PascalCase, one component per file, named export | `ParkingList.tsx` exports `ParkingList` |
| Hook file | camelCase starting with `use` | `useParkingSelection.ts` |
| Non-component TS file | camelCase | `parkingApi.ts`, `formatArea.ts` |
| Page component | `<Name>Page` | `ParkingDetailPage` |
| Map layer component | `<Name>Layer` | `ParkingLayer` |
| Redux slice | `<name>Slice.ts`, slice name `'<name>'` | `parkingSlice.ts` |
| Query key factory | `<name>Keys` | `parkingKeys.list(filters)` |
| zod schema | `<Name>Schema`; type `<Name>` inferred | `ParkingSchema`, `type Parking = z.infer<typeof ParkingSchema>` |
| Constants | `UPPER_SNAKE` for module-level literals | `MAX_GEOJSON_FEATURES = 5_000` |
| CSS file | Same name as the component it styles | `ParkingLayer.css` |
| i18n namespace | camelCase feature name | `parking`, `wasteTruck` |
| Map source/layer id | `<feature>-<kind>[-<variant>]`, kebab | `parking-points`, `parking-points-label`, `parking-fill-selected` |
| Test file | `<name>.test.ts(x)` next to the unit; e2e under `e2e/` | `useParkingSelection.test.ts` |
| Env var (runtime) | `APP_` prefix, UPPER_SNAKE | `APP_API_BASE_URL` |
| Env var (build-time) | `VITE_` prefix; only for [GEN-09]-compliant constants | `VITE_BUILD_ID` |

**[STR-15] MUST:** Named exports only. No `export default` except where a framework
requires it (`React.lazy` targets use a named re-export: `export { ParkingPage as default }`
inside the lazy import module, or `lazy(() => import('./ParkingPage').then(m => ({ default: m.ParkingPage })))`).
> **Why:** Default exports rename silently at the import site and break "find all references".

**[STR-16] MUST:** No file is named `index.tsx` for a component and no folder is created just
to hold `index.tsx`. `Button/Button.tsx` + `Button/index.ts` (re-export) is acceptable only
inside `src/shared/components/`.

**[STR-17] MUST:** English identifiers in code. Domain terms that have no clean English
equivalent (`imar`, `mahalle`, `ada/parsel`) are kept as-is and defined once in
`src/shared/types/domain.ts` with a comment. User-visible text is never in code ([GEN-14]).

---

## 5. The composition root (`src/app`)

```tsx
// src/main.tsx
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { RouterProvider } from 'react-router-dom'

import '@/shared/styles/index.css'
import '@/shared/i18n/config'
import { loadRuntimeConfig } from '@/app/config/runtimeConfig'
import { AppProviders } from '@/app/providers/AppProviders'
import { router } from '@/app/router/router'
import { initErrorTracking } from '@/shared/lib/errorTracking'

// Runtime config is validated BEFORE anything renders. A malformed /config.js is a
// deploy error and must fail loudly here, not as an undefined URL three screens later.
const config = loadRuntimeConfig()
initErrorTracking(config)

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <AppProviders config={config}>
      <RouterProvider router={router} />
    </AppProviders>
  </StrictMode>,
)
```

**[STR-18] MUST:** `main.tsx` does wiring only and stays under 60 lines. No business
logic, no feature imports beyond what `AppProviders` and `router` need.

**[STR-19] MUST:** `AppProviders` is the one place providers are nested, in this order
(outer to inner): error boundary → runtime config context → QueryClientProvider → Redux
`Provider` → theme → i18n (already initialised, no provider needed) → feature-level
providers that must be global (auth) → `Toaster`. Feature providers that are only needed on
some routes are mounted in that route's layout, not here.

**[STR-20] MUST:** `runtimeConfig.ts` reads `window.__APP_CONFIG__`, parses it with a zod
schema, and exports a typed frozen object. Missing or malformed config throws with the
field name. See [11](11-DOCKER-COMPOSE.md) §3 for the producing side.

```ts
// src/app/config/runtimeConfig.ts
import { z } from 'zod'

const RuntimeConfigSchema = z.object({
  apiBaseUrl: z.string().url().or(z.string().startsWith('/')),
  tileBaseUrl: z.string().startsWith('/'),
  mapStyleUrl: z.string(),
  mqttWsUrl: z.string().regex(/^wss?:\/\//).or(z.string().startsWith('/')),
  release: z.string().min(1),           // git sha, injected by the build ([OBS-05])
  environment: z.enum(['local', 'staging', 'production']),
  features: z.record(z.string(), z.boolean()).default({}),
  // Public sites only. Canonical URLs, hreflang alternates and OG tags need an absolute
  // origin, and it differs per environment, so it cannot be a build-time constant ([SEO-12]).
  siteUrl: z.string().url().optional(),
  siteName: z.string().min(1).optional(),
})
export type RuntimeConfig = z.infer<typeof RuntimeConfigSchema>

declare global {
  interface Window { __APP_CONFIG__?: unknown }
}

export function loadRuntimeConfig(): Readonly<RuntimeConfig> {
  const result = RuntimeConfigSchema.safeParse(window.__APP_CONFIG__)
  if (!result.success) {
    // Deploy-time error. Surfacing the field list is safe: config is public by definition.
    throw new Error(`Invalid runtime config (/config.js): ${result.error.issues.map(i => i.path.join('.')).join(', ')}`)
  }
  return Object.freeze(result.data)
}
```

---

## 6. Shared layer rules

**[STR-21] MUST:** `src/shared/components/` contains only components with no domain
knowledge: they take data via props and know nothing about parking, waste or parcels. A
component that imports a feature's types moves into that feature.

**[STR-22] MUST:** Third-party libraries with global setup (MapLibre worker config, Sentry,
i18next, MQTT client factory) are wrapped once in `src/shared/lib/<name>.ts`. Features import
the wrapper, never the library's setup API.

**[STR-23] MUST:** `src/shared/map/` owns the map instance lifecycle: `MapContext`,
`MapContainer`, `useMap()`, the layer registry and id helpers. Features add layers *through*
this module ([MAP-01]..[MAP-06]); they never create a second `maplibregl.Map`.

**[STR-24] SHOULD:** `src/shared/` is written as if it were a separate npm package: no
imports from above, no knowledge of routes, no `window.__APP_CONFIG__` reads (config is
passed in). If it ever needs to be extracted, it can be.

---

## 7. File size and shape

**[STR-25] MUST:** File ≤ 400 lines, component ≤ 250 lines, hook ≤ 150 lines, function ≤ 60
lines. The check script warns at the limit and errors at 1.5× ([TOOL-03]).

**[STR-26] MUST:** One React component per file. Small private sub-components (under 20
lines, used only by the file's main component) may live in the same file, below the main
export.

**[STR-27] MUST:** The order inside a component file: imports → constants/schemas → types →
the component → private sub-components → helpers. Hooks are not defined inside component
files; they get their own file in `hooks/`.

**[STR-28] MUST:** Comments explain *why*, not *what*. A comment that restates the code is
deleted. A workaround, a browser quirk, a MapLibre ordering constraint or a performance
measurement is exactly what a comment is for, and includes the measurement or the link.

---

## 8. Generated and vendored code

**[STR-29] MUST:** Generated files (OpenAPI types, i18n key typings) are committed, carry a
`// GENERATED — do not edit; run npm run gen:<x>` header, and are regenerated in CI with a
diff check ([CI-12]) so they cannot drift.

**[STR-30] MUST NOT:** Vendored copies of third-party source under `src/`. If a library
needs a patch, use `patch-package` style `patches/` (via `npm` `overrides` + a documented
patch) with an issue link and a removal condition.

---

## Open questions

- **npm workspaces / monorepo.** Not adopted. Revisit when two apps share more than
  `src/shared/components/` and the copy count exceeds three. At that point the shared code
  becomes a workspace package with its own tests and version.
- **Feature-level `locales/` merge step.** Allowed by [STR-05] but the build-time merge
  script is not yet in `tools/`. Until then, all keys live in `src/shared/i18n/locales/`
  under a per-feature namespace ([I18N-06]).
