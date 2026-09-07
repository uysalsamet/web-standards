# Getting started — wiring this standard into a project

> Three steps. Working within five minutes.

---

## Step 0 — Which form are you using?

**As a Claude Code plugin (recommended).** The standard is the
`frontend-standards:frontend` skill; Claude loads the rule files it needs on its own. Team
members install it once:

```bash
claude plugin marketplace add <github-user>/web-standards
claude plugin install frontend-standards@web-standards
```

**As a folder in the repo.** Copy `skills/frontend/` into the repo root as
`frontend-standards/`. Every path in this document then resolves literally. Tools that are
not Claude Code (Cursor, Copilot, Windsurf) need this form, because they read files from
the repo, not from a plugin.

The two forms can coexist: the plugin for Claude, the folder for everything else. Keep one
of them authoritative and update the other from it, or the two drift.

---

## Step 1 — Copy the agent instruction files to the repo root

**`AGENTS.md` is the single source.** Tool-specific files **point to it**; the rules are not
duplicated, so they live in one place and are updated in one place.

```bash
cp -r frontend-standards/templates/agents/. .
```

```
<repo-root>/
├── AGENTS.md                              ← the source
├── CLAUDE.md                              ← points to AGENTS.md
├── GEMINI.md                              ← points to AGENTS.md
├── .cursor/rules/frontend-standard.mdc    ← points to AGENTS.md
├── .github/copilot-instructions.md        ← points to AGENTS.md
└── .windsurfrules                         ← points to AGENTS.md
```

| File | Which tool reads it |
|---|---|
| **`AGENTS.md`** | **The common source.** Cursor · Copilot · Windsurf · Zed · Aider · Codex · VS Code · JetBrains Junie · Claude Code |
| `CLAUDE.md` | Claude Code (it reads `AGENTS.md` too; this is its richer native format) |
| `GEMINI.md` | Google Antigravity (comes before `AGENTS.md` in its hierarchy) |
| `.cursor/rules/frontend-standard.mdc` | Cursor |
| `.github/copilot-instructions.md` | GitHub Copilot |
| `.windsurfrules` | Windsurf |

Delete the files for tools you do not use; keep `AGENTS.md`.

> **Cursor warning:** the old `.cursorrules` file is **silently ignored in Agent mode**.
> That is why the template uses `.cursor/rules/*.mdc` with `alwaysApply: true`, which loads
> on every request. If your rules are not taking effect, look here first.

> **Why the content lives in one file:** copy the same rule into six files and one of them
> gets updated while the others rot, and nobody knows which is correct.

---

## Step 2 — Copy the infrastructure templates

```bash
# Docker + nginx (adjust upstream names to your services)
cp -r frontend-standards/templates/docker/.  deployments/main/
cp -r frontend-standards/templates/nginx/.   deployments/main/nginx/

# CI, PR template, git hygiene
cp -r frontend-standards/templates/github/.  .github/
cp frontend-standards/templates/git/.gitignore .gitignore
cp frontend-standards/templates/git/.gitattributes .gitattributes
```

Then, in order:

1. Fill in `deployments/main/.env.example` with your variable **names** (no values) and
   create `.env.local` / `.env.prod` with the real values. Both are git-ignored.
2. Edit `deployments/main/nginx/default.conf.template`: one `location` per upstream, using
   the prefix conventions in [12-NGINX.md](12-NGINX.md) §5.
3. Adjust the budgets in `budget.json` to your app ([07-PERFORMANCE.md](07-PERFORMANCE.md) §1).
4. Verify:

```bash
bash frontend-standards/tools/nginx-smoke.sh \
  deployments/main/nginx/default.conf.template deployments/main/.env.local
```

---

## Step 3 — Wire the checks into CI

`templates/github/workflows/ci.yml` already contains the gate from
[14-GIT-CI.md](14-GIT-CI.md). Make these twelve checks **required** in the branch
protection rules, otherwise the gate is decorative:

`lint` · `typecheck` · `format:check` · `i18n:check` · `test` · `build` · `size:check` ·
`standards:check` · `nginx:test` · `audit` · `gen:check` · `docker:build`

`e2e` runs on `main` and nightly rather than on every pull request, so it is not in the
required list. See [14-GIT-CI.md](14-GIT-CI.md) for what each check costs in wall time.

Add the scripts to `package.json`:

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

`docker:build` and `audit` are CI steps rather than npm scripts; their commands are in
[14-GIT-CI.md](14-GIT-CI.md).

---

## Applying the standard to an existing project

Do **not** open a "bring everything up to standard" pull request. It ships no user value,
buries real changes and stalls the team ([GEN-24]).

1. **Measure first.** Run `check-standards.sh` and keep the output. It is your backlog, and
   it tells you which rules this codebase breaks most.
2. **Set the floor at the infrastructure layer.** Dockerfile, nginx, runtime config, CI
   gate. These are contained changes with a large payoff and they do not touch feature code.
3. **New code only.** From today, every new feature follows the standard. Old code moves
   when it is touched for a real reason.
4. **Turn on the gate gradually.** Start with `standards:check` as a non-blocking job that
   only reports. When the error count reaches zero for the rules you have decided to enforce,
   make it required.
5. **Fix the security items immediately**, not gradually: secrets in `VITE_*`, tokens in
   `localStorage`, missing security headers, a root container.

---

## A one-line opening for a chat session

When you cannot place files (a quick question, an unsupported tool), paste this:

```
In this project the standard under frontend-standards/ is binding.
React 19 + Vite 8 + TypeScript strict + MapLibre GL, static build served by nginx.

Before writing code: read 01-GOLDEN-RULES.md and the signal-scan table in RULE-MAP.md §1.
Every signal in the code you are about to write triggers a rule; read that rule from its
file. Take versions and dependencies from 02-TECH-VERSIONS.md; ask me before adding a
package that is not in the table. Answers to "why X?" are in adr/.

Before you finish: run tools/check-standards.sh (must exit 0) and walk
15-NEW-FEATURE-CHECKLIST.md item by item. Say explicitly which items you skipped.
```

---

## Task-specific openings

For a narrower job, add this to your first message so the agent knows which files to read:

| What you are doing | The sentence to add |
|---|---|
| New project | `New app. Read 02, 03, 11, 12 and 15; start from the skeleton in 03 §1 and the templates.` |
| New feature | `New feature. Read 03 §2, 04, 05 and 15; create the feature folder with index.ts and README.md.` |
| Map work | `Map work. 08 is binding. Data goes to GPU layers, not markers ([GEN-18]); above 5,000 features use tiles ([GEN-19]).` |
| Form | `Form work. Read 18; react-hook-form + zod, server 422 errors mapped into setError.` |
| SEO page | `Public indexable page. 10 is binding. No API data baked into the build ([GEN-11]).` |
| i18n | `Adding text. Every key must exist in every locale file; run tools/check-i18n.mjs.` |
| nginx / deploy | `nginx and deploy work. Read 11 and 12; verify with tools/nginx-smoke.sh.` |
| Performance | `Performance work. Read 07. No change without a before/after measurement in the PR.` |
| Auth | `Auth work. Read 19 and 06 §4. No token touches JavaScript.` |
| Debugging an error | `Read 17. Reproduce, find the root cause, then fix. Do not silence the error.` |

---

## Keeping the standard current

- The version table in `02` carries a verification date. Re-check it monthly with the
  dependency-update PR ([VER-08]).
- When a decision is reopened, update the ADR; do not delete it ([adr/README.md](adr/README.md)).
- When you add a rule that a machine can check, add it to `tools/` and re-run both fixtures
  ([TOOL-03]).
- When a rule turns out to be wrong in practice, change it in the standard rather than
  ignoring it in the code. A rule everyone quietly breaks is worse than no rule.
