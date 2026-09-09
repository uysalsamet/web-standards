# ADR-0006 — Configuration: os.LookupEnv

- **Status:** Accepted
- **Date:** 2026-08-12
- **Related rules:** [VER-08], [STR-15], [STR-16], [OPS-14]

## Context

Config comes from the environment ([GEN-13]), never hardcoded. The question is whether to
use a library to read it.

## Options

### A) os.LookupEnv + a manual `getEnv` helper (CHOSEN)
**Strengths:** Zero dependencies. The config-loading flow is understandable **by
reading it**: which variable comes from where and what its default is, all visible in one
file. We decide what happens on a malformed value (like the explicit `panic` in [STR-15]).
**Weaknesses:** One line per field; repetition grows with the number of fields.

### B) viper
**Strengths:** Merges env + file (yaml/toml/json) + flags + remote config, supports live
reload.
**Weaknesses:** A heavy dependency with a wide dependency tree. Precedence order (does env,
file, or flag win) is magic and hard to debug. We need **none** of these features: in a
12-factor app, env is the single source.

### C) kelseyhightower/envconfig or caarlos0/env
**Strengths:** Declarative via struct tags (`env:"DB_HOST"`), less repetitive code.
**Weaknesses:** Still a dependency; the gain is ~20 lines. Because it works via reflection,
error messages are less clear.

### D) koanf
**Strengths:** A lighter, more modular alternative to viper.
**Weaknesses:** Still solves a problem we do not have (multi-source config).

## Decision

**os.LookupEnv.** We have exactly one config source: **env**. We do not need files, a
remote server, or live reload, and not needing them is deliberate: a running process's
configuration changing out from under it is a hard-to-diagnose class of bug.
Reconfiguration means redeploying.

## Accepted costs

- One line of repeated code per config field.
- We give up the readability advantage of declarative tags.

## What would change this decision

- If a service's number of config fields exceeds 30, `caarlos0/env` is evaluated.
- If a real dynamic configuration need appears (e.g. feature flags), that is **not a
  config problem, it is a separate one** and gets its own ADR.
