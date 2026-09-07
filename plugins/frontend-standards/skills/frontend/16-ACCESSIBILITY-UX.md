# 16 — Accessibility and UX

> The baseline every screen meets: correct semantics, full keyboard operation, visible focus,
> WCAG AA contrast, respected user preferences, and the four states (loading, empty, error,
> success) on every asynchronous region. Municipal software is used by people who did not choose
> it and cannot switch, including on a 5-year-old Android phone at a counter window, so this is a
> functional requirement, not a polish task.
>
> Read before building any UI. Map-specific accessibility is here (§8); map rendering rules are
> in [08](08-MAP-MAPLIBRE.md). Design tokens and styling mechanism are
> [ADR-0007](adr/0007-styling.md); form-specific rules are [18](18-FORMS-VALIDATION.md); i18n
> is [09](09-I18N.md).

---

## 1. Semantics first

**[A11Y-01] MUST:** `eslint-plugin-jsx-a11y`'s `recommended` flat config runs on all of `src/`
with severity `error`, in the same lint job that gates the PR ([GEN-23], [CI-03]). Rules are
disabled per line with a written reason, never globally.
> **Why:** This is the ~30 % of accessibility that a machine can check for free: missing
> `alt`, click handlers on non-interactive elements, `<label>` without a control, invalid ARIA
> attribute names, positive `tabIndex`. Running it as a warning means it is ignored within two
> sprints.

```js
// eslint.config.js (excerpt)
import jsxA11y from 'eslint-plugin-jsx-a11y'

export default defineConfig([
  {
    files: ['src/**/*.tsx'],
    // `flatConfigs.recommended` already sets severity to error for every rule it enables.
    ...jsxA11y.flatConfigs.recommended,
  },
])
```

**[A11Y-02] MUST:** An action is a `<button type="button">`; a navigation to a URL is an `<a>`
or a router `<Link>`. A `<div>` or `<span>` with `onClick` is forbidden.
> **Why:** A `div` with a click handler is not focusable, does not fire on Enter or Space, is not
> announced as a control, has no disabled state, and cannot be opened in a new tab when it is
> really a link. Adding `role="button"` plus `tabIndex` plus two key handlers reimplements
> `<button>` badly; `jsx-a11y` flags it and the fix is to use the right element.

```tsx
// WRONG: not focusable, no keyboard activation, no role.
<div className="btn" onClick={openPanel}>{t('details')}</div>

// RIGHT.
<button type="button" className="btn" onClick={openPanel}>{t('details')}</button>

// RIGHT, when it navigates: middle-click and "open in new tab" work.
<Link to={`/parking/${id}`} className="btn">{t('details')}</Link>
```

**[A11Y-03] MUST:** Every page uses landmarks: one `<header>`, one `<nav>` for primary
navigation, one `<main>` wrapping the routed content, `<aside>` for side panels, `<footer>` where
one exists. `<main>` is rendered once, in the app layout, not per page.
> **Why:** Screen-reader users navigate by landmark before they navigate by heading. A page built
> entirely from `<div>` requires reading it linearly from the top on every route change.

**[A11Y-04] MUST:** Exactly one `<h1>` per page, and heading levels descend without skipping
(`h1` then `h2`, never `h1` then `h3`). Heading level is chosen by document structure, never by
font size; size comes from a utility class.
> **Why:** The heading tree is the table of contents assistive technology reads. Skipping a level
> makes a section look like a subsection of the wrong parent.

**[A11Y-05] MUST:** Modals and dialogs use the native `<dialog>` element with `showModal()`, or
a component built on it.
> **Why:** `<dialog showModal>` gives focus trapping, the inert background, Escape handling and
> the top layer (so it is above everything regardless of z-index) from the platform, correctly,
> in every browser of [VER-12]. Every hand-rolled modal in this codebase family has had at least
> one of those four wrong.

**[A11Y-06] MUST:** Every form control has a programmatically associated visible label
(`<label htmlFor>`), and grouped controls (radio sets, related checkboxes, an address block) are
wrapped in `<fieldset>` with a `<legend>` ([FORM-06], [FORM-37]).

---

## 2. Keyboard and focus

**[A11Y-07] MUST:** Every interactive element is reachable and operable with Tab, Shift+Tab,
Enter and Space, in the visual order. `tabIndex` is `0` or `-1` only; positive values are
forbidden.
> **Why:** A positive `tabIndex` moves that element ahead of the entire document's natural order,
> so the tab sequence becomes unpredictable everywhere else on the page. `-1` is for
> programmatic focus targets (an error summary, a panel heading), not for removing things from
> the keyboard.

**[A11Y-08] MUST:** An overlay (modal, drawer, popover, map popup) moves focus into itself when
opened, traps focus while open, and returns focus to the element that opened it when closed.
> **Why:** Without the return, focus falls back to `<body>` and the next Tab starts from the top
> of the page. A user who opened a row's action dialog then has to tab past the whole header and
> table to get back to where they were. Native `<dialog>` ([A11Y-05]) handles the trap; the
> return is on the component. Map popups opened by keyboard follow the same rule ([MAP-36]).

```tsx
// The return-focus half, which <dialog> does not do for you.
const openerRef = useRef<HTMLElement | null>(null)

function open() {
  openerRef.current = document.activeElement as HTMLElement | null
  dialogRef.current?.showModal()
}
function close() {
  dialogRef.current?.close()
  // The opener may have unmounted (a deleted row); isConnected guards that.
  if (openerRef.current?.isConnected) openerRef.current.focus()
}
```

**[A11Y-09] MUST:** Focus is visible on every focusable element, with a `:focus-visible` ring of
at least 2 px and 3:1 contrast against the adjacent colour. `outline: none` without an equivalent
replacement is forbidden anywhere, including resets.
> **Why:** Removing the outline is the single most common accessibility defect in CSS, and it
> makes the application unusable by keyboard: the user has no idea what Enter will activate.
> `:focus-visible` rather than `:focus` means mouse users do not see a ring after a click, which
> is the reason people removed the outline in the first place.

```css
/* src/shared/styles/index.css */
:where(a, button, input, select, textarea, summary, [tabindex]):focus-visible {
  outline: 2px solid var(--color-focus);
  outline-offset: 2px;
  border-radius: var(--radius-sm);
}
```

**[A11Y-10] MUST:** Escape closes the topmost overlay (dialog, popover, popup, drawer,
combobox list) and nothing else; arrow keys move within composite widgets (menus, tabs,
listboxes, tree views) where Tab enters and leaves the widget as a whole.
> **Why:** A menu of 30 items that costs 30 Tab presses to leave is a keyboard trap in practice.
> The composite-widget pattern (one tab stop, arrows inside) is what assistive technology and
> users both expect.

**[A11Y-11] MUST:** The first focusable element of the page is a skip link to `#main-content`,
visually hidden until focused.
> **Why:** Otherwise a keyboard user tabs through the entire header and 25-item sidebar on every
> route change before reaching the content.

```tsx
// src/app/layouts/AppLayout.tsx (excerpt)
<a href="#main-content" className="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-modal">
  {t('a11y.skipToContent')}
</a>
...
<main id="main-content" tabIndex={-1}>{children}</main>
```

---

## 3. User preferences

**[A11Y-12] MUST:** `prefers-reduced-motion: reduce` disables non-essential animation and
transition. The map uses `jumpTo` instead of `flyTo`/`easeTo` ([MAP-48]), skeleton shimmer stops,
and toasts appear without a slide.
> **Why:** For users with vestibular disorders a 700 ms map fly-to is nausea, not delight. The
> preference is a real system setting people turn on deliberately.

```css
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after {
    animation-duration: 0.01ms !important;
    animation-iteration-count: 1 !important;
    transition-duration: 0.01ms !important;
    scroll-behavior: auto !important;
  }
}
```

```ts
// src/shared/hooks/usePrefersReducedMotion.ts
// JS also needs the value: MapLibre camera calls are not CSS.
export function usePrefersReducedMotion(): boolean {
  return useMediaQuery('(prefers-reduced-motion: reduce)')
}
```

**[A11Y-13] MUST:** `prefers-contrast: more` raises border and text contrast through token
overrides, and `forced-colors: active` (Windows high contrast) is not fought: no
`forced-color-adjust: none`, and elements that convey state with background colour alone get a
border or `forced-colors`-visible outline.
> **Why:** In forced-colors mode the OS replaces the palette. A status pill that is "green
> background, white text" becomes one solid system colour and loses its meaning entirely unless
> it also carries a border or a label.

---

## 4. Colour, tokens and layout stability

**[A11Y-14] MUST:** Contrast meets WCAG 2.2 AA: **4.5:1** for text under 18.66 px regular or
24 px bold, **3:1** for larger text, and **3:1** for the visible boundary of interactive
components and meaningful graphics (borders, icons, focus rings, chart series).
> **Why:** AA is the level referenced by Turkish public-sector accessibility guidance and by the
> EU accessibility directive that municipal portals are measured against. Grey-on-grey secondary
> text at 3:1 is unreadable outdoors on a phone, which is where field inspection apps are used.
> Verify with the DevTools contrast picker, not by eye.

**[A11Y-15] MUST:** Interactive targets are at least **44 x 44 CSS px** (the padded hit area may
exceed the visible control), never below 24 x 24; map feature hit targets follow [MAP-32]
(24 px diameter). Spacing and sizing come from the token scale; arbitrary Tailwind values
(`p-[13px]`, `w-[327px]`) require a written reason in the PR.
> **Why:** 44 px is the size at which a thumb hits a control on the first attempt; below 24 px
> WCAG 2.2 target size fails outright. Arbitrary values are how a 4 px spacing scale becomes 19
> distinct paddings that no longer align across screens.

**[A11Y-16] MUST:** Colours, spacing, radii, shadows and z-indices are CSS custom properties
defined in `src/shared/styles/index.css` and consumed through Tailwind theme tokens. Raw hex
values in components are forbidden.
> **Why:** A hex value in a component cannot participate in the dark theme, the contrast
> preference or the forced-colors mode, and it is invisible to a palette change. Detail:
> [ADR-0007](adr/0007-styling.md).

```css
/* src/shared/styles/index.css */
@import 'tailwindcss';

@theme {
  --color-surface: #ffffff;
  --color-text: #111827;          /* 16.1:1 on surface */
  --color-text-muted: #4b5563;    /* 7.6:1 on surface: still AA at small sizes */
  --color-focus: #1d4ed8;
  --color-danger: #b91c1c;        /* 5.9:1 on surface */

  /* One scale, four values, used by every overlay. See [A11Y-28]. */
  --z-map-controls: 10;
  --z-panel: 100;
  --z-modal: 1000;
  --z-toast: 2000;
}
```

**[A11Y-17] MUST:** The dark theme is driven by `data-theme` on `<html>` with
`prefers-color-scheme` as the default when the user has expressed no preference. Every token has
a dark value; components never branch on the theme in JavaScript.
> **Why:** A JS branch means the theme is wrong for one frame on every load and impossible to
> style from CSS alone. The attribute lets the OS preference win by default and lets an explicit
> user choice override it, which is the behaviour people expect.

```css
:root { color-scheme: light; --color-surface: #ffffff; --color-text: #111827; }

@media (prefers-color-scheme: dark) {
  :root:not([data-theme='light']) { color-scheme: dark; --color-surface: #0f172a; --color-text: #e5e7eb; }
}

:root[data-theme='dark'] { color-scheme: dark; --color-surface: #0f172a; --color-text: #e5e7eb; }
```

**[A11Y-18] MUST:** A region that will be replaced by loaded content reserves its space: a
skeleton with the same dimensions, an image with `width`/`height` or `aspect-ratio`, a table that
keeps its rows during a page change ([STA-18]). Cumulative Layout Shift stays within the budget
in [PERF-21].
> **Why:** Content that jumps down after 400 ms makes the user click the wrong row. This is the
> mechanism behind most real CLS in this stack: a spinner 40 px tall replaced by a 900 px table.

---

## 5. ARIA, used sparingly

**[A11Y-19] MUST:** ARIA is used only where native semantics cannot express the meaning. A role
that duplicates the element (`<button role="button">`, `<nav role="navigation">`) is removed.
> **Why:** "No ARIA is better than bad ARIA": an incorrect `role` overrides the correct native
> semantics and makes the element less usable than the plain element would have been.

**[A11Y-20] MUST:** Every control has a non-empty accessible name. Icon-only buttons carry
`aria-label` (a translated string, not an English literal, [GEN-14]); a disabled control still
needs its name, and the reason it is disabled is available as text or a tooltip, not by colour
alone ([AUTH-14]).
> **Why:** "Button" is what a screen reader announces for `<button><TrashIcon /></button>`, and
> `aria-label="Delete"` in a Turkish interface is announced in English by a Turkish voice, which
> is worse than useless.

```tsx
<button type="button" aria-label={t('parking.deleteAria', { name })} onClick={onDelete}>
  <Trash2 aria-hidden="true" />   {/* decorative: hide the SVG from the accessibility tree */}
</button>
```

**[A11Y-21] MUST:** Status that changes without user action is announced: toasts render inside a
live region, an async region under refresh sets `aria-busy="true"`, and inline result counts use
`role="status"` (polite). `role="alert"` (assertive) is reserved for errors and validation
failures.
> **Why:** A sighted user sees "142 results" update; a screen-reader user hears nothing at all
> unless the region is live. Making everything assertive is worse: it interrupts the user
> mid-sentence for a routine update.

**[A11Y-22] MUST:** Disclosure controls (accordion, dropdown, collapsible panel) set
`aria-expanded` and `aria-controls` pointing at the id of the region they toggle; the region is
removed from the accessibility tree when hidden (`hidden`, or unmounted, not `opacity: 0`).
> **Why:** Without `aria-expanded` the control announces identically open and closed, so the user
> cannot tell whether their activation worked. A panel hidden with `opacity: 0` is still focusable
> and still read, which produces phantom content.

---

## 6. The four states

**[A11Y-23] MUST:** Every asynchronous region implements loading, empty, error and success
([GEN-15]). "Nothing rendered" is not an empty state and "the spinner never stops" is not an
error state.

**[A11Y-24] MUST:** Content that is loading shows a **skeleton** matching its final layout;
an action in progress shows a **spinner or a busy button**. A loading indicator that would appear
for under 300 ms is not shown at all (delay the indicator, not the content).
> **Why:** A skeleton communicates the shape of what is coming and reserves layout ([A11Y-18]); a
> spinner in the middle of a page communicates only "wait". Below 300 ms a spinner is perceived
> as a flicker, which reads as a glitch rather than as speed.

**[A11Y-25] MUST:** An empty state states what is missing and offers the next action ("no
parking areas yet" plus a "create" button, or "no results for X" plus a "clear filters" button);
an error state shows a human message from an i18n key, the request id ([API-07]) and a retry
button, never a raw exception or a stack trace ([SEC-24], [OBS-09]).
> **Why:** An empty table with no explanation is indistinguishable from a broken one, and it is
> the state a user sees on their first day, when they most need direction. An error without retry
> forces a full page reload, which loses everything else on the screen.

---

## 7. Toasts and layering

**[A11Y-26] MUST:** There is exactly one `<Toaster>` ([VER-02] `react-hot-toast`), mounted in
`AppProviders` outside all layout containers, positioned `fixed`, so a toast never participates in
document flow and never shifts layout. At most 3 toasts are visible; further ones queue.
> **Why:** A toast inserted into the flow pushes the page down and is a direct CLS regression
> ([PERF-21]). Nine stacked toasts cover the content the user is trying to act on, and on a phone
> they cover the whole screen.

**[A11Y-27] MUST:** Toast duration is 3 s for success and 6 s for error; an error toast is
dismissible and an error the user must act on is not a toast at all but an inline error or a
dialog. Toasts never carry the only copy of information (an id, a code) the user needs.
> **Why:** Anything longer than 6 s reads as a stuck element; anything that disappears cannot be
> re-read, copied or reported to support. A validation failure belongs on the field ([FORM-09]).

**[A11Y-28] MUST:** Stacking order comes from the four z-index tokens and nothing else:
`--z-map-controls: 10`, `--z-panel: 100`, `--z-modal: 1000`, `--z-toast: 2000`. A numeric
`z-index` literal in a component is forbidden.
> **Why:** This rule exists because of a measured failure: in the reference codebase the toast
> library's default `z-index: 9999` sat behind a modal stack that had drifted to `12601`, so form
> error toasts inside modals were invisible, and the fix applied was `99999`, which is the next
> round of the same escalation. Four ordered tokens, one order of magnitude apart, end the
> auction. Native `<dialog>` ([A11Y-05]) renders in the top layer and needs no z-index at all,
> which is a further reason to use it.

---

## 8. Map accessibility

A map canvas is a single opaque element. The rule that makes a map-heavy application usable is
not "make the canvas accessible", it is **every dataset on the map is also reachable as text**.

**[A11Y-29] MUST:** The map canvas container carries `role="application"` and an `aria-label`
naming what the map shows; the MapLibre canvas keeps its own `tabindex` so it is focusable.
> **Why:** `role="application"` tells a screen reader to pass arrow keys through to the widget
> instead of using them for its own reading cursor, which is what makes keyboard panning work at
> all. It is a strong claim, so it applies to the canvas container only, never to the page.

**[A11Y-30] MUST:** Every map control (zoom, layer toggle, basemap switch, measure, fullscreen,
locate) is a real `<button>` with a translated accessible name, in the DOM, keyboard reachable.
Controls drawn onto the canvas are forbidden.
> **Why:** A control painted into the WebGL canvas does not exist for the keyboard, the screen
> reader, or automated testing. MapLibre's own controls are real buttons; custom controls are
> React components positioned over the canvas at `--z-map-controls`.

**[A11Y-31] MUST NOT:** Disable MapLibre's keyboard handler (`keyboard: false`) or remove the
canvas from the tab order.
> **Why:** It is the only way to pan and zoom without a mouse: arrows pan, `+`/`-` zoom,
> Shift+arrows rotate. Turning it off to "stop the page scrolling" is fixing the wrong problem.

**[A11Y-32] MUST:** Every dataset rendered on the map has a non-visual path to the same data: a
list or table view of the visible features, reachable from the map page, with the same filters
applied and the same actions available.
> **Why:** This is the load-bearing rule of the section. No amount of ARIA makes 4,000 GPU-drawn
> circles perceivable. A table of the same features is usable by a screen reader, by keyboard, on
> a slow connection, and by a sighted user who wants to sort by capacity. It is also what makes
> the page testable ([TEST-23] forbids asserting on rendered pixels).

**[A11Y-33] MUST:** A feature selected from the list opens the same popup or detail panel as a
click on the map, focus moves into it, and Escape closes it and returns focus to the list row
([A11Y-08], [MAP-36]).
> **Why:** Otherwise the list is a read-only shadow of the map rather than an equivalent path.

**[A11Y-34] MUST NOT:** Encode a category, status or magnitude on the map by colour alone. Layer
categories are additionally distinguished by icon, shape or pattern, and the legend states the
mapping in text.
> **Why:** Roughly 8 % of men have a colour-vision deficiency, and the red/green pair used for
> "over capacity" and "available" is exactly the one they cannot separate. On a printed or
> projected map at a council meeting the distinction disappears for everyone.

**[A11Y-35] MUST:** Map state changes that matter announce themselves in a visually hidden
`role="status"` region: the number of features in view after a filter, the active basemap, a
"loading tiles" state that lasts over 1 s.
> **Why:** A sighted user sees the map redraw. Without the live region, a screen-reader user
> pressing a layer toggle receives no confirmation that anything happened.

---

## 9. Responsive layout

**[A11Y-36] MUST:** Layout is mobile-first: base styles target the narrow viewport, and
Tailwind breakpoint prefixes (`sm:`, `md:`, `lg:`) add the wider layouts. Content reflows down to
**320 px** wide without loss of function.
> **Why:** 320 px is the WCAG reflow requirement and the width of the oldest phones still in the
> field. Desktop-first CSS produces a mobile layout made of overrides, which is where horizontal
> scroll comes from.

**[A11Y-37] MUST:** On viewports under `md`, a map page gives the map the full viewport, and
panels become bottom sheets (a drawer from the bottom, dismissible by swipe and by a real close
button) rather than side panels.
> **Why:** A 320 px wide side panel leaves 0 px of map. The bottom sheet is the pattern users
> already know from every native map application.

**[A11Y-38] MUST NOT:** Any page scroll horizontally. Wide content (tables, code, long ids)
scrolls inside its own `overflow-x: auto` container.
> **Why:** A body-level horizontal scrollbar makes the whole page shift under the user's thumb and
> hides the right-hand edge of every other component on the page.

**[A11Y-39] MUST:** Full-height layouts use `100dvh` (with `100vh` as a preceding fallback
declaration), not `100vh` alone.
> **Why:** On mobile Safari and Chrome `100vh` is the viewport with the URL bar hidden, so a
> "full height" map is taller than the screen and its bottom controls sit under the browser
> chrome, unreachable. `dvh` tracks the dynamic viewport.

```css
.map-shell { height: 100vh; height: 100dvh; }
```

---

## 10. Typography and language

**[A11Y-40] MUST:** Base font size is 16 px (`1rem`, never a `px` font-size on `html`), body
line-height is at least 1.5, paragraph measure is capped around 80 characters, and the layout
survives a browser zoom to 200 % and a text-only zoom to 200 %.
> **Why:** Setting `html { font-size: 14px }` breaks the user's own browser font setting for the
> entire application, which is the accessibility setting most non-expert users actually change.
> Text below 16 px also triggers automatic zoom on iOS when an input is focused, which then leaves
> the page zoomed.

**[A11Y-41] MUST:** Every self-hosted font ([PERF-19]) includes Latin Extended-A coverage for
`İ ı ş Ş ğ Ğ ç Ç ö Ö ü Ü`, and the subsetting step is verified with a rendering test.
> **Why:** A font subset to `latin` only drops `ğ`, `ş` and dotless `ı`, and the browser
> substitutes glyphs from a fallback font, so Turkish words render with mismatched letterforms
> mid-word. It is immediately visible to a Turkish reader and invisible to everyone reviewing the
> PR in English.

**[A11Y-42] MUST:** `<html lang>` matches the active locale and is updated when the user switches
language ([I18N-29]).
> **Why:** `lang` selects the screen reader's voice and pronunciation rules. A Turkish page
> declared `lang="en"` is read by an English voice, which is unintelligible. It also drives
> hyphenation and the locale-aware behaviour of `:lang()` selectors.

```ts
// src/shared/i18n/config.ts (excerpt)
i18n.on('languageChanged', (lng) => {
  document.documentElement.lang = lng
})
```

---

## 11. Testing and review

**[A11Y-43] MUST:** Component tests query the DOM the way a user perceives it: `getByRole`,
`getByLabelText`, `getByText`. `container.querySelector` and test ids are a last resort with a
comment ([TEST-02]).
> **Why:** A test written with `getByRole('button', { name: 'Kaydet' })` fails when the button
> loses its accessible name, which is exactly the regression you want a test to catch. A test id
> passes regardless.

**[A11Y-44] MUST:** Every PR that adds or changes a screen includes a keyboard-only pass: unplug
the mouse, reach every control with Tab, activate each one, open and close every overlay, and
confirm focus is visible throughout and returns correctly.
> **Why:** This finds more real defects in five minutes than any automated tool, and it is the
> only check that catches focus traps, lost focus after a delete, and controls reachable only by
> hover.

**[A11Y-45] SHOULD:** Run the browser's built-in accessibility audit (Chrome DevTools Lighthouse
accessibility category, or the Accessibility panel's contrast and tree inspection) on a new
screen before calling it done.
> **Why:** It is already installed, needs no dependency, and catches contrast and name defects
> that [A11Y-01] cannot see because they only exist after rendering. An automated axe run inside
> the test suite would be better, but see Open questions.

---

## 12. Review checklist

Twenty items, checked before a screen is called done. Skipped items are stated out loud in the
PR with the reason.

1. Lint passes with `jsx-a11y` errors, no new inline disables.
2. Every action is a `<button>`, every navigation an `<a>`/`<Link>`; no `div onClick`.
3. One `<h1>`; heading levels descend without skipping.
4. `<main>`, `<nav>` and other landmarks present; skip link reaches `#main-content`.
5. Tab reaches every control in visual order; no positive `tabIndex`.
6. Focus ring visible on every control, including custom ones and inside dialogs.
7. Overlays trap focus, close on Escape, and return focus to the opener.
8. Every icon-only button has a translated `aria-label`; decorative icons are `aria-hidden`.
9. Every input has a visible associated label; errors use `aria-describedby` + `aria-invalid`.
10. Text contrast checked at 4.5:1 (3:1 for large text and UI boundaries), in both themes.
11. No information conveyed by colour alone, on screen or on the map.
12. Interactive targets at least 44 x 44 px on touch.
13. Loading, empty, error and success all implemented; error has a message, request id and retry.
14. Skeletons reserve the final layout; no visible jump when data arrives.
15. Toasts: one `<Toaster>`, max 3, correct durations, above modals, z-index from tokens only.
16. `prefers-reduced-motion` honoured, including the map camera.
17. Layout works at 320 px and at 200 % zoom; no horizontal page scroll; `100dvh` where full height.
18. Dark theme correct for every new token; no raw hex in components.
19. Map data also reachable as a list or table with the same filters and actions.
20. Keyboard-only pass performed with the mouse unplugged.

---

## Open questions

- **Automated axe in the test suite.** `axe-core` and `@axe-core/playwright` are not in the
  version table ([02](02-TECH-VERSIONS.md)), so no rule requires them. They would catch contrast
  and ARIA defects at PR time rather than at review time, at a cost of roughly 1 to 2 s per
  component test and a new dev dependency. Decide by measuring on the reference repo: if a run
  over the ten busiest screens finds defects that [A11Y-01] and the checklist missed, add both
  packages to the table under [VER-06].
- **WCAG conformance target.** This file specifies AA-level requirements individually but does not
  claim formal WCAG 2.2 AA conformance, which needs an audit of the whole product including
  content. Revisit when a municipality asks for a conformance statement.
- **Screen-reader test matrix.** Which combination is the reference (NVDA + Firefox, VoiceOver +
  Safari, TalkBack + Chrome) is undecided; without a decision, [A11Y-44] is keyboard-only and
  screen-reader testing is ad hoc.
