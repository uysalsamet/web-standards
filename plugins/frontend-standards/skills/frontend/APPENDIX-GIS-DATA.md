# Appendix — GIS Data

> Governs the geodata itself: coordinate order and precision, projections, GeoJSON
> conformance, the size threshold where a file becomes tiles, the tiling recipe, tile
> naming and TileJSON, elevation encoding, area and length display, geocoding, and
> attribution. Core principle: **the browser receives WGS84 `[lng, lat]`, rounded to 6
> decimals, in the smallest form that answers the question on screen.** Read this file when
> a task mentions GeoJSON, a projection, an EPSG code, a `.mbtiles`/`.pmtiles` archive,
> `tippecanoe`, a DEM, a bbox or a coordinate that came out wrong.
>
> Out of scope: how MapLibre consumes this data (sources, layers, `feature-state`, popups,
> lifecycle, terrain rendering) is owned by [08-MAP-MAPLIBRE.md](08-MAP-MAPLIBRE.md). The
> tile service deployment and its SQL is owned by the backend standard.

---

## 1. Vocabulary

| Term | Meaning |
|---|---|
| **position** | A single `[lng, lat]` pair (RFC 7946 calls it a *position*). Never `[lat, lng]` |
| **4326** | EPSG:4326, WGS84 geographic degrees. The wire format for all our geodata |
| **3857** | EPSG:3857, Web Mercator. A *rendering* projection, never a storage format here |
| **TUREF** | Türkiye Ulusal Referans Çerçevesi, the Turkish national datum (ITRF96-based, epoch 2005.0). Municipal cadastral data arrives in one of its projected zones |
| **MVT** | Mapbox Vector Tile, the `.pbf` payload of a vector tile |
| **source-layer** | The named layer *inside* an MVT tile. Set by `tippecanoe -l`, consumed by MapLibre |
| **DEM** | Digital elevation model, delivered as RGB-encoded raster tiles |

---

## 2. Coordinate order and precision

**[GIS-01] MUST:** A position in TypeScript is the branded tuple `LngLat` from
`src/shared/types/geo.ts`; a raw `[number, number]` is not passed across a function
boundary. Bounds are the branded `BBox4` (`[west, south, east, north]`).
> **Why:** The compiler cannot tell `[lng, lat]` from `[lat, lng]`, and a swapped pair
> renders in the Indian Ocean instead of Istanbul with no error anywhere. A brand forces
> every producer through one constructor that validates ranges. Cross-ref: [TS-10].

```ts
// src/shared/types/geo.ts
declare const lngLatBrand: unique symbol

/** WGS84 position, ALWAYS [longitude, latitude] (RFC 7946 §3.1.1). */
export type LngLat = readonly [number, number] & { readonly [lngLatBrand]: true }
export type BBox4 = readonly [number, number, number, number] & { readonly [lngLatBrand]: true }

const LNG_MIN = -180
const LNG_MAX = 180
const LAT_MIN = -90
const LAT_MAX = 90

export function lngLat(lng: number, lat: number): LngLat {
  if (!Number.isFinite(lng) || !Number.isFinite(lat)) {
    throw new Error(`lngLat: non-finite input (lng=${lng}, lat=${lat})`)
  }
  if (lng < LNG_MIN || lng > LNG_MAX || lat < LAT_MIN || lat > LAT_MAX) {
    // The overwhelmingly common cause is a swapped pair: latitude 41 in the lng slot passes
    // silently, but longitude 29 in the lat slot is caught as soon as latitude exceeds 90.
    throw new Error(`lngLat: out of range (lng=${lng}, lat=${lat}); did you pass [lat, lng]?`)
  }
  return [lng, lat] as unknown as LngLat
}
```

**[GIS-02] MUST:** Every coordinate in code, in GeoJSON, in an API request and in a URL is
`[lng, lat]`, longitude first. This includes MapLibre (`setCenter`, `flyTo`, `fitBounds`,
`Popup.setLngLat`), turf, the tile bbox parameter and the viewport query parameters.
> **Why:** RFC 7946 §3.1.1 fixes the order as longitude, latitude, and MapLibre follows it.
> Much of the surrounding world uses the other order (Google Maps URLs, handheld GPS
> exports, almost every municipal Excel sheet), so the boundary is where the bug enters.
> One order in code, converted exactly once, at the parser. Cross-ref: [API-20].

**[GIS-03] MUST:** Coordinates are rounded to **6 decimal places** when they leave the app
(API request body, URL, exported file, clipboard) and are never stored or transmitted with
more. Viewport coordinates in the URL use 5 decimals ([MAP-45]).
> **Why:** The sixth decimal of a degree is about 11 cm at the equator and less further
> north; nothing a user does on a screen is more precise than that. Serialising 15
> significant digits inflates a 50,000-position GeoJSON by roughly 40 % for digits that are
> floating-point noise, and the noise makes cache keys and diffs unstable. The seventh
> decimal (about 1.1 cm) is only meaningful for survey data, which does not travel through
> the browser.

```ts
// src/shared/utils/geo/round.ts
import { lngLat, type LngLat } from '@/shared/types/geo'

const OUTPUT_DECIMALS = 6
const FACTOR = 10 ** OUTPUT_DECIMALS

/** Rounds for OUTPUT only. Data received from the API is displayed as received. */
export const roundPosition = ([lng, lat]: LngLat): LngLat =>
  lngLat(Math.round(lng * FACTOR) / FACTOR, Math.round(lat * FACTOR) / FACTOR)
```

**[GIS-04] MUST:** Coordinates shown to a human are rendered `lat, lng` in that order, each
value labelled ("Enlem 41,184230, Boylam 28,734190"), formatted with `Intl.NumberFormat`
for the active locale, and copied to the clipboard in the same order.
> **Why:** Municipal users paste coordinates into Google Maps or a handheld GPS, both of
> which expect `lat, lng`. Showing the internal order to be "consistent" makes the app the
> odd one out and produces a support ticket per user. The labels remove the ambiguity that
> order alone cannot. Cross-ref: [I18N-11] for the number formatting.

**[GIS-05] MUST:** Coordinates parsed from an external source (a pasted string, a CSV
column, an uploaded file, a query parameter) are validated for range and for plausibility
against the application's `maxBounds` ([MAP-47]) before use; a value outside it is a
user-facing validation error, never a silent clamp.
> **Why:** An export where two columns were swapped produces valid numbers in the wrong
> slots. Clamping hides it: the user sees the map jump to a corner of the municipality and
> files a bug against the map. Bounds checking names the offending row. Cross-ref: [SEC-28].

**[GIS-06] MUST:** A third element in a position (altitude, permitted by RFC 7946 §3.1.1)
is stripped at the parser unless the feature genuinely needs elevation, and is never assumed
to be metres above ellipsoid versus above geoid without the source stating which.
> **Why:** MapLibre ignores the third element in most layer types, but `tippecanoe` keeps
> it, so it grows every tile for nothing. Where elevation is used (a drone flight path), the
> ellipsoid-to-geoid separation in Turkey is roughly 35 to 40 m, which is the difference
> between a drone at rooftop height and a drone underground.

---

## 3. Coordinate reference systems

**[GIS-07] MUST:** All geodata crossing the network is EPSG:4326 (WGS84 geographic
degrees). Web Mercator (EPSG:3857) exists only inside the renderer and inside the tile
pyramid; no API returns 3857 metres and no application code computes in them.
> **Why:** One wire CRS means one validation rule, one rounding rule and one turf call
> signature. 3857 "metres" are not a usable length unit: at latitude 41 the Mercator scale
> factor is about 1.33, so a 1,000-unit difference in 3857 is roughly 754 real metres. Code
> that measures in 3857 is silently a third wrong in Istanbul.

**[GIS-08] MUST:** Data that arrives in a Turkish national grid (TUREF/TM 3-degree zones,
ITRF96, ED50/UTM, or a legacy local grid) is reprojected to 4326 **server-side with PostGIS**
(`ST_Transform`) during ingest, and only the 4326 result reaches the browser. The source CRS
is recorded in the dataset's ingest note ([GIS-42]).
> **Why:** A datum shift is not a formula the frontend can be trusted with: ED50 to WGS84 in
> Turkey is a shift of roughly 80 to 100 m, which puts a building on the neighbouring
> parcel. In a cadastral application that is a legal problem, not a rendering problem.
> PostGIS carries the full EPSG database including datum transformation parameters; a
> browser library carries whatever definition string someone pasted into a constant.

Codes seen in Turkish municipal handovers. **Verify each against the EPSG registry before
using it in an ingest script**; this is a starting point, not an authority:

| Code | Meaning | Where it shows up |
|---|---|---|
| 4326 | WGS84 geographic | Our wire format |
| 3857 | Web Mercator | Tile pyramid, renderer |
| 5254 | TUREF / TM30 (3-degree, central meridian 30E) | Istanbul-area cadastral data |
| 5255 | TUREF / TM33 | Ankara-area cadastral data |
| 23035, 23036 | ED50 / UTM zone 35N, 36N | Pre-2005 archives |
| 5252 | TUREF geographic | Usually in metadata only |

**[GIS-09] MUST NOT:** `proj4`/`proj4js` ships in the browser bundle. It is not in the
version table ([02](02-TECH-VERSIONS.md)) and adding it needs approval ([GEN-03]). The one
case that would justify it is an import screen where the user picks the source CRS of a file
they just dropped and needs a preview before ingest; that screen lazy-loads it, uses it for
preview only, and uploads the **original** file for the server to transform.
> **Why:** Two reprojection implementations with different datum handling produce two
> answers for the same input, and the one the user approved in the preview is not the one
> that got stored. Preview-only keeps a single authority.

---

## 4. GeoJSON hygiene (RFC 7946)

**[GIS-10] MUST:** Polygon and MultiPolygon rings follow the right-hand rule (RFC 7946
§3.1.6): exterior rings counter-clockwise, interior rings (holes) clockwise. Winding is
fixed at ingest, never in the browser.
> **Why:** MapLibre's `fill` layer tolerates either winding, so a wrongly wound polygon
> looks correct until something computes with it: `@turf/boolean-point-in-polygon` treats
> the "inside" as the whole world minus the polygon, and a district hit-test then matches
> every click on the map. `mapshaper -rewind` or PostGIS `ST_ForcePolygonCCW` fixes it once.

**[GIS-11] MUST NOT:** A GeoJSON document contains a `crs` member. RFC 7946 removed it, and
its presence means the file predates the RFC and its coordinates are probably not 4326.
> **Why:** Tools that still read `crs` and tools that ignore it disagree about the same
> file. A file with `"crs": {"properties": {"name": "EPSG:5254"}}` and 400,000-metre
> coordinates loads into MapLibre as a point far past the antimeridian, silently. Treat a
> `crs` member as a signal to send the file back to ingest ([GIS-08]).

**[GIS-12] MUST:** Committed and served GeoJSON is a single `FeatureCollection` whose
features are valid: no `null` geometry, no zero-length lines, no ring with fewer than four
positions, no unclosed rings, no self-intersections, and district or neighbourhood
boundaries typed `MultiPolygon` even when they currently have one part.
> **Why:** MapLibre skips an invalid feature without a message, so the count on screen
> silently differs from the count in the table. `MultiPolygon` up front prevents the schema
> break on the day a coastal neighbourhood turns out to include an island: with `Polygon` in
> the schema that day is a type error across the whole feature. Verify with
> `mapshaper -i file.geojson -verify` or PostGIS `ST_IsValidReason`.

**[GIS-13] MUST:** `properties` is a flat object of primitives (`string`, `number`,
`boolean`, `null`) and is validated with a zod schema before the collection reaches a
source. Nested objects and arrays are flattened at ingest.
> **Why:** MVT properties are flat by specification, so a nested object survives GeoJSON but
> becomes `"[object Object]"` after tiling, and the same feature then behaves differently in
> the GeoJSON and MVT paths of the same app. The zod parse is [GEN-07] applied to geodata.

```ts
// src/features/Neighborhood/api/neighborhoodSchemas.ts
import { z } from 'zod'

const PositionSchema = z.tuple([z.number().min(-180).max(180), z.number().min(-90).max(90)])

export const NeighborhoodPropsSchema = z.object({
  id: z.string().min(1),                       // stable across rebuilds ([GIS-14])
  name: z.string().min(1),
  areaM2: z.number().nonnegative(),
  population: z.number().int().nonnegative().nullable(),
})

export const NeighborhoodFeatureSchema = z.object({
  type: z.literal('Feature'),
  id: z.union([z.string(), z.number()]),
  geometry: z.object({
    type: z.literal('MultiPolygon'),
    coordinates: z.array(z.array(z.array(PositionSchema))),
  }),
  properties: NeighborhoodPropsSchema,
})

export const NeighborhoodCollectionSchema = z.object({
  type: z.literal('FeatureCollection'),
  features: z.array(NeighborhoodFeatureSchema),
})
export type NeighborhoodCollection = z.infer<typeof NeighborhoodCollectionSchema>
```

**[GIS-14] MUST:** Every feature carries an id that is **stable across rebuilds**, derived
from the source system's primary key, present both as the GeoJSON `id` member and as a
`properties.id` field. `tippecanoe --generate-ids` and MapLibre's `generateId: true` are
forbidden for any dataset with hover or selection.
> **Why:** `feature-state` ([MAP-17]) is keyed by feature id. A generated id is the feature's
> ordinal position inside its tile, so the next tiling run renumbers everything: the parcel
> the user selected before the nightly rebuild is a different parcel after it, and the hover
> highlight lands on a neighbour. `properties.id` is needed as well because MVT preserves
> the id member inconsistently across tilers, and `promoteId` reads it back from properties.
> The reference project's converter scripts use `--generate-ids`; they are the example of
> what not to copy.

---

## 5. Fetching by extent

**[GIS-15] MUST:** A dataset larger than the viewport is fetched by bounding box: the client
sends `?bbox=west,south,east,north` (4326, 6 decimals) plus a zoom or simplification hint,
and the server returns only intersecting features. Downloading a full collection and
filtering it in the browser is forbidden.
> **Why:** 50,000 parcels is roughly 40 MB of JSON: about 6 s of main-thread parse, 300 MB
> of heap, and every pan re-filters an array the GPU never needed. The same viewport as a
> bbox query is 200 features and 60 KB. The client cannot make a 40 MB download fast; only
> the server can make it small. Cross-ref: [MAP-25] for the debounce and abort behaviour,
> [GEN-19] for the point where bbox queries should become tiles instead.

**[GIS-16] MUST:** The bbox in a TanStack Query key is rounded to **3 decimals** (about
110 m) and expanded outwards to the next 0.001 grid cell, so sub-pixel camera movement does
not create a new cache entry.
> **Why:** An unrounded bbox changes on every rendered frame of a pan, making every frame a
> cache miss and a new request. Rounding outwards guarantees the requested extent still
> covers the visible one. At zoom 15, 0.001 degrees is a small fraction of the screen, so a
> real pan still refetches. Cross-ref: [STA-06].

**[GIS-17] MUST:** A bbox endpoint declares a maximum feature count (default **2,000**) and
returns `truncated: true` plus the true total when it is reached; the UI then shows a "zoom
in to see all" state rather than a silently partial map.
> **Why:** A user who zooms out to the whole province turns a bbox query into a full-table
> scan. The cap bounds the response; the flag is what stops the user believing an incomplete
> map. A dataset that hits the cap routinely is a dataset that should be tiles ([GEN-19]).

---

## 6. Size discipline and the tiling recipe

**[GIS-18] MUST:** A GeoJSON file committed under `public/data/` is at most **2 MB** and
**5,000 features** serialised, matching the runtime limit in [MAP-19] and [GEN-19]. Above
either limit the dataset becomes vector tiles ([GIS-20]) and the raw file lives outside the
repository. `tools/check-standards.sh` fails the build on an oversized file.
> **Why:** The file sits in the Docker image, in every git clone forever, in the nginx cache
> and in browser memory twice (text and parsed). A 40 MB `yapi.geojson` costs every developer
> 40 MB on every clone for the rest of the repository's life, and deleting it later does not
> shrink the history.

**[GIS-19] MUST:** Before a file is committed it is simplified with `mapshaper`, and the
command that produced it is recorded in `public/data/README.md` next to the file.
> **Why:** Cadastral exports carry vertices at survey precision, roughly a hundred times more
> than a screen can show. Visvalingam simplification at 10 % typically removes 90 % of the
> vertices with no visible change at zoom 16. Without the recorded command the next refresh
> is regenerated with different settings and the map changes shape for no reviewable reason.

```bash
# public/data/README.md records exactly this line per file.
# -rewind fixes RFC 7946 winding ([GIS-10]); -clean removes slivers and self-intersections;
# precision=0.000001 applies the 6-decimal rule ([GIS-03]) at write time.
mapshaper neighborhoods_raw.geojson \
  -clean \
  -simplify visvalingam 10% keep-shapes \
  -rewind \
  -filter-fields id,name,areaM2,population \
  -o precision=0.000001 format=geojson neighborhoods.geojson

mapshaper -i neighborhoods.geojson -verify     # must report no errors before commit
```

**[GIS-20] MUST:** Vector tiles are built with `tippecanoe` using the flags below: `-zg`,
`--drop-densest-as-needed`, `--extend-zooms-if-still-dropping`, and `-l <layer>` naming the
`source-layer` explicitly. The command lives in `deployments/map/converts/<dataset>.sh`,
committed, with the source file's date in a comment.
> **Why:** Without `-l`, tippecanoe derives the layer name from the input filename, so
> `parsel.geojson` yields `source-layer: "parsel"`, and the day someone renames the file
> every layer in the style stops drawing with no error at all (MapLibre renders nothing for
> an unknown `source-layer` and logs nothing). Without `--drop-densest-as-needed` a dense
> district exceeds the 500 KB tile limit and tippecanoe drops features to fit, so the map is
> missing buildings precisely in the busiest area, which is where everyone looks.
> `--extend-zooms-if-still-dropping` adds zoom levels instead of losing features when
> dropping is not enough.

```bash
#!/usr/bin/env bash
# deployments/map/converts/parcels.sh
# source: parsel_2026-08-14.geojson (TUREF/TM30, reprojected to 4326 by ingest [GIS-08])
set -euo pipefail

tippecanoe \
  -o parcels.mbtiles \
  -l parcels \
  -zg \
  --drop-densest-as-needed \
  --extend-zooms-if-still-dropping \
  --simplification=4 \
  --detect-shared-borders \
  --force \
  parcels_4326.geojson

# -l parcels          : the source-layer every layer spec must name ([GIS-21])
# -zg                 : maximum zoom derived from feature density, not guessed
# --simplification=4  : Douglas-Peucker in tile units; invisible at z16, halves vertex count
# --detect-shared-borders : adjacent parcels stop shimmering along their common edge
# NOT used: --generate-ids ([GIS-14]); ids come from properties.id via promoteId.
# NOT used: --no-tile-size-limit / --no-feature-limit; those disable the guard that makes
#           --drop-densest-as-needed meaningful and produce multi-megabyte tiles.

# MBTiles feeds a tile server; PMTiles is the static-archive path ([MAP-27]).
pmtiles convert parcels.mbtiles parcels.pmtiles
```

**[GIS-21] MUST:** The MVT layer name is `snake_case`, plural, English, equal to the dataset
name, and is used verbatim as `source-layer` in every layer spec and as `vector_layers[].id`
in TileJSON. Turkish source filenames (`parsel.geojson`, `kapı.geojson`) are renamed at
conversion (`parcels`, `doors`).
> **Why:** `source-layer` is a silent failure mode: a mismatch renders nothing and logs
> nothing. Keeping it equal to a name that also appears in the filename, the TileJSON and
> the layer id makes a mismatch visible in review. Non-ASCII additionally breaks tools that
> path-encode the name. Note that [STR-17] keeps Turkish domain terms as *identifiers in
> code*; that does not extend to tile layer names, which are a wire contract.

**[GIS-22] MUST:** Every dataset is served with a TileJSON document, and layer specs
reference it by `url` rather than a `tiles` template ([MAP-21]). The TileJSON carries
`tilejson`, `tiles`, `minzoom`, `maxzoom`, `bounds`, `center`, `attribution`, `scheme` and,
for vector data, `vector_layers` with each layer's `id`, `fields` and zoom range. These
values equal the archive's own metadata.
> **Why:** `bounds` and `maxzoom` are what stop MapLibre requesting tiles over the sea and
> above the pyramid, which is where 404 storms come from ([MAP-22]). `vector_layers[].fields`
> is the only machine-readable statement of which properties exist, so it is what a reviewer
> checks a filter expression against. A hand-written TileJSON that drifts from the MBTiles
> metadata is worse than none.

**[GIS-23] MUST:** A rebuilt archive is published under a new immutable path
(`/tiles/parcels/2026-08-14/`) and the TileJSON URL in runtime config is repointed; an
archive is never overwritten in place.
> **Why:** Tiles are cached for a day at nginx and in browsers ([MAP-23]). Overwriting an
> archive serves a mix of old and new tiles for that day, which appears as parcels that
> exist at one zoom and not at another. A new path makes the switch atomic and the rollback
> a config change ([GEN-09]).

---

## 7. Raster tiles and elevation

**[GIS-24] MUST:** Our tile service serves DEM tiles in **Mapbox Terrain-RGB** encoding
(`height = -10000 + (R * 65536 + G * 256 + B) * 0.1`) at 256 px, so every `raster-dem`
source omits `encoding` or sets `encoding: 'mapbox'` ([MAP-50]). A Terrarium-encoded archive
is converted at ingest, not declared at the source.
> **Why:** MapLibre cannot detect the encoding; it applies whichever the source declares.
> Two encodings in one deployment means one of the two DEM datasets is wrong and nobody
> knows which until the terrain looks strange, by which time the exaggeration has been
> "tuned" around the error.

**[GIS-25] MUST:** A consumer who suspects an encoding mismatch decodes one pixel with both
formulas and keeps the one that yields a plausible elevation for the area (Turkey: roughly
-20 m to 5,200 m). The finding is fixed at ingest, never patched in the frontend.

```ts
// Diagnostic only, for a console session against one tile pixel. Not shipped.
const terrainRgb = (r: number, g: number, b: number) => -10000 + (r * 65536 + g * 256 + b) * 0.1
const terrarium = (r: number, g: number, b: number) => r * 256 + g + b / 256 - 32768

// Reading Terrarium as Terrain-RGB: elevations in the hundreds of thousands of metres and a
// mesh that spikes into a wall at the first tile boundary.
// Reading Terrain-RGB as Terrarium: a nearly flat mesh with a large constant offset, and
// exaggeration that appears to do nothing.
```

**[GIS-26] MUST:** Raster and vector tile URLs use the **XYZ** scheme (`y` increasing
southwards, TileJSON `scheme: "xyz"`). An archive stored in TMS order (which is what raw
MBTiles holds) is served through a server that flips `y`, or its URL template uses `{-y}`.
The scheme is stated in the TileJSON.
> **Why:** A y-flip is not an error, it is a mirror: tiles load, nothing 404s, and the
> district renders flipped about the equator, so at latitude 41 the sea appears where the
> hills should be. `tileserver-gl`, `martin` and `pg_tileserv` all serve XYZ from MBTiles; a
> hand-written handler reading the file directly does not.

**[GIS-27] MUST:** A raster source declares `tileSize` matching the archive (**256** for DEM
and GDAL-produced overviews, **512** for basemap raster designed for it), and retina is
served by an `@2x` variant at the same nominal tile size, never by misdeclaring `tileSize`.
> **Why:** `tileSize` is how MapLibre maps a tile to a zoom level. Declaring 512 for 256 px
> tiles shifts the whole pyramid by one zoom: labels come out half size and the raster is
> soft everywhere. The reference project's hillshade archive is 256 px, z9 to z14, and
> declares exactly that ([MAP-51]).

**[GIS-28] MUST:** Raster tiles whose transparency carries information (hillshade overlays,
masks) are PNG; fully opaque imagery (satellite, orthophoto) is WebP. Lossy WebP is not used
where alpha is meaningful.
> **Why:** Lossy WebP quantises the alpha channel, which fringes a hillshade overlay with
> grey halos along every slope edge; the reference project hit exactly this and reverted to
> PNG. On opaque orthophoto, WebP is 25 to 35 % smaller than JPEG at the same visual quality,
> which is the difference between a smooth pan and a stuttering one.

---

## 8. Style JSON, sprites and glyphs

**[GIS-29] MUST:** The map style is served by our tile service at a versioned, same-origin
URL taken from runtime config (`config.mapStyleUrl`, for example
`/tiles/styles/municipal-light/v7/style.json`) with `Cache-Control: no-cache` on the JSON
([MAP-23]). Style JSON is not committed to the frontend repository and not built into the
bundle.
> **Why:** The style names sources, glyph and sprite URLs that are deployment-specific
> ([GEN-09]). A style in the bundle means a frontend release to change a colour; a style
> edited in place means half the users hold a style referencing a source the service no
> longer has.

**[GIS-30] MUST:** Sprites are self-hosted next to the style
(`"sprite": "/tiles/styles/<name>/<version>/sprite"`) with `sprite.png`/`sprite.json` **and**
`sprite@2x.png`/`sprite@2x.json` present. Icons added at runtime go through `map.addImage`
([MAP-13]) instead of being appended to the sprite.
> **Why:** MapLibre requests `sprite@2x` on any device with `devicePixelRatio > 1`; if it
> 404s the map falls back to blurry 1x icons on every retina screen, which is most laptops.
> Keeping runtime icons out of the sprite means a new feature icon does not require
> regenerating and redeploying the style.

**[GIS-31] MUST:** Glyph PBFs are self-hosted (`"glyphs": "/tiles/fonts/{fontstack}/{range}.pbf"`)
from a font whose Latin Extended-A coverage includes `ı İ ğ Ğ ş Ş ç Ç ö Ö ü Ü`, and the
`0-255` and `256-511` ranges are verified present for every fontstack the style names.
> **Why:** Glyph ranges are fetched lazily per 256-codepoint block. A font missing the
> `256-511` block renders `İ` and `ğ` as boxes, and only in the labels that contain them, so
> it survives review of a screenshot of one district and fails in the next. Cross-ref:
> [MAP-15] for the casing rule that goes with it, [I18N-14] for Turkish casing generally.

**[GIS-32] MUST:** A style change that adds or renames a source, a `source-layer` or an
anchor layer ([MAP-05]) is published as a new style version path and coordinated with the
frontend release that expects it.
> **Why:** The frontend inserts its layers relative to anchors that must exist in the style.
> Renaming `anchor-below-labels` on the tile service silently moves every feature layer to
> the top of the map, for every deployed client, at once.

---

## 9. Geometry operations in the browser

**[GIS-33] MUST:** Geometry maths in the browser uses individual `@turf/<fn>` packages
(`@turf/area`, `@turf/length`, `@turf/bbox`, `@turf/center`, `@turf/distance`,
`@turf/boolean-point-in-polygon`); the `@turf/turf` meta package is forbidden ([PERF-06],
[VER-05]).
> **Why:** `@turf/turf` pulls all 100+ modules, roughly half a megabyte minified, for one
> `area()` call. Individual packages are 2 to 10 KB each and tree-shake cleanly.

**[GIS-34] MUST:** Browser-computed measurements are **UI-only**: a drawn measurement, a live
length readout while dragging, a bbox for a request. Any figure that is stored, invoiced,
printed on a document or compared against a legal limit is computed server-side with PostGIS
`geography` and returned by the API.
> **Why:** turf and PostGIS use different ellipsoid maths, so they disagree by fractions of a
> percent, which for a 30 hectare parcel is hundreds of square metres. Two authorities for
> one number is a dispute the software loses. The browser also measures the *simplified*
> geometry it received ([GIS-19]); the server measures the real one.

**[GIS-35] MUST:** `@turf/area` and `@turf/length` are called on 4326 GeoJSON directly (they
are geodesic and return m² and metres); coordinates are never converted to 3857 first, and
`@turf/distance` is called with an explicit `{ units: 'meters' }`.
> **Why:** Measuring in the 3857 plane overstates area by the square of the Mercator scale
> factor: at latitude 41 that is about 1.77, so a 1 hectare parcel reports as 1.77 hectares.
> Several turf functions default to kilometres, so an omitted `units` option is a silent
> factor of 1,000.

---

## 10. Area, length and elevation display

**[GIS-36] MUST:** Areas and lengths are displayed with these thresholds, computed from the
metre value and formatted with `Intl.NumberFormat` for the active locale:

| Quantity | Range | Unit | Fraction digits |
|---|---|---|---|
| Area | < 10,000 m² | m² | 0 |
| Area | 10,000 m² to < 1,000,000 m² | ha (÷ 10,000) | 2 |
| Area | ≥ 1,000,000 m² | km² (÷ 1,000,000) | 2 |
| Length | < 1,000 m | m | 0 |
| Length | ≥ 1,000 m | km (÷ 1,000) | 2 |
| Elevation | any | m | 0 |

> **Why:** Hectares are the unit Turkish municipal staff use for parcels and zoning, and
> "184300 m²" is unreadable where "18,43 ha" is not (Turkish uses a comma as the decimal
> separator, which `Intl` produces for `tr-TR` and hand-built strings do not). Fixed
> thresholds mean the same parcel shows the same unit in the table, the popup and the PDF
> export.

```ts
// src/shared/utils/geo/formatMeasure.ts
import type { TFunction } from 'i18next'

const M2_PER_HA = 10_000
const M2_PER_KM2 = 1_000_000

export function formatArea(areaM2: number, locale: string, t: TFunction): string {
  if (!Number.isFinite(areaM2) || areaM2 < 0) {
    throw new Error(`formatArea: invalid area ${areaM2}`)
  }
  const nf = (digits: number) => new Intl.NumberFormat(locale, { maximumFractionDigits: digits })
  if (areaM2 >= M2_PER_KM2) return `${nf(2).format(areaM2 / M2_PER_KM2)} ${t('units.km2')}`
  if (areaM2 >= M2_PER_HA) return `${nf(2).format(areaM2 / M2_PER_HA)} ${t('units.ha')}`
  return `${nf(0).format(areaM2)} ${t('units.m2')}`
}
```

**[GIS-37] MUST:** Unit symbols come from i18n keys (`units.m2`, `units.ha`, `units.km2`,
`units.m`, `units.km`), never from a string literal in code, and superscripts are the real
characters (`m²`, `km²`), not `m2`.
> **Why:** [GEN-14] applies to units too, and a screen reader announces `m2` as "em two"
> while it announces `m²` as "square metres". Cross-ref: [I18N-03], [I18N-11].

---

## 11. Address search and geocoding

**[GIS-38] MUST:** Geocoding, reverse geocoding and address autocomplete go through our own
backend endpoint (`GET /api/geocode?q=`), never directly to Nominatim, Google, Mapbox or any
other third-party geocoder from the browser.
> **Why:** [GEN-22] (same origin) and [GEN-10] (no keys in the browser) both apply, and
> Nominatim's usage policy forbids autocomplete traffic from an application. Beyond
> compliance, the municipality's own address data (neighbourhood, cadastral block and parcel, door number) is
> better than any public geocoder inside its own borders, and only the backend has it.

**[GIS-39] MUST:** Search input is debounced **300 ms**, requires at least **3 characters**,
aborts the previous request with `AbortController`, and shows an explicit empty state for no
results.
> **Why:** Typing a district name at five characters a second is ten requests without a
> debounce and one with. 300 ms is below the point where typing feels laggy and above the
> fastest inter-keystroke interval, so it collapses a word into one request. Two characters
> match thousands of streets and return a list nobody can use. Cross-ref: [API-34], [STA-20].

**[GIS-40] MUST:** Turkish text normalisation for search (case folding of `ı/I` and `i/İ`,
optional diacritic folding) happens **server-side**; the client sends the raw query string
unmodified.
> **Why:** `'ISTANBUL'.toLowerCase()` in JavaScript yields `istanbul`, while
> `'istanbul'.toLocaleUpperCase('tr')` yields `İSTANBUL`. Folding on the client and matching
> on the server under a different collation produces results the user cannot predict. One
> collation, in the database, is the only way the same query returns the same rows.
> Cross-ref: [I18N-14].

---

## 12. Attribution and licensing

**[GIS-41] MUST:** Every source that requires attribution carries it in its own
`attribution` field (in TileJSON, or on the source object for a `tiles`-array source), and
MapLibre's `AttributionControl` is present and not hidden by CSS.
> **Why:** OpenStreetMap-derived tiles are ODbL: attribution is a licence condition, not a
> courtesy, and removing it makes the deployment non-compliant. Per-source attribution is
> what keeps the control correct when a layer is toggled off.

**[GIS-42] MUST:** `docs/data-sources.md` lists every dataset in the deployment with: source
organisation, licence, acquisition date, source CRS, the ingest command, refresh cadence and
whether redistribution is permitted. A dataset with no entry is not deployed.
> **Why:** Municipal handovers arrive on a disk with no metadata. Six months later nobody can
> say whether the parcel layer may be shown to the public, and the question reaches the team
> as a legal one with a deadline. The CRS and the ingest command in the same file are what
> make the next refresh reproducible ([GIS-19], [GIS-20]).

**[GIS-43] MUST:** Geodata containing personal data (address points tied to residents,
subscriber locations, complaint locations) is served only to permitted roles, and any public
layer derived from it is aggregated to a neighbourhood or a 100 m grid, never published as
points.
> **Why:** A point layer of "waste collection complaints" is a map of who complained about
> their neighbours. Coordinate precision is itself identifying: six decimals is a doorway.
> Permission enforcement is server-side ([SEC-16]); the frontend hiding the layer is UX, not
> a control. Cross-ref: [OBS-17] for the logging side.

---

## 13. Large dataset intake checklist

Run this before a new dataset reaches a layer spec. Every item is answered in the PR
description or in `docs/data-sources.md`.

1. **Provenance and licence recorded** in `docs/data-sources.md`: organisation, licence,
   acquisition date, redistribution permission ([GIS-42]).
2. **Source CRS identified and reprojected to 4326 server-side**, with the `ST_Transform`
   command recorded; the output carries no `crs` member ([GIS-08], [GIS-11]).
3. **Geometry validated**: `mapshaper -verify` clean, right-hand winding, no null geometries,
   polygons typed `MultiPolygon` where they may gain parts ([GIS-10], [GIS-12]).
4. **Stable ids present** as both the `id` member and `properties.id`, traceable to the source
   system's key; `--generate-ids` not used ([GIS-14]).
5. **Properties flattened, trimmed and schema'd**: only fields the UI uses, flat primitives, a
   committed zod schema ([GIS-13]).
6. **Size measured**: feature count and serialised bytes recorded. Under 5,000 features and
   2 MB it may be a committed GeoJSON; otherwise it is tiles ([GIS-18], [GEN-19]).
7. **Coordinates rounded to 6 decimals** at write time (`mapshaper -o precision=0.000001`)
   ([GIS-03]).
8. **Tiling command committed** under `deployments/map/converts/` with `-l <layer>`, `-zg`,
   `--drop-densest-as-needed`, `--extend-zooms-if-still-dropping` and the source file's date
   in a comment ([GIS-20]).
9. **TileJSON published** with `bounds`, `minzoom`, `maxzoom`, `vector_layers`, `scheme` and
   `attribution` matching the archive metadata, under a versioned immutable path ([GIS-22],
   [GIS-23]).
10. **Rendering verified at both ends of the zoom range**: the layer's `minzoom` is where the
    data becomes legible, no 404s in the network panel at maximum zoom, the feature count at a
    known bbox matches the source table, and `feature-state` hover still selects the same
    feature after a rebuild ([MAP-22], [GIS-14]).

---

## Open questions

- **Automated GeoJSON validation in CI.** No validator is committed. The candidates are a
  `mapshaper -verify` step (needs the package in devDependencies, so [VER-06] approval), a
  zod-only check that validates structure but not topology, or a server-side `ST_IsValid`
  gate at ingest that never lets a bad file reach the repository. The ingest gate is
  preferred because it also covers data that never becomes a file, but it belongs to the
  backend standard. Decide when the first invalid geometry reaches production; until then
  [GIS-12] is verified by hand and recorded in the intake checklist.
- **Imperial units.** [GIS-36]'s thresholds are absolute, not locale-keyed. If an
  English-locale deployment ever needs acres and miles, they become locale-keyed.
- **DMS coordinate display.** Some surveying workflows expect degrees/minutes/seconds. Not
  implemented; add a formatter under `src/shared/utils/geo/` behind a user preference if a
  second deployment asks for it.
