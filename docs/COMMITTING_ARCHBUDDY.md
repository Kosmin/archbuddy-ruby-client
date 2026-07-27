# Committing the archbuddy cache (audited-repo guide)

archbuddy v0.8 turns the auditor from a stateless full-recompute into a
**committed, incrementally-updated metadata cache**. An audited repo commits a
small, reviewable, real-name cache so a PR's architecture-score impact shows up
in its diff — the same way a lockfile, a `.rubocop_todo.yml` baseline, or a Jest
`__snapshots__/` tree does. This guide is for the **audited repo** (the codebase
you run archbuddy against), not for archbuddy's own repo.

## What is committed vs ignored

| Path | Committed? | What it is |
|------|-----------|-----------|
| `archbuddy-findings.json` (repo root) | **COMMITTED** | Compact aggregate: headline dimension scores + the `multiplexer_proxy` smell list + pointers into the detail tree. Kept small (pointers, not payload). |
| `.archbuddy/<mirrored-source-path>…` | **COMMITTED** | Real-name, line-free detail tree mirroring your source layout. Adaptively sharded (large files split per-class, then per-method) so diffs stay surgical. |
| `.archbuddy/id-map.yml` | **IGNORED (SECRET)** | The real↔opaque name map. Never commit, never share. |
| `.archbuddy/.cache/` | **IGNORED** | Machine-local incremental speed cache (raw parse/hash blobs). Re-derivable; the `.tsbuildinfo` of archbuddy. |
| `.archbuddy/graph.yml`, `.archbuddy/findings.yml` | **IGNORED** | Opaque interchange between `collect` and the engine `analyze`. Regenerated each run. |
| `.archbuddy/report.*` | **IGNORED** | De-anonymized report exports (`report.html`, etc.) — SECRET/local-only. |

The committed cache is **de-anonymized at write time**: it holds your repo's OWN
real class/method names and file paths. That is your own code in your own repo —
fine to commit. The **secret** is the `id-map.yml` (and any de-anonymized
`report.*`), which stays gitignored. A fresh clone reads the committed cache
**directly, with no id-map**.

## `.gitignore`

Copy the shipped template (`templates/audited-repo.gitignore`) into your repo's
tracked `.gitignore`:

```gitignore
# archbuddy — committed architecture cache
.archbuddy/*
!.archbuddy/*/
.archbuddy/id-map.yml
.archbuddy/.cache/
.archbuddy/graph.yml
.archbuddy/findings.yml
.archbuddy/report.*
# (archbuddy-findings.json at the repo root is committed — do NOT ignore it.)
```

`.archbuddy/*` ignores the top-level entries; `!.archbuddy/*/` re-includes the
committed source-mirrored subdirectories; the remaining lines re-ignore the
specific secret/interchange files. Verify with:

```sh
git check-ignore .archbuddy/id-map.yml        # → prints the path (ignored)  ✔
git check-ignore archbuddy-findings.json      # → nothing (tracked)          ✔
git check-ignore .archbuddy/app/models/x.rb.json  # → nothing (tracked)      ✔
```

## The four CLI modes

```sh
archbuddy collect .            # assemble fragments → graph.yml + id-map.yml + committed cache
archbuddy collect . --changed  # incremental: re-parse only content-changed files
architecture-auditor analyze   # engine: graph.yml → findings.yml (opaque)   [the OTHER repo]
archbuddy analyze              # engine analyze + de-anon-at-write the committed real-name cache
archbuddy report               # render from the committed cache (no id-map needed)
archbuddy reset .              # full re-collect + analyze from scratch (first run / model change)
```

Typical first run: `archbuddy reset .` (or `collect` + `analyze`), then commit
`archbuddy-findings.json` + `.archbuddy/` (minus the ignored paths).

## Upgrading to archbuddy 0.10.0 (v0.11) — one expected churn event

The first `collect`/`reset` after upgrading produces ONE larger-than-usual committed diff, then
diffs are surgical again:

- **Fragment edge symbols** — edges that pointed at a collapsed category sink
  (`<external:http>` etc.) now point at per-target sub-sinks
  (`<external:{category}:{ConstName}>`). Value churn only; the fragment shape is unchanged. The
  aggregate `egress` **counts** block is byte-identical. A repo with no categorized egress sees
  zero edge churn.
- **Fragment stamps** — every fragment's `serializer_version` bumps 2 → 3 (a stamp rewrite, not a
  re-parse), and the next `analyze` folds the new v3 blocks (`blast_radius`, `forward_depth`,
  `reverse_depth`, `branching_factor`, widened `headline_scores`/`egress` cost) into the aggregate.

Commit both together as one event. **Downgrade caveat:** running an OLDER client's `collect` over
a v3 cache rewrites the aggregate back to that client's v2 shape (the v3 blocks drop) — harmless;
the next `analyze` with a current client restores them.

## Upgrading to archbuddy 0.11.0 (v0.12) — one expected churn event

Same pattern as the v0.11 upgrade — ONE larger-than-usual committed diff on the first
`collect`/`reset`, then surgical again:

- **Fragment stamps + node keys, together** — every fragment's `serializer_version` bumps 3 → 4
  (a stamp rewrite, not a re-parse), and every fragment node gains two keys in the SAME event:
  `outcome_arity` (int, 1..5 — or null when statically unresolved; never fabricated) and
  `escapes` (bool). One churn event by design: the arity/escape keys ride the v4 stamp rather
  than a second bump.
- **Aggregate** — the next `analyze` (against an engine ≥ 0.9.0 / findings 1.7) folds the new
  `variety_mass` block (UNGRADED; hotspots dropped; `fallback_fraction` = the low-confidence
  disclosure) into the aggregate. Against an older engine there is no block — an honest absence.
- (One-time, machine-local, NOT committed: `COLLECTOR_VERSION` 1 → 2 forces a full re-parse of
  the gitignored speed cache on first run — slower once, zero committed diff from it.)

Commit the stamp + key churn together as one event. **Downgrade caveat (repeats v3's):** an
OLDER client's `collect` over a v4 cache rewrites the committed shape back to that client's
vintage (the v4 keys/block drop) — harmless; the next `analyze`/`collect` with a current client
restores them.

## Upgrading to archbuddy 0.12.0 (v0.13) — one expected churn event

Same pattern again — ONE larger-than-usual committed diff, then surgical:

- **Fragment compass stamps** — every fragment's `serializer_version` bumps 4 → 5 (a stamp
  rewrite, not a re-parse) and every fragment node gains four keys in the SAME event:
  `leverage`, `collapse`, `toll_booth`, `quadrant` (all null until the first `analyze` against
  an engine ≥ 0.10.0 / findings 1.8 — honest "never analyzed", never fabricated). Once an
  analyze fills them, **collect-only rewrites carry the stamps forward per surviving node**
  (the per-fragment carry) — fragments stay byte-identical between collect and analyze, so
  `--check` never sees compass churn.
- **Aggregate** — the next `analyze` folds the new `reusability` block (UNGRADED; the
  toll-booth/extraction worst-lists de-anonymized; ADVISORY — bypass *candidates*, never
  mandates). Against an older engine there is no block — an honest absence.
- (No `COLLECTOR_VERSION` change — the collector is untouched this release; no forced
  re-parse of the machine-local speed cache.)

**Downgrade caveat (repeats v4's):** an OLDER client's `collect` over a v5 cache rewrites the
committed shape back to that client's vintage (the compass keys/block drop) — harmless; the
next `analyze` with a current client restores them.

## The CI staleness step

Add `archbuddy collect --check` to CI. It regenerates the committed cache and
asserts it matches what is committed (via `git diff`), so a PR that changes
source without regenerating + committing the cache fails the gate — the lockfile
/ `jest --ci` idiom.

Exit codes:

- **0** — clean: the committed cache is up-to-date.
- **1** — DRIFT: the committed cache is stale. Run `archbuddy collect .` (or
  `archbuddy reset .`) and **commit** the updated `archbuddy-findings.json` +
  `.archbuddy/` tree.
- **2** — NO BASELINE: `.archbuddy/`/`archbuddy-findings.json` is absent. This is
  a **loud** failure (never a vacuous pass): run `archbuddy reset .` and commit
  the result before enabling the gate.

`--check` never reads the SECRET `id-map.yml` (the committed cache is real-name
and readable without it), so it works in a fresh CI checkout where the gitignored
secret is absent.

Generic CI snippet (adapt to your CI system — no hosted workflow is shipped, to
stay org-policy-safe):

```sh
# in CI, after checkout + bundle install:
bundle exec archbuddy collect --check
# non-zero exit fails the job
```

## The diff fast path (0.13.0)

Committing the cache turns `archbuddy diff`'s BASE-vintage read into a ~2 s git
read even at 17,975-node scale — vs 35.4 s/side for a stateless worktree
collect (measured on the study monorepo, tree-pinned). The reviewer resolves
the merge-base commit, checks the cache is committed AT that commit, and reads
it via `git archive` — zero collects on the base side.

This fast path MUST pair with the staleness gate above (the trust delegation:
the cache is only as honest as the `collect --check` job that guards it). The
two jobs side by side:

```sh
bundle exec archbuddy collect --check          # gate: committed cache == tree
bundle exec archbuddy diff . origin/main       # review: base read from git
```

`--trust-cache` is the escape hatch for the HEAD side (reuse a working-tree
cache without a freshness check) — deliberately LOUD on stderr, CI should not
need it. Note: no repo commits its cache today; this section is adoption
step 1.

### Stale-fragment hygiene (unreferenced fragment files)

The writer never deletes fragments of removed source files — only the
aggregate's pointers drop. Archbuddy readers are pointer-driven and immune
(398 unreferenced fragment files measured on the study monorepo), but
committed stale fragments accumulate as repo noise. Regenerate with
`archbuddy reset .` + a fresh `collect`, or clean paths the aggregate no
longer names:

```sh
comm -23 <(find .archbuddy -name '*.json' | sort) \
         <(jq -r '.sources[].path' archbuddy-findings.json | sort) | xargs rm -f
```

Writer-side GC is a possible future nicety — NOT shipped in 0.13.0.

Disambiguation: an unreferenced fragment file (a cache file no aggregate
pointer names) is unrelated to the review output's "not reachable from any
entrypoint" disclosure — that one is about call-graph reachability (see
docs/CONFIGURATION.md).
