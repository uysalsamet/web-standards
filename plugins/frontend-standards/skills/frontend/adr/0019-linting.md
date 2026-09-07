# ADR-0019 — Linting and formatting: ESLint 10 flat config (type-aware) + Prettier

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-23], [STR-12], [TS-30]..[TS-34], [A11Y-01], [I18N-03], [CI-03]

## Context

The standard has ~500 rules; humans and agents will not remember them. Everything that a
tool can check must be checked by a tool, on every PR, as an error. The lint setup is
therefore part of the standard, not a personal preference. It must enforce: import
direction, hook rules with React Compiler awareness, type-aware TypeScript rules (floating
promises, unsafe `any`), accessibility, no literal strings, and a formatting baseline nobody
argues about.

## Options

### A) ESLint 10 flat config with typescript-eslint `strictTypeChecked` + plugins + Prettier (CHOSEN)
**Strengths:**
- Type-aware rules (`no-floating-promises`, `no-unsafe-*`, `no-misused-promises`,
  `switch-exhaustiveness-check`) catch the async and narrowing bugs that dominate the
  reference tracker. Only ESLint + typescript-eslint provide these today.
- Plugin coverage for every enforcement point the standard needs: `react-hooks` 7 (includes
  compiler rules), `jsx-a11y`, `i18next`, `import-x` (restricted paths, cycles, order),
  `react-refresh`.
- Flat config is a single JS file, composable, and the only format ESLint 10 supports.
- Prettier takes formatting out of ESLint entirely: no style rules to maintain, no
  `eslint --fix` fighting the formatter, one `.prettierrc` shared across apps.

**Weaknesses:**
- Type-aware linting is slow: 40 to 90 s on the reference repo in CI. Mitigated by
  `projectService` and caching; still the slowest gate.
- Two tools (ESLint + Prettier) with two configs and one integration rule (`eslint-config-prettier` to disable conflicts).
- Plugin version drift across ESLint majors; each plugin's flat-config export shape differs
  and must be pinned in `02`.

### B) Biome (lint + format in one Rust tool)
**Strengths:** 10 to 50× faster, one tool, one config, Prettier-compatible formatting,
growing rule set.
**Weaknesses:** No type-aware rules (the ones we need most); no equivalents for
`jsx-a11y`, `i18next`, `import-x/no-restricted-paths`; plugin system immature. Could replace
Prettier alone, but running Biome for format and ESLint for lint is two tools again with a
newer one; no net simplification yet.

### C) oxlint
**Strengths:** Extremely fast, growing React and TS rule coverage, same authors as
Rolldown so future Vite integration is plausible.
**Weaknesses:** Type-aware rules are early; plugin ecosystem does not cover a11y/i18n/import
restrictions at the level we need. Good as a fast pre-check, not as the gate.

### D) ESLint with style rules, no Prettier
**Strengths:** One tool.
**Weaknesses:** Style rules in ESLint are deprecated upstream and slow; formatting debates
return. Rejected.

## Decision

**ESLint 10 (flat, type-aware) with the plugin set in `02`, and Prettier for formatting.**
Reason: it is the only combination that enforces every mechanically checkable rule in the
standard today. Speed is a cost we pay in CI, not a reason to enforce less.

## Accepted costs

- Lint time in CI (up to 90 s). Cache `.eslintcache`; run `oxlint` locally as a fast
  pre-check if desired (not a gate).
- Two tools and the `eslint-config-prettier` bridge.
- Each ESLint major requires re-verifying every plugin's flat-config export; this is a
  scheduled task under [VER-08].
- Zero-warning policy (`--max-warnings 0`) means a new rule rollout needs a one-time
  cleanup PR per app before it can be enabled as an error.

## What would change this decision

- Biome or oxlint shipping type-aware rules and an a11y/i18n/import-boundary rule set at
  parity. Then the gate could move and lint time would drop by an order of magnitude.
- typescript-eslint dropping support for the pinned TS line before TS 7 parity is reached.
