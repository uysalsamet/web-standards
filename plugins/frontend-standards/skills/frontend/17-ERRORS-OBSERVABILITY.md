# 17 — Errors and Observability

> Governs what happens when something goes wrong in the browser and how the team finds out.
> The core principle: **every error has exactly one owner and one user-visible outcome**,
> and every report carries the release it came from. Read this file when adding a boundary,
> handling a rejected promise, showing an error to a user, touching `errorTracking.ts` or
> `logger.ts`, or when a production incident needs a stack trace. Message text belongs to
> [09](09-I18N.md); the API error body shape belongs to [04](04-API-CLIENT.md) §4.

---

## 1. Error taxonomy

Every error that reaches application code is one of five classes. The class decides who
handles it, what the user sees and whether it is reported.

| Class | Origin | Handled by | User sees | Reported to tracker |
|---|---|---|---|---|
| **Expected API error** | 4xx with a normalised body (`ApiError` with `code`, [API-05]) | The component or mutation that made the call | i18n message for the `code`, inline or toast, with retry or a way out | No (breadcrumb only) |
| **Unexpected exception** | Render error, 5xx, schema parse failure ([GEN-07]), `TypeError` | Nearest error boundary, or global handler for non-render code | Boundary fallback with retry | Yes, with component stack |
| **Chunk-load failure** | Lazy `import()` of a chunk that no longer exists after a deploy | Route error boundary (§4) | Nothing on first occurrence (reload); a message on the second | Yes, on the second occurrence only |
| **Map / WebGL failure** | Context lost, style load failure, no WebGL 2, layer exception | `MapErrorBoundary` ([MAP-38]) and the map's `error` event | Map area shows fallback and retry; the rest of the page stays | Yes, with map diagnostics |
| **Network offline** | `navigator.onLine === false`, fetch `TypeError: Failed to fetch` while offline | Offline banner (§6), the API client | Banner; submits disabled; queries show cached data | No |

**[OBS-01] MUST:** Every `catch` block and every error path classifies the error with
`classifyError()` from `src/shared/api/errors.ts` before deciding what to do, and the
decision follows the table above. A `catch` that logs and continues, or that shows a
generic toast for every class, is a violation of [GEN-17].
> **Why:** Treating a 409 conflict like a crash sends a Sentry event for a normal
> validation outcome; treating a `TypeError` in the render path like a 409 shows the user
> "Record already exists" for a null dereference. The reference app's global handler
> toasted "Unexpected error" for both, and the tracker (when there was one) got neither.

```ts
// src/shared/api/errors.ts (classifier excerpt; ApiError itself is defined per 04 §4)
import { ApiError } from './ApiError'

export type ErrorClass =
  | { kind: 'api'; error: ApiError }
  | { kind: 'chunk'; error: Error }
  | { kind: 'map'; error: Error }
  | { kind: 'offline'; error: Error }
  | { kind: 'unexpected'; error: Error }

const CHUNK_PATTERNS = [
  /Failed to fetch dynamically imported module/,
  /Unable to preload CSS/,
  /Loading (CSS )?chunk [\w-]+ failed/,
  /error loading dynamically imported module/i,          // Firefox wording
]

export class MapError extends Error { override readonly name = 'MapError' }

export function classifyError(input: unknown): ErrorClass {
  const error = input instanceof Error ? input : new Error(String(input))
  if (error instanceof ApiError) return { kind: 'api', error }
  if (error instanceof MapError) return { kind: 'map', error }
  if (CHUNK_PATTERNS.some((re) => re.test(error.message))) return { kind: 'chunk', error }
  if (!navigator.onLine && error instanceof TypeError) return { kind: 'offline', error }
  return { kind: 'unexpected', error }
}
```

The `offline` branch checks `navigator.onLine` at classification time, not at throw time.
A fetch that failed because the Wi-Fi dropped is classified correctly if the banner logic
(§6) runs first, which it does because the `offline` event fires before the fetch rejects.

---

## 2. Error boundaries

Four levels, each with a different blast radius. A boundary further down the tree keeps
more of the page alive.

**[OBS-02] MUST:** `AppProviders` is wrapped by `AppErrorBoundary`
(`src/shared/components/ErrorBoundary/AppErrorBoundary.tsx`), a class component that
renders a self-contained fallback (no router, no query client, no theme provider
required), reports the error with `captureException` and offers a reload. It is the only
place in the app where a class component is required, and the only fallback that may use
inline styles.
> **Why:** An error thrown by a provider itself (a malformed Redux preloaded state, a
> failed i18n init) happens above every route boundary. Without this boundary the user gets
> a white page and the tracker gets nothing. The fallback cannot depend on anything that
> might be the thing that broke.

```tsx
// src/shared/components/ErrorBoundary/AppErrorBoundary.tsx
import { captureException } from '@sentry/react'
import i18n from 'i18next'
import { Component, type ErrorInfo, type ReactNode } from 'react'

interface Props { children: ReactNode }
interface State { error: Error | null }

export class AppErrorBoundary extends Component<Props, State> {
  override state: State = { error: null }

  static getDerivedStateFromError(error: Error): State {
    return { error }
  }

  override componentDidCatch(error: Error, info: ErrorInfo): void {
    captureException(error, { contexts: { react: { componentStack: info.componentStack } }, tags: { boundary: 'app' } })
  }

  override render(): ReactNode {
    if (!this.state.error) return this.props.children
    // i18n is initialised before render ([STR-18]); if it is not, keys render, which is still better than a blank page.
    return (
      <main role="alert" style={{ minHeight: '100dvh', display: 'grid', placeItems: 'center', padding: 24, fontFamily: 'system-ui' }}>
        <div style={{ maxWidth: 480, textAlign: 'center' }}>
          <h1>{i18n.t('errors.appCrashed.title')}</h1>
          <p>{i18n.t('errors.appCrashed.body')}</p>
          <button type="button" onClick={() => window.location.reload()}>{i18n.t('common.reload')}</button>
        </div>
      </main>
    )
  }
}
```

**[OBS-03] MUST:** Every route object in `router.tsx` has an `ErrorBoundary` (React Router
7 data router property) set to `RouteErrorBoundary` from `src/app/router/RouteErrorBoundary.tsx`,
either directly or inherited from a layout route. `RouteErrorBoundary` distinguishes route
error responses (404, 403 from loaders, [RTE-09]) from chunk-load failures (§4) from
unexpected exceptions, and renders inside the app layout so navigation stays usable.
Cross-ref: [RTE-07].
> **Why:** Without a route-level boundary an error in one page unmounts the whole router,
> including the navigation the user needs to leave the broken page. With one, the sidebar
> stays and the user clicks elsewhere.

**[OBS-04] MUST:** The map area is wrapped by `MapErrorBoundary` ([MAP-38]) so a layer
exception never unmounts the page around it, and every non-critical panel (a chart
widget, a KPI card, a notification list) is wrapped in `WidgetErrorBoundary`, which
renders an inline fallback the size of the widget with a retry and reports the error
tagged with the widget's `feature`. Critical content (the form the page exists for, the
primary data table) is not wrapped at widget level; it fails to the route boundary.
> **Why:** A dashboard with eight widgets should not go blank because the eighth's chart
> library threw on an empty series. Conversely, hiding the primary form behind a small
> "widget failed" box makes a broken page look like a working one.

```tsx
// src/shared/components/ErrorBoundary/WidgetErrorBoundary.tsx
import { ErrorBoundary } from '@sentry/react'          // captures automatically; works with the tracker disabled
import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'

import { Button } from '@/shared/components'

interface Props { feature: string; children: ReactNode }

export function WidgetErrorBoundary({ feature, children }: Props) {
  const { t } = useTranslation()
  return (
    <ErrorBoundary
      beforeCapture={(scope) => scope.setTag('boundary', 'widget').setTag('feature', feature)}
      fallback={({ resetError }) => (
        <div role="alert" className="grid min-h-32 place-items-center rounded border border-danger/30 p-4 text-sm">
          <p>{t('errors.widgetFailed')}</p>
          <Button variant="secondary" onClick={resetError}>{t('common.retry')}</Button>
        </div>
      )}
    >
      {children}
    </ErrorBoundary>
  )
}
```

---

## 3. Release identity

**[OBS-05] MUST:** Every build carries a release id equal to the git commit sha of the
source it was built from. It is available in code as `config.release` (runtime config,
[STR-20]) and as the compile-time constant `__APP_RELEASE__` ([PERF-09] `define`), the two
are set from the same Docker build argument, and every error report, vitals report and
log line sent off the device includes it.
> **Why:** A stack trace without a release cannot be symbolicated (the source map for
> "the current build" is ambiguous the moment two versions are live during a rollout),
> and a "this bug is fixed" claim cannot be verified against the reports that keep coming
> in from users who have not reloaded. The sha, not a version string, because it is
> unforgeable and needs no bump discipline.

```dockerfile
# deployments/main/Dockerfile (release wiring excerpt; full file in 11 §1)
ARG GIT_SHA=unknown
FROM node:24-alpine AS build
ARG GIT_SHA
ENV GIT_SHA=$GIT_SHA                       # read by vite.config.ts define → __APP_RELEASE__
# ... npm ci, npm run build

FROM nginxinc/nginx-unprivileged:1.30-alpine AS runtime
ARG GIT_SHA
ENV APP_RELEASE=$GIT_SHA                   # rendered into /config.js by envsubst → config.release
```

CI passes `--build-arg GIT_SHA=$(git rev-parse HEAD)` ([CI-10]). `loadRuntimeConfig()`
compares `config.release` with `__APP_RELEASE__` and reports a warning once if they
differ: that means an image was started with a hand-edited config, which is a deploy
error, not a code error.

```ts
// src/vite-env.d.ts (addition)
declare const __APP_RELEASE__: string
```

---

## 4. Chunk-load recovery

After a deploy, `dist/assets/` contains new hashed files and nginx no longer has the old
ones ([GEN-12]). A user with the previous `index.html` still open clicks a link, the router
requests `Parking-a1b2c3.js`, gets a 404, and React Router throws
`Failed to fetch dynamically imported module` (Chrome), `error loading dynamically
imported module` (Firefox) or `Unable to preload CSS` (route CSS). Reloading fetches the
new `index.html` and fixes it. Reloading in a loop when the error is something else
(a proxy misconfiguration, an ad-blocker) turns one broken page into a browser that
cannot be used.

**[OBS-06] MUST:** On a chunk-load failure the route boundary reloads the page **once per
release**, guarded by a `sessionStorage` flag keyed with `__APP_RELEASE__`; if the flag is
already set it renders the i18n message `errors.chunkLoad` with a manual reload button and
reports the error. The flag is never cleared by application code.
> **Why:** The reference codebase's `ChunkErrorBoundary` reloads unconditionally. When a
> chunk 404s for a reason that a reload does not fix, the page reloads, fails, reloads,
> and the user sees a flickering tab with no way out; the tracker sees nothing because
> the page never lives long enough to send. Keying by release means a genuine new deploy
> (new sha) gets its one free reload again, and the same broken release does not.

```tsx
// src/app/router/RouteErrorBoundary.tsx
import { captureException } from '@sentry/react'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { isRouteErrorResponse, useRouteError } from 'react-router-dom'

import { classifyError } from '@/shared/api/errors'
import { Button } from '@/shared/components'
import { NotFoundPage } from '@/shared/components/NotFoundPage'

const RELOAD_FLAG_KEY = `chunk-reload:${__APP_RELEASE__}`

function readReloadFlag(): boolean {
  try { return sessionStorage.getItem(RELOAD_FLAG_KEY) === '1' } catch { return true }   // storage blocked: behave as "already reloaded"
}
function writeReloadFlag(): void {
  try { sessionStorage.setItem(RELOAD_FLAG_KEY, '1') } catch { /* private mode: nothing to persist; the read path returns true */ }
}

export function RouteErrorBoundary() {
  const { t } = useTranslation()
  const error = useRouteError()
  const [reloading, setReloading] = useState(false)

  const isChunk = !isRouteErrorResponse(error) && classifyError(error).kind === 'chunk'

  useEffect(() => {
    if (!isChunk) return
    if (readReloadFlag()) {
      // Second failure on the same release: reloading will not help. Report and show the message.
      captureException(error, { tags: { boundary: 'route', errorClass: 'chunk', reloadAttempted: 'true' } })
      return
    }
    writeReloadFlag()
    setReloading(true)
    window.location.reload()
  }, [isChunk, error])

  useEffect(() => {
    if (isChunk || isRouteErrorResponse(error)) return
    captureException(error, { tags: { boundary: 'route', errorClass: classifyError(error).kind } })
  }, [isChunk, error])

  if (reloading) return null                                   // the page is going away; do not flash a message
  if (isRouteErrorResponse(error) && error.status === 404) return <NotFoundPage />

  const message = isChunk ? t('errors.chunkLoad') : t('errors.pageFailed')
  return (
    <section role="alert" className="mx-auto max-w-md p-8 text-center">
      <h1 className="text-xl font-semibold">{t('errors.title')}</h1>
      <p className="mt-2">{message}</p>
      <div className="mt-6 flex justify-center gap-3">
        <Button onClick={() => window.location.reload()}>{t('common.reload')}</Button>
        <Button variant="secondary" onClick={() => window.location.assign('/')}>{t('common.home')}</Button>
      </div>
    </section>
  )
}
```

Handler-time dynamic imports (`loadXlsx()` in [PERF-05]) do not pass through the router
and are not reloaded automatically: the loader resets its memoised promise and the caller
shows `errors.chunkLoad` with a retry button. A user who then reloads manually gets the
new build.

---

## 5. Global handlers and the query client

**[OBS-07] MUST:** `window.onerror` and `unhandledrejection` are captured by the
tracker's built-in global handlers (enabled by `init()` in §7); application code adds
exactly one additional listener pair, installed by `initErrorTracking()`, whose only job
is the user-facing outcome: an expected API error becomes an i18n toast, an offline error
is left to the banner, and anything else becomes a single deduplicated generic toast.
No other file registers `window.addEventListener('error' | 'unhandledrejection')`.
> **Why:** Two capture paths means two Sentry events per error and two toasts. The
> reference app's `useGlobalErrorHandler` hook toasted a raw Turkish string for every
> rejection, including the ones a boundary had already rendered a fallback for.

```ts
// src/shared/lib/errorTracking.ts (global UX handlers excerpt; init() is in §7)
import i18n from 'i18next'
import toast from 'react-hot-toast'

import { classifyError } from '@/shared/api/errors'
import { userMessageFor } from '@/shared/lib/userMessage'

const GLOBAL_TOAST_ID = 'global-error'          // one visible at a time; later errors replace the text

export function installGlobalUxHandlers(): () => void {
  const onRejection = (event: PromiseRejectionEvent) => {
    const cls = classifyError(event.reason)
    if (cls.kind === 'offline') return                            // the banner owns this ([OBS-10])
    toast.error(userMessageFor(cls, i18n.t), { id: GLOBAL_TOAST_ID })
  }
  const onError = () => {
    toast.error(i18n.t('errors.unknown'), { id: GLOBAL_TOAST_ID })
  }
  window.addEventListener('unhandledrejection', onRejection)
  window.addEventListener('error', onError)
  return () => {
    window.removeEventListener('unhandledrejection', onRejection)
    window.removeEventListener('error', onError)
  }
}
```

**[OBS-08] MUST:** The `QueryClient` ([STA-03]) is constructed with a `QueryCache` and a
`MutationCache` whose `onError` implement this policy: mutation errors show a toast with
`userMessageFor()` unless the mutation sets `meta.silent`; query errors never toast (the
component renders its error state, [GEN-15]); background refetch failures on a query that
already has data are silent; unexpected errors of either kind are reported to the tracker
with the query key or mutation key as a tag.
> **Why:** A refetch on window focus that hits a transient 502 must not toast, because the
> user did nothing and the data on screen is still valid. A mutation failure must toast,
> because the user pressed a button and nothing else tells them it did not work.

```ts
// src/app/providers/queryClient.ts
import { MutationCache, QueryCache, QueryClient } from '@tanstack/react-query'
import i18n from 'i18next'
import toast from 'react-hot-toast'

import { classifyError } from '@/shared/api/errors'
import { reportError } from '@/shared/lib/errorTracking'
import { userMessageFor } from '@/shared/lib/userMessage'

export const queryClient = new QueryClient({
  queryCache: new QueryCache({
    onError: (error, query) => {
      const cls = classifyError(error)
      if (cls.kind === 'unexpected') reportError(cls.error, { queryKey: JSON.stringify(query.queryKey) })
      // No toast: background refetches are silent; the component shows the inline error state.
    },
  }),
  mutationCache: new MutationCache({
    onError: (error, _variables, _context, mutation) => {
      const cls = classifyError(error)
      if (cls.kind === 'unexpected') reportError(cls.error, { mutationKey: JSON.stringify(mutation.options.mutationKey ?? []) })
      if (mutation.meta?.silent === true) return
      toast.error(userMessageFor(cls, i18n.t))
    },
  }),
  defaultOptions: {
    queries: {
      // Throw to the route boundary only when there is nothing to show AND it is not an expected 4xx.
      throwOnError: (error, query) => query.state.data === undefined && classifyError(error).kind === 'unexpected',
    },
    mutations: {
      // 'online' (the default) would pause an offline mutation and replay it silently on reconnect.
      // The standard does not queue writes ([OBS-10]); fail fast and tell the user instead.
      networkMode: 'always',
    },
  },
})
```

---

## 6. What the user sees

**[OBS-09] MUST:** User-facing error text comes from i18n keys of the form
`errors.<code>` where `<code>` is the normalised API error code ([API-05]), with
`errors.unknown` as the fallback when the key does not exist. The server's `message`
field is shown only when the error body is flagged `userSafe: true`. Every error surface
(toast, inline state, boundary fallback) offers a retry or a way out (a link to the parent
page, a reload, a close button). Cross-ref: [I18N-04].
> **Why:** Server messages are written for developers ("constraint parking_pkey violated")
> and in one language. `userSafe` exists in the API contract precisely so the backend can
> opt a message in (a business rule explanation) without the frontend guessing. A dead
> end ("Error." with no button) is the most reported UX complaint in the reference
> deployment's support tickets.

```ts
// src/shared/lib/userMessage.ts
import type { TFunction } from 'i18next'
import i18n from 'i18next'

import type { ErrorClass } from '@/shared/api/errors'

export function userMessageFor(cls: ErrorClass, t: TFunction): string {
  switch (cls.kind) {
    case 'api': {
      if (cls.error.userSafe) return cls.error.message
      const key = `errors.${cls.error.code}`
      return i18n.exists(key) ? t(key) : t('errors.unknown')      // dynamic key: existence check replaces the typed-key guarantee
    }
    case 'offline': return t('errors.offline')
    case 'chunk': return t('errors.chunkLoad')
    case 'map': return t('errors.map')
    case 'unexpected': return t('errors.unknown')
  }
}
```

**[OBS-10] MUST:** The app tracks connectivity with `navigator.onLine` plus the
`online`/`offline` window events through `useOnlineStatus()`, shows one persistent
banner (`role="status"`) while offline, and disables every submit button and mutation
trigger while the banner is visible. Mutations are **not** queued for replay when
connectivity returns. Queries keep showing cached data.
> **Why:** The applications in scope edit shared municipal records. A write queued offline
> and replayed twenty minutes later lands on data someone else changed in between, and no
> one is looking at the screen when the conflict toast appears. Disabled submits plus a
> visible banner is honest; a queue is a promise the app cannot keep. `navigator.onLine`
> has false positives (connected to a router with no upstream), so the API client's
> `TypeError` path (§1) is the second signal.

```ts
// src/shared/hooks/useOnlineStatus.ts
import { useSyncExternalStore } from 'react'

function subscribe(onChange: () => void): () => void {
  window.addEventListener('online', onChange)
  window.addEventListener('offline', onChange)
  return () => {
    window.removeEventListener('online', onChange)
    window.removeEventListener('offline', onChange)
  }
}

export function useOnlineStatus(): boolean {
  return useSyncExternalStore(subscribe, () => navigator.onLine, () => true)
}
```

The three non-success states (loading, empty, error) and their visual rules are in
[16](16-ACCESSIBILITY-UX.md) §7; this file only decides that "offline" is its own state,
shown once at app level, not per component.

---

## 7. The error tracker

**[OBS-11] MUST:** The tracker is `@sentry/react` initialised once in
`src/shared/lib/errorTracking.ts` by `initErrorTracking(config)` called from `main.tsx`
before the first render, with: `dsn` from `config.errorTrackingDsn` (runtime config; the
DSN is a public value), `release: config.release`, `environment: config.environment`,
`tracesSampleRate: 0.1`, no session replay integration in the bundle
(`replaysSessionSampleRate` and `replaysOnErrorSampleRate` effectively 0),
`sendDefaultPii: false`, and `enabled` false when the DSN is absent or the environment is
`local`. The backend is any Sentry-protocol server (self-hosted Sentry or GlitchTip,
[ADR-0020](adr/0020-error-tracking.md)).
> **Why:** One init point means one place to audit what leaves the device. Replay is left
> out of the bundle (about 50 KB gz) and off by default because a replay of a municipal
> clerk's screen is personal data of the citizens on it; enabling it is a data-protection
> decision, not a debugging convenience. 10 % tracing gives route timing without
> flooding a self-hosted instance. `local` is disabled so developers' experiments do not
> pollute the project.

```ts
// src/shared/lib/errorTracking.ts (init excerpt)
import {
  addBreadcrumb, browserTracingIntegration, captureException, init, setTag,
  reactRouterV7BrowserTracingIntegration,   // verify the export name against the pinned @sentry/react 10.x
} from '@sentry/react'
import { useEffect } from 'react'
import { createRoutesFromChildren, matchRoutes, useLocation, useNavigationType } from 'react-router-dom'

import type { RuntimeConfig } from '@/app/config/runtimeConfig'   // type-only import is allowed across the boundary ([STR-24])

import { scrubEvent, scrubBreadcrumb } from './errorScrub'

const TRACES_SAMPLE_RATE = 0.1

export function initErrorTracking(config: Readonly<RuntimeConfig>): void {
  init({
    dsn: config.errorTrackingDsn,
    enabled: Boolean(config.errorTrackingDsn) && config.environment !== 'local',
    release: config.release,
    environment: config.environment,
    sendDefaultPii: false,
    tracesSampleRate: TRACES_SAMPLE_RATE,
    integrations: [
      reactRouterV7BrowserTracingIntegration({ useEffect, useLocation, useNavigationType, createRoutesFromChildren, matchRoutes }),
    ],
    beforeSend: scrubEvent,
    beforeBreadcrumb: scrubBreadcrumb,
    ignoreErrors: [
      'ResizeObserver loop completed with undelivered notifications',
      'ResizeObserver loop limit exceeded',
      /^AbortError/,                                  // our own cancellation on unmount ([PERF-24])
      'Non-Error promise rejection captured',          // third-party code rejecting with a plain object
      /extension:\/\//,
    ],
    denyUrls: [/^chrome-extension:\/\//, /^moz-extension:\/\//, /^safari-extension:\/\//],
  })
  setTag('app', config.appName)
  installGlobalUxHandlers()
}

export function reportError(error: Error, context: Record<string, string> = {}): void {
  captureException(error, { tags: context })
}

export function breadcrumb(category: 'route' | 'map' | 'api' | 'ui', message: string, data?: Record<string, string | number | boolean>): void {
  addBreadcrumb({ category, message, data, level: 'info' })
}
```

`errorTrackingDsn` and `appName` are added to the `RuntimeConfigSchema` in [03](03-PROJECT-STRUCTURE.md) §5
as `z.string().url().optional()` and `z.string().min(1)`; the config template in
[11](11-DOCKER-COMPOSE.md) §3 exposes them as `APP_ERROR_TRACKING_DSN` and `APP_NAME`.

**[OBS-12] MUST:** `beforeSend` and `beforeBreadcrumb` scrub, in every string field of
the event (message, exception values, request URL, breadcrumb data): query-string
parameters named `token`, `access_token`, `refresh_token`, `code`, `session`;
e-mail addresses; Turkish national id numbers (TCKN: 11 digits, first digit non-zero).
Geographic coordinates are **kept**: they are the primary debugging signal for a map
application and are not personal data on their own. The `ignoreErrors` list contains at
least the entries shown above.
> **Why:** A DSN is public, and so is anyone's ability to read the project if the instance
> is misconfigured; what is sent must be safe to leak. TCKN appears in URLs of citizen
> lookup screens and in form values that end up in error messages. `ResizeObserver loop`
> is a benign browser notice that would otherwise be the top event by volume, and
> extension errors are not ours.

```ts
// src/shared/lib/errorScrub.ts
import type { Breadcrumb, ErrorEvent } from '@sentry/react'

const SECRET_QUERY = /([?&](?:token|access_token|refresh_token|code|session)=)[^&#\s]+/gi
const EMAIL = /[\w.+-]+@[\w-]+\.[\w.-]+/g
const TCKN = /\b[1-9]\d{10}\b/g                                   // 11 digits, cannot start with 0

export function scrubText(text: string): string {
  return text.replace(SECRET_QUERY, '$1[redacted]').replace(EMAIL, '[email]').replace(TCKN, '[tckn]')
}

function scrubUnknown(value: unknown): unknown {
  if (typeof value === 'string') return scrubText(value)
  if (Array.isArray(value)) return value.map(scrubUnknown)
  if (value && typeof value === 'object') {
    return Object.fromEntries(Object.entries(value as Record<string, unknown>).map(([k, v]) => [k, scrubUnknown(v)]))
  }
  return value
}

export function scrubEvent(event: ErrorEvent): ErrorEvent {
  return scrubUnknown(event) as ErrorEvent                       // structural walk; the shape is preserved
}

export function scrubBreadcrumb(crumb: Breadcrumb): Breadcrumb | null {
  if (crumb.category === 'console') return null                  // console output is not sent; logger.warn/error go through capture*
  return scrubUnknown(crumb) as Breadcrumb
}
```

`scrubText` has unit tests with one fixture per pattern, including a TCKN inside a URL
and an e-mail inside a JSON string ([OBS-20]).

**[OBS-13] MUST:** Breadcrumbs are recorded for: every route change (`category: 'route'`,
the matched route pattern, not the URL with ids), every map layer visibility toggle
(`category: 'map'`, `layerId`, `visible`), and every API call (`category: 'api'`, method,
path without query string, status, duration in ms, `requestId` from the response header
[API-04]). Request and response bodies are never attached. The tracker's default `fetch`
breadcrumb is kept but its URL goes through `scrubBreadcrumb`.
> **Why:** A stack trace says where the code failed; the last twenty breadcrumbs say what
> the user did to get there. "Toggled `parcels-fill`, navigated to `/parcels/:id`, GET
> `/api/parcels/:id` 500 in 4,210 ms, then `TypeError`" is a reproducible bug report.
> Bodies are excluded because they carry the personal data §7 works to keep out.

Route breadcrumbs come from a `RouteBreadcrumbs` component mounted once in the root
layout that reads `useMatches()` and calls `breadcrumb('route', pattern)` in an effect;
map breadcrumbs come from the layer registry in `src/shared/map/` ([MAP-06]); API
breadcrumbs come from `client.ts` ([GEN-06]).

---

## 8. Web Vitals reporting

**[OBS-14] MUST:** `src/shared/lib/webVitals.ts` registers `onLCP`, `onINP`, `onCLS` and
`onTTFB` from `web-vitals` once at startup, attaches `route` (the matched route pattern at
the time the metric is finalised), `release`, `environment`, `navigationType` and the
metric `rating`, and sends the batch with `navigator.sendBeacon` to
`config.vitalsEndpoint` on `visibilitychange` to `hidden`. Each metric is also added as a
tracker breadcrumb so an error report carries the session's vitals. Absent
`vitalsEndpoint`, metrics are only shown in the debug overlay ([OBS-19]).
> **Why:** Lighthouse measures one synthetic device; the vitals that matter are the ones
> from the clerk's five-year-old laptop on the district network. Per route, because the
> map page and the settings page have different budgets and different fixes. `sendBeacon`
> on hide, because INP and CLS are only final when the page goes away, and a `fetch` at
> that moment is cancelled by the unload.

```ts
// src/shared/lib/webVitals.ts
import { onCLS, onINP, onLCP, onTTFB, type Metric } from 'web-vitals'

import type { RuntimeConfig } from '@/app/config/runtimeConfig'

import { breadcrumb } from './errorTracking'

interface VitalReport {
  name: Metric['name']; value: number; rating: Metric['rating']; id: string
  navigationType: Metric['navigationType']; route: string; release: string; environment: string
}

export function initWebVitals(config: Readonly<RuntimeConfig>, getRoute: () => string): void {
  const queue: VitalReport[] = []

  const enqueue = (metric: Metric) => {
    const report: VitalReport = {
      name: metric.name, value: Math.round(metric.value), rating: metric.rating, id: metric.id,
      navigationType: metric.navigationType, route: getRoute(), release: config.release, environment: config.environment,
    }
    queue.push(report)
    breadcrumb('ui', `vital:${metric.name}`, { value: report.value, rating: metric.rating, route: report.route })
  }

  const flush = () => {
    if (!config.vitalsEndpoint || queue.length === 0) return
    const body = JSON.stringify(queue.splice(0))
    navigator.sendBeacon(config.vitalsEndpoint, new Blob([body], { type: 'application/json' }))
  }

  onLCP(enqueue); onINP(enqueue); onCLS(enqueue); onTTFB(enqueue)
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'hidden') flush() })
}
```

`getRoute` is supplied by `main.tsx` as a closure over `router.state.matches` (the last
match's `route.path` composed with its parents), so the value reflects the route on
which the metric was finalised. `vitalsEndpoint` is a same-origin path
(`/api/web/v1/telemetry/vitals`, [GEN-22]); the endpoint contract is an open question
for the backend standard.

---

## 9. Source maps

**[OBS-15] MUST:** `build.sourcemap` is `'hidden'` ([PERF-09]); CI uploads `dist/**/*.map`
to the tracker with the release id using the Sentry CLI, then deletes the `.map` files
before the runtime image is assembled ([CI-11]). `.map` files are never present in the
nginx image and never served ([SEC-12]).
> **Why:** Minified stack traces are unreadable; `hidden` keeps the `//# sourceMappingURL`
> comment out of the bundle so browsers do not request the maps, and the upload gives the
> tracker what it needs. Serving maps publishes the source, including the comments in
> which engineers explain the workarounds.

```yaml
# .github/workflows/ci.yml (excerpt; the full pipeline is in 14 §4)
- run: npm run build
  env: { GIT_SHA: ${{ github.sha }} }
- run: |
    npx @sentry/cli sourcemaps inject dist
    npx @sentry/cli sourcemaps upload --release "$GIT_SHA" dist
    find dist -name '*.map' -delete
  env:
    GIT_SHA: ${{ github.sha }}
    SENTRY_URL: ${{ vars.SENTRY_URL }}            # the self-hosted instance
    SENTRY_ORG: ${{ vars.SENTRY_ORG }}
    SENTRY_PROJECT: ${{ vars.SENTRY_PROJECT }}
    SENTRY_AUTH_TOKEN: ${{ secrets.SENTRY_AUTH_TOKEN }}
```

`@sentry/cli` is a CI-only tool invoked with `npx`, not a project dependency; if the
organisation's policy forbids `npx` in CI it is added to `02`'s dev table under the
same rule.

---

## 10. Logging policy

**[OBS-16] MUST NOT:** `console.log`, `console.debug`, `console.info`, `console.warn`,
`console.error`, `console.table` or `debugger` appear in committed application code.
All logging goes through `logger` from `src/shared/lib/logger.ts`, which prints
`debug`/`info` only in development, prints `warn`/`error` in development, and forwards
`warn` as a tracker message and `error` as a captured exception in every environment
where the tracker is enabled. ESLint `no-console: 'error'` is on for `src/**`, with the
single exception of `logger.ts` itself.
> **Why:** A `console.error` in production is invisible to the team and visible to the
> user who opens DevTools. The reference app had 213 `console.*` calls, several printing
> full API responses with citizen data. A wrapper turns "someone might see it" into
> "the tracker has it, with release and context, and the console is clean".

```ts
// src/shared/lib/logger.ts
/* eslint-disable no-console -- the one permitted console call site */
import { captureException, captureMessage } from '@sentry/react'

export interface LogContext {
  feature?: string
  layerId?: string
  requestId?: string
  [key: string]: string | number | boolean | undefined
}

const IS_DEV = import.meta.env.DEV

function tagsOf(context: LogContext | undefined): Record<string, string> {
  return Object.fromEntries(Object.entries(context ?? {}).filter(([, v]) => v !== undefined).map(([k, v]) => [k, String(v)]))
}

export const logger = {
  debug(message: string, context?: LogContext): void {
    if (IS_DEV) console.debug(message, context ?? '')
  },
  info(message: string, context?: LogContext): void {
    if (IS_DEV) console.info(message, context ?? '')
  },
  warn(message: string, context?: LogContext): void {
    if (IS_DEV) console.warn(message, context ?? '')
    captureMessage(message, { level: 'warning', tags: tagsOf(context) })
  },
  error(message: string, error: unknown, context?: LogContext): void {
    if (IS_DEV) console.error(message, error, context ?? '')
    const wrapped = error instanceof Error ? error : new Error(`${message}: ${String(error)}`)
    captureException(wrapped, { tags: tagsOf(context), extra: { message } })
  },
} as const
```

A `logger.warn` that can fire per frame, per tile or per MQTT message is a bug: it
exhausts the tracker's quota and hides real events. Warn once per condition per session
(guard with a module-level `Set`).

**[OBS-17] MUST:** Log messages and context contain no personal data: no names, e-mails,
phone numbers, TCKN, addresses, plate numbers or free-text form values. Context is
structured (`feature`, `layerId`, `requestId`, ids of records) so events can be grouped
and searched; the message is a constant string, the variable parts go in context.
> **Why:** `logger.error(\`Failed for ${citizen.name}\`)` creates one event group per
> citizen and one privacy incident per event. `logger.error('citizen.load.failed', err,
> { feature: 'Citizen', requestId })` creates one group and no incident; the request id
> lets the backend log (which is access-controlled) supply the rest.

---

## 11. Health and version

**[OBS-18] MUST:** The nginx image answers `GET /healthz` with `200 ok`, unlogged
([NGX-11]), and `GET /__version` with `Cache-Control: no-cache` JSON of the form
`{ "release": "<sha>", "builtAt": "<ISO 8601>" }` written into `dist/` at build time by
the `versionFile` Vite plugin below. The Docker `HEALTHCHECK` ([OPS-05]) uses `/healthz`;
deploy verification uses `/__version` and compares `release` to the sha that was pushed.
> **Why:** "Is the new version live?" is otherwise answered by opening DevTools and reading
> an asset hash. Ops can `curl` this, a deploy script can assert on it, and a bug report
> can include it. `/healthz` is separate because it must be cheap enough to poll every
> ten seconds and must not go through the SPA fallback.

```ts
// vite.config.ts (plugin excerpt)
import type { Plugin } from 'vite'

function versionFile(release: string): Plugin {
  return {
    name: 'version-file',
    apply: 'build',
    generateBundle() {
      // Emitted without a hash and without an extension; nginx maps /__version to it with default_type application/json.
      this.emitFile({ type: 'asset', fileName: '__version', source: JSON.stringify({ release, builtAt: new Date().toISOString() }) })
    },
  }
}
// plugins: [ ..., versionFile(process.env.GIT_SHA ?? 'dev') ]
```

`builtAt` is the only timestamp allowed in the artefact; it describes the build, not the
content, and does not violate [GEN-11].

---

## 12. Feature-level diagnostics

**[OBS-19] MUST:** Diagnostic overlays and `window`-level debug hooks exist only behind a
`?debug=1` URL flag read once by `src/shared/lib/debugFlags.ts`, persisted for the tab in
`sessionStorage`, and honoured only when `config.environment !== 'production'`. The
overlay shows: release, route pattern, FPS (rAF counter over one second), registered map
layer and source counts ([MAP-06]), the last five Web Vitals, and the tracker's enabled
state. Nothing is attached to `window` and no `PerformanceObserver` is created when the
flag is off.
> **Why:** The reference app grew `?terrainDebug=1`, `window.__mapPerf`, `window.__mapDiag`
> and a diag ring buffer, each with its own activation and its own leak when left on. One
> flag, one overlay, one place to delete from. Production is excluded because an overlay
> that a clerk can enable by editing the URL is a support ticket.

```ts
// src/shared/lib/debugFlags.ts
const KEY = 'debug'

export function isDebugEnabled(environment: string): boolean {
  if (environment === 'production') return false
  try {
    const fromUrl = new URLSearchParams(window.location.search).get(KEY)
    if (fromUrl === '1') sessionStorage.setItem(KEY, '1')
    if (fromUrl === '0') sessionStorage.removeItem(KEY)
    return sessionStorage.getItem(KEY) === '1'
  } catch {
    return false                                                   // storage blocked: no debug, no crash
  }
}
```

The map's own instrumentation (frame timing during pan, long-task attribution to layer
operations) is specified in [08](08-MAP-MAPLIBRE.md) §9 and renders into this overlay.

Alerting on error volume, vitals regressions and health-check failures is an
operations concern: the tracker's alert rules and the uptime monitor are configured per
the ops runbook, not by this standard.

---

## 13. Testing error paths

**[OBS-20] MUST:** Every feature's test suite includes: one MSW handler returning a 500
and one returning a 4xx with a known `code`, with assertions that the component shows the
i18n message for the code and a retry control ([TEST-09]); a boundary test that renders a
throwing child inside `WidgetErrorBoundary` and asserts the fallback and the `captureException`
call (mocked); and, once per app, a `RouteErrorBoundary` test that stubs
`window.location.reload` and asserts it is called exactly once across two consecutive
chunk errors on the same release. `scrubText` has fixture tests per pattern.
> **Why:** Error paths are the least-run code in the app and the most-run code during an
> incident. The reload-once guard in particular is the kind of logic that looks right and
> loops in production; a test with two consecutive errors is the only way to know.

```ts
// src/app/router/RouteErrorBoundary.test.tsx (guard test excerpt)
import { render } from '@testing-library/react'
import { createMemoryRouter, RouterProvider } from 'react-router-dom'
import { beforeEach, expect, it, vi } from 'vitest'

import { RouteErrorBoundary } from './RouteErrorBoundary'

const reload = vi.fn()
beforeEach(() => {
  sessionStorage.clear()
  vi.stubGlobal('location', { ...window.location, reload, assign: vi.fn() })
})

function renderChunkFailure() {
  const router = createMemoryRouter([{
    path: '/', ErrorBoundary: RouteErrorBoundary,
    loader: () => { throw new TypeError('Failed to fetch dynamically imported module: /assets/Parking-abc.js') },
    element: null,
  }])
  return render(<RouterProvider router={router} />)
}

it('reloads once per release, then shows the message', async () => {
  renderChunkFailure()
  expect(reload).toHaveBeenCalledTimes(1)
  const second = renderChunkFailure()
  expect(reload).toHaveBeenCalledTimes(1)
  expect(await second.findByRole('alert')).toBeInTheDocument()
})
```

---

## Open questions

- **Vitals endpoint contract.** [OBS-14] posts a JSON array to `config.vitalsEndpoint`.
  The path, payload schema and retention belong to the backend standard's telemetry
  section, which does not yet define them. Until it does, apps set `vitalsEndpoint` only
  where a receiving service exists; the tracker breadcrumbs work regardless.
- **`@sentry/cli` in CI.** Used via `npx` in [OBS-15]. If the organisation pins every CI
  tool, it goes into `02`'s dev table with a version.
- **Sentry React Router 7 integration names.** `reactRouterV7BrowserTracingIntegration`
  and the data-router wrapper `wrapCreateBrowserRouterV7` exist in `@sentry/react` 8.x and
  9.x; confirm against the pinned 10.x changelog when wiring. If renamed, the plain
  `browserTracingIntegration` is the fallback with manual `setTag('route', pattern)`.
- **Tracker outage behaviour.** When the self-hosted instance is down the SDK drops events
  after its internal queue fills. Whether to add a local `IndexedDB` spool is left open;
  the volume of a municipal app does not justify it today.
