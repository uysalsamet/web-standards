# Rule Map

> **What this file is for.** The standard has more than 800 rules across 23 documents.
> Nobody reads them all, and nobody should. This file is the index that turns "I am about
> to write some code" into "these four rules apply to it".
>
> **How to use it.** Before writing, scan §1 for the signals that appear in the code you
> are about to write. Each signal names the rules it triggers. **Open those rules in their
> file and read them.** Do not write from what you remember; the point of a signal scan is
> that the rules you have forgotten are exactly the ones that bite. Then use §2 to pick
> the one or two documents the task as a whole belongs to.

---

## 1. Signal scan

A signal is something visible in the code: a token you are about to type, a file you are
about to create, a config directive. If it appears in your change, the rules beside it
apply.

### Data and the network

| Signal in your code | Rules it triggers | File |
|---|---|---|
| `fetch(`, a new HTTP call | [GEN-06], [API-01], [API-02] | [04](04-API-CLIENT.md) |
| A response typed with `as`, or an untyped `await res.json()` | [GEN-07], [API-33], [TS-07] | [04](04-API-CLIENT.md), [21](21-TYPESCRIPT-REACT-STYLE.md) |
| A new DTO, a new zod schema | [API-33], [FORM-02] | [04](04-API-CLIENT.md) |
| `useQuery`, `queryOptions`, a new query key | [STA-05], [STA-07], [STA-08] | [05](05-STATE-AND-DATA.md) |
| A mutation, or anything that writes on the server | [STA-12] (invalidate, never `clear()`) | [05](05-STATE-AND-DATA.md) |
| `createAsyncThunk`, or a slice that fetches | [GEN-05], [STA-28] | [05](05-STATE-AND-DATA.md) |
| A 401, 403, 409, 422 or 429 branch | [API-28], [API-31], [AUTH-07], [FORM-09] | [04](04-API-CLIENT.md), [19](19-AUTH-SESSION.md) |
| A date, a number or a currency crossing the wire | [API-18], [I18N-08] | [04](04-API-CLIENT.md), [09](09-I18N.md) |
| A coordinate crossing the wire | [API-20], [GIS-01], [GIS-03] | [04](04-API-CLIENT.md), [GIS](APPENDIX-GIS-DATA.md) |
| A file upload | [API-35], [API-36], [FORM-21], [SEC-26] | [04](04-API-CLIENT.md), [18](18-FORMS-VALIDATION.md) |

### State

| Signal | Rules | File |
|---|---|---|
| A new `useState` holding server data | [GEN-05], [STA-01] | [05](05-STATE-AND-DATA.md) |
| A new Redux slice | [STA-03], [STA-27], [STA-28] | [05](05-STATE-AND-DATA.md) |
| A filter, a selected id, a map viewport | [STA-02], [STA-30], [STA-31] | [05](05-STATE-AND-DATA.md) |
| `localStorage`, `sessionStorage`, any persistence | [STA-38], [AUTH-23], [FORM-35] | [05](05-STATE-AND-DATA.md), [19](19-AUTH-SESSION.md) |
| A token, a JWT, a session identifier anywhere in JS | [GEN-10], [AUTH-04], [STA-38] | [19](19-AUTH-SESSION.md), [06](06-SECURITY.md) |
| `useEffect` that calls `setState` | [STA-34], [TS-27] | [05](05-STATE-AND-DATA.md), [21](21-TYPESCRIPT-REACT-STYLE.md) |

### Map

| Signal | Rules | File |
|---|---|---|
| `new maplibregl.Map(` | [MAP-01] | [08](08-MAP-MAPLIBRE.md) |
| `new maplibregl.Marker(` | [GEN-18], [MAP-11] | [08](08-MAP-MAPLIBRE.md) |
| `addSource` / `addLayer` | [MAP-06], [MAP-19], [MAP-20] | [08](08-MAP-MAPLIBRE.md) |
| Hover or selection styling | [MAP-17], [MAP-18] (never `setData`) | [08](08-MAP-MAPLIBRE.md) |
| A `.geojson` file, or any dataset over 2 MB | [GEN-19], [MAP-19], [GIS-01] | [08](08-MAP-MAPLIBRE.md), [GIS](APPENDIX-GIS-DATA.md) |
| A tile URL, `source-layer`, MVT | [MAP-22], [MAP-23] | [08](08-MAP-MAPLIBRE.md) |
| A map popup with HTML | [SEC-01], [SEC-03] | [06](06-SECURITY.md) |
| A map event handler | [MAP-25] (`queryRenderedFeatures` with a layer filter) | [08](08-MAP-MAPLIBRE.md) |
| Anything added to the map in an effect | [GEN-20], [GEN-21] | [08](08-MAP-MAPLIBRE.md) |
| A bbox sent to an API | [MAP-25], [GIS-16] | [GIS](APPENDIX-GIS-DATA.md) |

### Text the user can see

| Signal | Rules | File |
|---|---|---|
| Any literal string in JSX, `title`, `placeholder`, `aria-label`, `alt` | [GEN-14], [I18N-03] | [09](09-I18N.md) |
| A new i18n key | [I18N-01] (parity), [I18N-06] (namespacing) | [09](09-I18N.md) |
| A date, number, currency or list shown to a user | [I18N-08], [I18N-09] | [09](09-I18N.md) |
| `toUpperCase()`, `toLowerCase()`, `sort()` on text | [I18N-24], [I18N-25], [FORM-24] | [09](09-I18N.md) |
| A validation message | [FORM-07], [I18N-12] | [18](18-FORMS-VALIDATION.md) |
| An error message shown to a user | [SEC-24], [OBS-09] | [06](06-SECURITY.md), [17](17-ERRORS-OBSERVABILITY.md) |

### Security

| Signal | Rules | File |
|---|---|---|
| `dangerouslySetInnerHTML` | [SEC-01] | [06](06-SECURITY.md) |
| A `VITE_` variable, or anything in `config.js` | [GEN-09], [GEN-10], [SEC-12] | [06](06-SECURITY.md), [11](11-DOCKER-COMPOSE.md) |
| A `<script>` or `<link>` to another origin | [SEC-14] | [06](06-SECURITY.md) |
| `window.open`, `target="_blank"` | [SEC-27] | [06](06-SECURITY.md) |
| An `<iframe>`, `postMessage` | [SEC-15] | [06](06-SECURITY.md) |
| `JSON.parse` of a URL parameter or a message | [SEC-28], [TS-07] | [06](06-SECURITY.md) |
| `eval`, `new Function` | [SEC-05] | [06](06-SECURITY.md) |
| A redirect built from a parameter (`returnTo`) | [AUTH-07], [SEC-27] | [19](19-AUTH-SESSION.md) |
| A source map, a `console.` call | [SEC-22], [SEC-23], [OBS-15], [OBS-16] | [06](06-SECURITY.md), [17](17-ERRORS-OBSERVABILITY.md) |
| A permission check in the UI | [AUTH-03], [AUTH-11] | [19](19-AUTH-SESSION.md) |

### React and TypeScript

| Signal | Rules | File |
|---|---|---|
| `any`, `as`, `!` | [TS-05] and the escape-hatch rules around it | [21](21-TYPESCRIPT-REACT-STYLE.md) |
| `React.FC` | [TS-21] | [21](21-TYPESCRIPT-REACT-STYLE.md) |
| `export default` | [STR-15] | [03](03-PROJECT-STRUCTURE.md) |
| `useMemo`, `useCallback`, `memo` | [PERF-11], [TS-13] | [07](07-PERFORMANCE.md) |
| `useEffect` for anything other than an external system | [STA-34], [TS-27] | [21](21-TYPESCRIPT-REACT-STYLE.md) |
| `addEventListener`, a timer, a subscription | [GEN-21], [RT-12] | [21](21-TYPESCRIPT-REACT-STYLE.md) |
| An empty `catch` | [GEN-17], [TS-09] | [21](21-TYPESCRIPT-REACT-STYLE.md) |
| A promise you do not await | [TS-09] and the floating-promise rule | [21](21-TYPESCRIPT-REACT-STYLE.md) |
| A new file over 400 lines, a component over 250 | [GEN-08] | [03](03-PROJECT-STRUCTURE.md) |

### Structure and routing

| Signal | Rules | File |
|---|---|---|
| A new feature folder | [STR-05], [STR-06] (index.ts and README.md) | [03](03-PROJECT-STRUCTURE.md) |
| An import from another feature | [STR-11], [STR-12] | [03](03-PROJECT-STRUCTURE.md) |
| An import in `src/shared/` | [STR-10] | [03](03-PROJECT-STRUCTURE.md) |
| A new route path | [RTE-03], [RTE-05], [PERF-04] | [22](22-ROUTING.md) |
| A route guard | [RTE-24], [AUTH-18] | [22](22-ROUTING.md), [19](19-AUTH-SESSION.md) |
| A form that can be left half-filled | [FORM-14], [RTE-17] | [18](18-FORMS-VALIDATION.md) |
| A new proxy prefix in `vite.config.ts` or nginx | [RTE-16] (it must not swallow a route) | [22](22-ROUTING.md) |

### Accessibility and UX

| Signal | Rules | File |
|---|---|---|
| A `div` with `onClick` | [A11Y-01] and the semantics rules | [16](16-ACCESSIBILITY-UX.md) |
| A modal, a dropdown, any overlay | [A11Y-08], [A11Y-09] | [16](16-ACCESSIBILITY-UX.md) |
| `outline: none`, a custom focus style | [A11Y-09] | [16](16-ACCESSIBILITY-UX.md) |
| An icon-only button | [A11Y-29] | [16](16-ACCESSIBILITY-UX.md) |
| An animation or a transition | [A11Y-12] | [16](16-ACCESSIBILITY-UX.md) |
| A `z-index` | [A11Y-28] | [16](16-ACCESSIBILITY-UX.md) |
| Any async region in the UI | [GEN-15] | [16](16-ACCESSIBILITY-UX.md) |
| Colour used to encode meaning | The colour rules in [16](16-ACCESSIBILITY-UX.md) §4 | [16](16-ACCESSIBILITY-UX.md) |

### Realtime and heavy work

| Signal | Rules | File |
|---|---|---|
| `mqtt.connect`, a WebSocket, an EventSource | [RT-01], [RT-02], [SEC-19] | [20](20-REALTIME-MEDIA.md) |
| A message arriving faster than once a second | [RT-06], [RT-10] | [20](20-REALTIME-MEDIA.md) |
| `new Worker` | [RT-12], [STR-22] | [20](20-REALTIME-MEDIA.md) |
| A video element, HLS, WebRTC | [RT-27], [RT-28], [RT-29] | [20](20-REALTIME-MEDIA.md) |
| A list or table that can exceed 200 rows | [PERF-12] | [07](07-PERFORMANCE.md) |
| An `import()` of a heavy library | [PERF-05] | [07](07-PERFORMANCE.md) |
| A new dependency in `package.json` | [GEN-03], [VER-05], [VER-06] | [02](02-TECH-VERSIONS.md) |

### SEO and public pages

| Signal | Rules | File |
|---|---|---|
| A `<title>` or `<meta>` | [SEO-04] | [10](10-SEO-RENDERING.md) |
| A page that search engines should index | [GEN-11], [SEO-01] | [10](10-SEO-RENDERING.md) |
| API data read at build time | [GEN-11] (forbidden) | [10](10-SEO-RENDERING.md) |
| A canonical URL, `hreflang`, a locale prefix | [SEO-07], [SEO-08], [SEO-09] | [10](10-SEO-RENDERING.md) |
| `robots.txt`, `sitemap.xml` | [SEO-30], [SEO-31], [NGX-19] | [10](10-SEO-RENDERING.md), [12](12-NGINX.md) |

### Infrastructure

| Signal | Rules | File |
|---|---|---|
| `FROM` in a Dockerfile | [VER-02], [OPS-03] | [11](11-DOCKER-COMPOSE.md) |
| `npm install` in a Dockerfile or CI | [VER-04], [OPS-13] | [11](11-DOCKER-COMPOSE.md) |
| A `VITE_` build `ARG` | [GEN-09], [OPS-14] | [11](11-DOCKER-COMPOSE.md) |
| A new environment variable | [OPS-14] and the env-layering rules in §5 | [11](11-DOCKER-COMPOSE.md) |
| A `location` block | [NGX-25] and the location rules | [12](12-NGINX.md) |
| `add_header` inside a location | [NGX-10] (it replaces inherited headers) | [12](12-NGINX.md) |
| `proxy_pass` with a variable | [NGX-17] (needs `resolver`) | [12](12-NGINX.md) |
| A cache header | [GEN-12], [NGX-04], [NGX-05] | [12](12-NGINX.md) |
| A new CI job or a GitHub Action | [GEN-23], [SEC-21] | [14](14-GIT-CI.md) |

---

## 2. Reading list by task

Read `01-GOLDEN-RULES.md` first, always. Then:

| Task | Read | Skim |
|---|---|---|
| Starting a new app | [02](02-TECH-VERSIONS.md), [03](03-PROJECT-STRUCTURE.md), [11](11-DOCKER-COMPOSE.md), [12](12-NGINX.md), [15](15-NEW-FEATURE-CHECKLIST.md) | [14](14-GIT-CI.md), [START.md](START.md) |
| Adding a feature | [03](03-PROJECT-STRUCTURE.md) §2, [04](04-API-CLIENT.md), [05](05-STATE-AND-DATA.md), [15](15-NEW-FEATURE-CHECKLIST.md) | [09](09-I18N.md), [16](16-ACCESSIBILITY-UX.md) |
| Map work | [08](08-MAP-MAPLIBRE.md), [APPENDIX-GIS-DATA.md](APPENDIX-GIS-DATA.md) | [07](07-PERFORMANCE.md) §5, [16](16-ACCESSIBILITY-UX.md) §6 |
| A form | [18](18-FORMS-VALIDATION.md), [04](04-API-CLIENT.md) §5 | [09](09-I18N.md), [16](16-ACCESSIBILITY-UX.md) |
| Login, permissions, sessions | [19](19-AUTH-SESSION.md), [06](06-SECURITY.md) §4 | [22](22-ROUTING.md) §6 |
| A public, indexable page | [10](10-SEO-RENDERING.md), [12](12-NGINX.md) | [09](09-I18N.md), [07](07-PERFORMANCE.md) |
| Adding text, a new language | [09](09-I18N.md) | [16](16-ACCESSIBILITY-UX.md) |
| Something is slow | [07](07-PERFORMANCE.md) | [08](08-MAP-MAPLIBRE.md) §11, [05](05-STATE-AND-DATA.md) |
| Something is broken in production | [17](17-ERRORS-OBSERVABILITY.md) | [12](12-NGINX.md) §12, [11](11-DOCKER-COMPOSE.md) §9 |
| Docker, nginx, deploy | [11](11-DOCKER-COMPOSE.md), [12](12-NGINX.md) | [06](06-SECURITY.md) §3, [14](14-GIT-CI.md) |
| Live data, video | [20](20-REALTIME-MEDIA.md) | [05](05-STATE-AND-DATA.md), [07](07-PERFORMANCE.md) |
| Writing tests | [13](13-TESTING.md) | the file for the thing under test |
| Routing, URLs | [22](22-ROUTING.md) | [05](05-STATE-AND-DATA.md) §4 |
| Code review | [01](01-GOLDEN-RULES.md), §1 of this file, [15](15-NEW-FEATURE-CHECKLIST.md) | [14](14-GIT-CI.md) |
| "Why do we use X?" | [adr/](adr/README.md) | [02](02-TECH-VERSIONS.md) |

---

## 3. Where each prefix lives

| Prefix | Document | Prefix | Document |
|---|---|---|---|
| GEN | [01](01-GOLDEN-RULES.md) | I18N | [09](09-I18N.md) |
| VER | [02](02-TECH-VERSIONS.md) | SEO | [10](10-SEO-RENDERING.md) |
| STR | [03](03-PROJECT-STRUCTURE.md) | OPS | [11](11-DOCKER-COMPOSE.md) |
| API | [04](04-API-CLIENT.md) | NGX | [12](12-NGINX.md) |
| STA | [05](05-STATE-AND-DATA.md) | TEST | [13](13-TESTING.md) |
| SEC | [06](06-SECURITY.md) | CI | [14](14-GIT-CI.md) |
| PERF | [07](07-PERFORMANCE.md) | A11Y | [16](16-ACCESSIBILITY-UX.md) |
| MAP | [08](08-MAP-MAPLIBRE.md) | OBS | [17](17-ERRORS-OBSERVABILITY.md) |
| FORM | [18](18-FORMS-VALIDATION.md) | AUTH | [19](19-AUTH-SESSION.md) |
| RT | [20](20-REALTIME-MEDIA.md) | TS | [21](21-TYPESCRIPT-REACT-STYLE.md) |
| RTE | [22](22-ROUTING.md) | GIS | [APPENDIX-GIS-DATA.md](APPENDIX-GIS-DATA.md) |
| TOOL | [tools/README.md](tools/README.md) | | |

`node tools/check-refs.mjs .` prints the live count per prefix and fails if a rule is cited
but never defined.

---

## 4. Known gaps

These are places where the standard deliberately stops short. If your task falls into one:
**say so to the user**, make your own decision, and write the reason into the code as a
comment. Do not pretend a rule exists.

| Gap | What is undecided | What would close it |
|---|---|---|
| Monorepo and shared packages | The standard assumes one app per project ([STR-01]). Sharing components across three apps has no defined mechanism | Three apps copying the same component. Then a workspace package with its own tests and version, and an ADR |
| Full server-side rendering | [10](10-SEO-RENDERING.md) covers request-time head injection and SSR for SEO routes. A product that is mostly public and personalised is not covered | A product where most pages must be indexed and per-user. That gets its own ADR choosing a framework |
| Automated accessibility testing | `axe-core` is not in the version table, so no rule requires it. Coverage is lint plus a manual keyboard pass | A measured rate of a11y defects reaching production that lint does not catch |
| Very large dynamic point sets | Above roughly 200,000 animated points, MapLibre layers stop being enough and deck.gl becomes the answer. deck.gl is not in the table | A product that measurably needs it. It requires an ADR and a bundle-budget revision |
| Lazy locale loading | Bundling locales works to three languages. Beyond that needs `i18next-http-backend`, which is not approved | A fourth locale, or a locale bundle above 200 KB |
| Design system and component primitives | `src/shared/components/` is hand-built. Headless primitives (Radix, React Aria) are not in the table | The a11y cost of hand-rolled overlays becoming measurable, or a second app needing the same components |
| Offline and PWA | No service worker, no offline strategy, no install prompt | A field-use requirement, which changes caching, auth and data sync at once |
| Mobile applications | React Native is out of scope entirely | A native product. It would be a separate standard, not a section here |
| Feature-local locale files | [STR-05] allows a feature `locales/` folder but the build-time merge step does not exist in `tools/` | Someone writing the merge script; until then all keys live in the shared locale files |
| Backend SEO contract | The injector's `GET /seo/meta` shape is defined only by the frontend's schema | The backend standard adopting it as a published contract |

---

## 5. When the map is wrong

If you followed a signal here and the rule it named did not apply, or you hit a rule this
map does not mention, the map is the thing to fix. Add the signal, or correct the rule id,
in the same pull request as the code. A stale index is worse than no index, because it is
trusted.
