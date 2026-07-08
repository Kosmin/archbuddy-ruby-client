# .claude/docs Registry

Deeper topics that don't belong in the root pyramid. Last updated: 2026-07-08.

| File | Contents | Last Updated |
|------|----------|--------------|
| [resolver.md](resolver.md) | The tiered Ruby call-site resolver (R0–R9): full tier table, the AR implicit-self gotcha, db_op/external/endpoint classification | 2026-06-15 |
| [adapter-extension.md](adapter-extension.md) | The language-adapter seam: what's language-agnostic vs Ruby-specific, the adapter contract, + a concrete JavaScript/TypeScript + React/React-Native build guide (engine needs zero changes) | 2026-07-08 |
| [cross-repo.md](cross-repo.md) | The two-repo system: this client ↔ the `architecture_auditor` engine; the shared Contract; what crosses the boundary and what must not | 2026-06-15 |

For the committed incremental `.archbuddy/` cache (the v0.8 headline), see `ARCHITECTURE.md` →
[Concern 3](../../ARCHITECTURE.md) and the audited-repo guide `docs/COMMITTING_ARCHBUDDY.md`.
