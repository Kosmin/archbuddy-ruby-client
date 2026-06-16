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
- The **gemspec** declares `add_dependency "architecture_auditor", "~> 0.1"` (pessimistic bound; the
  open-ended `>= 0` form was removed so `gem build` emits no warning).

**Verified vs documented in this environment:** the env-override mode (Mode 1) and the bundler
local-config mode (Mode 2, which resolves the *git* source from the sibling — proving the git line is
syntactically valid and resolvable) both `bundle install` cleanly under `RBENV_VERSION=ruby-3.4.2`. A
**true remote git fetch** (no sibling at all) could not be exercised here because
`Kosmin/architecture-auditor` is a local-only repo not published over HTTPS — that line is the
documented distribution default, verified resolvable via the local override but not fetched from the
remote.

## The lockstep contract: metric kernel (D43/D39)

The one place the two repos must stay in exact agreement at the code level is the metric set:

- engine: `ArchitectureAuditor::Analyze::METRIC_KEYS` (8 symbols, source of truth)
- client: `Archbuddy::Report::METRIC_KEYS_FOR_DISPLAY` (8 strings)

`spec/report/metric_kernel_consistency_spec.rb` (client half) and the engine's
`spec/integration/metric_kernel_consistency_spec.rb` (engine half) both assert equality (set **and**
order). If either side adds/removes/renames a metric without the other following, CI fails. **Any metric
change is a two-repo change.**

## Working across both repos

- Run the client suite with the engine path-sourced: `RBENV_VERSION=ruby-3.4.2 bundle exec rspec`.
- A full dogfood run: `collect` this (or any) Ruby repo → run the engine's `analyze` on the resulting
  `graph.yml` → `report` the engine's `findings.yml` with `--id-map ./out/id-map.yml`.
- Decision/rationale history (D1–D48, M1–M3) lives in `docs/IMPLEMENTATION_PLAN.md` (this repo's slice)
  and the engine repo's own plan.
