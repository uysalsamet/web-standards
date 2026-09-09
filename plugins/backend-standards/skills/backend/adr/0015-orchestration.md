# ADR-0015 — Orchestration: Docker Compose

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [OPS-09], [OPS-11], [PERF-04], [PERF-30]

## Context

Services are containerized ([OPS-01]). We need a mechanism to run them in both development
and production.

## Options

### A) Docker Compose (CHOSEN)
**Strengths:** One file, one command, zero learning cost. Development and production use
the **same** file (with a different `--env-file`), reducing "works on my machine" bugs.
Resource limits ([PERF-04]), healthcheck-based dependencies ([OPS-10]), and log rotation
([OPS-12]) are supported.
**Weaknesses:** Single machine. No autoscaling, no self-healing, no rolling updates, no
distributed scheduling. `restart: unless-stopped` provides only limited resilience.

### B) Kubernetes
**Strengths:** Horizontal scaling, self-healing, rolling updates, service discovery,
secret management, multi-node. The industry standard.
**Weaknesses:** **A large operating burden.** Cluster setup and management, ingress, CNI,
storage classes, RBAC, Helm/Kustomize, all to learn and maintain. For a system running on
one machine, k8s creates more problems than it solves. A managed service (EKS/GKE) reduces
this burden but raises cost and cloud lock-in.

### C) Nomad
**Strengths:** Noticeably simpler than k8s; a single binary, easy to learn. Has multi-node
and scheduling.
**Weaknesses:** A much smaller ecosystem than k8s. Fills the gap, but sits in an awkward
spot, "not as simple as compose, not as widely used as k8s".

### D) Docker Swarm
**Strengths:** Very close to the Compose file, adds multi-node.
**Weaknesses:** Development has effectively stopped; not preferred for new projects.

## Decision

**Docker Compose.**

The same logic as [PERF-30]: **vertical first, horizontal later.** Setting up Kubernetes
for a system that can run on one machine means taking on a serious operating burden to
solve a problem that does not yet exist. Starting with Compose does not block a later move
to k8s either, container images, healthchecks, env-based config ([OPS-14]), and stateless
services ([PERF-29]) are exactly what k8s expects. A system that follows this standard is
already **ready** to move to k8s when needed.

## Accepted costs

- A single-machine limit; if that machine goes down, the system goes down.
- No rolling updates, brief downtime during deploys is possible. That is why the
  "old and new version run at the same time" rule in [OPS-25] still matters, to be ready
  for when we move to k8s.
- No autoscaling; replica count is set by hand.

## What would change this decision

- **If high availability becomes a genuine requirement** (a single-machine outage becomes
  unacceptable), we move to k8s.
- If traffic exceeds a single machine's capacity, scale up vertically first ([PERF-30]),
  then move to k8s.
- If the team builds k8s operating capacity and manages multiple environments, the
  migration cost drops and the decision is reconsidered.
