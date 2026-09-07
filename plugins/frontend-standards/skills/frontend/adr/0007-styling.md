# ADR-0007 — Styling: Tailwind 4 + scoped CSS files, no runtime CSS-in-JS

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [VER-05], [A11Y-14]..[A11Y-18], [PERF-15], [STR-04] (styles folder)

## Context

Styling decides bundle composition, runtime cost of rendering (INP), how design tokens are
shared (colour, spacing, z-index scale), how dark mode works, and how MapLibre's own DOM
(popups, controls, attribution) is themed. The reference codebase mixes Tailwind utilities
with per-feature `.css` files and inline `style` objects; the inline objects are the part
that hurt (no tokens, no theme, repeated magic numbers).

## Options

### A) Tailwind 4 utilities + one tokens file + scoped CSS for what utilities cannot express (CHOSEN)
**Strengths:**
- Zero runtime: styles are static CSS, generated at build from used classes. INP is not
  affected by styling code.
- Tailwind 4's CSS-first config (`@theme` in `src/shared/styles/index.css`) makes design
  tokens plain CSS variables, usable from MapLibre popups, `.css` files and Tailwind alike.
  One token file, three consumers.
- Co-location: the class list is in the JSX, reviewers see layout and behaviour together.
- Dark mode via `data-theme` + `prefers-color-scheme` with the `@variant` directive; no JS
  theme provider needed for CSS.
- The Vite plugin (`@tailwindcss/vite`) is first-party and fast.
- AI agents generate Tailwind class lists with very high accuracy.

**Weaknesses:**
- Long class strings reduce readability of complex components; mitigated by extracting
  components, not by `@apply` (which is forbidden except in the tokens file).
- Some things are not expressible as utilities: keyframe animations, MapLibre control
  overrides (`.maplibregl-popup-content`), complex `:has()` selectors, print styles. They go
  to the feature's `styles/<Component>.css`, which is the second mechanism the "one way"
  principle would rather not have.
- Utility discipline (spacing scale, colour tokens) must be enforced by review; Tailwind
  allows `p-[13px]` arbitrary values, which the standard limits ([A11Y-15]).

### B) CSS Modules only
**Strengths:** Plain CSS, scoped by build, no new syntax, works with any tool.
**Weaknesses:** No shared spacing/colour discipline unless tokens are re-declared and
manually referenced everywhere; more files; more naming; slower authoring. Agents produce
more inconsistent output (each file invents its own class names).

### C) Runtime CSS-in-JS (styled-components, Emotion)
**Strengths:** Dynamic styles from props, full JS in styling, colocated.
**Weaknesses:** Runtime style injection on every render path costs INP, doubles React 19
concurrent-rendering complexity (style insertion during render), adds 12 to 20 KB gz, and
conflicts with a CSP that forbids inline styles. React's own docs recommend against runtime
CSS-in-JS for new code. Forbidden in [VER-05].

### D) Zero-runtime CSS-in-JS (vanilla-extract, Panda CSS, StyleX)
**Strengths:** Typed styles, tokens as TS, static output.
**Weaknesses:** Another compiler in the build, smaller ecosystem, agents less reliable,
and for our needs no advantage over Tailwind's `@theme` tokens. Revisit if typed tokens
become a real pain point.

### E) A component library with its own styling (MUI, Ant Design, Mantine)
**Strengths:** Complete component set, accessibility work done, theming built in.
**Weaknesses:** 100 to 300 KB gz before the map loads; opinionated look that municipal
brands then fight; their runtime CSS-in-JS (MUI/Ant) inherits option C's costs. A headless
primitive library (Radix, React Aria) is a separate, allowed decision if the a11y burden of
hand-rolled modals/menus becomes measurable; it is not in `02` yet (see Open questions in 16).

## Decision

**Tailwind 4 with a single `@theme` tokens file, plus scoped `.css` files for the
residue.** Decisive reasons: zero runtime, tokens shared with non-React DOM (MapLibre), and
agent reliability.

## Accepted costs

- Two styling mechanisms (utilities + scoped CSS). Limited by rule: CSS files may contain
  only what utilities cannot express, and every value in them comes from a token.
- Class-string length in complex components; the fix is smaller components ([STR-25]).
- `style-src 'unsafe-inline'` remains in the CSP because MapLibre and some libraries set
  inline styles; Tailwind itself does not need it ([SEC-05] notes what would remove it).
- No ready-made component set. Shared components in `src/shared/components/` are built and
  maintained by us, with the a11y rules from `16`.

## What would change this decision

- A CSP requirement that forbids `unsafe-inline` for styles with no way to nonce MapLibre's
  inline styles; then a zero-runtime typed solution would be evaluated for the residue.
- Tailwind changing its config model again in a way that breaks `@theme` tokens.
- A measured need for typed tokens across more than two apps, where `@theme` variables
  proved error-prone.
