# 05 — State and Data

> Four kinds of state, four homes ([GEN-05]): server data in TanStack Query, URL-addressable
> state in the URL, cross-feature client state in Redux Toolkit, everything else local. This
> file decides which home a value gets, how queries are keyed, cached, invalidated and
> cancelled, what Redux is still for, and how URL and local state are written. Read it before
> adding any `useState` that holds something from the backend, any slice, or any `?param`.
> The HTTP call itself is [04](04-API-CLIENT.md); routing mechanics are [22](22-ROUTING.md).

---

## 1. Which home?

```
Does the value come from the backend, or is it derived from something that does?
├─ yes → TanStack Query. Realtime pushes patch the cache; above 1 Hz they go to Redux ([STA-22]).
└─ no
   Should a page reload or a pasted link restore it?
   ├─ yes → URL search params. Filters, selected entity, map viewport, active tab.
   └─ no
      Is it read by two or more features, or does it outlive the component that writes it?
      ├─ yes → Redux Toolkit slice, owned by one feature.
      └─ no
         Does changing it change what is rendered?
         ├─ yes → useState / useReducer in the component or its hook.
         └─ no  → useRef. Timers, map handles, the previous value of something.
```

| Value | Home | Why not elsewhere |
|---|---|---|
| Parking list, detail, districts, style JSON | TanStack Query | Redux would be a second cache with no staleness policy |
| List filters, page, sort | URL | A shared link must open the same table |
| Selected parking (single, opens detail panel) | URL `?selected=` | Map and sidebar both read it; reload must keep it |
| Map viewport | URL `?lng=&lat=&z=` (replace, throttled) | Reload lands on the same place; back button is not spammed |
| Hovered feature id | Local state in the layer hook | Nobody else needs it; it changes 60 times a second |
| Multi-selection for a bulk action | Redux | Transient, read by map, table and toolbar; must not be in the URL |
| Live vehicle positions (MQTT, 1 to 10 Hz) | Redux, batched | Query cache observers cannot absorb 10 writes a second |
| Sidebar collapsed, table density | Local state + persisted pref ([STA-37]) | Per device, not per link |
| Form draft | react-hook-form ([18](18-FORMS-VALIDATION.md)) | Form libraries own field state |
| Session identity, permissions | Auth context + query ([19](19-AUTH-SESSION.md)) | Changes rarely; needed everywhere |
| Map instance, runtime config | Context ([STA-39]) | Dependency injection, not state |

**[STA-01] MUST:** Server data is held only in the TanStack Query cache; a `useState` or a
Redux slice that receives the result of an API call is forbidden.
> **Why:** The reference codebase has 121 feature files doing `useEffect` + fetch into
> `useState`. Each one re-implements loading flags, cancellation, refresh and error handling,
> and none of them share a cache, so opening the map and the list fetches the same 4 MB twice.

**[STA-02] MUST:** State that a user would expect to survive a reload or to share by link
lives in the URL, parsed with a zod schema ([STA-33]).
> **Why:** "Send me the link" is the most common support request in a municipal dashboard. A
> filter held in React state produces a link that opens an empty page.

**[STA-03] MUST:** Redux holds only cross-feature client state: values written by one feature
and read by another that are neither server data nor URL state.
> **Why:** Everything else has a cheaper home. A Redux slice per feature "for consistency" is
> global mutable state with extra ceremony. Detail: [ADR-0005](adr/0005-client-state.md).

**[STA-04] MUST:** Anything not covered by [STA-01] to [STA-03] is local `useState`,
`useReducer` or `useRef`, as close to its consumer as possible.
> **Why:** Local state is deleted with its component. Lifted state is forgotten.

---

## 2. TanStack Query

### 2.1 Factories and keys

```ts
// src/features/Parking/api/parkingQueries.ts
import { keepPreviousData, queryOptions } from '@tanstack/react-query'

import { STALE_TIME } from '@/shared/api/queryDefaults'
import type { ParkingId } from '@/shared/types/ids'

import { getParking, getParkingList } from './parkingApi'
import type { ParkingListFilters } from './parkingSchemas'

export const parkingKeys = {
  all: ['parking'] as const,
  lists: () => [...parkingKeys.all, 'list'] as const,
  list: (filters: ParkingListFilters) => [...parkingKeys.lists(), filters] as const,
  details: () => [...parkingKeys.all, 'detail'] as const,
  detail: (id: ParkingId) => [...parkingKeys.details(), id] as const,
}

export const parkingListOptions = (filters: ParkingListFilters) =>
  queryOptions({
    queryKey: parkingKeys.list(filters),
    queryFn: ({ signal }) => getParkingList(filters, signal),
    placeholderData: keepPreviousData,
  })

export const parkingDetailOptions = (id: ParkingId) =>
  queryOptions({
    queryKey: parkingKeys.detail(id),
    queryFn: ({ signal }) => getParking(id, signal).then((r) => r.data),
  })

// Reference data: the district list changes a few times a year.
export const districtListOptions = () =>
  queryOptions({
    queryKey: ['district', 'list'] as const,
    queryFn: ({ signal }) => getDistricts(signal),
    staleTime: STALE_TIME.reference,
  })
```

**[STA-05] MUST:** Every query is defined once with `queryOptions()` in
`src/features/<Name>/api/<name>Queries.ts` and consumed via `useQuery(parkingListOptions(f))`,
`useSuspenseQuery(...)`, `queryClient.prefetchQuery(...)` or a route loader; inline
`useQuery({ queryKey, queryFn })` in a component is forbidden.
> **Why:** `queryOptions` gives one typed definition that prefetch, `getQueryData`,
> `setQueryData` and `invalidateQueries` all share. Inline keys get typed three different ways
> in three files and the invalidation misses one of them.

**[STA-06] MUST:** Keys come from a `<name>Keys` factory with the levels `all`, `lists()`,
`list(filters)`, `details()`, `detail(id)`; the filters object is the last key element, and
keys are never assembled by hand in components.
> **Why:** `invalidateQueries({ queryKey: parkingKeys.lists() })` matches every list regardless
> of filters because keys match by prefix. TanStack hashes objects with sorted keys, so
> `{ q, page }` and `{ page, q }` are the same entry.

### 2.2 Defaults

```ts
// src/shared/api/queryDefaults.ts
export const STALE_TIME = {
  default: 30_000,          // lists and details: a 30 s old table is fine, a duplicate request is not
  reference: 60 * 60_000,   // districts, categories, map style, enum lists
  live: 5_000,              // polled sensor values when no realtime channel exists
} as const
export const GC_TIME_DEFAULT = 5 * 60_000
export const GC_TIME_LARGE_GEO = 60_000   // a 2 MB FeatureCollection should not sit in memory for 5 min after the page closes
```

```ts
// src/app/providers/queryClient.ts
import { MutationCache, QueryCache, QueryClient } from '@tanstack/react-query'
import toast from 'react-hot-toast'

import { apiErrorMessage } from '@/shared/api/errorMessages'
import { isApiError } from '@/shared/api/errors'
import { GC_TIME_DEFAULT, STALE_TIME } from '@/shared/api/queryDefaults'
import { reportError } from '@/shared/lib/errorTracking'

// Transport-level retries (fast, same request id) live in client.ts ([API-09]). This one
// query-level retry covers a proxy that came back after that window closed. Worst case for
// an outage: 3 + 3 requests over about 3 s, then the error state. Never on 4xx, never on timeout.
function shouldRetryQuery(failureCount: number, error: unknown): boolean {
  if (failureCount >= 1 || !isApiError(error)) return false
  return error.kind === 'network' || error.status >= 500
}

export function createAppQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: STALE_TIME.default,
        gcTime: GC_TIME_DEFAULT,
        retry: shouldRetryQuery,
        retryDelay: 1_000,
        refetchOnWindowFocus: false,
        refetchOnReconnect: true,
      },
      mutations: { retry: 0 },
    },
    queryCache: new QueryCache({
      onError: (error, query) => {
        // Background refetch failed while stale data is on screen: toast. First load failed:
        // the component renders its error state ([GEN-15]); a toast on top would be noise.
        if (query.state.data !== undefined) toast.error(apiErrorMessage(error))
        reportError(error, { queryKey: query.queryKey })
      },
    }),
    mutationCache: new MutationCache({
      onError: (error, _variables, _context, mutation) => {
        // Forms own 409/422 ([API-31]); everything else toasts here so no mutation fails silently.
        if (isApiError(error) && error.isValidation && mutation.options.meta?.['handlesValidation'] === true) return
        toast.error(apiErrorMessage(error))
        reportError(error)
      },
    }),
  })
}
```

```tsx
// src/app/providers/AppProviders.tsx (excerpt)
const [queryClient] = useState(createAppQueryClient)   // one client per app instance, survives re-renders and StrictMode
```

**[STA-07] MUST:** Default `staleTime` is 30 seconds; `staleTime: 0` is never set globally.
> **Why:** TanStack's own default of 0 makes every mount a refetch. A sidebar and a map
> mounting the same list in the same second fire two identical requests. 30 s dedupes them and
> still shows a fresh table on navigation.

**[STA-08] MUST:** Per-domain `staleTime` uses the `STALE_TIME` constants: `reference` (1 h)
for lists that change a few times a year, `live` (5 s) for polled telemetry without a
realtime channel, and realtime-driven queries set `staleTime: Infinity` and are patched by the
channel ([STA-22]).
> **Why:** Polling a district list every 30 s is waste; polling a sensor every 30 s is a stale
> gauge. Infinity plus a push channel is the only correct setting for data that arrives by
> push: a refetch would race the push.

**[STA-09] MUST:** `gcTime` stays at the 5 minute default except for large geodata queries
(over 1 MB parsed), which use `GC_TIME_LARGE_GEO` (1 minute).
> **Why:** Five unmounted map layers at 2 MB each is 10 MB of FeatureCollections held for five
> minutes on a tablet that has 1 GB free. One minute still covers a back-and-forth navigation.

**[STA-10] MUST:** Queries retry at most once, only for network errors and 5xx, with a 1 s
delay; mutations never retry.
> **Why:** A 403 retried is a 403 twice, one second later. A `POST` retried creates the record
> twice ([API-09]).

**[STA-11] MUST:** `refetchOnWindowFocus` is `false` globally; a query that genuinely needs it
(an approval queue) enables it individually with a comment.
> **Why:** Map users alt-tab constantly between the map and a ticketing tool. Each return
> would refetch every mounted query, and each refetch that changes a byte re-uploads the map
> source and flashes the layer ([STA-19]). Wall-mounted dashboards never lose focus, so the
> setting buys nothing there either.

### 2.3 Mutations and invalidation

```ts
// src/features/Parking/api/parkingQueries.ts (continued)
import { useMutation, useQueryClient } from '@tanstack/react-query'

import { createParking, deleteParking, updateParking } from './parkingApi'
import type { Parking, ParkingCreate } from './parkingSchemas'

export function useCreateParking() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (body: ParkingCreate) => createParking(body).then((r) => r.data),
    meta: { handlesValidation: true },
    onSuccess: (created) => {
      queryClient.setQueryData(parkingDetailOptions(created.id).queryKey, created)
      // Returning the promise keeps `isPending` true until the lists are fresh, so the
      // dialog closes onto an updated table rather than a stale one.
      return queryClient.invalidateQueries({ queryKey: parkingKeys.lists() })
    },
  })
}

export function useDeleteParking() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: (id: ParkingId) => deleteParking(id),
    onSuccess: (_void, id) => {
      queryClient.removeQueries({ queryKey: parkingKeys.detail(id) })
      return queryClient.invalidateQueries({ queryKey: parkingKeys.lists() })
    },
  })
}
```

```ts
// Optimistic update with rollback. Used only for toggles the user expects to be instant.
export function useSetParkingClosed() {
  const queryClient = useQueryClient()
  return useMutation({
    mutationFn: ({ id, closedAt }: { id: ParkingId; closedAt: string | null }) =>
      updateParking(id, { closedAt }).then((r) => r.data),
    onMutate: async ({ id, closedAt }) => {
      const key = parkingDetailOptions(id).queryKey
      // An in-flight refetch landing after our optimistic write would overwrite it.
      await queryClient.cancelQueries({ queryKey: key })
      const previous = queryClient.getQueryData(key)
      queryClient.setQueryData(key, (old: Parking | undefined) => (old ? { ...old, closedAt } : old))
      return { previous }
    },
    onError: (_error, { id }, context) => {
      if (context?.previous) queryClient.setQueryData(parkingDetailOptions(id).queryKey, context.previous)
    },
    onSettled: (_data, _error, { id }) =>
      Promise.all([
        queryClient.invalidateQueries({ queryKey: parkingKeys.detail(id) }),
        queryClient.invalidateQueries({ queryKey: parkingKeys.lists() }),
      ]),
  })
}
```

**[STA-12] MUST:** After a successful mutation the owning feature invalidates `lists()` and
the affected `detail(id)` (or removes it after a delete); `queryClient.clear()`,
`invalidateQueries()` with no key, and `resetQueries` on `all` are forbidden outside logout.
> **Why:** `clear()` after saving one parking refetches the map style, the district list and
> every open layer. The reference codebase's "reload key" pattern is the same mistake at
> feature scale.

**[STA-13] MUST:** Optimistic updates follow the `onMutate` (cancel, snapshot, write)
`onError` (restore snapshot) `onSettled` (invalidate) sequence above, are used only for
single-field toggles and reorderings, and never for creates.
> **Why:** An optimistic create needs a fake id that the list, the map and the detail route
> all handle; when the server rejects it, three places must forget it. A toggle has one field
> and one rollback.

**[STA-14] MUST:** Mutation hooks are named `use<Verb><Name>` and live in the same
`<name>Queries.ts` as the queries they invalidate; a mutation is never dispatched from a
Redux thunk or called from an effect.
> **Why:** The invalidation logic sits next to the keys it must know about. An effect that
> fires a mutation runs twice under StrictMode ([GEN-21]) and posts twice.

### 2.4 Reading

**[STA-15] MUST:** `useSuspenseQuery` is used only inside a component tree that has both a
`<Suspense>` fallback and an error boundary closer than the route boundary; page-level
`useQuery` with explicit `isPending`/`isError` branches is the default.
> **Why:** A suspended query with no nearby boundary unmounts the whole route to show a
> spinner, including the map, which then re-initialises ([MAP-02]). Errors thrown to the
> route boundary lose the sidebar too.

**[STA-16] MUST:** `queryFn` forwards its `signal` to the API function ([API-34]).
> **Why:** Unmount and key change abort the request at the socket instead of leaving it to
> complete and parse for nobody.

**[STA-17] MUST:** Derived shapes (a FeatureCollection built from a list, a `Map` by id,
totals) are produced with `select`, and the `select` function is defined at module level.
> **Why:** `select` runs only when the data reference changes and its result is structurally
> shared, so consumers re-render only on real change. The same transformation in the
> component body runs on every render and produces a new reference every time ([STA-19]).

```ts
// module level: stable identity, memoised by TanStack per query
const toFeatureCollection = (page: ParkingListResponse): FeatureCollection<Point, Parking> => ({
  type: 'FeatureCollection',
  features: page.data.map((p) => ({ type: 'Feature', id: p.id, geometry: { type: 'Point', coordinates: p.location }, properties: p })),
})

export const parkingFeaturesOptions = (filters: ParkingListFilters) =>
  queryOptions({ ...parkingListOptions(filters), select: toFeatureCollection })
```

**[STA-18] MUST:** Paginated lists use `placeholderData: keepPreviousData`; detail routes
reachable from a list are prefetched on row hover or focus with
`queryClient.prefetchQuery(parkingDetailOptions(id))`, and route-level data uses the loader
pattern in [RTE-08].
> **Why:** Without `keepPreviousData` every page change collapses the table to a spinner and
> shifts layout ([A11Y-18]). A hover prefetch makes the detail open in 0 ms for the 60% of
> clicks that follow a hover by more than 200 ms.

**[STA-19] MUST:** Data handed to `source.setData()` is the query's `data` reference (or a
`select` result), and the effect that calls `setData` depends on that reference; a
FeatureCollection is never built inline in render or in the effect body.
> **Why:** `setData` serialises the GeoJSON, posts it to the worker, and re-tiles it: 50 to
> 200 ms for 5,000 polygons, measured on a 2023 laptop. TanStack's structural sharing keeps the
> old reference when a refetch returns equal JSON, so a 30 s poll with unchanged data costs
> nothing. An inline `{ type: 'FeatureCollection', features: data.map(...) }` is a new
> reference on every render, so every hover re-uploads the source. Verify: DevTools
> Performance, filter `setData`; count must equal the number of real data changes.

**[STA-20] MUST:** Dependent queries use `enabled: id !== null` (or `skipToken` as the
`queryFn` under `queryOptions`) and never a conditional hook call; the component handles the
`isPending && !isFetching` (disabled) state explicitly.
> **Why:** A query disabled by `enabled: false` reports `isPending: true` forever, which
> renders a spinner for a selection the user has not made yet.

**[STA-21] MUST:** The `QueryClient` is created once in `AppProviders` with
`createAppQueryClient()`, held in `useState`, and its `QueryCache`/`MutationCache` `onError`
handlers are the single global place that toasts and reports API errors.
> **Why:** A client created at module level is shared across tests and across StrictMode
> remounts with stale handlers. Per-component error toasts produce three toasts for one outage.

### 2.5 Realtime and the cache

**[STA-22] MUST:** Realtime events below 1 Hz per entity (an alert resolved, a record edited
by another user) patch the cache with `setQueryData` on the affected key or invalidate it;
streams at or above 1 Hz (vehicle positions, sensor ticks) go to a Redux slice via a batched
dispatch ([RT-06]) and never through the query cache.
> **Why:** Every `setQueryData` notifies every observer of that key and runs structural
> sharing over the data. At 10 Hz for 200 vehicles that is 2,000 notifications a second. A
> batched Redux write is one notification per 250 ms.

---

## 3. Redux Toolkit

```ts
// src/store/store.ts
import { configureStore } from '@reduxjs/toolkit'

import { bulkSelectionReducer } from '@/features/BulkEdit'
import { vehiclePositionsReducer } from '@/features/Vehicle'

export const store = configureStore({
  reducer: {
    bulkSelection: bulkSelectionReducer,
    vehiclePositions: vehiclePositionsReducer,
  },
  // The serializable and immutable checks run in development only; RTK strips them from
  // production builds. Disabling them buys no production speed and hides real bugs.
})

export type RootState = ReturnType<typeof store.getState>
export type AppDispatch = typeof store.dispatch
export type AppStore = typeof store
```

```ts
// src/store/hooks.ts
import { useDispatch, useSelector, useStore } from 'react-redux'

import type { AppDispatch, AppStore, RootState } from './store'

export const useAppDispatch = useDispatch.withTypes<AppDispatch>()
export const useAppSelector = useSelector.withTypes<RootState>()
export const useAppStore = useStore.withTypes<AppStore>()
```

```ts
// src/features/Vehicle/store/vehiclePositionsSlice.ts
import { createSelector, createSlice, type PayloadAction } from '@reduxjs/toolkit'

import type { VehicleId } from '@/shared/types/ids'

// `ts` is epoch milliseconds: a Date would fail the serializable check, and rightly so.
export interface VehiclePosition { lng: number; lat: number; headingDeg: number; speedKmh: number; ts: number }
interface VehiclePositionsState { byId: Record<VehicleId, VehiclePosition> }

const initialState: VehiclePositionsState = { byId: {} }

export const vehiclePositionsSlice = createSlice({
  name: 'vehiclePositions',
  initialState,
  reducers: {
    positionsReceived(state, action: PayloadAction<ReadonlyArray<{ id: VehicleId } & VehiclePosition>>) {
      for (const p of action.payload) state.byId[p.id] = p
    },
    vehicleDropped(state, action: PayloadAction<VehicleId>) {
      delete state.byId[action.payload]
    },
  },
  selectors: {
    selectPositionById: (state, id: VehicleId) => state.byId[id],
    selectPositionsById: (state) => state.byId,
  },
})

export const { positionsReceived, vehicleDropped } = vehiclePositionsSlice.actions
export const { selectPositionById, selectPositionsById } = vehiclePositionsSlice.selectors
export const vehiclePositionsReducer = vehiclePositionsSlice.reducer

// Derived, memoised: recomputed only when byId changes, not on every dispatch.
export const selectMovingVehicleIds = createSelector([selectPositionsById], (byId) =>
  (Object.keys(byId) as VehicleId[]).filter((id) => (byId[id]?.speedKmh ?? 0) > 1),
)
```

(The `as VehicleId[]` above is the one place a brand is reasserted: `Object.keys` returns
`string[]` by design. It is allowed only in a selector over a `Record<BrandedId, ...>` and
carries a comment in the real file. See [TS-06].)

**[STA-23] MUST:** A slice lives in `src/features/<Name>/store/<name>Slice.ts`, is exported
through the feature's `index.ts` as `<name>Reducer` plus its actions and selectors, and is
registered in `src/store/store.ts`; `src/store/` contains no reducers of its own.
> **Why:** The feature that owns the data owns its shape. A `src/store/slices/` folder is
> where every feature's state gets tangled into one file nobody can lazy-load.

**[STA-24] MUST:** Components use `useAppSelector`/`useAppDispatch` from `src/store/hooks.ts`;
the untyped `useSelector`/`useDispatch` are lint-restricted.
> **Why:** `useSelector((s) => s.vehiclePositions)` with an untyped `s` is `any` in disguise.

**[STA-25] MUST:** Derived values (filtered lists, counts, lookups) are `createSelector`
selectors in the slice file; a selector returning a new array or object without `createSelector`
is forbidden.
> **Why:** `useAppSelector((s) => Object.values(s.byId))` returns a new array every dispatch,
> so the component re-renders 10 times a second even when nothing it shows changed.

**[STA-26] MUST:** The serializable and immutable middleware checks stay enabled; state holds
only JSON values (strings, numbers, booleans, null, plain objects, arrays). `Date`, `Map`,
`Set`, class instances, functions, DOM nodes and the map instance are never stored.
> **Why:** The reference codebase sets `serializableCheck: false` "for speed and to avoid
> warnings". Both reasons are wrong: the check runs in development only, so production speed is
> unchanged, and the warning it silenced was a real `Date` in state that broke a time-travel
> replay and every `JSON.stringify` diff. If one high-frequency action path is measurably slow
> in development, narrow the check with `ignoredActions: [positionsReceived.type]` and a
> comment with the measurement; never disable it globally.

**[STA-27] MUST NOT:** Copy server data into a slice; store ids, and read the entity from the
query cache.
> **Why:** [GEN-05]. A `selectedParking: Parking` in Redux is stale the moment the detail
> query refetches. `selectedParkingId` plus `useQuery(parkingDetailOptions(id))` is always
> current and needs no sync code.

**[STA-28] MUST NOT:** Use `createAsyncThunk` or any thunk to perform HTTP; a request that
changes data is a TanStack mutation ([STA-14]), a request that reads data is a query.
> **Why:** A thunk that fetches is a second server-state layer with its own loading flags and
> no cache. `redux-thunk` stays only because RTK bundles it; it is used for pure synchronous
> multi-dispatch orchestration at most.

**[STA-29] MUST:** Every slice has a unit test for each reducer and for each `createSelector`
selector's memoisation (same input reference returns same output reference).
> **Why:** A selector that silently lost memoisation is a performance regression nobody sees
> until the map stutters.

---

## 4. URL state

```ts
// src/features/Parking/hooks/useParkingFilters.ts
import { useSearchParams } from 'react-router-dom'
import { z } from 'zod'

// .catch() defaults: a hand-edited or stale URL degrades to defaults instead of throwing.
const FiltersSchema = z.object({
  q: z.string().trim().max(100).catch(''),
  district: z.string().catch(''),
  page: z.coerce.number().int().min(1).catch(1),
})
export type ParkingFilters = z.infer<typeof FiltersSchema>

const DEFAULTS: ParkingFilters = { q: '', district: '', page: 1 }

export function useParkingFilters() {
  const [searchParams, setSearchParams] = useSearchParams()
  const filters = FiltersSchema.parse(Object.fromEntries(searchParams))

  function setFilters(patch: Partial<ParkingFilters>, options: { replace?: boolean } = {}) {
    setSearchParams(
      (prev) => {
        const next = new URLSearchParams(prev)
        // Any filter change resets to page 1; only an explicit page change keeps the rest.
        const resetPage = Object.keys(patch).some((k) => k !== 'page')
        const merged = { ...filters, ...patch, page: resetPage ? 1 : (patch.page ?? filters.page) }
        for (const key of Object.keys(DEFAULTS) as (keyof ParkingFilters)[]) {
          const value = merged[key]
          if (value === DEFAULTS[key]) next.delete(key)
          else next.set(key, String(value))
        }
        return next
      },
      { replace: options.replace ?? false },
    )
  }

  return { filters, setFilters }
}
```

```ts
// src/shared/map/useViewportUrl.ts (excerpt): ?lng=&lat=&z=, replace-only, throttled
const ViewportSchema = z.object({
  lng: z.coerce.number().min(-180).max(180),
  lat: z.coerce.number().min(-90).max(90),
  z: z.coerce.number().min(0).max(24),
})
// 5 decimals is about 1 m at the equator; more only makes URLs longer.
const round = (n: number, d: number) => Number(n.toFixed(d))
// map.on('moveend') → setSearchParams({ lng: round(c.lng, 5), lat: round(c.lat, 5), z: round(zoom, 2) }, { replace: true })
```

**[STA-30] MUST:** URL state is read and written only through a feature hook built on
`useSearchParams` with a zod schema using `.catch()` defaults; components never call
`searchParams.get()` directly.
> **Why:** `Number(searchParams.get('page'))` is `NaN` for `?page=abc` and `0` for a missing
> value; both reach the API. The schema makes every URL a valid state.

**[STA-31] MUST:** Default values are removed from the URL, filter changes push a history
entry, map viewport and typeahead text use `replace: true`, and viewport writes are
throttled to at most one per 250 ms after `moveend`.
> **Why:** Pushing on every map pan makes the back button useless (30 entries for one drag).
> Pushing on every keystroke does the same for a search box. A filter change is a navigation
> the user expects to undo with back.

**[STA-32] MUST:** The URL parameter set for each route is documented in the feature README
([STR-06]) and the parser is unit-tested with a malformed URL.
> **Why:** URL parameters are a public API: users bookmark them and other features link to
> them. An undocumented rename breaks bookmarks silently.

**[STA-33] MUST:** A selected entity that opens a panel is `?selected=<id>` parsed with the
branded id schema; the map layer and the sidebar both read it from the hook, and neither
holds a copy.
> **Why:** Two copies of "selected" is the classic map-vs-list desync: the sidebar shows one
> parking and the map highlights another.

---

## 5. Local state

```tsx
// WRONG: state synced from props with an effect. Renders once stale, then again.
function CapacityBar({ occupied, capacity }: Props) {
  const [ratio, setRatio] = useState(0)
  useEffect(() => { setRatio(occupied / capacity) }, [occupied, capacity])
  return <Bar value={ratio} />
}

// RIGHT: derive during render. The React Compiler memoises it if it is expensive.
function CapacityBar({ occupied, capacity }: Props) {
  const ratio = capacity === 0 ? 0 : occupied / capacity
  return <Bar value={ratio} />
}
```

**[STA-34] MUST NOT:** Set state from props or from other state inside `useEffect`; derived
values are computed in render, and a value that must reset when a prop changes is handled
with a `key` on the component or by lifting the state.
> **Why:** The effect version renders the stale value first, then the correct one, and the
> lint rule `react-hooks/set-state-in-effect` ([TS-27]) flags it. The reference codebase's
> `useParkingMapData` is the fetch variant of the same mistake.

**[STA-35] MUST:** `useReducer` is used when three or more `useState` calls change together
in the same handler; `useRef` is used for values that do not affect rendering (timers, the
last emitted viewport, an in-flight flag, a MapLibre handle).
> **Why:** Three `setX` calls that must stay consistent are a state machine; a reducer makes
> the transitions explicit and testable. A ref does not re-render, which is the point.

**[STA-36] MUST:** Local state initialisers that are expensive (parsing, building a lookup)
use the function form `useState(() => build())`.
> **Why:** `useState(build())` runs `build()` on every render and throws the result away.

---

## 6. Persistence

```ts
// src/shared/lib/storage.ts
import type { z } from 'zod'

import { logger } from './logger'

// Version bump when a stored shape changes incompatibly; old keys are simply ignored.
const PREFIX = 'app:v1:'

export function readStored<S extends z.ZodType>(key: string, schema: S): z.output<S> | null {
  try {
    const raw = localStorage.getItem(PREFIX + key)
    if (raw === null) return null
    const parsed = schema.safeParse(JSON.parse(raw))
    return parsed.success ? parsed.data : null
  } catch (e: unknown) {
    // Private mode, disabled storage, corrupt JSON: behave as if nothing was stored, once loudly.
    logger.warn('storage.read_failed', { key, error: String(e) })
    return null
  }
}

export function writeStored(key: string, value: unknown): void {
  try {
    localStorage.setItem(PREFIX + key, JSON.stringify(value))
  } catch (e: unknown) {
    logger.warn('storage.write_failed', { key, error: String(e) })   // quota or private mode; the pref is simply not kept
  }
}
```

**[STA-37] MUST:** Only UI preferences named in `src/shared/lib/storageKeys.ts` (an `as const`
list: sidebar collapsed, table density, last basemap, locale for non-SEO apps) are persisted,
through `readStored`/`writeStored`, with versioned keys and a zod schema on read; direct
`localStorage`/`sessionStorage` access anywhere else is a lint error.
> **Why:** Storage is per-browser, unencrypted, and readable by any injected script. An
> unbounded set of keys becomes a migration problem on the first shape change; the version
> prefix makes old data ignorable instead of crashing.

**[STA-38] MUST NOT:** Persist tokens, session identifiers, permissions, server data or form
drafts containing personal data.
> **Why:** [AUTH-02] puts the session in an HttpOnly cookie precisely so JavaScript cannot
> read it. A persisted permission list lets a demoted user keep their buttons until they clear
> storage. A draft with a citizen's TCKN stays on a shared clerk PC.

---

## 7. Context

**[STA-39] MUST:** React context is used for dependency injection of long-lived objects
(the map instance via `MapContext`, runtime config, the auth identity) and never for values
that change more than a few times per session (selection, filters, positions).
> **Why:** Every consumer of a context re-renders on every value change with no selector to
> narrow it. Selection in context re-renders the whole map tree on every click. The homes in
> §1 all have subscriptions with selectors; context does not.

**[STA-40] MUST:** A context provider exposes a hook `use<Name>()` that throws when used
outside its provider, and the context object itself is not exported.
> **Why:** `useContext(MapContext)` returning `null` fails as `map.addLayer is not a function`
> three components later; the hook fails at the call site with the provider's name.

---

## Open questions

- **Query persistence across reloads.** `@tanstack/query-persist-client` with IndexedDB would
  make the map's reference layers appear instantly after a reload. Not in [02](02-TECH-VERSIONS.md);
  adopt when a measured cold-start LCP on the map page exceeds the [PERF-02] budget because
  of reference data, not before.
- **Realtime store above Redux's ceiling.** At more than 2,000 tracked entities at 10 Hz,
  even batched Redux dispatches cost measurable main-thread time. The alternative is a
  `useSyncExternalStore` ring buffer with per-entity subscriptions in [20](20-REALTIME-MEDIA.md).
  Decided by measurement on the first fleet that size.
