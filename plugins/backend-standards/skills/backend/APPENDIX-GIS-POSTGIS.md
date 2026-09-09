# APPENDIX — GIS, PostGIS and Location Data

> **This file is optional.** It is only read if the project has geometry/map data.
> If there is no geometry, none of the rules here apply and none should be enforced.
>
> The rules **add to** the main standard; they do not replace it.

---

## 1. Setup

**[GIS-01] MUST:** The Postgres image is `postgis/postgis:18-3.6` ([VER-09]), and the
first step of the migration installs the extension:
```sql
-- +goose Up
CREATE EXTENSION IF NOT EXISTS postgis;
```

**[GIS-02] MUST:** All geometry is stored as **SRID 4326** (WGS84). Columns with mixed
SRIDs silently produce wrong results in operations such as `ST_Intersects`.

---

## 2. Choosing a geometry type — decide by measuring

**[GIS-03] MUST:** The column type is not chosen by looking at the source file's
`"type"` field. **First measure validity and part count:**

```sql
SELECT
  COUNT(*) FILTER (WHERE NOT ST_IsValid(g))                        AS invalid,
  COUNT(*) FILTER (WHERE ST_NumGeometries(
      ST_CollectionExtract(ST_MakeValid(g), 3)) > 1)               AS actually_multipart
FROM source;
```

**[GIS-04] MUST:** If even a **single record** in the source splits into multiple parts
once repaired, the column is set up as `MultiPolygon`. Single-part records are also
wrapped in a MultiPolygon, so the client does not have to branch on type.
> **Case:** The source said `"type": "Polygon"`; 10 of 265 areas were invalid, and once
> repaired, **all** of them split into 2-3 parts. These were not broken drawings but
> multipart areas squeezed into a single ring (the sum of the parts matched the source
> area exactly). Had `Polygon` been chosen, only bad options would have remained:
> dropping one of the parts (a 50 % area loss for one school) or deleting the record
> entirely.

---

## 3. Schema

```sql
CREATE TABLE IF NOT EXISTS facilities (
    id       UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    name     VARCHAR(255) NOT NULL,
    location GEOMETRY(MultiPolygon, 4326) NOT NULL,
    ...
    -- Only PostGIS can see a self-intersecting ring; the handler alone is not enough.
    CONSTRAINT facilities_location_valid CHECK (ST_IsValid(location))
);

-- A GIST index on the geometry column is MANDATORY: without it every spatial query does a full scan.
CREATE INDEX IF NOT EXISTS idx_facilities_location ON facilities USING GIST (location);
```

**[GIS-05] MUST:** Every geometry column has a **GIST index**.

**[GIS-06] MUST:** Every geometry column has a `CHECK (ST_IsValid(...))`.
> **Why:** The danger of invalid geometry is that it is **silent**: the record is
> written, the map renders, area is computed, but `ST_Intersects`/`ST_Contains` give
> the wrong answer, and this is only noticed months later.

**[GIS-07] MUST:** A `23514` (check violation) error is classified by constraint name
and the message states the **fix** ("do not merge the parts into a single ring").
Otherwise the client sees a meaningless "value out of range" error ([DB-20]).

---

## 4. Input validation

**[GIS-08] MUST:** Coordinate validation is done in the handler:

| Check | Why |
|---|---|
| Latitude `-90..90`, longitude `-180..180` | WGS84 boundary |
| `(0, 0)` is **rejected** | Null Island is in the Gulf of Guinea; almost never valid in any real dataset |
| Polygon ring is closed (first point == last point) and ≥ 4 points | An open ring makes PostGIS error out |
| Inside the project's bounding box | An out-of-bounds point in province/district data is a data error |

```go
// (0,0) is rejected: if accepted, the record is silently moved off the map and
// only a user looking at the map notices it.
func ValidateCoordinates(lat, lon float64) error {
	if lat < -90 || lat > 90 {
		return fmt.Errorf("latitude must be between -90 and 90, got: %v", lat)
	}
	if lon < -180 || lon > 180 {
		return fmt.Errorf("longitude must be between -180 and 180, got: %v", lon)
	}
	if lat == 0 && lon == 0 {
		return errors.New("coordinate (0,0) is not valid")
	}
	return nil
}
```

**[GIS-09] MUST:** A rejected geometry **does not corrupt the existing record**; the
validation happens before the write and is verified by a test.

---

## 5. API contract — GeoJSON

```json
{ "type": "FeatureCollection", "features": [
  { "type": "Feature",
    "geometry": { "type": "MultiPolygon", "coordinates": [...] },
    "properties": { "id": "…", "name": "…" } } ]}
```

**[GIS-10] MUST — Location lives ONLY inside `geometry`.** `properties` **does not
contain** `latitude`, `longitude`, `lat`, `lon`, `location`, `coordinates`.
> **Why:** Duplicated location data bloats the payload, and the two sources drift
> apart over time, making it unclear which one is correct ([PERF-09]).

**[GIS-11] MUST:** The map layer endpoint is separate and not paginated **but is
bounded**:
```
GET /<resource>/map?bbox=<minx,miny,maxx,maxy>
```
An endpoint that returns all geometry without a `bbox` can produce hundreds of MB in a
single request.

**[GIS-12] MUST:** Coordinate precision in the response is limited: `ST_AsGeoJSON(geom, 6)`
(≈ 10 cm). The default of 15 digits inflates the payload by 2-3x for no reason.

**[GIS-13] SHOULD:** For display-only layers, apply simplification based on zoom level
(`ST_SimplifyPreserveTopology`). **Raw geometry** is used for area/distance calculations.

---

## 6. Querying

**[GIS-14] MUST:** Spatial filters are written with `ST_Intersects` / `ST_DWithin`,
since these use the GIST index. `ST_Distance(...) < x` **does not use the index** and
does a full scan:
```sql
-- WRONG: the index is not used
WHERE ST_Distance(location, $1) < 500

-- CORRECT: the index is used
WHERE ST_DWithin(location::geography, $1::geography, 500)
```

**[GIS-15] MUST:** Distance/area calculations in metres are done by casting to the
`geography` type. A "distance" computed on `geometry` in 4326 is in **degrees** and
varies with latitude, silently producing a wrong result.

**[GIS-16] MUST:** Geometry is read with `ST_AsGeoJSON(location, 6) AS location`; raw
WKB is never returned to the outside.

---

## 7. Data migration and repair

**[GIS-17] MUST:** Repair (`ST_MakeValid`) is done **at seed-generation time**, not at
runtime. The seed is static SQL; the repaired result is written to the file.

**[GIS-18] MUST:** For existing installs, the migration order is: `ALTER COLUMN TYPE`
**first**, repair **after**. Reversing this order gives the error "Geometry type
(MultiPolygon) does not match column type (Polygon)".

**[GIS-19] MUST:** Migration and seed must produce the **same** result ([DB-16]).
`ST_MakeValid` computes new intersection points; if the seed rounds them with
`ST_AsGeoJSON(g, 9)` but the migration does not round, the two install paths diverge.
Apply the same round-trip in both.

---

## 8. Deriving business rules from source data

Institutional/municipal data carries a contract but does not write it down. Derive the
rules by measuring the source **before** setting up the schema.

**[GIS-20] SHOULD — Decision table:**

| Measurement | Meaning | Action |
|---|---|---|
| Rule holds 100 % | A real business rule | Enforce in the API (400), add a `CHECK` where possible |
| 100 % but only one value present | Not a rule, missing data | Do not add a `CHECK`; add the operational values to the schema up front |
| Small deviation (3/1245) | A legitimate exception to the rule | Examine the deviation; it is usually a more general rule |
| One field can be computed from the others | A derived field | Make it `GENERATED` or derive it server-side; **do not accept it** from the client ([DB-09]) |

**[GIS-21] MUST:** A field that carries only **a single value** in the source is not
discarded as "unnecessary": the data exists, there is simply no variety. A field to
skip is one with **no value in any record**.

**[GIS-22] MUST NOT:** Adding an empty column on the assumption "it will be filled
later." This creates the impression that "data exists but isn't showing." Write the
rationale in a schema comment; adding it later, when needed, is a one-line migration.

**[GIS-23] MUST NOT:** Squeezing a raw value and a derived value into a single column.
If you keep the raw value, filters miss records; if you keep the normalized value, the
original spelling from the source document is lost. Keep them in separate columns, and
do not accept the derived one from the client.

---

## 9. NEVER DO THIS — GIS

- ❌ Choosing the geometry type by looking at the source's `"type"` field, without measuring it
- ❌ Accepting geometry without a `CHECK (ST_IsValid(...))`
- ❌ Forgetting the GIST index on a geometry column
- ❌ Using mixed SRIDs
- ❌ Accepting the `(0,0)` coordinate
- ❌ Duplicating coordinates inside `properties`
- ❌ Opening an endpoint that returns all geometry without a `bbox`/bound
- ❌ Returning coordinates at full precision (15 digits)
- ❌ Filtering with `ST_Distance(...) < x` (does not use the index)
- ❌ Computing distance in metres without a `geography` cast
- ❌ Doing repair at runtime
- ❌ Repairing geometry before `ALTER COLUMN TYPE`
- ❌ Using different precision in the seed versus the migration
