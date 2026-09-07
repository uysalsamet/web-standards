# ADR-0020 — Error tracking: a Sentry-protocol client against a self-hosted backend

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-17], [OBS-05], [OBS-11], [OBS-12], [SEC-22], [SEC-25], [VER-06]

## Context

A single-page application fails on the user's machine, not on ours. Without a tracker the
only evidence is a support call saying "the map went white", which arrives hours later
without a browser version, a route, a release id or a stack. The reference application ran
for eighteen months this way; the recurring "Invalid hook call" production failure took
weeks to attribute because nobody could see which build the affected users were running.

What we need is narrow: capture an unhandled exception or rejection with its stack, the
release id ([OBS-05]), the route, and enough breadcrumbs to reconstruct the last few
actions, then group identical failures so a spike is visible. What we must avoid is equally
clear: shipping personal data (municipal apps handle national identity numbers, addresses
and citizen records) to a system whose retention we do not control, and paying a per-event
fee that makes people disable capture.

Source maps are the other half. Minified frames are useless, so the tracker has to accept
uploaded maps that are never served publicly ([SEC-22]).

## Options

### A) `@sentry/react` client against a self-hosted Sentry-protocol backend (CHOSEN)
GlitchTip or self-hosted Sentry; the client does not care which.

**Strengths:**
- The client is the mature one: React error boundary integration, router instrumentation,
  breadcrumbs, `beforeSend`/`beforeBreadcrumb` hooks that make [OBS-12] scrubbing
  enforceable in one place, release and source-map tooling in the CLI.
- The protocol is documented and implemented by more than one server, so the client is not
  a commitment to a vendor. Moving from GlitchTip to Sentry, or the reverse, is a DSN change.
- Self-hosting keeps citizen data inside the institution's network, which is what KVKK
  compliance actually turns on, and removes per-event pricing as a reason to sample down.
- Source map upload with a release id is a solved, scripted step in CI ([CI-11]).
- GlitchTip runs in a container next to the other services; the operational shape is the
  one the team already knows.

**Weaknesses:**
- Bundle cost: roughly 30 KB gzipped for the browser SDK with tracing enabled, which is
  about 12 % of the app-shell budget in [PERF-02]. Replay is a further 50 KB and is off.
- A self-hosted backend is a service to run, upgrade and back up. GlitchTip is far lighter
  than full Sentry, but it is still Postgres plus a worker.
- The SDK is large in API surface, and a careless integration will capture personal data by
  default. That is why [OBS-12] and [SEC-25] are MUST rules with an explicit scrub list
  rather than advice.
- GlitchTip implements a subset of the protocol. Performance tracing and some newer
  features degrade or no-op; the standard only depends on errors, breadcrumbs, releases and
  source maps, which are all supported.

### B) No tracker; rely on server logs and user reports
**Strengths:** Zero bundle cost, zero privacy surface, nothing to operate.
**Weaknesses:** Client-side failures do not reach server logs at all. A chunk-load failure
after a deploy, a WebGL context loss, a null dereference in a map layer, all of these are
invisible. This is the current state we are correcting, and its cost is measured in days of
diagnosis per incident.

### C) A custom `/api/client-errors` endpoint we write ourselves
**Strengths:** Complete control over payload and retention, no third-party protocol, a few
hundred bytes of client code, data never leaves our stack by construction.
**Weaknesses:** Everything past "receive a POST" is work we would repeat badly: grouping
identical errors, deduplication, rate limiting a broken loop that fires 10,000 events a
minute, source-map resolution, release comparison, search, alerting, retention. That is a
product, not an endpoint. Realistically it stays a table nobody reads.

### D) OpenTelemetry browser SDK to an OTel collector
**Strengths:** One telemetry vocabulary shared with the backend standard, which already
uses OpenTelemetry for traces; a single collector for both sides; vendor-neutral.
**Weaknesses:** Browser error capture in OTel is still weaker than the Sentry SDK: no
first-class issue grouping, no source-map handling, no release comparison. The backend uses
OTel for distributed traces, which is a different question from front-end crash reporting.
Adopting it here would mean building the grouping and symbolication layer ourselves, which
is option C wearing a standard's clothing.

## Decision

**`@sentry/react` as the client, pointed at a self-hosted Sentry-protocol backend, with
`sendDefaultPii: false`, an explicit scrub list, replay disabled and tracing sampled at
10 %.** The decisive reasons are the maturity of the client's React and source-map
integration, and self-hosting removing both the privacy objection and the pricing pressure
that leads teams to sample errors away.

## Accepted costs

- About 30 KB gzipped in the app shell. Accepted, and counted in the budget in [PERF-02]
  rather than treated as free.
- A service to operate, upgrade and back up. This is the price of seeing failures at all.
- The client is a large dependency with a wide API, and the standard has to carry rules
  ([OBS-11], [OBS-12], [SEC-25]) to keep its defaults from leaking personal data. A safer
  default would have been a smaller client, but no smaller client does symbolication.
- Session replay is off, so the reproduction path for a hard bug is breadcrumbs plus the
  user's account rather than a recording. That is a deliberate privacy trade against
  debugging speed.
- We depend on a protocol shaped by one vendor, even though several servers implement it.
  If that protocol turns hostile, the client is the piece we replace.

## What would change this decision

- The OpenTelemetry browser SDK reaching parity on issue grouping and source-map
  symbolication. Then one telemetry stack for frontend and backend becomes the simpler
  answer and this record is reopened alongside the backend's tracing decision.
- A measured need for session replay on a specific product, which would require its own
  privacy assessment rather than flipping a flag.
- The self-hosted backend proving more expensive to operate than the incidents it explains.
  That would be measured in operator hours per quarter against diagnosis time saved, not
  asserted.
