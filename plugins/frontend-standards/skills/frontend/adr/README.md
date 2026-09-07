# Architecture Decision Records

> **ADR = Architecture Decision Record.** For every significant technical choice: what we
> chose, what the alternatives were, each one's strengths and weaknesses, why we chose this
> one, what it costs us, and **what would change the decision**.
>
> **Why they exist:** a rule without a reason is deleted by the first person who dislikes
> it. "Why MapLibre, why not Leaflet?" gets asked by every new developer and every new AI
> session. These records hold that discussion once, close it, and say where to look if the
> decision turns out to be wrong.

---

## How to read them

- Before arguing about a choice, read its ADR. It has probably been argued already.
- If you have information the ADR does not list (a new major, a measurement, a licence
  change), reopen it. "I think X is nicer" on its own is not enough.
- Each ADR ends with **"What would change this decision"**. If that condition holds, it is
  time to revisit.

## Status labels

| Status | Meaning |
|---|---|
| **Accepted** | In force. Applied in the standard. |
| **Under review** | New information; being re-evaluated. |
| **Superseded** | Replaced by another ADR; which one is stated. |
| **Rejected** | Evaluated, not adopted. The reason stays on record. |

An ADR is **never deleted**. A wrong one is marked Superseded and a new one is written; the
record of the wrong decision is as valuable as the right one.

---

## Records

### Toolchain and language
| # | Decision | Chosen | Status |
|---|---|---|---|
| [0001](0001-build-tool.md) | Build tool | **Vite 8** | Accepted |
| [0002](0002-ui-framework.md) | UI framework | **React 19 + React Compiler** | Accepted |
| [0003](0003-language.md) | Language and strictness | **TypeScript 6, strict, no escape hatches** | Accepted |
| [0018](0018-package-manager.md) | Package manager | **npm + `npm ci`** | Accepted |
| [0019](0019-linting.md) | Lint and format | **ESLint 10 type-aware + Prettier** | Accepted |

### Application architecture
| # | Decision | Chosen | Status |
|---|---|---|---|
| [0004](0004-server-state.md) | Server state | **TanStack Query** | Accepted |
| [0005](0005-client-state.md) | Cross-feature client state | **Redux Toolkit (narrow scope)** | Accepted |
| [0006](0006-routing.md) | Routing | **React Router 7, data mode, no loaders for data** | Accepted |
| [0007](0007-styling.md) | Styling | **Tailwind 4 + scoped CSS, no runtime CSS-in-JS** | Accepted |
| [0011](0011-i18n.md) | Internationalisation | **i18next + typed keys + parity check** | Accepted |
| [0015](0015-forms.md) | Forms | **react-hook-form + zod** | Accepted |
| [0016](0016-testing.md) | Testing | **Vitest + Testing Library + MSW + Playwright** | Accepted |
| [0017](0017-auth-token-storage.md) | Auth token storage | **HttpOnly cookie session via gateway** | Accepted |
| [0020](0020-error-tracking.md) | Error tracking | **Sentry-protocol client, self-hosted backend** | Accepted |

### Map and geodata
| # | Decision | Chosen | Status |
|---|---|---|---|
| [0008](0008-map-library.md) | Map library | **MapLibre GL 5** | Accepted |
| [0009](0009-marker-rendering.md) | Marker rendering | **GPU layers; DOM markers only for rich widgets** | Accepted |
| [0010](0010-geodata-delivery.md) | Geodata delivery | **GeoJSON ≤ 5k features, else MVT/PMTiles** | Accepted |
| [0021](0021-realtime-transport.md) | Realtime transport | **MQTT over WebSocket** | Accepted |

### Delivery and operations
| # | Decision | Chosen | Status |
|---|---|---|---|
| [0012](0012-seo-strategy.md) | SEO strategy | **Template build + request-time meta injection / SEO-route SSR** | Accepted |
| [0013](0013-static-serving.md) | Static serving | **nginx serves `dist/` directly** | Accepted |
| [0014](0014-runtime-config.md) | Runtime configuration | **`/config.js` rendered at container start** | Accepted |

---

## Writing a new ADR

File name: `NNNN-short-topic.md` (number increases, never reused).

```markdown
# ADR-NNNN — <Topic>: <Chosen option>

- **Status:** Accepted
- **Date:** YYYY-MM-DD
- **Related rules:** [XXX-NN], [YYY-NN]

## Context
Which problem are we solving? Why do we have to decide?

## Options

### A) <Option> (CHOSEN)
**Strengths:** …
**Weaknesses:** …

### B) <Option>
…

## Decision
What we chose and **why**. The reason must rest on a measurement, a constraint or a concrete
risk. "More modern" and "everyone uses it" are not reasons.

## Accepted costs
What this choice costs us. Every decision gives something up; if nothing is given up, the
record is not honest.

## What would change this decision
Which concrete development would make us reopen this record?
```

**Rule:** "Accepted costs" cannot be empty. If you wrote a decision with no cost, either
the alternatives were not examined or the decision was never contested; in the second case
an ADR was not needed.
