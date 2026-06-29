# The two-repo system: client ↔ engine

`archbuddy-ruby-client` (this repo) is **one half** of an architecture-clutter auditor. The other half is
the **core engine** `architecture_auditor`, a sibling checkout at `../architecture-auditor`
(remote: `Kosmin/architecture-auditor`).

```
┌─────────────────────────────┐         ┌──────────────────────────────┐
│ archbuddy-ruby-client (HERE) │         │ architecture_auditor (ENGINE) │
│  • Collector (collect)       │ graph   │  • Contract (shared hub)      │
│  • Reporter  (report)        │ ───────▶│  • Processor (analyze)        │
│  depends on the Contract ────┼─────────┤    graph → findings           │
└─────────────────────────────┘ findings└──────────────────────────────┘
```

## Who owns what

| Concern | Repo |
|---------|------|
| Capturing a Ruby codebase → opaque graph + secret id-map | **client** (`collect`) |
| The shared **Contract** — `Ids`, `Serializer`, `Validator`, graph/findings JSON schemas, `SCHEMA_VERSION` | **engine** (`ArchitectureAuditor::Contract`) |
| Analyzing the graph → `findings.yml` (metrics + clutter scores + findings) | **engine** (`ArchitectureAuditor::Analyze`, `analyze` CLI) |
| Re-joining findings to real symbols → ranked report | **client** (`report`) |

The client **depends on** the engine gem; the engine does not depend on the client. The Contract is the
dependency hub both halves share and is forbidden (by an engine fitness spec) from referencing
collector/processor/reporter concepts.

## What crosses the boundary

| Artifact | Direction | Secrecy |
|----------|-----------|---------|
| `graph.yml` | client → engine | **Opaque, shareable.** Zero app semantics by construction (the Anonymizer guarantees it). |
| `findings.yml` | engine → client | Opaque (keyed by opaque ids). Safe to share. |
| `id-map.yml` | **stays in the client, on this machine** | **SECRET.** The engine NEVER receives it — `analyze` has no `--id-map` option by construction (D16/D18). Only `collect` (producer) and `report` (consumer) touch it. |

This is the core safety property: the engine can analyze the graph **without ever seeing real code
symbols**. De-anonymization happens only locally, in the client's `report`, against the local secret map.

## Dependency wiring (M2 finalized — D47)

The `Gemfile` is wired so a **fresh standalone clone installs cleanly** AND a sibling checkout keeps
its local-dev ergonomics. The logic:

```ruby
if (engine_path = ENV["ARCHITECTURE_AUDITOR_PATH"].to_s.strip) && !engine_path.empty?
  gem "architecture_auditor", path: engine_path           # local dev (env override)
else
  gem "architecture_auditor",                              # distribution default
      git: "https://github.com/Kosmin/architecture-auditor.git", branch: "main"
end
```

- **Distribution default (D47):** the **git source** above. A fresh clone with no sibling checkout
  resolves the engine from git — no `Gemfile` edits required.
- **Local dev — two override modes (both keep the sibling at `../architecture-auditor` "just working"):**
  1. **Env override (one-off):** `ARCHITECTURE_AUDITOR_PATH=../architecture-auditor bundle install`
     swaps the git source for a `path:` source. Blank/unset → falls through to git.
  2. **Bundler local config (persistent):** `bundle config set --local local.architecture_auditor
     ../architecture-auditor` makes bundler resolve the *git* gem from that local checkout
     (it must be on the same branch — `main`).
- The **gemspec** declares `add_dependency "architecture_auditor", "~> 0.2"` (pessimistic bound,
  maintained at the 0.2.x floor; the engine is already at 0.3.0 in development but the gemspec bound
  has not been bumped since the client's `metric_kernel_consistency_spec` verifies compatibility at
  test time rather than via a hard version pin).

**Verified vs documented in this environment:** the env-override mode (Mode 1) and the bundler
local-config mode (Mode 2, which resolves the *git* source from the sibling — proving the git line is
syntactically valid and resolvable) both `bundle install` cleanly under `RBENV_VERSION=ruby-3.4.2`. A
**true remote git fetch** (no sibling at all) could not be exercised here because
`Kosmin/architecture-auditor` is a local-only repo not published over HTTPS — that line is the
documented distribution default, verified resolvable via the local override but not fetched from the
remote.

## Versions and release sequence

The client is at **0.4.0**; the engine is at **0.3.0**. The mandatory release sequence is **engine
`main` first, then client**: the client's `metric_kernel_consistency_spec` loads the live engine
`METRIC_KEYS` constant at test time, so the engine must already carry a matching version before the
client suite can be verified green.

### v0.4.0 client bump (W4+W5) — engine 0.3.0

The client v0.4.0 adds the v0.3 sink-concentrated scoring support on top of the v0.3.0 framework-probe
release. Two waves, both committed on the `feat/sink-concentrated-cost` branch:

**W4 (collector):** De-idiomatizes `BranchCounter` (V7/P5) — only business control flow
(`if`/`unless`/`case`/`while`/`until`/`for`) multiplies into `branches`; idioms (`&&`/`||`, `&.`,
`||=`/`&&=`, `rescue`, pattern-match predicates) counted in `decisions` only. Adds `sink_open` capture
(V4/P4): classifies each AR call site's op-kind via `Vocab::AR_WRITE`/`AR_DESTROY`/`ar_op_kind`, with
`DbOpSpec` write-specificity (symbol-keyed literal = specific; variable/splat/string-SQL = open_ended,
the SAFE default), aggregated least-specific-wins, emitting ONLY `sink_open: bool` on `db_op` graph
nodes (graph 1.2). No `sink_op`/`sink_fields` field; engine derives U from topology (`in_degree`).

**W5 (reporter):** Adds `Scores::Connectivity` struct (CR-1 four-field shape: `forward`/`reverse`/
`scored_nodes`/`total_nodes`, no `verdict`) parsed from findings 1.3 `scores.connectivity`. Threads
connectivity through `Reconnect::Result` → `RenderContext`. Terminal formatter renders a one-line
`Connectivity: N/total nodes scored (P%)` banner ABOVE the dimension rows (nil → no banner, back-compat).
HTML formatter renders `<div class="connectivity">` before `.cards` (nil → `""`, HTML-escaped). All
figures are engine-emitted and formatted verbatim (D17 — client never recomputes ratios/counts).

The engine was released at 0.3.0 (engine-main-first) before these client waves. The gemspec dep
`~> 0.2` is UNCHANGED at the gem level — the client remains compatible with engine 0.2.x — but the
sibling checkout used in development is engine 0.3.0.

### v0.3.0 client bump — engine UNCHANGED at that step

The client v0.3.0 added the framework-probe seam and concrete probes (`grape`, `sidekiq_dispatch`) plus
the Rails-routes entrypoint seeder. This was **entirely collector-side**: the engine was UNCHANGED and
there was **NO contract/schema change** (graph `"1.1"` / findings `"1.2"` / `SUPPORTED_VERSIONS`
untouched; the `endpoint` node kind pre-exists). The engine gemspec dep `~> 0.2` was UNCHANGED because
the engine remained at 0.2.0. No engine release was required.

**Agnostic boundary preserved — even for a future dynamic pass.** The static probe seam (v0.3.0) reads
only the Prism AST — it never executes or loads the audited app. This preserves the engine's core
invariant (L1): the engine never boots / never parses source; all framework-aware work lives in the
collector. If a future dynamic pass is authorized (it is intentionally deferred — see README), it would
still be implemented as new `Probe` subclasses in the client, with zero engine changes, so the agnostic
boundary is never crossed.

## The lockstep contract: metric kernel (D43/D39)

The one place the two repos must stay in exact agreement at the code level is the **8-key metric set**:

- engine: `ArchitectureAuditor::Analyze::METRIC_KEYS` (8 symbols, source of truth)
- client: `Archbuddy::Report::METRIC_KEYS_FOR_DISPLAY` (8 strings)

`spec/report/metric_kernel_consistency_spec.rb` (client half) and the engine's
`spec/integration/metric_kernel_consistency_spec.rb` (engine half) both assert equality (set **and**
order). If either side adds/removes/renames a metric without the other following, CI fails. **Any metric
change is a two-repo change.**

**Important:** `branches`/`decisions` (graph 1.1), `sink_open` (graph 1.2), and the `connectivity`
object in `scores` (findings 1.3) are all **graph/findings INPUT fields**, not metric-kernel keys.
They are NOT added to `METRIC_KEYS`; the kernel remains 8 keys. The `metric_kernel_consistency_spec`
files in both repos are **untouched** and stay green without any edit. `sink_open` is the engine's
INPUT for deriving U (undifferentiated sink paths via `in_degree`); the engine never emits it back as
a metric. `connectivity` is a project-level summary object computed by the engine in `finish`; it is
not per-node and not part of the metric kernel.

## Working across both repos

- Run the client suite with the engine path-sourced:
  `RBENV_VERSION=ruby-3.4.2 ARCHITECTURE_AUDITOR_PATH=../architecture-auditor bundle exec rspec`.
- A full dogfood run: `collect` this (or any) Ruby repo → run the engine's `analyze` on the resulting
  `graph.yml` → `report` the engine's `findings.yml` with `--id-map ./out/id-map.yml`.
- Decision/rationale history (D1–D48+, M1–M3) lives in `docs/IMPLEMENTATION_PLAN.md` (this repo's slice)
  and the engine repo's own plan.
