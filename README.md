# archbuddy-ruby-client

The **Ruby client** for the [architecture-auditor](https://github.com/Kosmin/architecture-auditor)
engine. It captures a language-agnostic execution/call **graph** from a Ruby codebase, hands the
engine an *opaque* graph to analyze, and reconnects the engine's findings back to real code
locally — producing a ranked **architecture clutter report**.

## What archbuddy is

`archbuddy` is **one half of a two-repo system**:

- **archbuddy-ruby-client (this repo)** owns *capture* and *reconnect*.
- **[architecture-auditor](https://github.com/Kosmin/architecture-auditor) (the engine)** owns the
  shared **Contract** (ids/serializer/validator/schemas) and the *analysis* (graph → findings).

It owns two CLI concerns:

- **Collector** (`collect`): a static-AST adapter (via `prism`) that walks a Ruby codebase into
  method-level nodes + directed call/db/endpoint/external edges, then **anonymizes** them — emitting:
  - `graph.yml` — shareable, **opaque** node-ids, zero app semantics (safe to hand to the engine).
  - `id-map.yml` — **SECRET**, local-only, gitignored: maps each opaque id → `file:line:symbol`.
- **Reconnect + Report** (`report`): joins the engine's `findings.yml` back against the secret
  `id-map.yml` to produce a **ranked clutter report** scored against real code symbols.

The pluggable `Adapter` interface means a future React/Node.js client is a new adapter, not a rewrite.

## Data flow

```
your repo ──> archbuddy collect ──> graph.yml + id-map.yml(SECRET) + COMMITTED real-name cache
graph.yml ──> architecture-auditor analyze ──> findings.yml (opaque)
findings.yml + id-map.yml ──> archbuddy analyze ──> archbuddy-findings.json (COMMITTED, real-name)
archbuddy-findings.json ──> archbuddy report ──> ranked clutter report + multiplexer_proxy smell
```

`id-map.yml` **never leaves this machine** and is the only thing that can de-anonymize the *opaque* graph.
The **committed** cache (`archbuddy-findings.json` + `.archbuddy/<mirrored-source>/`) is de-anonymized at
write time — it holds the audited repo's OWN real names, so `report` reads it **directly, with no id-map**
(a fresh clone works). See [`docs/COMMITTING_ARCHBUDDY.md`](docs/COMMITTING_ARCHBUDDY.md) for what is
committed vs ignored and the CI staleness gate.

## Requirements

- Ruby **>= 3.2** (see `.ruby-version`). Ruby 3.4.2 is auto-selected by rbenv from `.ruby-version`
  when you're in the repo; if your shell doesn't auto-switch, prefix commands with
  `RBENV_VERSION=ruby-3.4.2`.
- [Bundler](https://bundler.io/).
- The **`architecture_auditor` engine gem** (the shared contract + the `analyze` CLI). See below.

## Install

```bash
git clone https://github.com/Kosmin/archbuddy-ruby-client.git
cd archbuddy-ruby-client
bundle install
```

### Installing the engine dependency

`archbuddy` depends on the `architecture_auditor` gem for the shared Contract. The `Gemfile` is wired
so a **fresh clone installs cleanly** *and* local dev keeps its ergonomics:

- **Default (fresh clone / distribution):** the engine resolves from its **git source**
  (`https://github.com/Kosmin/architecture-auditor.git`, branch `main`). No sibling checkout needed.
- **Local dev — two ways to point at a sibling checkout (`../architecture-auditor`):**

  1. **Env override (zero config), one-off:**
     ```bash
     ARCHITECTURE_AUDITOR_PATH=../architecture-auditor bundle install
     ```
     An unset/blank value falls through to the git source.

  2. **Bundler local override (persistent, no env needed)** — preferred for a permanent sibling:
     ```bash
     bundle config set --local local.architecture_auditor ../architecture-auditor
     bundle install
     ```
     Bundler resolves the git gem from that local path automatically (it must be on the same branch).

  Either mode lets a sibling checkout "just work" without editing the `Gemfile`.

## Quickstart — the full pipeline

The three stages share a single **`.archbuddy/`** workspace dir (relative to your CWD), so the whole
flow runs **flag-free**. (The middle stage runs the **engine**, not this repo.)

```bash
archbuddy collect .              # → .archbuddy/graph.yml + .archbuddy/id-map.yml (SECRET)
architecture-auditor analyze     # → .archbuddy/findings.yml   (the OTHER repo)
archbuddy report                 # → ranked clutter report (de-anonymized, local-only)
```

> Ruby 3.4.2 is auto-selected by rbenv from `.ruby-version` when you're in the repo; if your shell
> doesn't auto-switch, prefix commands with `RBENV_VERSION=ruby-3.4.2`.

### 1. Collect — capture + anonymize your codebase

```bash
archbuddy collect .
# → .archbuddy/graph.yml      (opaque, shareable)
# → .archbuddy/id-map.yml     (SECRET — local-only, never share/commit)
```

`--out-dir` is **optional** and defaults to `.archbuddy/`. **The secret stays safe automatically:**
when you use the default dir inside a git repo, `archbuddy` appends `.archbuddy/` to your repo's
**`.git/info/exclude`** (a *local* ignore — it never edits your tracked `.gitignore`) so the id-map is
git-ignored before it is written. (Pass an explicit `--out-dir` and you own ignoring it — `collect`
refuses to write the secret to a path that isn't gitignored.)

For a **non-Rails gem or library** (no controllers), the default entrypoint strategy may find no
entrypoints; `collect` warns on stderr and suggests:

```bash
archbuddy collect . --entrypoints all_public
```

`--entrypoints` accepts `default | controllers | all_public | none` (M3).

### 2. Analyze — run the engine on the opaque graph

```bash
# in / via the architecture-auditor engine repo (also defaults to the .archbuddy/ workspace):
architecture-auditor analyze
# → .archbuddy/findings.yml   (opaque; safe to share — keyed by opaque ids only)
```

The engine **never** receives `id-map.yml` — it analyzes the graph without ever seeing real symbols.

### 3. Report — reconnect findings to real symbols, ranked

```bash
archbuddy report
# reads .archbuddy/{findings,id-map,graph}.yml by default.
# add --format yaml|json|dot|html, --top N, or explicit FINDINGS/--id-map/--graph to override.
```

A missing default input fails with a friendly hint (e.g. `no findings at .archbuddy/findings.yml —
run \`architecture-auditor analyze\` first`), never a stack trace.

The report carries **real symbols** → treat it as SECRET/local-only (see below).

### Sample output (Architecture Scores summary + ranked bottlenecks)

```
archbuddy report — clutter ranking

Architecture Scores
------------------------------------------------------------
  Connectivity: 5/1672 nodes scored (0.3%)

  Reverse Traceability    27.1  (B)    — can you tell where code is used?
  Forward Discoverability 32.5  (C)    — can you follow where execution goes?

  Reverse Traceability
    top contributors to this dimension (worst-ranked first):
      1. Billing#charge (app/services/billing.rb:8)  [fan_in=42, centrality=0.9000, in_cycle=0]
      2. User#save (app/models/user.rb:12)  [fan_in=2, centrality=0.4000, in_cycle=0]

#1  OrdersController#create  [clutter 9.5000]
    kind: endpoint    app/controllers/orders_controller.rb:5
    metrics:
      path_length  0
      fan_in       0
      fan_out      3
      ...
```

## Reading the report: the two dimensions

The engine scores two **project-level** dimensions (eslint/rubocop-style). The **cost number is the
headline**; the letter grade is a tentative secondary indicator:

- **Reverse Traceability** — *"can you tell where code is used?"* Always computable. Driven by the
  branch-product round-trip cost to `db_op` terminals (reuse-is-cheap: fan-in into a plain function
  adds nothing; undifferentiated fan-in into an open-ended write sink is charged ×U).
- **Forward Discoverability** — *"can you follow where execution goes?"* Driven by `path_length` /
  `fan_out`. This is **N/A** when collection found **no entrypoints** (re-collect with
  `--entrypoints all_public`); it renders honestly as `N/A` with that reason, never a fake number.
- **Connectivity banner** — printed *above* the dimension rows when findings carry a `connectivity`
  block (findings 1.3): `Connectivity: N/total nodes scored (P%)`. A low percentage (e.g. 5/1672,
  0.3%) flags that only a small sample of the graph was reachable from entrypoints — treat the
  dimension scores as indicative, not representative.
- **v0.10 counter banners** — when the committed aggregate is SERIALIZER v2 it carries three
  counter blocks, each rendered as a nil-tolerant banner beside connectivity (absent on an older
  aggregate — back-compat):
  - `Entrypoints: N total (controllers 3, jobs 1, …)` — ingress counts by category; once the
    engine publishes per-category cost the banner appends `— mean M, median D` (median is the
    antidote to the outlier-dominated mean).
  - `Egress: N total (http 2, gem 3, …)` — non-DB exit points by category
    (`http`/`gem`/`queue`/`generic`).
  - `Dynamic dispatch: R/T resolved, D dynamic (coverage P%)` — the visible share of dispatch
    (`1 - dynamic/total`); `N/A` when there are no call sites (honest-undefined).
  These render even on a collect-only cache (no engine scores yet). Counts come straight from the
  committed cache — the report never recomputes them.

**Interpreting the cost:** the score is the **arithmetic mean over controller entrypoints** of each
entrypoint's branch-product round-trip cost — an **unbounded architectural cost** (≥ 0, no upper
limit), lower is better. The score is computed in real space (no logarithm, no `/100` normalization);
reusing a simple sink-free function scores ≈ 1. The letter grade is a PROVISIONAL ceiling-band
indicator (tuned empirically, may be adjusted in a later release):

| Grade | Cost |
|-------|------|
| A     | < 10 |
| B     | < 30 |
| C     | < 60 |
| D     | < 125 |
| F     | ≥ 125 |

A **hotspot** is just the worst-*ranked* node for that dimension (a relative top contributor) — on a
clean project the top hotspots may be perfectly benign. Scores are copied **verbatim** from the
engine; archbuddy never recomputes them.

> **Note:** The end-to-end validation runbook (W7 in the implementation plan) is not yet complete.
> Band ceilings and sample report numbers above are derived from the scoring model; real-repo
> calibration (W7.5) may refine them in a subsequent release.

## Interactive HTML report (offline, self-contained)

`--format html` renders the same data as a single, **fully self-contained, fully OFFLINE** HTML
dashboard: the two dimension scores as headline grade cards, an interactive Cytoscape.js call graph,
and the ranked bottleneck table. Cytoscape.js and all CSS/JS are **inlined** into the file — there are
zero external/CDN references, so it opens with no network and no build step.

```bash
archbuddy report --format html > .archbuddy/report.html
open .archbuddy/report.html   # macOS; or just open the file in any browser
```

- **Default (from the committed cache): the graph is built from the committed REAL-NAME detail tree**
  (`.archbuddy/<mirrored-source>` fragments), so `archbuddy report` with no args renders a clean
  **real-name, external-excluded, clutter-ranked** call graph **with no id-map** (a fresh clone works).
  On the legacy opaque path the graph nodes come from `graph.yml` (`--graph` defaults to
  `.archbuddy/graph.yml`), de-anonymized via the SECRET id-map. Either way, **without a graph the scores
  header + bottleneck table still render** (with a visible notice — no crash).
- Graph controls: toggle labels between **real symbols ↔ opaque ids** (defaults to real, since this is
  the local view), highlight each dimension's hotspots, switch built-in layout (cose/grid/breadthfirst/
  circle), recolor nodes by metric, and click a node (or a table row) to inspect its file:line, kind,
  all 8 metrics, clutter, and finding types in a side panel.
- **Minimum clutter-score filter:** a range slider + synced number input hides graph nodes (and their
  incident edges) below the chosen clutter score, with a live "showing N of M nodes" count. To avoid an
  overwhelming hairball on load it **defaults to a focused view of the worst offenders** (roughly the top
  ~120 nodes by clutter); drag the slider to **0** to reveal the full graph. Re-layout is debounced so
  dragging stays smooth, and highlighting a hotspot or clicking a table row reveals its node even if the
  filter had hidden it.
- **Sortable, paginated bottleneck table:** click any header (clutter score, each metric, symbol, file,
  kind) to sort — repeat-click toggles ascending/descending and the active column shows a ▲/▼ indicator.
  Null/`N/A` metric values always sort last. The table is paginated (rows-per-page selector of 25 / 50 /
  100 / All, default **25**, with Prev/Next and a "showing X–Y of Z" indicator); only the current page is
  rendered. Sorting and pagination are pure presentation over the already-emitted findings — nothing is
  recomputed — and they also work in the no-graph degradation path. A row click still centers and
  highlights the node in the graph regardless of which page it is on.
- The HTML carries **real symbols → SECRET/local-only.** Redirect it to a **gitignored** path (e.g.
  `.archbuddy/report.html` — the `.archbuddy/` workspace is ignored) and **never commit or share it.** The vendored
  `cytoscape.min.js` asset *is* committed (it's a runtime dependency, not a secret — see
  `lib/archbuddy/report/assets/CYTOSCAPE_LICENSE`).

## SECRET: the id-map and de-anonymized reports

`id-map.yml` is the **only** thing that can de-anonymize the opaque graph, and every de-anonymized
report (`terminal` text, `report.yml`, `report.json`, `*.dot`, `report.html`) carries **real
file/line/symbol** names.

- **Never commit** the id-map or any report. The repo `.gitignore` already covers `.archbuddy/`,
  `id-map.yml`, `*.id-map.yml`, `/out/`, `report.yml/json`, `*.dot`, `*.report.html`, `graph.yml`,
  `findings.yml`. (The vendored `cytoscape.min.js` library asset is intentionally NOT ignored — it is
  a runtime dependency, not a secret.)
- **Never share them externally.** They stay **local, on this machine**. `collect` even refuses to
  write the id-map unless its path is gitignored (gitignore-before-secret guard). For the **default
  `.archbuddy/` workspace** inside a git repo, `collect` makes that automatic by appending
  `.archbuddy/` to **`.git/info/exclude`** (a local ignore, never your tracked `.gitignore`) so the
  secret is ignored before it is ever written — you never have to think about it.

## CLI reference

```
archbuddy collect PATH [--out-dir .archbuddy] \
  [--language ruby] [--entrypoints default|controllers|all_public|none] [--entrypoint-pattern REGEX ...] \
  [--probes all|none|grape,sidekiq_dispatch,meta_send,egress] \
  [--root-types all|none|jobs,rake,middleware,script,cron] \
  [--changed [--base-ref origin/main]] [--check]

archbuddy analyze     # engine analyze + de-anon-at-write the committed real-name cache

archbuddy report [FINDINGS_YML] [--id-map .archbuddy/id-map.yml] \
  [--format terminal|yaml|json|dot|html] [--graph .archbuddy/graph.yml] [--top N]

archbuddy reset PATH  # full re-collect + analyze from scratch (first run / model change)
```

`--out-dir` (collect) and `FINDINGS_YML` / `--id-map` / `--graph` (report) all default into the shared
`.archbuddy/` workspace, so the common flow needs no flags. Explicit values override.

### The four modes (v0.8 committed cache)

- **`collect [--changed]`** — assemble per-file fragments → the opaque `graph.yml` + SECRET `id-map.yml`
  **and** the COMMITTED real-name cache (`archbuddy-findings.json` + `.archbuddy/<mirrored-source>/`).
  `--changed` re-parses only content-changed files (content-hash trigger; `--base-ref` is an optional
  git fast-path pre-filter). `--check` is the CI staleness gate — see below.
- **`analyze`** — run the engine on `graph.yml` → `findings.yml` (opaque), then **de-anonymize at write
  time** into the committed real-name aggregate (headline scores + the `multiplexer_proxy` smell).
- **`report`** — render from the COMMITTED real-name cache **directly, with no id-map** (a fresh clone
  works). As of **v0.8** the default report also builds its interactive graph from the committed
  **real-name detail tree** (reassembled across shards), so the graph shows **real method names**,
  excludes `<external>` sinks, and ranks by the committed clutter (`multiplexer_proxy`) — no id-map, no
  opaque node labels. Falls back to the legacy opaque `findings.yml` + `id-map.yml` (graph via
  `--graph`) when there is no committed cache or an explicit `FINDINGS_YML` is given. Surfaces the
  `multiplexer_proxy` smell across every formatter.
- **`reset PATH`** — full re-collect (ignoring the speed cache) + `analyze` from scratch. Use on first
  run or when the scoring model changes.

### CI staleness gate — `collect --check`

`archbuddy collect --check` regenerates the committed cache and asserts it matches what is committed
(`git diff`). Exit **0** clean, **1** on drift (run `collect`/`reset` + commit), **2** (loud) when there
is no committed baseline. It never reads the SECRET `id-map.yml`. See
[`docs/COMMITTING_ARCHBUDDY.md`](docs/COMMITTING_ARCHBUDDY.md) for the audited-repo `.gitignore` template
and a generic CI snippet.

## Framework probes (capture extensions)

The collector ships a **pluggable, static-DSL-aware probe seam** (v0.3.0) that recovers call edges the
base AST resolver can't see — edges the framework wires through a DSL (`Grape::API` route handlers,
Sidekiq/ActiveJob dispatch). Provenance rides the `--probes` diagnostics channel only; nothing extra
reaches `graph.yml` (the schema is unchanged).

### What the probes cover

| Probe | Key word | What it recovers |
|-------|----------|-----------------|
| `grape` | `mount Const` | A `mount` call inside a `Grape::API` resolves to the mounted API's representative endpoint node. |
| `sidekiq_dispatch` | `Const.perform_async` / `.perform_later` / `.perform_in` / `.perform_at` | An async-dispatch call resolves to a `caller → Const#perform` edge (with a single `.set(...)` hop unwrapped). |
| `meta_send` (v0.10) | `recv.send(:m)` / `public_send("m")` / `__send__(:m)` / `try(:m)` | A meta-dispatch with a **literal** Symbol/String first arg rewrites to the direct call (`caller → Target#m`) when the receiver is provable (const / typed var / self) AND the target exists in-tree. Dynamic-arg meta stays flagged-no-edge. |
| `egress` (v0.10) | any call on a provably **out-of-tree literal constant** | Classifies the external fallthrough into an egress category — `http` (known HTTP-client const + verb), `queue` (enqueue verb, `#perform` not in-tree), `gem` (any other out-of-tree const) — routed to a category-bearing sink `<external:http\|gem\|queue>`. Runs LAST so it never shadows a recoverable real edge. |

Rails route entries (`config/routes.rb`) are handled by the **RouteCatalogue** entrypoint seeder, which
reads `to: "controller#action"` strings and `resources`/`resource` RESTful expansions and seeds those
actions as entrypoints (Pass 1). It emits no new edges — it only confirms that already-known controller
actions are reachable as entrypoints.

### Ingress root seeders — `--root-types` (v0.10)

The entrypoint side has a mirror seam: **root seeders** tag methods that are provably execution
roots with an ingress **category** (they add no nodes and no edges — they only categorize methods
that already exist). Selection via `--root-types all|none|comma,list` (lenient — unknown names
select nothing):

| Root type | Evidence | What it tags |
|-----------|----------|--------------|
| `jobs` | `include Sidekiq::Job/Worker`, `< Sidekiq::Worker`, `< ApplicationJob/ActiveJob::Base` (chain-walked) | the job's `#perform` |
| `rake` | `task NAME do … end` in `.rake`/`Rakefile` (minted in Pass 1, not seeder-gated — structural like Grape) | the synthetic `rake:ns:name[N]` node |
| `middleware` | `def call(env)` + `@app` write in `initialize` + a `use`/`insert_before/after` registration (all three required) | the middleware's `#call` |
| `script` | file under `scripts/`/`script/`/`bin/` + shebang + non-loader-only body | the file's top-level defs |
| `cron` | **default OFF** — sidekiq-cron YAML / whenever `schedule.rb`; LINK-only: confirms already-seeded jobs/rake roots, never mints. Enable explicitly: `--root-types jobs,rake,cron` | nothing (confirm-or-decline ledger only) |

The detected category rides each entrypoint as `entrypoint_kind` (category precedence:
grape → routed → controllers → jobs → rake → middleware → script → top_level → pattern, one
category per method, first match wins) and feeds the `Entrypoints:` counter banner in the report.

### NEVER-FABRICATE invariant

Every probe and the routes seeder emit an edge or confirm an entrypoint **only** when the target is
provably wired AND `table.method?(target)` is true. An unprovable, dynamic, or empty target causes the
probe to **decline** (`nil`), letting the call fall through to the next probe or the `<external>` sink.
No edge is ever guessed.

### `--probes` CLI flag

```bash
archbuddy collect .                              # all probes on (default)
archbuddy collect . --probes none                # disable all probes
archbuddy collect . --probes grape               # only the Grape mount probe
archbuddy collect . --probes grape,sidekiq_dispatch  # explicit list
```

When at least one probe resolves a call, `collect` prints a one-line provenance note on stderr (mirrors
the metaprogramming-sites note):

```
note: 42 edges recovered by framework probes (grape=39 sidekiq_dispatch=3)
```

This is diagnostics-only — provenance never appears in `graph.yml`.

### Provenance diagnostics

`AdapterResult#diagnostics[:probe_edges]` carries a `{ probe_name => count }` hash (e.g.
`{ grape: 39, sidekiq_dispatch: 3 }`). It is available to the CLI and any downstream tooling that
consumes `AdapterResult` directly. The serialized `graph.yml` never carries it.

### Deferred seams (not yet built)

- **Dynamic/runtime path** — executing the audited app to capture the live route table /
  metaprogrammed endpoints / dynamic mounts. Researched and costed; intentionally not built (it would
  break the engine's app-agnostic, no-boot boundary — L7/P2). The static probe seam is clean: a future
  dynamic pass is a new `Probe` subclass, not a rewrite.
- **DB-connector probe** — a non-ActiveRecord connector probe (Sequel, ROM, …). Neither `nexus` nor
  `app-management` uses one (0 validated targets); the seam makes it a trivial future add.

## Development

```bash
bundle exec rspec               # full suite
gem build archbuddy.gemspec     # installability check (delete the .gem after)
```

> Ruby 3.4.2 is auto-selected by rbenv from `.ruby-version` when you're in the repo; if your shell
> doesn't auto-switch, prefix with `RBENV_VERSION=ruby-3.4.2`.

See [`AGENTS.md`](AGENTS.md) for the docs pyramid, [`ARCHITECTURE.md`](ARCHITECTURE.md) for the
as-built code map, [`CONTRACT.md`](CONTRACT.md) for the data contracts, and
[`.claude/docs/cross-repo.md`](.claude/docs/cross-repo.md) for the client ↔ engine relationship.
