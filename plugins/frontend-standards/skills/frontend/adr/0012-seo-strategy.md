# ADR-0012 — SEO strategy: a template build plus request-time meta injection (SSR only for SEO routes)

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-01], [GEN-09], [GEN-11], [GEN-12], [SEO-01]..[SEO-40], [VER-05], [NGX-03], [OPS-01]

## Context

The stack is fixed: React 19 + Vite, built to a static bundle, served by nginx from a Docker
image ([GEN-01]). Some of the products behind that stack are internal GIS and operations
applications where indexing is actively unwanted, and some are public municipal sites where
search traffic is the point: a citizen searching for "Arnavutköy imar durumu sorgulama" must
find the page, and the result's title and description must describe what the page says
today.

The concrete failure this decision exists to prevent, in the owner's words: *for
SEO-requiring sites people fetch APIs at build time and bake the latest data into the build.
One week later that build is still live, the site's data has moved on, yet the HTML still
carries the old titles and descriptions, and Google indexes that.* Worked through in
[10](../10-SEO-RENDERING.md) §2: new articles are never discovered because the baked sitemap
does not list them, corrected headlines stay wrong in `<title>` and in every WhatsApp share,
and unpublished articles keep returning 200 with stale metadata.

So the decision has to satisfy four constraints at once:

1. The HTML a non-executing crawler receives must reflect data that is at most minutes old.
2. HTTP status codes must be real: 404 for missing content, 301 for canonicalisation, 200
   only for a page that exists ([GEN-12], [SEO-26]).
3. One image per release, environment-agnostic, config injected at container start
   ([GEN-09]). No per-environment build.
4. No stack change, no second frontend framework, no per-app snowflake ([GEN-01], [VER-05]).

Note that the problem is narrower than "we need SSR". Google renders JavaScript, and the
*body* of these pages is usually indexed correctly from the client-side render. What is
never picked up reliably is the `<head>`, because head tags are read from the initial HTML
by social scrapers (which never execute JS at all) and are used by the crawler before and
independently of rendering. Titles, descriptions, canonicals and status codes are the part
that is broken.

## Options

### A) Template build + request-time meta injection, with `renderToString` for SEO routes only if needed (CHOSEN)

`dist/` contains a template with a `<!--seo-head-->` marker and no content. nginx routes the
locale-prefixed document paths to a ~120-line Node sidecar which fetches the page's metadata
from the backend, injects head tags and JSON-LD, and returns the correct status. Everything
else, including every asset, is served by nginx unchanged. Detail: [10](../10-SEO-RENDERING.md) §6.

**Strengths:**
- Directly answers the failure: maximum staleness is a declared 60 seconds ([SEO-16]),
  observable in the `Cache-Control` header, instead of "however long since the last deploy".
- Correct status codes without touching the SPA. A 404 is issued by the injector before any
  JavaScript runs, which removes the soft-404 class entirely ([SEO-29]).
- The build artefact stays a template, so [GEN-09] and [GEN-11] hold unchanged: one image,
  every environment, no content inside it.
- The React app is untouched. No component becomes server-rendered, so `window`,
  MapLibre, the Redux store and browser-only libraries keep working exactly as before.
- Small and inspectable: one file, Node 24 built-ins plus zod, no framework, no build step
  for the sidecar. It ships from the same Dockerfile and the same `dist/index.html` the
  nginx stage serves, so template and bundle cannot diverge ([SEO-20]).
- Fails open. If the sidecar is down, nginx serves the static shell ([SEO-19]) and the site
  works for humans; if the metadata upstream is down, the injector serves the template with
  the default head and a `no-store` header ([SEO-18]).
- Scales up smoothly: when head tags are not enough, the same process can render the SEO
  routes with `react-dom/server` and fill the existing `html` field ([SEO-24]), without
  changing the deployment shape.

**Weaknesses:**
- A Node process to operate: a container, a health check, log rotation, memory, restarts,
  and one more thing that can be the cause of an incident at 02:00.
- **Two code paths for head tags.** The React `PageHead` component ([SEO-04]) and the
  injector's string builder produce the same tags in two languages. They can disagree, and
  only [SEO-39]'s `curl` check catches it.
- Requires a backend endpoint (`GET /seo/meta`) that does not exist yet in the backend
  standard, so the contract is currently owned by the frontend's zod schema.
- The in-memory cache is per container. Two replicas mean two caches and up to two upstream
  calls per URL per minute, and a rolling restart empties both.
- Only Tier 2 needs it, so a Tier 1 site pays nothing and a Tier 2 site pays all of it; the
  tier classification ([SEO-01]) has to be made deliberately rather than by default.

### B) A full SSR framework (Next.js, Vike, TanStack Start)

**Strengths:** The problem disappears as a category. Head tags, status codes, streaming
HTML, per-route server data and image optimisation are framework features rather than local
inventions. One code path for head tags. Best possible LCP on content pages.

**Weaknesses:** It is a stack change, forbidden by [GEN-01] and [VER-05] without this ADR
overriding it, and the cost is not the migration, it is the permanent divergence:

- The deployment stops being "nginx serves `dist/`". Every rule in
  [11](../11-DOCKER-COMPOSE.md) and [12](../12-NGINX.md) about static serving is rewritten,
  and the runtime is now a Node server to scale and profile rather than a file server.
- `/config.js` at container start ([GEN-09]) is replaced by the framework's server
  environment model, which in practice reintroduces build-time variables and therefore
  per-environment images unless carefully worked around.
- Server state gains a second owner: loaders or server components fetch alongside TanStack
  Query, so cache invalidation is no longer in one place ([GEN-05]).
- MapLibre is browser-only. The largest surface in the reference product (the map) needs a
  client-only boundary and gains nothing from SSR.
- Every internal app would either migrate too (paying the cost for zero benefit, since they
  are `noindex`) or the organisation runs two stacks, which is the thing [GEN-01] exists to
  prevent.

The honest summary: B is the better answer to a question this organisation is not asking.
It is right when most of the app's *content* must be server-rendered, not when the titles
are wrong on 200 news pages.

### C) Build-time SSG with data (prerender the dynamic pages at build)

**Strengths:** No runtime component at all. Fast, cacheable, trivially served by nginx.
Correct HTML for crawlers on the day of the deploy.

**Weaknesses:** This is the failure in the Context section, written down as a strategy. Its
freshness equals the deploy interval, so it is only correct if content changes trigger a
full rebuild, which means an editor pressing "publish" runs a Docker build. That pipeline is
slower than a cache by two orders of magnitude, rebuilds the whole site to change one
headline, and fails silently when the webhook stops firing. It also violates [GEN-11]
outright. Retained only as the narrow, ADR-requiring exception in [SEO-23], with a mandatory
`builtAt` meta tag so staleness is at least observable.

Build-time prerendering *without* data is a different thing and is kept: it is the Tier 1
strategy ([SEO-21]), because repository content changes only with a commit, so a build is by
definition as fresh as the content.

### D) Client-only SPA plus a dynamic rendering service (Prerender.io, Rendertron, or a self-hosted headless Chrome)

**Strengths:** Zero application change. A middleware detects crawler user agents, renders the
page in headless Chrome and returns the HTML. Works for any route without listing them.

**Weaknesses:** It serves crawlers different bytes than users based on user-agent sniffing,
which Google explicitly tolerates only as a workaround and which is one configuration
mistake away from being cloaking. Operationally it is far heavier than option A: a headless
Chrome per render (hundreds of MB of RAM, seconds of latency) instead of a `fetch` and a
string replace, and its cache has the same staleness question with worse economics. Social
scrapers are missed unless every one of their user agents is in the list. A hosted service
sends every public URL to a third party, which is not acceptable for a public institution;
self-hosting it means operating a browser farm to produce a `<title>`.

## Decision

**Option A.** The build artefact stays a template ([GEN-11], [SEO-03]); Tier 2 sites get a
meta injector sidecar that produces head tags, JSON-LD and status codes at request time from
live data, with a 60 second freshness bound and a 300 second stale-while-revalidate window;
Tier 1 sites get a Playwright prerender of their API-free routes; Tier 0 sites get three
layers of `noindex` and nothing else.

The reasoning is proportionality. The defect is confined to the `<head>` and to HTTP status
codes, and those are 120 lines of Node away from being correct, with the SPA, the build, the
image and the nginx configuration all unchanged. Option B fixes it by replacing the
deployment model for every application in the organisation, including the ones that must not
be indexed at all. Option C is the defect. Option D costs a browser farm and a cloaking
argument to produce the same `<title>` that a `fetch` and a string replace produce.

Option A also degrades in the right direction. Its ceiling (SEO routes rendered with
`renderToString` inside the same process, [SEO-24]) is reached without changing the
deployment shape, and if that ceiling is ever genuinely too low, the case for B will be
supported by a measurement rather than by a preference.

## Accepted costs

- **One more container to operate per Tier 2 app.** Health checks, logs, restarts, memory,
  and an on-call surface that did not exist before. Mitigated by the nginx fallback
  ([SEO-19]) so its failure degrades the site rather than taking it down, but the pager is
  real.
- **Two code paths for head tags** (React `PageHead` and the injector's string builder).
  They can and will drift; the only defence is the `curl -A Googlebot` verification in
  [SEO-39] being genuinely run and pasted into the PR.
- **A backend contract the backend standard has not defined yet.** `GET /seo/meta` is
  specified here by a zod schema; until the backend standard adopts it, the two can disagree.
- **Cache correctness is now the frontend's problem.** Locale must be in the cache key,
  stale-while-revalidate has to be right, and a CDN in front of the site would introduce a
  second layer with its own staleness ([SEO-16] Open questions).
- **60 seconds of possible staleness** on titles and descriptions, accepted deliberately.
  Sub-second freshness would mean no cache and one backend call per crawler hit.
- **Only the head is server-rendered by default.** Content that must be indexable without
  JavaScript needs [SEO-24], and that step brings server-safety constraints and hydration
  mismatches into a codebase that has never had them.
- **Per-app duplication.** Each Tier 2 app currently carries its own copy of `server.mjs`
  until a third app justifies extracting it.

## What would change this decision

- Most of an application's indexable value moving into page *content* rather than metadata
  (long-form articles that must rank on body text without JavaScript execution). At that
  point [SEO-24] is doing SSR for most routes anyway and option B becomes the cheaper
  arrangement.
- A public product needing sub-second content freshness in the HTML, which no cache-based
  design serves well.
- The organisation acquiring a genuine need for a Node runtime in production for other
  reasons (a BFF layer, image optimisation, edge middleware). The main cost of B, operating
  a Node server, would already be paid.
- A measurement showing that client-side rendered body content is not being indexed on the
  reference site despite correct head tags. That would invalidate the premise that the
  problem is confined to the head, and should be gathered from Search Console's rendered-HTML
  view before anyone proposes a framework.
- Vite shipping a first-class, framework-free SSR story for a subset of routes that removes
  the second head-tag code path. That would strengthen A rather than replace it, and this
  record should be updated rather than superseded.
