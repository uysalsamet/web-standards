# AGENTS.md

> This file is the binding instruction for **every AI coding agent** working in this
> repository. Cursor, Claude Code, Antigravity, Copilot, Windsurf, Zed, Codex and others read
> it directly. Tool-specific files (`CLAUDE.md`, `.cursor/rules/`, `GEMINI.md`) **point to
> this file**; the rules live in one place.

## Frontend standard — BINDING

This project follows the frontend standard in `frontend-standards/` (or, when installed as
a Claude Code plugin, the `frontend-standards:frontend` skill). It is not a preference; it
is a **contract**. Code that does not follow it is not merged.

**Stack (not open for discussion):** React 19 + React Compiler · Vite 8 · TypeScript 6
strict · React Router 7 · TanStack Query 5 · Redux Toolkit 2 (narrow scope) · Tailwind 4 ·
react-hook-form + zod · i18next · MapLibre GL 5 · Vitest + Testing Library + MSW +
Playwright · nginx 1.30 in a non-root Docker image.
Every choice, its alternatives and its costs are recorded in `frontend-standards/adr/`.

---

## Before writing code — MANDATORY order

1. **`frontend-standards/01-GOLDEN-RULES.md`** — 24 items, read on every task.
2. **`frontend-standards/RULE-MAP.md` §1 — signal scan.** Every signal in the code you are
   about to write triggers a rule. Examples:
   `fetch(` · `as SomeType` on a response · a literal string in JSX · `VITE_` ·
   `new maplibregl.Marker` · `setData` for highlight · `dangerouslySetInnerHTML` ·
   `useEffect` that sets state · `localStorage` · `location /` in nginx · `FROM node` ·
   `.geojson` over 2 MB · `<title>` · a new route path · a `catch` block.
   **Read the triggered rule from its file.** Do not write from what you remember.
3. **The file for the task** — from `RULE-MAP.md` §2's reading list.

Do not read all files at once: it wastes context and unrelated rules blur the decision.

---

## While working

- **Versions and dependencies:** from `frontend-standards/02-TECH-VERSIONS.md`. A package
  not in the table is **not added — ask the user.**
- **"Why X, isn't Y better?"** Before answering, read the ADR under
  `frontend-standards/adr/`. The decision is made and justified; reopen it only if the
  condition under "What would change this decision" holds.
- **Standard vs existing code:** the standard wins — but **do not touch working code.**
  Write the new code to the standard and report the conflict to the user.
- **Environment values** go through `/config.js` (runtime), never `VITE_*` build args.
  Nothing secret is ever put in the frontend.
- **Map data** is rendered as MapLibre layers, never as DOM markers; above 5,000 features
  it comes from tiles, not GeoJSON.
- **Every user-visible string** is an i18n key present in **every** locale file.
- If you are entering one of the **known gaps** in `RULE-MAP.md` §4: **warn the user**,
  write your own decision with its reason into the code.

---

## Before finishing — MANDATORY

```bash
bash frontend-standards/tools/check-standards.sh .                 # exit code must be 0
node frontend-standards/tools/check-i18n.mjs src/shared/i18n/locales   # exit code must be 0
npm run lint && npm run typecheck && npm test && npm run build
```

Then walk `frontend-standards/15-NEW-FEATURE-CHECKLIST.md` item by item.
A skipped item is **stated explicitly**, never passed over in silence.

> **A clean tool run does NOT mean "compliant".** The tools see roughly a tenth of the rules.
> The rest is your responsibility.

---

## Never

- ❌ Say "it works" without running it
- ❌ Add a dependency without approval
- ❌ Say "small change, no need to check the standard" — the standard is **always** broken
  by a small change
- ❌ Say "done" without verifying
- ❌ Put a secret, token or private URL in `VITE_*`, `config.js` or the bundle
- ❌ Bake API data into the build for SEO
- ❌ Render a dataset as `maplibregl.Marker`

---

## Git

In this project the AI runs **read-only** git commands only
(`status`, `diff`, `log`, `show`, `branch`, `blame`).
`commit`, `push`, `reset`, `checkout`, `stash`, branch/tag creation and deletion are
**forbidden** — the human decides and runs them.
