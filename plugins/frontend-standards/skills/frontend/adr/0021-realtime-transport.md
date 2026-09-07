# ADR-0021 — Realtime transport: MQTT over WebSocket via EMQX

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [GEN-10], [GEN-22], [SEC-19], [STA-22], [RT-01]..[RT-24], [MAP-63]

## Context

The reference deployments push device data to the browser continuously: waste truck positions
and load, container fill levels, soil moisture and valve state for irrigation, air quality
measurements, and a live operational log. The producers are field devices and backend services,
not the web application; the consumers are several browser tabs, a mobile view, and backend
subscribers that are not browsers at all.

Two properties of that shape drive the decision. First, **fan-out**: one device publishes once
and N consumers receive it, and N includes non-browser consumers. Second, **topic-level
authorisation**: an irrigation operator may read valve state but not vehicle positions, and
that boundary has to exist at the transport, not in the UI.

Volume is modest by broker standards: a few hundred devices, a few hundred messages per second
at peak, a few dozen concurrent operators. The decision is therefore about shape, not scale.

## Options

### A) MQTT over WebSocket, brokered by EMQX (CHOSEN)

**Strengths:**
- **The broker already exists.** Devices publish MQTT because that is what field hardware
  speaks. Adding a WebSocket listener to the existing broker gives the browser the same stream
  the backend consumes, with no bridge service to write, deploy and keep in sync.
- **Topics are the routing and the authorisation model at once.** EMQX ACLs restrict a
  credential to a topic filter, so "this operator may read `irrigation/#` and nothing else" is
  broker configuration rather than application code. With a raw socket that logic would be a
  service we write.
- **Fan-out is the broker's job.** A new consumer is a subscription, not a change to the
  producer or to a connection registry.
- **Reconnect and keepalive are in the protocol**, so [RT-04] and [RT-05] configure behaviour
  rather than implement it.
- **The client library is mature and small enough to lazy-load** (`mqtt` 5.x, roughly 90 KB
  gzipped, loaded only on pages with live data, [RT-01], [PERF-05]).
- **It survives a proxy.** `wss://` on the app's own origin through nginx `/mqtt` satisfies
  [GEN-22]: no second certificate, no CORS, no extra CSP `connect-src` entry.
- **QoS and retained messages are available** when a use case needs them (a retained "last
  known valve state" so a newly opened tab is not blank until the next tick).

**Weaknesses:**
- **A broker is another production service** to run, monitor, upgrade and secure. Its
  authentication configuration is subtle: on EMQX 5 the `EMQX_ALLOW_ANONYMOUS` environment
  variable is ignored when the `authentication` list is empty, which the reference deployment
  measured the hard way. A misconfigured broker is open to the internet.
- **90 KB of client library**, even lazily loaded, for what is conceptually "receive JSON".
- **Credentials.** The broker cannot read our session cookie, so a bearer credential is
  unavoidable; making it short-lived and topic-scoped ([SEC-19], [RT-02]) is mitigation, not
  removal. A static broker password in the bundle, which is what the reference codebase ships
  today, is a published credential ([GEN-10]).
- **Client-id collisions kick sessions.** Two tabs with the same client id make EMQX evict the
  older one, and the two then reconnect over each other indefinitely. [RT-01] requires a
  random id per tab because of this exact failure.
- **Debugging is indirect.** A message that does not arrive could be the device, the broker
  ACL, the subscription, the proxy or the parser, and the browser sees the same silence in all
  five cases.

### B) A raw WebSocket to our own backend

**Strengths:** No broker, no extra service, no client library at all (`WebSocket` is a
platform API), full control over the wire format, and the session cookie authenticates it on
the same origin with no second credential.

**Weaknesses:** The backend becomes the fan-out layer: it must hold every connection, track
which client wants which stream, implement subscribe and unsubscribe messages, enforce
per-stream permissions, and handle its own reconnect and heartbeat semantics ([RT-22] describes
what the client side of that costs). That is a re-implementation of MQTT with fewer features
and no operational tooling. It also does not help the non-browser consumers, and the devices
still speak MQTT, so a bridge is needed anyway. Correct choice for an application whose live
data originates in the backend rather than in devices.

### C) Server-Sent Events (SSE)

**Strengths:** The simplest option by a wide margin: one HTTP GET, `EventSource` in the
platform, automatic reconnect with `Last-Event-ID`, authenticated by the session cookie,
proxied by nginx with one `proxy_buffering off` line. No library.

**Weaknesses:** One-way only, which is acceptable here, but the connection limit is not:
browsers cap HTTP/1.1 connections per origin at six, so a page with several streams starves
its own API calls ([RT-23]). Text only. And it moves the fan-out and authorisation problem to
the backend exactly as option B does, because SSE is a stream from our server, not from a
broker. It remains the right transport for a single one-way feed (notifications), which is why
[RT-23] keeps it as an allowed option rather than rejecting it.

### D) Polling (TanStack Query `refetchInterval`)

**Strengths:** No new transport, no new service, no new failure mode. Caching, deduplication,
retries and error handling already exist ([STA-07]). Works through any proxy and any
corporate firewall.

**Weaknesses:** Latency equals the interval, and the cost is the interval divided into the
number of tabs: 30 operators polling positions every 2 s is 15 requests per second of pure
overhead against the API, most of them returning unchanged data. Position updates at 4 Hz are
not achievable by polling at any acceptable cost. It remains correct below one update per 30
seconds, which is why [RT-24] mandates it there.

### E) WebTransport / HTTP/3 datagrams

**Strengths:** Purpose-built for exactly this, unreliable datagrams suit position updates
where a dropped message is irrelevant.

**Weaknesses:** Browser support is incomplete across the [VER-12] matrix, requires HTTP/3 end
to end (which municipal proxies frequently break), and there is no broker-side story. Not
viable today.

## Decision

**MQTT over WebSocket through the existing EMQX broker**, `wss://` on the app's own origin at
`/mqtt`, with a short-lived topic-scoped credential from the backend, one lazily created
client per tab, and the batching rules in [20](../20-REALTIME-MEDIA.md) §4.

SSE stays permitted for a single one-way feed ([RT-23]) and polling for anything slower than
one update per 30 s ([RT-24]). A raw WebSocket is permitted where the data genuinely originates
in our backend rather than in devices, under the same lifecycle rules ([RT-22]).

Decisive reasons: the devices already publish MQTT, so every alternative requires a bridge
service that adds a failure mode without removing one; and topic-level authorisation is
enforced by the broker rather than by code we write and test.

## Accepted costs

- **A broker in production**, with an authentication configuration whose failure mode is
  "open to anyone" rather than "does not work". It must be verified by measurement (attempt an
  anonymous connect from outside) rather than by reading the environment file.
- **A second credential path** alongside the session cookie: an endpoint that mints
  topic-scoped tokens, a refresh on every reconnect, and a revocation story on logout
  ([RT-02], [RT-05]). This is code that exists only because the broker cannot read a cookie.
- **90 KB of client library** on realtime pages, and a lazy-load boundary that must be
  respected or it lands in the main chunk.
- **Backpressure is our problem.** MQTT delivers as fast as the broker can push; a reconnect
  after an outage replays a burst. The queue, the coalescing and the rate caps in [RT-10] and
  [RT-11] are permanent client-side machinery.
- **An extra debugging surface.** Silence has five possible causes ([A] weaknesses), and
  diagnosing it needs broker access, which frontend developers usually do not have.
- **The reference codebase's current MQTT setup violates several of the rules that follow from
  this decision** (static credentials from `VITE_` variables, a fixed 3 s reconnect period, no
  batching). Those are fixed as the features are touched ([GEN-24]), not in one migration.

## What would change this decision

- Devices moving off MQTT (a vendor change to HTTP push or to a managed IoT service), which
  removes the "the broker already exists" argument and makes a raw WebSocket or SSE from our
  own backend the cheaper shape.
- Broker connection pressure beyond roughly 2,000 concurrent web sessions, which would force
  either a `SharedWorker` (the open question in [20](../20-REALTIME-MEDIA.md)) or a fan-out
  service in front of the broker, at which point that service could speak SSE instead.
- A deployment where the firewall blocks WebSocket upgrades entirely. SSE over plain HTTP
  survives more restrictive proxies, and would become the fallback transport.
- WebTransport reaching the [VER-12] browser matrix with broker support, for the position
  stream specifically, where message loss is acceptable and latency matters.
