# ADR-0008 — Map library: MapLibre GL 5

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-18], [GEN-19], [GEN-20], [VER-05], [MAP-01]..[MAP-69], [GIS-24]..[GIS-32]

## Context

The reference deployments are municipal GIS applications: a basemap, ten to thirty toggleable
data layers, cadastral parcels and building footprints in the hundreds of thousands, satellite
and drone orthophoto rasters, 3D terrain over a district, live vehicle positions at 4 Hz, and
drawing tools for zoning geometry. The map is the application, not a widget on a page.

The library choice therefore fixes: the rendering model (GPU or DOM), the data formats we can
serve, whether the deployment needs a commercial account, the styling language, and what
"toggle a layer" costs in frames.

The choice must also be made once for the organisation ([GEN-01]): two map libraries means two
sets of layer-lifecycle bugs, two styling languages and two bodies of agent-generated code.

## Options

### A) MapLibre GL JS 5 (CHOSEN)

**Strengths:**
- WebGL 2 rendering of vector tiles: 100,000 polygons in a `fill` layer cost the GPU, not the
  DOM, which is the whole basis of [GEN-18].
- BSD-3-Clause, no account, no token, no per-view billing, no telemetry callback to a vendor.
  For a public-sector deployment behind a municipal firewall this is not a preference, it is a
  requirement: the app must work with no outbound internet at all.
- Style specification is declarative JSON with data-driven expressions, so category colouring,
  zoom-dependent widths and hover styling are style data ([MAP-16]) rather than per-feature
  JavaScript. That data is unit-testable ([TEST-22]).
- `feature-state` gives hover and selection with no data mutation ([MAP-17]), which is what
  keeps a 50,000-feature layer interactive.
- Native support for the formats we already produce: MVT from `tippecanoe`, raster tiles from
  GDAL, PMTiles via a protocol handler, `raster-dem` terrain, hillshade, sky.
- Self-hosted glyphs and sprites, which is what makes Turkish label coverage our problem to
  solve rather than a vendor's ([GIS-31]).
- Active governance under the Linux Foundation with multiple corporate contributors, so the
  bus factor is not one company's product strategy.

**Weaknesses:**
- WebGL 2 is required. A locked-down municipal desktop with a blacklisted GPU driver falls
  back to software rendering (SwiftShader) at roughly 5 fps, so the app needs a capability
  check and a degraded path ([MAP-40], [MAP-52]). This is a real support burden.
- The imperative API is hostile to React's lifecycle: sources and layers must be added after
  `style.load`, removed in the right order, and re-added after `setStyle`. `08` needs seven
  rules and a registry to make this safe, and every one of those rules exists because the
  reference project hit the bug.
- Styling MapLibre's own DOM (popups, controls, attribution) is CSS against fixed class names,
  outside Tailwind's model ([ADR-0007](0007-styling.md)).
- The plugin ecosystem is smaller than Leaflet's. Where a Leaflet plugin exists for something
  niche, we write it.
- **MapLibre 6 is already released** ([02](../02-TECH-VERSIONS.md) lists 6.7 as latest) with
  style-spec and API changes. We are pinned to 5.x, so we are carrying a known, growing
  upgrade debt with a checklist ([08](../08-MAP-MAPLIBRE.md) §14) that has not yet passed on
  the reference repo. Terrain, `feature-state` on clustered sources and the draw adapter are
  the open items.

### B) Mapbox GL JS v3

**Strengths:** The upstream this forked from, ahead on 3D (standard style, lighting, model
layers), globe projection, better out-of-the-box basemap design, first-party support.

**Weaknesses:** Proprietary licence since v2, a required access token, and billing per map
load. Both are disqualifying here: the token is a secret we cannot keep ([GEN-10]), the
billing is a per-citizen cost on a public portal, and the deployment must run air-gapped. The
licence also forbids reverse-proxying their tiles, which is how our tile serving works
([MAP-23]). Forbidden in [VER-05].

### C) Leaflet (+ react-leaflet)

**Strengths:** Small, simple, enormous plugin ecosystem, trivial for a handful of markers, no
WebGL requirement so it works on any machine.

**Weaknesses:** It renders to DOM and SVG. A few hundred features is fine; 5,000 parcels is
5,000 SVG paths that the browser re-lays-out on every pan, and the map drops to single-digit
frames. It has no vector tile support without a plugin, no `feature-state` equivalent, no
terrain, no data-driven styling language. Every constraint in `08` that makes large data
possible has no Leaflet counterpart. Forbidden in [VER-05], and [ADR-0009](0009-marker-rendering.md)
covers the DOM-rendering argument in detail.

### D) OpenLayers 10

**Strengths:** The most complete GIS feature set of any web library: real projection support
(reproject on the fly, non-Mercator grids, WMS/WMTS/WFS out of the box), which matters for
Turkish national grids ([GIS-08]). Canvas and WebGL renderers. BSD licence.

**Weaknesses:** WebGL rendering covers only part of the layer types; much of the power is on
the canvas renderer, where large vector data has the same cost problem as Leaflet in a
different shape. The API is large and imperative in its own idiom, with a much smaller React
community and noticeably worse AI-agent output quality. No terrain. Its projection strength is
an advantage we deliberately do not need, because [GIS-07] and [GIS-08] put reprojection in
PostGIS at ingest, where the datum grids live.

### E) deck.gl alone (no basemap library)

**Strengths:** The best large-data GPU rendering available in a browser: millions of points,
GPU aggregation, proper 3D layers.

**Weaknesses:** It is a rendering framework, not a map: no basemap, no style specification, no
glyph or sprite handling, no built-in tile schema, no controls, no popups. Its normal use is
*on top of* MapLibre, not instead of it, which is what [MAP-66] leaves as a possible future
overlay rather than a base decision. Choosing it alone means writing a basemap layer, a label
engine and an interaction model.

## Decision

**MapLibre GL JS 5.x**, consumed directly (no React wrapper, [VER-05]) through the map module
in `src/shared/map/`.

Decisive reasons: the licence and token model are the only ones compatible with an offline
public-sector deployment; the GPU rendering model is the only one of the free options that
handles our data volumes; and the declarative style specification makes styling reviewable
data rather than imperative code.

## Accepted costs

- **A known upgrade debt.** MapLibre 6 exists and we are on 5. The longer the gap, the larger
  the eventual migration, and the checklist gating it is not passing yet. This is a scheduled
  cost, not an avoided one.
- **Lifecycle complexity.** Roughly a third of `08`'s rules exist to make an imperative WebGL
  object safe inside React's mount/unmount/remount. That is complexity a Leaflet app does not
  have, paid for a performance property a Leaflet app cannot have.
- **A WebGL 2 hard requirement**, with a capability check, a software-renderer detection path,
  a terrain FPS guard and a context-lost overlay ([MAP-40], [MAP-41], [MAP-52]) as permanent
  supporting code.
- **We own the basemap.** No vendor style means we run a tile service, build the style JSON,
  host glyphs and sprites, and keep them versioned ([GIS-29]..[GIS-32]). That is
  infrastructure the Mapbox option would have rented.
- **A smaller plugin ecosystem.** Snapping in the draw tool is currently an open question in
  `08` precisely because the community plugin is unmaintained.

## What would change this decision

- The MapLibre 6 checklist ([08](../08-MAP-MAPLIBRE.md) §14) passing, which does not change
  the library but does close the debt above; or that checklist failing permanently on terrain
  or the draw adapter, which would force a re-evaluation of the drawing stack rather than the
  map.
- A deployment requirement for a projection MapLibre cannot render (a non-Mercator national
  grid required for display, not just for storage), which would put OpenLayers back on the
  table for that application.
- Feature volumes where MapLibre's own tiling stops being enough (tens of millions of points
  with client-side aggregation), which would add deck.gl as an overlay ([MAP-66]) rather than
  replace MapLibre.
- MapLibre's governance collapsing to a single vendor, or a licence change on a dependency
  that reintroduces a token requirement.
