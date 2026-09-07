# Automated audit tools

> The **machine-checkable** part of the standard lives here. The aim is to take load off
> the human (and the AI): a rule that can be caught mechanically is not left to code review.
>
> **These tools do not replace the standard.** They check roughly a tenth of the rules; the
> rest is left to the signal scan in [RULE-MAP.md](../RULE-MAP.md) §1 and the checklist in
> [15-NEW-FEATURE-CHECKLIST.md](../15-NEW-FEATURE-CHECKLIST.md).

---

## Files

| File | What it does |
|---|---|
| `check-standards.sh` | Cross-cutting rules: dependencies, secrets, source patterns, structure, Docker, compose, nginx, route/proxy collisions |
| `check-i18n.mjs` | Locale key parity, placeholder parity, plural parity, empty values, unused keys |
| `check-bundle-size.mjs` | Bundle budgets against `budget.json` |
| `nginx-smoke.sh` | Renders the nginx template with a dev env file and runs `nginx -t` in the image |
| `check-refs.mjs` | Consistency of the standard itself: duplicate or undefined rule ids, numbering gaps, placeholder ids, broken links |
| `fixtures/compliant-app/` | A minimal app that follows the standard. Used to prove the tools produce no false positives |

They complement each other with ESLint: ESLint reads the TypeScript AST (exact), these
scripts read text patterns (broad but heuristic) and file/infra layout that ESLint cannot see.

---

## Usage

```bash
# Whole app
bash frontend-standards/tools/check-standards.sh .

# i18n parity (run from the app root)
node frontend-standards/tools/check-i18n.mjs src/shared/i18n/locales --src src

# Bundle budgets, after a build
npm run build && node frontend-standards/tools/check-bundle-size.mjs dist budget.json

# nginx config
bash frontend-standards/tools/nginx-smoke.sh deployments/main/nginx/default.conf.template deployments/main/.env.local

# The standard's own consistency (run when editing the standard, not the app)
node frontend-standards/tools/check-refs.mjs frontend-standards
```

Exit codes: **0** = clean · **1** = a MUST / MUST NOT violation (breaks CI).
Warnings do not affect the exit code.

`check-standards.sh` needs bash 4+, grep, awk, find and node. It runs in Git Bash on
Windows. On a repository with ~1,300 source files a full run takes about two minutes;
budget for that in CI.

---

## CI integration

Added to the pipeline in [14-GIT-CI.md](../14-GIT-CI.md) §4:

```yaml
- name: Standards audit
  run: bash frontend-standards/tools/check-standards.sh .

- name: i18n parity
  run: node frontend-standards/tools/check-i18n.mjs src/shared/i18n/locales --src src

- name: Bundle budget
  run: node frontend-standards/tools/check-bundle-size.mjs dist budget.json

- name: nginx config
  run: bash frontend-standards/tools/nginx-smoke.sh deployments/main/nginx/default.conf.template deployments/main/.env.example
```

---

## What `check-standards.sh` checks

### A. Dependencies and versions
| Rule | What it catches |
|---|---|
| [VER-01] | `engines.node` is not 24; missing `.nvmrc`; builder image is not `node:24` |
| [VER-02] | `FROM ...:latest` or `image: ...:latest` |
| [VER-04] | Missing `package-lock.json`; `npm ci` absent from the Dockerfile |
| [VER-05] | A forbidden dependency (axios, moment, lodash, mapbox-gl, react-map-gl, leaflet, `@turf/turf`, uuid, react-helmet, next…), or `xlsx` and `xlsx-js-style` installed together |
| [CI-02] | A required npm script (`lint`, `typecheck`, `test`, `build`) is missing |

### B. Configuration and secrets
| Rule | What it catches |
|---|---|
| [GEN-10] | A secret-shaped `VITE_*` variable (`*PASSWORD*`, `*SECRET*`, `*TOKEN*`, `*API_KEY*`…) in an env file, compose, Dockerfile, or read in source. **The value is masked in the report**; an audit must never print the secret it found |
| [GEN-09] | A `VITE_*` build `ARG` other than `VITE_BUILD_ID` in the Dockerfile |
| [OPS-07] | No `config.js.template` under `deployments/` |
| [STR-20] | Nothing in `src/` reads `window.__APP_CONFIG__` |
| [SEC-14] | A third-party `<script>` or `<link>` origin in `index.html` |
| [OPS-08] | `index.html` does not load `/config.js` |

### C. Source code
| Rule | What it catches |
|---|---|
| [GEN-06] | `fetch(` outside `src/shared/api` |
| [GEN-17] | Empty `catch` block, single-line and two-line forms |
| [GEN-18] | `new maplibregl.Marker(` (warning; at most 20 rich widgets per [MAP-11]) |
| [MAP-01] | `new maplibregl.Map(` outside `src/shared/map` |
| [MAP-18] | `setData(` with hover/selected/highlight data instead of `feature-state` |
| [SEC-01] | `dangerouslySetInnerHTML` outside `SafeHtml` |
| [OBS-16] | `console.*` outside the logger wrapper |
| [TS-05] | `any` in any form (`: any`, `as any`, `<any>`) |
| [TS-21] | `React.FC` |
| [STR-05] | A feature with no `index.ts` |
| [STR-06] | A feature with no `README.md` |
| [STR-09] | A `utils/` folder inside a feature |
| [STR-10] | `src/shared` importing from features/app, or a feature importing from app |
| [STR-11] | A deep import into another feature (not through its `index.ts`) |
| [STR-15] | `export default` (warning) |
| [STR-25] | File over the line limit (warning at the limit, error at 1.5×) |
| [AUTH-04] | A token or JWT written to `localStorage`/`sessionStorage` |
| [I18N-03] | Literal Turkish text in JSX (warning) |
| [STA-28] | `createAsyncThunk` performing HTTP (server state belongs to TanStack Query) |

### D. Docker and compose
[VER-02], [VER-04], [OPS-02] (a Node static server in the runtime image), [OPS-03]
(root user), [OPS-04] (no `BUILD_ID` cache-bust), [OPS-05] (no `HEALTHCHECK`),
[OPS-06] (no `.dockerignore`), [OPS-09] (a default value for an upstream host),
[OPS-11] (no restart policy), [OPS-12] (no log rotation).

### E. nginx
Applied only to files that define a `server {` block; include fragments are checked
through their includer. [NGX-03] SPA fallback, [NGX-04] `immutable` on assets,
[NGX-05] explicit no-cache for `index.html`/`config.js`, [NGX-06] `/healthz`,
[NGX-07] `gzip_static`, [NGX-10] the `add_header` inheritance trap, [NGX-11] security
headers, [NGX-12] `server_tokens off`, [NGX-13] `*.map` denied, [NGX-17] variable
`proxy_pass` without a `resolver`, [NGX-22] a global `client_max_body_size` above 100 MB.

### F. Routing vs proxy collisions
[RTE-16]: a Vite dev-proxy prefix without a trailing slash that also swallows an SPA
route. This is the check that would have caught `/map` eating the `/map-data` route and
`/epanet` eating `/epanet/networks` in the reference project.

### G. i18n
Presence of the locale directory and at least two locales. Key parity itself is
`check-i18n.mjs`.

---

## What `check-refs.mjs` checks

This one is aimed at the standard, not at an application. Twenty-five documents written
and revised separately will grow dangling cross references: a rule gets renumbered, a file
gets renamed, an ADR is cited before it is written. Left alone, the reader follows a
reference to a rule that does not exist and loses trust in the whole set.

| Check | Severity |
|---|---|
| A rule id defined more than once | error |
| A rule id referenced but never defined | error |
| A placeholder id (`[MAP-xx]`, `[SEC-NN]`) left in the text | error |
| A relative markdown link whose target file does not exist | error |
| One prefix defined across several files | warning |
| Gaps in a prefix's numbering, or numbering that does not start at 01 | warning |
| A prefix used but missing from the table in `00-README.md` | warning |

It reads `.md` files plus `tools/*.sh` and `tools/*.mjs`, so a rule id cited in a tool
message is checked too. `fixtures/` is skipped. A definition is a line beginning with
`**[XXX-NN]` followed by `MUST`, `MUST NOT` or `SHOULD`; anything else that looks like an
id counts as a reference. Tokens such as `[ADR-0001]`, `[RFC-7946]` and `[EPSG-4326]` are
excluded by name, so widen that list deliberately if a new one appears.

Run it after editing any document in the standard, and in the release check before
publishing a new version of the plugin.

---

## Verification: these tools were tested

Both directions were measured on 2026-09-07.

| Measurement | Result |
|---|---|
| Distinct rules triggered on a real, pre-standard production app (1,291 source files) | **40** |
| Total findings on that app | 827 errors + 812 warnings |
| **False positives on the compliant fixture** (`fixtures/compliant-app`) | **0 errors, 0 warnings** |
| Exit codes | violating repo → `1`, fixture → `0` |

`check-refs.mjs` on the standard itself: **56 documents, 806 rules, 23 prefixes,
0 errors, 0 warnings.**

Five defects were found and fixed by running these tools rather than by reading them:

- `check-standards.sh`: the marker pattern `new (maplibregl\.)?Map\(` also matched
  JavaScript's native `new Map()`, producing 106 findings of which 82 were false. The
  pattern now requires an explicit `maplibregl.`, `maplibre.` or `mapboxgl.` namespace:
  24 findings, all real.
- `check-standards.sh`: the [GEN-10] check printed the matched line verbatim, which put a
  real MQTT password from a production env file into the report. Values are now masked. An
  audit must never publish the secret it found.
- `check-standards.sh`: server-level nginx checks were applied to include fragments such as
  `security-headers.conf`, reporting four false errors on a correct config. They now run
  only on files that define a `server {` block.
- `check-standards.sh`: `node -e "require(process.argv[1])"` rejects a bare relative path,
  so `bash tools/check-standards.sh tools/fixtures/compliant-app` produced five false
  errors while the same run with an absolute path was clean. It now reads and parses the
  file instead of requiring it.
- `check-refs.mjs`: rule ids and placeholders shown as examples inside code blocks were
  reported as dangling references. Fenced blocks and inline code spans are now blanked
  before scanning, and `templates/` is exempt from link checking because its relative links
  resolve in the repository it is copied into, not here.

Reproduce the false-positive test with:

```bash
bash tools/check-standards.sh tools/fixtures/compliant-app   # must print CLEAN, exit 0
```

---

## Limits — the honesty section

**[TOOL-01] MUST:** These tools are **heuristics, not proof.**
- Text-pattern checks produce false positives and negatives.
- Comment lines are excluded from source scans; code inside **string literals is not**.
- [MAP-01] only sees an explicit `maplibregl.Map(`; a map created through a re-exported
  wrapper is invisible.
- [I18N-03] only detects Turkish-specific letters in JSX text. English literal strings are
  not caught here; `eslint-plugin-i18next` catches those.
- [GEN-06] matches the token `fetch(`; a `fetch` reached through an alias is missed.
- [RTE-16] reads route paths from `src/app/router/router.tsx` only. Routes defined
  elsewhere are invisible.

**[TOOL-02] MUST:** When a check produces a false positive, **narrow the rule**. Do not
silently disable it. If it must be disabled, the reason goes in the commit message.

**[TOOL-03] MUST:** A rule that can be delegated to a machine is added here and recorded in
the tables above. **After adding a check, re-run both fixtures** (compliant → 0, real repo →
still catches). An untested check produces false confidence.

**[TOOL-04] MUST:** A clean audit does **not** mean the code follows the standard. The tools
see roughly a tenth of the rules. The signal scan in [RULE-MAP.md](../RULE-MAP.md) §1 and
[15-NEW-FEATURE-CHECKLIST.md](../15-NEW-FEATURE-CHECKLIST.md) remain mandatory.
