# 20 — Realtime and Media

> Governs everything that pushes data into the browser without a request: MQTT over
> WebSocket, raw WebSocket, SSE, the workers that parse what arrives, and the video players
> (HLS, WebRTC WHEP) that stream alongside it. Core principle: **one connection per tab,
> created once and lazily, feeding a bounded queue that the UI drains at a fixed rate.**
> Read this file for any task containing `mqtt`, `WebSocket`, `EventSource`, `hls`, `WHEP`,
> `Worker`, or "live".
>
> Out of scope: what the map does with live positions ([08](08-MAP-MAPLIBRE.md) §12), which
> store holds the data ([05](05-STATE-AND-DATA.md) §2.5, §3), the broker credential's
> security model ([06](06-SECURITY.md) §6), and the nginx `/mqtt` proxy block
> ([12](12-NGINX.md) §5).

---

## 1. Scope and transport choice

Four transports are permitted. Pick by the shape of the traffic, not by familiarity:

| Transport | Use when | Do not use when |
|---|---|---|
| **MQTT over WebSocket** | Many topics, many producers, fan-out from devices, per-topic authorisation | A single stream from one endpoint |
| **Plain WebSocket** | One bidirectional stream with a small custom protocol | You would end up reimplementing topics and QoS |
| **SSE (`EventSource`)** | One-way server push, text events, no client-to-server messages | You need binary, or the client must send |
| **Polling (TanStack Query `refetchInterval`)** | Updates slower than one per 30 s | Sub-second latency matters |

**[RT-01] MUST:** The MQTT client is created **once**, lazily, in
`src/shared/lib/mqttClient.ts`, and every consumer goes through that module. No component,
hook or feature calls `mqtt.connect()` and no component imports the `mqtt` package
directly.
> **Why:** The `mqtt` browser build is roughly 90 KB gzipped ([PERF-05]); statically
> imported it lands in the main chunk of every page including the ones with no realtime.
> A per-component client means N TCP connections, N broker sessions and N client ids; EMQX
> kicks the older session when a client id repeats, and the two clients then fight in a
> reconnect loop (the reference project hit exactly this). One module also means one place
> for the token, the backoff and the teardown. Detail: [ADR-0021](adr/0021-realtime-transport.md).

```ts
// src/shared/lib/mqttClient.ts
import type { MqttClient, IClientOptions } from 'mqtt'

import { fetchRealtimeToken } from '@/shared/api/realtimeToken'
import { logger } from '@/shared/lib/logger'

const KEEPALIVE_SECONDS = 30
const CONNECT_TIMEOUT_MS = 8_000

let clientPromise: Promise<MqttClient> | null = null

/** Lazily imports the mqtt package and connects once per tab. */
export function getMqttClient(url: string): Promise<MqttClient> {
  clientPromise ??= createClient(url)
  return clientPromise
}

async function createClient(url: string): Promise<MqttClient> {
  const [{ default: mqtt }, credential] = await Promise.all([import('mqtt'), fetchRealtimeToken()])
  const options: IClientOptions = {
    // A unique client id per tab: a repeated id makes the broker kick the older session,
    // and the two tabs then reconnect over each other forever ([RT-17]).
    clientId: `web-${crypto.randomUUID()}`,
    clean: true,
    keepalive: KEEPALIVE_SECONDS,
    connectTimeout: CONNECT_TIMEOUT_MS,
    reconnectPeriod: 0,          // manual backoff, see [RT-04]
    protocolVersion: 5,
    username: credential.username,
    password: credential.token,
  }
  const client = mqtt.connect(url, options)
  client.on('error', (error) => logger.warn('mqtt.error', { message: error.message }))
  return client
}

/** Called by the auth module on logout ([RT-05]) and by tests. */
export async function destroyMqttClient(): Promise<void> {
  const pending = clientPromise
  clientPromise = null
  if (!pending) return
  const client = await pending
  await client.endAsync(true)
}
```

---

## 2. Connection lifecycle

**[RT-02] MUST:** The connection is opened only after the user is authenticated, and it
authenticates with a short-lived credential fetched from the backend
(`POST /api/realtime/token`, lifetime ≤ 15 minutes, scoped to the topics the user may read).
A static broker username and password from `config.js` or a `VITE_` variable is forbidden.
> **Why:** Everything shipped to the browser is public ([GEN-10]); a broker password in the
> bundle is a published credential that grants every topic to anyone who opens DevTools. The
> reference project ships `VITE_MQTT_USERNAME`/`VITE_MQTT_PASSWORD` and is the example of
> what not to do. Connecting before login also means an anonymous connection exists on every
> login page load. Detail: [06](06-SECURITY.md) §6 ([SEC-19]).

**[RT-03] MUST:** The broker URL is `wss://` on the app's own origin, proxied by nginx at
`/mqtt` ([GEN-22]); it comes from runtime config (`config.mqttWsUrl`) and a path-only value
is resolved against `window.location` at connect time. `ws://` is allowed only when the page
itself is `http://` on localhost.
> **Why:** A browser on an HTTPS page refuses a `ws://` connection outright (mixed content),
> and a cross-origin `wss://` needs its own certificate, its own CSP `connect-src` entry
> ([SEC-07]) and its own firewall hole. Same origin means the session cookie, the CSP and
> the TLS certificate are the ones already in place. Cross-ref: [NGX-14] for the proxy block
> (`proxy_http_version 1.1`, `Upgrade`/`Connection` headers, `proxy_read_timeout` above the
> keepalive).

**[RT-04] MUST:** Reconnect is implemented in `mqttClient.ts` with exponential backoff and
full jitter: delay `min(30_000, 1_000 * 2 ** attempt)` multiplied by a random factor in
`[0.5, 1]`, capped at **30 s**, reset to attempt 0 on a successful `connect`. The library's
own `reconnectPeriod` is set to `0`. Each reconnect fetches a fresh credential ([RT-02]).
> **Why:** A fixed 3 s reconnect period (the reference project's setting) means that when the
> broker restarts, every open tab in the municipality retries in lockstep every 3 seconds and
> the broker cannot finish starting. Jitter spreads the herd; the 30 s cap keeps a tab that
> was open overnight from taking an hour to notice the broker came back. Verify with
> `vi.useFakeTimers()` and `vi.advanceTimersByTime(8_000)` after three failures ([TEST-24]).

**[RT-05] MUST:** `keepalive` is **30 s**, `clean: true` (no persistent session), and the
client is destroyed on logout and on `pagehide`. Teardown waits for a socket that has not
finished its handshake rather than calling `end(true)` on it immediately.
> **Why:** 30 s is under the 60 s idle timeout of a default nginx proxy and of most corporate
> NAT tables, so the connection does not die silently between messages. A clean session means
> the broker does not queue megabytes of retained messages for a tab that closed a week ago.
> Calling `end(true)` mid-handshake logs "WebSocket is closed before the connection is
> established" on every StrictMode remount, which is noise that hides real errors; wait for
> `connect`, `error` or `close`, with a 5 s timeout so the client cannot outlive the page.

---

## 3. Subscriptions and where the data lands

**[RT-06] MUST:** A stream at or above **1 Hz per entity** (vehicle positions, sensor ticks)
lands in a Redux slice through **one batched action per flush** ([RT-10]), never one dispatch
per message, and the slice holds only the live fields (position, speed, bearing, timestamp,
state). Entity metadata (plate, type, owner) stays in the TanStack Query cache and is joined
by id at render.
> **Why:** Every dispatch notifies every `useSelector` subscriber and runs the immutability
> and serializability middleware over the state ([STA-26]). At 10 Hz for 200 vehicles that is
> 2,000 notifications a second and the app spends its frame budget in the store. One batched
> action per 250 ms is 4 notifications a second. Copying the metadata into the slice would
> also violate [STA-27]: it is server data with no invalidation policy. Cross-ref: [STA-22],
> [MAP-63].

**[RT-07] MUST:** A stream consumed by exactly one widget stays in that widget's local state
(`useState`/`useReducer` behind the topic hook). It goes to Redux only when a second feature
reads it.
> **Why:** [GEN-05] and [STA-03]: Redux is for cross-feature state. A live log panel that
> nothing else reads does not need a global store entry, a slice file, a selector and a test;
> it needs a `useReducer` with a capped array.

**[RT-08] MUST NOT:** A socket handler writes into the TanStack Query cache, with one
exception: an event slower than 1 Hz that maps to a **known, single** query key may call
`queryClient.setQueryData(key, updater)` or `invalidateQueries({ queryKey: key })`. Blanket
invalidation from a socket handler is forbidden.
> **Why:** `setQueryData` notifies every observer of the key and runs structural sharing over
> the whole cached value; at stream rates that is the [RT-06] problem with extra copying. A
> blanket `invalidateQueries()` on every message turns a push stream into a request storm,
> which is worse than the polling it replaced. Cross-ref: [STA-22].

**[RT-09] MUST:** Subscriptions are made through `useMqttTopic(topic, schema, onMessage)` in
`src/shared/hooks/useMqttTopic.ts`, which subscribes on mount, unsubscribes on unmount,
**ref-counts** shared topics so the last consumer unsubscribes and the others do not, and
parses every payload with the passed zod schema before calling `onMessage`.
> **Why:** Two components on the same topic that each call `unsubscribe` on unmount silently
> break the one that is still mounted; ref-counting is the only correct answer, and it must
> live in one place because every feature gets it wrong independently. StrictMode's
> mount/unmount/remount makes a non-ref-counted subscription leak on the first navigation
> ([GEN-21]).

```ts
// src/shared/hooks/useMqttTopic.ts
import { useEffect } from 'react'
import type { ZodType } from 'zod'

import { subscribeTopic } from '@/shared/lib/mqttTopics'

/**
 * Subscribes for the lifetime of the component. `onMessage` may change on every render;
 * the subscription does not resubscribe for it (the ref indirection lives in
 * subscribeTopic), so the effect depends only on topic identity.
 */
export function useMqttTopic<T>(
  topic: string,
  schema: ZodType<T>,
  onMessage: (message: T) => void,
): void {
  useEffect(() => {
    const unsubscribe = subscribeTopic(topic, schema, onMessage)
    return unsubscribe            // ref-counted: the broker unsubscribe happens at count 0
    // eslint-disable-next-line react-hooks/exhaustive-deps -- onMessage is read through a
    // ref inside subscribeTopic; including it would resubscribe on every parent render.
  }, [topic, schema])
}
```

---

## 4. Backpressure

**[RT-10] MUST:** Incoming messages are pushed into a queue and drained **once per animation
frame**, coalesced by entity id (the last message per id wins within a frame), with the queue
capped at **500** entries; on overflow the oldest are dropped and one counter is incremented,
not one log line per drop.
> **Why:** A device fleet that reconnects after an outage replays its buffer: 4,000 messages
> arrive in 200 ms. Without a queue, that is 4,000 React renders and the tab freezes for
> seconds. With per-frame draining and coalescing it is one render with the latest position
> per vehicle, which is all the screen can show anyway. Dropping oldest rather than newest is
> right because a stale position is worthless. Cross-ref: [MAP-63], [PERF-23].

```ts
// src/shared/lib/messageQueue.ts
const MAX_QUEUED = 500

export function createCoalescingQueue<T>(keyOf: (item: T) => string, flush: (batch: T[]) => void) {
  const pending = new Map<string, T>()
  let dropped = 0
  let frame: number | null = null

  const drain = () => {
    frame = null
    if (pending.size === 0) return
    const batch = [...pending.values()]
    pending.clear()
    if (dropped > 0) {
      // One line per flush, not per drop: the drop reason is always the same.
      console.warn(`messageQueue: dropped ${dropped} messages (cap ${MAX_QUEUED})`)
      dropped = 0
    }
    flush(batch)
  }

  return {
    push(item: T) {
      if (pending.size >= MAX_QUEUED && !pending.has(keyOf(item))) {
        const oldest = pending.keys().next()
        if (!oldest.done) pending.delete(oldest.value)
        dropped += 1
      }
      pending.set(keyOf(item), item)
      frame ??= requestAnimationFrame(drain)
    },
    dispose() {
      if (frame !== null) cancelAnimationFrame(frame)
      frame = null
      pending.clear()
    },
  }
}
```

**[RT-11] MUST:** The UI update rate is capped independently of the message rate: **4 Hz**
for moving entities (map positions, live tracks) and **1 Hz** for counters, gauges, tables
and badges. Smoothness between updates comes from interpolation or CSS transition, never from
rendering every message.
> **Why:** 4 Hz matches the map's `setData` budget ([MAP-26]) and is the rate at which
> interpolated motion looks continuous. A counter that changes 20 times a second is
> unreadable and costs a layout each time; at 1 Hz it is both readable and free. Verify with
> a Performance profile: the flush callback should appear at most four times per second.

---

## 5. Web workers

**[RT-12] MUST:** A worker is created inside an effect (or a lazily initialised module
singleton), terminated in that effect's cleanup with `worker.terminate()`, and its creation
is idempotent under StrictMode's mount/unmount/remount ([GEN-21]). A worker is never created
in a render body and never left running after its owner unmounts.
> **Why:** Each worker is an OS thread with its own heap. A worker created per mount and not
> terminated leaks one thread per navigation; after ten route changes the tab holds ten idle
> workers and several hundred megabytes. StrictMode makes this visible in development, which
> is the point of the rule.

```tsx
// src/features/Import/hooks/useGeojsonParser.ts
import { useEffect, useRef } from 'react'

export function useGeojsonParser() {
  const workerRef = useRef<Worker | null>(null)

  useEffect(() => {
    // new URL(..., import.meta.url) is what lets Vite emit the worker as its own chunk.
    const worker = new Worker(new URL('@/shared/workers/geojsonParse.worker.ts', import.meta.url), {
      type: 'module',
    })
    workerRef.current = worker
    return () => {
      worker.terminate()        // survives StrictMode: the remount creates a fresh worker
      workerRef.current = null
    }
  }, [])

  return workerRef
}
```

**[RT-13] MUST:** Worker files live in `src/shared/workers/` (or `src/features/<Name>/lib/`
for a feature-specific one), are named `<purpose>.worker.ts`, are created with
`new Worker(new URL('...', import.meta.url), { type: 'module' })`, and every message in both
directions is validated with a zod schema. Large binary payloads are passed as transferable
`ArrayBuffer`s, not copied.
> **Why:** A string path to a worker is not resolved by Vite's bundler and breaks in the
> production build only. `postMessage` is an untyped boundary, so a shape mismatch between
> worker and caller is a silent `undefined` three functions later ([GEN-07]). Transferring a
> 20 MB buffer is a pointer move; copying it is 20 MB of allocation on both sides. Cross-ref:
> [PERF-22], which owns the parsing threshold and the worker example.

**[RT-14] MUST:** Parsing or transforming input above **1 MB** (an uploaded GeoJSON or CSV, a
large export) happens in a worker; below that it runs inline. The threshold is checked on
`file.size` or `response.headers.get('content-length')`, not guessed from the feature name.
> **Why:** `JSON.parse` of 10 MB blocks the main thread for 300 to 900 ms on a mid-range
> device: the map stops panning and INP records the freeze ([PERF-23]). Under 1 MB the
> parse is around 20 ms, and the worker round trip plus the structured clone costs more than
> it saves.

---

## 6. Visibility, offline and multiple tabs

**[RT-15] MUST:** Message processing pauses while `document.hidden` is true: the queue keeps
accepting and coalescing but does not flush, and on `visibilitychange` back to visible the
app flushes once with the latest state per entity and resubscribes any topic whose
subscription the broker dropped.
> **Why:** `requestAnimationFrame` does not fire in a hidden tab, so a flush loop built on it
> stalls anyway, but the store keeps growing if the queue is unbounded. Explicitly pausing
> makes the behaviour the same on browsers that throttle rather than stop rAF, and the single
> flush on return means the user sees current data instead of a replay of the last hour.

```ts
// src/shared/lib/visibility.ts
export function onVisibilityChange(handler: (visible: boolean) => void): () => void {
  const listener = () => handler(!document.hidden)
  document.addEventListener('visibilitychange', listener)
  return () => document.removeEventListener('visibilitychange', listener)
}
```

**[RT-16] MUST:** Connection state (`connecting`, `connected`, `reconnecting`, `offline`) is
exposed by the client module and rendered as a non-blocking indicator; a stream that has
delivered nothing for more than **3 × keepalive** (90 s) is shown as stale rather than as
current data.
> **Why:** A frozen map of vehicles is indistinguishable from a map of parked vehicles.
> Without a staleness indicator, users make dispatch decisions on data from an hour ago and
> only discover the socket died when someone reloads. Cross-ref: [OBS-10], [GEN-15].

**[RT-17] SHOULD:** One connection per tab is accepted. Tabs do not coordinate, and each gets
its own client id ([RT-01]).
> **Why:** Five open tabs are five broker sessions, which for a municipal deployment (tens of
> concurrent operators) is a few hundred connections, well inside EMQX's capacity. The
> alternative costs a `SharedWorker` and a message-routing protocol, and is a real
> architectural change, not a tweak. See Open questions.

---

## 7. Topics, schemas and logging

**[RT-18] MUST:** Every payload is parsed with a zod schema before it is used, an invalid
message is dropped, and the warning is logged **once per topic per session** with the topic
name and the first issue path, never with the payload.
> **Why:** A device firmware update that changes `speed_kmh` to a string otherwise crashes a
> selector deep in a render. A per-message log for a 10 Hz topic writes 36,000 lines an hour
> to the error tracker and gets the project rate-limited; once per topic is enough to
> diagnose and cheap enough to leave on.

```ts
// src/shared/lib/mqttTopics.ts (excerpt)
const warnedTopics = new Set<string>()

function parseOrDrop<T>(topic: string, schema: ZodType<T>, raw: Uint8Array): T | null {
  const result = schema.safeParse(JSON.parse(new TextDecoder().decode(raw)))
  if (result.success) return result.data
  if (!warnedTopics.has(topic)) {
    warnedTopics.add(topic)
    // Path only. The payload may contain plate numbers and addresses ([RT-21]).
    logger.warn('mqtt.invalidPayload', { topic, path: result.error.issues[0]?.path.join('.') })
  }
  return null
}
```

**[RT-19] MUST:** Topic strings live in one `as const` object
(`src/shared/lib/mqttTopics.ts`), typed as a union; feature code references the constant. A
wildcard subscription (`+`, `#`) is allowed only for a documented, bounded set and never at
the root (`#` alone is forbidden).
> **Why:** A topic typo produces silence, not an error, and silence is the hardest bug to
> find in a push system. A root wildcard subscribes the browser to every device in the
> deployment, which is both a bandwidth problem and an authorisation problem ([RT-02] scopes
> the credential, but the client should not ask for what it cannot use).

**[RT-20] MUST:** Message schemas are versioned in the topic path
(`waste/trucks/position/v2`), the consumer subscribes to the versions it understands, and
unknown fields are ignored rather than rejected. A breaking change is a new version segment,
published alongside the old one until every consumer moves.
> **Why:** Devices in the field update on their own schedule, so producer and consumer are
> never deployed together. A version in the topic lets both run at once; a `version` field
> inside the payload does not, because the consumer has already subscribed and must parse
> what arrives. Ignoring unknown fields is what lets the producer add one without a frontend
> release, which is the same reasoning as [API-21].

**[RT-21] MUST:** Realtime logging records topic, direction, connection state, batch size and
timing. It never records payload contents: no plates, no addresses, no coordinates tied to a
person, no device identifiers that map to a household.
> **Why:** A live position stream is personal data about a driver. Logged payloads end up in
> the error tracker, which is a second system with a different retention policy and a wider
> audience. Cross-ref: [OBS-17], [SEC-25], [GIS-43].

---

## 8. Plain WebSocket and SSE

**[RT-22] MUST:** A raw `WebSocket` follows the same rules as the MQTT client: one instance
in `src/shared/lib/<name>Socket.ts`, lazily created, short-lived credential ([RT-02]),
same-origin `wss://` ([RT-03]), the backoff of [RT-04], the queue of [RT-10], the rate cap of
[RT-11] and the schema validation of [RT-18]. It additionally implements its own heartbeat
(a `ping` frame every 30 s and a 90 s dead-connection timeout).
> **Why:** The rules are transport-independent; only MQTT's library provides keepalive and
> reconnect for free. A raw socket without a heartbeat stays "open" through a NAT timeout
> and delivers nothing, forever, with no error event.

**[RT-23] MUST:** `EventSource` (SSE) is used for one-way, text-only streams and is subject
to the same lifecycle rules. Its limitations are accepted explicitly: no custom headers (so
authentication is the session cookie, same-origin only), and browsers cap HTTP/1.1
connections per origin at six, so at most **two** concurrent `EventSource` connections exist
per tab.
> **Why:** SSE reconnects and event ids come for free, which makes it the cheapest correct
> transport for a notification feed. The connection cap is the failure mode nobody predicts:
> a page with four SSE streams on HTTP/1.1 starves its own API calls, and the symptom is
> "requests hang after navigating to this page". nginx must set `proxy_buffering off` for the
> SSE location or events arrive in bursts when the buffer fills ([NGX-15]).

**[RT-24] MUST:** Updates slower than one per 30 seconds use TanStack Query with
`refetchInterval` instead of a persistent connection.
> **Why:** A socket held open for a value that changes twice an hour costs a connection, a
> credential refresh, a reconnect state machine and a test suite, to save two requests. The
> polling path already has caching, deduplication, retries and error handling ([STA-07]).

---

## 9. Timers and animation frames

**[RT-25] MUST:** Every `setTimeout`, `setInterval`, `requestAnimationFrame`,
`ResizeObserver`, `IntersectionObserver` and `addEventListener` created by realtime or media
code is cancelled in the same effect's cleanup ([GEN-21]), including the ones created inside
a callback.
> **Why:** A rAF loop whose cleanup cancels only the handle from the first frame keeps
> running forever, because each frame schedules the next one with a new handle. The tab then
> renders an unmounted component's animation at 60 Hz until it is closed. Store the handle in
> a ref and cancel the current one.

**[RT-26] MUST NOT:** `setInterval` drives rendering or animation. Interpolation and any
per-frame work use `requestAnimationFrame`, whose loop stops when the component unmounts or
the tab is hidden.
> **Why:** `setInterval(fn, 16)` does not align with the compositor, so frames are dropped or
> doubled and motion visibly stutters; it also keeps firing in a background tab on some
> browsers, burning battery to animate a map nobody is looking at. rAF is throttled to zero
> when hidden, which is the behaviour [RT-15] relies on.

---

## 10. Video

**[RT-27] MUST:** HLS playback tries the browser's native support first
(`video.canPlayType('application/vnd.apple.mpegurl')`, which is Safari and iOS) and falls
back to a **lazy-loaded** `hls.js` ([PERF-05]) only when native support is absent.
> **Why:** `hls.js` is roughly 130 KB gzipped and is useless on iOS, where Media Source
> Extensions are unavailable in the way it needs; using it there breaks playback that would
> have worked natively. Loading it statically puts 130 KB in the main chunk for a page most
> users never open.

```tsx
// src/features/Camera/components/HlsPlayer.tsx
import { useEffect, useRef } from 'react'

type Props = { readonly src: string; readonly posterUrl: string; readonly onError: () => void }

export function HlsPlayer({ src, posterUrl, onError }: Props) {
  const videoRef = useRef<HTMLVideoElement>(null)

  useEffect(() => {
    const video = videoRef.current
    if (!video) return
    let cancelled = false
    let hls: import('hls.js').default | null = null

    if (video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = src                                   // Safari/iOS: native, no library
      return () => { video.removeAttribute('src'); video.load() }
    }

    void import('hls.js').then(({ default: Hls }) => {
      if (cancelled || !Hls.isSupported()) return
      hls = new Hls({ maxBufferLength: 10, liveSyncDurationCount: 3 })
      hls.on(Hls.Events.ERROR, (_event, data) => { if (data.fatal) onError() })
      hls.loadSource(src)
      hls.attachMedia(video)
    })

    return () => {
      cancelled = true
      hls?.destroy()                                    // [RT-28]: releases the MSE buffers
      hls = null
    }
  }, [src, onError])

  return <video ref={videoRef} poster={posterUrl} muted playsInline controls preload="none" />
}
```

**[RT-28] MUST:** Every player is torn down in its effect cleanup: `hls.destroy()` for
`hls.js`, and for a native `<video>` clear `src` and call `load()`.
> **Why:** `hls.js` holds Media Source buffers, an XHR loader and its own timers; without
> `destroy()` an unmounted player keeps downloading segments. Six camera tiles opened and
> closed across a shift leave six streams running and the tab at a gigabyte. Leaving `src`
> set on a native video keeps the network connection open in Safari.

**[RT-29] MUST:** WebRTC (WHEP) streams are negotiated through a **same-origin** signalling
endpoint proxied by nginx with `proxy_buffering off`, and the deployment note records that
media travels over UDP on a port range that the site firewall must permit; where it does not,
a TURN server (or the HLS fallback) is required.
> **Why:** WHEP's SDP exchange is a single request/response, but with `proxy_buffering on`
> nginx holds the answer until its buffer fills and the offer times out. The firewall point
> is the one that actually kills deployments: signalling succeeds, ICE never completes, and
> the player shows a black rectangle with no error, because ICE failure is not an HTTP error.
> Municipal networks routinely block outbound UDP.

**[RT-30] MUST:** A `RTCPeerConnection` is closed in cleanup with `pc.close()` and every
local track stopped (`track.stop()`), and the `oniceconnectionstatechange` handler surfaces
`failed`/`disconnected` as a retryable player error rather than leaving the element black.
> **Why:** An unclosed peer connection keeps its ICE agent, its DTLS session and its media
> pipeline alive; the camera indicator stays on if local tracks were captured. ICE failure is
> the normal outcome behind a restrictive firewall ([RT-29]) and must be a visible state, not
> silence.

**[RT-31] MUST:** Autoplaying video is `muted` and `playsInline`, and the `play()` promise is
awaited with a catch that renders a play button when the browser refuses.
> **Why:** Every current browser blocks autoplay with sound, and the rejected `play()` promise
> is an unhandled rejection that reaches the error tracker ([OBS-07]) as noise. `playsInline`
> is what stops iOS Safari taking the video fullscreen, which destroys a multi-camera grid.

**[RT-32] MUST:** Every player has a `poster`, an explicit error state with a retry, and a
per-page cap on simultaneously playing streams (**4** by default); tiles beyond the cap show
the poster and start on click.
> **Why:** [GEN-15] applies to video like any async UI. Nine HLS players at 2 Mbps is 18 Mbps
> and nine decode pipelines, which exceeds what a municipal desktop and its uplink handle; the
> symptom is every stream stuttering rather than one failing, so the cap is what keeps the
> page usable.

---

## 11. Testing

**[RT-33] MUST:** Realtime hooks are tested against a fake client injected by replacing the
`src/shared/lib/mqttClient.ts` factory with `vi.mock`, plus `vi.useFakeTimers()` for backoff
and rate caps. The suite proves: subscribe on mount, unsubscribe on unmount, ref-counting
(two consumers, one broker subscription, unsubscribe only after both unmount), backoff delays
at attempts 1/2/3, and that an invalid payload is dropped with exactly one warning.
> **Why:** Real timers make a backoff test take 30 s and make it order-dependent. A fake
> client is also the only way to inject a malformed payload, which is the case that matters
> most and never occurs in a happy-path integration test. Cross-ref: [TEST-24].

**[RT-34] MUST:** The backpressure path has a test that pushes **100** messages inside one
frame and asserts exactly **one** flush and one render.
> **Why:** Coalescing is the rule most likely to be removed by a well-meaning refactor
> ("why is this queued? just dispatch it"). A test that counts renders is the only thing that
> notices before production does.

```ts
// src/shared/lib/messageQueue.test.ts
it('coalesces a burst into one flush with the latest message per id', () => {
  vi.useFakeTimers()
  const flush = vi.fn()
  const queue = createCoalescingQueue<{ id: string; n: number }>((m) => m.id, flush)

  for (let n = 0; n < 100; n += 1) queue.push({ id: n % 5 === 0 ? 'a' : 'b', n })
  vi.advanceTimersToNextFrame()

  expect(flush).toHaveBeenCalledTimes(1)
  expect(flush.mock.calls[0]?.[0]).toHaveLength(2)   // two ids, latest value each
  queue.dispose()
})
```

---

## Open questions

- **`SharedWorker` for a single connection across tabs.** [RT-17] accepts one connection per
  tab. A `SharedWorker` would hold one broker session per browser profile and broadcast to
  tabs over `MessagePort`, at the cost of a routing protocol, a leader-election fallback for
  browsers without `SharedWorker` support, and much harder debugging. Decide when a
  deployment reports broker connection pressure (more than roughly 2,000 concurrent web
  sessions) or when operators routinely keep more than five tabs open.
- **A typed worker RPC wrapper.** [RT-13] and [PERF-22] both hand-roll `postMessage` plumbing
  with zod on both sides. A small internal helper in `src/shared/lib/` would remove the
  duplication; an external package (`comlink`) needs [VER-06] approval and adds a proxy layer
  that obscures transferables. Revisit at the third worker.
- **MQTT 5 shared subscriptions.** `$share/<group>/<topic>` would let several tabs split a
  high-volume topic. Not used, because every tab needs the full picture for the map. Would
  become relevant only for a background ingest tab, which does not exist.
