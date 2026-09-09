---
name: frontend
description: Binding engineering standard for React + Vite + TypeScript web apps shipped as Docker images behind nginx. Use whenever writing, reviewing or scaffolding frontend code, map (MapLibre) features, i18n, SEO/prerendering, Dockerfiles, docker-compose or nginx config for a frontend, or when asked "what is our frontend standard". Loads only the rule files relevant to the task.
---

# Frontend Standard

This skill is a **contract, not a suggestion**. It exists so that every frontend, whoever
writes it (human or AI), uses the same stack, the same folder layout, the same error
handling, the same i18n discipline, the same Docker/nginx setup and the same map rendering
strategy.

All documents live next to this file. **Do not read all of them at once.** Read what the
task needs; the index below and `RULE-MAP.md` tell you which.

> **Language:** the rules are written in English so the set can be shared and reviewed by
> anyone. That is the source language, not the working language. **Answer the user in the
> language they write to you in**, and translate a rule when you quote it to them. What must
> not be translated is the rule itself: `MUST` stays a binding obligation and `SHOULD` stays
> a default, whatever language the conversation is in.

## Always read first

1. [01-GOLDEN-RULES.md](01-GOLDEN-RULES.md) — 24 non-negotiable rules. Every task.
2. [RULE-MAP.md](RULE-MAP.md) §1 — signal scan. Scan the code you are about to write for the
   listed signals (a `fetch(` call, a `new maplibregl.Marker`, a literal string in JSX, a
   `VITE_` variable, a `dangerouslySetInnerHTML`, a `location /` block…). Each signal points
   to a rule. **Read that rule from its file.** Do not write from memory.
3. The document(s) for the task, from the table below or `RULE-MAP.md` §2.

## Documents

| # | File | Read when |
|---|---|---|
| 00 | [00-README.md](00-README.md) | You want the full index with scope notes |
| 01 | [01-GOLDEN-RULES.md](01-GOLDEN-RULES.md) | **Always** |
| 02 | [02-TECH-VERSIONS.md](02-TECH-VERSIONS.md) | Starting a project, adding/upgrading a dependency, writing Dockerfile/compose |
| 03 | [03-PROJECT-STRUCTURE.md](03-PROJECT-STRUCTURE.md) | Creating files/folders, a new feature, imports |
| 04 | [04-API-CLIENT.md](04-API-CLIENT.md) | Calling a backend, defining DTOs, handling API errors |
| 05 | [05-STATE-AND-DATA.md](05-STATE-AND-DATA.md) | Any state: server, client, URL, form; caching, invalidation |
| 06 | [06-SECURITY.md](06-SECURITY.md) | HTML injection, tokens, CSP, uploads, third-party scripts |
| 07 | [07-PERFORMANCE.md](07-PERFORMANCE.md) | Bundle size, lazy loading, rendering, Web Vitals |
| 08 | [08-MAP-MAPLIBRE.md](08-MAP-MAPLIBRE.md) | **Putting something on the map:** instance, layers vs markers, events, popups, cleanup |
| 08b | [08b-MAP-DATA.md](08b-MAP-DATA.md) | Where map data comes from: GeoJSON limits, tiles, terrain, live data, map performance |
| 08c | [08c-MAP-TOOLING.md](08c-MAP-TOOLING.md) | Drawing and editing geometry; testing map code |
| 09 | [09-I18N.md](09-I18N.md) | Any user-visible text, dates, numbers, Turkish casing/sorting |
| 10 | [10-SEO-RENDERING.md](10-SEO-RENDERING.md) | Public pages, meta tags, prerender/SSR, sitemap, stale-build risk |
| 11 | [11-DOCKER-COMPOSE.md](11-DOCKER-COMPOSE.md) | Dockerfile, compose, env files, runtime config, local vs prod |
| 12 | [12-NGINX.md](12-NGINX.md) | Any nginx config: static serving, caching, proxying, headers, templates |
| 13 | [13-TESTING.md](13-TESTING.md) | Writing or reviewing tests |
| 14 | [14-GIT-CI.md](14-GIT-CI.md) | Branching, commits, PR checks, pipeline |
| 15 | [15-NEW-FEATURE-CHECKLIST.md](15-NEW-FEATURE-CHECKLIST.md) | **Before saying "done"** on a feature or a new project |
| 16 | [16-ACCESSIBILITY-UX.md](16-ACCESSIBILITY-UX.md) | Components, modals, forms, keyboard, loading/empty/error states |
| 17 | [17-ERRORS-OBSERVABILITY.md](17-ERRORS-OBSERVABILITY.md) | Error boundaries, global handlers, error tracking, logging |
| 18 | [18-FORMS-VALIDATION.md](18-FORMS-VALIDATION.md) | Any form, input validation, Turkish identifiers (TCKN, phone, IBAN) |
| 19 | [19-AUTH-SESSION.md](19-AUTH-SESSION.md) | Login, tokens, route guards, permissions in UI |
| 20 | [20-REALTIME-MEDIA.md](20-REALTIME-MEDIA.md) | WebSocket/MQTT, live data, video (HLS/WebRTC), workers |
| 21 | [21-TYPESCRIPT-REACT-STYLE.md](21-TYPESCRIPT-REACT-STYLE.md) | Code style, types, hooks, React 19 patterns |
| 22 | [22-ROUTING.md](22-ROUTING.md) | Routes, lazy pages, URL state, guards, 404 |
| GIS | [APPENDIX-GIS-DATA.md](APPENDIX-GIS-DATA.md) | GeoJSON, coordinates, projections, large geodata |
| — | [RULE-MAP.md](RULE-MAP.md) | Signal → rule table; task → reading list; known gaps |
| — | [START.md](START.md) | Wiring this standard into a repo (agent files, tools, CI) |
| — | [adr/](adr/README.md) | "Why X and not Y?" Every stack decision with alternatives and costs |
| — | [tools/](tools/README.md) | Five checks: standards, i18n parity, bundle budget, nginx config, reference consistency |
| — | [templates/](templates/) | Dockerfile, compose, nginx, runtime config, agent instruction files |

## How to work with this standard

- **Versions and dependencies** come from `02-TECH-VERSIONS.md`. A package not in the table
  is not added without asking the user. Ever.
- **"Why X, isn't Y better?"** Read the ADR first. The decision was made with alternatives
  and costs written down. Reopen it only if the "What would change this decision" condition holds.
- **Standard vs existing code:** the standard wins for new code. Do not rewrite working code
  to match; write the new code correctly and tell the user about the conflict.
- **Known gaps** are listed in `RULE-MAP.md` §4. If you are in one, warn the user and write
  your own decision with its reason into the code as a comment.

## Before saying "done"

```bash
bash <skill-dir>/tools/check-standards.sh .      # exit code must be 0
node <skill-dir>/tools/check-i18n.mjs src/shared/i18n/locales   # exit code must be 0
node <skill-dir>/tools/check-bundle-size.mjs dist budget.json   # after a build
npm run lint && npm run typecheck && npm test && npm run build
```

Then walk `15-NEW-FEATURE-CHECKLIST.md` item by item. Say explicitly which items were
skipped and why. A clean tool run is not "compliant"; tools see about 6 % of the rules.

## Never

- Say "works" without running it.
- Add a dependency without approval.
- Say "small change, no need to check the standard". The standard is always broken by a small change.
- Put a secret, a token or a private URL into a `VITE_` variable or the bundle.
- Bake time-sensitive data (SEO content, sitemap, feature flags) into the build artifact.
- Render data points as DOM markers on the map when a GPU layer would do.
