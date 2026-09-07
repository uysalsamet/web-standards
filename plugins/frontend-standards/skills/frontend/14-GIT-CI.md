# 14 — Git and CI

> Governs how code reaches `main` and how an image reaches a server: branch shape, commit
> and PR rules, the merge gate, the pipeline that implements it, release and deploy. The
> core principle is [GEN-23]: **CI is the gate.** Nothing merges red and nothing is "fixed
> after merge". Read this when setting up a repo, changing the pipeline, or arguing about
> a failing check.
>
> Out of scope: what each check verifies (owned by the file that defines the rule), the
> Docker image itself ([11](11-DOCKER-COMPOSE.md)), the audit scripts
> ([tools/](tools/README.md)).

---

## 1. The gate

Twelve required checks. A pull request merges when all of them are green, and branch
protection on `main` marks them required, otherwise the gate is decorative
([START.md](START.md) Step 3 lists the first eleven for the branch-protection UI;
`docker:build` is the twelfth and is required as well).

| Job | Command | Rule | Typical time |
|---|---|---|---|
| `lint` | `npm run lint` | [CI-03] | 40 to 90 s |
| `typecheck` | `npm run typecheck` | [CI-04] | 20 to 60 s |
| `format:check` | `npm run format:check` | [CI-04] | 5 s |
| `i18n:check` | `npm run i18n:check` | [CI-04] | 3 s |
| `test` | `npm test` | [CI-05] | 60 to 180 s |
| `build` | `npm run build` | [CI-05] | 40 to 120 s |
| `size:check` | `npm run size:check` | [CI-06] | 3 s |
| `standards:check` | `npm run standards:check` | [CI-09] | up to 120 s |
| `nginx:test` | `npm run nginx:test` | [CI-09] | 15 s |
| `audit` | `npm audit --audit-level=high` | [CI-08] | 10 s |
| `gen:check` | `npm run gen:check` | [CI-12] | 20 s |
| `docker:build` | build, run, curl | [CI-10] | 2 to 4 min |

**[CI-01] MUST:** Every CI and Docker install is `npm ci` against the committed
`package-lock.json`, on Node 24 ([VER-01]), with `ignore-scripts=true` in the CI `.npmrc`
([VER-09]). `npm install` in a pipeline is a failure, not a shortcut.
> **Why:** `npm install` may resolve a newer transitive version than the lockfile, so the
> tree that passed CI is not the tree that shipped. The reference project produced exactly
> that: a passing pipeline and a broken production build from an unpinned transitive minor.
> Detail: [ADR-0018](adr/0018-package-manager.md).

**[CI-02] MUST:** `package.json` declares at least the scripts `lint`, `typecheck`, `test`
and `build`. `check-standards.sh` fails when one is missing.
> **Why:** The pipeline calls scripts, not tools. A repo without `typecheck` silently drops
> that gate: the job still "passes" because npm exits 0 for a missing script under some
> runners, or the job is quietly deleted from the workflow so the pipeline stays green.

```json
{
  "scripts": {
    "dev": "vite",
    "build": "tsc -b && vite build",
    "lint": "eslint . --max-warnings 0",
    "typecheck": "tsc -b --noEmit",
    "format:check": "prettier --check .",
    "test": "vitest run --coverage",
    "test:watch": "vitest",
    "e2e": "playwright test",
    "i18n:check": "node frontend-standards/tools/check-i18n.mjs src/shared/i18n/locales --src src",
    "size:check": "node frontend-standards/tools/check-bundle-size.mjs dist budget.json",
    "standards:check": "bash frontend-standards/tools/check-standards.sh .",
    "nginx:test": "bash frontend-standards/tools/nginx-smoke.sh deployments/main/nginx/default.conf.template deployments/main/.env.example",
    "gen:check": "npm run gen:api && npm run gen:i18n && git diff --exit-code",
    "analyze": "vite build --mode analyze"
  }
}
```

**[CI-03] MUST:** The `lint` job runs `eslint . --max-warnings 0`. A warning is a failure.
> **Why:** A warning nobody must fix accumulates: the reference repo reached 812 warnings,
> at which point the output is scrolled past and a new real warning is invisible. Either a
> rule matters (error) or it is removed from the config. Detail: [ADR-0019](adr/0019-linting.md).

**[CI-04] MUST:** `typecheck` runs `tsc -b --noEmit` as its own job, separate from `build`,
and `format:check` and `i18n:check` are separate jobs too.
> **Why:** Separate jobs run in parallel and name the failure in the check list, so a
> reviewer sees "i18n:check failed" instead of opening a 900-line build log. `build` uses
> Vite's transpile-only path for speed, so without a standalone `tsc` a type error can ship.

**[CI-05] MUST:** `test` runs `npm test` (Vitest with the coverage thresholds in [TEST-05]:
70 % lines / 60 % branches overall, 90 % for `src/shared/utils/**` and `**/lib/**`) and the
job fails when a threshold is not met. `build` runs `npm run build` and uploads `dist/` as
an artifact that `size:check` and `docker:build` consume. Cross-ref: [TEST-39].
> **Why:** Rebuilding in three jobs triples the slowest step and lets the three jobs measure
> three different bundles. One build, one artefact, one set of numbers.

**[CI-06] MUST:** `size:check` runs `node tools/check-bundle-size.mjs dist budget.json`
after `build` and fails on any breach. Raising a budget is a reviewed change to
`budget.json` with the reason in the PR body. Cross-ref: [PERF-03], [RTE-20].
> **Why:** Bundle growth is invisible per PR (8 KB here, 30 KB there) and obvious per
> quarter. A gate turns "the app got slow" into "this PR added 180 KB".

**[CI-07] SHOULD:** Lighthouse CI runs against the built image on a throttled profile (4G,
4× CPU) and enforces [PERF-21]'s thresholds. It runs on `main` and nightly rather than on
every PR, because run-to-run variance on shared runners is ±15 % and a flaky performance
gate gets disabled within a month.
> **Why:** Field data ([OBS-14]) is the truth; the lab run is a regression tripwire. A
> tripwire that cries wolf is removed, so it does not go on the PR path.

**[CI-08] MUST:** `npm audit --audit-level=high` runs in CI and blocks the merge on an
unresolved high or critical advisory. A finding without an upstream fix is waived only with
a committed override that names the advisory, the reason and an expiry date; the job fails
again when the expiry passes. Cross-ref: [VER-07], [SEC-20].
> **Why:** Without a gate, advisories are noticed when a customer's scanner finds them. The
> expiry date is what stops a temporary waiver from becoming permanent: the reference repo
> carried an ignored advisory for 14 months.

**[CI-09] MUST:** `standards:check` (`tools/check-standards.sh`) and `nginx:test`
(`tools/nginx-smoke.sh`, which renders the template with `.env.example` and runs `nginx -t`
inside the pinned nginx image) both run on every PR and both must exit 0. Cross-ref:
[TOOL-01] on what these tools do and do not see.
> **Why:** A syntax error in an nginx template is found at container start, in production,
> at deploy time. `nginx -t` finds it in 15 seconds on the PR.

**[CI-10] MUST:** `docker:build` builds the runtime image with
`--build-arg GIT_SHA=$(git rev-parse HEAD)` ([OBS-05]), starts the container, and asserts
`GET /healthz` returns 200 and `GET /config.js` returns 200 with a `Cache-Control` that
contains `no-cache` ([GEN-12], [OBS-18]). The container is stopped and the image discarded
on a PR; only `main` pushes it.
> **Why:** `vite build` passing does not mean the image runs. The failures this catches are
> the ones with no local symptom: a missing `envsubst` variable leaving `${APP_API_BASE_URL}`
> literal in `config.js`, a non-root user that cannot write the rendered template, a
> `COPY --from` path that changed. All three happened in the reference project.

**[CI-11] MUST:** The release job uploads `dist/**/*.map` to the error tracker with the
release id and deletes the `.map` files before the runtime image is assembled, so no map is
ever served. Cross-ref: [OBS-15], [SEC-12].

**[CI-12] MUST:** `gen:check` regenerates every generated file (OpenAPI types, i18n key
typings, [STR-29]) and runs `git diff --exit-code`. Drift fails the job.
> **Why:** A committed generated file that nobody regenerates is a lie with a timestamp:
> the types say the API returns `status: string` while it has returned an enum for six
> weeks, and `tsc` confirms the lie. The diff check makes the generator the source.

**[CI-13] MUST:** The Playwright suite (`e2e`) runs on `main` after merge and nightly, not
on every PR, and a failure on `main` blocks the deploy and opens an issue. Cross-ref:
[TEST-03], [TEST-35].
> **Why:** The smoke suite needs the built image, the API and a seeded database; that is 6
> to 12 minutes and the most flake-prone thing in the pipeline. On the PR path it becomes
> the check people re-run until it is green, which teaches everyone to ignore red.

**[CI-14] MUST:** The workflow cancels superseded runs for the same ref
(`concurrency` with `cancel-in-progress`), pins every third-party action to a full commit
SHA ([SEC-21]), caches npm downloads keyed on `package-lock.json`, and uploads `dist/`,
`coverage/lcov.info` and Playwright traces as artifacts.
> **Why:** Without cancellation, five pushes to one branch occupy the runner pool for 45
> minutes and everyone waits. A tag (`@v4`) is a moving pointer the action's owner can
> repoint at any commit; that is the exact mechanism behind the `tj-actions/changed-files`
> compromise, where a retagged action exfiltrated CI secrets from thousands of repos.

---

## 2. The pipeline

`templates/github/workflows/ci.yml`, copied verbatim into `.github/workflows/ci.yml`:

```yaml
# .github/workflows/ci.yml
#
# Actions are pinned to commit SHAs ([CI-14]). Resolve each one before first use:
#   gh api repos/actions/checkout/git/ref/tags/v5.0.0 --jq .object.sha
# and replace the REPLACE_WITH_SHA placeholders. Keep the version in the trailing comment
# so the next upgrade knows what the SHA means.
name: ci

on:
  pull_request:
  push:
    branches: [main]
  schedule:
    - cron: '0 2 * * *' # nightly e2e ([CI-13])

# One run per ref. A new push cancels the previous run instead of queuing behind it.
concurrency:
  group: ci-${{ github.ref }}
  cancel-in-progress: ${{ github.event_name == 'pull_request' }}

permissions:
  contents: read

env:
  NODE_VERSION: '24'

jobs:
  # ---------------------------------------------------------------- static checks
  static:
    name: ${{ matrix.script }}
    runs-on: ubuntu-24.04
    strategy:
      fail-fast: false # one red check must not hide the other three
      matrix:
        script: [lint, typecheck, format:check, i18n:check]
    steps:
      - uses: actions/checkout@REPLACE_WITH_SHA # v5.0.0
      - uses: actions/setup-node@REPLACE_WITH_SHA # v5.0.0
        with:
          node-version: ${{ env.NODE_VERSION }}
          cache: npm
      - run: npm ci --ignore-scripts # [CI-01], [VER-09]
      - run: npm run ${{ matrix.script }}

  test:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@REPLACE_WITH_SHA # v5.0.0
      - uses: actions/setup-node@REPLACE_WITH_SHA # v5.0.0
        with: { node-version: '24', cache: npm }
      - run: npm ci --ignore-scripts
      - run: npm test # vitest run --coverage; thresholds fail the job ([TEST-05])
      - uses: actions/upload-artifact@REPLACE_WITH_SHA # v4.6.2
        if: always()
        with: { name: coverage, path: coverage/lcov.info, retention-days: 7 }

  audit:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@REPLACE_WITH_SHA # v5.0.0
      - uses: actions/setup-node@REPLACE_WITH_SHA # v5.0.0
        with: { node-version: '24', cache: npm }
      - run: npm ci --ignore-scripts
      - run: npm audit --audit-level=high # [CI-08]

  gen:
    name: gen:check
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@REPLACE_WITH_SHA # v5.0.0
      - uses: actions/setup-node@REPLACE_WITH_SHA # v5.0.0
        with: { node-version: '24', cache: npm }
      - run: npm ci --ignore-scripts
      - run: npm run gen:check # regenerate + git diff --exit-code ([CI-12])

  standards:
    name: standards:check
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@REPLACE_WITH_SHA # v5.0.0
      - uses: actions/setup-node@REPLACE_WITH_SHA # v5.0.0
        with: { node-version: '24', cache: npm }
      - run: npm ci --ignore-scripts
      - run: npm run standards:check
      - run: npm run nginx:test # renders the template and runs nginx -t ([CI-09])

  # ---------------------------------------------------------------- build + budget
  build:
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@REPLACE_WITH_SHA # v5.0.0
      - uses: actions/setup-node@REPLACE_WITH_SHA # v5.0.0
        with: { node-version: '24', cache: npm }
      - run: npm ci --ignore-scripts
      - run: npm run build
        env:
          # Only build-time constants ([GEN-09]). URLs come from /config.js at runtime.
          VITE_BUILD_ID: ${{ github.sha }}
      - uses: actions/upload-artifact@REPLACE_WITH_SHA # v4.6.2
        with: { name: dist, path: dist, retention-days: 7 }

  size:
    name: size:check
    needs: build
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@REPLACE_WITH_SHA # v5.0.0
      - uses: actions/download-artifact@REPLACE_WITH_SHA # v5.0.0
        with: { name: dist, path: dist }
      - uses: actions/setup-node@REPLACE_WITH_SHA # v5.0.0
        with: { node-version: '24' }
      - run: node frontend-standards/tools/check-bundle-size.mjs dist budget.json # [CI-06]

  # ---------------------------------------------------------------- image smoke test
  docker:
    name: docker:build
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@REPLACE_WITH_SHA # v5.0.0
      - name: Build image
        run: |
          docker build \
            -f deployments/main/Dockerfile \
            --build-arg GIT_SHA=${{ github.sha }} \
            -t app:${{ github.sha }} .
      - name: Run and probe
        run: |
          set -euo pipefail
          docker run -d --name app-smoke -p 8080:8080 \
            -e APP_API_BASE_URL=/api \
            -e APP_ENVIRONMENT=staging \
            app:${{ github.sha }}
          # Poll instead of sleeping: nginx is ready in ~200 ms, but a cold runner can take 5 s.
          for i in $(seq 1 30); do
            curl -fsS http://localhost:8080/healthz && break || sleep 1
          done
          curl -fsS http://localhost:8080/healthz | grep -q ok
          # config.js must exist, must be substituted, and must not be cached ([GEN-12]).
          curl -fsSI http://localhost:8080/config.js | grep -qi 'cache-control:.*no-cache'
          curl -fsS  http://localhost:8080/config.js | grep -q '__APP_CONFIG__'
          ! curl -fsS http://localhost:8080/config.js | grep -q '\${'
      - name: Container logs on failure
        if: failure()
        run: docker logs app-smoke
      - name: Clean up
        if: always()
        run: docker rm -f app-smoke || true

  # ---------------------------------------------------------------- e2e (not on PRs)
  e2e:
    if: github.event_name != 'pull_request'
    needs: [build, docker]
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/checkout@REPLACE_WITH_SHA # v5.0.0
      - uses: actions/setup-node@REPLACE_WITH_SHA # v5.0.0
        with: { node-version: '24', cache: npm }
      - run: npm ci --ignore-scripts
      - run: npx playwright install --with-deps chromium
      - run: npm run e2e
        env:
          E2E_BASE_URL: http://localhost:8080
      - uses: actions/upload-artifact@REPLACE_WITH_SHA # v4.6.2
        if: failure()
        with: { name: playwright-report, path: playwright-report/, retention-days: 14 }
```

**GitLab CI equivalent (SHOULD).** Same gate, different syntax. Stages
`static → build → verify → image → deploy`; `interruptible: true` plus
`workflow.auto_cancel.on_new_commit: interruptible` replaces `concurrency`;
`cache: { key: { files: [package-lock.json] }, paths: [.npm] }` replaces the npm cache;
`artifacts: { paths: [dist] }` replaces upload/download; there are no third-party actions
to pin, so [CI-14]'s pinning applies to the `image:` tags instead ([VER-02]). The deploy
job is `when: manual` with a protected environment.

---

## 3. Branches

**[CI-15] MUST:** Trunk-based development. `main` is protected (no direct push, no force
push, required checks, linear history). Work happens on short-lived branches named
`feat/<ticket>-<slug>`, `fix/<ticket>-<slug>` or `chore/<slug>`, living at most three days.
There is no `develop`, no `release/*` and no long-running feature branch.
> **Why:** A branch open for three weeks is a merge conflict with interest. Long-lived
> branches also defeat the gate: the code passes CI against a `main` from three weeks ago.
> Anything that cannot ship in three days ships dark behind a runtime feature flag
> ([GEN-09]).

**[CI-16] MUST:** Rebase onto `main` before merging (`git pull --rebase origin main`), then
**squash merge** with the PR title as the commit subject and the PR number in it. The
branch is deleted on merge.
> **Why:** Squash merge makes `main` one commit per change, so `git log --oneline` is a
> changelog, `git bisect` has meaningful units, and a revert is one commit. Rebasing first
> means the checks ran against the code that will actually be on `main`.

---

## 4. Commits

**[CI-17] MUST:** Commit subjects follow Conventional Commits: `type(scope): subject`, in
**English**, imperative mood, no trailing period, at most 72 characters. `type` is one of
`feat`, `fix`, `refactor`, `perf`, `test`, `docs`, `build`, `ci`, `chore`. `scope` is the
feature folder name in lower camel case (`parking`, `wasteTruck`) or an infrastructure area
(`nginx`, `docker`, `deps`).
> **Why:** The type and scope are what generate the changelog ([CI-21]) and what let you
> answer "what changed in the map feature last month" with one `git log --grep`. English is
> chosen because the code, the standard and the AI agents reading the history are English;
> the reference organisation writes Turkish commit messages, which means the history and
> the code speak two languages and no filter works across both.

**[CI-18] MUST:** The commit body (blank line, then wrapped at 72 columns) explains **why**,
not what, and the footer carries `Refs: <ticket>` and `BREAKING CHANGE:` where applicable.
Turkish is allowed in the PR **description**, which is where the discussion with
non-English-speaking stakeholders belongs.
> **Why:** The diff already says what changed. Six months later the only question is why,
> and the answer is either in the body or lost. Splitting the languages by artefact
> (English commits, Turkish PR prose) keeps the machine-readable history in one language
> without forcing a stakeholder to read English.

```
feat(parking): cache occupancy tiles for 60 seconds

Occupancy tiles were re-fetched on every viewport change, which cost
~40 requests per minute per user and made panning stutter on 4G.
The service updates the layer once a minute, so a 60 s cache costs no
freshness.

Refs: ARN-2431
```

This is one decision made in one place: if the organisation later decides commits are
written in Turkish, [CI-17] changes and nothing else does. Do not derive the language rule
from an example elsewhere in the standard.

---

## 5. Pull requests

**[CI-19] MUST:** Every PR uses `.github/PULL_REQUEST_TEMPLATE.md`, which requires: what
changed, why (with the ticket), before/after screenshots or a screen recording for any UI
change, the checklist link to [15](15-NEW-FEATURE-CHECKLIST.md), and an explicit **skipped
items** section naming what was not done and why.
> **Why:** "Skipped items" is the rule that makes the checklist honest. Without it a
> reviewer cannot tell a considered omission (no test for a one-line copy change) from an
> oversight (no test for a permission guard), so the checklist becomes decoration.

**[CI-20] MUST:** A PR targets **at most 400 changed lines** excluding lockfiles, generated
files and snapshots, and needs at least one approving review from someone who did not write
it. Code generated by an AI agent is reviewed exactly like any other code, by a human who
can explain it. Cross-ref: [GEN-24] on why "consistency" refactors are not bundled in.
> **Why:** Review effectiveness collapses above roughly 400 lines: reviewers stop finding
> defects and start approving. That number is from the SmartBear/Cisco review study and
> matches what large PRs look like in practice, a single "LGTM" with no comments. An
> AI-generated 900-line PR is the common way this limit is breached now, and the review
> that follows is the one nobody actually does.

---

## 6. Release and deploy

**[CI-21] MUST:** The image tag is the **short commit sha** (`app:1a2b3c4`), never
`latest` ([VER-02]). A production deploy also creates an annotated git tag
`v<YYYY.MM.DD>-<short-sha>` on the deployed commit, and `CHANGELOG.md` is generated from
the Conventional Commit subjects between the previous tag and this one.
> **Why:** With a sha tag, "which code is on the server" is answerable by reading the
> compose file, and a rollback is `docker compose up -d` with the previous sha. `latest`
> makes that question unanswerable and makes rollback a rebuild.

**[CI-22] MUST:** The production deploy job requires a **manual approval** (a protected
environment), runs `docker compose --env-file .env.prod up -d` on the target, and reads
every secret from the CI vault. Secrets are never committed, never echoed into logs, and
never passed as build args ([GEN-10]). The job's last step re-probes `/healthz` and rolls
back to the previous sha on failure.
> **Why:** An automatic production deploy on every merge to `main` means a merge at 18:55
> on a Friday is a deploy at 18:55 on a Friday. The approval is a 5-second click that owns
> that decision.

**[CI-23] MUST:** Dependency updates are automated on a **monthly** schedule (Dependabot or
Renovate) into a single PR that groups patch and minor updates, with each major update in
its own PR referencing the relevant ADR. Security advisories are not batched; they open
immediately. Cross-ref: [VER-08], [VER-06].
> **Why:** Weekly bot PRs are ignored within a month and then nothing is updated for a
> year. Monthly is small enough to review and frequent enough that a major is never more
> than one version behind.

---

## 7. Local hooks

**[CI-24] MUST NOT:** No git-hook manager is installed. Neither `husky` nor
`simple-git-hooks` is in the version table ([VER-05] governs additions), and a hook that
runs lint and tests on every commit adds 30 to 90 seconds to a commit, which is why the
first thing engineers learn is `--no-verify`. A `precommit` npm script is an **optional
local convenience**; CI is the gate ([GEN-23]).
> **Why:** A hook that can be skipped is not a gate, and a hook that cannot be skipped
> blocks the legitimate work-in-progress commit. Two enforcement points that disagree also
> means the fast one (the hook) drifts from the real one (CI) and produces false
> confidence.

```json
{ "scripts": { "precommit": "npm run lint && npm run typecheck" } }
```

Run it yourself before pushing if you want the fast feedback; nothing in the pipeline
depends on it, and no PR is rejected for not having run it.

---

## 8. Git hygiene

**[CI-25] MUST:** `.gitignore` covers, at minimum: `node_modules/`, `dist/`, `dist-ssr/`,
`coverage/`, `playwright-report/`, `test-results/`, `*.tsbuildinfo`, `.eslintcache`,
`*.mbtiles`, `*.pmtiles`, and **every** `.env*` file except `.env.example`.
> **Why:** A `.env.prod` committed once is in the history forever, and rotating the secrets
> is the only real fix. `*.mbtiles` matters here because a tile archive is 200 MB to 4 GB;
> one accidental commit makes every clone in the organisation permanently slower
> ([CI-27]).

**[CI-26] MUST:** `.gitattributes` sets `* text=auto eol=lf` and marks binary types
(`*.png`, `*.jpg`, `*.webp`, `*.woff2`, `*.ttf`, `*.pdf`, `*.mbtiles`, `*.pmtiles`) as
`binary`, and marks `package-lock.json` as `linguist-generated` and `-diff`.
> **Why:** Without `eol=lf`, a Windows developer commits CRLF, the Docker build's shell
> scripts fail with `\r: command not found`, and every diff shows the whole file. Marking
> binaries stops git from trying to merge them and from printing 4 MB of garbage in a diff.

**[CI-27] MUST NOT:** Files over 10 MB are committed. Tile archives, sample datasets,
videos and generated PDFs live in object storage or on the tile service volume, referenced
by URL. Git LFS is not used ([Open questions]).
> **Why:** Git stores every version of a binary forever. A 300 MB GeoJSON committed and
> then deleted still costs 300 MB in every clone, every CI checkout and every Docker build
> context, permanently.

**[CI-28] MUST:** An AI coding agent runs **read-only** git commands only: `status`, `log`,
`diff`, `show`, `branch` (listing), `blame`. Commit, push, reset, revert, rebase,
`checkout`/`restore` that discards changes, stash, and branch or tag creation and deletion
are performed by a human. An agent that believes one of these is needed says so and stops.
> **Why:** These commands destroy work that is not recoverable from the agent's context: a
> `git checkout .` discards an hour of uncommitted human edits with no undo, and a `reset
> --hard` on the wrong ref loses commits that were never pushed. The agent's model of what
> is uncommitted is always older than the working tree.

---

## 9. PR review checklist

The reviewer answers these ten before approving. Anything unanswerable is a comment, not an
approval.

1. **Scope.** Does the diff do one thing, and does the title say what that thing is? Under 400 lines ([CI-20])?
2. **Correctness at the boundary.** Is every API response parsed with a schema ([GEN-07]), and is every param and search param validated ([RTE-12], [STA-30])?
3. **State home.** Is server data in Query only, URL state in the URL, and is nothing copied into Redux ([GEN-05])?
4. **All four states.** Loading, empty, error and success for every async surface, with a retry that works ([GEN-15])?
5. **Errors.** No empty catch, no swallowed rejection, a route boundary in place, and expected 404/403 not reported as crashes ([GEN-17], [RTE-09])?
6. **Cleanup.** Every listener, timer, subscription and map layer removed on unmount, StrictMode-safe ([GEN-21], [GEN-20])?
7. **Strings and formats.** No literal user-visible text, keys present in every locale, `Intl` for dates and numbers ([GEN-14])?
8. **Security.** No secret in a `VITE_` var or `config.js`, no token in storage, no `dangerouslySetInnerHTML` outside `SafeHtml`, external links carry `rel="noopener"` ([GEN-10], [RTE-23])?
9. **Cost.** Any new dependency justified per [VER-06]; bundle budget still green; no new non-lazy heavy import ([CI-06], [PERF-05])?
10. **Verification.** Tests for the new logic and its main edge case, a screenshot for UI, and a "skipped items" section that is honest ([CI-19], [TEST-38])?

---

## Open questions

- **Git LFS.** Not adopted: it needs server support, a second credential path and breaks
  plain `git clone` for anyone who has not installed it. Revisit if a repo genuinely needs
  versioned binaries above 10 MB (design source files, for example), which none currently do.
- **Merge queue.** Not adopted; at the current merge rate (under 10 PRs a day) rebase before
  merge is enough. Adopt when the "rebase, wait 8 minutes, someone else merged first" loop
  starts costing more than one round per day.
- **Signed commits.** Not required. Revisit if the organisation adopts a supply-chain
  attestation policy that needs commit provenance, at which point it becomes a branch
  protection setting, not a rule people follow by hand.
