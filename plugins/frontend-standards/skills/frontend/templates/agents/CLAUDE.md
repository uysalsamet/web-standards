# CLAUDE.md

Read `AGENTS.md` in this directory first. It is the binding instruction for all AI agents
in this repository, including Claude Code, and it points to the frontend standard.

If the `frontend-standards` plugin is installed, the standard is also available as the
`frontend-standards:frontend` skill; invoke it for any frontend, map, i18n, SEO, Docker or
nginx task in this repo. If the plugin is not installed, the standard is the
`frontend-standards/` folder at the repo root.

Claude-specific notes:
- Use the skill's `RULE-MAP.md` §1 signal scan before writing code, every time.
- Run `tools/check-standards.sh` and `tools/check-i18n.mjs` before reporting completion.
- Git: read-only commands only. Never commit, push, reset, checkout, stash or create branches.
