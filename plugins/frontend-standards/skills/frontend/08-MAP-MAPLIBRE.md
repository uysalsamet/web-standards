# 08 — Map: MapLibre core

> The map instance, how features put things on it, and how they take them off again.
> This is the file you read to **add something to the map**: a layer, a popup, a click
> handler. Everything here applies to every map feature.
>
> Two sibling files carry the rest, so a task that only adds a layer does not have to read
> them:
> - [08b-MAP-DATA.md](08b-MAP-DATA.md) — where the data comes from: GeoJSON limits, vector
>   tiles, terrain and raster, large and animated datasets, map performance budgets.
> - [08c-MAP-TOOLING.md](08c-MAP-TOOLING.md) — drawing and editing, and how map code is tested.
>
> Rule ids are continuous across the three files: `MAP-01` to `MAP-69` are unique wherever
> they live, and every other document cites them by id. `node tools/check-refs.mjs .`
> fails if one goes missing.

---

## 1. Scope and vocabulary

In scope: MapLibre GL JS 5.x ([02](02-TECH-VERSIONS.md) §2) in a React 19 SPA. Out of
scope: geodata hygiene, coordinate order, projections and the tile-building recipe
([APPENDIX-GIS-DATA.md](APPENDIX-GIS-DATA.md)); MQTT and worker plumbing that feeds live
layers ([20](20-REALTIME-MEDIA.md)); nginx tile proxy and cache config ([12](12-NGINX.md) §6);
the tile service itself (backend standard).

Vocabulary used below:

| Term | Meaning |
|---|---|
| **map module** | `src/shared/map/`: `MapContainer`, `MapContext`, `useMap`, `useMapReady`, `layerRegistry`, `useMapLayer`, `usePopup`, `mapInteractions` |
| **layer spec** | A plain object describing one source, its layers, its images and which anchor they sit under. Data, not code |
| **anchor** | One of three empty, invisible layers in the style that fix z-order groups: `anchor-below-labels`, `anchor-above-labels`, `anchor-top` |
| **registry** | The per-map object that remembers every spec a feature added, so it can re-add after `setStyle` and remove on unmount |
| **ready** | `style.load` has fired **and** `map.isStyleLoaded()` returns true. Nothing is added before ready |

---

## 2. Instance ownership

**[MAP-01] MUST:** Exactly one `maplibregl.Map` per page, constructed only inside
`src/shared/map/MapContainer.tsx`. No file under `src/features/**` or `src/app/**` calls
`new maplibregl.Map(...)`.
> **Why:** Two maps on one page double the GPU memory, the worker pool and the tile
> requests, and every "the layer is missing" bug traces back to a feature adding to the
> wrong instance. The reference codebase had pages constructing their own map to bypass
> shared init and paid for it with a worker-URL bug that only reproduced in production
> builds. Detail: [03](03-PROJECT-STRUCTURE.md) [STR-23].

**[MAP-02] MUST:** The instance is exposed through `MapContext` and consumed with
`useMap()`, which throws when called outside a `MapContainer`. Features never receive the
map as a prop and never store it in Redux.
> **Why:** A `map` prop drilled through five components is a second, undocumented context.
> Storing a non-serialisable `Map` in Redux breaks devtools and the serialisability check.

```tsx
// src/shared/map/MapContext.tsx
import { createContext, useContext } from 'react'
import type { Map as MapLibreMap } from 'maplibre-gl'

import type { LayerRegistry } from './layerRegistry'

export interface MapContextValue {
  map: MapLibreMap
  registry: LayerRegistry
}

export const MapContext = createContext<MapContextValue | null>(null)

export function useMap(): MapContextValue {
  const value = useContext(MapContext)
  if (!value) throw new Error('useMap() called outside <MapContainer>')
  return value
}
```

**[MAP-03] MUST:** `useMapReady()` returns `true` only after the map has fired `style.load`
**and** `map.isStyleLoaded()` is true, and returns to `false` while a style switch is in
progress. Every effect that touches sources or layers starts with `if (!ready) return`.
> **Why:** `map.on('load')` fires once; after `setStyle` the style is empty again while
> `load` stays true. `isStyleLoaded()` alone is false during the first frames of a diffed
> style update. Only the combination is safe. The most common MapLibre crash in the
> reference project was `Style is not done loading` from an `addSource` racing a theme switch.

```ts
// src/shared/map/useMapReady.ts
import { useSyncExternalStore } from 'react'

import { useMap } from './MapContext'

export function useMapReady(): boolean {
  const { map } = useMap()
  return useSyncExternalStore(
    (notify) => {
      // style.load: style switched; styledata: a diffed update or a source added. Both change isStyleLoaded().
      map.on('style.load', notify)
      map.on('styledata', notify)
      return () => {
        map.off('style.load', notify)
        map.off('styledata', notify)
      }
    },
    () => map.isStyleLoaded(),
    () => false,
  )
}
```

**[MAP-04] MUST:** Every source, layer and image a feature adds goes through the layer
registry (`src/shared/map/layerRegistry.ts`). Direct `map.addLayer`/`map.addSource`/
`map.addImage` calls outside `src/shared/map/` are a lint error (`no-restricted-syntax`).
> **Why:** The registry is the only thing that knows what to re-add after `setStyle`
> ([MAP-07]), what to remove on unmount ([MAP-38]) and which layers are interactive
> ([MAP-29]). A layer added behind its back is a layer that disappears on theme switch.

**[MAP-05] MUST:** Z-order is expressed only through the three anchors. A layer spec names
its anchor; the registry passes it as `beforeId`. Feature code never calls `moveLayer` and
never passes a base-style layer id as `beforeId`.
> **Why:** Base-style layer ids (`waterway-label`, `building`) differ between the light,
> dark and satellite styles. A `beforeId` that exists in one style throws in another.
> Anchors are created by the registry after every `style.load`, so they exist in all styles.

| Anchor | Sits | Use for |
|---|---|---|
| `anchor-below-labels` | before the first `symbol` layer of the base style | fills, lines, extrusions, heatmaps, rasters that must not cover street names |
| `anchor-above-labels` | after the last base-style layer | points, icons and data labels |
| `anchor-top` | last | selection highlight, draw tools, measurement, drag handles |

Within one anchor, later `add()` calls render above earlier ones (mount order).

**[MAP-06] MUST:** Source, layer and image ids follow `<feature>-<kind>[-<variant>]`,
kebab-case, defined as `UPPER_SNAKE` constants in the feature's `lib/<name>LayerSpec.ts`
and listed in the feature `README.md` ([STR-06]). `<feature>` is the feature folder name in
kebab-case; `<kind>` is one of `src`, `fill`, `line`, `points`, `icon`, `label`,
`extrusion`, `heat`, `raster`, `img`.
> **Why:** Ids are global on the map. Two features both naming a source `points` collide
> silently: the second `addSource` throws and the feature renders nothing. Prefixing with the
> feature name makes the registry's ownership check trivial. Table: [03](03-PROJECT-STRUCTURE.md) §4.

```
parking-src              parking-fill         parking-fill-selected
parking-marker-src       parking-points       parking-label
waste-truck-src          waste-truck-icon     waste-truck-img-arrow
```

**[MAP-07] MUST:** Switching the base style (light/dark/satellite) is done by
`map.setStyle(url)` inside the map module; on the following `style.load` the registry
re-creates the anchors and re-adds every registered spec in registration order. Features do
nothing on style switch.
> **Why:** MapLibre rebuilds the style on `setStyle`. Custom sources, layers, images and
> `feature-state` are gone afterwards; with `diff: true` some survive and some do not
> depending on whether the diff succeeded, which is not something a feature can reason
> about. Treating every `setStyle` as "everything is gone" is the only deterministic model.

```ts
// src/shared/map/layerRegistry.ts
import type { LayerSpecification, Map as MapLibreMap, SourceSpecification } from 'maplibre-gl'

export const ANCHOR_IDS = ['anchor-below-labels', 'anchor-above-labels', 'anchor-top'] as const
export type AnchorId = (typeof ANCHOR_IDS)[number]
const ANCHOR_SOURCE_ID = 'anchors'
const EMPTY_FC: GeoJSON.FeatureCollection = { type: 'FeatureCollection', features: [] }

export interface ImageSpec {
  id: string
  load: () => Promise<HTMLImageElement | ImageBitmap>
  /** SDF images are recolourable with icon-color; use for single-colour pictograms. */
  sdf?: boolean
  pixelRatio?: number
}

export interface LayerSpec {
  sourceId: string
  source: SourceSpecification
  /** Paint order = array order. `interactive` layers take part in click/hover dispatch. */
  layers: ReadonlyArray<{ spec: LayerSpecification; anchor: AnchorId; interactive?: boolean; hover?: boolean }>
  images?: ReadonlyArray<ImageSpec>
}

export interface LayerRegistry {
  add(spec: LayerSpec): Promise<void>
  remove(sourceId: string): void
  has(sourceId: string): boolean
  /** Interactive layer ids in paint order, topmost last. Consumed by mapInteractions. */
  interactiveLayerIds(): string[]
  hoverEnabled(layerId: string): boolean
  readdAll(): Promise<void>
  dispose(): void
}

export function createLayerRegistry(map: MapLibreMap): LayerRegistry {
  const specs = new Map<string, LayerSpec>()
  let disposed = false
  map.once('remove', () => { disposed = true })

  // After map.remove() `map.style` is undefined and every style method throws.
  const alive = () => !disposed && map.getStyle() !== undefined

  function ensureAnchors(): void {
    if (map.getLayer('anchor-top')) return
    if (!map.getSource(ANCHOR_SOURCE_ID)) map.addSource(ANCHOR_SOURCE_ID, { type: 'geojson', data: EMPTY_FC })
    const firstSymbol = map.getStyle().layers.find((l) => l.type === 'symbol')?.id
    const anchor = (id: AnchorId): LayerSpecification =>
      ({ id, type: 'circle', source: ANCHOR_SOURCE_ID, layout: { visibility: 'none' } })
    map.addLayer(anchor('anchor-below-labels'), firstSymbol)
    map.addLayer(anchor('anchor-above-labels'))
    map.addLayer(anchor('anchor-top'))
  }

  async function addImages(images: ReadonlyArray<ImageSpec>): Promise<void> {
    for (const img of images) {
      if (map.hasImage(img.id)) continue
      const bitmap = await img.load()
      // The style may have switched while the image was loading.
      if (alive() && !map.hasImage(img.id)) map.addImage(img.id, bitmap, { sdf: img.sdf ?? false, pixelRatio: img.pixelRatio ?? 1 })
    }
  }

  async function paint(spec: LayerSpec): Promise<void> {
    if (!alive() || !map.isStyleLoaded()) return
    ensureAnchors()
    if (spec.images) await addImages(spec.images)
    if (!alive()) return
    if (!map.getSource(spec.sourceId)) map.addSource(spec.sourceId, spec.source)
    for (const { spec: layer, anchor } of spec.layers) {
      if (!map.getLayer(layer.id)) map.addLayer(layer, anchor)
    }
  }

  return {
    async add(spec) {
      if (specs.has(spec.sourceId)) throw new Error(`layer spec '${spec.sourceId}' already registered`)
      specs.set(spec.sourceId, spec)
      await paint(spec)
    },
    remove(sourceId) {
      const spec = specs.get(sourceId)
      specs.delete(sourceId)
      if (!spec || !alive()) return
      // Order matters: layers reference the source; images may be shared, removed last.
      for (const { spec: layer } of [...spec.layers].reverse()) if (map.getLayer(layer.id)) map.removeLayer(layer.id)
      if (map.getSource(sourceId)) map.removeSource(sourceId)
      for (const img of spec.images ?? []) if (map.hasImage(img.id)) map.removeImage(img.id)
    },
    has: (id) => specs.has(id),
    interactiveLayerIds: () =>
      [...specs.values()].flatMap((s) => s.layers.filter((l) => l.interactive).map((l) => l.spec.id)),
    hoverEnabled: (layerId) =>
      [...specs.values()].some((s) => s.layers.some((l) => l.spec.id === layerId && l.hover)),
    async readdAll() {
      for (const spec of specs.values()) await paint(spec)
    },
    dispose() {
      disposed = true
      specs.clear()
    },
  }
}
```

```tsx
// src/shared/map/MapContainer.tsx (the only place a Map is constructed)
import { useEffect, useRef, useState, type ReactNode } from 'react'

import maplibregl from '@/shared/lib/maplibreInit'

import { MapContext, type MapContextValue } from './MapContext'
import { createLayerRegistry } from './layerRegistry'
import { attachInteractions } from './mapInteractions'
import { checkWebGl2 } from './webglCapability'
import { WebGlUnavailable, ContextLostOverlay } from './MapFallbacks'

interface MapContainerProps {
  styleUrl: string                                   // from runtime config, per theme
  initialCenter: [number, number]
  initialZoom: number
  maxBounds?: [[number, number], [number, number]]
  transformRequest?: maplibregl.RequestTransformFunction
  children?: ReactNode                               // layer components and map UI
}

export function MapContainer({ styleUrl, initialCenter, initialZoom, maxBounds, transformRequest, children }: MapContainerProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const [value, setValue] = useState<MapContextValue | null>(null)
  const [contextLost, setContextLost] = useState(false)
  const gl = checkWebGl2()

  useEffect(() => {
    const el = containerRef.current
    if (!gl.ok || !el) return
    const map = new maplibregl.Map({
      container: el,
      style: styleUrl,
      center: initialCenter,
      zoom: initialZoom,
      maxBounds,
      fadeDuration: 0,                                          // [MAP-60]
      pixelRatio: Math.min(window.devicePixelRatio, 1.5),       // [MAP-58]
      canvasContextAttributes: { antialias: false, preserveDrawingBuffer: false }, // [MAP-59]
      transformRequest,
      attributionControl: { compact: true },
    })
    const registry = createLayerRegistry(map)
    const detachInteractions = attachInteractions(map, registry)

    // Every style.load (initial and after setStyle) rebuilds anchors and re-adds specs. [MAP-07]
    const onStyleLoad = () => { void registry.readdAll() }
    map.on('style.load', onStyleLoad)
    map.on('webglcontextlost', () => setContextLost(true))          // [MAP-41]
    map.on('webglcontextrestored', () => { setContextLost(false); map.setStyle(styleUrl) })
    map.on('idle', () => el.setAttribute('data-map-idle', 'true'))   // [MAP-68]
    map.on('render', () => el.removeAttribute('data-map-idle'))

    setValue({ map, registry })
    return () => {
      setValue(null)
      detachInteractions()
      registry.dispose()
      map.remove()                                                  // StrictMode: second run gets a fresh Map
    }
    // Initial view is read once; later view changes go through the URL ([MAP-45]).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [gl.ok, transformRequest])

  useEffect(() => { value?.map.setStyle(styleUrl) }, [value, styleUrl])

  if (!gl.ok) return <WebGlUnavailable reason={gl.reason} />
  return (
    <div className="relative h-full w-full">
      <div ref={containerRef} className="h-full w-full" data-testid="map-canvas" />
      {contextLost && <ContextLostOverlay />}
      {value && <MapContext.Provider value={value}>{children}</MapContext.Provider>}
    </div>
  )
}
```

**[MAP-08] MUST NOT:** Patching `maplibregl.Map.prototype` (wrapping `getLayer`,
`removeSource`, `setFeatureState` and friends to swallow errors) or any other
monkey-patching of the library.
> **Why:** The reference project wrapped fourteen prototype methods to return `undefined`
> when `this.style` was gone. It hid the real bug (effects running after `map.remove()`),
> broke TypeScript's view of return types and turned every genuine MapLibre error into a
> silent no-op. The registry's `alive()` guard and [MAP-38] solve the same problem at the
> call site. Global init that is legitimately needed (worker URL, worker count) lives in
> `src/shared/lib/maplibreInit.ts` and only calls public static setters.

**[MAP-09] MUST:** Layer components (`<Name>Layer`) are mounted by the **page** that needs
them as children of `<MapContainer>`. `MapContainer` imports no feature and contains no
route or pathname checks.
> **Why:** The reference `MapContainer` imported 40 feature layers and switched on
> `location.pathname` with 40 booleans. Every feature became part of the map chunk, lazy
> loading was impossible, and adding a page meant editing shared code. `shared` must not
> import `features` ([STR-10]).

```tsx
// src/features/Parking/pages/ParkingMapPage.tsx
export function ParkingMapPage() {
  const config = useRuntimeConfig()
  return (
    <MapContainer styleUrl={config.mapStyleUrl} initialCenter={DISTRICT_CENTER} initialZoom={12} maxBounds={DISTRICT_BOUNDS}>
      <ParkingLayer />
      <ParkingPopup />
      <LayerToggles />
    </MapContainer>
  )
}
```

---

## 3. Rendering strategy ([GEN-18])

**[MAP-10] MUST:** Data is drawn with MapLibre layers: `circle`, `symbol`, `line`, `fill`,
`fill-extrusion`, `heatmap`, `raster`, `hillshade`. A point dataset is a `circle` or
`symbol` layer over a source, never a loop that creates DOM nodes.
> **Why:** Layers are one draw call per tile per layer, batched on the GPU. DOM nodes are
> re-positioned by JavaScript on every frame of every pan. Measured on the reference
> hardware (Intel iGPU laptop): 2,000 `Marker`s pan at 9 to 12 fps; the same points as a
> `circle` layer pan at 60 fps. [ADR-0009](adr/0009-marker-rendering.md).

**[MAP-11] MUST:** `maplibregl.Marker` is allowed only for at most **20** simultaneous
rich interactive widgets from this list: a draggable location picker, a live video badge
with an embedded player, the user's own location puck, a measurement label with buttons,
the vertex handle of a geometry editor. Each use is named in the feature README.
> **Why:** These are widgets that need real DOM (focusable buttons, a `<video>`), and
> twenty absolutely-positioned elements are within the per-frame layout budget (< 2 ms
> measured). Anything that scales with data size is not a widget.

**[MAP-12] MUST NOT:** A dataset, a query result, a list of anything from an API,
rendered as `Marker`s. Not "for now", not "there are only 50". If the count is decided by
data, it is a layer.
> **Why:** Fifty becomes five hundred when the next municipality is onboarded, and the
> rewrite from markers to layers touches popups, hover, selection and tests. Starting with a
> layer costs nothing extra.

**[MAP-13] MUST:** Icons are added with `map.addImage` through the registry's `images`
list, loaded from the style sprite or from an SVG/PNG imported by Vite. Single-colour
pictograms are added with `sdf: true` and coloured with `icon-color` per feature; multi-colour
icons are raster at `pixelRatio: 2`.
> **Why:** One SDF image recoloured by expression replaces N images for N categories, which
> replaces N layers. Raster icons at `pixelRatio: 1` are blurry on every retina display the
> municipality's staff actually use.

```ts
// src/features/Parking/lib/parkingLayerSpec.ts
import type { LayerSpec } from '@/shared/map/layerRegistry'
import pinUrl from '../assets/pin.svg'   // Vite hashes it; 24x24 black on transparent, SDF-friendly

export const PARKING_SRC = 'parking-src'
export const PARKING_POINTS = 'parking-points'
export const PARKING_ICON = 'parking-icon'
export const PARKING_LABEL = 'parking-label'
export const PARKING_IMG_PIN = 'parking-img-pin'

const loadSvg = (url: string, size: number) => () =>
  new Promise<HTMLImageElement>((resolve, reject) => {
    const img = new Image(size, size)
    img.onload = () => resolve(img)
    img.onerror = () => reject(new Error(`icon failed to load: ${url}`))
    img.src = url
  })

export const parkingLayerSpec: LayerSpec = {
  sourceId: PARKING_SRC,
  source: { type: 'geojson', data: { type: 'FeatureCollection', features: [] }, promoteId: 'id', buffer: 64, tolerance: 0.375, maxzoom: 14 },
  images: [{ id: PARKING_IMG_PIN, load: loadSvg(pinUrl, 48), sdf: true, pixelRatio: 2 }],
  layers: [
    {
      anchor: 'anchor-above-labels', interactive: true, hover: true,
      spec: {
        id: PARKING_ICON, type: 'symbol', source: PARKING_SRC,
        layout: {
          'icon-image': PARKING_IMG_PIN, 'icon-size': 0.75, 'icon-anchor': 'bottom',
          'icon-allow-overlap': ['step', ['zoom'], false, 15, true],          // [MAP-14]
          'symbol-sort-key': ['case', ['boolean', ['feature-state', 'selected'], false], 0, 1],
        },
        paint: {
          'icon-color': ['case',
            ['boolean', ['feature-state', 'selected'], false], '#f59e0b',
            ['boolean', ['feature-state', 'hover'], false], '#fbbf24',
            ['match', ['get', 'parking_type'], 'municipal', '#e11d48', 'district', '#6366f1', '#64748b']],
        },
      },
    },
    {
      anchor: 'anchor-above-labels',
      spec: {
        id: PARKING_LABEL, type: 'symbol', source: PARKING_SRC, minzoom: 15,
        layout: { 'text-field': ['get', 'name'], 'text-font': ['Noto Sans Regular'], 'text-size': 12, 'text-offset': [0, 0.8], 'text-anchor': 'top' },
        paint: { 'text-halo-color': '#fff', 'text-halo-width': 1.2 },
      },
    },
  ],
}
```

**[MAP-14] MUST:** `icon-allow-overlap` and `text-allow-overlap` default to `false` and
are switched to `true` only by a `step` on zoom (at or above zoom 15) or for layers with a
documented maximum of 200 features. `symbol-sort-key` puts selected features first (lowest
value) so they win collisions.
> **Why:** With overlap allowed, 5,000 icons at zoom 11 draw as a solid blob and the
> collision index is bypassed, so `queryRenderedFeatures` returns dozens of hits per click.
> With overlap forbidden but no sort key, the selected feature is the one that gets hidden.

**[MAP-15] MUST:** Text is rendered from glyph PBFs served by our tile service
(`glyphs: "/tiles/fonts/{fontstack}/{range}.pbf"` in the style), from a self-hosted font
with Latin Extended-A coverage (`ı İ ğ Ğ ş Ş ç Ç ö Ö ü Ü`). `text-transform: uppercase` is
not used for Turkish text; uppercase variants are produced in the data with the `tr-TR`
locale.
> **Why:** Glyph ranges from a third-party CDN violate [GEN-22] and disappear when the CDN
> changes its terms. MapLibre's `text-transform` and the `upcase` expression are
> locale-insensitive: `istanbul` becomes `ISTANBUL`, which is a spelling error in Turkish
> (`İSTANBUL`). Detail on casing: [09](09-I18N.md) §6.

**[MAP-16] MUST:** Category, status and magnitude are expressed with data-driven
expressions (`match`, `case`, `step`, `interpolate`, `coalesce`) on **one** layer per
geometry kind. One layer per category is forbidden above three categories.
> **Why:** Twelve categories as twelve layers is twelve draw passes, twelve entries in the
> registry, twelve filters to keep in sync and twelve hover handlers. The same as one layer
> with a `match` is one pass. The layer budget ([MAP-55]) is 60 for the whole page.

```ts
// WRONG: one layer per status
for (const status of ['ok', 'warn', 'fail']) map.addLayer({ id: `sensor-${status}`, type: 'circle', filter: ['==', ['get', 'status'], status], paint: { 'circle-color': COLORS[status] } })

// RIGHT: one layer, an expression
paint: {
  'circle-color': ['match', ['get', 'status'], 'ok', '#16a34a', 'warn', '#f59e0b', 'fail', '#dc2626', '#94a3b8'],
  'circle-radius': ['interpolate', ['linear'], ['zoom'], 10, 3, 16, 9],
}
```

**[MAP-17] MUST:** Hover and selection are stored with `map.setFeatureState` and read with
`['feature-state', 'hover']` / `['feature-state', 'selected']`. Every source that takes
part in hover or selection has stable ids: `promoteId: 'id'` on GeoJSON and vector sources
(a string or integer property), or top-level integer `feature.id`.
> **Why:** `feature-state` is keyed by feature id. A GeoJSON feature without `id` gets none,
> so `setFeatureState` throws `The feature id parameter must be provided`. `generateId: true`
> assigns sequential integers that change on every `setData`, so the selected feature
> silently becomes a different one after a refresh. `generateId` is allowed only for
> read-only sources that are never refreshed. Vector tiles need `promoteId` per source layer
> (`promoteId: { parcels: 'id' }`) because MVT ids are optional and tippecanoe's
> `--generate-ids` is not stable across rebuilds ([GIS-14]).

**[MAP-18] MUST NOT:** Highlighting by calling `setData` with a modified copy of the
collection, by a second "selected" source, or by `setFilter` on a duplicate layer.
> **Why:** `setData` re-tiles the whole source in the worker (5,000 polygons: 80 to 200 ms
> on the reference hardware) and drops all feature state. A hover that re-tiles on every
> `mousemove` is the single most common cause of a stuttering map in the codebase this
> standard replaces.

```ts
// src/shared/map/featureState.ts
import type { Map as MapLibreMap } from 'maplibre-gl'

export interface FeatureRef { source: string; sourceLayer?: string; id: string | number }

export function setSelected(map: MapLibreMap, previous: FeatureRef | null, next: FeatureRef | null): void {
  if (previous) map.setFeatureState(previous, { selected: false })
  if (next) map.setFeatureState(next, { selected: true })
}
```

---

## 4. Events

**[MAP-29] MUST:** The map module registers **one** `click`, **one** `mousemove` and **one**
`mouseleave` handler per map (`attachInteractions`). It queries `registry.interactiveLayerIds()`
and dispatches to feature subscribers. Features subscribe with `useMapClick(layerIds,
handler)` and `useMapHover(layerIds, handler)`; they never call `map.on('click', layerId, …)`.
> **Why:** MapLibre's per-layer `on('click', layerId)` runs one `queryRenderedFeatures` per
> registered layer per click. With 30 layers that is 30 queries and 30 handlers deciding who
> owns the click, and two features both opening a popup. One query, one winner.

```ts
// src/shared/map/mapInteractions.ts
import type { Map as MapLibreMap, MapGeoJSONFeature, MapMouseEvent } from 'maplibre-gl'

import type { LayerRegistry } from './layerRegistry'
import type { FeatureRef } from './featureState'

export interface FeatureHit { feature: MapGeoJSONFeature; layerId: string; lngLat: [number, number]; point: { x: number; y: number } }
export type ClickListener = (hit: FeatureHit | null) => void
export type HoverListener = (hit: FeatureHit | null) => void

const clickListeners = new Set<ClickListener>()
const hoverListeners = new Set<HoverListener>()
export const subscribeClick = (l: ClickListener) => { clickListeners.add(l); return () => clickListeners.delete(l) }
export const subscribeHover = (l: HoverListener) => { hoverListeners.add(l); return () => hoverListeners.delete(l) }

const toRef = (f: MapGeoJSONFeature): FeatureRef | null =>
  f.id === undefined ? null : { source: f.source, sourceLayer: f.sourceLayer, id: f.id }

export function attachInteractions(map: MapLibreMap, registry: LayerRegistry): () => void {
  let hovered: FeatureRef | null = null
  let rafId = 0
  let lastPoint: { x: number; y: number } | null = null

  const topHit = (point: { x: number; y: number }): FeatureHit | null => {
    const layers = registry.interactiveLayerIds().filter((id) => map.getLayer(id))
    if (layers.length === 0) return null
    const [f] = map.queryRenderedFeatures([point.x, point.y], { layers }) // topmost first
    if (!f) return null
    const ll = map.unproject([point.x, point.y])
    return { feature: f, layerId: f.layer.id, lngLat: [ll.lng, ll.lat], point }
  }

  const onClick = (e: MapMouseEvent) => {
    const hit = topHit(e.point)
    for (const l of clickListeners) l(hit)
  }

  const applyHover = () => {
    rafId = 0
    if (!lastPoint) return
    const hit = topHit(lastPoint)
    const next = hit && registry.hoverEnabled(hit.layerId) ? toRef(hit.feature) : null
    if (hovered && (!next || hovered.id !== next.id || hovered.source !== next.source)) map.setFeatureState(hovered, { hover: false })
    if (next && (!hovered || hovered.id !== next.id || hovered.source !== next.source)) map.setFeatureState(next, { hover: true })
    hovered = next
    map.getCanvas().style.cursor = hit ? 'pointer' : ''                       // [MAP-30]
    for (const l of hoverListeners) l(hit)
  }
  const onMove = (e: MapMouseEvent) => {                                        // [MAP-31]
    lastPoint = e.point
    if (!rafId) rafId = requestAnimationFrame(applyHover)
  }
  const onLeave = () => {
    lastPoint = null
    if (hovered) map.setFeatureState(hovered, { hover: false })
    hovered = null
    map.getCanvas().style.cursor = ''
  }

  map.on('click', onClick)
  map.on('mousemove', onMove)
  map.getCanvas().addEventListener('mouseleave', onLeave)
  return () => {
    if (rafId) cancelAnimationFrame(rafId)
    map.off('click', onClick)
    map.off('mousemove', onMove)
    map.getCanvas().removeEventListener('mouseleave', onLeave)
    clickListeners.clear()
    hoverListeners.clear()
  }
}
```

```ts
// src/shared/map/useMapClick.ts
import { useEffect } from 'react'

import { subscribeClick, type FeatureHit } from './mapInteractions'

/** Called with the top hit when it belongs to one of `layerIds`; with null on an empty map click. */
export function useMapClick(layerIds: ReadonlyArray<string>, handler: (hit: FeatureHit | null) => void): void {
  useEffect(() => subscribeClick((hit) => {
    if (hit === null || layerIds.includes(hit.layerId)) handler(hit)
  }), [layerIds, handler])
}
```

**[MAP-30] MUST:** The cursor is set only by `attachInteractions` (`pointer` over an
interactive feature, `''` otherwise, `crosshair` while a draw mode is active, `grabbing`
is MapLibre's own). Features never write `map.getCanvas().style.cursor`.
> **Why:** Two features fighting over the cursor leave it stuck on `pointer` over empty map.

**[MAP-31] MUST:** `mousemove` work is throttled to one `queryRenderedFeatures` per
animation frame, always with a `layers` filter, and skipped while `map.isMoving()` is true.
> **Why:** `mousemove` fires at up to 120 Hz on a high-refresh mouse; an unfiltered
> `queryRenderedFeatures` over a base style with 80 layers costs 3 to 8 ms each. rAF caps it
> at the frame rate; the layer filter cuts the cost to under 0.5 ms.

**[MAP-32] MUST:** Touch devices get no hover behaviour; the first tap on a feature selects
it and opens the popup, and interactive hit targets on touch use a `circle-radius` or
`icon-size` at least **12 px** (24 px diameter) at the zoom where they are tappable.
> **Why:** There is no `mousemove` on touch. A 6 px circle is a 60 % miss rate on a phone;
> WCAG target size is 24 px ([A11Y-15]).

**[MAP-33] MUST:** When features from several layers overlap under the pointer, the topmost
rendered feature wins. Topmost is defined by anchor order then mount order ([MAP-05]).
A feature that needs priority over another feature's layer uses a higher anchor, not a
`click` handler that checks `hits.length`.
> **Why:** `queryRenderedFeatures` returns hits in render order, topmost first; the
> dispatcher takes `[0]`. Making that the rule means the paint order you see is the click
> order you get.

---

## 5. Popups

**[MAP-34] MUST:** One `maplibregl.Popup` per map, owned by `usePopup()` in the map module.
Features render popup content as React elements through `usePopup().open(lngLat, <Content />)`.
No feature constructs a `Popup`.
> **Why:** Two popups open at once is a UX bug and a memory leak (popups hold DOM and
> listeners until `remove()`).

**[MAP-35] MUST:** Popup content is rendered by React with `createPortal` into a container
passed to `popup.setDOMContent(container)`. `popup.setHTML` with any data-derived string is
forbidden ([SEC-01]).
> **Why:** `setHTML(\`<b>${feature.properties.name}</b>\`)` is an XSS for any feature whose
> name contains `<img onerror=…>`, and municipal datasets are imported from spreadsheets no
> one has sanitised. A portal keeps i18n, hooks and event handlers working inside the popup.

**[MAP-36] MUST:** The popup closes on Escape, on a click on empty map, and when its feature
is removed from the source. It opens with `anchor: 'auto'`, `maxWidth: '320px'`,
`closeButton: true` (a real `<button>` for keyboard users), and moves focus into the popup
when opened by keyboard ([A11Y-08]).
> **Why:** A popup pinned to `anchor: 'bottom'` renders off-screen for features near the top
> edge; `auto` flips it. Without Escape handling, keyboard users cannot dismiss it.

```tsx
// src/shared/map/usePopup.tsx
import { useCallback, useEffect, useMemo, useState, type ReactNode } from 'react'
import { createPortal } from 'react-dom'

import maplibregl from '@/shared/lib/maplibreInit'

import { useMap } from './MapContext'

interface PopupState { lngLat: [number, number]; content: ReactNode }

export function usePopup() {
  const { map } = useMap()
  const [state, setState] = useState<PopupState | null>(null)
  const container = useMemo(() => document.createElement('div'), [])
  const popup = useMemo(
    () => new maplibregl.Popup({ anchor: 'auto', maxWidth: '320px', closeButton: true, closeOnClick: true, className: 'app-popup' }).setDOMContent(container),
    [container],
  )

  useEffect(() => {
    const onClose = () => setState(null)
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') popup.remove() }
    popup.on('close', onClose)
    window.addEventListener('keydown', onKey)
    return () => {
      popup.off('close', onClose)
      window.removeEventListener('keydown', onKey)
      popup.remove()
    }
  }, [popup])

  useEffect(() => {
    if (!state) { popup.remove(); return }
    popup.setLngLat(state.lngLat).addTo(map)
  }, [state, popup, map])

  const open = useCallback((lngLat: [number, number], content: ReactNode) => setState({ lngLat, content }), [])
  const close = useCallback(() => setState(null), [])
  const portal = state ? createPortal(state.content, container) : null
  return { open, close, isOpen: state !== null, portal }
}
```

The feature's popup component renders `{portal}` in its tree so the content is part of the
React tree (providers, i18n, error boundary all apply).

---

## 6. Lifecycle, cleanup and the GL context ([GEN-20], [GEN-21])

**[MAP-37] MUST:** A feature adds its layers with `useMapLayer(spec, enabled)`. The hook
adds when ready, removes on unmount or when `enabled` becomes false, and is the only
public path from a feature to the registry. `spec` is a module-level constant or a
`useMemo` result; an inline object literal is a lint error (`react-hooks/exhaustive-deps`
catches the changing reference).
> **Why:** A spec re-created on every render would remove and re-add the layers on every
> render. A hook that owns both add and remove cannot forget the remove.

```ts
// src/shared/map/useMapLayer.ts
import { useEffect } from 'react'

import { useMap } from './MapContext'
import { useMapReady } from './useMapReady'
import type { LayerSpec } from './layerRegistry'

export function useMapLayer(spec: LayerSpec, enabled = true): void {
  const { registry } = useMap()
  const ready = useMapReady()
  useEffect(() => {
    if (!ready || !enabled) return
    let cancelled = false
    void registry.add(spec).catch((err: unknown) => {
      // Adding can fail for a bad expression or a missing source-layer; that is a bug, not noise.
      if (!cancelled) throw err
    })
    return () => {
      cancelled = true
      registry.remove(spec.sourceId)
    }
  }, [ready, enabled, registry, spec])
}
```

```tsx
// src/features/Parking/components/ParkingLayer.tsx
export function ParkingLayer() {
  const { map, registry } = useMap()
  const ready = useMapReady()
  const { data } = useQuery(parkingQueries.geojson())
  useMapLayer(parkingLayerSpec)

  useEffect(() => {
    if (!ready || !data || !registry.has(PARKING_SRC)) return
    const src = map.getSource(PARKING_SRC)
    if (src?.type === 'geojson') src.setData(data)   // same reference as the query cache ([STA-14])
  }, [ready, data, map, registry])

  return null
}
```

**[MAP-38] MUST:** Removal order is layers (reverse of add), then the source, then images.
Every removal is guarded by `map.getLayer`/`getSource`/`hasImage` and by an "is the map
alive" check (`map.getStyle() !== undefined` and the registry's `remove` flag). Effects that
run after `map.remove()` return early instead of touching the map.
> **Why:** `removeSource` with a layer still attached throws `Source cannot be removed
> while layer is using it`. After `map.remove()`, `map.style` is `undefined` and every
> style call throws `Cannot read properties of undefined (reading 'getLayer')`, which is
> exactly the error the reference project monkey-patched away ([MAP-08]).

**[MAP-39] MUST:** All map effects survive StrictMode's mount, unmount, remount: the
cleanup fully undoes the effect, and the effect body is idempotent (`if (map.getLayer(id))
return` before `addLayer`). `MapContainer` creates a new `Map` per effect run; it never
caches the instance in a module variable or ref across runs.
> **Why:** In development React 19 runs every effect twice. A layer added twice throws
> `Layer with id already exists`; a map cached across the double-invoke is a removed map on
> the second run. Code that only works with StrictMode off is code that leaks on route change.

**[MAP-40] MUST:** Before mounting the map, `checkWebGl2()` verifies that a `webgl2` context
can be created. If it cannot, `MapContainer` renders a translated message (`map.webglUnavailable`)
with the browser upgrade hint instead of a blank canvas, and reports the event to the error
tracker as a warning with the renderer string ([OBS-09]). A software renderer is allowed but
recorded so terrain and shadows start disabled ([MAP-52]).
> **Why:** MapLibre 5 requires WebGL 2. Without the check, an old Safari, a remote desktop
> session or a browser with hardware acceleration disabled shows an empty grey box and a
> console error nobody sees. The reference project's detection (renderer string from
> `WEBGL_debug_renderer_info`, `hardwareConcurrency`, `deviceMemory`) is kept: it is the
> only signal available before the first frame.

```ts
// src/shared/map/webglCapability.ts
export type GlCheck =
  | { ok: true; software: boolean; renderer: string }
  | { ok: false; reason: 'no-webgl2'; renderer: string }

const SOFTWARE_HINTS = ['swiftshader', 'llvmpipe', 'software', 'basic render', 'warp', 'mesa offscreen']
let cached: GlCheck | null = null

export function checkWebGl2(): GlCheck {
  if (cached) return cached
  const canvas = document.createElement('canvas')
  const gl = canvas.getContext('webgl2')
  if (!gl) return (cached = { ok: false, reason: 'no-webgl2', renderer: 'none' })
  const dbg = gl.getExtension('WEBGL_debug_renderer_info')
  const renderer = dbg ? String(gl.getParameter(dbg.UNMASKED_RENDERER_WEBGL)) : 'unknown'
  // failIfMajorPerformanceCaveat returns null on software rasterisers: a second, independent signal.
  const caveat = document.createElement('canvas').getContext('webgl2', { failIfMajorPerformanceCaveat: true }) === null
  const software = caveat || SOFTWARE_HINTS.some((h) => renderer.toLowerCase().includes(h))
  gl.getExtension('WEBGL_lose_context')?.loseContext()
  return (cached = { ok: true, software, renderer })
}
```

**[MAP-41] MUST:** `MapContainer` handles `webglcontextlost` by showing a blocking overlay
(`map.contextLost`, with a reload button) and `webglcontextrestored` by hiding it and calling
`map.setStyle(currentStyleUrl)`, which triggers the registry re-add ([MAP-07]). Feature code
does not listen to these events.
> **Why:** The GPU process is killed when the OS runs out of VRAM, when a laptop switches
> GPUs, or when Chrome's tab limit is hit. Without a handler the canvas freezes on the last
> frame and every subsequent `addLayer` throws. Treating restore as a style switch reuses a
> path that is already exercised by the theme toggle.

---

## 7. Viewport and URL

**[MAP-45] MUST:** The viewport (`lng`, `lat`, `z`, and `b` for bearing when non-zero,
`p` for pitch when non-zero) lives in the URL query as URL state ([STA-08]), written on
`moveend` (debounced 250 ms, `replace` not `push`) with 5 decimals for coordinates and 2 for
zoom, and read once when the map is created.
> **Why:** A shared link must open the same view; the back button must not step through
> forty pans. 5 decimals is 1.1 m, more than enough for a view centre ([GIS-03]).

**[MAP-46] MUST:** `fitBounds` is always called with `padding` (default `{ top: 48, right:
48, bottom: 48, left: 48 }`, larger on the side that has a panel) and `maxZoom: 18`, and
only when the bbox is non-empty and non-degenerate (a single point uses `flyTo` with a fixed
zoom).
> **Why:** A degenerate bbox (`[x, y, x, y]`) makes `fitBounds` zoom to level 24 and
> MapLibre clamps it to a blank canvas. Padding keeps the fitted geometry out from under the
> side panel.

**[MAP-47] MUST:** Municipal apps set `maxBounds` to the municipality's bbox padded by 20 %
and `minZoom` to the zoom at which the whole municipality fits.
> **Why:** Users who pan to the Atlantic by accident, and a zoomed-out view that requests
> whole-country tiles you do not serve.

**[MAP-48] MUST:** Animated camera moves (`flyTo`, `easeTo`) are used for user-initiated
navigation with `duration` ≤ 800 ms; `jumpTo` is used when the user has
`prefers-reduced-motion: reduce` ([A11Y-12]), on initial load, and when restoring from the
URL. A `useCameraMove()` helper in the map module picks the right one.
> **Why:** A 2 s fly-through triggers motion sickness for some users and is pure delay for
> everyone else. Reduced-motion is a WCAG requirement, not a preference.

**[MAP-49] MUST:** `map.resize()` is called after any container size change that does not
come from the window (side panel opening, split view), triggered by a `ResizeObserver` on
the map container inside `MapContainer`.
> **Why:** MapLibre listens to `window.resize` only. A panel that shrinks the container
> leaves the canvas at the old size, stretched, with clicks landing in the wrong place.

---

## 8. Map checklist

Walk this list when upgrading `maplibre-gl` (minor or major) and when adding a map feature.
Tick every item in the PR description.

1. One `Map` instance; the feature uses `useMap()`, `useMapReady()`, `useMapLayer()` only.
2. Ids follow `<feature>-<kind>[-<variant>]` and are listed in the feature README.
3. Every layer names an anchor; no `beforeId` of a base-style layer; no `moveLayer`.
4. Theme switch (light → dark → satellite → light) keeps every feature layer visible.
5. Hover and selection use `feature-state`; source has `promoteId` or integer ids.
6. No `Marker` for data; each `Marker` in the feature is a listed widget ([MAP-11]).
7. GeoJSON under 5,000 features and 2 MB, or the data is MVT/PMTiles from runtime config.
8. Sources declare `minzoom`/`maxzoom`/`bounds` or use TileJSON; layers declare `minzoom`.
9. Click and hover go through `useMapClick`/`useMapHover`; no `map.on('click', layerId)`.
10. Popup content rendered via `usePopup()` portal; no `setHTML`.
11. Unmount removes layers, source, images in that order; StrictMode double-mount is clean.
12. `setData` rate ≤ 4 Hz, stable object references, interpolation in a ref.
13. Layer count on the busiest page ≤ 60 (count via `map.getStyle().layers` at `idle`).
14. Terrain guard and hillshade separation untouched; sky uses `setSky`.
15. Spec unit test, fake-map component test and Playwright idle screenshot are green.

Extra items for a MapLibre **major** upgrade: run the draw adapter ([MAP-42]) against the
new version; verify `canvasContextAttributes`, `setSky`, `updateData`, `promoteId` on
vector sources, `feature-state` on clustered sources, and terrain with a custom layer
present; re-baseline the Playwright screenshots in a separate commit.

---

## 9. Known MapLibre pitfalls

| # | Symptom | Cause | Rule |
|---|---|---|---|
| 1 | `Style is not done loading` | `addSource`/`addLayer` before `style.load` and `isStyleLoaded()` | [MAP-03] |
| 2 | `Source "x" does not exist` on `addLayer` | Layer added before its source | registry paints source first ([MAP-04]) |
| 3 | `Source cannot be removed while layer is using it` | Removal order wrong | [MAP-38] |
| 4 | All custom layers vanish after theme toggle | `setStyle` rebuilds the style | [MAP-07] |
| 5 | `The feature id parameter must be provided` | GeoJSON without ids, no `promoteId` | [MAP-17] |
| 6 | Map zooms to grey at level 24 | `fitBounds` on an empty or point bbox | [MAP-46] |
| 7 | Canvas stretched, clicks offset | Container resized without `map.resize()` | [MAP-49] |
| 8 | Blurry icons and text on retina | Raster icon at `pixelRatio: 1`; `pixelRatio` uncapped costs frames | [MAP-13], [MAP-58] |
| 9 | Scroll-zoom hijacks page scroll on embedded maps | `cooperativeGestures` not set on maps inside scrolling pages | set `cooperativeGestures: true` for non-fullscreen maps |
| 10 | Blank canvas on iPad/iPhone at large sizes | iOS canvas memory limit (about 16.7 M pixels) exceeded by `pixelRatio` × container | [MAP-58]; never exceed 4096 px in either dimension |
| 11 | Two maps in the same container after a file save (Windows dev) | Vite HMR re-ran the effect but the old map was cached in a module variable | [MAP-39] |
| 12 | `Cannot read properties of undefined (reading 'getLayer')` | Effect ran after `map.remove()` (StrictMode or route change) | [MAP-38], [MAP-08] |
| 13 | `Layer with id "x" already exists` | Non-idempotent effect under StrictMode | [MAP-39] |
| 14 | Selected feature "jumps" to a neighbour after refresh | `generateId: true` on a refreshed source | [MAP-17] |
| 15 | `ReferenceError` inside the worker only in production | Default blob worker loses hoisted references after Rollup; use the CSP worker file | `maplibreInit.ts` ([MAP-27] snippet) |
| 16 | 404 storms for `/tiles/x/18/...` | Source without `maxzoom`/TileJSON | [MAP-22] |
| 17 | Turkish labels show `ISTANBUL` or boxes | `text-transform`, or a glyph font without Latin Extended-A | [MAP-15] |
| 18 | Hover flickers and the map stutters | `setData` used for highlight, or unfiltered `queryRenderedFeatures` on `mousemove` | [MAP-18], [MAP-31] |
| 19 | Draw vertices hidden under data layers | `gl-draw-*` layers below re-added feature layers | [MAP-43] |
| 20 | `setFog is not a function` (or silently nothing) | Mapbox API; MapLibre uses `setSky` | [MAP-54] |

---

## Open questions

- **Snapping in the draw tool.** Not in the table; `mapbox-gl-draw-snap-mode` is unmaintained.
  Decide when a feature needs shared-boundary editing (parcels, zoning): either a custom mode
  in `src/shared/map/draw/modes/` or an approved package via [VER-06].
- **MapLibre 6.** Blocked on §14 passing on the reference repo, in particular
  `canvasContextAttributes`, `feature-state` on clustered sources, terrain with custom
  layers and the draw adapter. Track in [02](02-TECH-VERSIONS.md).
- **`updateData` gain on 5.x.** [MAP-28] stays SHOULD until the reference project measures
  the diff path against `setData` for 300 vehicles at 4 Hz.
- **Section numbering cited elsewhere.** `02-TECH-VERSIONS.md` refers to "the map
  checklist in `08` §10" and "the `maplibre` style adapter in `08` §8". In this document the
  checklist is §14 and the draw adapter is §8. The `02` reference to §10 should be updated to §14.
