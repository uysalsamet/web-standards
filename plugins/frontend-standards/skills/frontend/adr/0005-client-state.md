# ADR-0005 — Cross-feature client state: Redux Toolkit, with a narrowed scope

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-05], [STA-03], [STA-23]..[STA-29], [RT-06], [RT-07]

## Context

After [ADR-0004](0004-server-state.md) puts server data in TanStack Query and [STA-02] puts
URL-addressable state in the URL, what is left is client state: values the browser owns that
no endpoint returns and no link should carry. In these applications that is a short list, but
a real one:

- Live entity state fed by MQTT at 4 to 10 Hz (vehicle positions, animation buffers), read by
  a map layer, a side panel and a status bar at the same time.
- Layer visibility and map UI mode shared between a control panel and the map module.
- Session-scoped UI preferences that outlive a route (theme, panel collapsed, units).

The reference codebase already uses Redux Toolkit for exactly the first of these
(`truckPositionSlice`: seed positions from REST, per-vehicle MQTT buffers, animation start
timestamps). It also uses it for things that should not be there, including copies of fetched
lists.

The question is not "do we need a store", it is "which store, and how much is allowed in it".

## Options

### A) Redux Toolkit, scope narrowed to cross-feature client state (CHOSEN)

**Strengths:**
- Already in the reference codebase for the hardest case (live positions), working, with the
  animation-buffer logic that took real effort to get right. Replacing it buys nothing a user
  can see ([GEN-24]).
- `createSlice` plus Immer gives readable reducers over a normalised `Record<id, T>`, which is
  the exact shape a 10 Hz position stream needs.
- One batched action per flush ([RT-06], [RT-10]) is a single notification to all subscribers,
  which is what makes a 200-vehicle stream affordable. A store with per-atom subscriptions
  makes this easy to get wrong in the other direction (200 atom writes per flush).
- `createSelector` memoisation is independent of React rendering, so a derived list is
  computed once per state change rather than once per consuming component ([STA-25]).
- The serializability and immutability middleware catch a class of bug (a `Map`, a `Date`, a
  MapLibre handle in the store) at development time ([STA-26]).
- Redux DevTools give a time-ordered action log, which is the only practical way to debug a
  realtime stream after the fact.
- Every AI agent and every developer already knows it. That matters for a standard consumed
  primarily by agents.

**Weaknesses:**
- The heaviest of the options: RTK plus react-redux is roughly 15 KB gzipped, and it is in the
  main chunk because the store is created in `AppProviders`.
- The most boilerplate per unit of state: a slice file, actions, selectors, store
  registration, typed hooks. For three booleans it is absurd, which is why [STA-04] sends
  those to `useState`.
- It attracts data that does not belong to it. Every Redux codebase drifts toward "the store
  is where state lives", which is how the reference app ended up with server data in slices.
  The scope narrowing is the entire point of this record, and it is enforced by rules
  ([STA-27], [STA-28]) rather than by the library.
- A slice registered in the root store is loaded on every page; lazy reducer injection exists
  but is extra machinery ([STA-23] keeps the slice count low instead).

### B) Zustand

**Strengths:** About 1 KB, minimal boilerplate, no provider, selector-based subscriptions
that avoid re-rendering unrelated consumers, trivially usable outside React (a socket handler
can call `store.setState` directly, which is genuinely nice for [RT-06]).

**Weaknesses:** No enforced action log, so a realtime bug is debugged by adding console
statements rather than by reading a DevTools timeline. No built-in immutability or
serializability guard, so a MapLibre instance in the store is a runtime surprise instead of a
development-time error. Middleware ecosystem is thinner. And the decisive point: it would
replace working code (`truckPositionSlice`) with equivalent code, at the cost of a migration,
two state libraries during the transition, and a second pattern for agents to choose between.
"Smaller and newer" is not a reason ([GEN-01]'s one-stack logic applies inside the app too).

### C) Jotai (atoms)

**Strengths:** Bottom-up atoms compose well, fine-grained subscriptions, minimal re-renders,
excellent for derived-value graphs.

**Weaknesses:** The model inverts what our hardest case needs: a batched write of 200 entities
per flush is one action in Redux and 200 atom updates in Jotai unless you build an atom of a
record, at which point the fine-grained advantage is gone. Debugging is per-atom rather than
per-transaction. Fewer engineers and fewer agents produce correct Jotai on the first attempt.

### D) React Context only

**Strengths:** No dependency at all. Sufficient for genuinely static, rarely changing values.

**Weaknesses:** Every context value change re-renders the entire subtree under the provider,
with no selector to narrow it. A 4 Hz position update through context re-renders the whole map
page four times a second, including the parts that show nothing live. Context remains the
right tool for dependency injection of stable objects (the map instance, the runtime config,
the query client), which is what [STA-39] says; it is not a state manager.

### E) No cross-feature store: lift state to the nearest common parent

**Strengths:** Zero dependency, zero indirection, and it is correct for most features.

**Weaknesses:** The nearest common parent of the map layer, the side panel and the status bar
is the route layout, so lifting means the layout holds a 10 Hz position record and prop-drills
it three levels. Every render of that record re-renders the whole page. This is the default
for everything that is *not* cross-feature ([STA-04]); it fails precisely for the case Redux
is kept for.

## Decision

**Redux Toolkit stays, and its scope narrows to cross-feature client state only.**

What is allowed in the store: live entity state written by a batched realtime flush
([RT-06]), cross-feature UI mode and layer visibility, and session-scoped preferences.
What is forbidden: any copy of server data ([STA-27]), any thunk performing HTTP ([STA-28]),
any non-serialisable value, and any state read by exactly one feature ([STA-03]).

Decisive reasons: the batched-write pattern that a high-rate stream needs is the one Redux is
best at; the action log is the only practical realtime debugging tool available; and the
existing working slice does not get rewritten for a smaller bundle ([GEN-24]).

## Accepted costs

- About 15 KB gzipped in the main chunk for a store that, in a small app, holds three keys.
- Boilerplate per slice, which makes the cheap thing (a shared boolean) look expensive and
  tempts developers to put it in `useState` in the wrong place, or to put everything in Redux
  because the file already exists. Both directions are review burden.
- The scope narrowing is a rule, not a mechanism. Nothing in the library stops the next
  developer adding a `parkingListSlice` full of API results; only [STA-27] and a reviewer do.
- The reference app's existing over-use of Redux is not cleaned up as a project. Slices holding
  server data are migrated to TanStack Query when the owning feature is touched ([GEN-24]),
  so both patterns coexist for a while and a reader must check which one a given feature uses.
- We give up Zustand's ability to write to the store from a plain module without a dispatch
  wrapper; the realtime flush has to import the store or dispatch through a subscribed
  wrapper, which is one extra indirection in `src/shared/lib/`.

## What would change this decision

- The store shrinking to nothing but a handful of booleans after the realtime layer moves to a
  worker or a different transport. Then RTK is 15 KB for a `useState`, and Zustand or context
  wins on cost.
- A measured re-render problem caused by the coarse subscription model that selectors and
  batching cannot fix.
- A second app in the repo needing a store with lazily loaded feature reducers, where RTK's
  injection story turns out to cost more than Zustand's absence of one.
