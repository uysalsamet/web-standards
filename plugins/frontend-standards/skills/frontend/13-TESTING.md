# 13 — Testing

> Governs what is tested, at which level, with which tools, and what CI enforces. Core
> principle: tests describe behaviour a user or a caller can observe, they run against a
> mocked network, and they never touch WebGL. Read when writing or reviewing a test, when
> a test is flaky, or when wiring the `test` and `e2e` jobs ([14](14-GIT-CI.md) §4).
> Tooling is fixed by [02](02-TECH-VERSIONS.md) §3: Vitest 5, Testing Library, MSW 2,
> Playwright. See [ADR-0016](adr/0016-testing.md) for why.

---

## 1. The pyramid for this stack

| Level | Tool | What | Share of tests | Runtime budget |
|---|---|---|---|---|
| Unit | Vitest, no DOM | `lib/`, `src/shared/utils/`, zod schemas, MapLibre expressions and layer specs, reducers, selectors, query-key factories, URL param parsers | 70 to 80 % | whole suite < 60 s |
| Component | Vitest + jsdom + RTL + MSW | One component or one page: behaviour through the DOM, network through MSW | 15 to 25 % | included above |
| E2E smoke | Playwright against the built image | Login, main page renders, map reaches `idle`, one critical flow per feature | 5 % (10 to 30 tests) | < 10 min in CI |

**[TEST-01] MUST:** Every module under `src/features/*/lib/`, `src/shared/utils/`, every zod
schema file, every Redux slice (reducer and selectors), every query-key factory and every
function that returns a MapLibre layer spec or expression has a unit test file next to it.
> **Why:** These are the pure, cheap-to-test parts and they carry the domain logic. A bug in
> `computeCapacityColour()` is found in 2 ms by a unit test or in 3 days by a citizen. Naming
> follows [03](03-PROJECT-STRUCTURE.md) §4: `<name>.test.ts` beside the unit.

**[TEST-02] MUST:** Component tests assert behaviour (what the user sees and can do), never
markup (class names, element order, wrapper divs).
> **Why:** A test that checks `.querySelector('.card > div:nth-child(2)')` breaks on every
> Tailwind refactor and passes when the button stops working. Queries go through
> `getByRole`, `getByLabelText`, `getByText`; `container.querySelector` is a review comment.

**[TEST-03] MUST:** The e2e suite is a smoke suite: login, the landing page renders, the map
reaches `idle` ([TEST-29]), and one critical flow per feature (create, view, or the one
action the feature exists for). Feature-complete e2e coverage is not a goal.
> **Why:** E2E tests cost 10 to 60 s each and fail for reasons unrelated to the change under
> test. Thirty focused tests catch a broken deploy; three hundred catch the same and take an
> hour to keep green.

**[TEST-04] MUST NOT:** Visual regression (pixel comparison) is not part of the default
suite. See Open questions for the condition that would add it for the map page.

---

## 2. Vitest configuration

**[TEST-05] MUST:** `vitest.config.ts` at the repo root is the file below, with the
thresholds unchanged. Lower thresholds need a written reason in the PR and a follow-up issue.

```ts
// vitest.config.ts
import { defineConfig, mergeConfig } from 'vitest/config'

import viteConfig from './vite.config'

// vite.config.ts must export an object (or be called if it exports a function) so the
// alias '@/' and the React plugin apply to tests too.
export default mergeConfig(
  viteConfig,
  defineConfig({
    test: {
      environment: 'jsdom',
      globals: false, // explicit imports; no ambient `describe`/`it` in the type space
      setupFiles: ['src/test/setup.ts'],
      css: false, // styling is not under test; parsing Tailwind output per test costs seconds
      include: ['src/**/*.test.{ts,tsx}'],
      exclude: ['e2e/**', 'node_modules/**', 'dist/**'],
      pool: 'threads', // verify against the Vitest 5 changelog; the key existed in 3.x and 4.x
      restoreMocks: true,
      clearMocks: true,
      coverage: {
        provider: 'v8',
        reporter: ['text-summary', 'lcov'],
        include: ['src/**/*.{ts,tsx}'],
        exclude: [
          'src/**/*.test.{ts,tsx}',
          'src/test/**',
          'src/**/*.d.ts',
          'src/main.tsx',
          'src/**/index.ts', // public-API barrels have no logic
          'src/shared/i18n/locales/**',
          'src/**/*.gen.ts', // generated ([STR-29])
        ],
        thresholds: {
          lines: 70,
          branches: 60,
          'src/shared/utils/**': { lines: 90, branches: 90 },
          '**/lib/**': { lines: 90, branches: 90 },
        },
      },
    },
  }),
)
```

**[TEST-06] MUST:** `src/test/setup.ts` registers jest-dom matchers, starts the MSW server
with `onUnhandledRequest: 'error'`, installs the jsdom gaps (`matchMedia`,
`ResizeObserver`, `IntersectionObserver`), mocks `maplibre-gl` globally ([TEST-20]) and
sets a valid `window.__APP_CONFIG__`.
> **Why:** Every one of these, missing, produces a different confusing failure (`matchMedia is
> not a function`, a real request to `/api/parkings`, a WebGL context error). One setup file
> means every test starts from the same known world.

```ts
// src/test/setup.ts
import '@testing-library/jest-dom/vitest'
import { cleanup } from '@testing-library/react'
import { afterAll, afterEach, beforeAll, vi } from 'vitest'

import { server } from '@/test/msw/server'
import { testRuntimeConfig } from '@/test/runtimeConfig'

// The real module needs a WebGL context; jsdom has none. See src/test/mocks/maplibre.ts.
vi.mock('maplibre-gl', () => import('@/test/mocks/maplibre'))

beforeAll(() => server.listen({ onUnhandledRequest: 'error' }))
afterEach(() => {
  server.resetHandlers() // per-test overrides never leak into the next test
  cleanup() // RTL auto-cleanup needs globals:true; we call it ourselves
})
afterAll(() => server.close())

window.__APP_CONFIG__ = testRuntimeConfig

// jsdom does not implement these; components call them at mount.
window.matchMedia ??= (query: string): MediaQueryList => ({
  matches: false, media: query, onchange: null,
  addEventListener: () => undefined, removeEventListener: () => undefined,
  addListener: () => undefined, removeListener: () => undefined,
  dispatchEvent: () => false,
})

class ObserverStub {
  observe(): void {}
  unobserve(): void {}
  disconnect(): void {}
  takeRecords(): never[] { return [] }
}
globalThis.ResizeObserver ??= ObserverStub as unknown as typeof ResizeObserver
globalThis.IntersectionObserver ??= ObserverStub as unknown as typeof IntersectionObserver
```

**[TEST-07] MUST:** `npm test` runs `vitest run --coverage`; `npm run test:watch` runs
`vitest`. CI runs `npm test` and fails on a threshold breach ([14](14-GIT-CI.md) §4).

---

## 3. Rendering components under test

**[TEST-08] MUST:** Components are rendered through `renderApp()` from `src/test/render.tsx`,
which wraps them in a fresh `QueryClient`, a fresh Redux store, the i18n test instance and a
`MemoryRouter`. Raw `render()` from RTL is used only for components with no provider
dependency (pure presentational components in `src/shared/components/`).
> **Why:** A component that reads `useTranslation`, `useAppSelector` or `useNavigate` throws
> without its providers. Each test building its own provider stack copies twenty lines and
> gets one of them wrong (a shared `QueryClient` across tests is the usual one).

```tsx
// src/test/render.tsx
import type { PropsWithChildren, ReactElement } from 'react'
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { render, type RenderOptions } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { I18nextProvider } from 'react-i18next'
import { Provider } from 'react-redux'
import { MemoryRouter } from 'react-router-dom'

import { setupStore, type RootState } from '@/store/store'
import { createTestI18n } from '@/test/i18n'

export function createTestQueryClient(): QueryClient {
  return new QueryClient({
    defaultOptions: {
      // retry:false -> an error state is reached in one round trip, not after 3 back-offs.
      // gcTime:Infinity -> no "cache garbage-collected after test end" warnings from the
      // default 5-minute timer outliving the test.
      queries: { retry: false, gcTime: Infinity, staleTime: 0 },
      mutations: { retry: false },
    },
  })
}

interface RenderAppOptions extends Omit<RenderOptions, 'wrapper'> {
  route?: string
  queryClient?: QueryClient
  preloadedState?: Partial<RootState>
}

export function renderApp(ui: ReactElement, options: RenderAppOptions = {}) {
  const { route = '/', queryClient = createTestQueryClient(), preloadedState, ...rest } = options
  const store = setupStore(preloadedState)
  const i18n = createTestI18n()

  function Wrapper({ children }: PropsWithChildren) {
    return (
      <QueryClientProvider client={queryClient}>
        <Provider store={store}>
          <I18nextProvider i18n={i18n}>
            <MemoryRouter initialEntries={[route]}>{children}</MemoryRouter>
          </I18nextProvider>
        </Provider>
      </QueryClientProvider>
    )
  }

  return {
    user: userEvent.setup(),
    store,
    queryClient,
    ...render(ui, { wrapper: Wrapper, ...rest }),
  }
}
```

```ts
// src/test/i18n.ts
import i18next, { type i18n } from 'i18next'
import { initReactI18next } from 'react-i18next'

// Every tr namespace file, eagerly. Tests run against the real bundle ([TEST-09]).
const trFiles = import.meta.glob<Record<string, unknown>>('@/shared/i18n/locales/tr/*.json', {
  eager: true, import: 'default',
})

export function createTestI18n(): i18n {
  const instance = i18next.createInstance()
  const tr: Record<string, Record<string, unknown>> = {}
  for (const [path, json] of Object.entries(trFiles)) {
    const ns = path.split('/').pop()!.replace('.json', '')
    tr[ns] = json
  }
  void instance.use(initReactI18next).init({
    lng: 'tr',
    fallbackLng: false,
    ns: Object.keys(tr),
    defaultNS: 'translation',
    resources: { tr },
    initImmediate: false, // synchronous init; the instance is usable on the next line
    interpolation: { escapeValue: false },
    react: { useSuspense: false },
    // A missing key fails the test with its name instead of rendering the key.
    parseMissingKeyHandler: (key) => { throw new Error(`Missing i18n key in tr bundle: ${key}`) },
  })
  return instance
}
```

**[TEST-09] MUST:** Tests render with the real `tr` locale bundle and assert on visible
text through accessible queries (`getByRole('button', { name: 'Kaydet' })`), not on
translation keys and not with a `t: (k) => k` mock.
> **Why:** Rendering the real bundle means a test fails when a key is missing, misspelled or
> lacks the interpolated value, which is exactly the class of bug [GEN-14] exists for. A key
> mock passes with a broken bundle. `tr` is the default locale of the reference deployment;
> [09](09-I18N.md) guarantees parity, so `en` needs no separate render.
>
> Note: the rule ID [TEST-09] is referenced from [02](02-TECH-VERSIONS.md) for MSW; MSW
> ownership is the next section, [TEST-11].

**[TEST-10] MUST:** Interaction uses `@testing-library/user-event` (`user.click`,
`user.type`, `user.keyboard`); `fireEvent` is forbidden except to dispatch events that
`user-event` cannot produce (`scroll`, `resize`, custom events).
> **Why:** `fireEvent.click` skips pointer-down, focus and keyboard semantics. A button that
> is `disabled`, a form that submits on Enter, or an input with an `onKeyDown` guard behaves
> differently under `fireEvent` and the test lies.

---

## 4. Network: MSW

**[TEST-11] MUST:** All network in tests is served by MSW handlers colocated in
`src/test/msw/<feature>.ts` and registered in `src/test/msw/server.ts`. Tests never reach a
real backend, never mock `fetch` or `XMLHttpRequest` by hand, and never `vi.mock` the API
client module.
> **Why:** Mocking `fetch` bypasses the client ([GEN-06]): timeout, credentials, error
> normalisation and zod parsing ([GEN-07]) are all untested. MSW intercepts at the network
> layer so the whole client path runs. `onUnhandledRequest: 'error'` ([TEST-06]) turns a
> forgotten handler into a failing test instead of a 5-second timeout.

```ts
// src/test/msw/server.ts
import { setupServer } from 'msw/node'

import { authHandlers } from './auth'
import { parkingHandlers } from './parking'

export const server = setupServer(...authHandlers, ...parkingHandlers)
```

```ts
// src/test/msw/parking.ts
import { http, HttpResponse, type HttpHandler } from 'msw'

import { buildParking } from '@/test/builders/parking'

// Handler paths are relative to the API base in test runtime config ('/api').
// The response shapes mirror the backend contract, including the pagination meta
// ([04](04-API-CLIENT.md) §5), so the zod schemas in features are exercised.
export const parkingHandlers: HttpHandler[] = [
  http.get('/api/parkings', ({ request }) => {
    const url = new URL(request.url)
    const q = url.searchParams.get('q') ?? ''
    const items = [buildParking({ id: 'p-1', name: 'Merkez Otopark' }), buildParking({ id: 'p-2', name: 'Sahil Otopark' })]
      .filter((p) => p.name.toLocaleLowerCase('tr').includes(q.toLocaleLowerCase('tr')))
    return HttpResponse.json({ data: items, meta: { page: 1, pageSize: 20, total: items.length } })
  }),

  http.get('/api/parkings/:id', ({ params }) => {
    if (params.id === 'missing') {
      return HttpResponse.json({ error: { code: 'NOT_FOUND', message: 'Parking not found' } }, { status: 404 })
    }
    return HttpResponse.json({ data: buildParking({ id: String(params.id) }) })
  }),

  http.post('/api/parkings', async ({ request }) => {
    const body = (await request.json()) as Record<string, unknown>
    return HttpResponse.json({ data: buildParking({ id: 'p-new', ...body }) }, { status: 201 })
  }),
]
```

**[TEST-12] MUST:** A test that needs a non-default response (error, empty list, slow
response) overrides the handler inside the test with `server.use(...)`; the default handler
file describes the happy path only.
> **Why:** Error paths belong to the test that asserts them. Encoding "id 42 returns 500" in
> the shared file makes another test fail for a reason its author cannot see.

```ts
server.use(http.get('/api/parkings', () => HttpResponse.json({ error: { code: 'INTERNAL' } }, { status: 500 })))
```

**[TEST-13] MUST:** MSW handlers are also the offline dev data source (`npm run dev:mock`
starts the browser worker with the same handlers). One set of handlers, two consumers.
> **Why:** Two mock data sets drift, and the one the tests use is the one nobody looks at.

---

## 5. Async assertions

**[TEST-14] MUST:** Anything that appears after an await (a fetched list, a toast, a
validation error) is asserted with `findBy*` or `await waitFor(() => expect(...))` using the
default timeout. Custom `timeout` values, `setTimeout` in tests and `await new Promise(r =>
setTimeout(r, 100))` are forbidden.
> **Why:** A hand-picked sleep is either too short (flaky on a loaded CI runner) or too long
> (adds up across 800 tests). `findBy` polls until the DOM matches and fails with the DOM
> printed when it does not.

**[TEST-15] MUST:** Loading and error states are asserted explicitly: a test for a page
proves the loading state (`getByRole('status')` or the skeleton's `aria-busy`), the loaded
state, the empty state and the error state with a working retry ([GEN-15]).
> **Why:** The four states are a golden rule; the test is where "every asynchronous UI has
> them" becomes checkable.

```tsx
// src/features/Parking/components/ParkingList.test.tsx
import { screen } from '@testing-library/react'
import { http, HttpResponse } from 'msw'
import { describe, expect, it } from 'vitest'

import { server } from '@/test/msw/server'
import { renderApp } from '@/test/render'

import { ParkingList } from './ParkingList'

describe('ParkingList', () => {
  it('shows the parkings returned by the API', async () => {
    renderApp(<ParkingList />)

    expect(screen.getByRole('status', { name: 'Yükleniyor' })).toBeInTheDocument()
    expect(await screen.findByRole('link', { name: 'Merkez Otopark' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Sahil Otopark' })).toBeInTheDocument()
  })

  it('filters the list when the user types in the search box', async () => {
    const { user } = renderApp(<ParkingList />)
    await screen.findByRole('link', { name: 'Merkez Otopark' })

    await user.type(screen.getByRole('searchbox', { name: 'Otopark ara' }), 'sahil')

    expect(await screen.findByRole('link', { name: 'Sahil Otopark' })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Merkez Otopark' })).not.toBeInTheDocument()
  })

  it('shows an empty state when the API returns no items', async () => {
    server.use(http.get('/api/parkings', () => HttpResponse.json({ data: [], meta: { page: 1, pageSize: 20, total: 0 } })))
    renderApp(<ParkingList />)

    expect(await screen.findByText('Kayıtlı otopark bulunamadı')).toBeInTheDocument()
  })

  it('shows an error with retry when the API fails, and recovers on retry', async () => {
    let calls = 0
    server.use(
      http.get('/api/parkings', () => {
        calls += 1
        return calls === 1
          ? HttpResponse.json({ error: { code: 'INTERNAL', message: 'boom' } }, { status: 500 })
          : HttpResponse.json({ data: [], meta: { page: 1, pageSize: 20, total: 0 } })
      }),
    )
    const { user } = renderApp(<ParkingList />)

    await user.click(await screen.findByRole('button', { name: 'Tekrar dene' }))

    expect(await screen.findByText('Kayıtlı otopark bulunamadı')).toBeInTheDocument()
    expect(screen.queryByText('boom')).not.toBeInTheDocument() // raw error text never shown
  })
})
```

---

## 6. Hooks and TanStack Query

**[TEST-16] MUST:** Hooks are tested with `renderHook` from `@testing-library/react`, using a
wrapper built from the same providers as `renderApp` (`createWrapper()` in `src/test/render.tsx`
returns it). A hook is not tested by rendering a throwaway component.

**[TEST-17] MUST:** Every test gets a fresh `QueryClient` ([TEST-08] creates one per
`renderApp` call) configured with `retry: false` and `gcTime: Infinity`. A module-level
`QueryClient` shared across tests is forbidden.
> **Why:** A shared client carries the previous test's cache: test B passes because test A
> fetched the data, and fails alone. `gcTime: Infinity` stops the 5-minute GC timer from
> firing after the test environment is torn down.

```ts
// src/features/Parking/hooks/useParkingList.test.ts
import { renderHook, waitFor } from '@testing-library/react'
import { describe, expect, it } from 'vitest'

import { createWrapper } from '@/test/render'

import { useParkingList } from './useParkingList'

describe('useParkingList', () => {
  it('returns the parsed parkings for the given filter', async () => {
    const { result } = renderHook(() => useParkingList({ q: 'merkez' }), { wrapper: createWrapper() })

    await waitFor(() => expect(result.current.isSuccess).toBe(true))

    expect(result.current.data?.items.map((p) => p.name)).toEqual(['Merkez Otopark'])
    expect(result.current.data?.total).toBe(1)
  })

  it('exposes a normalised ApiError when the backend fails', async () => {
    server.use(http.get('/api/parkings', () => HttpResponse.json({ error: { code: 'INTERNAL' } }, { status: 500 })))
    const { result } = renderHook(() => useParkingList({}), { wrapper: createWrapper() })

    await waitFor(() => expect(result.current.isError).toBe(true))

    expect(result.current.error).toMatchObject({ status: 500, code: 'INTERNAL' })
  })
})
```

**[TEST-18] MUST:** A mutation test proves cache invalidation by observing the effect (the
list re-fetches: the MSW handler is hit again, or the new item appears in the rendered list),
not by spying on `queryClient.invalidateQueries`.
> **Why:** Spying on the call verifies that a line exists; observing the re-fetch verifies
> the key matched ([05](05-STATE-AND-DATA.md) §3). A wrong key factory passes the spy and
> fails the user.

```tsx
it('adds the created parking to the list after submit', async () => {
  const { user } = renderApp(<ParkingPage />)
  await screen.findByRole('link', { name: 'Merkez Otopark' })

  await user.click(screen.getByRole('button', { name: 'Yeni otopark' }))
  await user.type(screen.getByRole('textbox', { name: 'Ad' }), 'Yeni Otopark')
  await user.click(screen.getByRole('button', { name: 'Kaydet' }))

  // The POST handler returns the created item; the list handler is called again because
  // onSuccess invalidated parkingKeys.lists(). No spy involved.
  expect(await screen.findByRole('link', { name: 'Yeni Otopark' })).toBeInTheDocument()
})
```

---

## 7. Forms, routes and guards

**[TEST-19] MUST:** A form ([18](18-FORMS-VALIDATION.md)) is tested through the DOM: the
user types, submits, the visible validation messages from the `tr` bundle are asserted, and
the payload is asserted from the MSW request body (`await request.json()` captured in the
handler). The zod schema itself has a separate unit test with `test.each` cases.
> **Why:** Two layers, two tests: the schema test proves the rule (a TCKN with a wrong
> checksum is rejected), the component test proves the wiring (the message appears next to
> the right field and the button is disabled while submitting).

```ts
// src/shared/utils/tckn.test.ts
import { describe, expect, it } from 'vitest'

import { isValidTckn } from './tckn'

// TCKN: 11-digit Turkish citizen id. Rules: no leading zero, digit 10 = ((sum odd*7) - sum even) mod 10,
// digit 11 = sum of first ten mod 10. Detail: 18-FORMS-VALIDATION.md §6.
describe('isValidTckn', () => {
  it.each([
    ['10000000146', true],
    ['12345678901', false], // checksum digit 10 wrong
    ['01234567890', false], // leading zero
    ['1000000014', false],  // 10 digits
    ['1000000014a', false], // non-digit
    ['', false],
  ])('%s -> %s', (input, expected) => {
    expect(isValidTckn(input)).toBe(expected)
  })
})
```

**[TEST-20] MUST:** Routes, layouts and guards are tested with `createMemoryRouter` +
`RouterProvider` using the feature's exported `RouteObject[]` ([22](22-ROUTING.md) §2),
never by rendering the page component alone with a `MemoryRouter`.
> **Why:** `RequireAuth`, `lazy`, `ErrorBoundary` and `loader` are route-level. Rendering
> the page directly skips all of them, and a broken guard ([19](19-AUTH-SESSION.md)) passes.

```tsx
// src/app/router/RequireAuth.test.tsx
import { screen } from '@testing-library/react'
import { createMemoryRouter, RouterProvider } from 'react-router-dom'
import { describe, expect, it } from 'vitest'

import { renderApp } from '@/test/render'

import { routes } from './routes'

function renderAt(path: string, preloadedState?: Parameters<typeof renderApp>[1]['preloadedState']) {
  const router = createMemoryRouter(routes, { initialEntries: [path] })
  return { router, ...renderApp(<RouterProvider router={router} />, { preloadedState }) }
}

describe('RequireAuth', () => {
  it('redirects an anonymous user to /login with returnTo', async () => {
    const { router } = renderAt('/parkings/p-1')

    await screen.findByRole('heading', { name: 'Giriş yap' })
    expect(router.state.location.pathname).toBe('/login')
    expect(router.state.location.search).toBe('?returnTo=%2Fparkings%2Fp-1')
  })

  it('renders the page for an authenticated user', async () => {
    renderAt('/parkings/p-1', { auth: { status: 'authenticated', user: buildUser() } })

    expect(await screen.findByRole('heading', { name: 'Merkez Otopark' })).toBeInTheDocument()
  })
})
```

Note: `renderApp` wraps in a `MemoryRouter`; nesting a `RouterProvider` inside it is
allowed for this purpose only because the inner data router owns navigation. If the nesting
produces a warning in the pinned React Router version, `renderApp` takes a `router` option
and skips its own `MemoryRouter`; do not disable the warning.

---

## 8. Map code

**[TEST-21] MUST:** `maplibre-gl` is replaced globally by `src/test/mocks/maplibre.ts`
([TEST-06]), a fake that records `addSource`/`addLayer`/`removeLayer`/`setFeatureState`
calls as data. Tests assert on the recorded calls; nothing in Vitest touches WebGL, a
canvas or `maplibregl.Map` from the real module.
> **Why:** jsdom has no WebGL. The real `Map` constructor throws, or worse, half-initialises
> and hangs on `style.load`. What a feature owns on the map is the set of sources, layers
> and listeners it registers and removes ([GEN-20]), and that set is fully testable as data.

```ts
// src/test/mocks/maplibre.ts
import { vi } from 'vitest'

type Listener = (ev: unknown) => void

export interface FakeMap {
  sources: Map<string, unknown>
  layers: Array<{ id: string; spec: Record<string, unknown>; before?: string }>
  featureState: Map<string, Record<string, unknown>>
  listeners: Map<string, Set<Listener>>
  styleLoaded: boolean
  fire(event: string, payload?: unknown): void
}

export function createFakeMap(): FakeMap & Record<string, unknown> {
  const map: FakeMap & Record<string, unknown> = {
    sources: new Map(), layers: [], featureState: new Map(), listeners: new Map(), styleLoaded: true,
    fire(event, payload) { map.listeners.get(event)?.forEach((l) => l(payload)) },
    isStyleLoaded: () => map.styleLoaded,
    loaded: () => map.styleLoaded,
    addSource: vi.fn((id: string, spec: unknown) => { map.sources.set(id, spec) }),
    removeSource: vi.fn((id: string) => { map.sources.delete(id) }),
    getSource: vi.fn((id: string) => map.sources.has(id) ? { setData: vi.fn(), id } : undefined),
    addLayer: vi.fn((spec: { id: string }, before?: string) => {
      const index = before ? map.layers.findIndex((l) => l.id === before) : -1
      const entry = { id: spec.id, spec, before }
      index === -1 ? map.layers.push(entry) : map.layers.splice(index, 0, entry)
    }),
    removeLayer: vi.fn((id: string) => { map.layers = map.layers.filter((l) => l.id !== id) }),
    getLayer: vi.fn((id: string) => map.layers.find((l) => l.id === id)?.spec),
    setFeatureState: vi.fn((target: { source: string; id: string | number }, state: Record<string, unknown>) => {
      const key = `${target.source}:${target.id}`
      map.featureState.set(key, { ...map.featureState.get(key), ...state })
    }),
    removeFeatureState: vi.fn((target: { source: string; id?: string | number }) => {
      for (const key of map.featureState.keys()) if (key.startsWith(`${target.source}:`)) map.featureState.delete(key)
    }),
    on: vi.fn((event: string, a: unknown, b?: unknown) => {
      const handler = (typeof a === 'function' ? a : b) as Listener // on(event, layerId, handler) form
      map.listeners.set(event, (map.listeners.get(event) ?? new Set()).add(handler))
    }),
    off: vi.fn((event: string, a: unknown, b?: unknown) => {
      const handler = (typeof a === 'function' ? a : b) as Listener
      map.listeners.get(event)?.delete(handler)
    }),
    once: vi.fn((event: string, handler: Listener) => { if (event === 'load' && map.styleLoaded) handler(undefined) }),
    addImage: vi.fn(), hasImage: vi.fn(() => false), removeImage: vi.fn(),
    setPaintProperty: vi.fn(), setLayoutProperty: vi.fn(), setFilter: vi.fn(),
    queryRenderedFeatures: vi.fn(() => []),
    flyTo: vi.fn(), easeTo: vi.fn(), fitBounds: vi.fn(), jumpTo: vi.fn(), resize: vi.fn(), remove: vi.fn(),
    getZoom: () => 12, getCenter: () => ({ lng: 28.74, lat: 41.18 }),
    getBounds: () => ({ toArray: () => [[28.6, 41.1], [28.9, 41.3]] }),
    getCanvas: () => ({ style: {} as CSSStyleDeclaration }),
    getContainer: () => document.createElement('div'),
  }
  return map
}

export const lastMap = { current: null as ReturnType<typeof createFakeMap> | null }

class Map { constructor() { lastMap.current = createFakeMap(); return lastMap.current as unknown as Map } }
class Popup { setLngLat = vi.fn(() => this); setHTML = vi.fn(() => this); setDOMContent = vi.fn(() => this); addTo = vi.fn(() => this); remove = vi.fn() }
class Marker { setLngLat = vi.fn(() => this); addTo = vi.fn(() => this); remove = vi.fn(); getElement = vi.fn(() => document.createElement('div')) }
class LngLatBounds { constructor(public sw?: unknown, public ne?: unknown) {} extend = vi.fn(() => this) }

export { Map, Popup, Marker, LngLatBounds }
export default { Map, Popup, Marker, LngLatBounds }
```

**[TEST-22] MUST:** Layer specs, paint expressions and filters are produced by pure functions
(`parkingLayers(theme): LayerSpecification[]`, `capacityColourExpression(): ExpressionSpecification`)
and unit-tested as data with `toEqual`. A snapshot is allowed for these ([TEST-26]).
> **Why:** An expression is a JSON tree; a wrong `['get', 'capasity']` typo is invisible on
> the map (the layer renders in the fallback colour) and obvious in a unit test.

```ts
// src/features/Parking/components/ParkingLayer.test.tsx
it('registers source and layers on mount and removes them in reverse order on unmount', async () => {
  const { unmount } = renderApp(<MapTestHarness><ParkingLayer /></MapTestHarness>)
  const map = lastMap.current!

  await waitFor(() => expect(map.sources.has('parking-points')).toBe(true))
  expect(map.layers.map((l) => l.id)).toEqual(['parking-points', 'parking-points-label'])

  unmount()

  expect(map.removeLayer.mock.invocationCallOrder[0]).toBeLessThan(map.removeSource.mock.invocationCallOrder[0])
  expect(map.layers).toEqual([])
  expect(map.sources.size).toBe(0)
})
```

**[TEST-23] MUST NOT:** Tests assert on rendered pixels, `queryRenderedFeatures` results
from the fake, or the internal behaviour of MapLibre (clustering output, label collision).
Those belong to MapLibre's own suite and to the e2e `idle` check ([TEST-29]).

---

## 9. Realtime, error boundaries, chunk recovery

**[TEST-24] MUST:** MQTT/WebSocket hooks ([20](20-REALTIME-MEDIA.md)) are tested with a
fake client injected through the wrapper in `src/shared/lib/mqtt.ts` (a factory the test
replaces with `vi.mock`) and `vi.useFakeTimers()` for reconnect back-off and throttling. The
test proves subscribe on mount, unsubscribe on unmount, and that a burst of 100 messages
produces one render batch, not 100 ([RT] backpressure section).
> **Why:** Reconnect logic with real timers takes seconds per case and is order-dependent.
> Fake timers make "after 3 failures the delay is 8 s" a deterministic assertion:
> `vi.advanceTimersByTime(8_000)`.

**[TEST-25] MUST:** The route error boundary and the chunk-load recovery
([17](17-ERRORS-OBSERVABILITY.md) §2) have tests: a route whose `lazy` rejects with
`Failed to fetch dynamically imported module` triggers exactly one `location.reload()`
(spied through the `reloadOnce()` wrapper, not by patching `window.location`), a second
identical failure renders the error page with a retry button, and a plain render error
renders the boundary without reloading.
> **Why:** The reload-once guard is the difference between "a deploy caused a blank page for
> everyone with an open tab" and "nobody noticed the deploy". A guard with no test is removed
> by the next refactor.

---

## 10. Snapshots, naming, hygiene

**[TEST-26] MUST NOT:** Snapshot tests (`toMatchSnapshot`, `toMatchInlineSnapshot`) of
rendered components or DOM. Allowed only for serialisable data with a stable shape: layer
specs, generated expressions, generated i18n key lists, URL search-param serialisation.
> **Why:** A DOM snapshot fails on every markup change and is updated with `-u` without being
> read; it has zero defect-finding power after its first week. A layer-spec snapshot is a
> readable JSON tree whose diff is the review.

**[TEST-27] MUST:** Naming: `describe('<unit name>')` at the top, `it('<does X when Y>')`
in plain English describing observable behaviour. One behaviour per `it`; no `it('works')`,
no `it('test 1')`.
> **Why:** The test name is the error message in CI. `ParkingList > shows an empty state when
> the API returns no items` tells the reader what broke without opening the file.

**[TEST-28] MUST NOT:** Logic in tests: no `if`, no loops that compute expectations, no
helpers that re-implement the unit under test. Expected values are literals. Parameterised
cases use `it.each` with a literal table ([TEST-19] example).
> **Why:** A test with logic can be wrong in the same way as the code, and then it passes.

**[TEST-29] MUST NOT:** Shared mutable state between tests: no module-level `let items = []`
mutated by tests, no reliance on execution order, no `beforeAll` that creates data a later
test mutates. Each test builds its own world with builders ([TEST-33]) and `server.use`.
> **Why:** Vitest runs files in parallel threads and may shuffle tests within a file. Order
> dependence shows up as "passes locally, fails in CI, passes on re-run", which is the most
> expensive kind of failure to debug.

**[TEST-30] MUST:** A flaky test (fails then passes without a code change) is quarantined
within 24 hours: `it.skip` with a comment `// FLAKY: <issue url>` and an issue assigned to
the author. `retry` in `vitest.config.ts` is forbidden; Playwright's `retries: 1` in CI is
allowed only because it captures the trace of the first failure, and a test reported as
`flaky` by the Playwright reporter counts as flaky under this rule.
> **Why:** Retrying hides a real race (usually a missing `await`, an order dependence or a
> real bug in cleanup) behind a green tick. The quarantine keeps CI trustworthy while the
> cause is found; the issue keeps it from being forgotten.

---

## 11. Playwright

**[TEST-31] MUST:** `playwright.config.ts` at the repo root: `baseURL` from `E2E_BASE_URL`,
`trace: 'on-first-retry'`, `locale: 'tr-TR'`, one Chromium desktop project, one mobile
project that runs only map specs, and a `setup` project that logs in once and saves storage
state. `forbidOnly` in CI.

```ts
// playwright.config.ts
import { defineConfig, devices } from '@playwright/test'

const isCI = Boolean(process.env.CI)
const STORAGE_STATE = 'e2e/.auth/user.json'

export default defineConfig({
  testDir: 'e2e',
  timeout: 30_000, // a smoke test that needs more is testing too much
  expect: { timeout: 10_000 },
  fullyParallel: true,
  forbidOnly: isCI,
  retries: isCI ? 1 : 0, // one retry so on-first-retry captures a trace; see [TEST-30]
  workers: isCI ? 2 : undefined,
  reporter: isCI ? [['github'], ['html', { open: 'never' }]] : 'list',
  use: {
    baseURL: process.env.E2E_BASE_URL ?? 'http://localhost:8080',
    trace: 'on-first-retry',
    screenshot: 'only-on-failure',
    locale: 'tr-TR',
    timezoneId: 'Europe/Istanbul',
  },
  projects: [
    { name: 'setup', testMatch: /.*\.setup\.ts/ },
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'], storageState: STORAGE_STATE },
      dependencies: ['setup'],
    },
    {
      // The map is the one page whose layout and input model differ on a phone.
      name: 'mobile-map',
      use: { ...devices['Pixel 7'], storageState: STORAGE_STATE },
      dependencies: ['setup'],
      testMatch: /map\..*\.spec\.ts/,
    },
  ],
})
```

**[TEST-32] MUST:** Authentication in e2e is done once in `e2e/auth.setup.ts` through the
real login form against the test backend and saved as storage state; individual tests never
log in and never set cookies by hand. Credentials come from `E2E_USER` / `E2E_PASSWORD`
environment variables provided by CI, never from the repo.

```ts
// e2e/auth.setup.ts
import { expect, test as setup } from '@playwright/test'

setup('login and save storage state', async ({ page }) => {
  const user = process.env.E2E_USER
  const password = process.env.E2E_PASSWORD
  if (!user || !password) throw new Error('E2E_USER and E2E_PASSWORD must be set')

  await page.goto('/login')
  await page.getByLabel('Kullanıcı adı').fill(user)
  await page.getByLabel('Şifre').fill(password)
  await page.getByRole('button', { name: 'Giriş yap' }).click()
  await expect(page.getByRole('navigation', { name: 'Ana menü' })).toBeVisible()

  await page.context().storageState({ path: 'e2e/.auth/user.json' })
})
```

**[TEST-33] MUST NOT:** E2E tests stub the application's own backend. `page.route()` is
allowed only for third-party origins (analytics, external map providers, payment) and for
simulating a network failure in a test whose subject is the failure UI.
> **Why:** The point of the smoke suite is that the built image talks to a real backend
> through the real nginx. Stubbing `/api/` turns it into a slow component test.

**[TEST-34] MUST:** The map module exposes `window.__mapIdle` (boolean, set on the MapLibre
`idle` event, cleared on `movestart` and `dataloading`) when the runtime config
`environment` is not `production` ([GEN-09]; e2e runs the same image with
`APP_ENVIRONMENT=staging`). Map e2e tests wait with
`page.waitForFunction(() => window.__mapIdle === true)` and never with a fixed sleep.
> **Why:** "The map rendered" has no DOM signal. `idle` fires when all tiles and sources
> have loaded and rendered, which is exactly the assertion the smoke test needs.

```ts
// src/shared/map/exposeMapIdle.ts
import type { Map as MapLibreMap } from 'maplibre-gl'

declare global { interface Window { __mapIdle?: boolean } }

export function exposeMapIdle(map: MapLibreMap, environment: string): () => void {
  if (environment === 'production') return () => undefined
  const onIdle = () => { window.__mapIdle = true }
  const onBusy = () => { window.__mapIdle = false }
  map.on('idle', onIdle)
  map.on('movestart', onBusy)
  map.on('dataloading', onBusy)
  return () => { map.off('idle', onIdle); map.off('movestart', onBusy); map.off('dataloading', onBusy); delete window.__mapIdle }
}
```

```ts
// e2e/map.smoke.spec.ts
import { expect, test } from '@playwright/test'

test.describe('map page', () => {
  test('renders the map and reaches idle with the parking layer visible', async ({ page }) => {
    await page.goto('/parkings/map')

    await expect(page.getByRole('region', { name: 'Harita' })).toBeVisible()
    await page.waitForFunction(() => window.__mapIdle === true)

    // Layer toggles are real controls with accessible names ([16]); the layer panel is the
    // user-visible proof that the feature registered its layers.
    await expect(page.getByRole('checkbox', { name: 'Otoparklar' })).toBeChecked()
  })

  test('opens a popup when a parking is selected from the list', async ({ page }) => {
    await page.goto('/parkings/map')
    await page.waitForFunction(() => window.__mapIdle === true)

    await page.getByRole('link', { name: 'Merkez Otopark' }).click()

    await expect(page.getByRole('dialog', { name: 'Merkez Otopark' })).toBeVisible()
    await expect(page).toHaveURL(/\/parkings\/map\?selected=p-1/)
  })
})
```

```ts
// e2e/login.smoke.spec.ts
import { expect, test } from '@playwright/test'

test.use({ storageState: { cookies: [], origins: [] } }) // this spec exercises login itself

test('shows a field error for a wrong password and logs in with the right one', async ({ page }) => {
  await page.goto('/login')
  await page.getByLabel('Kullanıcı adı').fill(process.env.E2E_USER!)
  await page.getByLabel('Şifre').fill('wrong-password')
  await page.getByRole('button', { name: 'Giriş yap' }).click()
  await expect(page.getByRole('alert')).toHaveText('Kullanıcı adı veya şifre hatalı')

  await page.getByLabel('Şifre').fill(process.env.E2E_PASSWORD!)
  await page.getByRole('button', { name: 'Giriş yap' }).click()
  await expect(page).toHaveURL('/')
  await expect(page.getByRole('heading', { level: 1 })).toBeVisible()
})
```

**[TEST-35] SHOULD:** E2E runs against the built Docker image inside the CI compose network
(`web` + a seeded test backend), on `main`, nightly, and on PRs labelled `e2e`
([14](14-GIT-CI.md) §4). Running e2e against `vite dev` is for local debugging only.

---

## 12. Test data and scope

**[TEST-36] MUST:** Test data comes from builder functions in `src/test/builders/<feature>.ts`
(`buildParking(overrides?: Partial<Parking>): Parking`) returning a valid object that passes
the feature's zod schema. Static fixture JSON files are forbidden except for one real-world
sample per external format (a 30-feature GeoJSON, an OpenAPI response captured once).
> **Why:** Fixture folders grow to hundreds of files nobody can name, and each test reads one
> and hopes it still matches the schema. A builder with overrides shows in the test exactly
> which field matters: `buildParking({ capacity: 0 })`.

```ts
// src/test/builders/parking.ts
import { ParkingSchema, type Parking } from '@/features/Parking'

export function buildParking(overrides: Partial<Parking> = {}): Parking {
  return ParkingSchema.parse({
    id: 'p-1',
    name: 'Merkez Otopark',
    capacity: 120,
    occupied: 48,
    location: { type: 'Point', coordinates: [28.7402, 41.1841] },
    updatedAt: '2026-09-07T08:00:00Z',
    ...overrides,
  })
}
```

**[TEST-37] MUST NOT:** Tests for third-party internals (does `react-hook-form` validate on
blur, does TanStack Query dedupe), for styling (a class is present, a colour is red), for
MapLibre rendering, or for TypeScript types via runtime assertions (use `expectTypeOf` in a
`.test-d.ts` file when a type matters).
> **Why:** Each of these tests a decision made elsewhere. When the library behaves as
> documented the test is redundant; when it does not, the test tells you nothing you can
> fix in this repo.

**[TEST-38] MUST:** Coverage thresholds ([TEST-05]) are a floor, not a target. A PR is not
asked to raise coverage, and a test written only to move a percentage (rendering a
component with no assertion) is rejected in review.
> **Why:** 100 % coverage with `expect(true).toBe(true)` is measurably worse than 70 % with
> real assertions: it costs runtime and creates false confidence.

**[TEST-39] MUST:** The `test` CI job runs `npm test` (Vitest with coverage thresholds) on
every PR; the `e2e` job runs per [TEST-35]. Both upload their reports as artifacts
(`coverage/lcov.info`, `playwright-report/`, traces). Detail: [14](14-GIT-CI.md) §4.

---

## 13. Test review checklist

Reviewer ticks these on any PR that adds or changes tests:

1. Test names read as behaviour: `describe('<unit>')`, `it('<does X when Y>')` ([TEST-27]).
2. Queries are accessible (`getByRole`, `getByLabelText`), no `querySelector`, no test ids unless there is no accessible handle ([TEST-02]).
3. Visible Turkish text is asserted, not translation keys ([TEST-09]).
4. `user-event`, not `fireEvent` ([TEST-10]).
5. `findBy*`/`waitFor` with default timeouts, no sleeps ([TEST-14]).
6. Network goes through MSW handlers in `src/test/msw/`; no `vi.mock` of the API client or `fetch` ([TEST-11]).
7. Non-default responses are `server.use` inside the test ([TEST-12]).
8. Loading, empty, error and retry are covered for any async UI ([TEST-15]).
9. Mutation tests observe the re-fetch, not the invalidate call ([TEST-18]).
10. Map tests assert recorded sources/layers/listeners and cleanup order ([TEST-21], [TEST-22]).
11. No component snapshots, no logic in tests, no shared mutable state ([TEST-26], [TEST-28], [TEST-29]).
12. Data comes from builders; new fixture files are justified ([TEST-36]).

---

## Open questions

- **Visual regression of the map page.** `expect(page).toHaveScreenshot({ maxDiffPixelRatio: 0.02 })`
  after `__mapIdle` would catch a style-JSON regression that no other test sees. Not adopted
  because tile rendering differs between the CI runner's software GL and a developer's GPU,
  and the baseline must be regenerated in CI. Condition to adopt: a nightly job with a fixed
  runner image, a fixed style, a fixed tile snapshot (PMTiles), and a measured false-positive
  rate under 1 in 20 runs for a month.
- **Accessibility assertions in e2e.** `@axe-core/playwright` is not in
  [02](02-TECH-VERSIONS.md). `eslint-plugin-jsx-a11y` covers the static half; the runtime
  half (contrast, focus order) has no automated check. Condition to adopt: approval of the
  package under [GEN-03] and a decision on which violations fail the job (proposal: `serious`
  and `critical` only).
- **Type-level tests.** `expectTypeOf` exists in Vitest; a convention for `.test-d.ts`
  files and a `typecheck` block in `vitest.config.ts` is not yet decided. Adopt when the
  first shared generic (the API client's `request<T>()`) breaks a consumer silently.
