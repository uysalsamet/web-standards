# ADR-0002 — Go version line: 1.25.12

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [VER-01], [VER-03]

## Context

Go applies a "the last two major versions are supported" policy. As of 2026-08, the
supported lines are **1.26** (current) and **1.25**. All services must be on the same
version ([GEN-02]).

## Options

### A) Go 1.25.12 (CHOSEN)
**Strengths:** The previous line, matured. Meets Gin v1.12's `go 1.25.0` requirement. The
whole ecosystem already supports this version.
**Weaknesses:** Falls out of support when 1.27 ships (≈ February 2027), meaning an upgrade
must be planned within ~6 months.

### B) Go 1.26.5
**Strengths:** The current line; gets security patches for the longest, no upgrade
pressure.
**Weaknesses:** On a new major line, some libraries lag a few months behind.

## Decision

**1.25.12.** The project owner's preference; conservative and fully defensible. Thanks to
Go's backward-compatibility guarantee, the practical difference between the two lines is
small.

## Accepted costs

- Within ~6 months (when 1.27 ships), a version upgrade will become mandatory. Tracked in
  the quarterly review ([02](../02-TECH-VERSIONS.md)).
- The features that ship with 1.26 cannot be used.

## What would change this decision

- The moment Go 1.27 ships, 1.25 falls out of support, and **an upgrade is then mandatory**.
- If a dependency requires 1.26+, we upgrade immediately.
