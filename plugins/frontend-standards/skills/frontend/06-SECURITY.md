# 06 — Security

> Everything the browser receives is public and everything it sends is forgeable. This file
> governs how the SPA avoids executing untrusted content (XSS), what the Content Security
> Policy is, how sessions and CSRF work from the browser side, what may never be put into
> `VITE_*`/`config.js`, how third-party code and iframes are contained, and how the build
> output and dependency chain are hardened. Read it when you touch HTML injection, links
> built from data, popups on the map, tokens, uploads, iframes, headers, or `package.json`.

---

## 1. XSS surfaces in React

React escapes text children and attribute values. That leaves a short list of places where
a string from outside becomes markup or code. Each one is a rule.

**[SEC-01] MUST:** DOMPurify is the only permitted path to `dangerouslySetInnerHTML`. The
prop is used in exactly one file, `src/shared/components/SafeHtml.tsx`, which sanitises with
an explicit allow-list; the lint config forbids the prop everywhere else.
> **Why:** A rich-text description from the CMS, a notification body from the backend, a
> "formatted" address: each one is a string somebody else controls. One `<img onerror>` in
> any of them runs with the user's session. Sanitising at one choke point can be reviewed;
> sanitising at forty call sites cannot. Detail: [02](02-TECH-VERSIONS.md) §2 (`dompurify` 3.x).

```tsx
// src/shared/components/SafeHtml.tsx
import DOMPurify from 'dompurify'
import { useMemo } from 'react'

// Two profiles. 'text' is for backend-formatted snippets; 'rich' is for CMS bodies.
const PROFILES = {
  text: { ALLOWED_TAGS: ['b', 'strong', 'i', 'em', 'br', 'span'], ALLOWED_ATTR: [] },
  rich: {
    ALLOWED_TAGS: ['p', 'br', 'strong', 'em', 'ul', 'ol', 'li', 'a', 'h2', 'h3', 'blockquote'],
    ALLOWED_ATTR: ['href', 'title'],
  },
} as const

// Only web protocols and relative paths survive in href. `javascript:` and `data:` are dropped.
const ALLOWED_URI_REGEXP = /^(?:https?:|mailto:|tel:|\/(?!\/))/i

DOMPurify.addHook('afterSanitizeAttributes', (node) => {
  if (node.tagName === 'A') {
    node.setAttribute('rel', 'noopener noreferrer')
    node.setAttribute('target', '_blank')
  }
})

type SafeHtmlProps = {
  html: string
  profile?: keyof typeof PROFILES
  className?: string
}

export function SafeHtml({ html, profile = 'text', className }: SafeHtmlProps) {
  const clean = useMemo(
    () => DOMPurify.sanitize(html, { ...PROFILES[profile], ALLOWED_URI_REGEXP }),
    [html, profile],
  )
  // eslint-disable-next-line no-restricted-syntax -- the single permitted use, see [SEC-01]
  return <div className={className} dangerouslySetInnerHTML={{ __html: clean }} />
}
```

```js
// eslint.config.js (excerpt). No eslint-plugin-react in the table, so core rules do the job.
{
  files: ['src/**/*.{ts,tsx}'],
  ignores: ['src/shared/components/SafeHtml.tsx'],
  rules: {
    'no-restricted-syntax': ['error',
      { selector: "JSXAttribute[name.name='dangerouslySetInnerHTML']",
        message: 'Use <SafeHtml> ([SEC-01])' },
      { selector: "JSXAttribute[name.name='srcDoc']",
        message: 'srcdoc renders raw HTML; forbidden ([SEC-04])' },
      { selector: "JSXOpeningElement[name.name='a']:has(JSXAttribute[name.name='target'][value.value='_blank']):not(:has(JSXAttribute[name.name='rel']))",
        message: 'target=_blank needs rel="noopener noreferrer" ([SEC-27])' },
    ],
    'no-restricted-properties': ['error',
      { property: 'innerHTML', message: 'Use <SafeHtml> ([SEC-04])' },
      { property: 'outerHTML', message: 'Forbidden ([SEC-04])' },
      { property: 'insertAdjacentHTML', message: 'Forbidden ([SEC-04])' },
      { object: 'document', property: 'write', message: 'Forbidden ([SEC-04])' },
      { property: 'setHTML', message: 'MapLibre popups use setDOMContent ([SEC-03])' },
    ],
    'no-eval': 'error', 'no-implied-eval': 'error', 'no-new-func': 'error',
  },
}
```

**[SEC-02] MUST:** Any `href`, `src`, `action` or `formAction` built from data (API response,
URL param, user input) passes through `safeHref()` from `src/shared/utils/safeHref.ts`, which
returns `undefined` for anything that is not `http(s):`, `mailto:`, `tel:` or a single-slash
relative path.
> **Why:** `<a href={item.url}>` with `item.url = "javascript:fetch('/api/auth/logout')"`
> is a click-to-execute link. React does not block it (it only warns in development). The
> same applies to `<img src>`, `<iframe src>` and `<form action>`.

```ts
// src/shared/utils/safeHref.ts
const SAFE_PROTOCOLS = new Set(['http:', 'https:', 'mailto:', 'tel:'])
const MAX_URL_LENGTH = 2048

/** Returns a URL safe to place in href/src, or undefined when the input must not be linked. */
export function safeHref(input: string | null | undefined): string | undefined {
  if (!input) return undefined
  const value = input.trim()
  if (value.length === 0 || value.length > MAX_URL_LENGTH) return undefined
  // Relative path on our own origin. "//host" (protocol-relative) is rejected on purpose.
  if (value.startsWith('/') && !value.startsWith('//') && !value.startsWith('/\\')) return value
  try {
    const url = new URL(value)
    return SAFE_PROTOCOLS.has(url.protocol) ? url.href : undefined
  } catch {
    // Not parseable as an absolute URL and not a clean relative path: do not link it.
    return undefined
  }
}
```

**[SEC-03] MUST:** MapLibre popups and DOM markers receive React content through
`setDOMContent` with a portal, never through `setHTML` with a template string containing
feature properties.
> **Why:** `popup.setHTML(\`<b>${props.name}</b>\`)` is `innerHTML` with a nicer name. Feature
> properties come from GeoJSON and tiles, which come from imports, other systems and users.
> MapLibre *expressions* (`['get', 'name']` in `text-field`) are safe: they render glyphs on
> the GPU, never HTML. The popup is the only HTML path on the map. Detail: [08](08-MAP-MAPLIBRE.md) §6.

```tsx
// WRONG
map.on('click', 'parking-points', (e) => {
  const p = e.features?.[0]?.properties
  new maplibregl.Popup().setLngLat(e.lngLat).setHTML(`<b>${p?.name}</b><br>${p?.address}`).addTo(map)
})

// RIGHT: src/shared/map/MapPopup.tsx
import maplibregl, { type LngLatLike } from 'maplibre-gl'
import { useEffect, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'

import { useMap } from '@/shared/map/useMap'

type MapPopupProps = { lngLat: LngLatLike; onClose: () => void; children: ReactNode }

export function MapPopup({ lngLat, onClose, children }: MapPopupProps) {
  const map = useMap()
  const [container] = useState(() => document.createElement('div'))

  useEffect(() => {
    const popup = new maplibregl.Popup({ closeOnClick: false, maxWidth: '320px' })
      .setLngLat(lngLat)
      .setDOMContent(container)
      .addTo(map)
    popup.on('close', onClose)
    return () => { popup.remove() }
  }, [map, container, lngLat, onClose])

  return createPortal(children, container)
}
// Usage: <MapPopup lngLat={sel.lngLat} onClose={clear}><ParkingCard parking={sel} /></MapPopup>
```

**[SEC-04] MUST NOT:** `innerHTML`, `outerHTML`, `insertAdjacentHTML`, `document.write`,
`srcdoc`, or `Range.createContextualFragment` in application code. The lint config in
[SEC-01] enforces the list.
> **Why:** Each is `dangerouslySetInnerHTML` without the warning label. Third-party wrappers
> that need them live in `src/shared/lib/` behind a reviewed comment, not in features.

**[SEC-05] MUST NOT:** `eval`, `new Function`, `setTimeout`/`setInterval` with a string
argument, or dynamic `import()` of a URL built from data.
> **Why:** The CSP in [SEC-06] blocks all of these at runtime (`script-src` without
> `'unsafe-eval'`), so code that uses them fails in production and works in development. Lint
> catches it before that.

---

## 2. Content Security Policy

**[SEC-06] MUST:** Production responses for `index.html` carry this CSP. The policy text is
owned by this file; the nginx `add_header` mechanics (the `always` flag, inheritance in nested
`location` blocks, the `map` for report-only) are owned by [12](12-NGINX.md) [NGX-10].

```nginx
# deployments/main/nginx/default.conf.template (excerpt). Rendered by envsubst; ${APP_HOST}
# is the public hostname so connect-src can be exact. See [NGX-10] for placement rules.
set $csp "default-src 'self'; \
  script-src 'self'; \
  style-src 'self' 'unsafe-inline'; \
  img-src 'self' data: blob:; \
  font-src 'self'; \
  connect-src 'self' wss://${APP_HOST}; \
  worker-src 'self' blob:; \
  frame-src 'none'; \
  frame-ancestors 'none'; \
  object-src 'none'; \
  base-uri 'self'; \
  form-action 'self'; \
  manifest-src 'self'; \
  report-uri /csp-report";
```

Directive by directive, and what breaks if you loosen or tighten it:

| Directive | Value | Reason |
|---|---|---|
| `default-src` | `'self'` | Everything not listed falls back to own origin. [GEN-22] makes every service same-origin, so nothing else is needed. |
| `script-src` | `'self'` | Bundle only. No `'unsafe-inline'`, no `'unsafe-eval'`, no CDN ([SEC-14]). Any inline `<script>` in `index.html` is blocked; the reference repo's inline context-menu script moves into `main.tsx`. |
| `style-src` | `'self' 'unsafe-inline'` | Accepted, see below. |
| `img-src` | `'self' data: blob:` | Vite inlines assets under `build.assetsInlineLimit` (4 KB) as `data:` URIs; file previews use `URL.createObjectURL` (`blob:`); raster tiles and sprites come through the proxy (`'self'`). |
| `font-src` | `'self'` | Fonts are self-hosted under `public/fonts/` ([PERF-xx]). Google Fonts is a third-party origin and is forbidden ([SEC-14]). |
| `connect-src` | `'self' wss://<host>` | `fetch`, XHR, EventSource, WebSocket. `'self'` covers `wss:` on the same host in CSP3 but Safari has been inconsistent, so the host is listed explicitly. Never a bare `wss:` scheme. |
| `worker-src` | `'self' blob:` | MapLibre spawns its worker from a `blob:` URL created from the bundled worker code. Without `blob:` the map is blank with a console error. |
| `frame-src` | `'none'` | Raised to a specific origin only when [SEC-14]'s iframe exception applies. |
| `frame-ancestors` | `'none'` | Clickjacking. Set to a specific origin only if the app is legitimately embedded (a municipality portal embedding the map). |
| `object-src` | `'none'` | No Flash-era plugins, no `<object data="user.svg">`. |
| `base-uri` | `'self'` | An injected `<base href>` would redirect every relative asset. |
| `form-action` | `'self'` | A form cannot be retargeted to an attacker host even if markup is injected. |
| `report-uri` | `/csp-report` | Proxied to the backend or a collector by nginx. `report-to` is added when the collector supports the Reporting API; browsers still honour `report-uri`. |

**Why `'unsafe-inline'` for styles is accepted, and what would remove it.** React's `style`
prop and MapLibre's markers and popups set styles through the CSSOM (`el.style.x = ...`),
which CSP does not block; Tailwind emits one static CSS file; Vite production builds emit
`<link>` tags. None of these need it. What needs it: `react-hot-toast` (via `goober`) and
`@codemirror/view` (via `style-mod`) inject `<style>` elements at runtime. A nonce would
allow them (CodeMirror exposes `EditorView.cspNonce`), but a nonce needs a per-request
`index.html` ([SEC-09]). Until then, `style-src 'unsafe-inline'` stays. Its risk is CSS-based
data exfiltration (attribute selectors leaking form values to `url()` fetches), which
`connect-src`/`img-src 'self'` already contain. Removing it requires: a nonce ([SEC-09]) or
replacing `react-hot-toast` with a CSS-file toast and passing a nonce to CodeMirror.

**[SEC-07] MUST:** `connect-src` lists only origins the app actually connects to. If a
service cannot be proxied (a WebRTC signalling host on another IP, an external tile provider
approved in `02`), its exact origin is added and the reason is a comment in the nginx template.
> **Why:** A wide `connect-src` turns an XSS into a data-exfiltration channel. The list is
> also documentation: it is the complete set of hosts the browser talks to.

**[SEC-08] MUST:** A new or changed CSP ships first as `Content-Security-Policy-Report-Only`
for at least one release cycle with reports collected, then switches to enforcing. A CSP that
has never been report-only does not go to production.
> **Why:** The map worker, a PDF export font, a `blob:` preview: each one is a directive you
> forget until a user hits it. Report-only shows the violations without breaking anything.
> Verify: `curl -sI https://<host>/ | grep -i content-security-policy` shows one header, the
> right one.

**[SEC-09] MUST NOT:** Nonce- or hash-based `script-src` while `index.html` is a static file.
There is no inline script to protect, and a nonce baked into a static file is not a nonce.
> **Why:** The nonce is only meaningful when it changes per response. nginx `sub_filter` can
> inject `$request_id` into a placeholder, but it disables `brotli_static`/`gzip_static` and
> `sendfile` for that file and adds a second place where `index.html` is edited. **This
> decision flips** the day the app adopts request-time meta injection or SSR
> ([10](10-SEO-RENDERING.md) tier 2/3): at that point `index.html` is rendered per request,
> a nonce is generated there, `'unsafe-inline'` is removed from `style-src`, and inline JSON
> state blocks get `nonce={...}`.

---

## 3. Other security headers

**[SEC-10] MUST:** Every response from the frontend nginx carries these headers. Values are
owned here; placement is [NGX-10].

```nginx
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
# List only what the app uses. A GIS app uses geolocation; nothing here uses camera or payment.
add_header Permissions-Policy "geolocation=(self), camera=(), microphone=(), payment=(), usb=(), interest-cohort=()" always;
# Legacy fallback for frame-ancestors. Harmless where CSP is understood.
add_header X-Frame-Options "DENY" always;
add_header Cross-Origin-Opener-Policy "same-origin" always;
```

- `Strict-Transport-Security: max-age=31536000; includeSubDomains` is set **only by the
  component that terminates TLS**. If this nginx is behind an edge proxy that terminates TLS,
  the edge sets it and this nginx does not; two HSTS headers with different values is a
  configuration bug. If this nginx has the certificate, it sets it and `upgrade-insecure-requests`
  is appended to the CSP.
- `Cross-Origin-Opener-Policy: same-origin` severs `window.opener` for pages this app opens
  and pages that open it. It breaks popup-based OIDC flows; the standard uses redirect flows
  ([AUTH-22]), so it is safe. Downgrade to `same-origin-allow-popups` with a written reason if
  a popup flow is unavoidable.
- `X-XSS-Protection` is not set. It is removed from modern browsers and introduced
  vulnerabilities in old ones.

**[SEC-11] MUST:** Headers are verified after every nginx change with `curl` and the output
is pasted into the PR. Expected output for a production host:

```bash
curl -sI https://gis.example.gov.tr/ | grep -iE '^(content-security-policy|x-content-type-options|referrer-policy|permissions-policy|x-frame-options|cross-origin-opener-policy|strict-transport-security|cache-control):'
# content-security-policy: default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; ...
# x-content-type-options: nosniff
# referrer-policy: strict-origin-when-cross-origin
# permissions-policy: geolocation=(self), camera=(), ...
# x-frame-options: DENY
# cross-origin-opener-policy: same-origin
# strict-transport-security: max-age=31536000; includeSubDomains     (only at the TLS terminator)
# cache-control: no-cache                                             ([GEN-12])

curl -sI https://gis.example.gov.tr/config.js | grep -i cache-control
# cache-control: no-store                                             ([SEC-13])

curl -sI https://gis.example.gov.tr/assets/index-Ab12Cd34.js.map
# HTTP/2 404                                                          ([SEC-22])
```

---

## 4. Secrets and runtime configuration

**[SEC-12] MUST NOT:** Anything private in a `VITE_*` variable, in `/config.js`, in source or
in the bundle. `VITE_*` values are string-replaced into the JavaScript; `/config.js` is a
public URL. Both are readable by anyone with DevTools, and both end up in error-tracker
breadcrumbs and browser caches. This restates [GEN-10] with the list of things people put
there anyway:

| Seen in the wild | Why it is a leak | The fix |
|---|---|---|
| `VITE_MQTT_USERNAME` / `VITE_MQTT_PASSWORD` | Anyone can publish to every topic the broker allows that user | Backend endpoint issues a short-lived, topic-scoped token ([SEC-19], [RT-xx]) |
| A map/geocoding API key with billing | Key is copied and your invoice grows | nginx proxies `/geocode/` and injects the key: `proxy_set_header Authorization "Bearer ${GEOCODER_KEY}"` from the container env; the browser never sees it |
| Superset / BI guest credentials | Full read of the warehouse | Backend mints a Superset guest token per user with row-level filters; the SPA passes only that |
| A "service" JWT for the tile server | Tiles for every tenant, forever | Tiles go through nginx on the same origin with the session cookie ([GEN-22]); the tile server validates it or nginx does `auth_request` |
| Error-tracker DSN with a *write* token | Attackers flood your issues | The public DSN is fine (it is designed to be public); never the auth token used for source-map upload |
| SMTP, database, S3 credentials "for the admin page" | Total compromise | Never. The admin page calls the backend. |

The rule of thumb: if rotating the value after a leak would be an incident, it does not go to
the browser. A key that must be restricted is restricted server-side (referrer allow-lists
are not a control; `Referer` is forgeable outside the browser).

**[SEC-13] MUST:** `/config.js` is served with `Cache-Control: no-store` and contains only
environment-level values: URLs, feature flags, public keys, timeouts. Never per-user or
per-tenant data, never anything derived from a request.
> **Why:** `no-store` (stricter than the `no-cache` floor of [GEN-12]) keeps a rotated URL or a
> flipped feature flag from surviving in a shared proxy cache. Per-user data in `config.js`
> would make it cacheable by user, which is a leak waiting for a misconfigured cache.
> Producing side: [11](11-DOCKER-COMPOSE.md) §3; header: [NGX-xx].

---

## 5. Third-party code and iframes

**[SEC-14] MUST NOT:** Load any script, style or font from a CDN or third-party origin. All
code is installed from npm and bundled ([GEN-03], [VER-05]). If a third-party *widget* (a BI
dashboard, a chatbot, a payment page) is unavoidable, it runs on its own origin inside an
`<iframe>` with a strict `sandbox` attribute, and that origin is added to `frame-src` and
nothing else.
> **Why:** A `<script src="https://cdn.example/lib.js">` executes with full access to the
> session, whatever `integrity` you add (the attribute helps only if you never update the
> file). Google Fonts leaks user IPs to a third party and is a GDPR/KVKK finding for a
> municipality. A CDN outage or a compromised package (polyfill.io, 2024) is your outage.
> The iframe boundary is the browser's only real isolation primitive.

```tsx
// src/features/Bi/components/BiFrame.tsx
// Third-party origin from runtime config; sandbox without allow-same-origin so the frame
// cannot read our cookies, storage or DOM even if it tries. allow-popups is omitted on purpose.
export function BiFrame({ src }: { src: string }) {
  return (
    <iframe
      src={src}
      title="BI dashboard"
      sandbox="allow-scripts allow-forms"
      referrerPolicy="no-referrer"
      loading="lazy"
      className="h-full w-full border-0"
    />
  )
}
```

`sandbox="allow-scripts allow-same-origin"` on a frame that is *actually* same-origin is not a
boundary: the frame can remove its own sandbox. A first-party service proxied under `/bi/`
(the reference repo's Superset) shares the origin by design; its protection is the proxy's
authentication, not the sandbox. A genuinely third-party widget gets its own origin.

**[SEC-15] MUST:** `postMessage` traffic checks `event.origin` against a single allowed origin
from runtime config on receive, passes the exact target origin on send (never `'*'`), and
parses every message with a zod schema before use.
> **Why:** Without the origin check, any page that can get a reference to your window (an
> ad in another tab that opened you) can send messages. Without the schema, the message is
> `any` flowing into state.

```ts
// src/features/Bi/lib/biMessages.ts
import { z } from 'zod'

export const BiMessageSchema = z.discriminatedUnion('type', [
  z.object({ type: z.literal('bi:resize'), height: z.number().int().min(0).max(20_000) }),
  z.object({ type: z.literal('bi:navigate'), path: z.string().regex(/^\/(?![/\\])/) }),
])
export type BiMessage = z.infer<typeof BiMessageSchema>

// src/features/Bi/hooks/useBiMessages.ts
export function useBiMessages(allowedOrigin: string, onMessage: (m: BiMessage) => void) {
  useEffect(() => {
    const handler = (e: MessageEvent) => {
      if (e.origin !== allowedOrigin) return
      const parsed = BiMessageSchema.safeParse(e.data)
      if (!parsed.success) {
        reportWarning('bi.message.invalid', { issues: parsed.error.issues.length })
        return
      }
      onMessage(parsed.data)
    }
    window.addEventListener('message', handler)
    return () => window.removeEventListener('message', handler)
  }, [allowedOrigin, onMessage])
}
// Sending: frame.contentWindow?.postMessage({ type: 'host:theme', theme }, allowedOrigin)
```

---

## 6. Sessions, tokens and CSRF (browser side)

The full auth flow is [19](19-AUTH-SESSION.md). This section fixes the security properties
the flow must have.

**[SEC-16] MUST:** Authentication state is a session cookie set by the gateway with
`HttpOnly; Secure; SameSite=Lax; Path=/api` (a `__Host-` prefix, which forces `Path=/`, is
acceptable when the size cost on static requests is accepted). The SPA never receives,
stores, decodes or forwards a token: no `localStorage`, no `sessionStorage`, no in-memory JWT,
no `Authorization` header set by application code.
> **Why:** A token in JavaScript is readable by any XSS, any compromised dependency and any
> browser extension, and it survives in `localStorage` after the tab closes. An `HttpOnly`
> cookie is invisible to script; the worst an XSS can do is act during the session, not steal
> it. `Path=/api` keeps the cookie off asset requests. Detail: [AUTH-01], [ADR-0017](adr/0017-auth-token-storage.md).

**[SEC-17] MUST:** Every request from `src/shared/api/client.ts` carries
`X-Requested-With: XMLHttpRequest`, and state-changing requests are never `GET`. The gateway
rejects state-changing requests that lack the header or whose `Origin`/`Sec-Fetch-Site` does
not match. Together with `SameSite=Lax` this is the CSRF defence; there is no CSRF token in
the SPA.
> **Why:** Three independent layers. `SameSite=Lax` stops the browser from attaching the
> cookie to cross-site `POST`s. The custom header cannot be added by a cross-origin page
> without a CORS preflight, which the gateway does not answer. The origin check catches
> browsers with `SameSite` quirks. A synchroniser token would be a fourth layer that costs an
> extra request and a place to leak; not worth it on a same-origin design ([GEN-22]).

**[SEC-18] MUST:** Redirect targets that come from the URL (`returnTo`, `next`, `redirect`)
are accepted only as same-document relative paths, validated by `safeReturnTo()`; anything
else falls back to `/`.
> **Why:** `/login?returnTo=https://evil.example/login` after a successful login is a
> phishing page with your domain in the user's history. `//evil.example` and `/\evil.example`
> are the classic bypasses of a "starts with slash" check.

```ts
// src/shared/utils/safeReturnTo.ts
const MAX_LENGTH = 2048
const BLOCKED_PREFIXES = ['/login', '/logout', '/auth/']
// eslint-disable-next-line no-control-regex -- rejecting control characters is the point
const CONTROL_CHARS = /[\x00-\x1f\x7f]/

/** Accepts "/parking/12?tab=history". Rejects absolute URLs, protocol-relative, backslash tricks, auth pages. */
export function safeReturnTo(raw: string | null | undefined, fallback = '/'): string {
  if (!raw || raw.length > MAX_LENGTH) return fallback
  if (!/^\/(?![/\\])/.test(raw)) return fallback
  if (CONTROL_CHARS.test(raw)) return fallback
  if (BLOCKED_PREFIXES.some((p) => raw.startsWith(p))) return fallback
  return raw
}
```

**[SEC-19] MUST:** WebSocket and MQTT connections authenticate with a short-lived credential
fetched from the backend (`POST /api/realtime/token`, lifetime ≤ 15 minutes, scoped to the
topics the user may read), never with a static username/password from config. Reconnects
fetch a fresh credential.
> **Why:** The broker cannot read the session cookie's meaning, so a bearer credential is
> unavoidable there; the fix is to make it short, scoped and per user. A static broker
> password in `config.js` is a published string ([SEC-12]). Lifecycle: [RT-xx].

---

## 7. Dependencies and supply chain

**[SEC-20] MUST:** The dependency chain is gated by: a committed lockfile with `npm ci`
([VER-04]), `ignore-scripts=true` in `.npmrc` for CI and Docker ([VER-09]),
`npm audit --audit-level=high` in CI ([CI-08]), and `npm audit signatures` in CI to verify
registry signatures and provenance attestations for packages that publish them.
> **Why:** Lifecycle scripts are how most npm compromises execute (they run at install, before
> any code review). A lockfile without `npm ci` is decorative. `npm audit signatures` fails
> when a package's tarball does not match what the registry signed, which catches a poisoned
> mirror or a tampered cache.

```ini
# .npmrc (repo root)
ignore-scripts=true
engine-strict=true
fund=false
```

**[SEC-21] MUST:** Third-party GitHub Actions (or the equivalent in another CI) are pinned to
a full commit SHA with the version as a trailing comment, never to a mutable tag.
> **Why:** A tag can be moved to a malicious commit by whoever controls the action's repo
> (tj-actions/changed-files, March 2025). The SHA cannot. Pipeline detail: [14](14-GIT-CI.md) [CI-xx].

```yaml
- uses: actions/checkout@11bd71901bbe5b1630ceea73d27597364c9af683 # v4.2.2
- uses: actions/setup-node@39370e3970a6d050ad2a8bc5a95b5d6b9a5a0c48 # v4.1.0
```

---

## 8. Build output

**[SEC-22] MUST:** Source maps are generated with `build.sourcemap: 'hidden'`, uploaded to
the error tracker in the build stage with the release id ([OBS-05]), then deleted before the
runtime image is assembled. nginx additionally returns 404 for `*.map` ([NGX-xx]) as a
second layer.
> **Why:** `'hidden'` omits the `//# sourceMappingURL` comment so browsers do not fetch maps,
> but the files still exist in `dist/`. Serving them publishes the unminified source, including
> comments that say things like `// TODO: this endpoint has no auth yet`. The tracker needs them
> to symbolicate; nobody else does.

```ts
// vite.config.ts (excerpt)
export default defineConfig({
  build: {
    sourcemap: 'hidden',
  },
})
```

```dockerfile
# deployments/main/Dockerfile (excerpt of the build stage). Maps leave the build context
# before the runtime stage copies dist/. The upload tool is an open question (see end).
RUN npm run build \
 && npx sentry-cli sourcemaps upload --release "$RELEASE" ./dist \
 && find ./dist -name '*.map' -delete
```

**[SEC-23] MUST:** `console.*` calls do not reach the production bundle. Application code
logs through `src/shared/lib/logger.ts`, which is a no-op in production except for `error`
(which forwards to the tracker); ESLint `no-console` is `error` outside that file. The build
additionally strips any `console`/`debugger` that slip through.
> **Why:** `console.log(response)` in a query hook prints every user's data to a DevTools
> panel that anyone at a shared kiosk can open, and stays in the bundle forever. The lint rule
> is the real control; the build option is the safety net.

```ts
// vite.config.ts (excerpt)
// Vite ≤ 7 used `esbuild: { drop: ['console', 'debugger'] }`. Vite 8 replaces esbuild with
// oxc for transforms. The equivalent option name in Vite 8 (`oxc.drop` or the rolldown
// minifier's compress options) MUST be verified against the Vite 8 docs at project setup;
// do not assume the esbuild key still works. If neither exists yet, the lint rule alone holds.
```

---

## 9. Errors, logs and personal data

**[SEC-24] MUST NOT:** Show a user any stack trace, internal hostname, upstream error body,
SQL fragment or request URL in an error message. Users see an i18n message plus the request id
from [API-xx] so support can find the server log.
> **Why:** `ECONNREFUSED 172.22.1.16:8889` in a toast is a network map for an attacker and
> noise for a citizen. The request id gives support everything the stack trace would, from the
> server side, where it belongs. Error UI rules: [17](17-ERRORS-OBSERVABILITY.md) §2.

**[SEC-25] MUST:** The error tracker is initialised with `sendDefaultPii: false` and a
`beforeSend` that removes cookies, `Authorization` headers, query strings containing `token`,
and scrubs Turkish identifiers (11-digit TCKN, 10-digit VKN) and e-mail addresses from
messages and breadcrumbs. The logger applies the same scrubber. Users are identified by
opaque id, never by name or e-mail.
> **Why:** A form validation error breadcrumb that contains the typed TCKN is personal data
> in a third-party (or at least another) system, with retention you do not control. KVKK
> treats that as processing without a basis. Tracker setup: [OBS-xx].

```ts
// src/shared/lib/scrubPii.ts
const PATTERNS: Array<[RegExp, string]> = [
  [/\b\d{11}\b/g, '[tckn]'],
  [/\b\d{10}\b/g, '[vkn]'],
  [/[\w.+-]+@[\w-]+\.[\w.-]+/g, '[email]'],
  [/([?&](?:token|access_token|code)=)[^&\s]+/gi, '$1[redacted]'],
]
export function scrubPii(text: string): string {
  return PATTERNS.reduce((acc, [re, repl]) => acc.replace(re, repl), text)
}
```

---

## 10. File uploads and downloads

**[SEC-26] MUST:** Client-side checks on uploads (`accept`, size, count) are UX, not
security; the server validates type by content, size and count, and the UI handles a 4xx from
the server as a normal field error ([FORM-21]). User-supplied SVG is never rendered inline
(`<svg>` via `SafeHtml`, `<object>`, `<iframe>`); it is shown only via `<img src>`, which does
not execute scripts. Download endpoints serve user files with
`Content-Disposition: attachment` and `X-Content-Type-Options: nosniff`, ideally from a
separate path with `Content-Security-Policy: sandbox`.
> **Why:** `accept=".pdf"` is a file-picker filter; the request body is whatever the sender
> wants. An SVG is an XML document that can contain `<script>`; inline it and it runs on your
> origin. `attachment` stops the browser from rendering an HTML file that was uploaded as
> "report.pdf".

---

## 11. Navigation, parsing and prototype safety

**[SEC-27] MUST:** `window.open(url, '_blank', 'noopener,noreferrer')` for programmatic
opens; `<a target="_blank" rel="noopener noreferrer">` in markup (lint in [SEC-01] checks it).
`url` goes through `safeHref()` first.
> **Why:** Without `noopener` the opened page gets `window.opener` and can navigate your tab to
> a phishing clone (reverse tabnabbing). Modern browsers imply `noopener` for `target=_blank`,
> but not for `window.open`, and the explicit attribute is what the reviewer can see.

**[SEC-28] MUST:** Data parsed from an untrusted source (`JSON.parse` of a URL parameter,
`localStorage`, `postMessage`, a file the user dropped) goes through a zod schema before it
touches state. `Object.assign(target, untrusted)` and spread-merging of query params into
objects are forbidden; keys are picked explicitly by the schema. Dictionaries keyed by
user-controlled strings use `Map` or `Object.create(null)`.
> **Why:** `{"__proto__": {"isAdmin": true}}` in a saved filter, merged with `Object.assign`,
> pollutes `Object.prototype` for the whole page. zod's `z.object()` strips unknown keys,
> including `__proto__`; a `Map` has no prototype to pollute. This is the same discipline as
> [GEN-07], applied to sources other than the API.

```ts
// WRONG: query params straight into state
const filters = { ...DEFAULT_FILTERS, ...Object.fromEntries(searchParams) }

// RIGHT: src/features/Parking/lib/parkingFilters.ts
const ParkingFiltersSchema = z.object({
  district: z.string().max(64).optional(),
  status: z.enum(['open', 'full', 'closed']).optional(),
  page: z.coerce.number().int().min(1).max(10_000).default(1),
})
export function parseParkingFilters(params: URLSearchParams) {
  return ParkingFiltersSchema.parse(Object.fromEntries(params)) // unknown keys are dropped
}
```

---

## 12. Security review checklist

Run through this on any PR that touches the listed areas. Each item names the rule so the
reviewer can quote it.

1. No `dangerouslySetInnerHTML` outside `SafeHtml.tsx`; no `innerHTML`/`setHTML` ([SEC-01], [SEC-03], [SEC-04]).
2. Every `href`/`src` built from data passes `safeHref()` ([SEC-02]).
3. No `eval`, `new Function`, string timers, CDN `<script>`, Google Fonts ([SEC-05], [SEC-14]).
4. CSP unchanged, or changed with a report-only cycle and a `curl -I` paste ([SEC-06], [SEC-08], [SEC-11]).
5. New network host? It is proxied same-origin, or it is in `connect-src` with a comment ([SEC-07], [GEN-22]).
6. New `VITE_*` or `config.js` key? It is public by definition; nothing on the [SEC-12] table.
7. No token in `localStorage`, `sessionStorage`, memory or an `Authorization` header set by app code ([SEC-16]).
8. All state-changing calls are non-GET through the shared client (header added automatically) ([SEC-17]).
9. Redirect params go through `safeReturnTo()` ([SEC-18]).
10. Realtime credentials are short-lived and fetched, not configured ([SEC-19]).
11. New dependency? Approved, in `02`, lockfile updated, `npm audit signatures` green ([GEN-03], [SEC-20]).
12. CI actions pinned by SHA ([SEC-21]).
13. No `console.*` outside the logger; no PII in log or tracker payloads ([SEC-23], [SEC-25]).
14. Uploads: server validates; no inline SVG; downloads are `attachment` ([SEC-26]).
15. `JSON.parse`/`postMessage`/query params parsed by zod; no `Object.assign` from untrusted ([SEC-15], [SEC-28]).

---

## Open questions

- **Source-map upload tool.** `@sentry/cli` (or `@sentry/vite-plugin`) is not in the `02`
  table. [SEC-22] assumes a CLI upload in the Docker build stage. Decide which package is
  approved and add it to `02` §3 in the same PR that wires the upload.
- **`console` stripping in Vite 8.** The rolldown/oxc option name replacing `esbuild.drop` is
  not confirmed against the pinned Vite 8.x. Verify at project setup; until then [SEC-23]
  relies on the lint rule and the logger wrapper.
- **CSP report collector.** `/csp-report` needs a receiver. Options: the backend gateway
  logging the JSON body, or the error tracker's CSP endpoint (Sentry-compatible backends
  accept `report-uri` with a DSN-derived path). Decide when the first report-only rollout
  happens.
- **`Cache-Control` for `/config.js`.** [GEN-12] says `no-cache`; this file requires the
  stricter `no-store` ([SEC-13]). [12](12-NGINX.md) should emit `no-store` for `/config.js`
  and `no-cache` for `index.html`; if the owners of `12` disagree, `no-cache` with `must-revalidate`
  is the minimum and this file's rule is relaxed.
