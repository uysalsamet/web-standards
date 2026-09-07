# ADR-0009 — Marker rendering: GPU layers, with DOM markers for a handful of rich widgets

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-18], [MAP-10], [MAP-11], [MAP-12], [MAP-13], [MAP-17], [MAP-63], [PERF-23]

## Context

"Show these things on the map" is the single most common map task, and the two ways to do it
look equally reasonable in a code review of ten items:

```tsx
// DOM: one absolutely positioned element per feature, projected by MapLibre each frame
items.map((item) => new maplibregl.Marker({ element: node }).setLngLat(item.position).addTo(map))

// GPU: one source, one layer, the whole dataset
map.addSource('parking-src', { type: 'geojson', data: collection })
map.addLayer({ id: 'parking-points', type: 'circle', source: 'parking-src', paint: { ... } })
```

They diverge at scale, and the divergence is not gradual. This record fixes which one is the
default and states precisely where the other still wins, because the DOM version is the one
every developer and every AI agent reaches for first: it lets you render React inside the
marker, which is a very attractive property.

## Options

### A) GPU layers by default, DOM markers capped at a handful of rich widgets (CHOSEN)

**Strengths:**
- **Cost per frame.** A `maplibregl.Marker` is a DOM element positioned with a CSS transform,
  and MapLibre recomputes that transform for every marker on every frame of every pan, zoom
  and rotation. That is layout and composite work proportional to marker count, on the main
  thread, inside the animation loop. A `circle` or `symbol` layer uploads its geometry to the
  GPU once and redraws it in a single draw call regardless of feature count: the per-frame
  main-thread cost is approximately constant. The observed break is around 500 markers on a
  mid-range machine (visible stutter while dragging) and total collapse to roughly 10 fps at
  2,000 ([GEN-18]).
- **Memory.** 2,000 markers is 2,000 detached-then-attached DOM nodes plus 2,000 React
  component instances if they render React; the same features in a source are one typed array.
- **Collision handling.** `symbol` layers get MapLibre's label collision engine for free
  ([MAP-14]), so icons and labels declutter as you zoom. DOM markers overlap into an unreadable
  pile and there is no way to fix it short of implementing collision yourself.
- **Interaction without re-rendering.** Hover and selection are `setFeatureState` ([MAP-17]),
  which changes a paint expression's input, not the data. The DOM equivalent is re-rendering a
  React component per marker, or worse, calling `setData` with a modified copy ([MAP-18]).
- **Clustering, zoom filtering and data-driven styling** are source and style options, not
  code you write.
- **It works with tiles.** Above [GEN-19]'s threshold the data is MVT, and MVT features never
  exist as JavaScript objects at all, so a DOM marker per feature is not even possible. The
  GPU path is the only one that scales past the threshold, so choosing it early avoids a
  rewrite at exactly the moment the dataset grows.

**Weaknesses:**
- **No React inside a feature.** A GPU symbol is an icon from a sprite or an `addImage` bitmap
  ([MAP-13]) with a text label. Rich content (a live video thumbnail, a progress ring, a
  button) is not expressible. This is a genuine capability loss, not just an inconvenience.
- **Styling is expressions, not CSS.** A designer's hover state becomes a `case`/`interpolate`
  expression, which is a different skill and a worse authoring experience.
- **Debugging is harder.** A missing DOM marker is visible in the elements panel; a missing GPU
  feature requires `queryRenderedFeatures`, checking `source-layer`, `minzoom`, the filter and
  the paint opacity, in that order.
- **Icon pipeline.** Every icon must reach the sprite or `addImage`, sized for `pixelRatio`
  ([MAP-13], [GIS-30]), instead of being an `<img>` in a component.

### B) DOM markers everywhere (`maplibregl.Marker`)

**Strengths:** React inside every marker, CSS styling, familiar debugging, trivial to write,
and correct for the first two weeks of a project when there are twelve features.

**Weaknesses:** Everything in A's first bullet, in reverse. The failure is not a crash, it is
the map becoming unusable at a dataset size nobody predicted, typically after the project has
150 files written against the marker model. Converting then means rewriting interaction,
styling, clustering and selection at once. The reference project shipped DOM markers for live
trucks and hit the frame cost at a few hundred vehicles.

### C) A hybrid based on a runtime feature-count switch

**Strengths:** Uses DOM markers while the count is small (so the rich content works) and swaps
to a GPU layer above a threshold, apparently getting both.

**Weaknesses:** Two implementations of every feature: two styling systems, two interaction
paths, two selection models, two sets of tests, and a visible visual discontinuity when the
switch happens (icons change shape and position by a pixel or two). The threshold behaviour is
also unstable at the boundary: filtering a list across the threshold flips the renderer while
the user watches. The maintenance cost is paid always; the benefit applies to a narrow count
range.

### D) Canvas overlay drawn by hand

**Strengths:** Full control, one element, no per-feature DOM.

**Weaknesses:** You reimplement projection, hit testing, label collision, zoom-dependent
styling and retina handling, and it is still the CPU drawing rather than the GPU. This is
building a worse MapLibre inside MapLibre.

## Decision

**All datasets render as MapLibre sources and layers.** `maplibregl.Marker` is permitted only
for **at most 20 simultaneous** rich interactive widgets on a map ([MAP-11]): a draggable
location picker, a live video badge on a selected camera, an editable label handle. A dataset,
an API result, or "a list of anything" is never DOM markers ([MAP-12]).

Decisive reason: the per-frame cost of DOM markers is proportional to feature count and lands
on the main thread inside the animation loop, so it degrades the one interaction (panning) the
user performs constantly. The GPU path's per-frame cost does not depend on feature count. The
cap of 20 is set where the per-frame layout of that many absolutely positioned elements stays
inside the frame budget on the reference hardware while leaving room for the rest of the page.

Where DOM markers still win, and are therefore allowed: a small, bounded number of features
that need React content, real DOM interaction (a form control, a video element), or CSS
animation. That set is small by construction, which is why a hard number rather than a
judgement call.

## Accepted costs

- **Rich per-feature content is unavailable for datasets.** A layer of parking sites cannot
  show an occupancy ring per site; it shows a data-driven colour and a label, and the detail
  goes in the popup ([MAP-34]). Product sometimes wants the ring, and the answer is no.
- **A learning curve.** Style expressions, `feature-state`, `promoteId`, `source-layer` and
  the sprite pipeline are all things a developer must learn before their first layer works,
  where a DOM marker works immediately. `08` exists largely to shorten that.
- **Harder debugging**, with a documented pitfall table ([08](../08-MAP-MAPLIBRE.md) §15) as
  the mitigation.
- **Two mechanisms remain in the codebase.** The 20-marker exception means both models exist,
  and the boundary is a rule a reviewer enforces. A feature that starts with three markers and
  grows to three hundred must be converted, and nothing detects that automatically except the
  registry's development warning.
- **Icon assets need a build step** into the sprite, or an `addImage` call with a cleanup
  ([MAP-62]), rather than being imported like any other image.

## What would change this decision

- A MapLibre release that supports rendering arbitrary HTML into a GPU-composited layer with
  collision handling, which would remove the reason the exception exists.
- A measurement showing DOM markers holding 60 fps at several thousand features on the
  reference hardware, which would mean the browser's layout cost model has changed
  fundamentally.
- A deployment whose largest dataset is genuinely under a hundred features and whose product
  requirement is rich per-feature content; that application could raise the [MAP-11] cap with a
  written reason, without changing the default for everyone else.
