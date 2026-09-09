# web-standards

Binding engineering standards for web projects, packaged as [Claude Code](https://code.claude.com)
plugins. Each plugin is a skill: an index (`SKILL.md`) plus rule documents, decision records
(ADRs), check tools and copyable templates. Claude loads only the rule files a task needs.

| Plugin | Skill | Scope |
|---|---|---|
| `frontend-standards` | `/frontend-standards:frontend` | React 19 + Vite 8 + TypeScript, feature-based structure, TanStack Query, MapLibre GPU rendering, i18n key parity, SEO without stale builds, Docker and nginx templates, CI gates. **806 rules** in 25 documents, 21 ADRs, 5 tools |
| `backend-standards` | `/backend-standards:backend` | Go + Gin microservices behind a gateway: clean architecture, API contract, security, resilience, PostgreSQL and PostGIS, cache, observability, Docker, CI. **594 rules** in 21 documents, 18 ADRs, 7 tools |

Both sets are written in English. The backend standard keeps the rules that come with
Turkish public-sector work, national identity and tax numbers, KVKK, text casing and
collation, and explains why each one exists rather than assuming the reader knows. The
skills answer in whatever language you write to them in.

The standards are also usable without Claude Code: copy a plugin's `skills/<name>/` folder
into your repo and the `templates/agents/` files to the repo root. `AGENTS.md` works with
Cursor, Copilot, Windsurf, Gemini and others.

## Install (Claude Code)

```bash
# once per machine
claude plugin marketplace add <github-user>/web-standards

# pick what you need
claude plugin install frontend-standards@web-standards
claude plugin install backend-standards@web-standards
```

Inside Claude Code the same works as `/plugin marketplace add …` and `/plugin install …`.
Run `/reload-plugins` (or restart) after installing. Update later with
`claude plugin marketplace update web-standards` then `claude plugin update <plugin>`.

## Use

The skills trigger automatically when the task matches (writing a React feature, a
Dockerfile for a frontend, a Go handler…). You can also invoke them explicitly:

```
/frontend-standards:frontend   I am adding a parking layer to the map. What rules apply?
/backend-standards:backend     I am starting a new service. Scaffold it.
```

Each skill tells Claude to read the golden rules first, run a "signal scan" over the code it
is about to write (each signal maps to a rule), read only those rule files, and finish by
running the check tools and walking the checklist.

## Wire a standard into a repository

See `plugins/frontend-standards/skills/frontend/START.md` and
`plugins/backend-standards/skills/backend/START.md`. In short: copy the agent
instruction files to the repo root, add the check tools to CI, and paste the opening prompt
into the first session.

## Layout

```
.claude-plugin/marketplace.json
plugins/
├── frontend-standards/
│   ├── .claude-plugin/plugin.json
│   └── skills/frontend/
│       ├── SKILL.md                 index + how to work
│       ├── 00-README.md … 22-*.md   rule documents
│       ├── APPENDIX-GIS-DATA.md
│       ├── RULE-MAP.md              signal → rule, task → reading list
│       ├── START.md
│       ├── adr/                     decision records
│       ├── tools/                   check-standards.sh, check-i18n.mjs, check-bundle-size.mjs, nginx-smoke.sh
│       └── templates/               docker/, nginx/, github/, git/, agents/
└── backend-standards/
    ├── .claude-plugin/plugin.json
    └── skills/backend/
        ├── SKILL.md
        ├── 00-README.md … 20-*.md, APPENDIX-GIS-POSTGIS.md, RULE-MAP.md, START.md
        ├── adr/
        ├── tools/                   check-standards.sh, check-secrets.sh, run-collection.sh,
        │                            load-test.sh, version-advice.sh, check-refs.mjs,
        │                            check-language.mjs, golangci.yml
        └── templates/               agent instruction files
```

## Validate before publishing

```bash
claude plugin validate . --strict
claude plugin validate plugins/frontend-standards --strict
claude plugin validate plugins/backend-standards --strict
```

## License

MIT. See `LICENSE`.
