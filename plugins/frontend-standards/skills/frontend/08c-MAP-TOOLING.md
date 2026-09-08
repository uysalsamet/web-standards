# 08c — Map: drawing and testing

> Two narrow topics kept out of [08-MAP-MAPLIBRE.md](08-MAP-MAPLIBRE.md) because most map
> work never touches them: letting a user draw or edit geometry, and testing map code.
>
> Read the core file first; the lifecycle and cleanup rules there apply here too.

---

## 1. Drawing and editing

**[MAP-42] MUST:** Geometry drawing and editing use `@mapbox/mapbox-gl-draw` 1.5.x
([02](02-TECH-VERSIONS.md)) wrapped once in `src/shared/map/draw/useDraw.ts`, which applies
the MapLibre class-name adapter below before the first `addControl`. Features never import
`@mapbox/mapbox-gl-draw` directly.
> **Why:** Draw locates the canvas and control containers by `mapboxgl-*` class names; on
> MapLibre they are `maplibregl-*`, so without the adapter the cursor and control buttons
> break silently. The type of `onAdd` expects a Mapbox `Map`; the cast lives in one file.

```ts
// src/shared/map/draw/useDraw.ts (excerpt)
import MapboxDraw from '@mapbox/mapbox-gl-draw'
import type { IControl } from 'maplibre-gl'
import '@mapbox/mapbox-gl-draw/dist/mapbox-gl-draw.css'

// Adapter: draw 1.5 hardcodes Mapbox class names. Set once, before any instance is created.
MapboxDraw.constants.classes.CANVAS = 'maplibregl-canvas'
MapboxDraw.constants.classes.CONTROL_BASE = 'maplibregl-ctrl'
MapboxDraw.constants.classes.CONTROL_PREFIX = 'maplibregl-ctrl-'
MapboxDraw.constants.classes.CONTROL_GROUP = 'maplibregl-ctrl-group'
MapboxDraw.constants.classes.ATTRIBUTION = 'maplibregl-ctrl-attrib'

export function createDraw(styles: object[], modes?: Record<string, unknown>): MapboxDraw & IControl {
  return new MapboxDraw({ displayControlsDefault: false, styles, modes: { ...MapboxDraw.modes, ...modes }, userProperties: true }) as MapboxDraw & IControl
}
```

**[MAP-43] MUST:** Draw styles are a project-level constant (`src/shared/map/draw/drawStyles.ts`)
using only MapLibre 5 style-spec properties (no `line-dasharray` with expressions, no
Mapbox-only `*-emissive-strength`), and the draw layers (`gl-draw-*`) are moved above
`anchor-top` after `addControl` so they render over every data layer.
> **Why:** Draw's default theme uses legacy filter syntax that MapLibre still accepts, but
> its layers are appended at the end of the style at `addControl` time; a feature layer added
> later ([MAP-07] re-add) lands above them and covers the vertices. Custom modes (e.g. a
> rectangle mode, a snap-to-vertex mode) are registered in `modes` with a test that the mode
> object has `onSetup`, `onClick`, `toDisplayFeatures`.

**[MAP-44] MUST:** Geometry leaving the draw tool is validated before it is sent to the
API: `draw.getAll()` output is parsed with the feature's zod schema, rings are closed and
right-hand-rule wound ([GIS-10]), coordinates rounded to 6 decimals ([GIS-03]), and
self-intersecting polygons are rejected with a translated message. Snapping to existing
geometry is out of scope for this standard (Open questions).
> **Why:** Draw emits whatever the user clicked: an unclosed ring, a polygon with two
> points, a hole outside its shell. PostGIS rejects invalid geometry with an error the user
> cannot act on; the browser can say "the shape crosses itself".

---

## 2. Testing maps ([TEST-14], [TEST-15])

**[MAP-67] MUST:** Layer specs and expressions are unit-tested as data: the spec object is
imported and asserted (ids follow [MAP-06], every layer has an anchor, every interactive
layer's source has `promoteId`, expressions validate with `@maplibre/maplibre-gl-style-spec`'s
`validateStyleMin` on a synthetic style). No map instance is needed.
> **Why:** A typo in a `match` expression fails at runtime with `Expected value to be of
> type string` in the console, which no one reads. `validateStyleMin` catches it in 5 ms.
> (`@maplibre/maplibre-gl-style-spec` ships as a dependency of `maplibre-gl`; import it from
> there. If it is not resolvable in the pinned build, use `maplibregl.validateStyle` and
> note the difference. Confirm on the repo.)

**[MAP-68] MUST:** Component tests mock `maplibre-gl` in jsdom with a fake `Map` that
records `addSource`/`addLayer`/`removeLayer`/`setFeatureState` calls and fires `style.load`
synchronously; assertions check the registry's calls and their order, not pixels.
`src/test/fakeMapLibre.ts` provides the fake. jsdom has no WebGL, so a real map never
constructs there.

**[MAP-69] MUST:** Every map page has a Playwright smoke test that opens the page, waits for
`[data-testid="map-canvas"][data-map-idle="true"]` ([MAP-01] container sets it on `idle`),
asserts no console errors containing `maplibre` or `Style`, and takes a screenshot compared
at a 2 % pixel tolerance against a committed baseline for the default viewport.
> **Why:** The layer that disappeared after a style switch, the icon that failed to load and
> the label font that fell back to a box glyph are all invisible to unit tests and obvious in
> a screenshot.

---
