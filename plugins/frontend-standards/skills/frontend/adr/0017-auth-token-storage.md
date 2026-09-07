# ADR-0017 — Auth token storage: HttpOnly session cookie issued by the gateway

- **Status:** Accepted
- **Date:** 2026-09-07
- **Related rules:** [AUTH-01], [AUTH-04], [AUTH-05], [SEC-16], [SEC-17], [SEC-18], [API-05], [API-28], [GEN-22], [STA-38]

## Context

The frontend is a static bundle served by nginx from the same origin as the API, which is
proxied under `/api/` ([GEN-22]). The question is where the credential that authenticates each
request lives, which decides:

- what an XSS can steal (a token that works for its whole lifetime, or nothing);
- what CSRF defence is required;
- how a 401 is recovered from and whether concurrent requests can stampede the refresh endpoint;
- whether the same session works across subdomains or a future mobile client;
- how much auth code exists in the SPA at all.

The reference codebase holds an access token in a module-level variable plus a mirror in web
storage, sets `Authorization: Bearer ...` from `getBearerHeaders()`, keeps a refresh token in a
cookie, and duplicates the permission list into `localStorage`. It also has the failure mode
this decision is meant to remove: a page with eight parallel queries hitting an expired token
issues eight refreshes.

Both the gateway and the browser are ours, on one origin. That is the constraint that makes the
cheapest option also the safest.

## Options

### A) HttpOnly session cookie issued by the gateway, no token in the SPA (CHOSEN)

The gateway authenticates, sets `HttpOnly; Secure; SameSite=Lax; Path=/api`, and maps the cookie
to whatever it uses internally (an opaque session, or a JWT it holds itself). The SPA sends
`credentials: 'include'` and calls `GET /api/auth/me` on boot.

**Strengths:**
- An XSS cannot read the credential. It can act as the user while the page is open, which is
  bad, but it cannot exfiltrate a token that keeps working from the attacker's own machine after
  the tab is closed. This is the entire point.
- Nothing survives the browser session in storage, so a shared counter workstation does not carry
  the previous user's credential into the next person's session ([AUTH-04]).
- The SPA's auth code shrinks to: one `me` query, one single-flight refresh ([AUTH-05]), one
  logout, three guards. No token parsing, no expiry arithmetic, no clock-skew handling, no
  storage synchronisation.
- Same-origin means no CORS, no preflight on every request, and no `Access-Control-Allow-Credentials`
  configuration to get wrong ([GEN-22]).
- Map tiles, image `src` and file downloads authenticate for free, because the browser attaches
  the cookie itself. With a bearer token each of those needs `transformRequest`, a blob fetch, or
  a signed URL ([AUTH-06], [MAP-24]).
- Revocation is real: the gateway drops the session and the next request fails. A stateless JWT
  is valid until it expires no matter what the server thinks.

**Weaknesses (accepted, see below):**
- CSRF becomes relevant, because the browser attaches the cookie to cross-site requests within
  the limits of `SameSite`. This is handled by three layers in [SEC-17], but it is a surface that
  option C does not have.
- The session works only where the cookie is scoped. Serving the same SPA from a second domain,
  or calling a different origin's API, does not work without more configuration.
- A native mobile client cannot reuse this scheme comfortably; it needs a token endpoint of its
  own on the gateway.
- The SPA cannot read the expiry time, so it cannot pre-emptively refresh or show "your session
  ends in 3 minutes" from the credential itself. The idle timeout ([AUTH-26]) is a client-side
  approximation, and the authoritative answer is always a 401.
- One extra round trip on boot (`me`) before any route renders ([AUTH-16]).

### B) JWT in `localStorage`, `Authorization: Bearer` set by the client

**Strengths:** Trivially works across origins and subdomains; identical code path for a mobile
client; no CSRF because nothing is attached automatically; the client can read `exp` and refresh
ahead of time; every tutorial describes it.
**Weaknesses:** One XSS, one malicious npm postinstall, or one compromised transitive dependency
reads the token and uses it from anywhere until it expires. `localStorage` is shared by every
script on the origin, has no expiry, and persists across browser restarts. Logging out cannot
invalidate a stateless JWT that has already been copied. This is the pattern [AUTH-04] exists to
forbid, and the check script fails the build on it.

### C) JWT in memory only, refresh token in an HttpOnly cookie

**Strengths:** Survives an XSS better than B (the token is not in storage, so a script must run
while the page is open), no CSRF on the API calls themselves, works cross-origin, and a mobile
client can reuse most of the flow.
**Weaknesses:** An XSS running in the page can still read the in-memory token, and can simply
call the refresh endpoint to mint fresh ones, so the improvement over B is smaller than it looks.
A full page reload loses the access token and requires a refresh round trip anyway, so the "extra
boot request" cost of option A is not actually saved. The refresh cookie still needs CSRF
protection on the refresh endpoint. And the SPA carries the whole machinery: expiry tracking,
clock skew, a single-flight refresh, a queue of paused requests, and header injection into
MapLibre and every download. That is the code the reference implementation already has, and it is
where its bugs are.

### D) Backend-for-frontend (a dedicated BFF process that holds tokens and proxies the API)

**Strengths:** The strongest option on paper: tokens never leave the server, upstream APIs can be
third-party or multi-tenant, per-user rate limiting and response shaping become possible, and it
is the recommended pattern for browser clients talking to external OAuth providers.
**Weaknesses:** A new deployable service, with its own image, health check, scaling, session
store and on-call surface, added to every municipal deployment. When the API is already ours and
already behind the same nginx, the gateway **is** the BFF: option A is option D without a second
process. It buys nothing here and costs an operational unit per site.

## Decision

**Option A.** The gateway issues an `HttpOnly; Secure; SameSite=Lax; Path=/api` session cookie
and the SPA never handles a credential ([AUTH-01], [SEC-16]). CSRF is covered by three
independent layers ([SEC-17]): `SameSite=Lax`, a required `X-Requested-With` header that a
cross-origin page cannot add without a preflight the gateway does not answer, and an
`Origin`/`Sec-Fetch-Site` check. A 401 is recovered by one single-flight
`POST /api/auth/refresh` and one replay ([AUTH-05], [API-28]); a second 401 logs out
([AUTH-07]).

The decisive reason is not "cookies are more secure than localStorage" in the abstract. It is
that on a same-origin deployment with our own gateway, option A removes an entire category of
client code (token lifecycle, header injection, storage sync) **and** removes the
token-exfiltration class of attack, while its one new surface (CSRF) is closed by configuration
we control on both sides.

## Accepted costs

- **CSRF is now in scope.** Three layers are required, and the gateway must actually enforce the
  header and origin checks. If it stops enforcing them, `SameSite=Lax` alone is the only defence
  left, and it does not cover every browser quirk. This must be verified after gateway changes,
  not assumed.
- **Multi-domain is out.** Serving the same application from `belediye.gov.tr` and
  `harita.belediye.gov.tr` against one session requires a shared parent-domain cookie and the
  wider CSRF exposure that comes with it. Two separate origins mean two logins.
- **Mobile app reuse is not free.** A native client needs its own token-issuing endpoint on the
  gateway, with its own storage decision made in that platform's terms (Keychain, Keystore). This
  ADR does not cover it, and the frontend rules must not be cited as if it did.
- **No client-side expiry knowledge.** The SPA cannot warn "session ends in 3 minutes" from the
  credential. The idle timeout ([AUTH-26]) is a client-side approximation of a server-side fact,
  and the two can disagree.
- **`Path=/api` cookie scoping.** It keeps the cookie off static asset requests, but it also means
  anything outside `/api/` that needs authentication (a tile service under `/tiles/`) must either
  be moved under the cookie's path, get its own cookie, or use a short-lived credential
  ([SEC-19]). This is a real deployment constraint, not a detail.
- **One extra boot round trip.** `GET /api/auth/me` before the first route renders ([AUTH-16]),
  which is roughly 30 to 80 ms on a local network and is spent under a skeleton.
- **The SPA cannot log the user out of other devices or read the session list** without dedicated
  endpoints; nothing about the session is inspectable from the browser.

## What would change this decision

- **A third-party API that the gateway cannot proxy** and that requires an OAuth token from the
  browser. That is the case option D exists for, and it would mean adding a BFF rather than
  moving tokens into the SPA.
- **A native mobile client sharing the frontend's auth code.** Today it does not exist. If one is
  built and code sharing turns out to matter more than the exfiltration risk, option C becomes the
  serious contender, and the mitigation cost (token lifecycle in the SPA) must be budgeted
  explicitly.
- **A deployment that must serve one session across two origins.** Cross-origin cookies with
  `SameSite=None` are a materially different risk profile and would justify reopening this.
- **Evidence that the gateway's CSRF enforcement cannot be relied on** (for example an
  organisation-wide reverse proxy that strips custom headers). Then either a synchroniser token
  is added, or the model changes.
- **Browser changes to third-party or partitioned cookie behaviour** that affect same-site
  first-party cookies. This is unlikely for a same-origin deployment, but it is the platform
  assumption the whole decision rests on.
