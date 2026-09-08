# 08b — Map: data delivery and performance

> Where map data comes from and what it costs to draw. Read this when the **data** is the
> question: how big a GeoJSON may be, when it becomes vector tiles, how terrain and raster
> layers are wired, how live datasets are updated, and which budgets keep the map at 60 fps.
>
> For the map instance, layers, events, popups and cleanup, read
> [08-MAP-MAPLIBRE.md](08-MAP-MAPLIBRE.md) first: the rules there apply to everything here.
> Geodata formats, projections and the tile-building recipe are in
> [APPENDIX-GIS-DATA.md](APPENDIX-GIS-DATA.md).

---

## 1. Data delivery ([GEN-19])

**[MAP-19] MUST:** A `geojson` source holds at most **5,000 features and 2 MB** (serialised).
Above either limit the dataset is served as vector tiles ([MAP-21]) or a PMTiles archive
([MAP-27]). The limit is enforced by `tools/check-standards.sh` for files under
`public/data/` and by a `console.warn` in the registry in development builds for runtime data.
> **Why:** GeoJSON is parsed on the main thread, then transferred to the worker and tiled
> there. 40 MB of parcels takes 6 s to parse, 300 MB of heap and blocks input for the
> duration. The same parcels as MVT stream in 40 KB tiles, only for the visible viewport.
> [ADR-0010](adr/0010-geodata-delivery.md).

**[MAP-20] MUST:** GeoJSON sources set `buffer`, `tolerance` and `maxzoom` explicitly;
point sources above 500 features that are not individually labelled set `cluster: true`.

| Option | Value | Reason |
|---|---|---|
| `buffer` | `64` (points), `128` (lines/polygons with wide strokes) | Default 128 doubles tile work for points; too small clips strokes at tile edges |
| `tolerance` | `0.375` (default) for points/lines, `0.5` for administrative polygons | Douglas-Peucker in tile pixels; 0.5 is invisible at any zoom and halves vertex count |
| `maxzoom` | `14` (default 18) | Tiles are overzoomed beyond it; 4 fewer zoom levels of tiling for no visual loss at 5,000 features |
| `cluster` | `true`, `clusterRadius: 50`, `clusterMaxZoom: 14` | Below 14 the clusters open; above it features are individual |
| `promoteId` | `'id'` | [MAP-17] |

Clusters need three layers: cluster circle (`filter: ['has', 'point_count']`), cluster count
label (`text-field: ['get', 'point_count_abbreviated']`), and unclustered points
(`filter: ['!', ['has', 'point_count']]`). Cluster click calls
`source.getClusterExpansionZoom(clusterId)` and `easeTo` there. `supercluster` directly
([02](02-TECH-VERSIONS.md)) is used only when cluster properties need custom reducers
(`clusterProperties` covers sum/max/min; use it first).

**[MAP-21] MUST:** Large datasets are `vector` sources from the tile service, referenced by
TileJSON URL built from runtime config: `url: \`${config.tileBaseUrl}/<dataset>.json\``.
Tile URL templates are never string literals in feature code.
> **Why:** TileJSON carries `bounds`, `minzoom`, `maxzoom` and `vector_layers`, so MapLibre
> requests no tiles outside the data extent and the feature does not hardcode zoom limits
> that drift from the MBTiles metadata. The base URL is deployment-specific ([GEN-09]).

```ts
// src/features/Parcel/lib/parcelLayerSpec.ts
export const parcelLayerSpec = (tileBaseUrl: string): LayerSpec => ({
  sourceId: 'parcel-src',
  source: { type: 'vector', url: `${tileBaseUrl}/parcels.json`, promoteId: { parcels: 'id' } },
  layers: [
    { anchor: 'anchor-below-labels', interactive: true, hover: true,
      spec: { id: 'parcel-fill', type: 'fill', source: 'parcel-src', 'source-layer': 'parcels', minzoom: 14,
        paint: { 'fill-color': '#6366f1', 'fill-opacity': ['case', ['boolean', ['feature-state', 'hover'], false], 0.35, 0.12] } } },
    { anchor: 'anchor-below-labels',
      spec: { id: 'parcel-line', type: 'line', source: 'parcel-src', 'source-layer': 'parcels', minzoom: 14,
        paint: { 'line-color': '#4338ca', 'line-width': ['interpolate', ['linear'], ['zoom'], 14, 0.5, 18, 2] } } },
  ],
})
```

**[MAP-22] MUST:** Every `vector` and `raster` source declared with a `tiles` array (no
TileJSON) also declares `minzoom`, `maxzoom` and `bounds` that match the archive's metadata.
Layers on top set their own `minzoom` at the zoom where the data is legible.
> **Why:** Without `maxzoom` MapLibre requests z18 tiles that do not exist (404 storms in
> the nginx log, one per tile per pan). Without `bounds` it requests tiles over the sea.
> Without a layer `minzoom`, 300,000 building footprints are requested at zoom 10 to draw
> nothing visible. MapLibre overzooms automatically: data at `maxzoom: 14` renders sharp at 18.

**[MAP-23] MUST:** Tile requests go to the same origin under `/tiles/`, proxied and cached by
nginx ([NGX-36], [NGX-37]): `proxy_cache` with `inactive=7d`, `Cache-Control: public,
max-age=86400` on `.pbf`/`.png`/`.webp`, and `no-cache` on `.json` (TileJSON, style).
> **Why:** A pan over a district requests 40 to 120 tiles. Without an edge cache every user
> hits the tile server's SQLite; with it the second user is served from disk in under 1 ms.
> TileJSON and style must stay fresh so a rebuilt archive with new `maxzoom` is picked up.

**[MAP-24] MUST:** Authentication for tile requests is cookie-based and same-origin by
default and needs no code. `transformRequest` is used only when the auth model is
header-based ([AUTH-06]): it adds the header for `resourceType === 'Tile'` and URLs under
`config.tileBaseUrl`, and nothing else. Tokens are never put in the tile URL query.
> **Why:** A token in the URL lands in the nginx access log, the proxy cache key and the
> browser history. `transformRequest` runs for every resource (glyphs, sprites, images) so
> an unfiltered header leaks the token to any third-party URL in the style.

```ts
// src/shared/map/tileTransformRequest.ts
import type { RequestTransformFunction } from 'maplibre-gl'

export function createTileTransformRequest(tileBaseUrl: string, getAccessToken: () => string | null): RequestTransformFunction {
  return (url, resourceType) => {
    if (resourceType !== 'Tile' || !url.startsWith(tileBaseUrl)) return { url }
    const token = getAccessToken()
    return token ? { url, headers: { Authorization: `Bearer ${token}` } } : { url }
  }
}
```

**[MAP-25] MUST:** `map.on('moveend')` handlers that fetch by bbox are debounced 250 ms,
send the bbox to the API ([GIS-15]), and abort the previous request with `AbortController`
(TanStack Query does this when the key includes the bbox rounded to 3 decimals).
> **Why:** A fling emits `moveend` once but a user dragging in steps emits one per step; 250
> ms collapses them into one request without feeling laggy. Rounding the bbox keeps the
> query key stable across sub-pixel moves.

**[MAP-26] MUST:** `GeoJSONSource.setData` is called only for datasets under the [MAP-19]
limit, at most **4 times per second** for live data (vehicle positions) and only with a new
object reference when the content changed ([STA-14]). The data object passed is the same
reference held in state; no cloning.
> **Why:** Each `setData` serialises the collection, posts it to the worker and re-tiles.
> At 30 Hz with 300 vehicles the worker never idles and the UI thread spends 40 % of its
> time in `postMessage`. 4 Hz with interpolation on the main thread ([MAP-63]) looks smooth.

**[MAP-27] MUST:** PMTiles archives (`pmtiles` package, `pmtiles://` protocol registered
once in `src/shared/lib/maplibreInit.ts`) are allowed for **static** datasets served from
object storage or nginx with HTTP range support, when no tile server is deployed for that
dataset. The archive URL comes from runtime config and is under the same origin.
> **Why:** A single file with range requests needs no tile server, which is right for a
> 2 GB orthophoto that changes once a year. It is wrong for data that updates daily because
> the whole archive is rebuilt and the CDN cache invalidated. nginx must not be configured
> with `proxy_buffering on` for that location or the range request is downloaded whole.

```ts
// src/shared/lib/maplibreInit.ts (excerpt)
import maplibregl from 'maplibre-gl'
import { Protocol } from 'pmtiles'
import workerUrl from 'maplibre-gl/dist/maplibre-gl-csp-worker?url'

// The CSP worker is a self-contained file Rollup never rewrites. The default blob worker
// lost a hoisted reference in production builds on the reference repo (ReferenceError on addSource).
maplibregl.setWorkerUrl(workerUrl)
maplibregl.addProtocol('pmtiles', new Protocol().tile)

export default maplibregl
```

**[MAP-28] SHOULD:** Partial updates to a GeoJSON source use `source.updateData({ add,
update, remove })` instead of `setData` when fewer than 10 % of features changed.
> **Why:** `updateData` (present since MapLibre 3.x; confirm it exists on the pinned 5.x
> build with a type check in the wrapper, and fall back to `setData` if not) sends only the
> diff to the worker. For 300 vehicles where 12 moved, that is 12 features instead of 300.
> The reference project has not measured the gain on 5.x, hence SHOULD.

---

## 2. Terrain, raster and sky

**[MAP-50] MUST:** 3D terrain uses one `raster-dem` source (`terrain-dem-src`, Mapbox
Terrain-RGB encoding, `tileSize: 256`, `maxzoom` from the DEM archive) and
`map.setTerrain({ source: 'terrain-dem-src', exaggeration })`. That source is used by
terrain only.
> **Why:** The DEM used for terrain defines the mesh. Swapping it for a different-resolution
> DEM "because the hillshade looked better" changes the vertical scale under every 3D
> building and breaks `exaggeration` tuning. The reference project made exactly this mistake
> with a 12 m DTM, measured the result, and reverted.

**[MAP-51] MUST:** Hillshade is a **separate** source from the terrain DEM: either a
pre-rendered raster (`raster` source + `raster` layer, produced with `gdaldem hillshade` into
RGBA tiles where flat ground is transparent) or a second `raster-dem` source with a
`hillshade` layer. It is added under `anchor-below-labels` and can be toggled independently
of terrain.
> **Why:** MapLibre's live `hillshade` layer decodes the DEM a second time and recomputes
> normals per frame; on an Intel iGPU it cost 8 to 15 fps in the reference project. The
> pre-baked raster costs the same as any raster overlay. Keeping it separate means the
> terrain DEM's resolution and the shading's resolution are chosen independently.

```ts
// src/shared/map/terrain/hillshadeSpec.ts
export const hillshadeSpec = (tileBaseUrl: string): LayerSpec => ({
  sourceId: 'terrain-hillshade-src',
  source: { type: 'raster', tiles: [`${tileBaseUrl}/hillshade/{z}/{x}/{y}.png`], tileSize: 256, minzoom: 9, maxzoom: 14,
            bounds: [28.4988, 40.9991, 29.0013, 41.5009] },   // from the archive metadata; MapLibre requests nothing outside
  layers: [{ anchor: 'anchor-below-labels', spec: { id: 'terrain-hillshade', type: 'raster', source: 'terrain-hillshade-src',
             paint: { 'raster-opacity': 1, 'raster-fade-duration': 0 } } }],
})
```

**[MAP-52] MUST:** Terrain is off by default on software renderers ([MAP-40]), on
integrated GPUs identified by renderer string (`intel`, `iris`, `uhd graphics`), and on
viewports narrower than 768 px. When on, an FPS guard samples frames only while
`map.isMoving()`; three consecutive 1 s windows under **24 fps** turn terrain off and show a
toast (`map.terrainDisabledForPerformance`). The guard is `src/shared/map/terrain/terrainPerfGuard.ts`.
> **Why:** Renderer-string detection is a guess; the frame rate is the truth. Measured on
> the reference hardware: discrete NVIDIA/AMD hold 100+ fps with terrain; a typical Intel
> iGPU drops to about 20 fps at the same tier, and the first impression is the one users
> remember. Sampling idle frames would always read low because MapLibre does not repaint
> when nothing moves.

**[MAP-53] MUST:** Satellite, drone orthophoto and other raster basemap variants are
`raster` sources registered once and toggled with `setLayoutProperty(id, 'visibility',
'none' | 'visible')`, not by swapping sources or calling `setStyle`.
> **Why:** Removing and re-adding a raster source throws its tile cache away; the user waits
> for every tile again on every toggle. Visibility keeps the cache and costs nothing while
> hidden.

**[MAP-54] MUST:** Sky and atmosphere use `map.setSky({...})` (MapLibre 5 style-spec `sky`)
from a theme-keyed constant in `src/shared/map/mapSky.ts`. `setFog` does not exist in
MapLibre; a call guarded by optional chaining is a silent no-op and is forbidden.
> **Why:** The reference project called `(map as any).setFog?.(spec)`, which never ran, and
> the "fog" the team saw was the style's own `sky`. A no-op behind a cast is a bug waiting
> for someone to "fix" by reading Mapbox docs.

```ts
// src/shared/map/mapSky.ts
import type { Map as MapLibreMap, SkySpecification } from 'maplibre-gl'

const SKY: Record<'light' | 'dark', SkySpecification> = {
  light: { 'sky-color': '#a8d6ff', 'horizon-color': '#e8f8ff', 'fog-color': '#d8e8f5', 'fog-ground-blend': 0.6, 'horizon-fog-blend': 0.8, 'sky-horizon-blend': 0.7, 'atmosphere-blend': ['interpolate', ['linear'], ['zoom'], 0, 1, 10, 1, 12, 0] },
  dark:  { 'sky-color': '#4a607e', 'horizon-color': '#5c7696', 'fog-color': '#788eaa', 'fog-ground-blend': 0.6, 'horizon-fog-blend': 0.8, 'sky-horizon-blend': 0.7, 'atmosphere-blend': ['interpolate', ['linear'], ['zoom'], 0, 1, 10, 1, 12, 0] },
}
export const applySky = (map: MapLibreMap, theme: 'light' | 'dark') => map.setSky(SKY[theme])
```

---

## 3. Performance

**[MAP-55] MUST:** At most **60** custom (registry-added) layers exist on the map at once,
and at most 25 of them are `symbol` layers. The registry warns at 50 in development and
throws at 60.
> **Why:** Each layer is at least one draw pass per visible tile per frame; symbol layers
> also run collision detection. Past 60 the reference project measured frame times over 16 ms
> on discrete GPUs with nothing else happening. [MAP-16] is how you stay under it.

**[MAP-56] MUST:** Toggling a layer sets `visibility`; it never removes and re-adds the
layer or source. Filtering by category sets `setFilter` on the existing layer.
> **Why:** Remove/add drops the tile cache and re-runs symbol placement. Visibility is free.

**[MAP-57] MUST:** Measurements (frame time, tile counts, layer stats) are taken after
`map.once('idle')`, never after `load`. Performance work states the device, the zoom, the
number of visible features and the frame time before and after in the PR.
> **Why:** `load` fires before tiles arrive. "It feels faster" is not a measurement
> ([07](07-PERFORMANCE.md) [PERF-03]).

**[MAP-58] MUST:** `pixelRatio` is capped at 1.5 (`Math.min(devicePixelRatio, 1.5)`) and set
to 1 on software/integrated renderers.
> **Why:** A 3x phone renders 9x the fragments of a 1x screen. 1.5 is visually
> indistinguishable from 2 for map data and halves the fragment load.

**[MAP-59] MUST:** `canvasContextAttributes.antialias` is `false` and `preserveDrawingBuffer`
is `false`. Image export toggles `preserveDrawingBuffer` by creating the map with it `true`
only on the export page, or reads pixels inside a `render` callback of the same frame.
> **Why:** MSAA costs 20 to 40 % on integrated GPUs and MapLibre already anti-aliases lines
> in the shader. `preserveDrawingBuffer: true` disables the swap-chain optimisation on every
> frame just so `toDataURL` works once. MapLibre 5 moved both into `canvasContextAttributes`;
> the top-level options are gone.

**[MAP-60] MUST:** `fadeDuration: 0` on the map and `raster-fade-duration: 0` on data
rasters.
> **Why:** The 300 ms crossfade doubles the render passes for tiles in transition and makes
> layers appear to flicker on `setData`. It exists for basemap aesthetics, not data.

**[MAP-61] SHOULD:** Leave `maplibregl.setWorkerCount` at its default. Set it explicitly
(in `maplibreInit.ts`, with the measurement in a comment) only after profiling shows tile
parsing is the bottleneck. `setMaxParallelImageRequests` stays at the default 16.
> **Why:** Workers cost memory (about 10 MB each) and the default (half the cores) already
> saturates the network for a single map. The reference set 2 without a measurement.

**[MAP-62] MUST:** Images added with `addImage` are removed when their owning spec is
removed ([MAP-38]) and are never added per feature. Image count per map stays under 200 and
every image is at most 128×128 px at `pixelRatio: 2`.
> **Why:** Images live in one sprite atlas texture; when it overflows, MapLibre allocates a
> larger atlas and re-uploads everything. 500 unique 256 px icons is 32 MB of texture.

---

## 4. Large and animated data

**[MAP-63] MUST:** Live vehicle positions are one `geojson` source updated at ≤ 4 Hz from
the MQTT batch ([RT-10]) with interpolation between updates done on the main thread in a
`requestAnimationFrame` loop that lerps positions held in a `useRef`, not in React state,
and writes the interpolated collection with `setData` once per frame (or every second frame
above 200 vehicles).
> **Why:** Positions in React state would re-render the layer component 60 times per
> second for no DOM change. A ref plus rAF costs one `setData` per frame, which for 300
> features is under 2 ms in the worker.

```ts
// src/features/WasteTruck/hooks/useVehicleInterpolation.ts (excerpt)
interface Track { from: [number, number]; to: [number, number]; bearing: number; t0: number; t1: number }

export function useVehicleInterpolation(sourceId: string, latest: ReadonlyMap<string, VehiclePosition>) {
  const { map } = useMap()
  const tracks = useRef(new Map<string, Track>())

  useEffect(() => {
    const now = performance.now()
    for (const [id, p] of latest) {
      const prev = tracks.current.get(id)
      const from = prev ? lerpTrack(prev, now) : p.lngLat
      tracks.current.set(id, { from, to: p.lngLat, bearing: p.bearing, t0: now, t1: now + POSITION_INTERVAL_MS })
    }
  }, [latest])

  useEffect(() => {
    let raf = 0
    const tick = () => {
      const src = map.getSource(sourceId)
      if (src?.type === 'geojson') src.setData(toFeatureCollection(tracks.current, performance.now()))
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [map, sourceId])
}
```

**[MAP-64] MUST:** Vehicle glyphs are a `symbol` layer with `icon-rotate: ['get', 'bearing']`,
`icon-rotation-alignment: 'map'`, `icon-allow-overlap: true` (documented exception, count is
bounded by the fleet size), and a `text-field` label that appears at zoom ≥ 14.
> **Why:** Rotation by expression is free; rotating DOM markers with CSS transforms is a
> layout per marker per frame.

**[MAP-65] MUST:** Heatmaps use the `heatmap` layer type with `heatmap-weight` from a
property, `heatmap-radius` interpolated by zoom and a `maxzoom` after which the point layer
takes over. Heatmap input stays under the [MAP-19] limit or comes from tiles.
> **Why:** A heatmap of 50,000 points is a tile job, not a GeoJSON job, like everything else.

**[MAP-66] MUST:** deck.gl and other WebGL overlay frameworks are not in the version table
and are not added for a feature. They become justified only above **200,000 dynamic points**
or when a custom shader is genuinely required (particle flow fields, volumetric data), and
then through an ADR that names the layer types used and the bundle cost (deck.gl core is
about 250 KB gzipped). A custom `CustomLayerInterface` layer written against MapLibre's
own GL context is the first thing to try; the reference project's wind particle layer is
1,200 particles in one custom layer with no framework.
> **Why:** Two rendering engines on one canvas means two coordinate systems, two picking
> models and two upgrade cycles.

---
