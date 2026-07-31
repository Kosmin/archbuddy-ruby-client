# frozen_string_literal: true

require "tmpdir"
require "json"
require "stringio"
require "fileutils"
require "open3"
require "archbuddy/cli"

# v0.15 P2-T12: the degenerate battery — [S] rows 1-15 + the v0.15 rows
# 16-19 (zero-ep key absence, metric-quiet union 0, orphan-file touch,
# offsetting-zero). One spec per row; every row asserts exit + streams;
# row 15's clean-stdout property is folded into each row's assertions
# (JSON rows: stdout is valid JSON and nothing else; exit-2 rows: stdout
# empty byte-for-byte).
RSpec.describe "diff degenerate battery" do
  FIXTURES_DD = File.expand_path("../fixtures/review/vintages", __dir__)

  DD_GIT_ENV = {
    "GIT_AUTHOR_NAME" => "spec", "GIT_AUTHOR_EMAIL" => "spec@example.invalid",
    "GIT_COMMITTER_NAME" => "spec", "GIT_COMMITTER_EMAIL" => "spec@example.invalid",
    "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null"
  }.freeze

  def fixture(name) = File.join(FIXTURES_DD, name)

  def git!(dir, *args)
    out, err, status = Open3.capture3(DD_GIT_ENV, "git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out.strip
  end

  def init_repo(dir)
    git!(dir, "init", "-q", "-b", "main")
    git!(dir, "config", "user.name", "spec")
    git!(dir, "config", "user.email", "spec@example.invalid")
  end

  def run_diff(**kwargs)
    out = StringIO.new
    err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    code = nil
    begin
      Archbuddy::CLI::Diff.new.call(**kwargs)
    rescue SystemExit => e
      code = e.status
    ensure
      $stdout = orig_out
      $stderr = orig_err
    end
    [code, out.string, err.string]
  end

  def parse_json!(stdout)
    expect(stdout[0]).to eq("{") # clean-stdout property (row 15)
    JSON.parse(stdout)
  end

  def write_plain_source(dir)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    File.write(File.join(dir, "lib/thing.rb"), <<~RUBY)
      class Thing
        def choose(a)
          a ? 1 : 2
        end
      end
    RUBY
  end

  def write_monster(dir)
    FileUtils.mkdir_p(File.join(dir, "lib"))
    guards = (1..6).map { |i| "    x = #{i} if p#{i}" }.join("\n")
    File.write(File.join(dir, "lib/monster.rb"), <<~RUBY)
      class Monster
        def huge
      #{guards}
          :ok
        end
      end
    RUBY
  end

  def collect!(dir)
    err = StringIO.new
    orig = $stderr
    $stderr = err
    Archbuddy::Review::Collector.collect(source_root: dir, write_root: dir)
  ensure
    $stderr = orig
  end

  # Hand-authored vintage caches (zero_ep fixture format) for rows 13/18/19.
  def write_vintage(dir, fragments)
    sources = {}
    fragments.each do |file, nodes_and_edges|
      rel = ".archbuddy/#{file}.json"
      sources[file] = { "path" => rel, "shard_mode" => "single" }
      path = File.join(dir, rel)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, JSON.generate(
                         "serializer_version" => 5, "file" => file,
                         "nodes" => nodes_and_edges[:nodes],
                         "edges" => nodes_and_edges[:edges]
                       ))
    end
    File.write(File.join(dir, "archbuddy-findings.json"),
               JSON.generate("serializer_version" => 5, "sources" => sources))
    dir
  end

  def node(symbol, branches:, entrypoint: false, kind: nil, arity: nil, escapes: false)
    { "symbol" => symbol, "kind" => "function", "class" => symbol.split("#").first,
      "branches" => branches, "decisions" => Math.log2(branches).round,
      "entrypoint" => entrypoint, "entrypoint_kind" => kind,
      "escapes" => escapes, "outcome_arity" => arity,
      "toll_booth" => nil, "quadrant" => nil, "leverage" => nil, "collapse" => nil }
  end

  # ---- rows 1-3: git repo with committed cache --------------------------------

  it "row 1: empty diff (same tree, two commits, committed cache) → zeroed" do
    Dir.mktmpdir do |raw|
      repo = File.realpath(raw)
      init_repo(repo)
      write_plain_source(repo)
      collect!(repo)
      git!(repo, "add", "-f", ".")
      git!(repo, "commit", "-q", "-m", "one")
      sha1 = git!(repo, "rev-parse", "HEAD")
      File.write(File.join(repo, "README.md"), "docs only\n")
      git!(repo, "add", "README.md")
      git!(repo, "commit", "-q", "-m", "two")

      code, stdout, = run_diff(target: repo, base_ref: sha1)
      expect(code).to eq(0)
      expect(stdout).to include("0 error(s)")
      expect(stdout).to include("net Δlog2 +0.000")

      code, stdout, = run_diff(target: repo, base_ref: sha1, format: "json")
      expect(code).to eq(0)
      doc = parse_json!(stdout)
      expect(doc["summary"]["counts"].values).to all(eq(0))
      expect(doc["summary"]["delta"]["nodes_new"]).to eq(0)
      expect(doc["summary"]["delta"]["nodes_removed"]).to eq(0)
    end
  end

  it "rows 2+3: NEW b=64 node — advisory exit 0; config fail_level error → 1" do
    Dir.mktmpdir do |raw|
      repo = File.realpath(raw)
      init_repo(repo)
      write_plain_source(repo)
      collect!(repo)
      git!(repo, "add", "-f", ".")
      git!(repo, "commit", "-q", "-m", "one")
      sha1 = git!(repo, "rev-parse", "HEAD")
      write_monster(repo)
      collect!(repo)
      git!(repo, "add", "-f", ".")
      git!(repo, "commit", "-q", "-m", "two")

      # row 2 — no config: advisory
      code, stdout, = run_diff(target: repo, base_ref: sha1)
      expect(code).to eq(0)
      expect(stdout).to include("[ExponentialNode]")

      # row 3 — config gates; JSON exit_code == process status
      config = File.join(Dir.mktmpdir, ".archbuddy.yml")
      File.write(config, "version: 1\n")
      code, stdout, = run_diff(target: repo, base_ref: sha1,
                               config: config, format: "json")
      expect(code).to eq(1)
      doc = parse_json!(stdout)
      expect(doc["exit_code"]).to eq(1)
    end
  end

  it "row 4: unresolvable BASE_REF → exit 2, pinned stderr, empty stdout" do
    Dir.mktmpdir do |raw|
      repo = File.realpath(raw)
      init_repo(repo)
      write_plain_source(repo)
      git!(repo, "add", ".")
      git!(repo, "commit", "-q", "-m", "one")
      code, stdout, stderr = run_diff(target: repo, base_ref: "nope")
      expect(code).to eq(2)
      expect(stdout).to eq("")
      expect(stderr).to include("error: cannot resolve base ref 'nope'")
    end
  end

  it "row 5: orphan-branch pair (no merge-base) → exit 2" do
    Dir.mktmpdir do |raw|
      repo = File.realpath(raw)
      init_repo(repo)
      write_plain_source(repo)
      git!(repo, "add", ".")
      git!(repo, "commit", "-q", "-m", "one")
      git!(repo, "checkout", "-q", "--orphan", "other")
      git!(repo, "commit", "-q", "-m", "orphan")
      code, stdout, stderr = run_diff(target: repo, base_ref: "main")
      expect(code).to eq(2)
      expect(stdout).to eq("")
      expect(stderr).to match(/no merge-base .*shallow clone\?/m)
    end
  end

  it "row 6: ref-like TARGET gets the did-you-mean" do
    Dir.mktmpdir do |raw|
      repo = File.realpath(raw)
      init_repo(repo)
      write_plain_source(repo)
      git!(repo, "add", ".")
      git!(repo, "commit", "-q", "-m", "one")
      git!(repo, "branch", "origin/main") # a resolvable ref named like a remote
      code = stdout = stderr = nil
      Dir.chdir(repo) do
        code, stdout, stderr = run_diff(target: "origin/main")
      end
      expect(code).to eq(2)
      expect(stdout).to eq("")
      expect(stderr).to include(
        "error: 'origin/main' is not a directory — did you mean 'archbuddy diff . origin/main'?"
      )
    end
  end

  it "row 7: non-git target without --base-cache → exit 2 naming --base-cache" do
    Dir.mktmpdir do |dir|
      write_plain_source(dir)
      code, stdout, stderr = run_diff(target: dir)
      expect(code).to eq(2)
      expect(stdout).to eq("")
      expect(stderr).to include("is not inside a git repository")
      expect(stderr).to include("--base-cache")
    end
  end

  it "row 8: --base-cache dir without an aggregate → pinned message" do
    Dir.mktmpdir do |empty|
      code, stdout, stderr = run_diff(target: fixture("v5_small"),
                                      base_cache: empty, trust_cache: true)
      expect(code).to eq(2)
      expect(stdout).to eq("")
      expect(stderr).to include(
        "error: --base-cache #{empty} does not contain archbuddy-findings.json"
      )
    end
  end

  it "row 9: corrupt BASE fragment → warn + excluded_files, no phantom REMOVED" do
    code, stdout, stderr = run_diff(target: fixture("corrupt"),
                                    base_cache: fixture("corrupt"),
                                    trust_cache: true, format: "json")
    expect(code).to eq(0)
    expect(stderr).to include("warning: unreadable fragment")
    doc = parse_json!(stdout)
    expect(doc["summary"]["excluded_files"].join).to include("lib/bad.rb")
    expect(doc["summary"]["delta"]["nodes_removed"]).to eq(0) # phantom-delta guard
    expect((doc["delta_top"] || []).map { |r| r["file"] }).not_to include("lib/bad.rb")
  end

  it "row 10: --trust-cache without / with a cache" do
    Dir.mktmpdir do |bare|
      code, stdout, stderr = run_diff(target: bare, base_cache: fixture("v5_small"),
                                      trust_cache: true)
      expect(code).to eq(2)
      expect(stdout).to eq("")
      expect(stderr).to include(
        "error: --trust-cache given but no archbuddy-findings.json at #{File.expand_path(bare)}"
      )
    end

    code, stdout, stderr = run_diff(target: fixture("v5_small"),
                                    base_cache: fixture("v5_small"),
                                    trust_cache: true, format: "json")
    expect(code).to eq(0)
    expect(stderr.scan(/warning: --trust-cache: using the working-tree cache WITHOUT/).size)
      .to eq(1) # exactly once
    doc = parse_json!(stdout)
    expect(doc["run"]["head"]["vintage"]).to eq("trusted-cache")
  end

  it "row 11: ratchet paths budget matching nothing → no_match, no breach" do
    Dir.mktmpdir do |dir|
      config = File.join(dir, ".archbuddy.yml")
      File.write(config, <<~YAML)
        version: 1
        rules:
          ComplexityRatchet:
            budgets:
              - { paths: ["nowhere/**"], max_increase_log2: 0.0 }
      YAML
      code, stdout, = run_diff(target: fixture("twin_2146_head"),
                               base_cache: fixture("twin_2146_head"),
                               trust_cache: true, config: config, format: "json")
      expect(code).to eq(0)
      doc = parse_json!(stdout)
      expect(doc["ratchet"].fetch(0)["verdict"]).to eq("no_match")
      expect(doc["findings"].map { |f| f["rule"] }).not_to include("ComplexityRatchet")
    end
  end

  it "row 12: entrypoint budget over zero eps both sides → no_match" do
    Dir.mktmpdir do |dir|
      config = File.join(dir, ".archbuddy.yml")
      File.write(config, <<~YAML)
        version: 1
        rules:
          ComplexityRatchet:
            budgets:
              - { entrypoints: ["Api::**"], max_increase_log2: 0.0 }
      YAML
      code, stdout, = run_diff(target: fixture("zero_ep"),
                               base_cache: fixture("zero_ep"),
                               trust_cache: true, config: config, format: "json")
      expect(code).to eq(0)
      doc = parse_json!(stdout)
      expect(doc["ratchet"].fetch(0)["verdict"]).to eq("no_match") # never pass/breach
    end
  end

  it "row 13: empty base vintage → all head nodes NEW + the note" do
    Dir.mktmpdir do |empty_base|
      File.write(File.join(empty_base, "archbuddy-findings.json"),
                 JSON.generate(serializer_version: 5, sources: {}))
      code, stdout, stderr = run_diff(target: fixture("twin_2146_head"),
                                      base_cache: empty_base,
                                      trust_cache: true, format: "json")
      expect(code).to eq(0)
      expect(stderr).to include("note: base vintage is empty (0 nodes) — " \
                                "all head nodes count as NEW")
      doc = parse_json!(stdout)
      expect(doc["summary"]["delta"]["nodes_new"]).to eq(3) # anchor + 2 NEW eps
      expect(doc["summary"]["delta"]["nodes_removed"]).to eq(0)
    end
  end

  it "row 14: head target with zero sources → exit 2 pinned" do
    Dir.mktmpdir do |bare|
      code, stdout, stderr = run_diff(target: bare, base_cache: fixture("v5_small"))
      expect(code).to eq(2)
      expect(stdout).to eq("")
      expect(stderr).to include("error: no scored sources at #{File.expand_path(bare)}")
    end
  end

  # ---- v0.15 rows 16-19 ([D2] P2-T12) ----------------------------------------

  it "row 16: zero-ep head — Q8 note, key absence, ep rules not_evaluable, node rules live" do
    code, stdout, stderr = run_diff(target: fixture("zero_ep"),
                                    base_cache: fixture("zero_ep"),
                                    trust_cache: true, format: "json")
    expect(code).to eq(0)
    expect(stderr).to include(
      "vintage has no entrypoints (nothing is reachable — check collector entrypoint detection)"
    )
    doc = parse_json!(stdout)
    expect(doc["summary"]).not_to have_key("unreachable_from_entrypoints")
    expect(doc).not_to have_key("review_surface")

    q8_rows = doc["summary"]["not_evaluable"]
              .select { |row| row["reason"].include?("no entrypoints") }
    expect(q8_rows.map { |row| row["rule"] }.sort)
      .to eq(%w[ReviewSurface UseCaseComplexity UseCaseDividend]) # V15-F4: FB diff still runs
    all_na_rules = doc["summary"]["not_evaluable"].map { |row| row["rule"] }
    expect(all_na_rules).not_to include("ExponentialNode") # node rules still evaluated
    expect(all_na_rules).not_to include("MultiplicativeGrowth")
  end

  it "row 17: metric-quiet touch — union 0, no use_case findings, zero offsetting" do
    code, stdout, = run_diff(target: fixture("twin_2083_head"),
                             base_cache: fixture("twin_2083_head"),
                             trust_cache: true, format: "json")
    expect(code).to eq(0)
    doc = parse_json!(stdout)
    expect(doc["review_surface"]["union"]).to eq(0)
    expect(doc["review_surface"]["sum"]).to eq(0)
    use_case_rules = %w[UseCaseComplexity UseCaseDividend FirewallBreaches]
    expect(doc["findings"].map { |f| f["rule"] } & use_case_rules).to eq([])
    expect(doc["summary"]["disclosures"]["offsetting_zero_count"]).to eq(0)

    code, stdout, = run_diff(target: fixture("twin_2083_head"),
                             base_cache: fixture("twin_2083_head"), trust_cache: true)
    expect(code).to eq(0)
    expect(stdout).to include("review surface: 0 use case(s) to re-verify")
  end

  it "row 18: orphan-file-only touch — disclosure + ExponentialNode STILL fires" do
    Dir.mktmpdir do |root|
      base = write_vintage(FileUtils.mkdir_p(File.join(root, "base")).first,
                           "app/api/thing.rb" => {
                             nodes: [node("Api::Thing#GET[0]", branches: 2,
                                          entrypoint: true, kind: "grape", arity: 2)],
                             edges: [{ "from" => "Api::Thing#GET[0]", "to" => "Ext.sink",
                                       "calls" => 1 }]
                           },
                           "lib/orphan.rb" => {
                             nodes: [node("Orphan#big", branches: 32, arity: 2)],
                             edges: [{ "from" => "Orphan#big", "to" => "Ext.sink",
                                       "calls" => 1 }]
                           })
      head = write_vintage(FileUtils.mkdir_p(File.join(root, "head")).first,
                           "app/api/thing.rb" => {
                             nodes: [node("Api::Thing#GET[0]", branches: 2,
                                          entrypoint: true, kind: "grape", arity: 2)],
                             edges: [{ "from" => "Api::Thing#GET[0]", "to" => "Ext.sink",
                                       "calls" => 1 }]
                           },
                           "lib/orphan.rb" => {
                             nodes: [node("Orphan#big", branches: 64, arity: 2)],
                             edges: [{ "from" => "Orphan#big", "to" => "Ext.sink",
                                       "calls" => 1 }]
                           })

      code, stdout, = run_diff(target: head, base_cache: base,
                               trust_cache: true, format: "json")
      expect(code).to eq(0)
      doc = parse_json!(stdout)
      expect(doc["summary"]["disclosures"]["orphan_touched_files"]).to eq(["lib/orphan.rb"])
      expect(doc["review_surface"]["union"]).to eq(0) # no ep metric moved
      # the universe is reachability-independent (Q8/[S:G4]):
      expect(doc["findings"].map { |f| f["rule"] }).to include("ExponentialNode")
    end
  end

  it "row 19: offsetting-zero cone — disclosure count 1, U_metric quiet, MG below threshold" do
    Dir.mktmpdir do |root|
      shape = lambda do |a_branches, b_branches|
        {
          "app/api/pair.rb" => {
            nodes: [node("Api::Pair#GET[0]", branches: 2,
                         entrypoint: true, kind: "grape", arity: 2)],
            edges: [{ "from" => "Api::Pair#GET[0]", "to" => "Lib::A#a", "calls" => 1 },
                    { "from" => "Api::Pair#GET[0]", "to" => "Lib::B#b", "calls" => 1 }]
          },
          "lib/a.rb" => {
            nodes: [node("Lib::A#a", branches: a_branches, arity: 8)],
            edges: [{ "from" => "Lib::A#a", "to" => "Ext.sink", "calls" => 1 }]
          },
          "lib/b.rb" => {
            nodes: [node("Lib::B#b", branches: b_branches, arity: 8)],
            edges: [{ "from" => "Lib::B#b", "to" => "Ext.sink", "calls" => 1 }]
          }
        }
      end
      base = write_vintage(FileUtils.mkdir_p(File.join(root, "base")).first,
                           shape.call(4, 8)) # log2 2.0 + 3.0
      head = write_vintage(FileUtils.mkdir_p(File.join(root, "head")).first,
                           shape.call(8, 4)) # +1.0 / −1.0 → net 0 per metric

      code, stdout, = run_diff(target: head, base_cache: base,
                               trust_cache: true, format: "json")
      expect(code).to eq(0)
      doc = parse_json!(stdout)
      expect(doc["summary"]["disclosures"]["offsetting_zero_count"]).to eq(1)
      expect(doc["findings"].map { |f| f["rule"] }).not_to include("UseCaseComplexity")
      # MG fires iff growth ≥ its +2.0 threshold — the +1.0 node stays quiet
      # (universe independence is the observable; the threshold is the gate).
      expect(doc["findings"].map { |f| f["rule"] }).not_to include("MultiplicativeGrowth")

      code, stdout, = run_diff(target: head, base_cache: base, trust_cache: true)
      expect(code).to eq(0)
      expect(stdout).to match(/note: 1 use case\(s\) have changed nodes in their cone/)
    end
  end

  # ---- v0.16 score degenerate matrix (T12) -----------------------------------
  #
  # The reusability-score feature's degenerate / honest-absence behaviors
  # through the shipped CLI: never-analyzed sides, zero-ep + stale
  # disclosures, mixed serializer generations, classless nodes, zero-arity
  # surface absence (L6 — never a fabricated 0), and the absorb-absent path.
  # Committed v6 fixtures where a real cache is clearest; hand-authored
  # vintages for the generation/class/arity corners.
  describe "v0.16 score degenerate matrix (T12)" do
    def run_lint(**kwargs)
      out = StringIO.new
      err = StringIO.new
      orig_out = $stdout
      orig_err = $stderr
      $stdout = out
      $stderr = err
      code = nil
      begin
        Archbuddy::CLI::Lint.new.call(**kwargs)
      rescue SystemExit => e
        code = e.status
      ensure
        $stdout = orig_out
        $stderr = orig_err
      end
      [code, out.string, err.string]
    end

    # A v6 fragment node: the v5 `node` shape + the five findings-1.9 stamps.
    # `collapse` defaults to the FRESH value round(branches / max(arity, 1), 2)
    # (the D-C3 consistency channel); pass a mismatching value for staleness.
    # `drop:` omits stamp keys — the L6 surface-absent path.
    def v6_node(symbol, branches:, arity: 1, score: nil, score_band: nil,
                score_raw: nil, absorb: nil, absorb_raw: nil, klass: :auto,
                collapse: :fresh, entrypoint: false, kind: nil, drop: [])
      base = node(symbol, branches: branches, entrypoint: entrypoint, kind: kind, arity: arity)
      base["class"] = klass == :auto ? symbol.split("#").first : klass
      base["collapse"] =
        collapse == :fresh ? (branches.to_f / [arity || 1, 1].max).round(2) : collapse
      { "score" => score, "score_band" => score_band, "score_raw" => score_raw,
        "absorb" => absorb, "absorb_raw" => absorb_raw }
        .each { |k, v| base[k] = v unless drop.include?(k) }
      base
    end

    # Hand-authored multi-fragment vintage. Each spec: {file:, nodes:[, version:]}.
    def write_v6(dir, version: 6, **fragments)
      sources = {}
      fragments.each_value do |spec|
        rel = ".archbuddy/#{spec[:file]}.json"
        sources[spec[:file]] = { "path" => rel, "shard_mode" => "single" }
        path = File.join(dir, rel)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.generate(
                           "serializer_version" => spec.fetch(:version, version),
                           "file" => spec[:file], "nodes" => spec[:nodes], "edges" => []
                         ))
      end
      File.write(File.join(dir, "archbuddy-findings.json"),
                 JSON.generate("serializer_version" => version, "sources" => sources))
      dir
    end

    def mkdir(root, name)
      FileUtils.mkdir_p(File.join(File.realpath(root), name)).first
    end

    it "row d: never-analyzed both sides ⇒ reusability block OMITTED + RS absent-note" do
      code, stdout, stderr = run_diff(target: fixture("score_twin_v5_base"),
                                      base_cache: fixture("score_twin_v5_base"),
                                      trust_cache: true, format: "json")
      expect(code).to eq(0)
      doc = parse_json!(stdout)
      expect(doc).not_to have_key("reusability") # absent, never a null block
      expect(stderr).to include(
        "note: reusability score block omitted — no score stamps on either side"
      )
      rs = doc["summary"]["not_evaluable"].select { |n| n["rule"] == "ReusabilityScore" }
      expect(rs.map { |n| n["reason"] })
        .to eq(["score stamps absent — serializer < v6 or vintage never analyzed"])
    end

    it "row e: zero-ep v6 vintage ⇒ empty leaderboard, but the score rule still fires" do
      code, stdout, = run_lint(target: fixture("score_zero_ep"),
                               trust_cache: true, format: "json")
      expect(code).to eq(0) # advisory
      doc = JSON.parse(stdout)
      expect(doc["use_cases"]["count"]).to eq(0)
      expect(doc["use_cases"]["leaderboard"]).to eq([])
      # seed-independent (Q7 G-7): the node-kind rule evaluates regardless of eps
      rs = doc["findings"].select { |f| f["rule"] == "ReusabilityScore" }
      expect(rs.map { |f| f["symbol"] }).to eq(["Lib::Unreached#big"])
    end

    it "row f: stale head stamp ⇒ per-node disclosure, NO finding, no fabricated number" do
      code, stdout, = run_lint(target: fixture("score_stale_head"),
                               trust_cache: true, format: "json")
      expect(code).to eq(0)
      doc = JSON.parse(stdout)
      expect(doc["findings"].map { |f| f["rule"] }).not_to include("ReusabilityScore")
      rs = doc["summary"]["not_evaluable"].select { |n| n["rule"] == "ReusabilityScore" }
      expect(rs.map { |n| n["reason"] }).to eq([
        "score stamp stale for app/api/drift.rb:Api::V1::Drift#PATCH[0] — " \
        "run archbuddy analyze (or --analyze-sides)"
      ])
    end

    it "mixed v5/v6 generations ⇒ provenance serializer [5,6]; only v6 scores evaluate" do
      Dir.mktmpdir do |root|
        mk = lambda do |name, big_branches, big_score|
          write_v6(mkdir(root, name),
                   six: { file: "lib/mix6.rb", version: 6,
                          nodes: [v6_node("A#big", branches: big_branches, score: big_score,
                                          score_band: -5, score_raw: -18.75)] },
                   five: { file: "lib/mix5.rb", version: 5,
                           nodes: [node("B#plain", branches: 4, arity: 2)] })
        end
        base = mk.call("base", 8192, -4.23)
        head = mk.call("head", 65_536, -4.52)
        code, stdout, = run_diff(target: head, base_cache: base, trust_cache: true, format: "json")
        expect(code).to eq(0)
        reuse = parse_json!(stdout)["reusability"]
        expect(reuse["base"]["serializer"]).to eq([5, 6])
        expect(reuse["head"]["serializer"]).to eq([5, 6])
        # only the v6-stamped node produces a delta row; the v5 node is inert
        expect(reuse["deltas"].map { |d| d["symbol"] }).to eq(["A#big"])
      end
    end

    it "classless scored node ⇒ evaluated without a class (no crash, finding fires)" do
      Dir.mktmpdir do |root|
        dir = write_v6(File.realpath(root),
                       one: { file: "lib/anon.rb", version: 6,
                              nodes: [v6_node("A#big", branches: 65_536, klass: nil,
                                              score: -4.52, score_band: -5, score_raw: -18.75)] })
        code, stdout, = run_lint(target: dir, trust_cache: true, format: "json")
        expect(code).to eq(0)
        rs = JSON.parse(stdout)["findings"].select { |f| f["rule"] == "ReusabilityScore" }
        expect(rs.map { |f| f["symbol"] }).to eq(["A#big"])
      end
    end

    it "zero-arity surface absent ⇒ node carries NO score keys ⇒ RS absent-note, never a 0" do
      Dir.mktmpdir do |root|
        dir = write_v6(File.realpath(root),
                       one: { file: "lib/arityless.rb", version: 6,
                              nodes: [v6_node("A#noarity", branches: 4, arity: nil, collapse: nil,
                                              drop: %w[score score_band score_raw absorb absorb_raw])] })
        code, stdout, = run_lint(target: dir, trust_cache: true, format: "json")
        expect(code).to eq(0)
        doc = JSON.parse(stdout)
        expect(doc["findings"].map { |f| f["rule"] }).not_to include("ReusabilityScore")
        rs = doc["summary"]["not_evaluable"].select { |n| n["rule"] == "ReusabilityScore" }
        expect(rs.map { |n| n["reason"] })
          .to eq(["score stamps absent — serializer < v6 or vintage never analyzed"])
      end
    end

    it "absorb-absent ⇒ diff renders NO absorb candidates (engine omitted the keys)" do
      Dir.mktmpdir do |root|
        pair = lambda do |name, branches, score, raw, band|
          write_v6(mkdir(root, name),
                   one: { file: "lib/a.rb", version: 6,
                          nodes: [v6_node("A#ep", branches: branches, entrypoint: true,
                                          kind: "grape", score: score, score_band: band,
                                          score_raw: raw, drop: %w[absorb absorb_raw])] })
        end
        base = pair.call("base", 8192, -4.23, -15.0, -4)
        head = pair.call("head", 65_536, -4.52, -18.75, -5)
        code, stdout, = run_diff(target: head, base_cache: base, trust_cache: true, format: "json")
        expect(code).to eq(0)
        expect(parse_json!(stdout)["reusability"]["absorb_candidates"]).to eq([])
      end
    end
  end
end
