# ADR-0002 — UI framework: React 19

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-01], [GEN-02], [TS-20]..[TS-30]

## Context

One UI framework for every frontend. The choice sets the hiring pool, the component
ecosystem (map wrappers, editors, charts, virtualisers), the testing tools, and how much
correct code an AI agent produces per attempt. The organisation already has a large React
codebase in production; that is a fact, not an argument, and is weighed below as a cost of
switching rather than as a reason to stay.

## Options

### A) React 19 (CHOSEN)
**Strengths:**
- The React Compiler removes the manual `useMemo`/`useCallback` discipline that produced
  most performance bugs and most review noise in the reference codebase ([TS-27]).
- React 19 idioms (`use()`, ref as prop, native `<title>`/`<meta>` hoisting, actions) cut
  library dependencies: no `forwardRef`, no helmet.
- Largest ecosystem for our specific needs: TanStack Query/Virtual/Table, react-hook-form,
  react-i18next, Testing Library, Playwright component tooling. MapLibre has no framework
  binding requirement; we use it directly.
- By a wide margin the framework AI agents generate most correctly. This standard is applied
  by agents; first-attempt correctness is a real cost driver.
- Existing production code and team knowledge.

**Weaknesses:**
- Rendering model requires discipline: effects are easy to misuse, and stale closures are a
  recurring bug class. The standard compensates with lint (`react-hooks` 7 with compiler
  rules as errors) and [TS-25]..[TS-29].
- Bundle: React 19 core is ~45 KB gz, larger than Svelte/Solid output for small apps.
  Irrelevant next to a 250 KB MapLibre chunk, but real for a marketing site.
- No built-in router, data layer or forms. Each is a separate decision (ADR-0004/5/6/15).

### B) Vue 3
**Strengths:** Excellent DX, official router and state library, single-file components,
smaller runtime, gentler learning curve.
**Weaknesses:** Smaller ecosystem for GIS-adjacent needs (virtualisers, form libs at the
same maturity); a full rewrite of production code; team retraining; AI-generated Vue is
measurably less reliable on Composition API edge cases than React in our experience. No
capability we need that React lacks.

### C) SolidJS
**Strengths:** Fine-grained reactivity, no virtual DOM, smallest runtime, very fast updates,
JSX familiarity.
**Weaknesses:** Ecosystem an order of magnitude smaller; fewer mature form/query/i18n
libraries; hiring pool small; AI code generation noticeably weaker. The performance edge
does not matter where our cost is (map rendering happens in WebGL, not the DOM).

### D) Svelte 5
**Strengths:** Compiler-based, minimal runtime, runes are a clean reactivity model,
SvelteKit is a good full-stack story.
**Weaknesses:** Same ecosystem and hiring arguments as Solid; SvelteKit pushes toward a
Node runtime we do not want by default ([ADR-0001](0001-build-tool.md)).

## Decision

**React 19 with the React Compiler enabled.** Decisive reasons: ecosystem fit for maps,
forms and data; agent-generated code reliability; and the compiler removing a whole class
of manual optimisation bugs. Existing code makes the decision cheaper to keep but was not
the reason.

## Accepted costs

- Larger baseline runtime than compiled frameworks. Accepted because it is below 5 % of
  our typical initial payload.
- The standard must carry rules that other frameworks enforce by design (effect discipline,
  derived-state rules, cleanup). That is files 05 and 21.
- React major upgrades are org-wide events ([GEN-02]). React 19 brought breaking changes
  (ref handling, `act` semantics, removed APIs); the next one will too.
- Compiler correctness depends on following the Rules of React; code that breaks them is
  silently not optimised. Lint rules from `eslint-plugin-react-hooks` 7 are errors, not
  warnings, for this reason.

## What would change this decision

- A product class where DOM update cost dominates (dense real-time tables at 60 fps with
  thousands of cells) and measurements show React's reconciliation as the bottleneck after
  virtualisation. That product would get its own ADR.
- React Compiler being withdrawn or failing on the reference codebase across a major.
- A measured, sustained drop in agent-generated React correctness relative to an
  alternative. Not expected.
