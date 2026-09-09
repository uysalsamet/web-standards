# ADR-0008 — Messaging: Postgres queue first, Kafka (franz-go) if needed

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [ASYNC-01], [ASYNC-03], [ASYNC-11], [ASYNC-17]

## Context

There are two separate questions here, and they get mixed up often:
1. **What do we use as async infrastructure?** (Kafka, NATS, a queue, or none)
2. If Kafka is used, **which Go client?**

## Options — infrastructure

### A) A Postgres-based job queue, the default starting point (CHOSEN)
Via `FOR UPDATE SKIP LOCKED` ([ASYNC-03]).
**Strengths:** **No new infrastructure component.** You can enqueue work **in the same
transaction** as the application data, which resolves the outbox problem ([ASYNC-17]) by
construction. Backup, monitoring, and access control already exist. More than enough for
small/medium load.
**Weaknesses:** Wears on the DB at very high volume (tens of thousands of messages per
second). Fan-out (distributing one event to many consumers) has to be built by hand. No
durable event-log semantics.

### B) Kafka 4.3.1, once scale/fan-out is needed (CHOSEN, second stage)
**Strengths:** A durable, replayable event log. One event can be read by **multiple**
independent consumers, and a consumer joining later can process history from the start.
Partitioning gives horizontal scale plus per-key ordering. KRaft removed the ZooKeeper
dependency.
**Weaknesses:** High operating cost, cluster, disk, retention, partition planning,
monitoring. Getting the partition count wrong is a painful thing to fix later
([ASYNC-16]).

### C) NATS JetStream
**Strengths:** Much lighter than Kafka; a single binary, easy to operate. Supports both
request/reply and streams. Low latency.
**Weaknesses:** Smaller ecosystem and operational track record than Kafka. The
connector/CDC world (Debezium etc.) is built around Kafka. Less established than Kafka for
long-lived event-log scenarios.

### D) RabbitMQ
**Strengths:** Rich routing (exchange/binding), mature, well known.
**Weaknesses:** A **queue**, not an event log, once consumed a message is gone and history
cannot be replayed. This is the opposite of what we need (publish an event, let a late
joiner consume it).

### E) Redis Streams
**Strengths:** If Redis is already present, no extra component.
**Weaknesses:** Durability guarantees are not at Kafka's level; puts Redis in a critical
role outside caching. Conflicts with [CACHE-24].

## Options — Kafka Go client

### F) franz-go v1.21.6 (CHOSEN)
**Strengths:** Actively developed, supports the full protocol (transactions/exactly-once,
KRaft, every consumer-group detail), **no cgo**, good performance.
**Weaknesses:** A lower-level API than segmentio's; a somewhat steeper learning curve.

### G) segmentio/kafka-go v0.4.51
**Strengths:** Simple, readable API; quick to get started.
**Weaknesses:** Development has slowed (last release April 2026). Weak transaction
support.

### H) confluent-kafka-go
**Strengths:** Wraps librdkafka; the most mature protocol implementation.
**Weaknesses:** **Requires cgo**, which conflicts with our goal of static binaries and
`CGO_ENABLED=0` alpine images ([OPS-01]).

### I) IBM/sarama
**Strengths:** Long history, very widely used.
**Weaknesses:** Maintenance has been handed off; its API carries historical baggage.

## Decision

**Progress in order** ([ASYNC-01]):
1. Work < 300 ms with the client waiting for the result → **synchronous**, no queue.
2. Long but single-consumer work → **Postgres queue**.
3. An event listened to (or to be listened to) by **more than one** service → **Kafka +
   franz-go**.

Setting up Kafka up front "because we'll need it eventually" pays the operating cost before
the benefit. Moving from a Postgres queue to Kafka is mechanical if the outbox pattern
([ASYNC-17]) is already in place.

The choice of franz-go was settled by the cgo ban and its transaction support.

## Accepted costs

- We give up NATS JetStream's operational ease; once we move to Kafka we run heavier
  infrastructure.
- We may need a thin wrapper around franz-go's lower-level API.
- The two-stage approach creates a migration task at the transition point.

## What would change this decision

- If the team lacks Kafka operating capacity and a fan-out need arises, **NATS JetStream**
  is seriously reconsidered, it is the closest alternative.
- A need for Debezium/CDC or stream processing (Flink etc.) makes Kafka unavoidable.
- If the Postgres queue grows into a measurable share of DB load (monitored), it is time
  to move to Kafka.
