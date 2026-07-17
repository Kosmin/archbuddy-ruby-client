# .claude/docs Registry

Deeper topics that don't belong in the root pyramid. Last updated: 2026-07-17.

| File | Contents | Last Updated |
|------|----------|--------------|
| [resolver.md](resolver.md) | The tiered Ruby call-site resolver (R0–R9): full tier table (v0.10: R1 narrowed to dynamic meta; R5 = Grape→Dispatch→MetaSend→Egress), the AR implicit-self gotcha, db_op/external/endpoint classification, per-target egress sub-sinks (v0.11 E1) | 2026-07-17 |
| [adapter-extension.md](adapter-extension.md) | The language-adapter seam: what's language-agnostic vs Ruby-specific, the adapter contract (incl. v0.10 `entrypoint_kind`/`terminal_kind`, v0.11 per-target egress sub-sinks + diagnostics keys), + a concrete JavaScript/TypeScript + React/React-Native build guide mirroring the root-seeder + egress seams (engine needs zero changes) | 2026-07-17 |
| [cross-repo.md](cross-repo.md) | The two-repo system: this client ↔ the `architecture_auditor` engine; the shared Contract; what crosses the boundary and what must not; the version/changelog block (client 0.10.0 / engine 0.8.0 — graph 1.3, findings 1.6 read nil-tolerantly, SERIALIZER v3 client-owned) | 2026-07-17 |

For the committed incremental `.archbuddy/` cache (the v0.8 headline), see `ARCHITECTURE.md` →
[Concern 3](../../ARCHITECTURE.md) and the audited-repo guide `docs/COMMITTING_ARCHBUDDY.md`.
