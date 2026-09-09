# ADR-0007 — Input validation: manual, in the handler layer

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [SEC-12], [SEC-12b], [VER-09], [API-06], [API-07], [API-11]

## Context

Input must be validated at every write endpoint ([SEC-12]). Gin **already pulls in**
`go-playground/validator` as a transitive dependency, and it offers declarative validation
via struct tags like `binding:"required,max=255"`.

So this decision is not "should we pull in an extra package", it is **"should we use what
we already have"**. The reasoning has to be built around that.

## Options

### A) Manual validation, with shared helpers (CHOSEN)
**Strengths:** Compatible with the pointer/tri-state design ([API-06], [API-07],
[API-11]). Error messages are in Turkish, contextual, and fully under our control
([API-15]). Validation order and short-circuit behavior are explicit. The `pkg/validator.go`
helpers (`ValidateUUID`, `maxLen`, `nonNegative`, `ValidateCoordinates`) collect the
repetition.
**Weaknesses:** An explicit check line per field; handlers get longer.

### B) `binding:"..."` struct tags
**Strengths:** Short, declarative, rules visible on the DTO, less code duplication.

**Weaknesses, and decisive:** for `required`, **the value type's zero value counts as
"missing".** `{"latitude": 0}` is treated the same as "latitude was never sent". This is
the exact opposite of the distinction at the center of this standard:

> [API-07]: a field whose absence must be noticeable becomes a **pointer** even when
> required, because in the request `{"name":"X","latitude":41.19}` (no longitude),
> `longitude` silently became `0` and moved the point into the ocean off Ghana.

`required` works correctly on pointer fields (nil check). But then half the validation is
in the tag and half is in code, and "which goes where" gets re-argued on every PR.
Error messages also come in English and in field-path form; a separate translation layer
is needed to show them to a client.

### C) Both together
**Strengths:** Simple field rules in tags, business rules in code.
**Weaknesses:** Where the line falls gets re-argued every time. The whole point of a
standard is to end exactly that argument.

## Decision

**Manual validation.** One consistent path. The decisive reason is technical: `required`
semantics **do not fit** the pointer/tri-state design, and that design came out of a real
production incident.

## Accepted costs

- Handlers are longer; validation lines repeat.
- It is possible to **forget** to validate a field. Countermeasures: the [SEC-12] minimum
  check table, the [SEC-13] two-layer defense (handler + schema), [TEST-08] boundary-value
  tests.

## What would change this decision

- If the need for pointer/tri-state in DTOs disappears (e.g. partial updates move to a
  separate mechanism like JSON Merge Patch), tag-based validation is reconsidered.
- If validation code duplication is shown to be a measurable source of bugs (the same bug
  class repeating across multiple services), a hybrid approach is discussed.
