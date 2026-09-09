# 15 — New Feature Checklist

> Copy it, tick it item by item. **Every item you skip is written down in the pull request
> with its reason.** An item skipped with "I will do it later" is an item that does not get
> done.
>
> Sections A to J apply to any feature. K applies when the feature touches the map, L when
> it has a form, M when the page is publicly indexable, N when it consumes live data.
> Section O is for a new application rather than a new feature.
>
> The automated part is `bash tools/check-standards.sh .`, which covers about 6 % of
> this list. The rest is you.

---

## A. Structure

- [ ] Feature folder is PascalCase, a singular domain noun — [STR-04]
- [ ] `index.ts` exists and exports only the public API — [STR-05]
- [ ] `README.md` exists: purpose, routes, map layers and source ids, endpoints, permissions — [STR-06]
- [ ] No `utils/` inside the feature; pure logic is in `lib/` — [STR-09]
- [ ] No empty subfolders — [STR-07]
- [ ] Nothing imports another feature's internals; only `@/features/<Name>` — [STR-11]
- [ ] Nothing in `src/shared/` imports from `features/` or `app/` — [STR-10]
- [ ] Every file under 400 lines, every component under 250 — [GEN-08]
- [ ] Named exports only — [STR-15]
- [ ] Comments explain why, not what — [STR-28]

## B. Types

- [ ] No `any`, no `as` on a response, no non-null `!` — [TS-05]
- [ ] No `React.FC`; props typed explicitly — [TS-21]
- [ ] UI state is a discriminated union, not several booleans
- [ ] Ids that must not be mixed up are branded — [TS-10]
- [ ] `catch (e: unknown)` with a real narrowing — [TS-09]
- [ ] No floating promises

## C. Data and the API

- [ ] Every call goes through the shared client; no bare `fetch` — [GEN-06], [API-01]
- [ ] Every response is parsed with a zod schema — [GEN-07], [API-33]
- [ ] Server data lives only in TanStack Query — [GEN-05], [STA-01]
- [ ] Queries are defined with `queryOptions` and a key factory — [STA-05]
- [ ] `staleTime` chosen deliberately for this domain, not left at the default by accident — [STA-07]
- [ ] Mutations invalidate the affected list and detail keys; no `queryClient.clear()` — [STA-12]
- [ ] No `createAsyncThunk`, no HTTP in a slice — [STA-28]
- [ ] 401, 403, 409, 422 and 429 all have a defined behaviour — [API-28], [API-31]
- [ ] Requests are cancelled on unmount
- [ ] Pagination limits are clamped

## D. State

- [ ] Anything a user would share by link or expect to survive a reload is in the URL — [STA-02], [STA-30]
- [ ] Redux holds only cross-feature client state; no server data — [STA-03], [STA-27]
- [ ] Nothing persisted to `localStorage` except whitelisted UI preferences with a versioned key — [STA-38]
- [ ] No token, session id or permission list in web storage — [AUTH-04]
- [ ] No `useEffect` that only derives state from props — [STA-34], [TS-27]

## E. Text and locale

- [ ] No literal user-visible strings anywhere, including `title`, `placeholder`, `aria-label`, `alt` — [GEN-14], [I18N-03]
- [ ] Every new key exists in **every** locale file with the same nesting and the same placeholders — [I18N-01]
- [ ] Keys are namespaced by feature — [I18N-06]
- [ ] Dates, numbers, currency and lists formatted with `Intl` — [I18N-08]
- [ ] No `toUpperCase()` / `toLowerCase()` on Turkish text; sorting uses a collator — [I18N-24], [I18N-25]
- [ ] `node tools/check-i18n.mjs src/shared/i18n/locales --src src` exits 0

## F. Errors and observability

- [ ] No empty `catch` — [GEN-17]
- [ ] The route has an error boundary; a non-critical panel has its own — [OBS-03]
- [ ] User-facing messages come from i18n by error code, never a raw server string — [OBS-09], [SEC-24]
- [ ] Every async region has loading, empty, error and success states — [GEN-15]
- [ ] Error states offer a retry or a way out
- [ ] No `console.*` outside the logger wrapper — [OBS-16]
- [ ] Nothing personal reaches the error tracker — [OBS-12], [SEC-25]

## G. Security

- [ ] No `dangerouslySetInnerHTML` outside `SafeHtml` — [SEC-01]
- [ ] Nothing secret in `VITE_*`, `config.js`, source or the bundle — [GEN-10], [SEC-12]
- [ ] No third-party script or style origin added — [SEC-14]
- [ ] `window.open` and `target="_blank"` carry `noopener` — [SEC-27]
- [ ] Anything parsed from a URL parameter or a message is schema-checked — [SEC-28]
- [ ] Permission checks use `can()` and the server enforces the same rule — [AUTH-03], [AUTH-11]
- [ ] No new dependency, or one approved and added to the version table — [GEN-03], [VER-05]

## H. Performance

- [ ] The route is lazy — [PERF-04], [RTE-03]
- [ ] Heavy libraries are imported on demand, not at module top level — [PERF-05]
- [ ] Lists or tables over 200 rows are virtualised — [PERF-12]
- [ ] No manual `useMemo` / `useCallback` / `memo` without a measurement in a comment — [PERF-11]
- [ ] Bundle budget still passes: `node tools/check-bundle-size.mjs dist budget.json`
- [ ] If this change was made for performance, the pull request carries a before and after number

## I. Accessibility and UX

- [ ] Actions are `<button>`, navigation is `<a>`; no `div` with `onClick` — [A11Y-01]
- [ ] Everything reachable and operable by keyboard, with a visible focus ring — [A11Y-09]
- [ ] Overlays trap focus and return it on close; Escape closes — [A11Y-08]
- [ ] Icon-only controls have a label — [A11Y-29]
- [ ] Contrast meets AA; colour is never the only encoding
- [ ] Animations respect `prefers-reduced-motion` — [A11Y-12]
- [ ] `z-index` comes from the token scale — [A11Y-28]
- [ ] Works at mobile width with no horizontal scroll
- [ ] A keyboard-only pass was actually performed, not assumed

## J. Tests

- [ ] Pure logic in `lib/` and `utils/` has unit tests
- [ ] The main user path has a component test using the real `tr` bundle — [TEST-09]
- [ ] Network is mocked with MSW; no test hits a real backend — [TEST-11]
- [ ] Error and empty paths are tested, not only the happy path
- [ ] Coverage thresholds still pass — [TEST-38]
- [ ] No test was made to pass by weakening an assertion

## K. Map (only if the feature touches the map)

- [ ] No second `maplibregl.Map` instance — [MAP-01]
- [ ] Data is rendered as layers, not markers — [GEN-18], [MAP-11]
- [ ] Source and layer ids follow `<feature>-<kind>[-<variant>]`
- [ ] Layers are registered with an explicit `beforeId` anchor — [MAP-06]
- [ ] Hover and selection use `feature-state`, never `setData` — [MAP-17], [MAP-18]
- [ ] GeoJSON stays under 5,000 features and 2 MB; larger data is served as tiles — [GEN-19], [MAP-19]
- [ ] Features carry stable ids so `feature-state` works — [GIS-14]
- [ ] Coordinates are `[lng, lat]` and rounded to 6 decimals — [GIS-01], [GIS-03]
- [ ] Popups use DOM content, not an HTML string built from data — [SEC-03]
- [ ] Every layer, source, image, listener and popup is removed on unmount, in the right order — [GEN-20]
- [ ] The feature survives a style switch (light, dark, satellite)
- [ ] It survives React StrictMode's double mount — [GEN-21]
- [ ] The map data has a non-visual equivalent (a list or a table)

## L. Form (only if the feature has a form)

- [ ] react-hook-form with a zod resolver; the schema extends the request schema — [FORM-02]
- [ ] Validation messages are i18n keys — [FORM-07]
- [ ] Server 422 errors map onto the right fields — [FORM-09]
- [ ] Errors are announced accessibly and the first invalid field takes focus — [FORM-38]
- [ ] Submit is disabled while in flight; double submit is impossible
- [ ] Unsaved changes block navigation — [FORM-14], [RTE-17]
- [ ] Turkish identifiers (national id, tax number, phone, IBAN, plate) use the shared validators — [FORM-26]
- [ ] Numbers accept the Turkish decimal comma and store a real number — [FORM-24]
- [ ] File inputs check type, size and count before sending — [SEC-26]

## M. Public page (only if it should be indexed)

- [ ] No API data baked into the build — [GEN-11]
- [ ] Title, description, canonical and Open Graph tags per page — [SEO-04], [SEO-07]
- [ ] Locale is in the URL, with `hreflang` alternates — [SEO-08], [SEO-09]
- [ ] An unknown URL under an indexed prefix returns a real 404, not a 200
- [ ] Structured data matches what the page actually shows
- [ ] Verified with `curl -A Googlebot` against a running container, not assumed

## N. Live data (only if the feature consumes it)

- [ ] One shared client, lazy-loaded, not one per component — [RT-01]
- [ ] Connects only after authentication, with a short-lived credential — [RT-02], [SEC-19]
- [ ] Subscriptions are removed on unmount and shared subscriptions are ref-counted
- [ ] Messages are schema-checked and invalid ones dropped with one warning
- [ ] Updates are batched and capped; positions at most 4 Hz — [RT-06], [RT-10]
- [ ] Processing pauses when the tab is hidden
- [ ] Video players are destroyed on unmount — [RT-29]

## O. New application (only when starting one)

- [ ] Stack and versions taken from the table — [GEN-01], [VER-01]
- [ ] Repository layout matches [03](03-PROJECT-STRUCTURE.md) §1
- [ ] Runtime config through `/config.js`; no `VITE_*` per-environment build args — [GEN-09]
- [ ] Container fails to start when a required variable is empty
- [ ] Multi-stage Dockerfile, pinned base, non-root, `HEALTHCHECK`, `.dockerignore` — [GEN-13], [OPS-03]
- [ ] nginx: SPA fallback, `immutable` assets, `no-cache` on `index.html` and `config.js`, `/healthz`, security headers, `*.map` denied — [GEN-12]
- [ ] `bash tools/nginx-smoke.sh` passes on the rendered config
- [ ] Dev proxy prefixes and route paths do not collide — [RTE-16]
- [ ] Agent instruction files copied to the repo root ([START.md](START.md))
- [ ] All twelve CI checks wired and marked required — [GEN-23]
- [ ] `docs/README.md` written: what the app is, its pages, its upstreams and ports

---

## Before you say "done"

```bash
bash frontend-standards/tools/check-standards.sh .                       # exit 0
node frontend-standards/tools/check-i18n.mjs src/shared/i18n/locales --src src   # exit 0
npm run lint && npm run typecheck && npm test && npm run build
node frontend-standards/tools/check-bundle-size.mjs dist budget.json     # exit 0
```

Then run the application and use the feature. A green pipeline is not evidence that the
feature works; it is evidence that nothing obviously broke.

**In the pull request, write:**

1. Which sections of this checklist apply and which you skipped, each with a reason.
2. Any rule you had to break, and why.
3. Any gap in the standard you hit ([RULE-MAP.md](RULE-MAP.md) §4), and the decision you
   made instead.

> A clean tool run does **not** mean the code follows the standard. The tools see roughly a
> tenth of the rules ([TOOL-04]). The rest of this list is the part only you can confirm.
