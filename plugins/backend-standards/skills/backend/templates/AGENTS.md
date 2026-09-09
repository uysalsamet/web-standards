# AGENTS.md

> This file is a binding instruction for **every AI coding agent** working in this
> project. Cursor, Claude Code, Antigravity, Copilot, Windsurf, Zed, Codex and others
> read it directly. Tool-specific files (`CLAUDE.md`, `.cursor/rules/`, `GEMINI.md`)
> **point to** this file; the rule lives in one place.

## Backend standard — BINDING

The standard under `backend-standards/` applies to this project. It is not a
preference, it is a **contract**: code is not merged without following it.

**Stack (non-negotiable):** Go 1.25.12 · Gin v1.12.0 · pgx/v5 · Valkey · goose ·
`log/slog` · Prometheus + OpenTelemetry.
The reasoning for every choice, and the alternatives that were ruled out, are under
`backend-standards/adr/`.

---

## Before writing code — MUST, in this order

1. **`backend-standards/01-GOLDEN-RULES.md`** — 24 items, read on every task.
2. **`backend-standards/RULE-MAP.md` §1, signal scan.**
   Every signal present in the code you're about to write triggers a rule. Examples:
   `float64` plus an amount · `ORDER BY` plus `LIMIT` · a `PUT` handler ·
   `http.Client{}` · a user-supplied URL · a `DELETE` endpoint · `strings.ToLower` ·
   a cron/`time.Ticker` · file upload · a name/TCKN/phone column · `go func(...)` ·
   a new table.
   **Read the triggered rule from the file** — do not write from what you think you
   remember.
3. **The file matching the task** — from the reading list in `RULE-MAP.md` §2.

Do not read every file at once: it wastes context and irrelevant rules muddy the
decision.

---

## While working

- **Version and dependencies:** from the `backend-standards/02-TECH-VERSIONS.md`
  table. Do not **add** a package that isn't in the table, **ask the user.**
- **"Why do we use X, isn't Y better?"** Before answering, read the relevant decision
  record under `backend-standards/adr/`. The decision has already been made and
  justified; do not reopen it unless the condition in the "What would change this
  decision" section has actually occurred.
- **If the standard conflicts with existing code:** the standard wins, but **do not
  touch working code.** Write the new code to the standard and report the conflict to
  the user.
- **Even if you see services written with an old framework, write the new service in
  Gin** ([VER-17]). Do not copy from a neighbouring service; start from the skeleton
  in `03-PROJECT-STRUCTURE.md` §4.
- **If you're heading into one of the known gaps in `RULE-MAP.md` §4:** **warn** the
  user, and write your own decision into the code with a reason.

---

## Before finishing — MUST

```bash
bash backend-standards/tools/check-standards.sh .   # exit code must be 0
golangci-lint run                                       # must be clean
```

Then go through `backend-standards/15-NEW-SERVICE-CHECKLIST.md` item by item.
A skipped item is **stated explicitly**, never passed over silently.

> **A clean automated check does NOT mean "compliant with the standard."**
> Tooling covers about 9% of the 590 rules ([TOOL-04]). The rest is your
> responsibility.

---

## Never

- Say "it works" without a test written
- Add a dependency without approval
- Say "this is a small change, no need to check the standard" — the standard is
  **always** broken through a small change
- Say "done" without verifying it

---

## Git

On this project, AI runs **only read-only** git commands
(`status`, `diff`, `log`, `show`, `branch`, `blame`).
`commit`, `push`, `reset`, `checkout`, `stash`, and creating/deleting branches or tags
are **forbidden** — the user does those themselves.
