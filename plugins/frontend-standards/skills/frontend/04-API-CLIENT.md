# 04 — API Client

> One client, one error type, one parser. Every byte that comes from the backend passes
> through `src/shared/api/client.ts`, is validated by a zod schema, and either becomes a typed
> value or a typed `ApiError`. This file governs the client, DTO schemas, pagination, query
> strings, uploads, status-code handling, retries, cancellation and API logging. Read it when
> you call a backend, define a DTO, or handle an API error. Caching and invalidation are in
> [05](05-STATE-AND-DATA.md); session and refresh are in [19](19-AUTH-SESSION.md).

---

## 1. Scope and the wire contract

The backend standard (companion plugin) owns the wire format. This file consumes it. The
shapes below are restated so the client code compiles against something concrete; if they
ever disagree with the backend standard, the backend standard wins and this file is updated.

```jsonc
// Success. `meta` is present only on paginated list endpoints.
{ "data": { /* resource or array */ }, "meta": { "page": 1, "limit": 20, "total": 143 } }

// Failure. Same body for every 4xx/5xx the backend produces itself.
{ "error": { "code": "PARKING_NOT_FOUND", "message": "Parking p-12 does not exist", "details": { /* optional */ } } }
```

Headers the backend standard defines and this client uses: `X-Request-Id` (sent by the
browser, echoed by the backend), `Retry-After` (seconds, on 429 and 503).

**[API-01] MUST:** All HTTP from application code goes through the `api` object exported by
`src/shared/api/client.ts`; no bare `fetch()`, no `XMLHttpRequest` outside `upload.ts`, no
`axios` ([VER-05]).
> **Why:** The reference codebase has 161 files calling its own wrapper and 34 bare `fetch(`
> calls next to it. The bare calls have no timeout, no request id and three different ideas of
> what an error body looks like. Verify: `grep -rnE "[^a-zA-Z]fetch\(" src --include=*.ts --include=*.tsx`
> must list only `src/shared/api/client.ts`. `check-standards.sh` runs this grep ([TOOL-01]).

**[API-02] MUST:** The success envelope, error envelope, pagination `meta` and header names
are defined by the backend standard and only *mirrored* here as zod schemas in
`src/shared/api/schemas/common.ts` and `src/shared/api/errors.ts`.
> **Why:** Two owners of one wire format drift within a quarter. The frontend mirrors the
> contract so a change is a two-line schema edit, not a hunt through forty features.

**[API-03] MUST:** The base URL comes from runtime config ([STR-20]) and is injected once via
`configureClient()` inside `AppProviders`; `src/shared/api/**` never reads
`window.__APP_CONFIG__` or `import.meta.env`.
> **Why:** [GEN-09] forbids build-time URLs and [STR-24] keeps `shared` free of global reads.
> The reference codebase's `API_BASE_URL = import.meta.env.VITE_API_BASE_URL` is exactly the
> pattern this replaces: one image per environment.

**[API-04] MUST:** Feature code passes relative paths (`/parkings`, `/parkings/${id}`); the
path never contains a scheme or host.
> **Why:** [GEN-22]: the browser talks to its own origin and nginx proxies. A hard-coded host
> is a CORS bug waiting for the next environment.

---

## 2. The client

```ts
// src/shared/api/client.ts
import type { z } from 'zod'

import { ApiError, isAbortError, isTimeoutError, parseRetryAfter } from './errors'
import { parseResponse } from './parseResponse'
import { buildQuery, type QueryParams } from './query'

export const DEFAULT_TIMEOUT_MS = 15_000
// 2 retries: a proxy restart is over in under a second; anything longer is an outage and
// the user needs the error, not a spinner. Base 300 ms with jitter avoids a thundering herd.
const MAX_GET_RETRIES = 2
const RETRY_BASE_DELAY_MS = 300
const RETRYABLE_STATUS = new Set([429, 502, 503, 504])

export type HttpMethod = 'GET' | 'POST' | 'PUT' | 'PATCH' | 'DELETE'

export interface RequestOptions {
  query?: QueryParams | undefined
  body?: unknown
  signal?: AbortSignal | undefined
  timeoutMs?: number | undefined
  /** Auth endpoints (login, refresh, logout) set this; everything else leaves the default. */
  skipAuthRefresh?: boolean | undefined
}

export interface ClientConfig {
  baseUrl: string
  /** Single-flight session refresh ([AUTH-05]). Resolves true when the request may be replayed. */
  onUnauthorized: () => Promise<boolean>
}

let clientConfig: ClientConfig | undefined

export function configureClient(next: ClientConfig): void {
  clientConfig = next
}

async function send(url: string, method: HttpMethod, options: RequestOptions, requestId: string) {
  const timeout = AbortSignal.timeout(options.timeoutMs ?? DEFAULT_TIMEOUT_MS)
  const signal = options.signal ? AbortSignal.any([options.signal, timeout]) : timeout
  const headers: Record<string, string> = { Accept: 'application/json', 'X-Request-Id': requestId }
  const init: RequestInit = { method, credentials: 'include', headers, signal }
  if (options.body !== undefined) {
    headers['Content-Type'] = 'application/json'
    init.body = JSON.stringify(options.body)
  }
  return fetch(url, init)
}

function backoff(attempt: number, retryAfterMs: number | null): Promise<void> {
  const exponential = RETRY_BASE_DELAY_MS * 2 ** (attempt - 1) + Math.random() * RETRY_BASE_DELAY_MS
  return new Promise((resolve) => setTimeout(resolve, retryAfterMs ?? exponential))
}

async function request(method: HttpMethod, path: string, options: RequestOptions, requestId: string) {
  if (!clientConfig) throw new Error('configureClient() must run in AppProviders before any request')
  const url = `${clientConfig.baseUrl}${path}${buildQuery(options.query)}`
  const maxAttempts = method === 'GET' ? MAX_GET_RETRIES + 1 : 1
  let replayed = false

  for (let attempt = 1; ; attempt++) {
    let response: Response
    try {
      response = await send(url, method, options, requestId)
    } catch (e: unknown) {
      // Abort and timeout are final: the user cancelled, or already waited the full timeout.
      if (isAbortError(e) || isTimeoutError(e) || attempt >= maxAttempts) throw ApiError.fromNetwork(e, requestId)
      await backoff(attempt, null)
      continue
    }
    if (response.status === 401 && !options.skipAuthRefresh && !replayed) {
      replayed = true
      if (await clientConfig.onUnauthorized()) continue
    }
    if (RETRYABLE_STATUS.has(response.status) && attempt < maxAttempts) {
      await backoff(attempt, parseRetryAfter(response.headers.get('Retry-After')))
      continue
    }
    if (!response.ok) throw await ApiError.fromResponse(response, requestId)
    if (response.status === 204) return undefined
    if (!response.headers.get('Content-Type')?.includes('application/json')) {
      throw ApiError.invalidResponse(`${method} ${path}`, 'non-JSON body', requestId)
    }
    const json: unknown = await response.json()
    return json
  }
}

async function requestJson<S extends z.ZodType>(method: HttpMethod, path: string, schema: S, options: RequestOptions = {}) {
  const requestId = crypto.randomUUID()
  const raw = await request(method, path, options, requestId)
  return parseResponse(schema, { endpoint: `${method} ${path}`, requestId })(raw)
}

type ReadOptions = Omit<RequestOptions, 'body'>

// The schema parameter is mandatory by construction: there is no way to obtain a response
// body from this module without naming the schema that validates it ([GEN-07]).
export const api = {
  get: <S extends z.ZodType>(path: string, schema: S, options?: ReadOptions) => requestJson('GET', path, schema, options),
  delete: <S extends z.ZodType>(path: string, schema: S, options?: ReadOptions) => requestJson('DELETE', path, schema, options),
  post: <S extends z.ZodType>(path: string, schema: S, options?: RequestOptions) => requestJson('POST', path, schema, options),
  put: <S extends z.ZodType>(path: string, schema: S, options?: RequestOptions) => requestJson('PUT', path, schema, options),
  patch: <S extends z.ZodType>(path: string, schema: S, options?: RequestOptions) => requestJson('PATCH', path, schema, options),
}
```

Wiring in the composition root:

```ts
// src/app/providers/AppProviders.tsx (excerpt)
import { configureClient } from '@/shared/api/client'
import { refreshSession } from '@/features/Auth'   // single-flight, see [AUTH-05]

configureClient({ baseUrl: config.apiBaseUrl, onUnauthorized: refreshSession })
```

**[API-05] MUST:** Every request is sent with `credentials: 'include'` and no `Authorization`
header set from JavaScript.
> **Why:** Sessions are HttpOnly cookies ([AUTH-01]). A bearer token held in JS memory or
> storage is readable by any injected script; the reference codebase's in-memory access token
> plus `getBearerHeaders()` is the pattern this replaces.

**[API-06] MUST:** The default timeout is 15 seconds, overridable per call with `timeoutMs`;
exports and report generation may go to 60 seconds; nothing goes above 60 seconds.
> **Why:** A 15 s wait already exceeds what a user tolerates for a list. Above 60 s the request
> belongs in a background job with polling, not an open socket. Timeout throws
> `ApiError` with `kind: 'timeout'`; the UI shows retry ([GEN-15]).

**[API-07] MUST:** Every logical request carries one `X-Request-Id` (`crypto.randomUUID()`),
kept across retries and the post-refresh replay, and surfaced in `ApiError.requestId`.
> **Why:** The backend logs the id; the user sees it in the error toast ([OBS-09]); support
> joins the two. A new id per retry breaks the join for exactly the requests that failed.

**[API-08] MUST:** The client speaks JSON only: `Accept: application/json`, body via
`JSON.stringify`, and a 2xx response whose `Content-Type` is not JSON is an `ApiError` with
`kind: 'invalid_response'`.
> **Why:** An nginx 200 with an HTML maintenance page, or an SPA fallback returning
> `index.html` for a mistyped API path, otherwise surfaces as `SyntaxError: Unexpected token <`
> deep inside a component. Multipart uploads are the one exception and live in `upload.ts` (§9).

**[API-09] MUST NOT:** Retry a `POST`, `PUT`, `PATCH` or `DELETE`. `GET` is retried at most
twice, with exponential backoff (300 ms base, plus 0 to 300 ms jitter), only on a network
`TypeError` or on 429/502/503/504.
> **Why:** A replayed `POST` after a timeout creates the record twice; the first one succeeded
> and the response was lost. Idempotency keys are not part of the backend contract today
> (see Open questions). 500 is not retried: it is a bug, not a transient.

**[API-10] MUST NOT:** Retry after a timeout or a caller abort.
> **Why:** After a timeout the user has already waited 15 s; a retry turns that into 45 s
> behind a spinner. After an abort the component is gone and nobody will read the result.

---

## 3. Errors

```ts
// src/shared/api/errors.ts
import { z } from 'zod'

// Mirror of the backend standard's error envelope ([API-02]). Change it there first.
export const ErrorBodySchema = z.object({
  error: z.object({ code: z.string().min(1), message: z.string(), details: z.unknown().optional() }),
})

// Assumed shape of `details` on 409/422. Verify against the backend standard's validation section.
export const FieldErrorSchema = z.object({ field: z.string().min(1), code: z.string().min(1), message: z.string() })
export type FieldError = z.infer<typeof FieldErrorSchema>
const FieldErrorListSchema = z.array(FieldErrorSchema)

const MAX_RETRY_AFTER_MS = 10_000

export type ApiErrorKind = 'http' | 'network' | 'timeout' | 'aborted' | 'invalid_response'

interface ApiErrorInit {
  kind: ApiErrorKind
  status: number
  code: string
  message: string
  requestId: string
  details?: unknown
  retryAfterMs?: number | null
  cause?: unknown
}

export class ApiError extends Error {
  override readonly name = 'ApiError'
  readonly kind: ApiErrorKind
  readonly status: number        // 0 when no response was received
  readonly code: string          // backend code, or NETWORK / TIMEOUT / ABORTED / INVALID_RESPONSE / UNKNOWN
  readonly details: unknown
  readonly requestId: string
  readonly retryAfterMs: number | null

  constructor(init: ApiErrorInit) {
    super(init.message, { cause: init.cause })
    this.kind = init.kind
    this.status = init.status
    this.code = init.code
    this.details = init.details
    this.requestId = init.requestId
    this.retryAfterMs = init.retryAfterMs ?? null
  }

  static async fromResponse(response: Response, requestId: string): Promise<ApiError> {
    const body = await response.json().then((j: unknown) => j, () => null)
    const parsed = ErrorBodySchema.safeParse(body)
    return new ApiError({
      kind: 'http',
      status: response.status,
      code: parsed.success ? parsed.data.error.code : 'UNKNOWN',
      message: parsed.success ? parsed.data.error.message : `HTTP ${response.status}`,
      details: parsed.success ? parsed.data.error.details : undefined,
      requestId,
      retryAfterMs: parseRetryAfter(response.headers.get('Retry-After')),
    })
  }

  static fromNetwork(cause: unknown, requestId: string): ApiError {
    const kind: ApiErrorKind = isTimeoutError(cause) ? 'timeout' : isAbortError(cause) ? 'aborted' : 'network'
    return new ApiError({ kind, status: 0, code: kind.toUpperCase(), message: `Request ${kind}`, requestId, cause })
  }

  static invalidResponse(endpoint: string, reason: string, requestId: string, cause?: unknown): ApiError {
    return new ApiError({ kind: 'invalid_response', status: 0, code: 'INVALID_RESPONSE', message: `${endpoint}: ${reason}`, requestId, cause })
  }

  get isUnauthorized(): boolean { return this.status === 401 }
  get isForbidden(): boolean { return this.status === 403 }
  get isNotFound(): boolean { return this.status === 404 }
  get isValidation(): boolean { return this.status === 422 || this.status === 409 }

  /** Field-level errors for react-hook-form ([FORM-09]). Empty when `details` has another shape. */
  fieldErrors(): FieldError[] {
    const result = FieldErrorListSchema.safeParse(this.details)
    return result.success ? result.data : []
  }
}

export function isApiError(e: unknown): e is ApiError {
  return e instanceof ApiError
}
export function isAbortError(e: unknown): boolean {
  return e instanceof DOMException && e.name === 'AbortError'
}
export function isTimeoutError(e: unknown): boolean {
  return e instanceof DOMException && e.name === 'TimeoutError'
}

/** Accepts delay-seconds or an HTTP-date. Capped: nobody waits more than 10 s in a browser. */
export function parseRetryAfter(header: string | null): number | null {
  if (!header) return null
  const seconds = Number(header)
  const ms = Number.isFinite(seconds) ? seconds * 1000 : Date.parse(header) - Date.now()
  return Number.isFinite(ms) && ms > 0 ? Math.min(ms, MAX_RETRY_AFTER_MS) : null
}
```

**[API-11] MUST:** Every failure that leaves the client is an `ApiError`; no raw `Error`, no
string, no `Response` object.
> **Why:** Callers branch on `status`, `code` and `kind`. An `Error` with a message like
> `"HTTP 404 Not Found"` (the reference codebase's `handleResponse`) forces string matching in
> the UI, which breaks with the first backend wording change.

**[API-12] MUST:** A non-2xx body that does not match `ErrorBodySchema` still produces an
`ApiError` with the real `status`, `code: 'UNKNOWN'` and message `HTTP <status>`.
> **Why:** nginx, the gateway and a crashed process all produce non-standard bodies. The status
> is still the most useful fact; losing it to a parse failure hides a 503 behind "unknown error".

**[API-13] MUST NOT:** Show the backend `message` as the primary text in the UI; the UI maps
`code` to an i18n key and falls back to a generic message plus the request id.
> **Why:** Backend messages are English, developer-facing and change without notice ([GEN-14]).
> `message` is for the error tracker and the details panel, not the toast. Mapping lives in
> `src/shared/api/errorMessages.ts` ([I18N-11], [OBS-09]).

---

## 4. Response parsing and DTO schemas

```ts
// src/shared/api/parseResponse.ts
import type { z } from 'zod'

import { ApiError } from './errors'

export interface ParseContext { endpoint: string; requestId: string }

export function parseResponse<S extends z.ZodType>(schema: S, ctx: ParseContext) {
  return (raw: unknown): z.output<S> => {
    const result = schema.safeParse(raw)
    if (result.success) return result.data
    // First three paths are enough to locate the field; the full issue list goes to the tracker as `cause`.
    const paths = result.error.issues.slice(0, 3).map((i) => i.path.map(String).join('.') || '(root)')
    throw ApiError.invalidResponse(ctx.endpoint, `schema mismatch at ${paths.join(', ')}`, ctx.requestId, result.error)
  }
}
```

```ts
// src/shared/api/schemas/common.ts
import { z } from 'zod'

export const PAGE_LIMIT_DEFAULT = 20
export const PAGE_LIMIT_MAX = 100

export const PageMetaSchema = z.object({
  page: z.number().int().min(1),
  limit: z.number().int().min(1),
  total: z.number().int().min(0),
})
export type PageMeta = z.infer<typeof PageMetaSchema>

export function single<T extends z.ZodType>(item: T) {
  return z.object({ data: item })
}
export function paginated<T extends z.ZodType>(item: T) {
  return z.object({ data: z.array(item), meta: PageMetaSchema })
}
export const EmptyResponseSchema = z.undefined()   // 204 No Content
```

```ts
// src/shared/api/schemas/geo.ts
import { z } from 'zod'

// [lng, lat], WGS84, in that order ([GIS-02]). Bounds catch swapped coordinates at the boundary.
export const PositionSchema = z.tuple([z.number().min(-180).max(180), z.number().min(-90).max(90)])
export type Position = z.infer<typeof PositionSchema>
```

**[API-14] MUST:** Every response body is parsed with the zod schema passed to `api.*`; a
`Response`, `unknown` or `any` never reaches feature code, and `as SomeType` on API data is a
lint error ([GEN-07], [TS-05]).
> **Why:** `res.json() as Promise<T>` (the reference codebase) promises the compiler a shape the
> backend never agreed to. The failure surfaces as `Cannot read properties of null` three
> screens away instead of `GET /parkings: schema mismatch at data.0.capacity`.

**[API-15] MUST:** A schema mismatch is an `ApiError` with `kind: 'invalid_response'`, is
reported to the error tracker with the endpoint and issue paths ([OBS-04]), and renders the
error state; it is never caught and replaced by a default value.
> **Why:** Silently defaulting a broken field ships wrong numbers to a municipality dashboard.
> The screen must fail visibly so the backend change is found the same day.

**[API-16] MUST:** DTO schemas live in `src/features/<Name>/api/<name>Schemas.ts`, are named
`<Name>Schema`, and their types are `type <Name> = z.infer<typeof <Name>Schema>`; no
hand-written `interface` duplicates a schema.
> **Why:** Two definitions of one DTO (the reference `types/index.ts` plus whatever the code
> assumes) drift silently. One schema, one inferred type, one place to edit.

**[API-17] MUST:** A field the backend always sends but may set to `null` is `.nullable()`;
a field the backend may omit is `.optional()`; a field is both only when the backend standard
documents it as such.
> **Why:** `.optional()` on a field that arrives as `null` fails parsing; `.nullable()` on an
> omitted field also fails. The default for backend DTOs is `.nullable()`, because the backend
> standard serialises every column. `.nullish()` everywhere hides which case you handled.

**[API-18] MUST:** Dates and timestamps are ISO 8601 strings in DTOs, validated with
`z.iso.datetime({ offset: true })`, and converted to `Date` or formatted text only at the edge
(a `select` in the query or the formatting call in the component, [I18N-08]).
> **Why:** `Date` objects in cached data defeat TanStack's structural sharing (two equal dates
> are different references), so every refetch re-renders every consumer and re-uploads every
> map source ([STA-19]). Strings compare by value.

**[API-19] MUST:** Numeric fields are `z.number()`; `z.coerce.number()` or a `.transform`
from string is allowed only with a comment linking the backend issue that will fix the
serialisation, and is removed when it closes.
> **Why:** A numeric column serialised as `"12.50"` is a backend standard violation. Coercing
> it on 40 screens hides the bug and turns `"12,50"` (Turkish locale) into `NaN` in production.

**[API-20] MUST:** Coordinates are `[lng, lat]` tuples parsed with `PositionSchema`; GeoJSON
responses use the shared geometry schemas in `src/shared/api/schemas/geo.ts`, never a hand
typed `{ type: string; coordinates: number[] }`.
> **Why:** Swapped `[lat, lng]` renders every feature in the Indian Ocean. The tuple bounds
> reject it at the boundary. Detail: [APPENDIX-GIS-DATA.md](APPENDIX-GIS-DATA.md) §1.

**[API-21] MUST NOT:** Use `.strict()` or `.loose()`/`.passthrough()` on response object
schemas; the default (unknown keys stripped) is the rule.
> **Why:** `.strict()` breaks the UI the day the backend adds a field; `.loose()` lets
> unvalidated keys flow into components and into `JSON.stringify` diffs. Stripping is the
> forward-compatible middle.

**[API-22] MUST:** Request body types derive from the same schema file
(`ParkingCreateSchema = ParkingSchema.omit({ id: true, updatedAt: true })`) and are the
resolver schemas for the form that produces them ([FORM-02]).
> **Why:** The form validates what the API accepts, from one definition. A separate "form type"
> is where `capacity: string` sneaks in.

---

## 5. Pagination and query strings

```ts
// src/shared/api/query.ts
export type QueryValue = string | number | boolean | null | undefined
export type QueryParams = Record<string, QueryValue | readonly QueryValue[]>

/** Sorted keys so equal filters produce equal URLs (stable query keys, stable MSW matching). */
export function buildQuery(params: QueryParams | undefined): string {
  if (!params) return ''
  const search = new URLSearchParams()
  for (const key of Object.keys(params).sort()) {
    const value = params[key]
    const values = Array.isArray(value) ? value : [value]
    for (const v of values) {
      if (v === undefined || v === null || v === '') continue
      search.append(key, String(v))
    }
  }
  const s = search.toString()
  return s ? `?${s}` : ''
}
```

```ts
// src/shared/api/pagination.ts
import { PAGE_LIMIT_DEFAULT, PAGE_LIMIT_MAX } from './schemas/common'

export function clampLimit(limit: number | undefined): number {
  if (limit === undefined || !Number.isFinite(limit)) return PAGE_LIMIT_DEFAULT
  return Math.min(PAGE_LIMIT_MAX, Math.max(1, Math.trunc(limit)))
}
export function clampPage(page: number | undefined): number {
  return page !== undefined && Number.isFinite(page) && page >= 1 ? Math.trunc(page) : 1
}
```

**[API-23] MUST:** `limit` is clamped to 1..100 with default 20 and `page` to `>= 1` on the
client before the request is built; the clamp is `clampLimit`/`clampPage`, not inline math.
> **Why:** The backend rejects `limit=500` with a 422 the user cannot act on, and `page=0` from
> a mistyped URL gives an empty table with no explanation. 100 is the backend standard's cap;
> 20 keeps a first paint under one screen of rows. Lists above 200 rows virtualise ([PERF-12]).

**[API-24] MUST:** Offset pagination (`page`, `limit`, `meta.total`) is used for admin tables
that show a total and jump to pages; cursor pagination is used for feeds, logs and anything
that grows while the user reads; the mode is dictated per endpoint by the backend, and the
client does not convert one into the other.
> **Why:** Offset pages shift when a row is inserted above the cursor (duplicates and gaps in
> a live log). Cursors cannot jump to page 7. Faking a total on a cursor endpoint is a lie in
> the UI. Cursor `meta` shape is an open question below.

**[API-25] MUST:** Query strings are built by `buildQuery` from a `QueryParams` object with
sorted keys; `undefined`, `null` and `''` are omitted; arrays are repeated keys; manual
string concatenation of `?a=${x}` is forbidden.
> **Why:** `?parking_type=${type}` with an unencoded Turkish `ş` produces a 400 on one proxy and
> silently mismatches on another. Sorted keys make `{ a, b }` and `{ b, a }` the same cache
> entry and the same MSW match.

---

## 6. A feature API file

```ts
// src/shared/types/ids.ts
import { z } from 'zod'

// Branded ids: a ParkingId cannot be passed where a VehicleId is expected ([TS-10]).
// The brand is applied by the schema, never by a cast.
export const ParkingIdSchema = z.string().min(1).brand<'ParkingId'>()
export type ParkingId = z.infer<typeof ParkingIdSchema>
```

```ts
// src/features/Parking/api/parkingSchemas.ts
import { z } from 'zod'

import { PAGE_LIMIT_DEFAULT, PAGE_LIMIT_MAX, paginated, single } from '@/shared/api/schemas/common'
import { PositionSchema } from '@/shared/api/schemas/geo'
import { ParkingIdSchema } from '@/shared/types/ids'

export const ParkingSchema = z.object({
  id: ParkingIdSchema,
  name: z.string().min(1),
  capacity: z.number().int().nonnegative(),
  occupied: z.number().int().nonnegative(),
  location: PositionSchema,
  district: z.string().nullable(),                      // null: not yet assigned
  closedAt: z.iso.datetime({ offset: true }).nullable(), // null: open
  updatedAt: z.iso.datetime({ offset: true }),
})
export type Parking = z.infer<typeof ParkingSchema>

export const ParkingListFiltersSchema = z.object({
  q: z.string().trim().max(100).optional(),
  district: z.string().optional(),
  page: z.number().int().min(1).default(1),
  limit: z.number().int().min(1).max(PAGE_LIMIT_MAX).default(PAGE_LIMIT_DEFAULT),
})
export type ParkingListFilters = z.input<typeof ParkingListFiltersSchema>

export const ParkingCreateSchema = ParkingSchema.omit({ id: true, updatedAt: true })
export type ParkingCreate = z.infer<typeof ParkingCreateSchema>
export const ParkingUpdateSchema = ParkingCreateSchema.partial()
export type ParkingUpdate = z.infer<typeof ParkingUpdateSchema>

export const ParkingResponseSchema = single(ParkingSchema)
export const ParkingListResponseSchema = paginated(ParkingSchema)
```

```ts
// src/features/Parking/api/parkingApi.ts
import { api } from '@/shared/api/client'
import { EmptyResponseSchema } from '@/shared/api/schemas/common'
import type { ParkingId } from '@/shared/types/ids'

import {
  ParkingListResponseSchema,
  ParkingResponseSchema,
  type ParkingCreate,
  type ParkingListFilters,
  type ParkingUpdate,
} from './parkingSchemas'

const BASE = '/parkings'
const detailPath = (id: ParkingId) => `${BASE}/${encodeURIComponent(id)}`

export function getParkingList(filters: ParkingListFilters, signal?: AbortSignal) {
  return api.get(BASE, ParkingListResponseSchema, { query: filters, signal })
}
export function getParking(id: ParkingId, signal?: AbortSignal) {
  return api.get(detailPath(id), ParkingResponseSchema, { signal })
}
export function createParking(body: ParkingCreate) {
  return api.post(BASE, ParkingResponseSchema, { body })
}
export function updateParking(id: ParkingId, body: ParkingUpdate) {
  return api.patch(detailPath(id), ParkingResponseSchema, { body })
}
export function deleteParking(id: ParkingId) {
  return api.delete(detailPath(id), EmptyResponseSchema)
}
```

**[API-26] MUST:** A feature's API functions live in `api/<name>Api.ts`, one function per
endpoint, returning the parsed `data` type (or the envelope for lists), taking typed
parameters, and containing no React, no state and no UI text.
> **Why:** Pure functions are testable with MSW alone and reusable from queries, mutations,
> loaders and workers. The reference codebase's `hooks/api.ts` name misleads: it has no hooks.

**[API-27] MUST:** Path parameters are passed through `encodeURIComponent`; ids are branded
types ([TS-10]) so a `VehicleId` cannot be interpolated into a parking path.
> **Why:** An id containing `/` (some legacy municipal codes do) becomes a different route.

---

## 7. Status-code handling

| Status | Client behaviour | UI behaviour | Rule |
|---|---|---|---|
| 401 | `onUnauthorized()` single-flight refresh, replay once, else throw | Auth feature logs out ([AUTH-07]) | [API-28] |
| 403 | throw, `isForbidden` | Permission message, no retry button | [API-29] |
| 404 (detail) | throw, `isNotFound` | Route-level not-found state | [API-30] |
| 409 / 422 | throw, `isValidation`, `fieldErrors()` | Field errors into the form | [API-31] |
| 429 | GET: wait `Retry-After` (cap 10 s), retry; others: throw with `retryAfterMs` | "Try again in N s" | [API-32] |
| 500 | throw | Generic message + request id + retry | [API-33] |
| 502 / 503 / 504 | GET: backoff retry x2; others: throw | Generic message + request id + retry | [API-33] |
| network / timeout | GET: retry (network only); timeout throws | "Check connection" + retry | [API-06], [API-10] |

**[API-28] MUST:** On 401 the client awaits the configured `onUnauthorized()` (the auth
feature's single-flight refresh, [AUTH-05]) and replays the request exactly once with the same
request id; a second 401 is thrown and the auth feature performs logout ([AUTH-07]). Auth
endpoints pass `skipAuthRefresh: true`.
> **Why:** Ten queries expiring together must trigger one refresh, not ten (single-flight).
> The refresh endpoint itself must not trigger refresh on its own 401 or the client deadlocks
> waiting on the promise it is part of.

**[API-29] MUST:** 403 is never refreshed, retried or hidden; `error.isForbidden` renders a
permission message naming the action, and the UI element that triggered it is hidden or
disabled on the next render via the permission check ([AUTH-11]).
> **Why:** A 403 after a permission check passed means the check is stale; hiding the error
> hides the drift. Refreshing on 403 (the reference `refreshOnce` treats 403 like 401) logs
> out users who merely lack one permission.

**[API-30] MUST:** A 404 on a detail request renders the route's not-found state
([RTE-14]); it is not a toast and not reported to the error tracker.
> **Why:** Stale links to deleted records are normal traffic, not errors.

**[API-31] MUST:** 409 and 422 responses feed `error.fieldErrors()` into the form's
`setError(field, ...)` ([FORM-09]); errors without a field go to the form-level message.
> **Why:** A toast saying "validation failed" next to a 12-field form is not actionable.

**[API-32] MUST:** `Retry-After` on 429 is honoured (capped at 10 s) for the automatic GET
retry; for mutations the UI shows the remaining seconds from `error.retryAfterMs` and disables
the submit button for that duration.
> **Why:** Retrying a rate-limited request immediately extends the block.

**[API-33] MUST:** Any 5xx that reaches the UI shows the generic server-error message, the
request id, and a retry action; the raw message and status are logged, not rendered.
> **Why:** [GEN-15] and [GEN-17]. The request id is what support needs; "Internal Server
> Error" is what the user gets otherwise, in the wrong language.

---

## 8. Cancellation

**[API-34] MUST:** Every read function accepts `signal?: AbortSignal` as its last parameter
and forwards it; `queryFn` passes TanStack Query's `signal` ([STA-16]).
> **Why:** A user typing in a search box fires six list requests; without the signal all six
> complete, six JSON bodies parse, and the last to *arrive* (not the last sent) wins. With the
> signal, the five stale ones are aborted at the socket. Verify in DevTools: Network shows
> `(canceled)` for the superseded requests.

---

## 9. Uploads

```ts
// src/shared/api/upload.ts (excerpt; XHR is the only way to get upload progress events)
import type { z } from 'zod'

import { ApiError } from './errors'
import { parseResponse } from './parseResponse'

export const UPLOAD_MAX_BYTES_DEFAULT = 10 * 1024 * 1024

export interface UploadOptions {
  file: File
  fieldName?: string | undefined
  maxBytes?: number | undefined
  /** Extension allowlist without dots, lower case. Checked with the MIME type, not instead of it. */
  allowedExtensions: readonly string[]
  allowedMimeTypes: readonly string[]
  onProgress?: ((fraction: number) => void) | undefined
  signal?: AbortSignal | undefined
}

export function validateFile(o: UploadOptions, requestId: string): void {
  const ext = o.file.name.split('.').pop()?.toLowerCase() ?? ''
  if (o.file.size === 0) throw ApiError.invalidResponse('upload', 'empty file', requestId)
  if (o.file.size > (o.maxBytes ?? UPLOAD_MAX_BYTES_DEFAULT)) throw new ApiError({ kind: 'http', status: 413, code: 'FILE_TOO_LARGE', message: 'File exceeds limit', requestId })
  if (!o.allowedExtensions.includes(ext) || !o.allowedMimeTypes.includes(o.file.type)) {
    throw new ApiError({ kind: 'http', status: 415, code: 'FILE_TYPE_NOT_ALLOWED', message: `${ext}/${o.file.type}`, requestId })
  }
}

export function upload<S extends z.ZodType>(path: string, schema: S, o: UploadOptions): Promise<z.output<S>> {
  const requestId = crypto.randomUUID()
  validateFile(o, requestId)
  const form = new FormData()
  form.append(o.fieldName ?? 'file', o.file, o.file.name)
  return new Promise((resolve, reject) => {
    const xhr = new XMLHttpRequest()
    xhr.open('POST', path)           // base URL prefixing and credentials are identical to client.ts
    xhr.withCredentials = true
    xhr.setRequestHeader('X-Request-Id', requestId)
    xhr.upload.onprogress = (ev) => { if (ev.lengthComputable) o.onProgress?.(ev.loaded / ev.total) }
    xhr.onerror = () => reject(ApiError.fromNetwork(new TypeError('network'), requestId))
    xhr.onload = () => {
      if (xhr.status >= 400) { reject(ApiError.fromResponse(new Response(xhr.response as string, { status: xhr.status }), requestId)); return }
      try { resolve(parseResponse(schema, { endpoint: `POST ${path}`, requestId })(JSON.parse(xhr.responseText))) }
      catch (e: unknown) { reject(e) }
    }
    o.signal?.addEventListener('abort', () => xhr.abort(), { once: true })
    xhr.send(form)
  })
}
```

(The `xhr.response as string` cast above is the one permitted `as` in this module because
`responseType` is left at `''`, which the DOM lib types as `any`; it is annotated in the real
file with the reason. Do not copy the pattern elsewhere.)

**[API-35] MUST:** File uploads go through `upload()` in `src/shared/api/upload.ts`, which
validates size and type (extension **and** MIME) before sending, reports progress, and parses
the response with a schema like every other call. The server re-validates ([SEC-11]).
> **Why:** A 200 MB drag-and-drop with no client check burns the user's upstream for a minute
> before a 413. MIME alone is spoofable and extension alone is a lie; both together catch
> honest mistakes, and the server catches the rest.

**[API-36] MUST:** Default upload limit is 10 MB; a feature may raise it per call up to 100 MB
with a comment stating the use case; above that the file is not uploaded from the browser in
one request (see Open questions).
> **Why:** Cloudflare-style proxies and the nginx `client_max_body_size` in [NGX-12] agree on
> 100 MB; a single request above that fails at the edge regardless of what the app does.

---

## 10. OpenAPI versus hand-written zod

**[API-37] MUST:** Hand-written zod schemas are the source of truth for DTOs. OpenAPI type
generation is adopted only when the backend publishes a versioned spec and the generator is
approved in [02](02-TECH-VERSIONS.md); generated types are then used only in `satisfies`
checks against the zod schemas (`ParkingSchema satisfies z.ZodType<components['schemas']['Parking']>`)
and never as runtime types.
> **Why:** Generated types are compile-time promises; the wire is runtime. The `satisfies`
> check turns a spec change into a type error next to the schema, which is the right place,
> while the zod schema still guards production. Generated files follow [STR-29].

---

## 11. Logging API errors

**[API-38] MUST:** API errors are logged through `src/shared/lib/logger.ts` ([OBS-11]) with
exactly these fields: `method`, `path` (no query string), `status`, `code`, `kind`,
`requestId`, `durationMs`. Request bodies, response bodies, query values, headers and the
backend `message` are never logged from the browser.
> **Why:** A query string carries the TCKN (Turkish national id, 11 digits) the clerk just
> searched for; a body carries a citizen's address. Browser logs end up in the error tracker
> and in screenshots. The request id lets the backend log, which is access-controlled, hold
> the details.

---

## 12. MSW handlers

```ts
// src/features/Parking/api/parkingHandlers.ts (test-only; aggregated by src/test/msw/handlers.ts)
import { HttpResponse, http } from 'msw'

import { parkingFixtures } from './parkingFixtures'

export const parkingHandlers = [
  http.get('/api/parkings', ({ request }) => {
    const limit = Number(new URL(request.url).searchParams.get('limit') ?? 20)
    return HttpResponse.json({ data: parkingFixtures.slice(0, limit), meta: { page: 1, limit, total: parkingFixtures.length } })
  }),
  http.get('/api/parkings/:id', ({ params }) => {
    const item = parkingFixtures.find((p) => p.id === params['id'])
    return item ? HttpResponse.json({ data: item }) : HttpResponse.json({ error: { code: 'PARKING_NOT_FOUND', message: 'nope' } }, { status: 404 })
  }),
]
```

**[API-39] MUST:** Each feature ships `api/<name>Handlers.ts` and `api/<name>Fixtures.ts`;
fixtures are asserted to pass the feature's zod schemas in a test
(`expect(ParkingSchema.safeParse(fixture).success).toBe(true)`), and the aggregated handler
list in `src/test/msw/handlers.ts` is the network for every component test ([TEST-09]).
> **Why:** A fixture that does not satisfy the schema tests a UI that can never render in
> production. Colocation keeps the handler next to the schema it must satisfy, so the schema
> change and the handler change are the same diff.

---

## Open questions

- **Cursor pagination `meta` shape.** Assumed `{ nextCursor: string | null, limit }`. Not yet in
  the backend standard's success envelope. Decided when the first cursor endpoint ships;
  `CursorMetaSchema` is added to `schemas/common.ts` then.
- **Idempotency keys for mutations.** [API-09] forbids retrying mutations because the backend
  does not accept an `Idempotency-Key` header. If the backend standard adopts one, `POST` gains
  the same retry policy as `GET` with the key held constant across attempts.
- **Uploads above 100 MB.** Chunked or resumable upload (tus or S3 multipart) needs a backend
  endpoint and a library not in [02](02-TECH-VERSIONS.md). Decided when a feature needs it;
  until then the UI refuses the file with a clear message.
- **OpenAPI generator choice.** `openapi-typescript` is the candidate; not in the table until
  the backend publishes a spec ([API-37]).
