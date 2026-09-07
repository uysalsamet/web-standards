# ADR-0006 — Routing: React Router 7 in data mode

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-01], [GEN-05], [RTE-01], [RTE-03], [RTE-08], [RTE-12], [PERF-04]

## Context

The applications in scope are static SPAs served by nginx ([GEN-01]): an internal GIS
dashboard with 120 pages and a live map, and public municipal portals where a handful of
routes must be indexable. The router must give us, at minimum:

- route-level code splitting, because the map chunk alone is ~250 KB gz and must not be on
  the login page's critical path ([PERF-02]);
- route-level error boundaries, so one broken page does not unmount the navigation
  ([OBS-03]);
- a pending state we can show during a chunk download ([RTE-06]);
- a navigation blocker for dirty forms ([RTE-17]);
- search params as first-class state, because the map viewport, filters and the selected
  feature live in the URL ([STA-02]).

Server state is already owned by TanStack Query ([ADR-0004](0004-server-state.md)), so the
router does **not** need to be a data-fetching framework. It needs to be a good navigation
layer that does not fight the cache.

## Options

### A) React Router 7, data mode (`createBrowserRouter` + `RouterProvider`) (CHOSEN)

**Strengths:**
- Every capability above is in the box: `lazy` route modules, per-route `ErrorBoundary`,
  `useNavigation`, `useBlocker`, `useSearchParams`, `<ScrollRestoration getKey>`.
- It is the same library the reference codebase already uses (`react-router-dom` 7.x), so
  adoption is a refactor of the route tree, not a migration of 120 pages.
- Library mode is a plain dependency: no build plugin, no file-system convention, no
  server. It builds to the same static `dist/` we already serve ([GEN-09]).
- Data mode's loaders can be used purely as prefetch hooks
  (`queryClient.ensureQueryData`, [RTE-08]), which removes the chunk-then-fetch waterfall
  without introducing a second cache.
- Largest ecosystem and the most training data, which measurably matters when AI agents
  write the routes.

**Weaknesses (the honest ones):**
- **Loaders are the framework's main feature and we deliberately do not use them for
  data.** We pay the conceptual cost (every engineer and every agent must be told why
  `useLoaderData` is absent) for no benefit beyond prefetch. A reader coming from the
  React Router docs will write a loader that returns data, and only a review catches it.
- **Params are not typed.** `useParams()` returns `Record<string, string | undefined>`.
  Every route pays for a hand-written zod parse into a branded id ([RTE-12]). A typed
  router gives this for free; here it is boilerplate that can be forgotten, and forgetting
  it produces a 400 from the backend rather than a compile error.
- Search params are also untyped, so `useSearchParamState(schema)` ([RTE-15]) is our code
  to maintain, not the library's.
- Two modes (framework and data/library) with overlapping docs: features shown in the docs
  (`<Link prefetch>`, route modules with `loader` exports) may only exist in framework
  mode, which costs verification time on every upgrade ([RTE-21]).
- Version churn: v6 to v6.4 to v7 changed the recommended API twice in three years.

### B) TanStack Router

**Strengths:** Fully type-safe paths, params and search params, including a validated
search-param API that is exactly what [RTE-15] hand-rolls; first-class integration with
TanStack Query (the same authors); built-in route-level code splitting and a good pending
UI model.
**Weaknesses:** It is a second routing paradigm in an organisation whose entire existing
codebase is React Router, so it means a rewrite of 120 route definitions with no user-facing
benefit, against [GEN-24]. Its type inference requires either the file-based route generator
(a Vite plugin and a generated route tree, more build machinery) or verbose manual route
trees. Smaller ecosystem and far less training data, which shows up as wrong AI-generated
code. Reconsider for a greenfield app if the params boilerplate proves to be a real defect
source rather than a nuisance.

### C) wouter

**Strengths:** 2 KB, hooks-only, trivial to learn.
**Weaknesses:** No route-level error boundaries, no navigation blocking, no pending state,
no scroll restoration, no nested layout routes with an outlet model rich enough for the
`RootLayout → RequireAuth → MapLayout` chain ([RTE-04]). We would rebuild four of those
ourselves and get them subtly wrong. Bundle size is not the constraint here: the router is
under 20 KB gz against a 250 KB map chunk.

### D) Next.js (or Remix) file-system routing

**Strengths:** Routing, splitting, prefetching, streaming and SEO solved together; a real
404 status without an nginx rule ([RTE-14]).
**Weaknesses:** It is a different stack, forbidden by [GEN-01] and [VER-05]. It requires a
Node server in production, which contradicts the single static-nginx-image deployment
([GEN-13], [OPS-02]) and the runtime-config model ([GEN-09]). The SEO need that motivates it
is narrow (a few indexable routes) and is solved in [10](../10-SEO-RENDERING.md) without
changing the stack.

## Decision

**React Router 7 in data mode**, with loaders restricted to prefetch, redirect and param
validation ([RTE-08]), and with two thin wrappers of our own: `useSearchParamState(schema)`
for typed search params ([RTE-15]) and per-feature zod id schemas for typed path params
([RTE-12]).

The deciding factor is not that React Router is the best router available. It is that it is
the router already in the codebase, it covers every capability the standard requires, and
the gaps it leaves (types) are closable with about 60 lines of shared code, while the gap
the alternatives leave (a rewrite, or a server in production) is not closable at all.

## Accepted costs

- Loaders exist in the API and are mostly unused. Every engineer and agent must be told
  once, and reviewers must catch `useLoaderData` in PRs ([CI-19] item 3, [RTE-08]).
- Path and search params are typed by hand. A forgotten parse is caught by review or by a
  backend 400, not by the compiler.
- `useSearchParamState` and `safeReturnTo` are our code: our bugs, our tests.
- Verification tax on each 7.x upgrade: confirm that `lazy`'s shape and any prefetch API
  still behave as documented for data mode ([RTE-03], [RTE-21] open questions).
- No route-level type safety means a renamed path can only be found by grep and by the
  route tests ([RTE-27]).

## What would change this decision

- TanStack Router reaching parity in ecosystem maturity **and** a greenfield app starting
  with no React Router history. Then the typed params and typed search params are worth the
  paradigm change for that app only.
- React Router shipping typed params generation for data mode. That closes the main
  weakness and ends the discussion.
- A product needing genuine SSR for more than meta tags. That is an [ADR-0012](0012-seo-strategy.md)
  decision, not a routing one, and it would be re-opened there first.
