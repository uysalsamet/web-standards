# ADR-0015 — Forms: react-hook-form + zod, with React 19 actions allowed for trivial forms

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [FORM-01], [FORM-02], [FORM-05], [FORM-09], [GEN-07], [API-22], [VER-05]

## Context

A municipal application is mostly forms: a parking record has 14 fields, a building inspection
form has 40 across five steps, a permit application has conditional sections. These forms need
things a `useState` per field does not give:

- **Validation shared with the API contract.** The request body is already described by a zod
  schema ([API-22]); the form must not invent a second, weaker set of rules.
- **Server field errors.** A 422 carries `details: [{ field, code, message }]` and each one has
  to land on its field ([FORM-09]).
- **Dirty tracking**, because navigating away from a half-filled inspection form must warn
  ([FORM-14]).
- **Turkish input reality**: decimal comma, TCKN and IBAN checksums, plate normalisation. These
  are transforms and refinements, not simple `required` flags.
- **Render cost.** A 40-field form that re-renders every field on every keystroke is a
  measurable INP problem on the hardware actually used at counter windows.

The reference codebase has forms in three shapes: controlled `useState` per field, an ad-hoc
`useForm`-like custom hook, and one `FormData` read on submit. They validate differently, show
errors differently, and none of them handles a 422 on a field.

## Options

### A) react-hook-form 7 + zod 4 via `@hookform/resolvers/zod` (CHOSEN)

**Strengths:**
- Uncontrolled by default (`register` attaches a ref), so typing in one field re-renders that
  field's error subscriber, not the form. Measured on a 40-field form this is the difference
  between roughly 40 component renders per keystroke and about 1.
- `zodResolver` lets the **same schema** validate the form and the request body, so
  [FORM-02] is a two-line derivation (`ParkingCreateSchema.extend({ ... })`) rather than a
  parallel rule set.
- zod is already a dependency and already mandatory at the API boundary ([GEN-07]). No new
  validation vocabulary enters the codebase.
- `setError(path, ...)` accepts the same dotted paths the backend sends
  (`contacts.1.phone`), so [FORM-09] is a mapping, not a translation layer.
- `useFieldArray` covers repeated sections (contacts, attachments, parcel list) without custom
  state.
- `formState.isDirty`, `isSubmitting`, `errors` are exactly the inputs the unsaved-changes
  blocker ([FORM-14]) and the submit lock ([FORM-11]) need.
- Both libraries are in wide use, so AI agents generate correct code for them at a high rate,
  which matters for a standard consumed primarily by agents.

**Weaknesses:**
- Two libraries and a resolver adapter (about 14 KB gz for react-hook-form; zod is already
  paid for). A trivial one-field form does not earn that.
- The uncontrolled model leaks: any component that must render a formatted value
  (`NumberInput`, a date picker, a map coordinate field) needs `<Controller>`, which is a
  second wiring pattern in the same file.
- Transforming schemas need three type parameters (`useForm<z.input<S>, unknown, z.output<S>>`)
  or the submit handler is silently mistyped ([FORM-05]). This is a real trap and the reason
  that rule exists.
- `shouldUnregister` defaults surprise people in multi-step forms ([FORM-32]).

### B) Formik

**Strengths:** Very widely known; `<Field>` API is easy to read; large body of examples.
**Weaknesses:** Fully controlled, so every keystroke re-renders the whole form, which is the
performance problem this decision exists to avoid; maintenance has been slow (long gaps between
releases and an open React 19 compatibility tail); Yup is its native validation partner, which
would add a second schema library alongside the zod that [GEN-07] already mandates.

### C) React 19 native form actions only (`<form action>` + `useActionState` + `useFormStatus`)

**Strengths:** Zero dependencies; the pending state and the reset-on-success behaviour come from
the platform; progressive enhancement is free; it is the direction the framework is moving.
**Weaknesses:** In a client-only SPA with no server functions ([GEN-01]) the action is just an
async callback, so almost nothing is gained. There is no field-level validation state, no
`touched` tracking, no `isDirty`, no per-field error placement and no field arrays; all of that
would be rebuilt by hand. Reading values through `FormData` loses types, and every non-native
control (combobox, map picker, file list) needs a hidden input to participate.

### D) TanStack Form 1.x

**Strengths:** Type inference is the best of the four, first-class zod/standard-schema support,
framework agnostic, actively developed, and it shares the TanStack Query mental model this
standard already uses.
**Weaknesses:** Not in the version table ([VER-05] gate), a much smaller ecosystem of examples,
and correspondingly weaker AI-agent output. Migrating 40+ existing forms buys type ergonomics we
do not currently lack, since zod already types the values. The decision is close enough that it
is named in "what would change this decision" rather than dismissed.

## Decision

**react-hook-form 7 + zod 4 through `zodResolver` for every form with validation or more than one
field ([FORM-01]).** The decisive reasons are the shared schema with the request body ([API-22])
and the field-path error mapping ([FORM-09]); the render-cost advantage is a bonus, not the
argument.

**React 19 form actions are permitted for trivial forms**, and the boundary is fixed here so it
is not renegotiated per PR. A form may use `<form action>` + `useActionState` when **all** of the
following hold:

- at most two fields;
- no field-level error display (a single form-level message is enough);
- no unsaved-changes protection needed (`isDirty` is not consulted);
- no server 422 field mapping (the endpoint either succeeds or fails as a whole);
- no `<Controller>`-style formatted or composite input.

Typical members of that set: a search box, a single-field rename dialog, a comment box, a
"reason for rejection" prompt. If a form later grows a third field or a field-level error, it
moves to react-hook-form; there is no hybrid.

## Accepted costs

- Two form mechanisms in one codebase. Bounded by the explicit five-condition list above; a PR
  that uses an action outside it is a review failure, not a judgement call.
- About 14 KB gz of react-hook-form in the main chunk, since forms appear on most routes and
  lazy-loading it per route would duplicate it across chunks.
- Two wiring patterns inside a single form file: `register` for native inputs, `<Controller>` for
  `NumberInput`, date pickers, comboboxes and the map coordinate field.
- The `z.input` / `z.output` typing trap on transforming schemas ([FORM-05]), which the compiler
  only catches if the three type parameters are written out.
- zod schemas carry i18n **keys** in `message`, not sentences ([FORM-07]), so a schema read in
  isolation does not show the user-facing text.

## What would change this decision

- **Server functions or an SSR/RSC framework entering the stack.** That would invert the
  calculus for option C, since actions would then run on the server and carry real progressive
  enhancement. It also contradicts [GEN-01], so it would be a stack decision first.
- **TanStack Form reaching the version table** with a demonstrated migration path and comparable
  agent-generation reliability. The trigger to measure: if [FORM-05]-class typing bugs (a
  transformed value mistyped at the submit boundary) appear in more than two PRs in a quarter,
  run a side-by-side on one real 40-field form.
- **react-hook-form stalling on a React major.** It is a single library on the critical path for
  every screen; a missed React release cycle would force the evaluation immediately.
- **A measured INP regression traced to `<Controller>`-heavy forms.** That would mean the
  controlled escape hatch is being used too widely and the input primitives need to be
  uncontrolled instead, not that the library is wrong.
