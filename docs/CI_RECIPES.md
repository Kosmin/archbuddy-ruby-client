# CI Recipes — running `archbuddy diff` as a PR reviewer

Vendor-neutral contract first; verified recipes for GitHub Actions, GitLab CI,
and CircleCI below. Everything here is DOCUMENTATION (no vendor API code ships
in the gem); the jq translations at the bottom are executed against a fixture
report by `spec/docs/ci_recipes_jq_spec.rb`, so the snippets cannot rot.

## The contract (any CI)

Requirements: the base commit present locally, ruby ≥ 3.2, and both gems
installed (`archbuddy` + the `architecture-auditor` engine). Then:

```sh
bundle exec archbuddy diff . <base-ref> --format json   # or markdown/terminal
```

Exit table (verbatim — the whole gate):

| exit | meaning |
|---|---|
| 0 | pass, or advisory mode (ALWAYS 0 with no config file — advisory is the default) |
| 1 | at least one error-severity finding (e.g. an `ExponentialNode` node above 2^5, or a `ComplexityRatchet` budget breach); warn-severity findings such as a `UseCaseComplexity` Q4-trigger gate only at `--fail-level warn` |
| 2 | tool or config failure (bad flags, unresolvable base ref, invalid `.archbuddy.yml`) |

stdout carries ONLY the rendered report (clean-stdout contract) — pipe-safe;
all notes/warnings go to stderr.

## Install (two wiring modes)

Not on rubygems.org. Distribution-time (copyable — pin a tag or SHA rather
than a branch):

```ruby
# Gemfile
gem "architecture-auditor", git: "https://github.com/<org>/architecture-auditor", tag: "v0.10.0"
gem "archbuddy", git: "https://github.com/<org>/archbuddy-ruby-client", tag: "v0.13.0"
```

Dev-time sibling-checkout override (what this repo's own suite uses):

```sh
ARCHITECTURE_AUDITOR_PATH=../architecture-auditor bundle exec archbuddy diff . origin/main
```

Cache the bundle in CI (standard bundler caching; cold-install time was not
measured — no number is quoted here).

## GitHub Actions

Defaults dated 2026-07-23: `actions/checkout@v4` clones with `fetch-depth: 1`
— the base commit will be MISSING. Use `fetch-depth: 0`. On `pull_request`
events the checkout is `refs/pull/N/merge` (the merge commit), so
`origin/$GITHUB_BASE_REF` is the base ref and `HEAD^1` is its merge-parent
equivalent.

```yaml
- uses: actions/checkout@v4
  with:
    fetch-depth: 0
- run: bundle install
- run: bundle exec archbuddy diff . "origin/${GITHUB_BASE_REF}" --format markdown >> "$GITHUB_STEP_SUMMARY"
```

The step summary caps at 1 MiB per step; the markdown report's 50-row details
cap keeps far below it. Exit 1 fails the step — that IS the gate. JSON-artifact
variant: `--format json > archbuddy.json` + `actions/upload-artifact`.
PR-comment variant: generate markdown, then a user-run
`gh pr comment --body-file archbuddy.md` (comment cap 65,536 chars).

Advanced alternative (**verify on first use** — left unverified by the study
setup): a `git fetch --deepen=50` loop until `git merge-base` resolves, for
repos where full history is prohibitively large.

## GitLab CI

Defaults dated 2026-07-23: new projects clone with `GIT_DEPTH: 20`. Set it to
`"0"` for merge-request pipelines and use the pre-computed diff base:

```yaml
archbuddy:
  variables:
    GIT_DEPTH: "0"
  script:
    - bundle exec archbuddy diff . "$CI_MERGE_REQUEST_DIFF_BASE_SHA" --format json > archbuddy.json
    - jq -f codeclimate.jq archbuddy.json > gl-code-quality-report.json
  artifacts:
    reports:
      codequality: gl-code-quality-report.json
```

`codeclimate.jq` is the CodeClimate translation below.

## CircleCI

CircleCI clones FULL history by default — the portable form works as-is:

```sh
bundle exec archbuddy diff . origin/main --format terminal
```

Warning: the popular shallow-clone orbs re-introduce the missing-base failure;
if you use one, keep the base commit reachable (see the deepen note above).

## Committed-cache fast path

See docs/COMMITTING_ARCHBUDDY.md for committing `.archbuddy/` +
`archbuddy-findings.json`. With the cache committed, the BASE side reads via
`git archive` in ≈ 2 s even at 17,975-node scale, vs 35.4 s/side for a
stateless worktree collect (measured on the study monorepo, tree-pinned).
REQUIRES pairing with a `archbuddy collect --check` job — the trust model is
"the cache matches the tree because CI verifies it", not "trust whoever
committed". `--trust-cache` is the escape hatch and is deliberately LOUD on
stderr. Shallow clones must still carry the base commit's TREE objects; avoid
`--filter=blob:none` partial clones (per-blob network round trips during the
base read).

## jq translations (documented snippets — the tool ships no vendor formats)

Both consume the `archbuddy-diff-report/1` envelope. Fragments are line-free
by design, so `lines.begin` degrades honestly to `1` (file-granular findings).
PR-scoped findings (a configured `ReviewSurface` gate) carry no file; the
translation degrades to the repo root.

GitLab CodeClimate:

```jq
[.findings[] | {
  description: .message,
  check_name: .rule,
  fingerprint: .fingerprint,
  severity: ({error: "major", warn: "minor", info: "info"}[.severity]),
  location: {path: (.file // "."), lines: {begin: (.line // 1)}}
}]
```

SARIF 2.1.0 minimal (documented translation — SARIF is a v1.1 native-format
candidate, not v1):

```jq
{
  "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
  version: "2.1.0",
  runs: [{
    tool: {driver: {name: "archbuddy", informationUri: "", rules: []}},
    results: [.findings[] | {
      ruleId: .rule,
      level: ({error: "error", warn: "warning", info: "note"}[.severity]),
      message: {text: .message},
      locations: [{physicalLocation: {
        artifactLocation: {uri: (.file // ".")},
        region: {startLine: (.line // 1)}
      }}]
    }]
  }]
}
```

## Recipe defaults, restated with dates

| fact | value | dated |
|---|---|---|
| actions/checkout@v4 default depth | 1 | 2026-07-23 |
| GitLab new-project GIT_DEPTH | 20 | 2026-07-23 |
| CircleCI clone | full history | 2026-07-23 |
| GHA step-summary cap | 1 MiB | 2026-07-23 |
| gh pr comment cap | 65,536 chars | 2026-07-23 |

These are vendor defaults and DO drift — re-check when a recipe misbehaves.
