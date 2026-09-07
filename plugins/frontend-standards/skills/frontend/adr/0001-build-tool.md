# ADR-0001 — Build tool: Vite 8

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-01], [VER-01], [PERF-01]..[PERF-05], [OPS-01]

## Context

Every frontend needs one build tool that produces a static bundle nginx can serve. The
tool decides dev-server speed, code-splitting behaviour, how environment values enter the
bundle, and which ecosystem of plugins (compression, visualiser, React Compiler) is
available. It also decides how much AI-generated configuration is correct on the first try.

The organisation's apps are single-page applications with heavy client-side rendering
(MapLibre, charts, editors). Server-side rendering is a narrow SEO concern (file 10), not
the default runtime model.

## Options

### A) Vite 8 (CHOSEN)
**Strengths:**
- Rolldown-based production build (Rust): full builds of the reference app dropped from
  ~90 s (Vite 5 / Rollup) to under 20 s on the same machine, which changes how often people
  run a real build locally.
- Dev server with native ESM and pre-bundled deps; HMR under 100 ms on a 60-feature app.
- The largest React tooling ecosystem outside Next.js: `@vitejs/plugin-react` with React
  Compiler support, compression plugins, visualiser, MSW and Vitest share the config.
- `advancedChunks` gives explicit control over chunk grouping, which we need to force a
  single React copy ([PERF-03]).
- Config is TypeScript and small; AI agents produce correct `vite.config.ts` reliably.

**Weaknesses:**
- Vite 8 moved to Rolldown; some Rollup-era plugins are not yet ported or behave
  differently (chunking hooks in particular). Each plugin in `02` was verified on 8.x.
- Two different bundlers in dev (esbuild pre-bundling + native ESM) and prod (Rolldown)
  can hide prod-only issues. The reference app hit a prod-only "two React copies" bug this
  way. Mitigation: `npm run build && npm run preview` is part of the checklist.

### B) Next.js
**Strengths:** SSR/SSG/ISR built in, file routing, image optimisation, the most complete
answer to SEO.
**Weaknesses:** Requires a Node runtime in production (a different container, memory
profile and failure mode than static nginx); pulls the whole app into its rendering model
even when 95 % of pages are behind a login; a 100 MB+ image; vendor-shaped conventions
(App Router, server components) that change every major. For an org whose main products
are authenticated GIS dashboards, this is paying for SEO on every page to get it on five.
SEO needs are solved without a stack change in [ADR-0012](0012-seo-strategy.md).

### C) Rspack / Rsbuild
**Strengths:** Very fast, webpack-compatible plugin API, good for migrating webpack apps.
**Weaknesses:** Smaller React-specific ecosystem; no existing webpack apps to migrate; AI
tooling produces webpack-era config that only mostly works. No advantage over Vite for a
greenfield standard.

### D) Parcel / esbuild directly
**Strengths:** Zero config (Parcel), extremely fast (esbuild).
**Weaknesses:** esbuild alone has no HMR, no CSS code-splitting strategy and no plugin
ecosystem for React Compiler; Parcel's ecosystem is a fraction of Vite's. Both lose on the
"AI writes correct config" axis.

## Decision

**Vite 8.** Decisive reasons: static output that matches the nginx serving model
([ADR-0013](0013-static-serving.md)); explicit chunk control; the ecosystem shared with
Vitest and MSW; build speed that keeps people running real builds.

## Accepted costs

- Rolldown is younger than Rollup. Plugin compatibility is verified per plugin and listed
  in `02`; a plugin not in the table is not assumed to work.
- Dev/prod bundler asymmetry. The checklist requires a production build + preview before
  "done" on any change to chunking, dependencies or `vite.config.ts`.
- No SSR by default. Tier 2 SEO products need the sidecar or SSR route handler from
  [ADR-0012](0012-seo-strategy.md), which is extra infrastructure to run.
- Environment values are build-time by design (`import.meta.env`). We deliberately do not
  use that for per-environment values ([ADR-0014](0014-runtime-config.md)), which costs one
  extra `<script>` tag and a global.

## What would change this decision

- A product where most pages must be indexed and personalised per request. That is a
  full-SSR product and would get its own ADR choosing Next.js or Vike for that product only.
- Rolldown breaking a plugin we depend on with no port within one release cycle.
- Vite's React plugin dropping React Compiler support, or the compiler moving to a
  different integration point.
