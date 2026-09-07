# 22 — Routing

> Governs the route tree: how it is composed, how pages are split and loaded, what the URL
> is allowed to mean, and what happens when a path does not exist. The core principle:
> **the router owns navigation, TanStack Query owns data.** Read this when adding a page,
> adding a guard, changing a path, or debugging a route that a dev proxy has swallowed.
>
> Out of scope: server state and cache policy ([05](05-STATE-AND-DATA.md)), error boundary
> internals ([17](17-ERRORS-OBSERVABILITY.md)), auth mechanics ([19](19-AUTH-SESSION.md)),
> the map instance itself ([08](08-MAP-MAPLIBRE.md)), SEO rendering ([10](10-SEO-RENDERING.md)).

---

## 1. The router

The app has exactly one router: a React Router 7 **data router**
(`createBrowserRouter` + `RouterProvider`). Data mode is what makes route-level
`ErrorBoundary`, `lazy`, `useNavigation`, `useBlocker` and `useRouteError` available. The
older `<BrowserRouter><Routes>` component mode has none of them.

**[RTE-01] MUST:** The application creates one router with `createBrowserRouter` in
`src/app/router/router.tsx` and renders it with `<RouterProvider router={router} />` in
`main.tsx` ([STR-18]). `<BrowserRouter>`, `<Routes>` and `<Switch>` are not used anywhere in
`src/`, and no second router is created for a sub-tree.
> **Why:** Component mode silently disables every route-level facility this document
> depends on. A `<Routes>` island inside a data router also creates a second history
> consumer: `useNavigation` reports idle while that island is loading, so the progress bar
> ([RTE-06]) never appears for those pages.

**[RTE-02] MUST:** `router.tsx` contains no page imports. Every feature exports its own
route objects from its public `index.ts` ([STR-05]) as
`export const <feature>Routes: RouteObject[]`, defined in
`src/features/<Name>/routes.tsx`, and `router.tsx` only composes them into layout routes.
> **Why:** A central file that imports every page is the file every feature branch edits,
> so it is the file every merge conflicts on. The reference project's `router.tsx` is
> 1,300 lines with 120 `React.lazy` calls at the top; adding a page there means reading all
> of it. With feature route objects, adding a page touches one feature folder and one line
> in `router.tsx`.

**[RTE-03] MUST:** Every page component is loaded through the route object's `lazy`
property. No page component is imported statically into `router.tsx` or into a feature's
`routes.tsx`. Cross-ref: [PERF-04].
> **Why:** A static import pulls the page, its feature and its heavy dependencies (charts,
> exporters, the map) into the app shell for every user. On the reference app one
> non-lazy admin page added 210 KB gz to first paint for the 95 % who never opened it.

```tsx
// The RR7 data-mode form: `lazy` is an async function returning a partial route module.
// The returned object's keys are route properties (Component, loader, ErrorBoundary…),
// NOT a React component.
{
  path: 'parkings',
  lazy: async () => {
    const { ParkingListPage } = await import('./pages/ParkingListPage')
    return { Component: ParkingListPage }
  },
}
```

> Verify against the installed `react-router-dom` 7.x: recent 7.x minors also accept an
> **object** form (`lazy: { Component: async () => …, loader: async () => … }`) that lazies
> each property separately. The standard uses the function form above because it is present
> in every 7.x release. If you adopt the object form, confirm it exists in the pinned
> version (`node -e "console.log(require('react-router-dom/package.json').version)"`) before
> relying on it.

**[RTE-04] MUST:** The tree has exactly three kinds of layout route, nested in this order:
`RootLayout` (chrome, `<ScrollRestoration>`, progress bar, toaster outlet) →
`RequireAuth` (session gate, [RTE-24]) → optionally `MapLayout` for map pages. `MapLayout`
mounts the single `MapContainer` ([MAP-01]) and renders `<Outlet />` over it, so navigating
between two map pages does not destroy and recreate the WebGL context.
> **Why:** A map page that owns its own `MapContainer` unmounts the map on every
> navigation. Recreating a MapLibre instance with a style, glyphs, sprites and 12 sources
> costs 900 to 1,400 ms on the reference hardware and shows a white rectangle for that
> whole time. Under a shared layout route the map instance survives; only the layers the
> leaving feature registered are removed ([MAP-06], [GEN-20]).

**[RTE-05] MUST:** Every lazy page renders inside a `<Suspense>` whose fallback is a
route-shaped skeleton, never `null` and never a full-screen spinner that replaces the
chrome. The boundary sits in the layout route around `<Outlet />`, not around each page.
> **Why:** `fallback={null}` (the reference project's choice) means clicking a nav item does
> nothing visible for the 200 to 900 ms the chunk takes on 4G, so users click again and
> queue two navigations. A skeleton of the right shape also keeps CLS ≤ 0.1 ([PERF-21]).

**[RTE-06] MUST:** Global pending state comes from `useNavigation()`. A top progress bar is
shown when `navigation.state !== 'idle'` **and** the navigation has lasted more than 150 ms;
it is never shown for a state change under that threshold.
> **Why:** Navigations that resolve in 40 ms (a cached chunk) produce a bar that flashes on
> and off, which reads as a glitch. 150 ms is the threshold below which humans do not
> perceive a delay as a wait, so a bar there adds noise, not information.

**[RTE-07] MUST:** Every route object has an `ErrorBoundary`, set directly or inherited
from its layout route, and it is `RouteErrorBoundary` from
`src/app/router/RouteErrorBoundary.tsx`. Cross-ref: [OBS-03], [OBS-06].
> **Why:** Without a route-level boundary an exception in one page unmounts the whole
> router, including the navigation the user needs to leave the broken page. The boundary
> also distinguishes chunk-load failure after a deploy (reload once per release, [OBS-06])
> from a genuine crash.

```tsx
// src/app/router/router.tsx
import { createBrowserRouter } from 'react-router-dom'
import type { RouteObject } from 'react-router-dom'

import { authRoutes } from '@/features/Auth'
import { parkingRoutes } from '@/features/Parking'
import { wasteTruckRoutes } from '@/features/WasteTruck'
import { NotFoundPage } from '@/shared/components/NotFoundPage'

import { MapLayout } from './MapLayout'
import { RequireAuth } from './RequireAuth'
import { RootLayout } from './RootLayout'
import { RouteErrorBoundary } from './RouteErrorBoundary'

export const routes = [
  {
    // Pathless root: chrome + ScrollRestoration + progress bar + Suspense boundary.
    element: <RootLayout />,
    ErrorBoundary: RouteErrorBoundary,
    children: [
      // Public routes: login, password reset, share links. No session required.
      ...authRoutes,
      {
        element: <RequireAuth />,
        children: [
          { index: true, lazy: async () => ({ Component: (await import('@/features/Home')).HomePage }) },
          // Map pages share one MapLibre instance ([RTE-04], [MAP-01]).
          {
            element: <MapLayout />,
            children: [...parkingRoutes.filter((r) => r.handle?.map), ...wasteTruckRoutes.filter((r) => r.handle?.map)],
          },
          ...parkingRoutes.filter((r) => !r.handle?.map),
          ...wasteTruckRoutes.filter((r) => !r.handle?.map),
        ],
      },
      // Catch-all. Renders the same component nginx serves for indexed 404s ([RTE-14]).
      { path: '*', Component: NotFoundPage },
    ],
  },
] satisfies RouteObject[]

export const router = createBrowserRouter(routes)
```

If the `handle.map` filtering above reads as clever, split the export instead: a feature
may export `parkingRoutes` and `parkingMapRoutes`. Both are acceptable; pick one per repo
and keep it.

The feature side of the same tree, in full:

```tsx
// src/features/Parking/routes.tsx
import { redirect } from 'react-router-dom'
import type { LoaderFunctionArgs, RouteObject } from 'react-router-dom'

import { queryClient } from '@/app/providers/queryClient'
import { RequirePermission } from '@/app/router/RequirePermission'

import { parkingDetailOptions, parkingListOptions } from './api/parkingQueries'
import { ParkingIdSchema } from './types/ids'

// Loaders prefetch only; the components still read through useQuery ([RTE-08]).
function listLoader() {
  void queryClient.ensureQueryData(parkingListOptions({})).catch(() => {})
  return null
}

async function detailLoader({ params }: LoaderFunctionArgs) {
  const parsed = ParkingIdSchema.safeParse(params.id)
  if (!parsed.success) throw new Response('Not Found', { status: 404 }) // [RTE-09]
  void queryClient.ensureQueryData(parkingDetailOptions(parsed.data)).catch(() => {})
  return null
}

export const parkingRoutes: RouteObject[] = [
  {
    path: 'parkings',
    handle: { crumb: 'nav.parkings' }, // read by useRouteInstrumentation ([RTE-26])
    children: [
      { index: true, loader: listLoader, lazy: async () => ({ Component: (await import('./pages/ParkingListPage')).ParkingListPage }) },
      // Map view lives under MapLayout; handle.map is how router.tsx sorts it there.
      { path: 'map', handle: { crumb: 'nav.parkingsMap', map: true }, lazy: async () => ({ Component: (await import('./pages/ParkingMapPage')).ParkingMapPage }) },
      { path: ':id', loader: detailLoader, lazy: async () => ({ Component: (await import('./pages/ParkingDetailPage')).ParkingDetailPage }) },
      {
        // Editing needs a permission the list does not ([RTE-24]).
        element: <RequirePermission permission="parking.manage" />,
        children: [
          { path: ':id/edit', loader: detailLoader, lazy: async () => ({ Component: (await import('./pages/ParkingEditPage')).ParkingEditPage }) },
        ],
      },
    ],
  },
  // Legacy Turkish path kept for bookmarks. Added 2026-09-07, remove after 2027-09-07.
  { path: 'otoparklar', loader: () => redirect('/parkings') },
]
```

```ts
// src/features/Parking/index.ts: the feature's public API ([STR-05])
export { parkingRoutes } from './routes'
export { ParkingLayer } from './components/ParkingLayer'
export type { ParkingId } from './types/ids'
```

---

## 2. Loaders, actions and data

**[RTE-08] MUST:** Route `loader`s are not used to fetch data for rendering. A component
reads server data with `useQuery`/`useSuspenseQuery` ([STA-05], [GEN-05]). A loader is
permitted only to (a) validate params ([RTE-12]), (b) call
`queryClient.ensureQueryData(...)` to start a fetch before the component mounts, or
(c) `redirect()` ([RTE-13]). A loader never returns data that a component then reads with
`useLoaderData`.
> **Why:** Two caches with two invalidation policies is [GEN-05]'s exact failure: a mutation
> invalidates the Query cache, the loader data stays stale, and the page shows the old row
> until a full navigation. Keeping the loader as a *prefetch* keeps one cache and still
> removes the request waterfall (chunk downloads and fetch start in parallel instead of
> in series, worth 150 to 400 ms on a detail route).

```ts
// src/features/Parking/routes.tsx (excerpt)
import type { LoaderFunctionArgs, RouteObject } from 'react-router-dom'

import { queryClient } from '@/app/providers/queryClient'

import { parkingDetailOptions } from './api/parkingQueries'
import { ParkingIdSchema } from './types/ids'

async function parkingDetailLoader({ params }: LoaderFunctionArgs) {
  const parsed = ParkingIdSchema.safeParse(params.id)
  // An unparseable id is a 404, not a crash and not a request the backend has to reject.
  if (!parsed.success) throw new Response('Not Found', { status: 404 })

  // Fire and forget: the component still renders through useQuery, so a failed prefetch
  // is not a navigation failure. The error surfaces in the component's error state.
  void queryClient.ensureQueryData(parkingDetailOptions(parsed.data)).catch(() => {})
  return null
}
```

**[RTE-09] MUST:** A loader signals "this route cannot be shown" by throwing a `Response`
with the right status (404 for a missing or invalid resource, 403 for a permission
failure). `RouteErrorBoundary` renders these through `isRouteErrorResponse` ([OBS-03]);
loaders never `throw new Error()` for an expected condition and never `console.error` it.
> **Why:** A thrown `Error` is reported to the error tracker as a crash. A stale bookmark to
> a deleted parking is normal traffic ([API-30]); with 400 such visits a day it drowns the
> tracker and the real crashes are never seen.

**[RTE-10] MUST NOT:** Route `action`s and `<Form method="post">` are not used. All
mutations go through TanStack Query mutation hooks ([STA-14]) submitted from
react-hook-form ([FORM-01]).
> **Why:** Actions have their own revalidation model (revalidate all loaders on the page).
> Mixing it with Query invalidation means every write has two competing refresh paths, and
> which one wins depends on timing. One mutation path, one invalidation policy ([STA-12]).

---

## 3. Paths, params, redirects and 404

**[RTE-11] MUST:** Paths are lowercase kebab-case, collections are plural nouns, and a
resource identifier is a path segment, not a query parameter:

| Shape | Example | Not |
|---|---|---|
| Collection | `/parkings` | `/parkingList`, `/Parking`, `/parking_list` |
| Detail | `/parkings/:id` | `/parkings/detail?id=7` |
| Sub-resource | `/parkings/:id/edit`, `/parkings/:id/sessions` | `/edit-parking/:id` |
| View variant | `/parkings/map`, `/parkings/list` | `/parkings?view=map` when the two views load different code |
| Action | never a path; a mutation is a button | `/parkings/:id/delete` |

No path ends with a trailing slash, and no path contains a locale prefix except in an
SEO-indexed product ([SEO-08]), where the prefix is the first segment (`/tr/…`, `/en/…`).
> **Why:** `/parkings/7` and `/parkings/7/` are two URLs for one page: two analytics rows,
> two cache entries, and a canonical-tag mismatch on public pages. Ids in the path make the
> route pattern the unit of analytics, prefetch and permission; ids in the query make every
> detail page the same route with a hidden variable.

**[RTE-12] MUST:** Params from `useParams` are parsed with a zod schema into a branded id
type before use; an unparseable param renders the not-found state ([RTE-14]). Raw
`params.id` is never passed to an API function.
> **Why:** `useParams` is typed `Record<string, string | undefined>`. `params.id!` sends
> `undefined` or `%20` to the backend, which answers 400 or 500, and the UI shows a server
> error for what is really a bad link.

```ts
// src/features/Parking/types/ids.ts
import { z } from 'zod'

// Branded id: a plain string cannot be passed where a ParkingId is expected ([TS-12]).
export const ParkingIdSchema = z.string().uuid().brand<'ParkingId'>()
export type ParkingId = z.infer<typeof ParkingIdSchema>
```

```tsx
// src/features/Parking/hooks/useParkingIdParam.ts
import { useParams } from 'react-router-dom'

import { ParkingIdSchema, type ParkingId } from '../types/ids'

/** Returns null for a malformed id so the page can render the not-found state. */
export function useParkingIdParam(): ParkingId | null {
  const { id } = useParams()
  const parsed = ParkingIdSchema.safeParse(id)
  return parsed.success ? parsed.data : null
}
```

**[RTE-13] MUST:** A permanent path change is a `redirect()` from a loader on the legacy
path; an in-render redirect uses `<Navigate to={…} replace />`. Legacy redirects carry a
comment with the date they were added and the date they may be deleted (12 months).
> **Why:** `<Navigate>` without `replace` puts the old path in the history stack, so the
> back button lands on the redirect and bounces the user forward again: the page becomes
> impossible to leave with back. A loader `redirect()` happens before any component
> renders, so nothing flashes.

```ts
// Legacy path kept for bookmarks. Added 2026-09-07, remove after 2027-09-07.
{ path: 'otoparklar', loader: () => redirect('/parkings') }
```

**[RTE-14] MUST:** A missing resource or an unmatched path renders `NotFoundPage`: an i18n
message, a link to the section root and a link to home. A catch-all `{ path: '*' }` route
exists at the top level. Cross-ref: [API-30], [OBS-03].

**A single-page application cannot set an HTTP 404 status.** The document is
`index.html`, served with 200 by nginx before any JavaScript runs, so a client-side 404 is a
*soft 404*: correct for the human, invisible to a crawler. Fix it at the layer that owns the
status code:

- **Internal apps (no indexing):** nothing more to do. The soft 404 is acceptable because
  no crawler reads it, and `robots.txt` disallows everything ([SEO-02]).
- **Indexed prefixes:** nginx returns a real 404 for paths under an indexed prefix that do
  not resolve, or the request-time SEO injector answers 404 for an unknown entity, instead
  of falling back to `index.html`. Cross-ref: [NGX-03], [SEO-11], [GEN-12].

> **Why:** Google treats a 200 page saying "not found" as a soft 404: it stays in the index,
> competes with the real pages and drags the site's quality signal down. The fallback rule
> in nginx is what decides this, not the React component.

```tsx
// src/shared/components/NotFoundPage.tsx
import { useTranslation } from 'react-i18next'
import { Link, useLocation } from 'react-router-dom'

export function NotFoundPage() {
  const { t } = useTranslation()
  const { pathname } = useLocation()
  // First segment: /parkings/nope → /parkings. Gives a useful "back to the section" link.
  const sectionRoot = `/${pathname.split('/').filter(Boolean)[0] ?? ''}`

  return (
    <main className="mx-auto flex max-w-md flex-col items-center gap-4 p-8 text-center">
      <h1 className="text-2xl font-semibold">{t('errors.notFound.title')}</h1>
      <p className="text-sm text-slate-500">{t('errors.notFound.description')}</p>
      <div className="flex gap-3">
        {sectionRoot !== '/' && (
          <Link className="underline" to={sectionRoot}>
            {t('errors.notFound.backToSection')}
          </Link>
        )}
        <Link className="underline" to="/">
          {t('errors.notFound.backHome')}
        </Link>
      </div>
    </main>
  )
}
```

---

## 4. URL as state

**[RTE-15] MUST:** Search-param state is read and written through a
`useSearchParamState(schema, options)` hook built on `useSearchParams`. The setter merges
into the existing params and never replaces them wholesale. Updates that follow a
continuous gesture (map viewport, typeahead text, a slider) use `replace: true`; updates
that express a user intent (a filter, a tab, a page number, opening a detail panel) push a
history entry. Cross-ref: [STA-30], [STA-31], [STA-33].
> **Why:** `setSearchParams({ page: '2' })` drops every other parameter, so changing the
> page loses the filters and the map viewport. Pushing on every `moveend` adds ~30 history
> entries to a single map drag, and the back button becomes unusable for the rest of the
> session.

```ts
// src/shared/hooks/useSearchParamState.ts
import { useCallback, useMemo } from 'react'
import { useSearchParams } from 'react-router-dom'
import type { z } from 'zod'

type Options<T> = {
  /** Values equal to a default are removed from the URL, keeping it short and canonical. */
  defaults: T
  /** true for continuous updates (viewport, typing); false for user intent (filters). */
  replace?: boolean
}

export function useSearchParamState<S extends z.ZodType<Record<string, unknown>>>(
  schema: S,
  { defaults, replace = false }: Options<z.infer<S>>,
) {
  const [searchParams, setSearchParams] = useSearchParams()

  // The schema must use .catch() defaults ([STA-30]): a hand-edited URL degrades to
  // defaults instead of throwing inside render.
  const value = useMemo(
    () => schema.parse(Object.fromEntries(searchParams)) as z.infer<S>,
    [schema, searchParams],
  )

  const setValue = useCallback(
    (patch: Partial<z.infer<S>>, override?: { replace?: boolean }) => {
      setSearchParams(
        (previous) => {
          const next = new URLSearchParams(previous) // preserve params this hook does not own
          for (const [key, patchValue] of Object.entries(patch)) {
            if (patchValue === undefined || patchValue === defaults[key as keyof z.infer<S>]) next.delete(key)
            else next.set(key, String(patchValue))
          }
          return next
        },
        { replace: override?.replace ?? replace },
      )
    },
    [defaults, replace, setSearchParams],
  )

  return [value, setValue] as const
}
```

---

## 5. Routes and the proxy

**[RTE-16] MUST:** A proxied path prefix must never collide with an SPA route. Every
prefix in `vite.config.ts` `server.proxy` and in the nginx `location` blocks ends with a
slash (`'/map/'`, not `'/map'`), and no SPA route path is a prefix of, or prefixed by, a
proxied path. `check-standards.sh` fails the build when a proxy key without a trailing
slash also matches a route in `src/app/router/router.tsx` ([TOOL-01] states the limits of
that check).
> **Why:** Measured in the reference project: the proxy key `'/map'` also matched the SPA
> route `/map-data`. The rewrite stripped `/map` and forwarded `/-data` to the map server,
> which answered `Cannot GET /-data`, so the page 404'd in dev and worked in prod, or the
> reverse, depending on which config was fixed. The same class of bug hit `'/epanet'`
> swallowing the `/epanet/networks` route, which needed a `bypass()` hack keyed on
> `Accept: text/html` to survive a page refresh. A trailing slash makes `/map/styles/x`
> match and `/map-data` not match, and the hack disappears.

```ts
// vite.config.ts (excerpt): the two forms, and why the slash is not cosmetic
server: {
  proxy: {
    // WRONG: also matches the SPA routes /map-data, /map-dark and /maps.
    // '/map': { target: MAP_TARGET, rewrite: (p) => p.replace(/^\/map/, '') },

    // RIGHT: matches only real map-server paths (/map/styles/…), leaves /map-data to the SPA.
    '/map/': { target: MAP_TARGET, changeOrigin: true, rewrite: (p) => p.replace(/^\/map/, '') },
    '/api/': { target: API_TARGET, changeOrigin: true },
    '/tiles/': { target: TILE_TARGET, changeOrigin: true, rewrite: (p) => p.replace(/^\/tiles/, '') },
  },
}
```

**Additional protection, and the reason it is not sufficient:** reserving a namespace for
all backend prefixes (`/api/`, `/tiles/`, `/map/`, `/mqtt`) and never using those first
segments as route paths is the real fix. The trailing slash prevents the accidental
overlap; the naming convention prevents the deliberate one. Both are required, because a
route added a year later by someone who never read `vite.config.ts` is the common case.
The nginx side of the same rule is [NGX-15].

---

## 6. Leaving a route

**[RTE-17] MUST:** A form with unsaved changes blocks navigation with `useBlocker` and
shows a confirm dialog with three outcomes (stay, discard, and where the form supports it,
save). The blocker is registered only while the form is dirty and is reset on submit.
Cross-ref: [FORM-14].
> **Why:** `window.confirm` in a `beforeunload` handler covers only tab close and reload,
> not in-app navigation, which is where the data is actually lost. `useBlocker` is the data
> router's only hook that sees an in-app navigation before it commits.

```tsx
// src/shared/hooks/useUnsavedChangesBlocker.ts
import { useEffect } from 'react'
import { useBlocker } from 'react-router-dom'

export function useUnsavedChangesBlocker(isDirty: boolean) {
  const blocker = useBlocker(
    ({ currentLocation, nextLocation }) =>
      isDirty && currentLocation.pathname !== nextLocation.pathname,
  )

  // Tab close and reload are a separate mechanism; the browser shows its own dialog.
  useEffect(() => {
    if (!isDirty) return
    const onBeforeUnload = (event: BeforeUnloadEvent) => event.preventDefault()
    window.addEventListener('beforeunload', onBeforeUnload)
    return () => window.removeEventListener('beforeunload', onBeforeUnload)
  }, [isDirty]) // cleanup is mandatory ([GEN-21])

  return blocker // blocker.state === 'blocked' → render the dialog; proceed()/reset()
}
```

**[RTE-18] MUST:** `<ScrollRestoration>` is rendered once in `RootLayout` with an explicit
`getKey`. List and detail routes restore by `location.key` (default). Routes that own a
viewport (map pages, full-height dashboards) opt out by returning a constant key, and the
map viewport is restored from the URL instead ([STA-31]).
> **Why:** Default restoration on a map page scrolls a container that has no scroll, or
> resets a virtualised list to a pixel offset that no longer matches the data. Returning a
> constant key for those routes makes restoration a no-op instead of a wrong guess.

```tsx
<ScrollRestoration
  getKey={(location) =>
    // Map routes share one key, so no scroll offset is stored or restored for them.
    location.pathname.includes('/map') ? 'map' : location.key
  }
/>
```

**[RTE-19] MUST:** Every route sets a document title of the form
`<page> · <app name>` through React 19's hoisted `<title>` rendered by the page component,
with the text coming from i18n ([GEN-14]). The title is not set in a `useEffect` and not
via `react-helmet` ([VER-05]). Cross-ref: [SEO-04].
> **Why:** Screen readers announce the title on navigation, and it is the only label a user
> with 20 tabs has. Setting it in an effect means the tab shows the previous page's title
> until after paint, which is exactly the moment the announcement happens.

---

## 7. Splitting, prefetching and links

**[RTE-20] MUST:** Route-level splitting follows the budgets in [07](07-PERFORMANCE.md) §1:
the initial entry chunks stay under the `initial` budget and each route chunk under the
`chunk` budget in `budget.json`, verified by `npm run size:check` ([PERF-03], [CI-06]). A
page that exceeds the route budget splits further (lazy panels, lazy export libraries,
[PERF-05]), it does not get a budget increase by default.
> **Why:** Route splitting only helps if the route chunk is actually small. A 600 KB
> "reports" chunk is a 3 s wait on the navigation that a spinner cannot hide.

**[RTE-21] SHOULD:** A navigation target is prefetched on intent (pointer enter or focus on
the link, after 100 ms) by warming both halves: the route chunk and its query data.
> **Why:** 60 % of clicks follow a hover longer than 200 ms. Warming both removes the chunk
> download and the request from the critical path, which is 150 to 500 ms on 4G.

```tsx
// React Router 7's <Link prefetch="intent"> is a FRAMEWORK-mode feature. Verify whether the
// pinned data-mode build exports it before using it; the standard assumes it does not and
// prefetches explicitly, which works in both modes.
import { Link } from 'react-router-dom'

import { queryClient } from '@/app/providers/queryClient'

import { parkingDetailOptions } from '../api/parkingQueries'
import type { ParkingId } from '../types/ids'

export function ParkingLink({ id, children }: { id: ParkingId; children: React.ReactNode }) {
  const warm = () => {
    void import('../pages/ParkingDetailPage') // same module specifier as the route's lazy()
    void queryClient.prefetchQuery(parkingDetailOptions(id)) // [STA-18]
  }
  return (
    <Link to={`/parkings/${id}`} onPointerEnter={warm} onFocus={warm}>
      {children}
    </Link>
  )
}
```

**[RTE-22] MUST:** In-app navigation uses `<Link>`/`<NavLink>`, never `<a href>` and never
`window.location.assign`. Active styling uses `NavLink`'s render-prop `isActive` plus
`aria-current="page"`; `end` is set on any link whose path is a prefix of its siblings
(`/parkings` next to `/parkings/map`).
> **Why:** An `<a href>` to an internal path reloads the whole app: a full bundle parse,
> a lost Query cache and a destroyed map instance, for what should be a 30 ms transition.
> Without `end`, the parent link stays highlighted on every child route, so the sidebar
> shows two active items.

```tsx
<NavLink
  to="/parkings"
  end
  className={({ isActive }) => clsx('rounded px-3 py-2', isActive && 'bg-slate-100 font-medium')}
>
  {({ isActive }) => <span aria-current={isActive ? 'page' : undefined}>{t('nav.parkings')}</span>}
</NavLink>
```

**[RTE-23] MUST:** External links use `<a>` with `target="_blank"` **and**
`rel="noopener noreferrer"`, and the URL's scheme is checked against an allow-list
(`https:`, `mailto:`, `tel:`) when it comes from data rather than from a literal.
Cross-ref: [SEC-06].
> **Why:** Without `noopener` the opened page gets `window.opener` and can navigate this
> tab to a phishing page (reverse tabnabbing). A `javascript:` URL from an API field
> rendered into `href` is a stored XSS with no `dangerouslySetInnerHTML` in sight.

---

## 8. Guards and permissions

**[RTE-24] MUST:** Session and permission checks are layout routes, not per-page code:
`RequireAuth` gates authentication, `RequirePermission` gates a specific permission key
(`<module>.<action>`, defined by the backend standard). Neither is called inside a page
component. Cross-ref: [AUTH-10], [AUTH-11].
> **Why:** A guard inside a page runs after the page's own effects, so the page fires its
> queries (and its 403s) before the redirect happens. A guard called in 120 pages is
> forgotten in the 121st, which is the one with the payroll data.

**[RTE-25] MUST:** A redirect to login carries `?returnTo=<path>` built from
`location.pathname + location.search`, and the login page validates it as **relative-only**
(starts with a single `/`, does not start with `//`, contains no scheme) before navigating
there; an invalid value falls back to `/`.
> **Why:** `returnTo=https://evil.example/login` turns your login page into an open
> redirector: the phishing link starts on your real domain, which is what the user checks.
> `//evil.example` is protocol-relative and passes a naive `startsWith('/')` check, which is
> why the double slash is tested explicitly.

```tsx
// src/app/router/RequireAuth.tsx
import { Navigate, Outlet, useLocation } from 'react-router-dom'

import { useSession } from '@/features/Auth'
import { FullPageSpinner } from '@/shared/components'

export function RequireAuth() {
  const { status } = useSession() // 'loading' | 'authenticated' | 'anonymous' ([AUTH-06])
  const location = useLocation()

  // A redirect before the session is known logs out every user on every hard refresh.
  if (status === 'loading') return <FullPageSpinner label="auth.checkingSession" />

  if (status === 'anonymous') {
    const returnTo = `${location.pathname}${location.search}`
    return <Navigate to={`/login?returnTo=${encodeURIComponent(returnTo)}`} replace />
  }

  return <Outlet />
}
```

```ts
// src/features/Auth/lib/safeReturnTo.ts
/** Only same-origin, path-relative targets. Anything else falls back to the app root. */
export function safeReturnTo(raw: string | null): string {
  if (!raw) return '/'
  // "//evil.example" is protocol-relative; "/\evil" is treated as "//" by some browsers.
  if (!raw.startsWith('/') || raw.startsWith('//') || raw.startsWith('/\\')) return '/'
  if (/^[a-z][a-z0-9+.-]*:/i.test(raw)) return '/' // any scheme, including javascript:
  return raw
}
```

```tsx
// src/app/router/RequirePermission.tsx, used as a layout route around a subtree
export function RequirePermission({ permission }: { permission: string }) {
  const { has } = usePermissions() // [AUTH-11]
  if (!has(permission)) return <ForbiddenPage permission={permission} />
  return <Outlet />
}
// In routes.tsx: { element: <RequirePermission permission="parking.manage" />, children: [...] }
```

---

## 9. Navigation instrumentation

**[RTE-26] MUST:** Route changes are observed in exactly one place, a
`useRouteInstrumentation()` hook mounted in `RootLayout`, which records the error-tracker
breadcrumb ([OBS-13]) and the analytics page view. The **route pattern** is reported
(`/parkings/:id`), never the concrete path, and never the query string. Breadcrumb labels
come from the route's `handle.crumb`.
> **Why:** Reporting concrete paths produces 40,000 distinct "pages" for one route, so no
> aggregate is meaningful, and it ships resource ids (and anything a user typed into a
> filter) to the tracker, which [OBS-17] forbids.

```tsx
// src/app/router/useRouteInstrumentation.ts
import { useEffect } from 'react'
import { useLocation, useMatches } from 'react-router-dom'

export function useRouteInstrumentation() {
  const location = useLocation()
  const matches = useMatches()
  // The deepest match's route id doubles as the stable pattern name.
  const pattern = matches.at(-1)?.id ?? 'unknown'

  useEffect(() => {
    addBreadcrumb({ category: 'route', message: pattern, level: 'info' }) // [OBS-13]
    trackPageView(pattern) // never location.pathname + location.search ([OBS-17])
  }, [pattern, location.key])
}
```

---

## 10. Testing routes

**[RTE-27] MUST:** Routing behaviour (guards, redirects, `lazy`, the catch-all, param
validation) is tested with `createMemoryRouter` over the real exported `RouteObject[]`,
asserting on `router.state.location`. A page component rendered directly inside
`<MemoryRouter>` does not test routing. Cross-ref: [TEST-20].

```tsx
it('redirects a legacy path and keeps history clean', async () => {
  const router = createMemoryRouter(routes, { initialEntries: ['/otoparklar'] })
  render(<RouterProvider router={router} />)

  await waitFor(() => expect(router.state.location.pathname).toBe('/parkings'))
  expect(router.state.historyAction).toBe('REPLACE') // back must not bounce ([RTE-13])
})

it('renders the not-found page for an unknown path', async () => {
  const router = createMemoryRouter(routes, { initialEntries: ['/no-such-page'] })
  render(<RouterProvider router={router} />)

  expect(await screen.findByRole('heading', { name: /bulunamadı/i })).toBeInTheDocument()
})
```

---

## Open questions

- **`lazy` object form.** RR7 minors after 7.5 accept per-property lazy
  (`lazy: { Component, loader }`), which lets the loader load without the component. The
  standard keeps the function form until the exact minor is confirmed against the pinned
  version. Decided by reading the installed package's types.
- **`<Link prefetch>` in data mode.** If a 7.x data-mode build exports `prefetch` on
  `Link`, [RTE-21]'s manual warm-up is replaced by it and the rule becomes a MUST. Decided
  by a one-line check against the pinned version.
- **View Transitions.** `useViewTransitionState` and `<Link viewTransition>` exist in RR7,
  but Firefox support for the API is recent. Revisit when the browser matrix in [VER-12]
  covers it in all four engines; until then no route uses it.
- **A route manifest for nginx.** [RTE-14]'s indexed-prefix 404 currently duplicates route
  knowledge in the nginx config. A build step emitting the route pattern list for nginx to
  consume would remove the duplication; not written, because only SEO products need it.
