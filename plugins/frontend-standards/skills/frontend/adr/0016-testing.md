# ADR-0016 — Testing: Vitest + Testing Library + MSW, with Playwright for a smoke suite

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-23], [TEST-01], [TEST-05], [TEST-08], [TEST-11], [TEST-31], [CI-05], [CI-13]

## Context

The test suite has to be worth its maintenance cost on applications where most of the risk
is in three places: data at the API boundary (a field turns null and a screen crashes,
[GEN-07]), asynchronous UI states (loading, empty, error, retry, [GEN-15]) and lifecycle
cleanup (a map layer or an MQTT subscription that outlives its component, [GEN-21]). None
of those are caught by types.

The stack is Vite 8 + React 19 + TypeScript ([02](../02-TECH-VERSIONS.md)), and the suite
must run in CI as a merge gate ([GEN-23]) fast enough that nobody wants to skip it. The
map is a WebGL canvas, which no DOM-based runner can render, so map code has to be testable
without pixels ([TEST-21], [TEST-23]).

## Options

### A) Vitest + Testing Library + MSW, plus Playwright for a small e2e smoke suite (CHOSEN)

**Strengths:**
- **One config.** Vitest reuses `vite.config.ts` through `mergeConfig`, so the `@/` alias,
  the React plugin, the React Compiler transform and the env handling are identical in
  tests and in the build ([TEST-05]). There is no second transform pipeline to keep in sync,
  which is where Jest-on-Vite setups rot.
- **Speed.** ESM-native with Vite's transform pipeline and worker threads. The reference
  suite runs in well under the 180 s the gate budgets ([CI-05]); a watch-mode re-run of one
  file is sub-second, which is what makes people actually write tests.
- **MSW mocks the network, not the client.** Handlers intercept at the request layer, so
  the real `src/shared/api/client.ts` runs: its timeout, its error normalisation and its
  zod parsing are all exercised ([TEST-11], [GEN-06]). `vi.mock('@/shared/api/client')`
  would test a fiction. The same handlers double as the offline dev data source
  ([TEST-13]), so they are maintained because developers use them daily, not only CI.
- **Testing Library forces behavioural assertions.** Queries are by role and label, which
  makes the tests double as an accessibility check ([GEN-16]) and makes them survive
  refactors that change markup but not behaviour.
- **Playwright covers what jsdom cannot:** real navigation, cookies as the browser sets
  them ([AUTH-02]), a real WebGL context for the map, and the built Docker image rather
  than the dev server ([TEST-35]). Traces on failure make a CI-only failure debuggable.
- Vitest's API is Jest-compatible, so the existing knowledge (and the training data every
  AI agent has) transfers unchanged.

**Weaknesses (the honest ones):**
- **Four tools, four failure modes.** MSW version majors have changed the handler API
  (`rest` to `http`); jsdom lags real browsers on newer DOM APIs and needs polyfills for
  `ResizeObserver`, `matchMedia` and `IntersectionObserver` in `src/test/setup.ts`.
- **jsdom is not a browser.** Layout is fake: no real scrolling, no element sizes, no
  `getBoundingClientRect` values other than zeros. Anything measured in pixels, and every
  MapLibre interaction, is untestable at this layer and has to be either a pure-function
  test ([TEST-22]) or a Playwright test.
- **The map is mocked, not run** ([TEST-21]). We assert that the right sources, layers and
  listeners were registered and cleaned up. A bug inside MapLibre, or a wrong paint
  expression that still parses, passes.
- **Playwright is the flakiest and slowest part** of the pipeline, which is precisely why
  it is kept to a smoke suite and off the PR path ([CI-13]). That means an e2e regression
  is discovered after merge, not before.
- Vitest 5 is a recent major; some config keys (`pool`, coverage thresholds per glob) must
  be re-verified on upgrade ([TEST-05] carries that note in a comment).

### B) Jest + Testing Library

**Strengths:** The most widely known runner, the largest plugin ecosystem, very stable.
**Weaknesses:** It needs its own transform (`babel-jest` or `ts-jest` or SWC) and its own
module resolution config, so a Vite app maintains two build pipelines that must agree about
aliases, ESM interop and the React Compiler transform. They drift, and the symptom is a
test that fails only in CI. Jest is also slower on ESM-heavy dependency graphs, and every
Vite plugin behaviour (asset imports, `import.meta.env`) has to be re-implemented in the
Jest config. No benefit here that Vitest does not already provide.

### C) Cypress for e2e

**Strengths:** Excellent interactive debugging experience, mature ecosystem, easy for
newcomers.
**Weaknesses:** Runs the app inside its own browser harness with a same-origin model that
complicates login flows across origins; parallelisation across shards is a paid feature;
trace/artefact story on CI is weaker than Playwright's. Playwright's multi-browser support,
free sharding, `page.route` control and trace viewer cover our needs at no licence cost. In
addition our e2e suite must drive a WebGL canvas and wait for a `window.__mapIdle` flag
([TEST-34]), which both tools can do, so the tie is broken by cost and CI ergonomics.

### D) No e2e at all, unit and component tests only

**Strengths:** Fastest pipeline, least flake, least maintenance.
**Weaknesses:** Nothing then verifies the artefact we actually ship. The failures that hurt
most in the reference project were integration failures invisible to jsdom: a cookie not
set because of a `SameSite` attribute, an nginx proxy prefix swallowing a route ([RTE-16]),
a `config.js` that still contained `${APP_API_BASE_URL}`. A ten-test smoke suite against
the built image catches all three. Rejected, but its argument is why the suite stays at ten
tests and not two hundred.

## Decision

**Vitest 5 + Testing Library + MSW for everything that can run headless, and Playwright for
a smoke suite of about ten flows against the built Docker image.** Coverage thresholds are a
merge gate at 70 % lines / 60 % branches overall and 90 % for pure logic directories
([TEST-05]); the e2e suite runs on `main` and nightly, not on pull requests ([CI-13]).

## Accepted costs

- jsdom's fake layout means an entire class of bugs (sizing, scrolling, overflow, sticky
  headers) is not covered by the fast suite and reaches either Playwright or production.
- Map correctness is verified structurally, not visually. A wrong colour ramp or a
  mis-ordered layer that still registers passes the suite ([TEST-23] forbids pretending
  otherwise with pixel assertions).
- Four tools to upgrade, and MSW and Vitest majors have both broken configs before.
- Post-merge e2e means a broken login flow is detected after it is on `main`. Mitigated by
  blocking the deploy on a red `main` e2e run and opening an issue automatically ([CI-13]).
- Coverage thresholds invite gaming (a test that renders a component and asserts nothing
  raises the number). [TEST-38] states explicitly that the threshold is a floor, and review
  is what enforces the intent.

## What would change this decision

- Playwright component testing reaching stability with the Vite 8 pipeline. Real browser
  layout for component tests would remove the jsdom weakness and could replace the jsdom
  environment for the subset of tests that depend on layout.
- A native browser-mode runner in Vitest becoming production-grade for our stack. Same
  effect: the fast suite would stop being a fake DOM.
- The e2e suite growing past roughly 25 tests or 10 minutes. At that point it is no longer a
  smoke suite, and it needs sharding and a decision about which tests block a deploy.
