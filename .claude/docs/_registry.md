# .claude/docs Registry

Deeper topics that don't belong in the root pyramid. Last updated: 2026-07-13.

| File | Contents | Last Updated |
|------|----------|--------------|
| [resolver.md](resolver.md) | The tiered Ruby call-site resolver (R0–R9): full tier table (v0.10: R1 narrowed to dynamic meta; R5 = Grape→Dispatch→MetaSend→Egress), the AR implicit-self gotcha, db_op/external/endpoint classification, category egress sinks | 2026-07-13 |
| [adapter-extension.md](adapter-extension.md) | The language-adapter seam: what's language-agnostic vs Ruby-specific, the adapter contract (incl. v0.10 `entrypoint_kind`/`terminal_kind` + diagnostics keys), + a concrete JavaScript/TypeScript + React/React-Native build guide mirroring the root-seeder + egress seams (engine needs zero changes) | 2026-07-13 |
| [cross-repo.md](cross-repo.md) | The two-repo system: this client ↔ the `architecture_auditor` engine; the shared Contract; what crosses the boundary and what must not; the v0.10 gated-additive posture (graph 1.3 stamps behind the acceptance gate, findings 1.5 read nil-tolerantly) | 2026-07-13 |

For the committed incremental `.archbuddy/` cache (the v0.8 headline), see `ARCHITECTURE.md` →
[Concern 3](../../ARCHITECTURE.md) and the audited-repo guide `docs/COMMITTING_ARCHBUDDY.md`.
