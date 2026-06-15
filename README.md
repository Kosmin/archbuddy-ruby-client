# archbuddy-ruby-client

The **Ruby client** for the [architecture-auditor](https://github.com/Kosmin/architecture-auditor)
engine. It captures a language-agnostic execution/call **graph** from a Ruby codebase and reconnects
the engine's findings back to real code locally.

## What this repo owns

- **Collector** (`collect`): a static-AST adapter (via `prism`) that walks a Ruby codebase into
  method-level nodes + directed call/db/endpoint/external edges, then **anonymizes** them — emitting:
  - `graph.yml` — shareable, **opaque** node-ids, zero app semantics (safe to hand to the engine).
  - `id-map.yml` — **SECRET**, local-only, gitignored: maps each opaque id → `file:line:symbol`.
- **Reconnect + Report** (`report`): joins the engine's `findings.yml` back against the secret
  `id-map.yml` to produce a **ranked clutter report** scored against real code symbols.

The pluggable `Adapter` interface means a future React/Node.js client is a new adapter, not a rewrite.

## Data flow

```
your repo ──> archbuddy collect ──> graph.yml + id-map.yml(SECRET)
graph.yml ──> architecture-auditor analyze ──> findings.yml
findings.yml + id-map.yml ──> archbuddy report ──> ranked clutter report
```

`id-map.yml` **never leaves this machine** and is the only thing that can de-anonymize the graph.

## Requirements

- Ruby **>= 3.2** (see `.ruby-version`).
- Depends on the `architecture_auditor` gem (git source) for the shared contract
  (schemas + `Ids`/`Serializer`/`Validator`).

## CLI (this repo)

```
archbuddy collect PATH --out-dir ./out      # → out/graph.yml + out/id-map.yml
archbuddy report findings.yml --id-map ./out/id-map.yml   # → ranked clutter report
```

## Status

Greenfield. See `docs/IMPLEMENTATION_PLAN.md` for the verified build plan (Phase B-Track-1 + Phase C).
