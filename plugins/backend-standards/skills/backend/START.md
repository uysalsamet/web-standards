# Getting started — wiring this standard into a project

> Three steps. Working within five minutes.

---

## Step 1 — Copy the folder into the project

```
<project-root>/
├── backend-standards/     ← this whole folder goes here
├── services/
├── deployments/
└── AGENTS.md                 ← Step 2 (comes from templates/)
```

Also copy `tools/golangci.yml` into every service's root as `.golangci.yml`.

---

## Step 2 — Copy the contents of `templates/` into the project root

**`AGENTS.md` is the single source.** Since December 2025 it has been the shared
standard under the Linux Foundation's Agentic AI Foundation, used by 28+ tools and
60,000+ repos. Tool-specific files **point to it**, content is not duplicated, the
rule lives in one place and is updated in one place.

```bash
cp -r backend-standards/templates/. .
```

| File | Which tool reads it |
|---|---|
| **`AGENTS.md`** | **Shared source.** Cursor, Antigravity, Copilot, Windsurf, Zed, Aider, Codex, VS Code, JetBrains Junie, Claude Code |
| `CLAUDE.md` | Claude Code (also reads AGENTS.md; this is its rich native format) |
| `GEMINI.md` | Google Antigravity (comes before AGENTS.md in the hierarchy) |
| `.cursor/rules/backend-standardi.mdc` | Cursor |
| `.github/copilot-instructions.md` | GitHub Copilot |
| `.windsurfrules` | Windsurf |

You can delete the files for tools you don't use; keep `AGENTS.md`.

> **Cursor warning:** the old `.cursorrules` file is **silently ignored in Agent
> mode.** That's why the template uses the `.cursor/rules/*.mdc` format instead,
> loaded on every request via `alwaysApply: true`. If your rules aren't taking
> effect, check here first.

> **Why the content lives in a single file:** if you copy the same rule into 6 files,
> one gets updated and the others don't, and which one is correct becomes unclear.
> This is the exact same problem as the standard's own [DB-11] (denormalisation) rule.

## Step 3 — A one-line intro for a chat (when you can't drop in a file)

For situations where you can't place a file (a quick question, a tool that doesn't
support it), paste this:

```
On this project, the standard under backend-standards/ is binding.
Go 1.25.12 + Gin v1.12 + pgx/v5, single stack.

Before writing code: read 01-GOLDEN-RULES.md and the RULE-MAP.md §1 signal table,
every signal present in the code you're about to write triggers a rule, read that
rule from the file. Pick versions/dependencies from 02-TECH-VERSIONS.md; ask me
before adding a package that isn't in the table. Answers to "why X?" live under adr/.

Before finishing: run tools/check-standards.sh (must exit 0) and go through
15-NEW-SERVICE-CHECKLIST.md item by item. State clearly which item you skipped.
```

---

## Task-specific opening lines

For a narrower job, add this to the first message, the AI will know which files to
read:

| What you're doing | Sentence to add |
|---|---|
| New service | `I'm opening a new service. Read 02, 03, 13 and 15, start the skeleton from main.go in 03 §4.` |
| Endpoint | `I'm adding an endpoint. Read 04 and 05, scan RULE-MAP §1.3.` |
| Money/debt/payment | `There's a money concern. 16 §1 MUST, float for money is forbidden, use the Money type.` |
| Turkish search/sort | `There's Turkish text search. 18 §2 MUST, the ı/İ problem.` |
| File upload | `There's file upload. 17 MUST.` |
| Identity/password | `Auth service. 19 MUST.` |
| Data transfer/cron | `There's a bulk import. 20 §1-2 MUST.` |
| Slowness | `Performance problem. Follow the order in 09 §5: metric → trace → EXPLAIN → pprof.` |
| Schema change | `I'm changing the schema. Read 07, migration with goose and forward-compatible.` |

---

## Using this in an existing (legacy) repo

In a repo written with an older framework like Fiber v2:

- **All the documents still apply** — API contract, security, database, testing,
  observability. Only the HTTP layer syntax differs ([VER-20]).
- **New services are written in Gin** ([VER-17]), existing ones are left alone
  ([VER-18]).
- **Run `tools/check-standards.sh` for information only for now**, don't let it break
  CI: findings about old frameworks/dependencies (VER-01, VER-05, OBS-01) are expected.
  Until an exemption mechanism is added, filter the output by hand:
  ```bash
  bash backend-standards/tools/check-standards.sh services/x-service \
    | grep -vE 'VER-01|VER-05|OBS-01'
  ```

Also add this line to `AGENTS.md`:
```
This repo is written in <framework> (legacy). New services are opened in Gin
[VER-17]; existing services are left untouched to bring them in line with the
standard [VER-18].
```

---

## Check: is it wired up correctly?

In the first session, ask the AI:

> "According to backend-standards, how should I store a money field in this project,
> and why?"

**Correct answer:** `NUMERIC(14,2)` in the schema, `Money` in Go (int64 in the minor
unit), a **string** in JSON, and the reason is `0.1 + 0.2 != 0.3`,
[MONEY-01]…[MONEY-04].

If it can't give that answer, the standard isn't being read. Check in order:
is `AGENTS.md` at the project **root** · is the `backend-standards/` folder name
correct · if you're using Cursor, does `.cursor/rules/*.mdc` exist
(`.cursorrules` doesn't work in Agent mode).
