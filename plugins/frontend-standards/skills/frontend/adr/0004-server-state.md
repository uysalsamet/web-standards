# ADR-0004 — Server state: TanStack Query

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-05], [GEN-06], [GEN-07], [STA-01]..[STA-22], [API-34], [TS-27]

## Context

Every application in this standard is a client of an HTTP API behind the same origin. The
server owns the data; the browser holds a copy for as long as the screen shows it. That copy
needs: caching with an expiry, deduplication of concurrent requests for the same thing,
invalidation after a mutation, retry for transient failures, abort on unmount or on a changed
filter, and a loading/error/empty state per view ([GEN-15]).

Somebody writes that machinery. The question is whether it is a library or the team.

The reference codebase answers "the team": data is fetched in `useEffect` hooks
(`useParkingMapData` and about forty siblings), stored in `useState`, and refetched by
whatever calls the hook again. The observed consequences are the ones this ADR exists to
prevent: the same endpoint requested three times on one page load because three components
mount at once, a request that resolves after unmount and sets state on a dead component, no
abort when the filter changes so an older response overwrites a newer one, and "refresh after
save" implemented as a `refetchTrigger` counter passed down four levels.

## Options

### A) TanStack Query 5 (CHOSEN)

**Strengths:**
- Cache keyed by a serialisable key with per-key `staleTime`/`gcTime`; concurrent mounts of
  the same key produce one request, which removes the triple-fetch class of bug outright.
- Invalidation is declarative and colocated: a mutation names the keys it affects
  ([STA-12]), instead of a trigger counter travelling through props.
- `signal` is passed into the query function, so abort on unmount and on key change is the
  default rather than something each hook remembers ([API-34], [STA-16]).
- `placeholderData: keepPreviousData` gives paginated tables a non-flickering transition that
  hand-rolled hooks never implement.
- Devtools show every key, its state and its observers, which is how a stale-data question is
  answered in thirty seconds rather than by reading four hooks.
- Transport agnostic: it wraps our own `fetch` client ([GEN-06]) rather than replacing it, so
  the error normalisation, timeout, request id and zod parsing in `04` stay exactly where
  they are.
- Suspense and `useSuspenseQuery` available where a route wants them ([STA-15]), without
  forcing them everywhere.

**Weaknesses:**
- Roughly 13 KB gzipped in the main chunk, on every page including ones with no data.
- Two caches exist in the app (Query for server data, Redux for client state), and the
  boundary has to be taught and policed ([STA-27]). Developers copy query results into Redux
  the moment the rule is not enforced.
- Its defaults are wrong for this deployment and must be overridden globally
  (`refetchOnWindowFocus: false`, retry policy, `staleTime`), which is a configuration file
  someone must maintain ([STA-21]).
- Key discipline is real work: a hand-built key array in one component and a factory in
  another means invalidation misses, so [STA-06] mandates a key factory per feature.
- The v4 to v5 migration renamed most options; another such major is a repo-wide edit.

### B) RTK Query

**Strengths:** Already in the dependency tree via Redux Toolkit ([ADR-0005](0005-client-state.md)),
so no new package. One store, one devtools panel, generated hooks, cache lifetime and tag
invalidation built in. Codegen from OpenAPI exists.

**Weaknesses:** Its endpoint definitions want to own the transport (`baseQuery`), which fights
[GEN-06]'s single client and makes the zod boundary ([GEN-07]) an extra wrapper rather than the
natural place. Tag-based invalidation is coarser than key-based in practice for geodata queries
keyed by a rounded bbox ([GIS-16]). Cache entries live in the Redux store, so server data sits
in the client store by construction, which is the exact confusion [GEN-05] is trying to end.
Every query re-renders through `react-redux` subscriptions rather than per-observer, which is
measurable on pages with many independent queries. Suspense support lags.

### C) SWR

**Strengths:** Smallest of the three (about 5 KB), simple mental model, good defaults for
read-mostly UIs.

**Weaknesses:** No first-class mutation story: optimistic updates and invalidation are
hand-assembled per call site, which is where the reference codebase's bugs already are. No
query cancellation on key change without extra code. Devtools are third-party. Paginated
tables need manual previous-data handling. It solves the caching half of the problem and
leaves the write half, which is the half that produces user-visible defects.

### D) Hand-rolled `fetch` in `useEffect` (what the reference codebase does)

**Strengths:** No dependency, no API to learn, and each hook is readable on its own.

**Weaknesses:** Every hook reimplements abort, dedup, retry, staleness and invalidation, and
most of them implement one or two. Measured on the reference app: 40+ fetch hooks, of which 3
abort, 0 dedupe, 0 have a stale policy, and refresh is a counter prop. Race conditions between
a slow request and a fast one are invisible until a user with a bad connection reports "the
list shows the wrong district". This is not cheaper, it is deferred and distributed.

### E) React Router 7 loaders as the data layer

**Strengths:** Data fetching tied to navigation, parallel loading, no waterfall, already in
the stack.

**Weaknesses:** Loaders answer "data for a route transition", not "data for a widget that
appears after the user opens a panel", and half the data in a map application is the second
kind. There is no cache across navigations without adding one, so going back refetches
everything. [ADR-0006](0006-routing.md) already decides loaders are used for route-level
gating, not for data.

## Decision

**TanStack Query 5 for all server state**, wrapping the single `fetch` client from
[04](../04-API-CLIENT.md), with the defaults and key factories in
[05](../05-STATE-AND-DATA.md) §2.

Decisive reasons, in order: request deduplication and abort are correctness features, not
conveniences, and options C, D and E leave them to the caller; the cache stays out of the
client store, which is what makes [GEN-05]'s four homes teachable; and it composes with our
own HTTP client instead of replacing it, so the error and schema boundary stays in one place.

## Accepted costs

- 13 KB gzipped on every page, including pages with no queries.
- A second cache in the app, and a rule ([STA-27]) that must be enforced in review because
  the compiler cannot see a violation.
- Global defaults must be overridden; the out-of-the-box behaviour (refetch on focus, three
  retries) would fire redundant traffic at a municipal API on every window switch.
- Query keys are a shared naming space with no compiler support. A typo is a cache miss, not
  an error, which is why [STA-06] forces a factory.
- Migrating the reference codebase is real work: about 40 hooks, each with its own call
  shape, its own state variables and its own refresh mechanism. That migration is **not**
  scheduled as a project. [GEN-24] applies: new code uses Query, an old hook is converted when
  it is touched for a real reason, and both exist in the codebase in the meantime. Expect the
  transitional period to last quarters, and expect PRs that touch a converted screen to look
  larger than their feature.

## What would change this decision

- The Query cache and the Redux store merging in practice despite [STA-27], repeatedly, in
  review. At that point RTK Query's single-store model would be honest about what the team
  actually does.
- A React release that makes `use()` plus a cache primitive cover deduplication, abort and
  invalidation in the framework, at which point the library is a compatibility layer.
- A major that again renames the option surface without a codemod, making the upgrade cost
  exceed the maintenance saved.
