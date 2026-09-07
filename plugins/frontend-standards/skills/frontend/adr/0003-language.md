# ADR-0003 — Language: TypeScript 6, strict, no escape hatches

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-01], [GEN-07], [VER-03], [TS-01]..[TS-12]

## Context

The choice is not "TypeScript or JavaScript"; nobody proposes untyped code for a 60-feature
app. The real decisions are: how strict, which compiler line, and whether escape hatches
(`any`, `as`, `!`) are allowed by policy. These decide whether types are documentation or
a guarantee, and whether API boundary bugs surface at the boundary or three screens later.

## Options

### A) TypeScript 6.0.x, `strict` + extra flags, escape hatches lint-forbidden (CHOSEN)
**Strengths:**
- `strict`, `noUncheckedIndexedAccess`, `exactOptionalPropertyTypes` and
  `useUnknownInCatchVariables` together remove the four most common runtime crashes in the
  reference codebase's error tracker: undefined index access, `null` where `undefined` was
  typed, optional-vs-undefined confusion, and `error.message` on a non-Error.
- Forbidding `any`/`as`/`!` by lint makes the boundary rule ([GEN-07]) enforceable: the
  only way to get a typed value from JSON is a schema.
- `verbatimModuleSyntax` + `erasableSyntaxOnly` keep the code compatible with
  type-stripping runtimes and with TS 7's native compiler, so the next upgrade is cheaper.
- 6.0 is the last JS-implemented line and the bridge release to 7; it deprecates what 7
  removes, so warnings now are errors later, on our schedule.

**Weaknesses:**
- Strict flags increase friction in the first weeks; `exactOptionalPropertyTypes` in
  particular breaks habits (`{ a?: string }` no longer accepts `a: undefined`).
- Schema parsing at every boundary is runtime cost (microseconds per response; measured as
  irrelevant) and code volume (one schema per DTO).
- Type-check time on a large repo is tens of seconds with `tsc`; TS 7 will fix this but is
  not yet adopted ([VER-03]).

### B) TypeScript 7.x (native compiler)
**Strengths:** 8 to 10× faster type-checking, same language; the future of the toolchain.
**Weaknesses:** 7.0 shipped weeks before this ADR; Vite's `tsc -b` integration, editor
plugins and `typescript-eslint` type-aware rules are still catching up; API-consuming
tools (`typescript-eslint`, code generators) need the new API. Adopting the first release of
a compiler rewrite into a standard that AI agents apply blindly is the wrong risk. Path:
verify on the reference repo, then move all apps together ([GEN-02]).

### C) TypeScript with `strict: false` or per-file `// @ts-nocheck` tolerance
**Strengths:** Fastest onboarding of legacy code, fewer red squiggles.
**Weaknesses:** Types become suggestions. Every `any` is a hole through which a `null`
travels to a crash. The reference codebase's `serializableCheck: false` and `as`-typed
fetches are exactly what this option produces. Rejected outright.

### D) JSDoc-typed JavaScript checked by `tsc`
**Strengths:** No build step for types, gradual.
**Weaknesses:** Verbose for generics and unions; tooling and agent support weaker; no
benefit over TS when a build step exists anyway (Vite).

## Decision

**TypeScript 6.0.x with the strict flag set from [TS-01] and escape hatches forbidden by
lint.** Reason: the value of types is proportional to how few holes they have. The cost of
strictness is paid once, at authoring; the cost of holes is paid at 3 a.m.

## Accepted costs

- More code at boundaries (zod schemas). Accepted because the alternative is trusting the
  network.
- Occasional fights with library typings that are not strict-clean; solved with a typed
  wrapper in `src/shared/lib/`, never with `any`.
- Delayed TS 7 benefits (compile speed) until parity is verified.
- Developers coming from looser codebases need a week. The WRONG/RIGHT pairs in `21` exist
  for that week.

## What would change this decision

- TS 7.1+ with documented parity for `tsc -b`, `typescript-eslint` type-aware rules and
  `vite build` on the reference repo. Then the pinned line moves to 7.x for all apps.
- A type-checking time above 2 minutes in CI on the reference repo before 7 is ready would
  justify moving 7 forward with reduced lint coverage as a temporary cost.
