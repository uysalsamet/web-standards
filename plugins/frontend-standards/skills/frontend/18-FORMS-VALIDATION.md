# 18 — Forms and Validation

> One way to build a form: react-hook-form for state, zod for the rules, one schema per form,
> and the same schema that validates the request body ([API-22]). This file covers validation,
> server-side field errors, the input types that go wrong in a Turkish municipal application
> (numbers with a decimal comma, TCKN, IBAN, plates, coordinates), unsaved-changes handling and
> form UX.
>
> Out of scope: the API client and error envelope ([04](04-API-CLIENT.md)), upload security
> ([06](06-SECURITY.md) §10), keyboard and ARIA baseline ([16](16-ACCESSIBILITY-UX.md)),
> mutation and cache invalidation mechanics ([05](05-STATE-AND-DATA.md) §2).

---

## 1. The stack and the schema

**[FORM-01] MUST:** Every form with more than one field, or any validation at all, uses
`react-hook-form` with `zodResolver` from `@hookform/resolvers/zod`. No hand-rolled
`useState` per field, no `Formik`, no uncontrolled `FormData` reads in application code.
> **Why:** Per-field `useState` re-renders the whole form on every keystroke (measurable INP
> damage above about 15 fields), and every such form reimplements touched-state, error display
> and submit locking slightly differently. Detail: [ADR-0015](adr/0015-forms.md).

A React 19 form action (`<form action={fn}>` with `useActionState`) is permitted **only** for a
trivial form: at most two fields, no field-level error display, no unsaved-changes protection,
no server field-error mapping. A search box, a single-field rename dialog, a comment box.
Anything else is react-hook-form. The boundary is written down in [ADR-0015](adr/0015-forms.md)
so it is not renegotiated per PR.

**[FORM-02] MUST:** One schema per form, and where the form produces a request body that schema
**is** the DTO request schema from `api/<name>Schemas.ts` ([API-22]), extended with `.extend()`
or narrowed with `.refine()` for UI-only fields and cross-field rules.
> **Why:** Two schemas for the same payload drift: the form allows a 300 character name, the
> backend allows 200, and the user discovers it after filling twelve fields. Deriving the form
> schema from the request schema makes the wire contract the floor and the UI rules an addition.

```ts
// src/features/Parking/api/parkingSchemas.ts
export const ParkingSchema = z.object({
  id: z.string(),
  name: z.string().min(3).max(200),
  capacity: z.number().int().min(0).max(10_000),
  hourlyRate: z.number().min(0),
  location: PositionSchema,                      // [lng, lat] ([API-20])
  updatedAt: z.iso.datetime(),
})
export const ParkingCreateSchema = ParkingSchema.omit({ id: true, updatedAt: true })
export type ParkingCreate = z.infer<typeof ParkingCreateSchema>
```

```ts
// src/features/Parking/components/parkingFormSchema.ts
import { ParkingCreateSchema } from '../api/parkingSchemas'

// UI-only: a confirmation checkbox that is never sent. The wire schema stays untouched.
export const ParkingFormSchema = ParkingCreateSchema.extend({
  confirmPublic: z.boolean(),
}).refine((v) => !v.confirmPublic || v.hourlyRate > 0, {
  message: 'validation.publicRequiresRate',
  path: ['hourlyRate'],            // a cross-field error must land on a field, not on the root
})
export type ParkingFormValues = z.infer<typeof ParkingFormSchema>
```

**[FORM-03] MUST:** The form schema lives next to the form component
(`components/<name>FormSchema.ts`), is named `<Name>FormSchema`, and its inferred type is
`<Name>FormValues` ([STR-14] naming).

**[FORM-04] MUST:** `useForm` is configured with `mode: 'onTouched'` and
`reValidateMode: 'onChange'`.
> **Why:** `onChange` from the first keystroke shows "e-mail is invalid" while the user is
> typing the second character of their address, which reads as the app arguing with them.
> `onSubmit` only, the RHF default, hides a problem until the user has left the field far behind.
> Validate when the field is left, then correct live while they fix it.

```tsx
const form = useForm<ParkingFormValues>({
  resolver: zodResolver(ParkingFormSchema),
  mode: 'onTouched',
  reValidateMode: 'onChange',
  values: parking ? toFormValues(parking) : undefined,   // [FORM-15]
  shouldUnregister: false,                               // [FORM-32]
})
```

**[FORM-05] MUST:** When the schema transforms (`z.coerce`, `.transform()`), the form is typed
with both sides: `useForm<z.input<typeof S>, unknown, z.output<typeof S>>`. `any` and casts on
`handleSubmit` are forbidden ([TS-05]).
> **Why:** With a transform, the value the input holds and the value the submit handler receives
> are different types. A single type parameter makes one of the two silently wrong, usually the
> submit handler, and the mutation receives a string where the API expects a number.

---

## 2. Rendering fields and errors

**[FORM-06] MUST:** Every control has a programmatically associated visible `<label>`, and
errors are rendered by the shared `FieldError` component, which wires `aria-describedby` and
`aria-invalid` ([A11Y-06], [A11Y-21]).
> **Why:** A red border alone is invisible to a screen reader and to a colour-blind user. Without
> `aria-describedby` the error text exists in the DOM but is never announced when focus reaches
> the field, so the user hears "Capacity, edit text" and nothing about why the form refused.

```tsx
// src/shared/components/FieldError.tsx
import { useTranslation } from 'react-i18next'
import type { FieldError as RhfFieldError } from 'react-hook-form'

interface FieldErrorProps {
  /** Must match the input's aria-describedby. */
  id: string
  error: RhfFieldError | undefined
}

export function FieldError({ id, error }: FieldErrorProps) {
  const { t } = useTranslation()
  // Reserve the line height even when empty: an error appearing must not push the rest of the
  // form down ([A11Y-18]).
  if (!error?.message) return <p id={id} className="min-h-5" />
  return (
    <p id={id} className="min-h-5 text-sm text-danger" role="alert">
      {/* zod messages are i18n keys, not sentences ([FORM-07]). */}
      {t(error.message, { defaultValue: error.message })}
    </p>
  )
}
```

```tsx
// Usage. The three attributes always travel together.
<label htmlFor="capacity">{t('parking.capacity')}</label>
<input
  id="capacity"
  inputMode="numeric"
  aria-invalid={!!errors.capacity}
  aria-describedby="capacity-error"
  {...register('capacity')}
/>
<FieldError id="capacity-error" error={errors.capacity} />
```

**[FORM-07] MUST:** Validation messages in schemas are i18n keys
(`'validation.name.tooShort'`), never user-facing sentences ([GEN-14], [I18N-12]).
> **Why:** A zod schema is a module, not a component; it has no access to `t()` at definition
> time. Putting the key in `message` and translating it at render time keeps the schema pure and
> keeps the Turkish string in the locale file where the i18n parity check can see it.

**[FORM-08] MUST NOT:** Render `errors.field?.message` inline in a page. Field errors go through
`FieldError`, form-level errors through the form's error summary.
> **Why:** Inline rendering is how half the fields end up without `aria-describedby` and how the
> styling drifts between screens.

---

## 3. Submitting, server errors and unsaved changes

**[FORM-09] MUST:** A 409 or 422 response feeds `error.fieldErrors()` ([API-31]) into
`setError(path, { type: 'server', message })`, matched by the DTO field path.
> **Why:** The server owns rules the client cannot check (uniqueness of a plate, a parcel that
> was built on since the form opened). Showing them as a toast leaves the user hunting for which
> of eighteen fields is wrong; putting them on the field is the whole point of having a field
> path in the error envelope.

```ts
// src/shared/utils/applyServerFieldErrors.ts
import type { FieldValues, Path, UseFormSetError } from 'react-hook-form'

import { ApiError } from '@/shared/api/errors'

/**
 * Maps the backend's `details: [{ field, code, message }]` onto RHF fields.
 * Returns true when at least one error was placed on a known field, so the caller can decide
 * whether a toast is still needed.
 *
 * The backend sends dotted paths ("location.0", "contacts.1.phone"); RHF understands the same
 * syntax, so no translation is needed beyond checking the path exists in the schema.
 */
export function applyServerFieldErrors<T extends FieldValues>(
  error: unknown,
  setError: UseFormSetError<T>,
  knownFields: ReadonlySet<string>,
): boolean {
  if (!(error instanceof ApiError) || !error.isValidation) return false

  const fieldErrors = error.fieldErrors()
  if (fieldErrors.length === 0) return false

  let placed = false
  const orphans: string[] = []

  for (const item of fieldErrors) {
    // Only the first segment identifies the schema field; "contacts.1.phone" -> "contacts".
    const root = item.field.split('.')[0] ?? item.field
    if (knownFields.has(root)) {
      setError(item.field as Path<T>, { type: 'server', message: item.code }, { shouldFocus: !placed })
      placed = true
    } else {
      // A field the form does not have (a backend rename, a rule on a computed column).
      // Losing it silently means the user sees a form that refuses to submit with no reason.
      orphans.push(`${item.field}: ${item.code}`)
    }
  }

  if (orphans.length > 0) {
    setError('root.serverError', { type: 'server', message: 'validation.serverRejected' })
  }
  return placed
}
```

**[FORM-10] MUST:** A server field error whose path does not exist in the form sets
`root.serverError`, which the form renders in its error summary together with the request id
([API-07]).
> **Why:** Dropping an unmatched error produces the worst bug class in forms: submit does
> nothing, no message, no console output, and the user retries eleven times before calling
> support. The request id turns that call into a log lookup.

**[FORM-11] MUST:** The submit button is `disabled` while `formState.isSubmitting`, and the
submit handler is additionally guarded against re-entry.
> **Why:** `disabled` alone loses the race on a slow device: a double click can dispatch two
> `submit` events before React re-renders. Two `POST`s create two records, and [API-09] forbids
> deduplicating that at the client by retrying differently. The guard is two lines.

```tsx
const onSubmit = form.handleSubmit(async (values) => {
  if (createParking.isPending) return          // re-entry guard, belt and braces
  try {
    const created = await createParking.mutateAsync(values)
    form.reset(toFormValues(created))          // [FORM-13]
    toast.success(t('parking.created'))
  } catch (error) {
    const placed = applyServerFieldErrors(error, form.setError, PARKING_FORM_FIELDS)
    if (!placed) toast.error(messageForError(error))   // [OBS-09]
  }
})
```

**[FORM-12] MUST:** The submit handler calls a TanStack Query mutation ([STA-14]), never
`api.post` directly, so cache invalidation stays with the feature that owns the data.
> **Why:** A direct call leaves the list the user returns to showing stale rows, and the bug is
> reported as "it did not save".

**[FORM-13] MUST:** After a successful submit the form is `reset()` with the server's response
(create forms reset to empty or to the created entity, edit forms reset to the returned entity).
> **Why:** `reset()` is what clears `isDirty`; without it the unsaved-changes blocker fires on the
> way out of a form that saved correctly. Resetting to the **response** rather than the submitted
> values also picks up server-side normalisation (a trimmed name, a generated code).

**[FORM-14] MUST:** A form with `isDirty === true` blocks navigation with `useBlocker`
([RTE-17]) and a confirm dialog, and registers a `beforeunload` handler for tab close.
> **Why:** A municipal inspection form takes fifteen minutes to fill. Losing it to a
> misclicked sidebar link is the single most expensive UX failure in this class of application.
> `beforeunload` covers close and reload, which the router cannot see.

```ts
// src/shared/hooks/useUnsavedChangesWarning.ts
import { useEffect } from 'react'
import { useBlocker } from 'react-router-dom'

export function useUnsavedChangesWarning(isDirty: boolean) {
  const blocker = useBlocker(({ currentLocation, nextLocation }) =>
    isDirty && currentLocation.pathname !== nextLocation.pathname)

  useEffect(() => {
    if (!isDirty) return
    // The browser shows its own generic text; a custom string has been ignored since 2017.
    const handler = (event: BeforeUnloadEvent) => { event.preventDefault() }
    window.addEventListener('beforeunload', handler)
    return () => window.removeEventListener('beforeunload', handler)   // [GEN-21]
  }, [isDirty])

  return blocker
}
```

**[FORM-15] MUST:** Default values that come from a query use the `values` prop of `useForm`.
`defaultValues` plus a `useEffect` calling `reset()` is forbidden ([STA-34]).
> **Why:** `defaultValues` is read once, at first render, when the query has not resolved, so the
> form renders empty and stays empty. The `useEffect` workaround then fights the user: a refetch
> on focus resets the field they were typing in. The `values` prop re-syncs only when the value
> identity changes and keeps dirty fields intact.

```tsx
// WRONG: overwrites what the user typed on every refetch.
const form = useForm({ defaultValues: EMPTY })
useEffect(() => { if (data) form.reset(toFormValues(data)) }, [data, form])

// RIGHT.
const form = useForm({
  resolver: zodResolver(ParkingFormSchema),
  defaultValues: EMPTY_PARKING_FORM,   // shape only, so every field is controlled from render 1
  values: data ? toFormValues(data) : undefined,
})
```

**[FORM-16] MUST NOT:** Pass `undefined` or `null` as the value of a controlled input. A
`toFormValues` mapper converts nullable DTO fields to `''`, `false` or a sentinel.
> **Why:** React logs "a component is changing an uncontrolled input to be controlled" and, more
> importantly, the field silently stops tracking its value, so the user's typing is discarded on
> the next parent render.

---

## 4. Inputs that go wrong

**[FORM-17] MUST NOT:** Use `register('field', { valueAsNumber: true })` for any number a user
types in a locale that is not `en-US`.
> **Why:** `valueAsNumber` is `Number(input.value)`, which is locale blind. A Turkish user typing
> `1.234,56` produces `NaN`, and zod reports "expected number, received nan", which the user
> reads as the app rejecting a perfectly ordinary price. `valueAsNumber` is acceptable only on
> `<input type="number">` with `step` and no grouping, which is a narrow case.

**[FORM-18] MUST:** Locale-formatted numeric input goes through the shared `NumberInput`, which
parses with the active locale's separators, stores a `number` in form state, and displays a
`Intl.NumberFormat` string when the field is not focused.
> **Why:** In `tr-TR` the decimal separator is a comma and the grouping separator is a full stop,
> exactly inverted from `en-US`. Reading the separators from `Intl.NumberFormat().formatToParts()`
> rather than hard-coding them means the same component works when the app adds a locale.

```tsx
// src/shared/components/NumberInput.tsx
import { useMemo, useState } from 'react'
import { useTranslation } from 'react-i18next'

interface NumberInputProps {
  id: string
  value: number | null
  onChange: (value: number | null) => void
  onBlur: () => void
  maximumFractionDigits?: number
  'aria-describedby'?: string
  'aria-invalid'?: boolean
}

/** Reads the separators from Intl instead of hard-coding "," and "." ([I18N-08], [I18N-09]). */
function separatorsFor(locale: string) {
  const parts = new Intl.NumberFormat(locale).formatToParts(12345.6)
  return {
    group: parts.find((p) => p.type === 'group')?.value ?? ',',
    decimal: parts.find((p) => p.type === 'decimal')?.value ?? '.',
  }
}

export function parseLocaleNumber(raw: string, locale: string): number | null {
  const { group, decimal } = separatorsFor(locale)
  const normalised = raw
    .replaceAll(group, '')
    .replace(decimal, '.')
    .replaceAll(/[\s  ]/g, '')   // regular, non-breaking and narrow no-break spaces
    .trim()
  if (normalised === '' || normalised === '-') return null
  const value = Number(normalised)
  return Number.isFinite(value) ? value : null
}

export function NumberInput({ id, value, onChange, onBlur, maximumFractionDigits = 2, ...aria }: NumberInputProps) {
  const { i18n } = useTranslation()
  const [draft, setDraft] = useState<string | null>(null)
  const formatter = useMemo(
    () => new Intl.NumberFormat(i18n.language, { maximumFractionDigits }),
    [i18n.language, maximumFractionDigits],
  )

  // While focused show exactly what the user typed; when blurred show the formatted value.
  const display = draft ?? (value === null ? '' : formatter.format(value))

  return (
    <input
      id={id}
      // Not type="number": it rejects the grouping separator and its spinner is a hazard on
      // a laptop trackpad, where a scroll over the field silently changes a price.
      type="text"
      inputMode="decimal"
      value={display}
      onFocus={() => setDraft(value === null ? '' : String(value).replace('.', separatorsFor(i18n.language).decimal))}
      onChange={(event) => {
        setDraft(event.target.value)
        onChange(parseLocaleNumber(event.target.value, i18n.language))
      }}
      onBlur={() => { setDraft(null); onBlur() }}
      {...aria}
    />
  )
}
```

`NumberInput` is a controlled component, so it is wired with `<Controller>`:

```tsx
<Controller
  name="hourlyRate"
  control={form.control}
  render={({ field, fieldState }) => (
    <NumberInput
      id="hourlyRate" value={field.value ?? null} onChange={field.onChange} onBlur={field.onBlur}
      aria-invalid={!!fieldState.error} aria-describedby="hourlyRate-error"
    />
  )}
/>
```

**[FORM-19] MUST:** Dates use `<input type="date">`, whose value is always `YYYY-MM-DD`
regardless of locale. That string is stored in form state, converted to a full ISO 8601 instant
only when the API expects one ([API-18]), and displayed with `Intl.DateTimeFormat`
([I18N-08]).
> **Why:** The native control renders in the user's locale for free and is keyboard and screen
> reader accessible, while its `value` stays machine readable. Building a `Date` from
> `new Date('01.02.2026')` is the classic day/month swap that silently books an inspection for
> the wrong date. Date-only values must not be sent as an instant with a local midnight: in
> `Europe/Istanbul` (UTC+3) that becomes the previous day in UTC.

```ts
// Date-only value -> API instant. Explicit UTC, never new Date('2026-03-01').toISOString()
// from a local-midnight Date object.
export function dateOnlyToInstant(value: string): string {
  return `${value}T00:00:00.000Z`
}
```

**[FORM-20] MUST:** A select with more than about 20 options is a combobox with type-ahead
search; above **200** options it is virtualised ([PERF-12]) and its options come from a
server-side search query, debounced 300 ms, with `placeholderData: keepPreviousData`
([STA-18]).
> **Why:** A native `<select>` with 4,000 neighbourhood names is 4,000 DOM nodes built on open
> and unusable without search. The debounce and `keepPreviousData` stop the list from flashing
> empty between keystrokes.

**[FORM-21] MUST:** File inputs declare `accept`, enforce a size limit before upload, upload
through `upload()` ([API-35], [API-36]) with progress, and treat a server 4xx as a normal field
error on the file field ([SEC-26]).
> **Why:** Client checks are UX, not security: they stop the user from waiting 40 seconds for a
> 200 MB file that the server will reject anyway. The server validates by content, and its
> rejection must land on the field, not in a toast the user has already dismissed.

```tsx
// Preview lifecycle. Every createObjectURL has a revoke in the cleanup ([PERF-24]).
useEffect(() => {
  if (!file) { setPreviewUrl(null); return }
  const url = URL.createObjectURL(file)
  setPreviewUrl(url)
  return () => URL.revokeObjectURL(url)
}, [file])
```

Additional requirements for a file field: a drop zone that also works as a keyboard-reachable
button (`<input type="file">` visually hidden but focusable, label as the drop target), a
`dragover` handler that calls `preventDefault` (without it the browser navigates away from the
app and the user loses the form), a per-file progress bar with `role="progressbar"`, a cancel
button wired to the upload's `AbortController` ([API-34]), and no rendering of a user-supplied
SVG inline ([SEC-26]).

**[FORM-22] MUST:** Coordinates captured from the map picker are stored as a `[lng, lat]` tuple
([API-20], [GIS-01], [GIS-03]) rounded to **6 decimal places**, and the numeric fields shown next to the
map are read-only mirrors unless the form explicitly supports manual entry.
> **Why:** `[lat, lng]` order is the most common defect in this codebase family: it places
> Istanbul in Somalia, and only a human looking at the map notices. Six decimals is about 11 cm,
> below any survey accuracy a municipality has; more digits are noise that breaks value equality
> checks and inflates payloads.

```ts
export const COORDINATE_PRECISION = 6

export function roundPosition([lng, lat]: [number, number]): [number, number] {
  const f = 10 ** COORDINATE_PRECISION
  return [Math.round(lng * f) / f, Math.round(lat * f) / f]
}
```

**[FORM-23] MUST:** Text values are normalised on blur, before validation: trim both ends,
collapse internal whitespace runs to one space, and normalise Unicode with `String.prototype.normalize('NFC')`.
> **Why:** Copy-paste from Excel and from PDF brings trailing spaces, non-breaking spaces and
> decomposed characters. `"Ş"` typed on a Turkish keyboard and `"Ş"` pasted from a PDF can be
> different byte sequences that compare unequal, so a duplicate check on the server passes and
> the municipality gets two records for one street.

```ts
// src/shared/utils/normalizeText.ts
export function normalizeText(value: string): string {
  return value
    .normalize('NFC')
    .replaceAll(/[\s ​]+/g, ' ')   // includes NBSP and zero-width space
    .trim()
}
```

**[FORM-24] MUST:** Case changes on Turkish data use `toLocaleUpperCase('tr-TR')` and
`toLocaleLowerCase('tr-TR')`. Plain `toUpperCase()`/`toLowerCase()` on user data is forbidden
([I18N-24]).
> **Why:** Turkish has two i letters. `'istanbul'.toUpperCase()` is `'ISTANBUL'`, but the correct
> Turkish result is `'İSTANBUL'`; `'IĞDIR'.toLowerCase()` is `'iğdir'` where Turkish requires
> `'ığdır'`. A plate normaliser using `toUpperCase()` turns `34 abc 123` into a value that fails
> a server-side comparison against `34 ABC 123` for one letter in a hundred.

---

## 5. Turkish identifiers

**[FORM-25] MUST:** Identifier validation lives in `src/shared/utils/trIdentifiers.ts` as pure
functions, is exposed to schemas through named zod refinements, is unit-tested with known-valid
and known-invalid samples ([TEST-01]), and stores the **normalised** value (digits only, no
spaces or punctuation) in form state.
> **Why:** A regex checking only the digit count accepts 11 random digits as a TCKN and the
> record is rejected by the ministry integration three days later, by which time the citizen has
> left. Storing the formatted value ("+90 532 123 45 67") makes every equality check and every
> database index depend on the formatting the user happened to use.

```ts
// src/shared/utils/trIdentifiers.ts

/** Digits only, ASCII, with Arabic-Indic digits folded to ASCII (mobile keyboards emit them). */
export function digitsOnly(value: string): string {
  return value.replaceAll(/[^\d٠-٩]/g, '')
    .replaceAll(/[٠-٩]/g, (d) => String(d.charCodeAt(0) - 0x0660))
}
```

**[FORM-26] MUST:** TCKN (Turkish national identity number) is validated with the full
checksum, not a length check.

```ts
/**
 * TCKN: 11 digits.
 *   - d1 is never 0.
 *   - d10 = ((d1+d3+d5+d7+d9) * 7 - (d2+d4+d6+d8)) mod 10
 *   - d11 = (d1 + ... + d10) mod 10
 * Repeated-digit values (11111111110) satisfy the checksum but are not issued, so they are
 * rejected explicitly: they are the value a bored user types to get past the field.
 */
export function isValidTckn(input: string): boolean {
  const value = digitsOnly(input)
  if (!/^[1-9]\d{10}$/.test(value)) return false
  if (/^(\d)\1{10}$/.test(value)) return false

  const d = [...value].map(Number)
  const odd = d[0] + d[2] + d[4] + d[6] + d[8]      // digits 1,3,5,7,9
  const even = d[1] + d[3] + d[5] + d[7]            // digits 2,4,6,8

  const tenth = (odd * 7 - even) % 10
  if (((tenth + 10) % 10) !== d[9]) return false

  const eleventh = d.slice(0, 10).reduce((sum, n) => sum + n, 0) % 10
  return eleventh === d[10]
}
```

**[FORM-27] MUST:** VKN (tax number) is validated with its own checksum. VKN and TCKN are
different fields; a single "identity number" field that accepts either is allowed only when the
backend accepts either, and then it validates as `isValidTckn(v) || isValidVkn(v)`.

```ts
/**
 * VKN: 10 digits. For each of the first 9 digits, at position p = 9-i (8 down to 0):
 *   tmp = (digit + p) mod 10
 *   contribution = tmp === 0 ? 9 : (tmp * 2^p) mod 9, and a result of 0 counts as 9
 * The check digit is (10 - (sum mod 10)) mod 10.
 */
export function isValidVkn(input: string): boolean {
  const value = digitsOnly(input)
  if (!/^\d{10}$/.test(value)) return false

  const d = [...value].map(Number)
  let sum = 0
  for (let i = 0; i < 9; i++) {
    const p = 9 - i
    const tmp = (d[i] + p) % 10
    if (tmp === 0) {
      sum += 9
    } else {
      const partial = (tmp * 2 ** p) % 9
      sum += partial === 0 ? 9 : partial
    }
  }
  return (10 - (sum % 10)) % 10 === d[9]
}
```

**[FORM-28] MUST:** Phone numbers are normalised to E.164 (`+905321234567`) for storage, with
`+90` as the default country code, accepting the `05xx`, `5xx`, `0090` and `+90` forms users
actually type. Display uses a grouped format; storage never does.
> **Why:** The same person's number arrives as `0532 123 45 67`, `(532) 1234567` and
> `+90-532-123-45-67`. Without normalisation the duplicate check fails, the SMS gateway rejects
> two of the three, and nobody can search for a citizen by phone.

```ts
const TR_COUNTRY_CODE = '90'
const TR_NATIONAL_LENGTH = 10          // 5321234567: area/operator code + 7 digits

export function toE164Tr(input: string): string | null {
  let value = digitsOnly(input)
  if (value.startsWith('00')) value = value.slice(2)
  if (value.startsWith(TR_COUNTRY_CODE) && value.length === TR_NATIONAL_LENGTH + 2) {
    value = value.slice(2)
  } else if (value.startsWith('0')) {
    value = value.slice(1)
  }
  // National numbers never start with 0 or 1 after the trunk prefix is removed.
  if (!new RegExp(`^[2-9]\\d{${TR_NATIONAL_LENGTH - 1}}$`).test(value)) return null
  return `+${TR_COUNTRY_CODE}${value}`
}

export function isTrMobile(e164: string): boolean {
  return /^\+905\d{9}$/.test(e164)     // mobile ranges start with 5
}
```

**[FORM-29] MUST:** IBAN is validated with the ISO 13616 mod-97 check; Turkish IBANs are
additionally required to be 26 characters starting with `TR`.

```ts
/**
 * mod-97: move the first four characters to the end, map letters to numbers (A=10 .. Z=35),
 * and check that the resulting integer mod 97 is 1. The number is far beyond Number.MAX_SAFE_INTEGER,
 * so it is reduced in chunks rather than with BigInt (chunking is faster and needs no polyfill
 * consideration).
 */
export function isValidIban(input: string): boolean {
  const value = input.replaceAll(/[\s ]/g, '').toLocaleUpperCase('tr-TR')
  if (!/^[A-Z]{2}\d{2}[A-Z0-9]{11,30}$/.test(value)) return false
  if (value.startsWith('TR') && value.length !== 26) return false

  const rearranged = value.slice(4) + value.slice(0, 4)
  const digits = [...rearranged]
    .map((ch) => (ch >= 'A' && ch <= 'Z' ? String(ch.charCodeAt(0) - 55) : ch))
    .join('')

  let remainder = 0
  for (let i = 0; i < digits.length; i += 7) {
    remainder = Number(String(remainder) + digits.slice(i, i + 7)) % 97
  }
  return remainder === 1
}
```

**[FORM-30] MUST:** Vehicle plates are normalised to the canonical spaced form
(`34 ABC 123`) and validated against the four legal shapes.

```ts
/**
 * Turkish civilian plates: a 2-digit province code (01..81) then either
 *   1 letter  + 4 or 5 digits   (34 A 1234, 34 A 12345)
 *   2 letters + 3 or 4 digits   (34 AB 123, 34 AB 1234)
 *   3 letters + 2 or 3 digits   (34 ABC 12, 34 ABC 123)
 * Letters use the Latin subset that appears on plates (no Turkish-specific letters).
 * Diplomatic and military plates are out of scope; a form that needs them takes free text.
 */
const PLATE_PATTERN = /^(0[1-9]|[1-7]\d|8[01])([A-Z]{1,3})(\d{2,5})$/

export function normalizePlate(input: string): string | null {
  const compact = input.replaceAll(/[\s -]/g, '').toLocaleUpperCase('tr-TR')
  const match = PLATE_PATTERN.exec(compact)
  if (!match) return null

  const [, province, letters, digits] = match
  const allowed: Record<number, readonly number[]> = { 1: [4, 5], 2: [3, 4], 3: [2, 3] }
  if (!allowed[letters.length]?.includes(digits.length)) return null

  return `${province} ${letters} ${digits}`
}
```

**[FORM-31] MUST:** Postal codes are 5 digits whose first two are a valid province code
(`01`..`81`), stored as a string.
> **Why:** Storing a postal code as a number loses the leading zero, and `01330` (Adana) becomes
> `1330`, which fails every downstream address lookup.

```ts
export function isValidPostalCode(input: string): boolean {
  const value = digitsOnly(input)
  if (!/^\d{5}$/.test(value)) return false
  const province = Number(value.slice(0, 2))
  return province >= 1 && province <= 81
}
```

Wiring them into a schema:

```ts
import { isValidTckn, normalizePlate, toE164Tr } from '@/shared/utils/trIdentifiers'

export const CitizenFormSchema = z.object({
  tckn: z.string().refine(isValidTckn, { message: 'validation.tckn.invalid' }),
  // transform stores the normalised value; z.input keeps the raw string for the input ([FORM-05]).
  phone: z.string().transform((v, ctx) => {
    const e164 = toE164Tr(v)
    if (!e164) { ctx.addIssue({ code: 'custom', message: 'validation.phone.invalid' }); return z.NEVER }
    return e164
  }),
  plate: z.string().transform((v, ctx) => {
    const plate = normalizePlate(v)
    if (!plate) { ctx.addIssue({ code: 'custom', message: 'validation.plate.invalid' }); return z.NEVER }
    return plate
  }),
})
```

---

## 6. Multi-step forms and drafts

**[FORM-32] MUST:** A multi-step form is **one** `useForm` instance with
`shouldUnregister: false`; each step renders a subset of the fields and validates only its own
fields with `trigger(fieldsOfStep)` before advancing.
> **Why:** One instance per step loses the values of every step the user navigates back through,
> because RHF unregisters unmounted fields by default. `shouldUnregister: false` keeps them, and
> a single instance means one `isDirty`, one blocker, one submit.

**[FORM-33] MUST:** The current step is in the URL (`?step=2`) ([STA-02]), validated against the
step count, and a step the user has not reached is redirected to the first incomplete step.
> **Why:** Refreshing on step 4 of a permit application and landing on step 1 with the values
> still in memory but the wrong screen showing is the reason people fill forms twice. The URL
> also makes the step reachable from a support conversation.

**[FORM-34] SHOULD:** A form that takes more than about two minutes to fill autosaves a draft
to `localStorage`, debounced 1,000 ms, under a versioned key
`draft:v1:<feature>:<entityId ?? 'new'>` registered in `storageKeys.ts` ([STA-37]).
> **Why:** Browsers crash, laptops sleep, and municipal Wi-Fi drops. A 1 s debounce keeps the
> write off the typing path (a `localStorage.setItem` of a 20 KB object is 1 to 3 ms of main
> thread, which is fine once a second and not fine per keystroke). The version prefix means a
> schema change makes old drafts ignorable rather than crash-inducing.

**[FORM-35] MUST NOT:** Persist personal data in a draft ([STA-38]). Fields holding a TCKN,
a full name, an address, a phone number or a health note are excluded from the persisted subset
by an explicit allow-list, never by a deny-list.
> **Why:** A draft in `localStorage` on a shared counter workstation outlives the session, the
> logout and the user ([AUTH-23] clears it, but only if the app is closed cleanly). A deny-list
> silently starts leaking the day someone adds a field.

**[FORM-36] MUST:** A draft is cleared on successful submit, on explicit cancel, and by
`clearUserScopedStorage()` at logout ([AUTH-23]). Restoring a draft is offered explicitly ("you
have an unsaved draft from 14:32, restore or discard"), never applied silently.
> **Why:** Silently restoring means a user who intentionally abandoned a form finds it
> half-filled with someone else's answers and submits it.

---

## 7. Form UX rules

**[FORM-37] MUST:** Labels are always visible above or beside the control. A placeholder is
never the label.
> **Why:** The placeholder disappears the moment the user types, so anyone interrupted mid-form
> has to clear the field to find out what it was. Placeholder text also fails contrast
> requirements in every browser's default styling ([A11Y-14]).

**[FORM-38] MUST:** Required fields are marked visually and with `aria-required`; if most fields
are required, mark the optional ones instead and say so once at the top of the form.
> **Why:** A form where nineteen of twenty labels carry a red asterisk communicates nothing.

**[FORM-39] MUST:** A form with more than 8 fields renders an error summary at the top on failed
submit: a `role="alert"` region listing each invalid field as a link to its control.
> **Why:** On a long permit form the first error can be 1,500 px below the submit button, so the
> user presses submit, nothing visibly happens, and they conclude the app is broken. The summary
> is also the only practical way for a screen-reader user to learn how many things failed.

**[FORM-40] MUST:** On failed submit, focus moves to the first invalid control (RHF's
`shouldFocusError`, on by default) or to the error summary when one is rendered.
> **Why:** Without focus movement, keyboard and screen-reader users have no idea the submit was
> even processed.

**[FORM-41] MUST:** Enter in a single-line text field submits the form; a `<button>` inside a
form that is not the submit action carries `type="button"`.
> **Why:** The default `type` of `<button>` is `submit`. An unlabelled "add row" button therefore
> submits the whole form, which users experience as random saves. This is one of the highest
> value five-character fixes in the standard.

**[FORM-42] MUST:** Escape closes a modal form; when the form is dirty, Escape opens the same
discard confirmation as navigation ([FORM-14]), it does not discard silently.
> **Why:** Escape is muscle memory. Making it destroy twelve minutes of typing without a prompt
> is a bug report; making it do nothing at all is also a bug report.

**[FORM-43] MUST:** Common personal-data fields carry the correct `autocomplete` tokens
(`name`, `email`, `tel`, `street-address`, `postal-code`, `organization`), and login fields
follow [AUTH-30].
> **Why:** A clerk entering fifty citizen records a day gets browser autofill for their own
> repeated organisation data, and the tokens are also what mobile keyboards use to decide which
> layout to show.

---

## 8. Testing forms

**[FORM-44] MUST:** Forms are tested through the DOM with `@testing-library/user-event` and MSW
([TEST-19], [TEST-10]): fill by label text, submit by button role, assert on the visible error
or the resulting navigation. `form.getValues()` is never asserted directly.
> **Why:** Asserting on internal RHF state proves the library works ([TEST-37]) and passes even
> when the input is not connected to its label, which is the defect users actually hit.

```tsx
it('shows the server field error on the plate field', async () => {
  server.use(http.post('/api/vehicles', () =>
    HttpResponse.json(
      { error: { code: 'VALIDATION', message: 'x', details: [{ field: 'plate', code: 'validation.plate.taken', message: 'taken' }] } },
      { status: 422 },
    )))

  const user = userEvent.setup()
  renderApp(<VehicleForm />)

  await user.type(screen.getByLabelText('Plaka'), '34 ABC 123')
  await user.click(screen.getByRole('button', { name: 'Kaydet' }))

  expect(await screen.findByText('Bu plaka zaten kayıtlı')).toBeInTheDocument()
  expect(screen.getByLabelText('Plaka')).toHaveAttribute('aria-invalid', 'true')
})
```

**[FORM-45] MUST:** Every form has at least these three tests: a successful submit that asserts
the mutation's visible effect, a client-side validation failure, and a 422 mapped onto a field.

**[FORM-46] MUST:** Every identifier validator has a table-driven unit test with at least three
known-valid values, the "all same digit" case, an off-by-one checksum case, and a wrong-length
case ([TEST-01]).
> **Why:** These functions are pure, cheap to test, and impossible to verify by reading. A
> checksum that is wrong in one branch passes manual testing with the developer's own TCKN.

---

## Open questions

- **Address autocomplete against the national address database (NVI/AKS).** Not specified: the
  integration would be a backend proxy endpoint plus a combobox, but no reference deployment has
  the credential yet. Decide when one does; until then addresses are free text with
  `postal-code` and province/district selects.
- **Client-side image downscaling before upload.** A 12 MP phone photo of a building defect is
  4 MB, and a canvas resize to 1,600 px would cut it to about 300 KB. It needs a worker
  ([PERF-22]) and a rule about when the original must be preserved for evidentiary purposes,
  which is a legal question, not a frontend one.
- **`Temporal` for date arithmetic.** [VER-11] prefers the platform, but `Temporal` is not in the
  version table and the polyfill is 40 KB gzipped. Revisit when it is available unflagged in all
  browsers of [VER-12]; until then date-only strings plus `Intl` cover every case in this file.
