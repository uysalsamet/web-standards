# ADR-0016 — Primary database: PostgreSQL

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [DB-05], [DB-08], [GEN-06], [ASYNC-03]

## Context

The services' persistent data store. Per [GEN-06], every service owns its own schema, but
they can physically share the same Postgres instance (with different schemas/databases).

## Options

### A) PostgreSQL 18 (CHOSEN)
**Strengths:** Relational integrity ([DB-07] FK, [DB-08] CHECK), the standard's principle
of "business rules also live in the schema" rests on this. Semi-structured data via
`jsonb`, `GENERATED` columns ([DB-09]), CTEs, window functions, a job queue via
`FOR UPDATE SKIP LOCKED` ([ASYNC-03]), full-text search, and first-class geospatial data
via **PostGIS** ([the PostGIS appendix](../APPENDIX-GIS-POSTGIS.md)). Permissive license.
A mature ecosystem.
**Weaknesses:** No built-in horizontal write scaling. A process-per-connection model makes
PgBouncer mandatory in a multi-service setup ([DB-03]).

### B) MySQL / MariaDB
**Strengths:** Very widely used, simple replication.
**Weaknesses:** Geospatial support is not at PostGIS's level. A weaker `jsonb`
counterpart. CHECK constraint support has historically been troubled. Many of the features
our rule set depends on are either missing or weak.

### C) MongoDB
**Strengths:** Schemaless flexibility, easy horizontal scaling.
**Weaknesses:** **Conflicts with this standard's core assumption**: [GEN-22], "business
rules also live in the schema". A system without schema enforcement has no `NOT NULL`,
`CHECK`, or FK, data consistency falls entirely on the application layer, and the [DB-07]
case shows exactly why that is not enough.

### D) CockroachDB
**Strengths:** Postgres-compatible, distributed, automatic horizontal scaling.
**Weaknesses:** Our scale does not require it. Some Postgres features (including PostGIS)
are not fully supported. High operating complexity.

### E) ClickHouse, **as an addition for analytics**
**Strengths:** Column-oriented; far faster than Postgres for high-volume time-series/
telemetry queries.
**Weaknesses:** Not suited for transactions or single-row updates. **Does not replace
Postgres, it sits alongside it.**

## Decision

**PostgreSQL 18, as the primary data store.**

Most of the standard's database rules ([DB-05]...[DB-09]) rely on the integrity mechanisms
Postgres provides. Postgres also covers three separate needs in a single component:
relational data, geospatial data (PostGIS), and a job queue ([ASYNC-03]), a concrete gain
that reduces the number of components to operate.

**ClickHouse as an addition**, only when a genuine analytical workload exists
(aggregation over high-volume sensor/telemetry data), and even then alongside Postgres,
not in place of it.

## Accepted costs

- No horizontal write scaling; if we hit the limit, read replicas, partitioning, or
  sharding must be planned by hand.
- **PgBouncer is mandatory** in a multi-service setup ([DB-03]), one more component to
  operate.
- If an analytical workload arrives, a second data store (ClickHouse) and a data pipeline
  will be needed.

## What would change this decision

- If a single Postgres instance cannot keep up with write load: vertical scaling and a
  read replica first, then partitioning, and sharding/CockroachDB as a last resort.
- If time-series volume overloads Postgres, **ClickHouse** (or the TimescaleDB extension)
  is added via a separate ADR.
