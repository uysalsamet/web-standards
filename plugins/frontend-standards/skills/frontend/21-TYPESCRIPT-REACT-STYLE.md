# 21 — TypeScript and React Style

> Governs how the code is written: compiler strictness, what happens at untyped boundaries,
> how UI state is modelled, how components and props are shaped, hook and effect discipline,
> the React 19 idioms that replace older patterns, and the lint and format configuration
> that enforces all of it. Core principle: **the compiler and the linter are the review;
> anything they cannot check is a rule with a name so a reviewer can cite it.** Read this
> file before writing any TypeScript or TSX, and whenever a review comment says "types".
>
> Out of scope: where files live ([03](03-PROJECT-STRUCTURE.md)), which store holds which
> state ([05](05-STATE-AND-DATA.md)), bundle and render budgets
> ([07](07-PERFORMANCE.md)), and test style ([13](13-TESTING.md)).

---

## 1. Strictness: the tsconfig

**[TS-01] MUST:** `tsconfig.app.json` is the file below. Every flag in it is on; removing
one requires an ADR, not a PR comment.

```jsonc
// tsconfig.app.json
{
  "compilerOptions": {
    "tsBuildInfoFile": "./node_modules/.tmp/tsconfig.app.tsbuildinfo",
    "target": "es2023",
    "lib": ["ES2023", "DOM", "DOM.Iterable"],
    "module": "esnext",
    "types": ["vite/client"],
    "skipLibCheck": true,

    /* Bundler mode: Vite transpiles, tsc only checks. */
    "moduleResolution": "bundler",
    "resolveJsonModule": true,
    "verbatimModuleSyntax": true,        // an `import type` is erased; a value import is kept
    "moduleDetection": "force",
    "noEmit": true,
    "jsx": "react-jsx",
    "baseUrl": ".",
    "paths": { "@/*": ["src/*"] },       // [STR-13]

    /* Correctness */
    "strict": true,
    "noUncheckedIndexedAccess": true,    // arr[i] is T | undefined
    "exactOptionalPropertyTypes": true,  // `x?: string` cannot be assigned `undefined`
    "noImplicitOverride": true,
    "noImplicitReturns": true,
    "noFallthroughCasesInSwitch": true,
    "useUnknownInCatchVariables": true,  // implied by strict; stated because [TS-09] depends on it
    "erasableSyntaxOnly": true,          // no enums, no parameter properties, no namespaces

    /* Hygiene */
    "noUnusedLocals": true,
    "noUnusedParameters": true,
    "forceConsistentCasingInFileNames": true
  },
  "include": ["src"]
}
```

> **Why per flag:** `noUncheckedIndexedAccess` is the one that finds real bugs: `items[0].name`
> on an empty array is the single most common runtime crash in list code, and without the flag
> the compiler says it is fine. `exactOptionalPropertyTypes` stops `{ title: undefined }` being
> passed where the prop is optional, which React renders as a missing prop but a schema
> serialises as an explicit null. `erasableSyntaxOnly` makes the code compatible with
> transpile-only tooling (Vite, and Node's type stripping) and enforces [TS-16] at the compiler
> level. `verbatimModuleSyntax` makes import elision explicit, which is what stops a
> type-only import accidentally keeping a module in the bundle. `noUnusedLocals`/`Parameters`
> keep dead code from accumulating in files an AI agent edits repeatedly.

**[TS-02] MUST:** An indexed access is narrowed before use, not asserted. `array.at(i)`,
optional chaining, a `??` default or an explicit guard, never `array[i]!`.
> **Why:** `noUncheckedIndexedAccess` exists to make the empty case visible; `!` removes the
> only warning you were going to get. The crash then happens in production against a list
> that was non-empty in every test.

```ts
// WRONG: the flag is on, the assertion turns it back off
const first = features[0]!
map.fitBounds(first.bbox)

// RIGHT
const first = features.at(0)
if (!first) return                                  // empty state is a real state ([GEN-15])
map.fitBounds(first.bbox)
```

**[TS-03] MUST:** With `exactOptionalPropertyTypes`, an optional property (`x?: T`) means
"may be absent" and `x?: T | undefined` means "may be absent or explicitly undefined". Pick
deliberately; do not widen every optional to `| undefined` to silence an error.
> **Why:** Widening everywhere restores the pre-flag behaviour and wastes the check. The
> common real case is a component prop spread from a partial object; the fix is to build the
> object conditionally, not to change the type.

**[TS-04] MUST:** `tsc -b --noEmit` runs in CI and blocks merge ([GEN-23]). `@ts-ignore` is
forbidden; `@ts-expect-error` is allowed only with a reason on the same line and an issue or
upstream link, and it fails the build when the error disappears (which is the point).
> **Why:** `@ts-ignore` silently survives the fix and then hides the next, different error on
> that line. `@ts-expect-error` breaks the build once the underlying problem is gone, which is
> what removes it from the codebase.

---

## 2. Boundaries and escape hatches

**[TS-05] MUST NOT:** `any` appears in any form: `: any`, `as any`, `<any>`, `any[]`,
`Record<string, any>`, `Promise<any>`, or a generic defaulted to `any`. This is checked
mechanically by `tools/check-standards.sh` and by
`@typescript-eslint/no-explicit-any` as an error.
> **Why:** `any` is not "a type I have not written yet", it is a hole that disables checking
> for every value derived from it, silently, in both directions. One `as any` on an API
> response removes type safety from the entire feature that consumes it, which is exactly the
> code most likely to receive a shape change ([GEN-07]). The correct tool at an unknown
> boundary is `unknown` plus narrowing ([TS-07]).

**[TS-06] MUST NOT:** A type assertion (`as T`, `<T>value`) is used, except:
`as const`; the `satisfies` operator (which is not an assertion and is preferred);
re-asserting a brand over `Object.keys`/`Object.entries` of a `Record<BrandedId, T>`; and
narrowing a DOM query result **after** a runtime check. Each exception carries a comment.
> **Why:** An assertion is a claim the compiler accepts without evidence, so it fails at
> runtime rather than at build. `satisfies` gives the same inference benefit while still
> checking. The `Object.keys` case is a genuine language limitation (it returns `string[]` by
> design) and is confined to selectors ([STA-25]).

```ts
// WRONG: three assertions, three unchecked claims
const config = JSON.parse(raw) as AppConfig
const el = document.querySelector('.panel') as HTMLDivElement
const status = response.status as 'active' | 'passive'

// RIGHT
const config = AppConfigSchema.parse(JSON.parse(raw))          // zod validates, then types
const el = document.querySelector('.panel')
if (!(el instanceof HTMLDivElement)) return                    // runtime check, then narrowed
const status = StatusSchema.parse(response.status)

// RIGHT: the allowed brand exception, with the comment the rule requires
// Object.keys returns string[] by design; the keys of this Record are VehicleIds.
const ids = Object.keys(byId) as VehicleId[]
```

**[TS-07] MUST:** Values crossing an untyped boundary (`fetch` response, `JSON.parse`,
`postMessage`, `localStorage`, `window.__APP_CONFIG__`, a URL parameter, a third-party
callback) are typed `unknown` and narrowed with a zod schema or a type predicate before use.
> **Why:** `unknown` forces the narrowing to be written; `any` lets it be forgotten. The
> narrowing is the only place that can produce a useful error message naming the field and
> the source. Cross-ref: [GEN-07], [API-14], [SEC-28].

**[TS-08] MUST NOT:** The non-null assertion `!` is used, with exactly one permitted
occurrence in the codebase: `document.getElementById('root')!` in `src/main.tsx`, where the
element is guaranteed by `index.html` and its absence is an unrecoverable boot failure.
> **Why:** `!` is `as` with less visibility: it produces `Cannot read properties of null` at a
> point far from the assertion, and it is the single most common way a strict codebase drifts
> back to unsafe. Everywhere else the null case is real and needs a branch.

**[TS-09] MUST:** `catch` binds `unknown` and narrows before use: `instanceof ApiError`
first ([API-11]), then `instanceof Error`, then a string fallback. A caught error is either
handled with a defined outcome or rethrown; an empty `catch` is forbidden ([GEN-17]).
> **Why:** JavaScript can throw anything, including a string or a rejected non-Error, so
> `error.message` on an untyped catch is itself a crash inside error handling. The narrowing
> order matters because `ApiError` carries the status and field errors the UI needs.

```ts
try {
  await saveParking(input)
} catch (error: unknown) {
  if (error instanceof ApiError && error.status === 422) {
    form.setErrors(error.fieldErrors())            // a defined outcome
    return
  }
  logger.error('parking.save.failed', { requestId: getRequestId(error) })
  throw error                                      // anything else goes up to the boundary
}
```

**[TS-10] MUST:** Entity identifiers are branded types declared in
`src/shared/types/branded.ts`; a bare `string` or `number` is not accepted where an id is
expected.
> **Why:** Every id in the system is a string, so the compiler cheerfully lets a `VehicleId`
> be passed to `getParking(id)`, and the result is a 404 that looks like a backend bug. A
> brand makes it a compile error at the call site. Cross-ref: [API-27], [GIS-01].

```ts
// src/shared/types/branded.ts
declare const brand: unique symbol
type Brand<T, B extends string> = T & { readonly [brand]: B }

export type VehicleId = Brand<string, 'VehicleId'>
export type ParkingId = Brand<string, 'ParkingId'>

// Constructors live next to the schema that validates the raw value.
export const vehicleId = (raw: string): VehicleId => {
  if (raw.length === 0) throw new Error('vehicleId: empty id')
  return raw as VehicleId
}
```

**[TS-11] MUST:** A promise is never floating. `@typescript-eslint/no-floating-promises` is
an error; a deliberately unawaited call is prefixed with `void` **and** a comment saying why
nothing awaits it, and it handles its own failures.
> **Why:** An unawaited rejection becomes an `unhandledrejection` far from its cause
> ([OBS-07]), with a stack that points at the microtask queue. In an effect it also means the
> cleanup runs before the work finishes, so the component is gone when the result arrives.

```ts
// WRONG
useEffect(() => { refreshTiles() }, [])

// RIGHT: fire and forget, stated as such, with its own error path
useEffect(() => {
  // Prefetch only: a failure degrades to a slower first pan, so nothing awaits it.
  void refreshTiles().catch((error: unknown) => logger.warn('tiles.prefetch.failed', { error }))
}, [])
```

---

## 3. The React Compiler contract

**[TS-12] MUST:** The React Compiler (`babel-plugin-react-compiler`) is enabled for the whole
app ([PERF-09]), so the Rules of React are not style advice: no mutation of props, state or
values received from hooks; no reading or writing refs during render; no conditional hook
calls; pure render bodies. `eslint-plugin-react-hooks` 7's compiler rules run as errors.
> **Why:** The compiler silently **skips** a component that breaks the rules. The failure mode
> is not a crash, it is a component that quietly loses its memoisation while its neighbours
> keep theirs, so a performance regression appears with no diff that explains it. The lint
> rules are how you find out at build time instead.

**[TS-13] MUST NOT:** `useMemo`, `useCallback` or `memo()` is added without an adjacent
comment naming the measurement (what was measured, the before and after numbers) and why the
compiler could not do it.
> **Why:** With the compiler on, hand-written memoisation is redundant in the common case and
> harmful in two: it hides a Rules-of-React violation that made the compiler skip the
> component, and its dependency array goes stale on the next edit. The reference app carried
> 340 `useCallback`s from the pre-compiler era; removing them changed no measured metric.
> Detail: [07](07-PERFORMANCE.md) §3 ([PERF-11]).

```tsx
// WRONG: no measurement, and the dependency array is one edit away from being stale
const rows = useMemo(() => features.map(toRow), [features])
const handleSelect = useCallback((id: string) => setSelected(id), [])

// RIGHT: plain derivation; the compiler memoises it
const rows = features.map(toRow)
const handleSelect = (id: ParkingId) => setSelected(id)

// RIGHT: the exception, with the evidence the rule requires
// Measured 2026-08-30 on 12k parcels: MapLibre's setData re-tiles on reference change.
// Without this the source re-tiled on every parent render (18 ms per render, profiler).
// The compiler cannot help: maplibre-gl is not compiled and compares by identity.
const collection = useMemo(() => toFeatureCollection(parcels), [parcels])
```

---

## 4. Modelling state and values

**[TS-14] MUST:** UI state that has phases is a discriminated union on a `status` field, not
a set of independent booleans.
> **Why:** Four booleans describe sixteen states, of which twelve are impossible, and the
> render body then has to guard against combinations that cannot happen (`isLoading &&
> isError`). A union makes the impossible states unrepresentable and lets the compiler check
> the switch exhaustively. It also puts the data next to the state that guarantees it, so
> `data` is not optional in the success branch.

```tsx
// WRONG: boolean soup. What renders when isLoading and isError are both true?
type State = { isLoading: boolean; isError: boolean; isEmpty: boolean; data?: Parking[] }

// RIGHT: one axis, exhaustive, data present exactly where it exists
type State =
  | { status: 'idle' }
  | { status: 'loading' }
  | { status: 'error'; error: ApiError }
  | { status: 'success'; data: readonly Parking[] }

function ParkingPanel({ state }: { readonly state: State }) {
  switch (state.status) {
    case 'idle':
      return <EmptyState message={t('parking.selectDistrict')} />
    case 'loading':
      return <Skeleton rows={5} />
    case 'error':
      return <ErrorState error={state.error} onRetry={refetch} />
    case 'success':
      return state.data.length === 0 ? <EmptyState /> : <ParkingList items={state.data} />
    // No default: with noFallthroughCasesInSwitch and a union, a new status is a build error.
  }
}
```

**[TS-15] MUST:** `type` is the default. `interface` is used only when a declaration is
genuinely extended (a props type that another component's props extend, an augmented
third-party type).
> **Why:** One default removes a per-file coin flip. `type` covers unions, tuples, mapped and
> conditional types, which `interface` cannot, and it does not silently merge with a
> same-named declaration elsewhere. Declaration merging is a feature exactly once (module
> augmentation) and a hazard the rest of the time.

**[TS-16] MUST NOT:** `enum` and `const enum` are used. A closed set is an `as const` object
plus a union type derived from it.
> **Why:** `enum` emits runtime code, which `erasableSyntaxOnly` ([TS-01]) forbids outright;
> numeric enums are additionally assignable from any number, so `Status.Active` accepts `7`.
> The `as const` form is plain data: iterable, serialisable, and usable as a zod input.

```ts
// RIGHT
export const PARKING_STATUS = { active: 'active', passive: 'passive', full: 'full' } as const
export type ParkingStatus = (typeof PARKING_STATUS)[keyof typeof PARKING_STATUS]

export const ParkingStatusSchema = z.enum(Object.values(PARKING_STATUS))  // one source of truth
```

**[TS-17] MUST:** Array and object props are `readonly` (`readonly Parking[]`,
`ReadonlyMap`), and props, state and hook return values are never mutated in place.
> **Why:** `readonly` is what makes [TS-12]'s "no mutation" rule checkable rather than
> aspirational. `items.sort()` inside a render body mutates the array the parent still holds
> and the compiler's memoisation then serves the mutated value; `[...items].sort()` does not.

**[TS-18] MUST:** A literal number or string with meaning is a named module-level constant in
`UPPER_SNAKE` ([STR-14]), declared next to the code that uses it, with a comment when the
value was chosen rather than derived.
> **Why:** `if (features.length > 5000)` is unreviewable: nobody can tell whether it matches
> [MAP-19] or is a guess. `MAX_GEOJSON_FEATURES = 5_000` is greppable, testable and changes in
> one place. Numeric separators (`5_000`, `86_400_000`) are used for anything above four
> digits.

**[TS-19] MUST:** Guard clauses come first and functions return early; nesting stays at three
levels or fewer inside a function ([STR-25] for the length limits).
> **Why:** The happy path at the lowest indentation is the readable form, and it is the form
> an AI agent edits correctly. Deep nesting is where a missing `return` after an error branch
> hides.

---

## 5. Components and props

**[TS-20] MUST:** A component is a named-export function declaration with an explicitly typed
props parameter, one component per file ([STR-26]), and a return type left to inference.
> **Why:** A named function shows up in React DevTools, in stack traces and in
> `react-refresh` boundaries under its own name; an arrow assigned to a `const` does too, but
> only a declaration hoists, which matters for the private sub-components allowed below the
> main export. Explicit props are the component's contract; an inferred props type from a
> default object is not readable at the call site.

**[TS-21] MUST NOT:** `React.FC` (or `React.FunctionComponent`) is used to type a component.
This is checked mechanically by `tools/check-standards.sh`.
> **Why:** `React.FC` adds nothing the props parameter does not, forces the props type into a
> position where generics are awkward, and (historically) injected an implicit `children` that
> made "this component takes no children" unexpressible. In React 19 its remaining effect is
> to obscure the props type behind a generic wrapper for zero benefit.

```tsx
// WRONG
export const ParkingCard: React.FC<ParkingCardProps> = ({ parking, onSelect }) => { ... }

// RIGHT
type ParkingCardProps = {
  readonly parking: Parking
  readonly isSelected: boolean
  readonly onSelect: (id: ParkingId) => void
  readonly children?: ReactNode          // explicit: this component does take children
}

export function ParkingCard({ parking, isSelected, onSelect, children }: ParkingCardProps) {
  ...
}
```

**[TS-22] MUST:** Props are named by convention: event handlers `on<Event>`
(`onSelect`, `onClose`, `onBoundsChange`), booleans `is<X>`/`has<X>`/`can<X>`
(`isSelected`, `hasPermission`), render props `render<X>`. A prop named `data`, `item`,
`obj`, `info` or `value` (outside form primitives) is forbidden; name it after the domain
(`parking`, `vehicles`, `bbox`).
> **Why:** `data` at three nesting levels means three different things and none of them is
> greppable. `on*` and `is*` let a reader tell a callback from a value without opening the
> type. Handler *implementations* are `handle<Event>`, so the wiring reads
> `onSelect={handleSelect}` and the two sides are distinguishable in a stack trace.

**[TS-23] MUST:** A list `key` is a stable identifier from the data ([GIS-14] for map data);
the array index is a key only for a list that is append-only and never reordered, filtered or
deleted from, and that case carries a comment.
> **Why:** With an index key, deleting the second of five rows makes React reuse the third
> row's DOM node for the second item: focus, scroll position, uncontrolled input values and
> CSS transitions all move to the wrong row. The symptom is reported as "the form clears
> itself", which nobody traces back to a key.

**[TS-24] MUST NOT:** `&&` is used for conditional rendering with a value that can be a
number or an empty string. Use a boolean coercion, a ternary, or an early return.
> **Why:** `{items.length && <List />}` renders a literal `0` when the list is empty, because
> `0` is a valid React child. It survives review because it works whenever the list is
> non-empty. `{items.length > 0 && <List />}` is the fix. Nested ternaries in JSX are
> forbidden for the same readability reason as [TS-19]: extract a component or a switch.

---

## 6. Hooks and effects

**[TS-25] MUST:** Hooks are called at the top level of a component or another hook, never
inside a condition, loop, callback or `try`. `react-hooks/rules-of-hooks` and
`react-hooks/exhaustive-deps` are both **errors**, not warnings.
> **Why:** Hook identity is positional; a conditional call shifts every later hook's state to
> the wrong hook on the next render. `exhaustive-deps` as a warning is a warning nobody reads,
> and a stale closure in an effect is the second most common realtime bug after a missing
> cleanup. When the rule is genuinely wrong, the disable line names which dependency and why
> ([TS-37]).

**[TS-26] MUST:** A custom hook returns a single value or a tuple of at most two; beyond that
it returns a named object. It is named `use<Thing>` and lives in `hooks/` ([STR-04]).
> **Why:** `const [a, b, c, d] = useThing()` binds by position, so inserting a return value in
> the hook silently rebinds every call site to the wrong variable, with matching types often
> enough that it compiles. An object is order-independent and self-documenting at the call
> site.

**[TS-27] MUST:** `useEffect` is used only to synchronise with a system outside React: a
MapLibre instance, a socket subscription, a `ResizeObserver`, a browser API, a video element.
It is never used to compute derived state, to react to a prop change by calling `setState`,
or to fetch data.
> **Why:** An effect that sets state renders twice: once with the stale value the user sees
> for a frame, once with the correct one. Derived values belong in the render body, where the
> compiler memoises them ([TS-12]); a value that must reset when a prop changes uses a `key`
> on the component; data fetching belongs to TanStack Query ([STA-01]), which brings caching,
> deduplication, abort and retry that a hand-written effect never gets right (the reference
> codebase's `useParkingMapData` is the fetch variant of this mistake). The lint rule
> `react-hooks/set-state-in-effect` flags the state case. Cross-ref: [STA-34].

```tsx
// WRONG: derived state through an effect. Renders the stale total first, every time.
function Basket({ items }: Props) {
  const [total, setTotal] = useState(0)
  useEffect(() => {
    setTotal(items.reduce((sum, item) => sum + item.price, 0))
  }, [items])
  return <span>{formatPrice(total)}</span>
}

// RIGHT: derive during render
function Basket({ items }: Props) {
  const total = items.reduce((sum, item) => sum + item.price, 0)
  return <span>{formatPrice(total)}</span>
}
```

**[TS-28] MUST:** Every effect that subscribes, opens, observes or schedules returns a
cleanup that undoes exactly that, and the pair survives StrictMode's mount, unmount, remount
([GEN-21]). Async work inside an effect is guarded against completing after unmount.
> **Why:** React 19 in development mounts every effect twice on purpose. Code that leaks
> under StrictMode leaks in production on every navigation instead: two `resize` listeners,
> two intervals, two MapLibre layers with the same id ([MAP-39]). The double invocation is
> the test, not the bug.

```tsx
// WRONG: no cleanup. Two listeners and a live interval after one StrictMode remount.
useEffect(() => {
  window.addEventListener('resize', handleResize)
  setInterval(refresh, 5_000)
}, [])

// RIGHT: everything acquired is released, and the late async result is ignored
useEffect(() => {
  const controller = new AbortController()
  const timer = setInterval(refresh, REFRESH_INTERVAL_MS)
  window.addEventListener('resize', handleResize, { signal: controller.signal })

  void loadOverlay(controller.signal)
    .then((overlay) => { if (!controller.signal.aborted) setOverlay(overlay) })
    .catch((error: unknown) => { if (!controller.signal.aborted) logger.warn('overlay', { error }) })

  return () => {
    controller.abort()        // removes the listener too: addEventListener took the signal
    clearInterval(timer)
  }
}, [refresh, handleResize])
```

**[TS-29] MUST:** Logic that belongs to a user action lives in the event handler, not in an
effect that watches the state the action changed.
> **Why:** An effect cannot tell *why* the value changed, so "post the analytics event when
> `selectedId` changes" also fires when the id is restored from the URL on load. The handler
> knows the cause. This is also what keeps the effect list short enough to reason about.

---

## 7. React 19 idioms

**[TS-30] MUST:** `use()` is used to read a context (including conditionally, which
`useContext` cannot do) and to unwrap a promise inside a Suspense boundary. A promise passed
to `use()` is created by a cache (TanStack Query's `useSuspenseQuery`, [STA-15]) and never
created in the render body.
> **Why:** A promise created during render is a new promise on every render, so `use()`
> suspends forever in a loop that never settles. `use()` for context is the version that can
> sit behind an early return, which removes the "call the hook then ignore it" pattern.

**[TS-31] MUST:** `ref` is a normal prop on function components. `forwardRef` is not used in
new code, and `useImperativeHandle` only for a genuinely imperative API (focus, scroll,
play).
> **Why:** React 19 passes `ref` through like any other prop, so `forwardRef` is a wrapper
> that costs a component layer in DevTools and an extra generic for nothing. Cleanup functions
> returned from ref callbacks are the React 19 way to release a DOM subscription, which the
> old callback form could not express.

```tsx
type SearchInputProps = {
  readonly ref?: Ref<HTMLInputElement>
  readonly onSearch: (query: string) => void
}

export function SearchInput({ ref, onSearch }: SearchInputProps) {
  return <input ref={ref} onChange={(event) => onSearch(event.target.value)} />
}
```

**[TS-32] SHOULD:** A form with no client-side validation beyond `required` and no field-level
error display uses a form `action` with `useActionState` and `useFormStatus`. Anything with
per-field validation, cross-field rules, a zod schema or a controlled map interaction uses
react-hook-form with the zod resolver ([18](18-FORMS-VALIDATION.md)).
> **Why:** `useActionState` removes a `useState` per field and gives pending state for free,
> which is the right size for a search box or a single-field dialog. It has no field-level
> error model, so a permit application form built on it reimplements react-hook-form badly.
> The boundary is "does a field need its own error message".

**[TS-33] MUST:** Updates that are not the direct visual result of the user's gesture
(applying a filter to a large list, toggling an expensive map layer, switching a tab that
renders a chart) are wrapped in `useTransition`, and the pending flag drives a visible
indicator. `useOptimistic` is used for a mutation whose result the UI can predict.
> **Why:** Without a transition, typing in a filter box that re-renders 2,000 rows blocks
> input between keystrokes and INP records every one ([PERF-15]). A transition keeps the
> input responsive and renders the list when it can. `useOptimistic` removes the
> `onMutate`/rollback boilerplate for the simple predictable cases; the complex ones stay with
> TanStack Query's optimistic update ([STA-13]).

---

## 8. Lint, format, imports and comments

**[TS-34] MUST:** `eslint.config.js` is the file below (ESLint 10 flat config). Every plugin
in the table in [02](02-TECH-VERSIONS.md) §3 is wired; type-aware rules run on `src/**`.

```js
// eslint.config.js
import js from '@eslint/js'
import { defineConfig, globalIgnores } from 'eslint/config'
import importX from 'eslint-plugin-import-x'
import i18next from 'eslint-plugin-i18next'
import jsxA11y from 'eslint-plugin-jsx-a11y'
import reactHooks from 'eslint-plugin-react-hooks'
import reactRefresh from 'eslint-plugin-react-refresh'
import globals from 'globals'
import tseslint from 'typescript-eslint'

// Defined verbatim in [STR-12]; kept in this file, not imported, so one config file is
// the whole lint contract.
const IMPORT_ZONES = [
  { target: './src/shared', from: './src/features', message: 'shared must not import features' },
  { target: './src/shared', from: './src/app', message: 'shared must not import app' },
  { target: './src/features', from: './src/app', message: 'features must not import app' },
  { target: './src/features/*/!(index.ts)', from: './src/features/*/!(index.ts)',
    except: ['./index.ts'], message: 'import another feature only via its index.ts' },
]
const IMPORT_ORDER = {
  groups: ['builtin', 'external', 'internal', 'parent', 'sibling', 'index', 'type'],
  pathGroups: [{ pattern: '@/**', group: 'internal' }],
  'newlines-between': 'always',
  alphabetize: { order: 'asc', caseInsensitive: true },
}

export default defineConfig([
  globalIgnores(['dist', 'coverage', 'playwright-report']),
  {
    files: ['src/**/*.{ts,tsx}'],
    extends: [
      js.configs.recommended,
      // strictTypeChecked, not `recommended`: the rules that need type information
      // (no-floating-promises [TS-11], no-unnecessary-condition) are the ones that find bugs.
      tseslint.configs.strictTypeChecked,
      tseslint.configs.stylisticTypeChecked,
      reactHooks.configs.flat.recommended,   // includes the React Compiler rules ([TS-12])
      reactRefresh.configs.vite,
      jsxA11y.flatConfigs.recommended,       // plugin config shape: verify against the pinned 6.x
      i18next.configs['flat/recommended'],   // plugin config shape: verify against the pinned 6.x
    ],
    languageOptions: {
      globals: globals.browser,
      parserOptions: { projectService: true, tsconfigRootDir: import.meta.dirname },
    },
    plugins: { 'import-x': importX },
    rules: {
      // [TS-05]: the whole point of the standard's type rules.
      '@typescript-eslint/no-explicit-any': 'error',
      '@typescript-eslint/no-unsafe-assignment': 'error',
      '@typescript-eslint/no-unsafe-member-access': 'error',
      '@typescript-eslint/no-unsafe-call': 'error',
      '@typescript-eslint/no-unsafe-return': 'error',
      '@typescript-eslint/no-unsafe-argument': 'error',
      // [TS-08]
      '@typescript-eslint/no-non-null-assertion': 'error',
      // [TS-11]
      '@typescript-eslint/no-floating-promises': 'error',
      '@typescript-eslint/no-misused-promises': 'error',
      // [TS-15], [TS-16]
      '@typescript-eslint/consistent-type-definitions': ['error', 'type'],
      'no-restricted-syntax': ['error',
        { selector: 'TSEnumDeclaration', message: 'Use an `as const` object plus a union ([TS-16])' },
      ],
      // [TS-01] verbatimModuleSyntax needs the type/value split to be explicit.
      '@typescript-eslint/consistent-type-imports': ['error', { fixStyle: 'inline-type-imports' }],
      // [TS-25]: errors, not warnings.
      'react-hooks/rules-of-hooks': 'error',
      'react-hooks/exhaustive-deps': 'error',
      // [SEC-23], [OBS-16]: console.warn/error survive; log/debug/info do not.
      'no-console': ['error', { allow: ['warn', 'error'] }],
      // [STR-10], [STR-12]: import direction and ordering. The full `no-restricted-paths`
      // zone list and the `order` groups live in 03 and are pasted in verbatim here.
      'import-x/no-cycle': ['error', { maxDepth: 4 }],
      'import-x/no-restricted-paths': ['error', { zones: IMPORT_ZONES }],   // see [STR-12]
      'import-x/order': ['error', IMPORT_ORDER],                            // see [STR-12]
    },
  },
  {
    // Tests may use console and non-null assertions on fixtures they own.
    files: ['src/**/*.test.{ts,tsx}', 'src/test/**/*.{ts,tsx}', 'e2e/**/*.ts'],
    rules: { 'no-console': 'off', '@typescript-eslint/no-non-null-assertion': 'off' },
  },
])
```

> **Why `strictTypeChecked`:** it is the only preset that enables the type-aware rules, and
> those are the ones that catch real defects (a floating promise, a condition that is always
> true, an `await` on a non-promise). It costs a slower lint run because ESLint builds the
> type graph; on the reference repo that is roughly 25 s versus 6 s, paid once per CI run.
> Two plugin config keys above (`jsxA11y.flatConfigs.recommended`, `i18next.configs['flat/recommended']`)
> are marked because their exported shape has changed across recent majors; verify the export
> name against the installed version before assuming the config compiles.

**[TS-35] MUST:** `.prettierrc` is exactly this, Prettier owns all formatting, and no ESLint
rule duplicates a Prettier concern (no `indent`, no `quotes`, no `semi`).

```json
{
  "printWidth": 100,
  "singleQuote": true,
  "semi": false,
  "trailingComma": "all",
  "arrowParens": "always",
  "endOfLine": "lf"
}
```

> **Why:** `printWidth: 100` fits a typed React props destructure on one line at the font
> size a side-by-side diff uses; 80 wraps almost every JSX attribute list and 120 makes
> side-by-side review scroll horizontally. `endOfLine: "lf"` is not cosmetic: the team
> develops on Windows and CI runs on Linux, and without it every file shows as fully changed.
> Formatting rules in ESLint conflict with Prettier and produce fix loops.

**[TS-36] MUST:** Imports are ordered by `import-x/order` in the groups defined in [STR-12]
(builtin, external, internal `@/`, parent, sibling, index, type) with a blank line between
groups and alphabetical order inside them; type-only imports use `import type` (or inline
`type`) as `verbatimModuleSyntax` requires; relative imports stay inside a feature ([STR-13]).
> **Why:** A deterministic order removes the import block from every diff, which is where
> merge conflicts in an actively edited file mostly come from. The `@/` group is the visual
> line between "this feature" and "the rest of the app", which is what makes an import
> direction violation ([STR-10]) visible in review before the linter reports it.

**[TS-37] MUST:** An `eslint-disable` comment names the single rule, is scoped to one line
(`eslint-disable-next-line`), and carries a reason after `--`. File-level disables and bare
`eslint-disable` are forbidden.
> **Why:** A file-level disable silences the rule for code written next year by someone who
> never saw the comment. The reason is what lets a reviewer decide whether the exception still
> holds, which is the same argument as [TS-04] for `@ts-expect-error`.

**[TS-38] MUST:** Comments explain **why**, not what ([STR-28]). A comment that restates the
code is deleted. A workaround, a browser or library quirk, a measurement, an ordering
constraint or a deliberate deviation is exactly what a comment is for, and it includes the
number or the link. JSDoc is written for exported functions in `src/shared/` only.
> **Why:** `// increment the counter` above `counter += 1` is noise that trains readers (and
> agents) to skip comments, so the one comment that says "MapLibre must remove layers before
> sources" gets skipped too. Every comment in the examples in this standard is of the second
> kind; that is the standard.

---

## Open questions

- **`@typescript-eslint/no-unnecessary-condition` on data from zod.** `strictTypeChecked`
  enables it, and it fires on defensive checks against values a schema already guarantees.
  Those checks are sometimes right (the schema can be looser than the code assumes) and
  sometimes dead code. Currently handled case by case with [TS-37] disables; revisit if the
  disable count in a repo passes ten.
- **A shared `tsconfig` package.** Each app repeats [TS-01]'s file. Once a third app exists,
  the options become a published base config that each app extends, at the cost of an npm
  package to version ([STR-01] open question on workspaces is the same decision).
- **`useActionState` boundary.** [TS-32] is a SHOULD because the reference deployment has no
  form simple enough to prove the boundary in production. Promote to MUST once two forms have
  shipped on each side of it.
