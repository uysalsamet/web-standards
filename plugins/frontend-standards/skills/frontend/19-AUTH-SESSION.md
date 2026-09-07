# 19 — Authentication and Session

> How the browser proves who the user is, how the app learns what that user may do, and what
> happens when the proof expires. The core principle: **the SPA never holds a credential.**
> The gateway issues an `HttpOnly` cookie, the SPA asks `/api/auth/me` who it is talking to,
> and every authorisation decision in the UI is a hint, not an enforcement point.
> Read this before writing a login page, a route guard, a permission check or a logout button.
>
> Out of scope: the wire format of the session cookie, token lifetimes and the permission
> catalogue (companion backend standard); CSRF header and cookie attributes ([06](06-SECURITY.md) §6);
> the HTTP client and its 401 replay mechanics ([04](04-API-CLIENT.md) §7); the route tree
> shape ([22](22-ROUTING.md)).

---

## 1. Architecture

```
 Browser                      nginx (same origin)            Gateway / API
 ───────────────────────────  ─────────────────────────────  ─────────────────────────
 POST /api/auth/login    ───► proxy_pass /api/          ───► verify credentials
                                                             Set-Cookie: HttpOnly session
 GET  /api/auth/me       ───►                           ───► { user, permissions, ... }
 GET  /api/parkings      ───►  (cookie sent by browser) ───► 200 | 401 | 403
 POST /api/auth/refresh  ───►                           ───► new Set-Cookie, or 401
 POST /api/auth/logout   ───►                           ───► Set-Cookie: expired
```

There is no JWT in the browser. There is no `Authorization` header written by application
code. There is no "access token in memory plus refresh token in a cookie" split. There is one
cookie the browser attaches automatically, and one endpoint that tells the SPA who the cookie
belongs to.

**[AUTH-01] MUST:** The session is a cookie issued by the gateway on successful login, with
`HttpOnly; Secure; SameSite=Lax; Path=/api` ([SEC-16]). The SPA never receives, decodes,
stores or forwards a token of any kind.
> **Why:** Every alternative puts a bearer credential inside JavaScript's reach, where an XSS,
> a compromised transitive dependency or a browser extension can read it and replay it for its
> full lifetime from anywhere. With an `HttpOnly` cookie the worst an injected script can do is
> act inside the current session on this origin, which is a far smaller blast radius.
> Detail: [ADR-0017](adr/0017-auth-token-storage.md).

**[AUTH-02] MUST:** The SPA's knowledge of the session is exactly the response of
`GET /api/auth/me`, held in memory for the lifetime of the page. Nothing about the session is
persisted, mirrored into Redux, or reconstructed from a previous page load.
> **Why:** Two sources of truth for "am I logged in" diverge within one sprint: the cookie
> expires server side while a stored `user` object still says "administrator", and the app
> renders a menu that 403s on every click. The cookie is the truth; `me` is how you read it.
> [STA-38] forbids persisting it.

**[AUTH-03] MUST:** Permission keys are opaque strings in the format `<module>.<action>`
(`parking.create`, `buildingInspection.approve`) defined by the companion backend standard.
The frontend compares them for exact equality and never parses, splits, prefixes or
constructs one at runtime.
> **Why:** The moment the frontend does `permission.startsWith('parking.')` to decide
> something, a backend rename silently grants or removes access in the UI without a single
> failing test. The catalogue belongs to one side of the wire ([API-02]).

**[AUTH-04] MUST NOT:** Write a token, JWT, session id, refresh token or permission list to
`localStorage`, `sessionStorage`, IndexedDB or a JavaScript-set cookie.
> **Why:** Web storage is readable by any script on the origin, has no expiry, and survives the
> tab, the browser restart and the shared counter terminal that municipal offices actually use.
> This rule is mechanically checked: `tools/check-standards.sh` greps for
> `(local|session)Storage.setItem` with a key or value matching `token|jwt|auth|session` and
> fails the build. The named UI-preference keys of [STA-37] are the only permitted storage
> writes.

```ts
// WRONG. Fails check-standards.sh, and hands the session to any injected script.
localStorage.setItem('accessToken', payload.access_token)
setAuthHeader(`Bearer ${payload.access_token}`)

// RIGHT. Nothing to store: the gateway set the cookie on the login response.
await api.post('/auth/login', LoginResultSchema, { body: credentials, skipAuthRefresh: true })
await queryClient.fetchQuery(meQueryOptions())
```

---

## 2. Session lifecycle: 401, refresh, logout

**[AUTH-05] MUST:** `refreshSession()` in `src/features/Auth/api/refreshSession.ts` is single
flight: concurrent callers share one in-flight promise, and it resolves `true` only when the
caller may replay its request. It is wired into the client once, in `AppProviders`, as
`configureClient({ onUnauthorized: refreshSession })` ([API-28]).
> **Why:** A dashboard fires eight parallel queries. Without deduplication an expired session
> produces eight `POST /auth/refresh` calls; with rotating refresh tokens seven of them present
> an already-used token, the gateway treats that as replay, revokes the token family, and the
> user is logged out at random under load. One promise, one refresh, eight replays.

```ts
// src/features/Auth/api/refreshSession.ts
import { api } from '@/shared/api/client'
import { isApiError } from '@/shared/api/errors'

import { RefreshResultSchema } from './authSchemas'
import { forceLogout } from './forceLogout'

// A refresh that has not answered in 10 s will not help the request waiting on it, and the
// caller's own 15 s budget ([API-06]) must not be spent entirely inside the refresh.
const REFRESH_TIMEOUT_MS = 10_000

let inFlight: Promise<boolean> | null = null

/**
 * Resolves true when the caller may replay its request exactly once.
 * Resolves false when the session is definitively gone (the user has been logged out) or when
 * the refresh failed transiently; in both cases the original 401 must surface to the caller.
 */
export function refreshSession(): Promise<boolean> {
  inFlight ??= runRefresh().finally(() => {
    inFlight = null
  })
  return inFlight
}

async function runRefresh(): Promise<boolean> {
  try {
    // skipAuthRefresh breaks the recursion: a 401 from /auth/refresh must not trigger
    // another refresh ([AUTH-08]).
    await api.post('/auth/refresh', RefreshResultSchema, {
      skipAuthRefresh: true,
      timeoutMs: REFRESH_TIMEOUT_MS,
    })
    return true
  } catch (error: unknown) {
    if (isApiError(error) && (error.status === 401 || error.status === 403)) {
      // The session is over. Tear down once, and tell the other tabs ([AUTH-28]).
      await forceLogout('expired')
      return false
    }
    // Network error or 5xx: the session may still be valid. Do not log a user out because
    // of a flaky connection; let the original request fail with a retryable error ([API-33]).
    return false
  }
}

/** Test-only: this module holds process-wide state and must be reset between tests. */
export function __resetRefreshState(): void {
  inFlight = null
}
```

**[AUTH-06] MUST:** Subresources the browser fetches itself (map tiles under `/tiles/`, images,
file downloads) authenticate with the same session cookie on the same origin and need no client
code. A header-based scheme (MapLibre `transformRequest`, [MAP-24]) is used only for an upstream
that cannot sit behind the session cookie, and then the header value is a short-lived
server-issued credential ([SEC-19]), never the session itself.
> **Why:** `transformRequest` runs for every tile on the main thread, and a mistake there breaks
> the map silently at one zoom level. Same-origin cookies cost zero lines and zero per-request
> work ([GEN-22]).

**[AUTH-07] MUST:** A second 401 for the same logical request (a 401 after the replay, or a 401
when `refreshSession()` resolved `false`) triggers logout and one redirect to
`/login?returnTo=<current relative path>`, no matter how many requests failed simultaneously.
> **Why:** Ten queries failing at once must not push ten history entries, fire ten toasts and
> race three navigations. `forceLogout()` is idempotent, guarded by a module-level flag.

```ts
// src/features/Auth/api/forceLogout.ts
import { toast } from 'react-hot-toast'

import { t } from '@/shared/i18n/config'

import { authEvents } from './authEvents'            // BroadcastChannel wrapper ([AUTH-28])
import { resetClientState } from './resetClientState'

type LogoutReason = 'expired' | 'user' | 'idle' | 'other-tab'

let loggingOut = false

export async function forceLogout(reason: LogoutReason): Promise<void> {
  if (loggingOut) return
  loggingOut = true
  try {
    if (reason !== 'other-tab') {
      // Best effort: the cookie may already be dead server side. Never block teardown on it.
      await fetch('/api/auth/logout', {
        method: 'POST',
        credentials: 'include',
        headers: { 'X-Requested-With': 'XMLHttpRequest' },   // [SEC-17]
      }).catch(() => undefined)
      authEvents.post({ type: 'logged-out', reason })
    }
    resetClientState()
    if (reason === 'expired' || reason === 'idle') toast(t(`auth:logout.${reason}`))

    const returnTo = `${window.location.pathname}${window.location.search}`
    // A full navigation, not router.navigate: it guarantees that no module-level state
    // (map instance, MQTT client, timers, workers) survives into the logged-out app.
    window.location.assign(`/login?returnTo=${encodeURIComponent(returnTo)}`)
  } finally {
    loggingOut = false
  }
}
```

**[AUTH-08] MUST:** `POST /auth/login`, `POST /auth/refresh`, `POST /auth/logout` and the boot
`GET /auth/me` are all called with `skipAuthRefresh: true` ([API-05] `RequestOptions`).
> **Why:** Without it a 401 from `/auth/refresh` calls `onUnauthorized()`, which calls
> `/auth/refresh`, which 401s. The recursion is bounded only by the client's replay flag, and it
> produces a duplicate request on every visit to the login page. A 401 from the boot `me` is the
> normal "nobody is logged in yet" answer, not a session worth rescuing.

**[AUTH-09] MUST:** A `returnTo` value read from the URL is validated with `safeReturnTo()`
([SEC-18]) at the point of use, and only relative same-document paths are accepted.
> **Why:** The login page reads a value the user controls. `?returnTo=https://evil.example`
> turns a successful login into an off-site redirect with your domain in the referrer chain and
> in the user's history. Validating when the link is created does not help, because the attacker
> crafts the link directly.

---

## 3. The auth module, permissions in the UI, and the boot sequence

**[AUTH-10] MUST:** The auth feature lives in `src/features/Auth` and its `index.ts` exports
exactly: `AuthProvider`, `BootGate`, `useAuth`, `RequireAuth`, `RequirePermission`,
`refreshSession`, `forceLogout`, the lazy `LoginPage` and the `Permission` type. Everything
else is internal ([STR-05]).

**[AUTH-11] MUST:** `can(permission)` from `useAuth()` is the only permission check in
application code. A component never reads `user.permissions` directly and never compares role
names.
> **Why:** One function is one place to add impersonation handling, a superuser bypass or a
> feature-flag gate. Forty inline `user.permissions.includes(...)` calls are forty places to
> forget the null check and forty places to update when the rule changes.

**[AUTH-12] MUST:** Navigation entries a user cannot reach are **hidden**; actions on an object
the user can see but may not act on are **rendered disabled with a tooltip stating the reason**.
> **Why:** A menu of ten items where eight answer "not authorised" is worse than a menu of two.
> But a silently missing "Delete" on a row where a colleague has one produces a support ticket;
> a disabled control saying "requires the parking.delete permission" produces a request to the
> administrator, which is the outcome you want. The disabled control still needs an accessible
> name, and the tooltip must not be the only way to learn the reason ([A11Y-20]).

```tsx
// src/features/Parking/components/DeleteParkingButton.tsx
import { useTranslation } from 'react-i18next'

import { useAuth } from '@/features/Auth'
import { Button, Tooltip } from '@/shared/components'

export function DeleteParkingButton({ onDelete }: { onDelete: () => void }) {
  const { can } = useAuth()
  const { t } = useTranslation('parking')
  const allowed = can('parking.delete')

  return (
    <Tooltip content={allowed ? undefined : t('permission.requires', { key: 'parking.delete' })}>
      <Button variant="danger" disabled={!allowed} onClick={onDelete}>
        {t('action.delete')}
      </Button>
    </Tooltip>
  )
}
```

**[AUTH-13] MUST NOT:** Treat a UI permission check as an authorisation decision. Every guarded
endpoint is enforced by the server, and a 403 is a normal handled outcome ([API-29]), not an
assertion failure or an error-tracker event.
> **Why:** `can()` runs on data the client received and can edit in DevTools in ten seconds. The
> UI check exists so users are not shown doors they cannot open, nothing more. A feature whose
> security depends on a hidden button is not secured.

**[AUTH-14] MUST:** `useAuth()` throws when called outside `AuthProvider` ([STA-40]) and returns
a discriminated union, so `user` is non-nullable exactly when `status === 'authenticated'`.
> **Why:** `const { user } = useAuth()` followed by `user!.displayName` is the most common
> source of "cannot read properties of null" in a guarded app, and it fires precisely during the
> boot window that is hardest to reproduce. A union makes the compiler refuse the unguarded read.

**[AUTH-15] MUST:** `me` is a TanStack Query with `staleTime: Infinity`, `gcTime: Infinity` and
`retry: false`, owned by the auth feature. `AuthProvider` derives its value from that query and
never copies it into Redux or `useState` ([STA-01], [STA-27]).
> **Why:** One cache, one invalidation point: after a role change the app calls
> `queryClient.invalidateQueries({ queryKey: authKeys.me() })` and every `can()` in the tree is
> correct on the next render. `retry: false` matters at boot: a 401 must settle immediately, not
> after three attempts and four seconds of skeleton.

```ts
// src/features/Auth/api/authSchemas.ts
import { z } from 'zod'

// `<module>.<action>` ([AUTH-03]). Kept as a plain string at the wire boundary: a union of
// literal keys here would break the app whenever the backend adds a permission ([API-21]).
export const PermissionSchema = z.string().min(3)
export type Permission = string

export const MeSchema = z.object({
  id: z.string().min(1),
  displayName: z.string().min(1),
  email: z.email(),
  permissions: z.array(PermissionSchema),
  // Present only while an administrator is impersonating another user ([AUTH-35]).
  impersonatedBy: z.object({ id: z.string(), displayName: z.string() }).nullish(),
})
export type Me = z.infer<typeof MeSchema>

export const RefreshResultSchema = z.object({ expiresIn: z.number().int().positive() })
export const LoginResultSchema = z.object({ mustChangePassword: z.boolean().default(false) })
```

```ts
// src/features/Auth/api/authQueries.ts
import { queryOptions } from '@tanstack/react-query'

import { api } from '@/shared/api/client'

import { MeSchema } from './authSchemas'

export const authKeys = {
  all: ['auth'] as const,
  me: () => [...authKeys.all, 'me'] as const,
}

export function meQueryOptions() {
  return queryOptions({
    queryKey: authKeys.me(),
    // skipAuthRefresh: a 401 here means "not logged in", not "session expired" ([AUTH-08]).
    queryFn: ({ signal }) => api.get('/auth/me', MeSchema, { signal, skipAuthRefresh: true }),
    staleTime: Infinity,
    gcTime: Infinity,
    retry: false,
  })
}
```

```tsx
// src/features/Auth/AuthProvider.tsx
import { useQuery } from '@tanstack/react-query'
import { createContext, use, useMemo, type ReactNode } from 'react'

import { isApiError } from '@/shared/api/errors'

import { meQueryOptions } from './api/authQueries'
import type { Me, Permission } from './api/authSchemas'

export type AuthState =
  | { status: 'loading'; user: null; can: (permission: Permission) => false }
  | { status: 'anonymous'; user: null; can: (permission: Permission) => false }
  | { status: 'error'; user: null; error: unknown; can: (permission: Permission) => false }
  | { status: 'authenticated'; user: Me; can: (permission: Permission) => boolean }

const AuthContext = createContext<AuthState | null>(null)

const denyAll = () => false as const

export function AuthProvider({ children }: { children: ReactNode }) {
  const query = useQuery(meQueryOptions())

  const value = useMemo<AuthState>(() => {
    if (query.isPending) return { status: 'loading', user: null, can: denyAll }

    if (query.isError) {
      // 401 is the normal "no session" answer. Anything else is a real failure and must offer
      // a retry rather than pretending the user is anonymous ([AUTH-17]).
      const anonymous = isApiError(query.error) && query.error.status === 401
      return anonymous
        ? { status: 'anonymous', user: null, can: denyAll }
        : { status: 'error', user: null, error: query.error, can: denyAll }
    }

    const granted = new Set(query.data.permissions)
    return {
      status: 'authenticated',
      user: query.data,
      // Set lookup, not Array.includes: a municipal administrator carries 300+ permissions
      // and can() runs in every render of every menu item and every row action.
      can: (permission: Permission) => granted.has(permission),
    }
  }, [query.isPending, query.isError, query.error, query.data])

  return <AuthContext value={value}>{children}</AuthContext>
}

export function useAuth(): AuthState {
  const state = use(AuthContext)
  if (!state) throw new Error('useAuth() used outside <AuthProvider>')
  return state
}
```

**[AUTH-16] MUST:** No route renders before the `me` query settles. `BootGate` is mounted inside
`AuthProvider` and above `RouterProvider`, and renders the application shell skeleton while
`status === 'loading'`.
> **Why:** Without a gate the router mounts, `RequireAuth` sees no user and redirects to
> `/login`, and 200 ms later `me` resolves and redirects back. The user sees a flash of the login
> page on every reload, loses the deep link they opened, and any component mounted in between
> fires its queries twice.

**[AUTH-17] MUST:** The boot gate distinguishes three outcomes: authenticated (render the app),
anonymous (render the app, and let `RequireAuth` redirect), and error (render a retry screen with
the request id, never the login page).
> **Why:** A 502 from the gateway during a rolling deploy is not "you are logged out". Sending the
> user to a login form that will also 502 destroys their unsaved work for no reason and generates
> a support call about "the password stopped working".

```tsx
// src/features/Auth/BootGate.tsx
import { useQueryClient } from '@tanstack/react-query'
import { useTranslation } from 'react-i18next'
import type { ReactNode } from 'react'

import { AppShellSkeleton, ErrorState } from '@/shared/components'

import { authKeys } from './api/authQueries'
import { useAuth } from './AuthProvider'

export function BootGate({ children }: { children: ReactNode }) {
  const auth = useAuth()
  const queryClient = useQueryClient()
  const { t } = useTranslation('auth')

  // A skeleton with the real shell dimensions, not a spinner: it reserves the layout and
  // avoids the shift the login-page flash used to cause ([A11Y-18]).
  if (auth.status === 'loading') return <AppShellSkeleton />

  if (auth.status === 'error') {
    return (
      <ErrorState
        title={t('boot.failedTitle')}
        description={t('boot.failedDescription')}
        onRetry={() => void queryClient.refetchQueries({ queryKey: authKeys.me() })}
      />
    )
  }

  return children
}
```

Provider order inside `AppProviders` ([STR-19]): auth sits below Query and Redux, above the
router.

```tsx
<AppErrorBoundary>
  <RuntimeConfigProvider config={config}>
    <QueryClientProvider client={queryClient}>
      <ReduxProvider store={store}>
        <AuthProvider>
          <BootGate>
            <IdleTimeoutWatcher />          {/* [AUTH-26] */}
            <AuthTabSync />                 {/* [AUTH-28] */}
            <RouterProvider router={router} />
          </BootGate>
        </AuthProvider>
      </ReduxProvider>
    </QueryClientProvider>
  </RuntimeConfigProvider>
  <Toaster />                               {/* [A11Y-26] */}
</AppErrorBoundary>
```

---

## 4. Route guards

**[AUTH-18] MUST:** Guards are **layout routes** (`element: <RequireAuth />` rendering an
`<Outlet />`), not wrappers placed inside page components ([RTE-24], [22](22-ROUTING.md) §4).
> **Why:** A wrapper inside the page runs after the page module has been imported and after its
> `useQuery` calls have been declared. A layout route decides before the child element exists, so
> an unauthorised user never fires the page's requests and, when the guard sits above the lazy
> boundary, never downloads its chunk.

```tsx
// src/features/Auth/guards/RequireAuth.tsx
import { Navigate, Outlet, useLocation } from 'react-router-dom'

import { useAuth } from '../AuthProvider'

export function RequireAuth() {
  const auth = useAuth()
  const location = useLocation()

  if (auth.status !== 'authenticated') {
    const returnTo = `${location.pathname}${location.search}`
    // replace: the protected URL must not remain in history behind the login page, or Back
    // after a login bounces the user through the guard again.
    return <Navigate to={`/login?returnTo=${encodeURIComponent(returnTo)}`} replace />
  }
  return <Outlet />
}
```

**[AUTH-19] MUST:** `RequirePermission` takes one key or a list plus an explicit `mode`
(`'all'` by default, `'any'` when stated) and renders the 403 page; it never redirects to
`/login`.
> **Why:** Redirecting an authenticated user who lacks a permission to the login page is wrong
> twice: they are logged in, and logging in again will not help. A 403 page naming the missing
> permission is actionable, and keeping the URL lets them send the link to an administrator.

```tsx
// src/features/Auth/guards/RequirePermission.tsx
import type { ReactNode } from 'react'
import { Outlet } from 'react-router-dom'

import type { Permission } from '../api/authSchemas'
import { useAuth } from '../AuthProvider'
import { ForbiddenPage } from '../pages/ForbiddenPage'

interface RequirePermissionProps {
  /** One key, or several combined according to `mode`. */
  permission: Permission | readonly Permission[]
  mode?: 'all' | 'any'
  /** Omitted when used as a layout route; then <Outlet /> is rendered. */
  children?: ReactNode
}

export function RequirePermission({ permission, mode = 'all', children }: RequirePermissionProps) {
  const auth = useAuth()
  const required: readonly Permission[] = Array.isArray(permission) ? permission : [permission as Permission]

  // RequireAuth runs above this guard, so a non-authenticated state here is a router wiring
  // bug. Failing closed is still the correct behaviour.
  const granted =
    auth.status === 'authenticated' &&
    (mode === 'all' ? required.every((p) => auth.can(p)) : required.some((p) => auth.can(p)))

  if (!granted) return <ForbiddenPage missing={required} />
  return <>{children ?? <Outlet />}</>
}
```

```tsx
// src/app/router/router.tsx (excerpt)
{
  element: <RequireAuth />,
  children: [{
    path: '/',
    element: <AppLayout />,
    children: [
      { index: true, lazy: () => import('@/features/Dashboard').then((m) => ({ Component: m.DashboardPage })) },
      {
        element: <RequirePermission permission="parking.read" />,
        children: [
          { path: 'parking', lazy: () => import('@/features/Parking').then((m) => ({ Component: m.ParkingPage })) },
          {
            path: 'parking/new',
            element: <RequirePermission permission="parking.create" />,
            children: [{
              index: true,
              lazy: () => import('@/features/Parking').then((m) => ({ Component: m.ParkingCreatePage })),
            }],
          },
        ],
      },
    ],
  }],
}
```

**[AUTH-20] MUST:** Every guarded route's permission keys are listed in the owning feature's
`README.md` ([STR-06]).
> **Why:** "Which permission does this page need?" is otherwise answered by reading the router
> and three guard components. The backend needs the same list to seed roles, and the checklist
> requires it before a feature is done.

---

## 5. Logout and state teardown

**[AUTH-21] MUST:** Logout is `POST /api/auth/logout` (never a `GET` link, never a client-side
state clear alone), followed by a full teardown of client state and a hard navigation to
`/login`.
> **Why:** A `GET` logout is triggerable by any `<img src="/api/auth/logout">` on any page the
> user visits, which is a nuisance attack with no defence. Clearing only client state leaves the
> cookie alive: the next tab, or the Back button, is still authenticated.

**[AUTH-22] MUST:** `queryClient.clear()` is called **only** inside `resetClientState()` during
logout. It appears nowhere else in the codebase.
> **Why:** `clear()` empties every cache entry at once and is a refetch storm anywhere else,
> including for data the current screen is mid-render on. At logout that is exactly the desired
> behaviour: no trace of the previous user may survive into the next session on a shared
> workstation. Everywhere else the correct tool is targeted invalidation ([STA-12]).

```ts
// src/features/Auth/api/resetClientState.ts
import { queryClient } from '@/app/providers/queryClient'
import { disconnectRealtime } from '@/shared/lib/realtime'      // [RT-04]
import { clearUserScopedStorage } from '@/shared/lib/storageKeys'
import { store } from '@/store/store'

/**
 * Everything scoped to the user who is leaving. Order matters: stop the producers (realtime)
 * before emptying the consumers (query cache), or an in-flight MQTT message writes into a
 * cache you have just cleared.
 */
export function resetClientState(): void {
  disconnectRealtime()                     // MQTT/WebSocket close plus subscription teardown
  void queryClient.cancelQueries()
  queryClient.clear()                      // the only permitted call site ([AUTH-22])
  store.dispatch({ type: 'app/reset' })    // root reducer returns every slice to initial state
  clearUserScopedStorage()                 // drafts, last-visited ids, saved filters
}
```

**[AUTH-23] MUST:** Logout clears user-scoped persisted values (form drafts [FORM-36],
last-selected entity ids, saved table filters) and keeps device-scoped UI preferences (theme,
language, map base style, sidebar width) from [STA-37].
> **Why:** The next user at a shared counter must not see the previous user's draft inspection
> report. They also should not have the interface switch to English and light mode because
> somebody logged out. `storageKeys.ts` marks each key `scope: 'user' | 'device'`, and
> `clearUserScopedStorage()` removes only the first group.

---

## 6. Single sign-on and OIDC readiness

**[AUTH-24] MUST:** When SSO is enabled the **gateway** performs the OIDC authorization code
flow. The SPA's entire involvement is: navigate the browser to
`/api/auth/sso/start?returnTo=...` (a real navigation, not `fetch`), and handle the landing
route `/auth/callback`, which reads `returnTo`, refetches `me`, and navigates.
> **Why:** An OIDC client in the browser means a public client, PKCE state parked in web storage,
> tokens that [AUTH-04] forbids, an id token in the URL fragment that lands in browser history,
> and a second identity implementation to keep patched. The gateway already terminates the
> session; making it terminate the federation too costs the SPA one route.

```tsx
// src/features/Auth/pages/SsoCallbackPage.tsx
import { useQueryClient } from '@tanstack/react-query'
import { useEffect } from 'react'
import { useNavigate, useSearchParams } from 'react-router-dom'

import { AppShellSkeleton } from '@/shared/components'
import { safeReturnTo } from '@/shared/utils/safeReturnTo'

import { authKeys } from '../api/authQueries'

export function SsoCallbackPage() {
  const [params] = useSearchParams()
  const navigate = useNavigate()
  const queryClient = useQueryClient()

  useEffect(() => {
    // The cookie is already set by the gateway's redirect response. There is no code, no
    // state and no token for the SPA to process here ([AUTH-24]).
    let cancelled = false
    void queryClient.refetchQueries({ queryKey: authKeys.me() }).then(() => {
      if (!cancelled) navigate(safeReturnTo(params.get('returnTo')), { replace: true })
    })
    return () => { cancelled = true }
  }, [navigate, params, queryClient])

  return <AppShellSkeleton />
}
```

**[AUTH-25] MUST NOT:** Add an OIDC or SAML client library to the frontend. No such package is in
the version table ([GEN-03], [VER-05]).
> **Why:** `oidc-client-ts` and its equivalents exist to do exactly what [AUTH-01] forbids: hold
> tokens in the browser. Adopting one reverses the security model of the whole standard for the
> convenience of not configuring the gateway.

The redirect flow, rather than a popup flow, is also what makes
`Cross-Origin-Opener-Policy: same-origin` safe to keep in [SEC-10].

---

## 7. Idle timeout and multi-tab consistency

**[AUTH-26] MUST:** Sessions time out on inactivity after `config.idleTimeoutMinutes`
([STR-20]), defaulting to **30 minutes**, with a warning dialog **60 seconds** before. Activity
is `pointerdown`, `keydown`, a `visibilitychange` back to visible, and any successful mutation.
Passive `mousemove` and `scroll` do not count.
> **Why:** 30 minutes is the usual municipal information-security requirement and sits below a
> typical server session lifetime, so the client warning fires before the server surprise. The
> warning exists because silently discarding a half-written form is the most hated behaviour of
> internal tools. `mousemove` is excluded because a mouse resting on a trackpad, or an extension
> nudging the cursor, keeps a session alive forever and defeats the control entirely.

```ts
// src/features/Auth/hooks/useIdleTimeout.ts
import { useEffect, useRef, useState } from 'react'

import { useRuntimeConfig } from '@/app/config/RuntimeConfigContext'

import { forceLogout } from '../api/forceLogout'

const WARNING_LEAD_MS = 60_000
const ACTIVITY_EVENTS = ['pointerdown', 'keydown'] as const
// Coalesce activity: a burst of keystrokes resets the timer once per second, not 40 times.
const RESET_THROTTLE_MS = 1_000

export function useIdleTimeout() {
  const { idleTimeoutMinutes } = useRuntimeConfig()
  const [warningVisible, setWarningVisible] = useState(false)
  const lastResetRef = useRef(0)

  useEffect(() => {
    const timeoutMs = idleTimeoutMinutes * 60_000
    let warnTimer = 0
    let logoutTimer = 0

    const schedule = () => {
      window.clearTimeout(warnTimer)
      window.clearTimeout(logoutTimer)
      setWarningVisible(false)
      warnTimer = window.setTimeout(() => setWarningVisible(true), timeoutMs - WARNING_LEAD_MS)
      logoutTimer = window.setTimeout(() => void forceLogout('idle'), timeoutMs)
    }

    const onActivity = () => {
      const now = Date.now()
      if (now - lastResetRef.current < RESET_THROTTLE_MS) return
      lastResetRef.current = now
      schedule()
    }

    schedule()
    for (const type of ACTIVITY_EVENTS) window.addEventListener(type, onActivity, { passive: true })

    return () => {
      // [GEN-21]: every listener and timer removed, survives StrictMode remount.
      for (const type of ACTIVITY_EVENTS) window.removeEventListener(type, onActivity)
      window.clearTimeout(warnTimer)
      window.clearTimeout(logoutTimer)
    }
  }, [idleTimeoutMinutes])

  return { warningVisible, dismissWarning: () => setWarningVisible(false) }
}
```

**[AUTH-27] MUST:** The idle warning dialog offers "stay signed in" (which issues one
`POST /auth/refresh` and resets the timer) and "sign out now", traps focus, and cannot be
dismissed by clicking outside ([A11Y-08]).
> **Why:** A dialog that closes on an accidental outside click resets nothing, and the user is
> logged out 20 seconds later anyway. The refresh is what actually extends the server session;
> resetting only the client timer produces a client that believes it is alive talking to a
> server that has forgotten it.

**[AUTH-28] MUST:** Tabs synchronise auth transitions over `BroadcastChannel('auth')`. A
`logged-out` message makes every other tab run `resetClientState()` and navigate to `/login`; a
`logged-in` message makes every other tab refetch `me`. Incoming messages are parsed with a zod
schema before being acted on.
> **Why:** Logging out in one tab while another still shows the previous user's records on a
> shared screen is a data-exposure incident, not a cosmetic bug. `BroadcastChannel` is supported
> by every browser in [VER-12], needs no storage, and therefore does not weaken [AUTH-04]. It is
> also reachable by browser extensions, which is why the payload is untrusted input ([SEC-28]).

```ts
// src/features/Auth/api/authEvents.ts
import { z } from 'zod'

const AuthEventSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('logged-in') }),
  z.object({ type: z.literal('logged-out'), reason: z.enum(['expired', 'user', 'idle']) }),
])
export type AuthEvent = z.infer<typeof AuthEventSchema>

const channel = 'BroadcastChannel' in window ? new BroadcastChannel('auth') : null

export const authEvents = {
  post(event: AuthEvent): void {
    channel?.postMessage(event)
  },
  subscribe(handler: (event: AuthEvent) => void): () => void {
    if (!channel) return () => undefined
    const listener = (message: MessageEvent<unknown>) => {
      const parsed = AuthEventSchema.safeParse(message.data)
      if (parsed.success) handler(parsed.data)
    }
    channel.addEventListener('message', listener)
    return () => channel.removeEventListener('message', listener)
  },
}
```

**[AUTH-29] MUST NOT:** Poll `/api/auth/me` on a timer to detect a dead session.
> **Why:** A 30 second poll from 200 open municipal workstations is 400 requests a minute whose
> only purpose is to discover something the next real request discovers for free. The 401 path
> ([AUTH-05], [AUTH-07]) is the detection mechanism. If a stale-permission window matters,
> refetch `me` on `visibilitychange` to visible, at most once a minute.

---

## 8. The login form

**[AUTH-30] MUST:** The login form is a real `<form>` with an `autocomplete="username"` field
whose `type` matches the actual identifier, and an `autocomplete="current-password"` field,
submitted through react-hook-form ([FORM-01]).
> **Why:** Without the correct `autocomplete` tokens, password managers either fail to offer a
> fill or save the wrong field, and users respond by choosing passwords they can type from
> memory. `type="email"` on a form whose username is a staff number blocks valid logins on
> mobile keyboards that enforce the format.

```tsx
// src/features/Auth/pages/LoginPage.tsx (form body excerpt)
<form onSubmit={handleSubmit(onSubmit)} noValidate>
  <label htmlFor="username">{t('login.username')}</label>
  <input
    id="username" type="text" autoComplete="username" autoCapitalize="none" spellCheck={false}
    aria-invalid={!!errors.username} aria-describedby="username-error" {...register('username')}
  />
  <FieldError id="username-error" error={errors.username} />

  <label htmlFor="password">{t('login.password')}</label>
  <input
    id="password" type="password" autoComplete="current-password"
    aria-invalid={!!errors.password} aria-describedby="password-error" {...register('password')}
  />
  <FieldError id="password-error" error={errors.password} />

  {/* One generic message for every credential failure ([AUTH-31]), announced to screen readers. */}
  {errors.root?.serverError && <p role="alert">{errors.root.serverError.message}</p>}

  <button type="submit" disabled={isSubmitting}>{t('login.submit')}</button>
</form>
```

**[AUTH-31] MUST:** Every credential failure (unknown user, wrong password, disabled account,
expired account) renders the same message: "the username or password is incorrect". The
distinguishing detail stays in the backend log.
> **Why:** Different messages turn the login form into a user-enumeration oracle: an attacker
> learns which of 10,000 leaked addresses have accounts here, which is exactly the list worth
> attacking. Locked-account and password-expiry details are delivered after authentication
> succeeds, not before.

**[AUTH-32] MUST:** A `429` on login shows a rate-limit message whose wait comes from
`ApiError.retryAfterMs` ([API-32]), disables the submit button for that period, and never
retries automatically ([API-09]).
> **Why:** A generic "something went wrong" during a lockout makes the user hammer the button and
> extend a window they cannot see. Naming the wait ("try again in 2 minutes") converts a support
> call into waiting.

**[AUTH-33] MUST NOT:** Log, breadcrumb or report the password field, the username, or the
request body of `/auth/login` ([OBS-12], [OBS-17]).
> **Why:** The error tracker becomes a credential store the moment one login failure is captured
> with its request body. The `beforeSend` scrubbing in [OBS-12] is the backstop, not the plan.

---

## 9. Impersonation

Only for products that have the feature. If the product does not, this section is not
implemented and not scaffolded "for later".

**[AUTH-34] MUST:** Impersonation is started and ended by the server
(`POST /api/auth/impersonate/:userId`, `POST /api/auth/impersonate/stop`), which reissues the
session cookie. The frontend never sends an "acting as" header, query parameter or body field.
> **Why:** A client-supplied identity switch is a privilege-escalation endpoint with extra steps.
> The server decides who may impersonate whom and writes the audit record; the frontend learns
> the result only through `me.impersonatedBy`.

**[AUTH-35] MUST:** While `me.impersonatedBy` is non-null, a non-dismissible banner is rendered
above the application shell in a distinct colour, naming both identities, with a "stop
impersonating" button.
> **Why:** An administrator who forgets they are impersonating deletes records as somebody else,
> and the audit trail says that person did it. The banner lives in the shell layout, not in a
> page, so it survives every route change.

**[AUTH-36] MUST:** An impersonated session uses a 10 minute idle timeout instead of the
configured default, and is excluded from any "remember this device" behaviour.
> **Why:** An abandoned impersonated session is the worst possible session to leave open on a
> shared screen.

---

## 10. Testing

**[AUTH-37] MUST:** `src/test/handlers/auth.ts` ships MSW handlers for `GET /auth/me` (200
authenticated and 401 anonymous), `POST /auth/refresh` (200 and 401) and `POST /auth/login`, and
every test that renders a guarded tree selects one explicitly ([TEST-12]).
> **Why:** A suite where `me` silently returns a hard-coded administrator proves nothing about
> the guards and keeps passing after somebody deletes `RequireAuth`.

**[AUTH-38] MUST:** A test proves refresh deduplication: three concurrent requests receive 401,
the refresh handler is called exactly once, all three are replayed, and all three resolve.
> **Why:** This is the rule most likely to regress during a refactor of the client, and its
> production failure mode (random logouts under load) is nearly impossible to reproduce by hand.

```ts
// src/features/Auth/api/refreshSession.test.ts
import { http, HttpResponse } from 'msw'
import { beforeEach, expect, it, vi } from 'vitest'

import { api } from '@/shared/api/client'
import { ParkingSchema } from '@/features/Parking/api/parkingSchemas'
import { server } from '@/test/server'

import { __resetRefreshState } from './refreshSession'

beforeEach(() => { __resetRefreshState() })

it('refreshes once for concurrent 401s and replays every request', async () => {
  const refresh = vi.fn()
  let sessionValid = false

  server.use(
    http.post('/api/auth/refresh', () => {
      refresh()
      sessionValid = true
      return HttpResponse.json({ expiresIn: 900 })
    }),
    http.get('/api/parkings/:id', ({ params }) =>
      sessionValid
        ? HttpResponse.json({ id: params.id, name: 'A' })
        : HttpResponse.json({ error: { code: 'UNAUTHORIZED', message: 'expired' } }, { status: 401 }),
    ),
  )

  const results = await Promise.all(['1', '2', '3'].map((id) => api.get(`/parkings/${id}`, ParkingSchema)))

  expect(refresh).toHaveBeenCalledTimes(1)
  expect(results.map((r) => r.id)).toEqual(['1', '2', '3'])
})
```

**[AUTH-39] MUST:** Guards are tested with `createMemoryRouter` ([TEST-20]): an anonymous user at
`/parking` lands on `/login` with the correct `returnTo`, an authenticated user without
`parking.read` sees the 403 page, and a user with it sees the page.
> **Why:** Guard regressions are invisible in development, where the developer is always logged
> in as an administrator.

**[AUTH-40] MUST:** The e2e suite logs in through the real login form once in
`e2e/auth.setup.ts` and reuses the storage state ([TEST-32]); it never injects a cookie or a
token by hand.
> **Why:** Login is the path every user takes every day and the one most likely to break silently
> after a gateway change. Injecting state skips exactly the code under test.

---

## Open questions

- **Permission key typing.** [AUTH-03] keeps permissions as `string` because a literal union
  would have to be regenerated whenever the backend adds a key. When the backend standard
  publishes a machine-readable permission catalogue, generate `Permission` as a union under
  [STR-29] so the compiler catches `can('parking.craete')`. Until then a typo is a silently false
  check, which fails closed but stays invisible.
- **Activity during long operations.** [AUTH-26] resets the idle timer on user input only.
  Whether a running upload or a 20 minute report generation should count as activity is
  undecided; it needs one real case of a user being logged out mid-export before a rule is worth
  writing.
- **Device trust and "remember me".** Not specified. It requires a second, longer-lived cookie
  with its own revocation story, which is a backend-standard decision before it is a frontend
  one.
