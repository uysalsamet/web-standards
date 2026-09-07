# Copilot instructions

Read `AGENTS.md` at the repository root first. It is the binding instruction for all AI
agents and points to the frontend standard in `frontend-standards/`.

- Before writing code: `frontend-standards/01-GOLDEN-RULES.md`, then the signal scan in
  `frontend-standards/RULE-MAP.md` §1, then the file for the task.
- Stack is fixed; dependencies only from `frontend-standards/02-TECH-VERSIONS.md`.
- Every user-visible string is an i18n key present in every locale file.
- Environment values via `/config.js` at runtime, never `VITE_*` build args. No secrets in
  the frontend.
- Map data as MapLibre layers, never DOM markers; above 5,000 features use tiles.
- Before finishing: `frontend-standards/tools/check-standards.sh` and
  `frontend-standards/tools/check-i18n.mjs` exit 0; walk
  `frontend-standards/15-NEW-FEATURE-CHECKLIST.md`.
- Git: read-only commands only.
