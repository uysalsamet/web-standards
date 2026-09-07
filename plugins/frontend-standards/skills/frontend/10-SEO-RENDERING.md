# 10 — SEO and Rendering

> A single-page application can rank, but only if the HTML that reaches a crawler describes
> the page that a human would see **today**. The core principle of this file: **the build
> artefact is a template, not content** ([GEN-11]). Titles, descriptions, canonicals,
> sitemaps and structured data for dynamic pages are produced at request time, never frozen
> into `dist/` by a build that ran last Tuesday. Read this before a public site's first
> deploy, and before anyone proposes fetching an API at build time.

Out of scope: the stack itself stays React + Vite ([GEN-01]); nginx directive syntax
([12](12-NGINX.md)); image and font budgets ([07](07-PERFORMANCE.md)); which keys the
locale lives under ([09](09-I18N.md)).

---

## 1. SEO tiers: decide once, write it down

Almost every SEO argument in a review is two people assuming different tiers. Classify the
product first.

| | Tier 0: authenticated app | Tier 1: public, static content | Tier 2: public, dynamic content |
|---|---|---|---|
| Example | The reference GIS product, an admin panel, a field-operations dashboard | A five-page municipal information site, a product brochure | A news/announcements portal, an events calendar, a service directory |
| Indexable pages | none | a known, small, fixed route list | unbounded, created by editors |
| Head tags | one static set in `index.html` | per route, prerendered at build | per request, from live data |
| Rendering | SPA only | SPA + build-time prerender (no API data) | SPA + request-time meta injection (§6) |
| `robots.txt` | `Disallow: /` | allow, static sitemap | allow, sitemap generated at request time |
| Extra runtime component | none | none | one Node sidecar (the injector) |
| Cost | zero | one prerender script | one more container to operate |

**[SEO-01] MUST:** Every app declares its SEO tier in `docs/README.md`, in one line, with
the indexable route patterns if the tier is 1 or 2. The tier decides the rendering strategy
and nothing else in this file applies until it is written down.
> **Why:** Without a declared tier, half the team adds meta tags "just in case" and the
> other half assumes Google renders JavaScript fine, and neither position is tested. The
> line in the README is also what tells the next engineer why an injector container exists.

**[SEO-02] MUST:** Tier 0 apps are excluded from indexing on three independent levels: a
`<meta name="robots" content="noindex, nofollow">` in `index.html`, a `robots.txt`
containing `User-agent: *` / `Disallow: /`, and an `X-Robots-Tag: noindex, nofollow`
response header from nginx.
> **Why:** An internal dashboard behind a login still leaks its route names, screenshots and
> error pages into the index if it is reachable without a session at any point (a staging
> host, a misconfigured gateway, a public health page). Three layers cost three lines and
> survive one of them being removed by accident. Header configuration: [12](12-NGINX.md) §4.

---

## 2. The build artefact is a template, not content

This is the failure this file exists to prevent, so it gets its own section.

**The failure story.** A municipality's news portal is built with Vite. To make the news
pages indexable, someone writes a build step that calls `GET /api/news?limit=200`, renders
200 HTML files with titles and descriptions baked in, and ships them inside the image. It
works on the day it is deployed: Google sees real titles, the pages rank. Nine days later
the editors have published 14 new articles, corrected two headlines and unpublished one
that named a person incorrectly. The container has not been rebuilt, because nothing in the
deploy pipeline is triggered by an editor pressing "publish". So:

- the 14 new articles have no HTML entry at all, and the sitemap in the image does not list
  them, so they are not discovered;
- the two corrected headlines are still served in `<title>` and `og:title` to crawlers and
  to anyone sharing the link on WhatsApp, while the visible page (rendered by React from
  the live API) shows the correct one, so the indexed title and the page content disagree;
- the unpublished article still has an indexed page returning HTTP 200 with a stale title
  and an empty body after hydration, which is a soft-404 and a legal problem at the same
  time.

None of this produces an error anywhere. The build is green, the health check is green, the
site looks correct to every human who visits it in a browser.

**[SEO-03] MUST NOT:** Fetch API data at build time and freeze it into `dist/`. This
includes prerendered HTML containing API content, generated `sitemap.xml` listing database
records, meta descriptions built from article bodies, and feature-flag values.
> **Why:** The build's freshness is the deploy interval, which is a property of the release
> process and not of the content. As soon as they differ, the HTML a crawler sees describes
> a page that no longer exists. Direct application of [GEN-11]; the request-time alternative
> is §6, the narrow exception with an ADR is [SEO-23].

Build-time content is fine when the content is part of the code: marketing copy in i18n
files, an "about us" page, a route list, the app's own name and default description. The
test is simple: **can this value change without a commit?** If yes, it may not be baked in.

---

## 3. Head tags per page

**[SEO-04] MUST:** Per-page `<title>`, `<meta>` and `<link>` tags are rendered as ordinary
React elements and hoisted to `<head>` by React 19. `react-helmet`, `react-helmet-async`
and any other head manager are forbidden ([VER-05]).

```tsx
// src/shared/components/PageHead.tsx
import { useRuntimeConfig } from '@/app/config/RuntimeConfigContext'

interface PageHeadProps {
  title: string          // already translated, without the site suffix
  description: string    // already translated, <= 160 characters
  path: string           // canonical path with the locale prefix, e.g. /tr/haberler/123-yeni-park
  locale: string
  image?: string         // absolute or root-relative; falls back to the site's default card
  robots?: 'index, follow' | 'noindex, follow' | 'noindex, nofollow'
}

export function PageHead({ title, description, path, locale, image, robots = 'index, follow' }: PageHeadProps) {
  const { siteUrl, siteName } = useRuntimeConfig()
  const canonical = new URL(path, siteUrl).toString()
  const cardImage = new URL(image ?? '/images/social-card.png', siteUrl).toString()

  // React 19 hoists title, meta and link out of the component tree into <head>.
  // The last mounted duplicate wins, so a nested route may override a layout's tag.
  return (
    <>
      <title>{`${title} | ${siteName}`}</title>
      <meta name="description" content={description} />
      <meta name="robots" content={robots} />
      <link rel="canonical" href={canonical} />

      <meta property="og:type" content="website" />
      <meta property="og:site_name" content={siteName} />
      <meta property="og:title" content={title} />
      <meta property="og:description" content={description} />
      <meta property="og:url" content={canonical} />
      <meta property="og:image" content={cardImage} />
      <meta property="og:locale" content={locale === 'tr' ? 'tr_TR' : 'en_US'} />

      <meta name="twitter:card" content="summary_large_image" />
      <meta name="twitter:title" content={title} />
      <meta name="twitter:description" content={description} />
      <meta name="twitter:image" content={cardImage} />
    </>
  )
}
```
> **Why:** `react-helmet` is unmaintained and not React 19 compatible; `react-helmet-async`
> is a second rendering path for something the framework now does natively. React 19's
> hoisting also deduplicates by tag identity, which is what makes a layout-level default
> overridable by a page. Note that this only fixes the head **after hydration**: a crawler
> that does not execute JavaScript still sees the template's head, which is why Tier 2 needs
> §6.

**[SEO-05] MUST:** Every indexable route renders exactly one `PageHead` with a unique title
in the form `<Page> | <Site>`, 60 characters or fewer including the suffix. Two indexable
routes never share a title.
> **Why:** Google truncates titles around 580 pixels, roughly 60 characters, and rewrites
> titles it considers unhelpful. Duplicate titles across a paginated list (`News | X` on
> pages 1 to 40) are the most common duplicate-content report in Search Console; add the
> distinguishing part (`News, page 3 | X`).

**[SEO-06] MUST:** The description comes from an i18n key or from the content's own summary
field, is at most 160 characters, and is never the first 160 characters of a raw HTML body.
A page with no meaningful description omits the tag rather than emitting an empty one.
> **Why:** Above about 160 characters the snippet is cut mid-word. A description sliced out
> of an HTML body ships tag fragments and boilerplate ("Skip to content Menu Search"), and
> an empty `content=""` is worse than no tag because it suppresses Google's own snippet
> generation.

**[SEO-07] MUST:** `<link rel="canonical">` is an absolute URL built from the runtime config
value `siteUrl`, not from `window.location`, and it points at the URL you want indexed
(locale prefix included, tracking and filter query parameters excluded).

```ts
// src/app/config/runtimeConfig.ts (excerpt, extends the schema in 03 §5)
const RuntimeConfigSchema = z.object({
  // ...existing fields
  siteUrl: z.string().url(),   // https://www.arnavutkoy.bel.tr - no trailing slash
  siteName: z.string().min(1),
})
```
> **Why:** `window.location.href` canonicalises a page to whatever host, protocol and query
> string the visitor arrived with, so a crawler reaching the staging host self-canonicalises
> staging as the authority. A runtime value keeps one image working on every environment
> ([GEN-09]) while still producing one correct absolute URL per environment.

---

## 4. Locale and SEO

**[SEO-08] MUST:** SEO-indexed products (Tier 1 and Tier 2) carry the locale in the URL
prefix (`/tr/...`, `/en/...`) and each locale's URL is a separate indexable document with
`hreflang` alternates. Locale detection from `localStorage`, a cookie or `Accept-Language`
is disabled for these products; it may only redirect the bare root `/` to the default
locale.
> **Why:** One URL that serves two languages depending on client state is a single document
> to a crawler, so only one language is ever indexed and which one is a race. It also makes
> every shared link ambiguous: a Turkish user sends `/haberler/123` to an English colleague
> who receives the Turkish page. The app-side rule and the localStorage alternative for
> Tier 0 are [I18N-28].

```tsx
// src/app/router/router.tsx (excerpt)
export const router = createBrowserRouter([
  { path: '/', loader: () => redirect(`/${DEFAULT_LOCALE}/`) },   // 302, not indexed
  {
    path: '/:locale',
    loader: ({ params }) => (SUPPORTED_LOCALES.includes(params.locale as Locale) ? null : notFound()),
    Component: LocaleLayout,   // calls changeLocale(params.locale) and renders <Outlet />
    children: [
      { index: true, lazy: () => import('@/features/Home/pages/HomePage') },
      { path: 'haberler/:slug', lazy: () => import('@/features/News/pages/NewsDetailPage') },
    ],
  },
])
```

**[SEO-09] MUST:** Every indexable page emits one `hreflang` link per locale **including
itself**, plus an `x-default` pointing at the default locale's URL, and every alternate URL
returns 200 and links back to the same set.

```tsx
<link rel="alternate" hrefLang="tr" href={`${siteUrl}/tr/haberler/123-yeni-park`} />
<link rel="alternate" hrefLang="en" href={`${siteUrl}/en/news/123-new-park`} />
<link rel="alternate" hrefLang="x-default" href={`${siteUrl}/tr/haberler/123-yeni-park`} />
```
> **Why:** `hreflang` is only honoured when the annotations are reciprocal. A page that
> lists an English alternate which does not list the Turkish one back is discarded entirely,
> so the whole set silently stops working. The self-reference is part of the specification
> and is the most commonly omitted line.

**[SEO-10] MUST:** The locale prefix in the URL is the single source of truth for
`<html lang>`, `dir`, `og:locale` and the i18n instance's active language. The layout
component sets the language from the route parameter, not from storage.
> **Why:** If the URL says `/en/` and `localStorage` says `tr`, the crawler is served
> Turkish content under an English URL that claims `hreflang="en"`, which is worse than
> having no alternates at all.

---

## 5. Social cards and structured data

**[SEO-11] MUST:** Open Graph and Twitter tags are produced from the same title,
description and image values as the standard meta tags (one `PageHead` call, as in §3),
never maintained separately. `og:image` is an absolute URL to an image of at least
1200 x 630 pixels that exists in `public/` or comes from the CMS.
> **Why:** Separately maintained social tags drift within one sprint; a relative
> `og:image` is not fetched by any social scraper; an image below 600 pixels wide is
> rendered by Facebook and LinkedIn as a small square thumbnail instead of a card.

**[SEO-12] MUST:** Indexable pages emit JSON-LD structured data built from the same data
object the meta tags use: `Organization` (once, on the home page), `BreadcrumbList` (on
every page below the root), and the page's own type: `NewsArticle` for news, `Event` for
calendar entries, `Place` or `GovernmentService` for municipal facilities and services.

```tsx
// src/features/News/components/NewsJsonLd.tsx
interface Props { article: NewsArticle; canonical: string; siteName: string }

export function NewsJsonLd({ article, canonical, siteName }: Props) {
  const data = {
    '@context': 'https://schema.org',
    '@type': 'NewsArticle',
    headline: article.title.slice(0, 110),        // schema.org caps headline at 110 chars
    datePublished: article.publishedAt,           // ISO 8601 with offset ([API-18])
    dateModified: article.updatedAt ?? article.publishedAt,
    image: article.imageUrl ? [article.imageUrl] : undefined,
    mainEntityOfPage: { '@type': 'WebPage', '@id': canonical },
    publisher: { '@type': 'Organization', name: siteName },
  }
  // JSON.stringify escapes nothing HTML-significant except via the </script> sequence,
  // which cannot appear in JSON string output once '<' is escaped below.
  return (
    <script
      type="application/ld+json"
      dangerouslySetInnerHTML={{ __html: JSON.stringify(data).replace(/</g, '\\u003c') }}
    />
  )
}
```
> **Why:** Structured data is what produces rich results (article cards, event dates,
> breadcrumb trails in the SERP) and it is the only machine-readable statement of what the
> page is. Building it from the same object as the meta tags is what keeps them from
> disagreeing.

**[SEO-13] MUST:** JSON-LD describes only content that is visible on the rendered page, and
is serialised with `JSON.stringify` plus `<` escaping as above. Hand-built JSON strings and
unescaped interpolation of content into a `<script>` body are forbidden.
> **Why:** Structured data that claims a rating or a date the page does not show is a
> manual-action risk in Search Console. Technically, an unescaped `</script>` inside a title
> closes the script element and turns the rest of the JSON into HTML, which is a direct XSS
> sink on data an editor controls ([SEC-01], [SEC-04]). This is the one sanctioned use of
> `dangerouslySetInnerHTML` outside `SafeHtml`, precisely because the content is
> machine-generated JSON and never markup.

---

## 6. Request-time rendering: the meta injector (Tier 2)

**[SEO-14] MUST:** For Tier 2, the head of every indexable URL is produced **at request
time** from current data. The default implementation is a meta injector: nginx routes the
SEO-prefixed paths to a small Node service that reads the built `index.html` as a template,
fetches the page's metadata from the backend, injects the head tags (and optionally a
server-rendered content block), and returns it with the correct status code. Everything
else, including all assets, is served by nginx from the static bundle as before.

```
             ┌──────────────────────────────────────────────┐
 request ───▶│ nginx (frontend image)                       │
             │  /assets/*        -> static, immutable       │
             │  /tr/* /en/*      -> proxy to meta-injector  │
             │  /api/*           -> proxy to backend        │
             │  everything else  -> index.html (SPA, 200)   │
             └───────────────┬──────────────────────────────┘
                             │
             ┌───────────────▼─────────────┐      ┌──────────────┐
             │ meta-injector (Node 24)     │─────▶│ backend /seo │
             │  template = dist/index.html │      │  /meta       │
             │  60 s cache + SWR 300 s     │      └──────────────┘
             └─────────────────────────────┘
```

**[SEO-15] MUST:** The injector implements exactly this contract: read the template once at
start, validate the upstream response with zod, apply a 2 second upstream timeout, inject
into a template that carries the marker comment, and fall back to the unmodified template
with the site's default head when the upstream fails.

```js
// deployments/main/meta-injector/server.mjs
// Node 24, ESM. Dependencies: zod only. No framework, no build step.
import { createServer } from 'node:http'
import { readFileSync } from 'node:fs'
import { z } from 'zod'

const PORT = Number(process.env.PORT ?? 8081)
const API_BASE = requireEnv('API_BASE_URL')        // http://backend:8000 (internal, [GEN-22])
const SITE_URL = requireEnv('SITE_URL')            // https://www.example.bel.tr
const TEMPLATE_PATH = process.env.TEMPLATE_PATH ?? '/usr/share/nginx/html/index.html'
const LOCALES = (process.env.LOCALES ?? 'tr,en').split(',')
const FRESH_MS = 60_000                            // [SEO-16]
const STALE_MS = 300_000
const UPSTREAM_TIMEOUT_MS = 2_000
const MARKER = '<!--seo-head-->'

function requireEnv(name) {
  const value = process.env[name]
  if (!value) throw new Error(`meta-injector: missing required env ${name}`)
  return value
}

// The template is immutable for the life of the container: it ships in the same image.
const TEMPLATE = readFileSync(TEMPLATE_PATH, 'utf8')
if (!TEMPLATE.includes(MARKER)) throw new Error(`meta-injector: ${MARKER} not found in template`)

const MetaSchema = z.object({
  status: z.union([z.literal(200), z.literal(404), z.literal(301)]),
  location: z.string().optional(),                 // set when status is 301
  title: z.string().min(1).max(120).optional(),
  description: z.string().max(300).optional(),
  image: z.string().optional(),
  canonicalPath: z.string().startsWith('/').optional(),
  alternates: z.record(z.string(), z.string()).optional(),   // locale -> path
  jsonLd: z.unknown().optional(),
  html: z.string().optional(),                     // optional server-rendered content block
})

const cache = new Map()                            // key -> { at, value }

async function fetchMeta(path, locale) {
  const key = `${locale}|${path}`                  // [SEO-16]: the locale is part of the key
  const hit = cache.get(key)
  const age = hit ? Date.now() - hit.at : Infinity
  if (hit && age < FRESH_MS) return hit.value
  if (hit && age < STALE_MS) { void revalidate(key, path, locale); return hit.value }  // stale-while-revalidate
  return revalidate(key, path, locale)
}

async function revalidate(key, path, locale) {
  const url = `${API_BASE}/seo/meta?path=${encodeURIComponent(path)}&locale=${encodeURIComponent(locale)}`
  const response = await fetch(url, { signal: AbortSignal.timeout(UPSTREAM_TIMEOUT_MS) })
  if (!response.ok) throw new Error(`meta upstream ${response.status} for ${path}`)
  const value = MetaSchema.parse(await response.json())   // untrusted input ([GEN-07])
  cache.set(key, { at: Date.now(), value })
  return value
}

const escape = (s) => String(s).replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]))

function head(meta, path, locale) {
  const canonical = new URL(meta.canonicalPath ?? path, SITE_URL).toString()
  const tags = [
    meta.title && `<title>${escape(meta.title)}</title>`,
    meta.description && `<meta name="description" content="${escape(meta.description)}">`,
    `<link rel="canonical" href="${escape(canonical)}">`,
    `<meta property="og:title" content="${escape(meta.title ?? '')}">`,
    `<meta property="og:description" content="${escape(meta.description ?? '')}">`,
    `<meta property="og:url" content="${escape(canonical)}">`,
    meta.image && `<meta property="og:image" content="${escape(new URL(meta.image, SITE_URL))}">`,
    `<meta name="twitter:card" content="summary_large_image">`,
    ...LOCALES.map((lng) => {
      const alt = meta.alternates?.[lng]
      return alt && `<link rel="alternate" hreflang="${escape(lng)}" href="${escape(new URL(alt, SITE_URL))}">`
    }),
    meta.jsonLd && `<script type="application/ld+json">${JSON.stringify(meta.jsonLd).replace(/</g, '\\u003c')}</script>`,
  ].filter(Boolean)
  return tags.join('\n    ')
}

function render(meta, path, locale) {
  let html = TEMPLATE.replace(MARKER, head(meta, path, locale))
  html = html.replace('<html lang="tr"', `<html lang="${escape(locale)}"`)
  if (meta.html) html = html.replace('<div id="root"></div>', `<div id="root">${meta.html}</div>`)
  return html
}

createServer(async (req, res) => {
  const url = new URL(req.url, 'http://internal')
  if (url.pathname === '/healthz') return send(res, 200, 'text/plain', 'ok', 'no-store')

  const locale = LOCALES.find((l) => url.pathname === `/${l}` || url.pathname.startsWith(`/${l}/`)) ?? LOCALES[0]
  try {
    const meta = await fetchMeta(url.pathname, locale)
    if (meta.status === 301 && meta.location) {
      res.writeHead(301, { Location: meta.location, 'Cache-Control': 'public, max-age=60' })
      return res.end()
    }
    // A 404 still returns the SPA shell so the user sees a styled page ([SEO-26], [SEO-29]).
    const status = meta.status === 404 ? 404 : 200
    send(res, status, 'text/html; charset=utf-8', render(meta, url.pathname, locale),
      'public, max-age=60, stale-while-revalidate=300')
  } catch (error) {
    // Fail open: the SPA still renders the page client-side. Never 500 a public page
    // because the metadata service is slow ([SEO-15]).
    console.error(`meta-injector: ${url.pathname}: ${error.message}`)
    send(res, 200, 'text/html; charset=utf-8', TEMPLATE.replace(MARKER, ''), 'no-store')
  }
}).listen(PORT, () => console.log(`meta-injector listening on ${PORT}`))

function send(res, status, type, body, cacheControl) {
  res.writeHead(status, { 'Content-Type': type, 'Cache-Control': cacheControl, 'X-Robots-Tag': status === 404 ? 'noindex' : 'all' })
  res.end(body)
}
```

`index.html` carries the marker and the default head, so the same file works for the SPA
and as the injector's template:

```html
<!doctype html>
<html lang="tr">
  <head>
    <meta charset="UTF-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Arnavutköy Belediyesi</title>
    <meta name="description" content="Arnavutköy Belediyesi resmi web sitesi." />
    <!--seo-head-->
    <script src="/config.js"></script>
  </head>
  <body>
    <div id="root"></div>
    <script type="module" src="/src/main.tsx"></script>
  </body>
</html>
```

**[SEO-16] MUST:** The injector caches upstream metadata in memory with a 60 second fresh
window and a 300 second stale-while-revalidate window, keyed by locale **and** path.
Maximum staleness of an indexed title is therefore 60 seconds under load and 300 seconds if
the upstream is failing.
> **Why:** 60 seconds bounds the upstream to roughly one request per URL per minute, which
> makes a crawl of 5,000 URLs cost 5,000 backend calls spread over the crawl rather than
> one per hit. The stale window keeps the site serving correct-enough titles through a
> backend restart instead of falling back to the generic template. An unkeyed cache would
> serve the Turkish title under the English URL, which breaks `hreflang` ([SEO-09]).

**[SEO-17] MUST:** Injector responses carry
`Cache-Control: public, max-age=60, stale-while-revalidate=300`. `index.html` served
statically by nginx stays `no-cache` ([GEN-12]), and hashed assets stay `immutable`.
> **Why:** Without a public cache header, an upstream CDN or the reverse proxy either stores
> the page forever (stale titles again, one layer further out) or not at all (every crawler
> hit reaches Node). Sixty seconds matches the injector's own freshness so the two layers
> cannot disagree by more than one interval.

**[SEO-18] MUST:** The injector returns the status code the content deserves: 200 for a
published document, 404 for one that does not exist or was unpublished, 301 with `Location`
for a canonicalisation redirect ([SEO-28]). It never returns 500 for a public page; on any
internal failure it serves the unmodified template with 200 and `Cache-Control: no-store`,
and logs the error.
> **Why:** A 500 on an indexable URL removes the page from the index quickly, and a metadata
> service being briefly unavailable is not a reason to deindex a site. Serving the SPA shell
> means a human still gets the page; `no-store` means the degraded response is not cached.

**[SEO-19] MUST:** nginx routes only the SEO-prefixed HTML paths to the injector. Assets,
`/config.js`, `/api/`, and every non-SEO path keep their existing handling.

```nginx
# deployments/main/nginx/default.conf.template (excerpt)
# Only the locale-prefixed document paths go to the injector. Assets must not: routing
# a 3 MB JS chunk through Node would add a hop and defeat gzip_static.
location ~ ^/(tr|en)(/|$) {
    proxy_pass         http://meta_injector;
    proxy_http_version 1.1;
    proxy_set_header   Host $host;
    proxy_set_header   X-Forwarded-Proto $scheme;
    proxy_read_timeout 5s;
    # If the injector container is down, serve the static shell rather than a 502.
    proxy_intercept_errors on;
    error_page 502 503 504 = @spa_shell;
}

location @spa_shell {
    root /usr/share/nginx/html;
    try_files /index.html =404;
    add_header Cache-Control "no-store" always;
}

upstream meta_injector {
    server ${META_INJECTOR_HOST}:8081;
    keepalive 8;
}
```
> **Why:** The regular expression location is evaluated before the prefix `location /`
> fallback, so ordering is explicit rather than accidental. `proxy_intercept_errors` plus
> the named fallback is what keeps a crashed sidecar from taking the whole public site down.
> Directive-level rules: [12](12-NGINX.md) §5.

**[SEO-20] MUST:** The injector ships as its own container in the same compose project,
built from the same `dist/` (so template and bundle can never diverge), runs as a non-root
user, has a health check on `/healthz`, and receives `API_BASE_URL`, `SITE_URL` and
`LOCALES` as environment variables. It holds no secrets ([GEN-10]).

```dockerfile
# deployments/main/Dockerfile (excerpt, third stage; builder and nginx stages unchanged)
FROM node:24-alpine AS injector
WORKDIR /app
COPY deployments/main/meta-injector/package*.json ./
RUN npm ci --omit=dev
COPY deployments/main/meta-injector/server.mjs ./
# The template comes from the SAME build output the nginx stage serves.
COPY --from=builder /app/dist/index.html /usr/share/nginx/html/index.html
USER node
EXPOSE 8081
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8081/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "server.mjs"]
```
```yaml
# deployments/main/docker-compose.yml (excerpt)
  meta-injector:
    build: { context: ../.., dockerfile: deployments/main/Dockerfile, target: injector }
    environment:
      API_BASE_URL: http://backend:8000
      SITE_URL: ${APP_SITE_URL}
      LOCALES: tr,en
    restart: unless-stopped
    logging: { driver: json-file, options: { max-size: 10m, max-file: "3" } }
```
> **Why:** A separate image built from a different commit than the bundle is exactly how the
> template loses the `<!--seo-head-->` marker and the injector starts throwing at boot. One
> Dockerfile, one build, one artefact. Ops rules: [11](11-DOCKER-COMPOSE.md) §1, §5.

**Why this fixes the stale-build problem.** The image still contains only a template. When
an editor publishes an article at 14:03, the injector's cache entry for that URL expires at
most 60 seconds later, and the next crawler request gets the live title, description, image
and JSON-LD from the database. Nothing needs to be rebuilt, nothing needs to be redeployed,
and the maximum divergence between the HTML a crawler sees and what a human sees is one
minute, a number that is written down and observable in the response headers, rather than
"however long since the last deploy".

---

## 7. Build-time prerender (Tier 1 only)

**[SEO-21] MUST:** Tier 1 prerendering renders the app's own static routes with a headless
browser at build time and writes one HTML file per route, and the rendered routes contain no
API data. Playwright is already a dev dependency ([02](02-TECH-VERSIONS.md) §3); no new
package is added.

```ts
// scripts/prerender.ts - run after `vite build`, from package.json: "build": "vite build && tsx scripts/prerender.ts"
import { mkdirSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { chromium } from '@playwright/test'
import { preview } from 'vite'

// Only routes whose content lives in the repository (i18n copy, static components).
// A route that reads the API belongs to Tier 2 and must not be listed here ([SEO-03]).
const ROUTES = ['/tr/', '/tr/hakkimizda', '/tr/iletisim', '/en/', '/en/about', '/en/contact']

const server = await preview({ preview: { port: 4173 } })
const browser = await chromium.launch()
const page = await browser.newPage()

for (const route of ROUTES) {
  await page.goto(`http://localhost:4173${route}`, { waitUntil: 'networkidle' })
  const html = await page.content()
  if (!html.includes('<title>')) throw new Error(`prerender: no title for ${route}`)
  const file = join('dist', route.endsWith('/') ? `${route}index.html` : `${route}.html`)
  mkdirSync(dirname(file), { recursive: true })
  writeFileSync(file, html, 'utf8')
}

await browser.close()
await server.close()
```
> **Why:** Prerendering static routes costs one build step and gives a crawler the real
> head and body without any runtime component. The restriction to API-free routes is what
> keeps it from becoming [SEO-03]: copy in the repository changes only with a commit, so a
> build is exactly as fresh as the content.

**[SEO-22] MUST:** A prerendered route hydrates to the same DOM it was rendered with. Any
value that differs between build machine and browser (`Date.now()`, a random id, the
browser's time zone, `window.matchMedia`) is read after mount, not during the first render.
> **Why:** React 19 recovers from a hydration mismatch by discarding the server HTML and
> re-rendering on the client, which throws away the entire benefit and produces a visible
> flash. It also logs an error to the console on every page load in production.

**[SEO-23] SHOULD NOT:** Use a scheduled rebuild as a freshness mechanism for dynamic
content. If it is nevertheless chosen, it requires an ADR in the app's own `docs/adr/`
recording: the trigger (a content-change webhook from the CMS, not only a cron), the
declared maximum staleness in minutes, and a `<meta name="builtAt" content="<ISO>">` tag
emitted by the build so staleness is observable from `curl`.
> **Why:** A rebuild pipeline is slower than a cache (minutes versus seconds), rebuilds the
> entire site to change one title, and fails silently: nothing alerts when the webhook stops
> firing. The `builtAt` tag is the minimum honesty requirement, because without it nobody
> can tell a stale page from a fresh one without reading the deploy log. This is the only
> exception to [SEO-03] and it must be written down.

---

## 8. SSR alternatives, and what full SSR would change

**[SEO-24] MUST:** If the head alone is not enough (the indexable content itself must be in
the HTML, for example a long article body that must be crawlable without JavaScript), the
sanctioned upgrade is to render **only the SEO routes** on the server with
`react-dom/server`'s `renderToString`, inside the same injector process, and return the
markup in the `html` field the injector already supports. The client still hydrates the
full SPA.

```js
// meta-injector/renderRoute.mjs (only when the head is insufficient)
import { renderToString } from 'react-dom/server'
import { StaticRouter } from 'react-router-dom/server'
// The SEO subset is a separate, deliberately small entry point built by Vite with
// build.ssr, so the injector never pulls MapLibre, the Redux store or the API client.
import { SeoApp } from '../../dist-ssr/seoApp.js'

export function renderRoute(path, data) {
  return renderToString(<StaticRouter location={path}><SeoApp data={data} /></StaticRouter>)
}
```
> **Why:** Scoping SSR to a handful of routes keeps one build, one router and one component
> tree, and keeps the map and the dashboard out of a Node process where `window` does not
> exist. The cost is real and must be accepted knowingly: every component on those routes
> must be server-safe, so no `window` in render, no browser-only libraries, and hydration
> mismatches become a class of bug the team did not previously have.

**[SEO-25] MUST:** Adopting a full SSR framework (Next.js, Vike, TanStack Start) is a
stack change ([GEN-01], [VER-05]) and requires its own ADR before any code is written.

What actually changes if that ADR is ever accepted, so the comparison is honest:

- **Deployment.** The artefact stops being a static bundle behind nginx and becomes a Node
  server that must be scaled, restarted, memory-profiled and health-checked. Every rule in
  [11](11-DOCKER-COMPOSE.md) and [12](12-NGINX.md) about serving `dist/` is rewritten.
- **Runtime config.** `/config.js` at container start ([GEN-09]) is replaced by the
  framework's own server-environment model, which usually reintroduces build-time variables
  and therefore per-environment images unless carefully avoided.
- **Data fetching.** TanStack Query stops being the only server-state home ([GEN-05]);
  loaders or server components fetch too, and cache invalidation now has two owners.
- **The map.** MapLibre is browser-only. Every map route needs a client-only boundary, and
  the map page (the largest surface in the reference product) gains nothing from SSR.
- **What you get.** Streaming HTML, per-route data on the server, better LCP on
  content-heavy pages, and no injector sidecar.

The injector exists because Tier 2 needs correct, fresh head tags and status codes, which is
about 120 lines of Node. A framework migration is the right answer when the *content itself*
must be server-rendered across most of the app, not when the titles are wrong.
Detail: [ADR-0012](adr/0012-seo-strategy.md).

---

## 9. Status codes, redirects and the SPA fallback

**[SEO-26] MUST:** A URL under an SEO-indexed prefix that does not correspond to real
content returns HTTP 404 with the rendered 404 page in the body. The status comes from the
injector (Tier 2) or from nginx (Tier 1, `try_files ... =404` for the prerendered routes).

**[SEO-27] MUST:** The `try_files ... /index.html` SPA fallback returns 200 only for paths
outside the SEO-indexed prefixes. Inside them, an unknown path is a 404, not a 200 shell.
> **Why:** Direct application of [GEN-12]. A 200 with an empty shell for every possible URL
> means every typo, every removed article and every crawler-invented URL is an indexable
> page, and Google classifies the whole site as producing soft-404s.

**[SEO-28] MUST:** Canonicalisation is a 301 issued before the SPA loads: one host (with or
without `www`, pick one), HTTPS only, lower-case paths, no trailing slash except on the
locale root, and a slug that does not match the id redirects to the canonical slug
([SEO-35]). Redirect chains are at most one hop.
> **Why:** Every variant that returns 200 is a duplicate document competing with the
> canonical one for the same query. A client-side redirect (`navigate()` after mount) is not
> a redirect to a crawler at all: it sees a 200 page with the wrong URL.

**[SEO-29] MUST NOT:** Render a "not found" screen with a 200 status, and never render a
loading skeleton as the final state of a public page. If the data cannot be fetched, the
response is a 404 (missing) or a 503 with `Retry-After` (temporarily unavailable).
> **Why:** These are the two soft-404 patterns Search Console reports and neither is visible
> in a browser, because a human sees the same page either way. `curl -I` is the only way to
> notice, which is why it is in the verification checklist ([SEO-39]).

---

## 10. robots.txt and sitemap

**[SEO-30] MUST:** For Tier 2, `sitemap.xml` is generated at request time. nginx proxies
`/sitemap.xml` (and the per-section sitemaps) to the backend or to the injector; it is never
a file inside `dist/`.
> **Why:** A sitemap in the image lists the records that existed at build time, which is the
> discovery half of the [SEO-03] failure: new articles are never crawled because nothing
> points at them, and deleted ones are advertised until the next deploy.

```nginx
location = /sitemap.xml       { proxy_pass http://backend/seo/sitemap.xml; }
location ^~ /sitemaps/        { proxy_pass http://backend/seo/sitemaps/; }
location = /robots.txt        { proxy_pass http://backend/seo/robots.txt; }
```

**[SEO-31] MUST:** `robots.txt` differs per environment and is produced from the same
runtime configuration as the rest of the deployment. Staging and any non-production host
serve `User-agent: *` / `Disallow: /`. Production allows crawling and names the absolute
sitemap URL.
> **Why:** A staging host indexed alongside production splits the ranking signal and puts
> half-finished content in front of citizens. This is the single most common SEO incident
> in a multi-environment deployment, and it is invisible until someone searches for the
> site name.

**[SEO-32] MUST:** Sitemap entries are canonical absolute URLs that return 200, carry a real
`lastmod` from the content's `updatedAt`, and include `xhtml:link` alternates matching
[SEO-09]. A sitemap holds at most 50,000 URLs or 50 MB uncompressed; beyond that it is split
and a sitemap index is served.
> **Why:** A `lastmod` set to the build time on every URL (a common generator default) tells
> Google that all 5,000 pages changed today, which trains it to ignore the field entirely.
> URLs that redirect or 404 reduce the crawler's trust in the whole file.

---

## 11. URL design

**[SEO-33] MUST:** Indexable URLs are lower case, use hyphens as word separators, contain
no query parameters that change the primary content, and no file extensions. Filters,
sorting and pagination that produce near-duplicate pages are `noindex, follow` or
canonicalised to the unfiltered page.
> **Why:** Underscores are not word separators to Google; upper-case paths create duplicate
> documents on case-sensitive servers; and a filtered list is an infinite URL space that
> consumes crawl budget without adding a single indexable page.

**[SEO-34] MUST:** Turkish text in a URL is transliterated with an explicit map, not with
`normalize('NFD')` alone, because `ı`, `ş` and `ğ` do not decompose into ASCII plus a
diacritic.

```ts
// src/shared/utils/slug.ts
const TR_MAP: Record<string, string> = {
  ç: 'c', Ç: 'c', ğ: 'g', Ğ: 'g', ı: 'i', I: 'i', İ: 'i',
  ö: 'o', Ö: 'o', ş: 's', Ş: 's', ü: 'u', Ü: 'u',
}

export function slugify(input: string): string {
  return input
    .replace(/[çÇğĞıIİöÖşŞüÜ]/g, (ch) => TR_MAP[ch])
    .toLocaleLowerCase('tr-TR')       // after the map, so 'I' does not become 'ı' first ([I18N-24])
    .normalize('NFD').replace(/\p{Diacritic}/gu, '')   // handles the remaining Latin accents
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
    .slice(0, 80)
}
// slugify('Yeni Park Açılışı: Çağdaş Mahallesi') -> 'yeni-park-acilisi-cagdas-mahallesi'
```
> **Why:** `'ışık'.normalize('NFD').replace(/\p{Diacritic}/gu,'')` leaves `ışık` unchanged,
> because `ı` is its own code point and not `i` plus a mark. The result is a URL containing
> percent-encoded UTF-8 (`%C4%B1`), which is legal but unreadable in a search result, in an
> analytics report and in a printed leaflet.

**[SEO-35] MUST:** A content URL contains a stable id and a human-readable slug
(`/haberler/123-yeni-park`). The id resolves the content; a request whose slug does not
match the current slug is answered with a 301 to the canonical URL.
> **Why:** The slug is for humans and for the snippet; the id is what makes an edited
> headline not break every existing inbound link. Without the redirect the old slug keeps
> returning 200, which is a duplicate of the canonical page.

---

## 12. Performance for SEO

**[SEO-36] MUST:** Indexable pages meet the Core Web Vitals targets in
[07](07-PERFORMANCE.md) §6 ([PERF-21]) measured on the public entry route, not on the
authenticated dashboard. If the public site and the app share a bundle, the public routes
are split so the map, the charts and the export libraries are not in their initial chunk
([PERF-04], [PERF-05]).
> **Why:** Core Web Vitals are a ranking signal for the page that was measured. A public
> landing page that ships MapLibre because the router is not split loses on a metric it did
> not need to compete in, and the fix is a chunk boundary, not an SEO change.

**[SEO-37] MUST:** Every content image has a descriptive `alt` from the content (not the
file name), explicit `width` and `height` attributes, and `loading="lazy"` for everything
below the fold. The LCP image is not lazy-loaded and is preloaded when it is known.
> **Why:** `alt` is both an accessibility requirement ([GEN-16]) and the only text Google
> Images has. Missing dimensions are the most common cause of CLS, which is measured on the
> exact pages you want to rank ([PERF-18]).

**[SEO-38] MUST:** No render-blocking third-party resource in `<head>` of an indexable page.
Fonts are self-hosted with `font-display: swap` and preloaded ([PERF-19], [PERF-20],
[SEC-14]); analytics and chat widgets load after `load` or on interaction.
> **Why:** A `fonts.googleapis.com` stylesheet in `<head>` adds a DNS lookup, a TLS
> handshake and a blocking request before first paint, on the connection profile crawlers
> and mobile users actually get. It is also a CSP hole and a third-party dependency for a
> government site.

---

## 13. Verification

**[SEO-39] MUST:** Before a Tier 1 or Tier 2 release, the SEO behaviour is verified against
the running container with JavaScript disabled, and the output is pasted into the PR.

```bash
# 1. The head a non-executing crawler sees. Titles must be real, not the template default.
curl -sA 'Mozilla/5.0 (compatible; Googlebot/2.1; +http://www.google.com/bot.html)' \
  https://staging.example.bel.tr/tr/haberler/123-yeni-park | grep -iE '<title>|name="description"|rel="canonical"|hreflang'

# 2. Status codes. A missing article must be 404, not 200.
curl -sI https://staging.example.bel.tr/tr/haberler/999999-yok | head -1     # HTTP/1.1 404
curl -sI https://staging.example.bel.tr/tr/haberler/123-wrong-slug | head -1 # HTTP/1.1 301
curl -sI https://staging.example.bel.tr/uygulama/harita | head -1            # HTTP/1.1 200 (SPA, not indexed)

# 3. Freshness. Change a title in the CMS, wait 60 s, repeat step 1: it must have changed.
# 4. Caching.
curl -sI https://staging.example.bel.tr/tr/ | grep -i cache-control   # public, max-age=60, stale-while-revalidate=300

# 5. Environment isolation.
curl -s https://staging.example.bel.tr/robots.txt                     # must be Disallow: /
```

**[SEO-40] MUST:** After a production release that changes routes, meta generation or the
injector, the Rich Results test is run on one URL per structured-data type, and Search
Console's coverage and Core Web Vitals reports are checked at 48 hours and 7 days. Findings
go into the app's issue tracker, not into a chat message.
> **Why:** Structured-data errors and soft-404 classifications appear in Search Console days
> after the deploy that caused them. Without a scheduled check they are found by the drop in
> traffic a month later.

### SEO release checklist

Copy into the PR for any Tier 1 or Tier 2 change.

1. The app's SEO tier is stated in `docs/README.md` and this change matches it ([SEO-01]).
2. No API data is fetched at build time; `dist/` contains no content ([SEO-03]).
3. Every new indexable route renders one `PageHead` with a unique title ([SEO-04], [SEO-05]).
4. Description present, from i18n or the content, at most 160 characters ([SEO-06]).
5. Canonical is absolute, built from `siteUrl`, and points at the URL you want indexed ([SEO-07]).
6. Locale is in the URL; no client-side locale detection on indexable routes ([SEO-08]).
7. `hreflang` set is reciprocal, includes the self-reference and `x-default` ([SEO-09]).
8. OG and Twitter tags come from the same values; `og:image` is absolute and >= 1200x630 ([SEO-11]).
9. JSON-LD emitted for the page type, matching visible content, `<` escaped ([SEO-12], [SEO-13]).
10. Tier 2: the injector returns fresh data within 60 s and the correct status ([SEO-16], [SEO-18]).
11. Unknown SEO URL returns a real 404; the SPA fallback 200 is confined to non-SEO prefixes ([SEO-26], [SEO-27]).
12. Slug or host canonicalisation is a single 301, no chains ([SEO-28], [SEO-35]).
13. `robots.txt` and `sitemap.xml` are served at request time; staging is `Disallow: /` ([SEO-30], [SEO-31]).
14. Images have `alt`, explicit dimensions, and the LCP image is not lazy ([SEO-37]).
15. The `curl -A Googlebot` output from [SEO-39] is in the PR description.

---

## Open questions

- **Where the metadata endpoint lives.** This file assumes the backend exposes
  `GET /seo/meta?path=&locale=`, `/seo/sitemap.xml` and `/seo/robots.txt`. The shape of that
  contract belongs to the backend standard; the zod schema in [SEO-15] is the frontend's
  copy of it and must be reconciled when the backend standard adopts one.
- **A shared injector image.** Every Tier 2 app currently ships its own copy of
  `server.mjs`. It becomes a small internal package when a third app needs it, at which
  point it also needs its own tests and version ([GEN-03]).
- **Edge caching.** The 60 second window assumes the injector is the only cache in front of
  the app. If a CDN is introduced, the `stale-while-revalidate` window and the purge-on-
  publish story need to be decided together, and [SEO-16] revisited.
