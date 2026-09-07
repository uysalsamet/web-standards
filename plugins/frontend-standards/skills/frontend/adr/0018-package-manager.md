# ADR-0018 — Package manager: npm with a committed lockfile and `npm ci`

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [VER-04], [VER-09], [OPS-01], [CI-01]

## Context

The package manager decides install determinism (does the server get the same tree as the
laptop?), install speed in CI and Docker, supply-chain posture (lifecycle scripts,
provenance) and how many tools every developer and every base image must have. The
reference project hit a real production bug from non-determinism: `npm install` on the
server resolved a different tree than the laptop, producing two React copies.

## Options

### A) npm (bundled with Node 24), `npm ci`, lockfile v3 (CHOSEN)
**Strengths:**
- Zero extra tooling: present in `node:24-alpine`, on every CI runner, on every laptop.
- `npm ci` is fully deterministic from `package-lock.json` and refuses to run when the
  lock and manifest disagree. This alone fixes the bug above.
- `overrides`, `ignore-scripts`, provenance verification (`npm audit signatures`) and
  workspaces are all built in.
- Every AI agent knows npm's exact commands and flags; fewer wrong invocations.

**Weaknesses:**
- Slower cold installs than pnpm (roughly 1.5 to 2× on the reference repo: 55 s vs 30 s),
  partly offset by CI and Docker layer caching.
- Flat `node_modules` allows phantom dependencies (importing a package you did not
  declare). Mitigated by `eslint-plugin-import-x/no-extraneous-dependencies`.
- Disk usage per project higher than pnpm's content-addressed store.

### B) pnpm
**Strengths:** Fast, strict (no phantom deps), disk-efficient, excellent workspaces.
**Weaknesses:** Another binary to install in every image and runner (`corepack` helps but
adds its own version pinning); strictness breaks some poorly-declared packages and needs
`.npmrc` hoisting exceptions; agents sometimes mix npm and pnpm commands, leaving two
lockfiles. The speed gain is real but mostly hidden behind caching.

### C) Yarn (Berry)
**Strengths:** PnP mode eliminates `node_modules`, good workspaces, plugins.
**Weaknesses:** PnP compatibility issues with tooling (editors, Vite plugins, Playwright);
`node_modules` linker mode gives up the main advantage; smallest mindshare of the three in
2026; agents frequently produce Yarn 1 syntax.

### D) Bun as package manager
**Strengths:** Fastest installs by a wide margin, drop-in for most projects.
**Weaknesses:** Lockfile format changes, Windows support still trailing, and the
organisation develops on Windows; separate runtime semantics if anyone runs scripts with
`bun` instead of `node`. Not enough maturity for a binding standard.

## Decision

**npm with `npm ci` everywhere.** Reason: determinism and zero extra tooling outweigh
install speed, which caching mostly hides.

## Accepted costs

- Slower cold installs. Docker layer caching of `npm ci` ([OPS-04]) and CI cache keyed on
  the lockfile make this a one-time cost per lockfile change.
- Phantom dependencies are possible; the lint rule and review catch them.
- `--legacy-peer-deps` is occasionally needed while a library's peer range lags React 19;
  allowed only with a named package and a removal condition ([VER-04]).

## What would change this decision

- Adoption of npm workspaces for shared packages across three or more apps, where pnpm's
  workspace and strictness advantages become daily savings. That would be a repo-wide
  switch, not a per-app one.
- npm regressing on determinism or dropping `ignore-scripts` semantics.
