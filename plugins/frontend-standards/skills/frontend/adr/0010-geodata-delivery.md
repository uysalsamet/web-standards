# ADR-0010 — Geodata delivery: GeoJSON up to 5,000 features, MVT or PMTiles above

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-19], [MAP-19]..[MAP-27], [GIS-15]..[GIS-28], [PERF-22]

## Context

The same dataset can reach the browser four ways, and the right answer depends entirely on
size and update frequency, not on preference:

| Way | Shape |
|---|---|
| Static GeoJSON file under `public/data/` | One HTTP request, whole dataset, parsed on the main thread |
| GeoJSON from an API, filtered by bbox | One request per viewport, server-side filtering |
| Vector tiles (MVT) from a tile server | Many small requests, only the visible pyramid |
| PMTiles archive over HTTP range requests | One file on static storage, ranges fetched as needed |

The reference deployment has all four kinds of data at once: 25 neighbourhood polygons that
never change, 300 parking sites updated hourly, 480,000 cadastral parcels rebuilt nightly, and
a 2 GB drone orthophoto refreshed annually. A single answer for all of them is wrong in three
cases out of four, so this record fixes the **thresholds**, not a single format.

The measurements that set the thresholds, taken on the reference app with a mid-range laptop:
a 40 MB parcel GeoJSON takes roughly 6 s to parse on the main thread, holds about 300 MB of
heap, and blocks input for the whole parse. The same parcels as MVT arrive in 20 to 60 KB
tiles, only for the visible viewport, decoded in MapLibre's worker.

## Options

### A) A size threshold: GeoJSON up to 5,000 features and 2 MB, tiles above (CHOSEN)

**Strengths:**
- Matches where the cost curve actually bends. Under a few thousand features, GeoJSON parse
  and client-side tiling are tens of milliseconds and a tile pipeline is pure overhead: a
  build step, a server, a cache and a versioned path for data that fits in one request.
- Two hard numbers instead of a judgement call, so the rule is mechanically checkable:
  `tools/check-standards.sh` fails on an oversized file under `public/data/` and the layer
  registry warns at runtime in development ([MAP-19], [GIS-18]).
- Small data keeps GeoJSON's advantages: `setData` for updates, features present as JavaScript
  objects, no `source-layer`, no rebuild to change a property.
- Large data gets the properties that only tiles have: viewport-scoped transfer, overzoom, a
  server-side simplification per zoom level, and an HTTP cache that works ([MAP-23]).
- Both feature count and bytes are checked, because they fail differently: 5,000 complex
  polygons blow the byte limit long before the count, and 50,000 points blow the count while
  staying small.

**Weaknesses:**
- A dataset near the threshold is unstable: 4,800 features today is 5,200 next quarter, and
  the format changes with it, which means a layer spec rewrite (`source-layer`, `promoteId`,
  `minzoom`) at an inconvenient time.
- The thresholds are calibrated on the reference hardware and network. They are conservative
  for a fibre-connected office and optimistic for a 3G tablet in the field.
- Two code paths for the same conceptual thing, so a feature's layer spec looks different
  depending on which side of the line its data is on.

### B) Always GeoJSON, simplify aggressively to stay small

**Strengths:** One format, one code path, no tile server, no build step, and features are
ordinary objects the whole time.

**Weaknesses:** Simplification cannot fix count: 480,000 parcels simplified to two vertices
each is still 480,000 features and about 30 MB. The parse is on the main thread ([PERF-22]
moves it to a worker but does not make it free), the whole dataset is downloaded to render one
neighbourhood, and the cache entry is invalidated wholesale on every nightly rebuild. This is
the reference codebase's current behaviour for its largest layers and it is the problem being
solved.

### C) Always MVT, no GeoJSON anywhere

**Strengths:** One format, one code path, consistent performance, and no dataset can ever be
the wrong shape.

**Weaknesses:** Every dataset needs a build step and a server before it can be shown, so a
25-polygon neighbourhood layer costs a `tippecanoe` run, an archive, a versioned path and a
TileJSON. Live and frequently changing data is worse: tiles are baked, so a layer that changes
every few minutes needs either dynamic tiles from PostGIS (a different server) or a rebuild
loop. Vector tiles also lose exact geometry (coordinates are quantised to the tile grid), which
is wrong for anything the user edits or measures against.

### D) Always PMTiles

**Strengths:** No tile server at all: one file on nginx or object storage with range requests.
Operationally the cheapest thing that scales.

**Weaknesses:** The whole archive is rebuilt for any change, so daily-updating data means a
daily multi-gigabyte rebuild and a full cache invalidation. Range requests need the serving
path configured correctly (`proxy_buffering off`, [MAP-27]), and a misconfiguration downloads
the entire archive per tile with no error message. Client-side protocol registration adds a
package ([02](../02-TECH-VERSIONS.md)) and a code path that a plain tile URL does not need.

### E) Always raster tiles (pre-rendered images)

**Strengths:** Simplest possible client, works without WebGL, cheapest to render.

**Weaknesses:** No interaction (no hover, no click-to-select, no `feature-state`), no client
styling, no dark mode without a second pyramid, blurry between zoom levels, and a style change
means re-rendering the whole pyramid. Raster remains right for imagery and hillshade
([GIS-27], [GIS-28]), which is data that genuinely is a picture, and wrong for anything the
user interacts with.

## Decision

**Threshold-based, with the format chosen by size and update frequency:**

| Condition | Delivery |
|---|---|
| ≤ 5,000 features **and** ≤ 2 MB, changes rarely | Static GeoJSON under `public/data/` ([GIS-18]) |
| ≤ 5,000 features **and** ≤ 2 MB, changes often, or is user-filtered | GeoJSON from the API, fetched by bbox ([GIS-15]) |
| Above either limit, rebuilt daily or more often | MVT from the tile service, referenced by TileJSON ([MAP-21]) |
| Above either limit, static (rebuilt monthly or less), large | PMTiles over range requests ([MAP-27]) |
| Imagery, orthophoto, hillshade, DEM | Raster or `raster-dem` tiles ([GIS-24], [GIS-27]) |

Tile server candidates, all serving MVT from the same archives:

- **tileserver-gl**: what the reference deployment runs. Serves MBTiles, raster and vector,
  plus style JSON, glyphs and sprites from one process, which is why it is the default: it
  covers [GIS-29]..[GIS-31] as well. Node, moderate throughput, fine behind an nginx cache.
- **Martin**: Rust, serves MVT directly from PostGIS tables and functions, so a
  frequently changing layer needs no rebuild at all. The right choice when data changes faster
  than a nightly tiling run. Does not serve styles, glyphs or sprites.
- **pg_tileserv**: Go, same PostGIS-direct model as Martin, simpler configuration, smaller
  feature set.
- **Static PMTiles on nginx**: no server process. Correct for the orthophoto case.

Any of these is acceptable; the choice is per dataset and belongs to the deployment, because
the frontend sees only a TileJSON URL under `/tiles/` ([MAP-21], [MAP-23]).

## Accepted costs

- **Two client code paths.** A `geojson` source and a `vector` source differ in the layer spec
  (`source-layer`, `promoteId` shape, `minzoom`) and in how updates work (`setData` versus
  rebuild). Developers must know which one they are on, and a feature that crosses the
  threshold is a real edit.
- **A tiling pipeline to maintain.** Committed conversion scripts, a versioned archive path,
  a TileJSON that must match the archive metadata, and a rebuild schedule ([GIS-20], [GIS-22],
  [GIS-23]). That is infrastructure that would not exist under option B.
- **Exact geometry is lost above the threshold.** MVT quantises coordinates to the tile grid,
  so a parcel measured from tiles is not the parcel in the database. [GIS-34] already forbids
  authoritative measurement in the browser, so this is consistent, but it does mean editing
  workflows must fetch the exact geometry by id rather than reading it from the rendered
  feature.
- **The threshold is a cliff, not a ramp.** A dataset that grows past 5,000 features requires
  work at the moment it grows, which is usually not the moment anyone planned for.
- **Staleness on rebuilt archives.** Immutable versioned paths ([GIS-23]) mean the frontend's
  runtime config has to be repointed on each rebuild, so a data refresh touches deployment
  configuration.

## What would change this decision

- A measurement showing the GeoJSON limit is wrong on current hardware in either direction. If
  a 10,000-feature collection parses in 40 ms on the target machines, the threshold rises and
  several datasets come back out of the tile pipeline.
- MapLibre gaining a streaming or incremental GeoJSON source that parses off the main thread
  by default, which would move the bend in the cost curve.
- Adoption of PostGIS-direct tiles (Martin or pg_tileserv) for the frequently changing layers,
  which would collapse the "rebuild daily" row into "always current" and remove the archive
  versioning cost for those datasets. This is the most likely revision.
- A requirement to run fully offline on a client machine with no tile service, which would
  push everything toward PMTiles files shipped with the deployment.
