# frozen_string_literal: true

require "tmpdir"
require "json"
require "stringio"
require "digest"
require "open3"
require "archbuddy/cli"

# v0.15 P2-T11: `archbuddy diff [TARGET] [BASE_REF]` end-to-end — the exit
# table ([S:L3/P6/R4] carried), the #2083-twin canon JSON (review_surface /
# disclosures / components / contributors), zero-ep Q8 honesty, stdout
# purity, no-mutation + tmpdir hygiene, and the corpus-gated two-graph
# wall budget (≤ 2 s; measured 153 ms cold — headroom is the alarm).
RSpec.describe Archbuddy::CLI::Diff do
  FIXTURES = File.expand_path("../fixtures/review/vintages", __dir__)
  REPO_ROOT = File.expand_path("../..", __dir__)

  def fixture(name)
    File.join(FIXTURES, name)
  end

  # In-process run (house SystemExit interception, check_gate_spec pattern).
  def run_diff(**kwargs)
    out = StringIO.new
    err = StringIO.new
    orig_out = $stdout
    orig_err = $stderr
    $stdout = out
    $stderr = err
    code = nil
    begin
      described_class.new.call(**kwargs)
    rescue SystemExit => e
      code = e.status
    ensure
      $stdout = orig_out
      $stderr = orig_err
    end
    [code, out.string, err.string]
  end

  def twin_kwargs(head: "twin_2083_head", base: "twin_2083_base", **extra)
    { target: fixture(head), base_cache: fixture(base), trust_cache: true, **extra }
  end

  def write_config(dir, yaml)
    path = File.join(dir, ".archbuddy.yml")
    File.write(path, yaml)
    path
  end

  describe "--help" do
    it "exits 0 and documents the merge-base semantics + all 8 options" do
      output, status = Open3.capture2e(
        { "ARCHITECTURE_AUDITOR_PATH" => ENV.fetch("ARCHITECTURE_AUDITOR_PATH", nil) }.compact,
        RbConfig.ruby, File.join(REPO_ROOT, "exe", "archbuddy"), "diff", "--help",
        chdir: REPO_ROOT
      )
      expect(status.exitstatus).to eq(0)
      expect(output).to include("git merge-base BASE_REF HEAD")
      # dry-cli renders booleans as --[no-]flag; accept both spellings.
      %w[format config base-cache trust-cache fail-level
         advisory todo no-todo].each do |flag|
        expect(output).to match(/--(\[no-\])?#{Regexp.escape(flag)}/)
      end
    end
  end

  describe "the exit table (L3 advisory default, gating by config/flags)" do
    it "no config: findings printed, exit 0 (advisory)" do
      code, stdout, = run_diff(**twin_kwargs)
      expect(code).to eq(0)
      expect(stdout).to include("[ExponentialNode]")
    end

    it "config present: the #2083 error findings gate at exit 1" do
      Dir.mktmpdir do |dir|
        config = write_config(dir, "version: 1\n")
        code, = run_diff(**twin_kwargs(config: config))
        expect(code).to eq(1)
      end
    end

    it "--advisory and --fail-level none never gate" do
      Dir.mktmpdir do |dir|
        config = write_config(dir, "version: 1\n")
        expect(run_diff(**twin_kwargs(config: config, advisory: true)).first).to eq(0)
        expect(run_diff(**twin_kwargs(config: config, fail_level: "none")).first).to eq(0)
      end
    end

    it "--fail-level warn gates on a warn-only run (EN+MG disabled leaves UCC/UCD)" do
      Dir.mktmpdir do |dir|
        config = write_config(dir, <<~YAML)
          version: 1
          rules:
            ExponentialNode: { enabled: false }
            MultiplicativeGrowth: { enabled: false }
        YAML
        code, stdout, = run_diff(**twin_kwargs(config: config, fail_level: "warn",
                                               format: "json"))
        expect(code).to eq(1)
        doc = JSON.parse(stdout)
        expect(doc["summary"]["counts"]["error"]).to eq(0)
        expect(doc["summary"]["counts"]["warn"]).to eq(2)

        expect(run_diff(**twin_kwargs(config: config, fail_level: "error")).first).to eq(0)
      end
    end
  end

  describe "exit-2 paths (pinned stderr, EMPTY stdout)" do
    it "rejects an unknown --format" do
      code, stdout, stderr = run_diff(**twin_kwargs(format: "bogus"))
      expect(code).to eq(2)
      expect(stdout).to eq("")
      expect(stderr).to include("error: unknown format 'bogus' (terminal|markdown|json)")
    end

    it "rejects an unknown --fail-level" do
      code, stdout, stderr = run_diff(**twin_kwargs(fail_level: "bogus"))
      expect(code).to eq(2)
      expect(stdout).to eq("")
      expect(stderr).to include("error: unknown fail level 'bogus' (none|info|warn|error)")
    end

    it "rejects --todo combined with --no-todo" do
      code, stdout, stderr = run_diff(**twin_kwargs(todo: "x.yml", no_todo: true))
      expect(code).to eq(2)
      expect(stdout).to eq("")
      expect(stderr).to include("error: --todo and --no-todo are mutually exclusive")
    end

    it "rejects a nonexistent target" do
      code, stdout, stderr = run_diff(target: "/nonexistent/nowhere")
      expect(code).to eq(2)
      expect(stdout).to eq("")
      expect(stderr).to include("error: target '/nonexistent/nowhere' is not a directory")
    end

    it "gives the did-you-mean when the target parses as a git ref" do
      code, stdout, stderr = run_diff(target: "HEAD")
      expect(code).to eq(2)
      expect(stdout).to eq("")
      expect(stderr)
        .to include("error: 'HEAD' is not a directory — did you mean 'archbuddy diff . HEAD'?")
    end

    it "requires --base-cache outside a git repository" do
      Dir.mktmpdir do |dir|
        code, stdout, stderr = run_diff(target: dir)
        expect(code).to eq(2)
        expect(stdout).to eq("")
        expect(stderr).to include("is not inside a git repository")
        expect(stderr).to include("--base-cache")
      end
    end

    it "surfaces config validation errors" do
      Dir.mktmpdir do |dir|
        config = write_config(dir, "version: 1\nrules:\n  NoNewEscapes: {}\n")
        code, stdout, stderr = run_diff(**twin_kwargs(config: config))
        expect(code).to eq(2)
        expect(stdout).to eq("")
        expect(stderr).to start_with("error:")
        expect(stderr).to include("FirewallBreaches") # retired-name successor guidance
      end
    end
  end

  describe "the #2083-twin canon JSON (air-gapped: --base-cache + --trust-cache)" do
    it "carries review_surface.union 1, disclosures, components + contributors" do
      code, stdout, = run_diff(**twin_kwargs(format: "json"))
      expect(code).to eq(0)
      expect(stdout[0]).to eq("{") # first stdout byte (purity)
      doc = JSON.parse(stdout)

      expect(doc["exit_code"]).to eq(0) # equals the process status
      expect(doc["review_surface"]["union"]).to eq(1) # TOP-LEVEL key (R41)
      expect(doc["review_surface"]["sum"]).to eq(1)
      expect(doc["summary"]["disclosures"]["orphan_touched_files"])
        .to eq(["app/models/program/redeem/template.rb"])
      expect(doc["summary"]["delta"]["net_log2_b_own"]).to eq(3.0)
      expect(doc["summary"]["unreachable_from_entrypoints"]).not_to be_nil

      ucc = doc["findings"].find { |f| f["rule"] == "UseCaseComplexity" }
      expect(ucc["components"]).to be_a(Hash)
      expect(ucc["contributors"]).not_to be_empty
      expect(doc["run"]["base"]["sources_count"]).to be_a(Integer) # [S:F5]
      expect(doc["run"]["head"]["sources_count"]).to be_a(Integer)
    end

    it "json exit_code field equals the process status on a gating run too" do
      Dir.mktmpdir do |dir|
        config = write_config(dir, "version: 1\n")
        code, stdout, = run_diff(**twin_kwargs(config: config, format: "json"))
        expect(code).to eq(1)
        expect(JSON.parse(stdout)["exit_code"]).to eq(1)
      end
    end
  end

  describe "Q8 zero-ep honesty" do
    it "zero-ep head: review_surface ABSENT, the Q8 note on stderr, exit unchanged" do
      code, stdout, stderr = run_diff(target: fixture("zero_ep"),
                                      base_cache: fixture("zero_ep"),
                                      trust_cache: true, format: "json")
      expect(code).to eq(0)
      doc = JSON.parse(stdout)
      expect(doc).not_to have_key("review_surface")
      expect(doc["summary"]).not_to have_key("unreachable_from_entrypoints")
      expect(stderr).to include("vintage has no entrypoints (nothing is reachable")
    end
  end

  describe "degenerates" do
    it "comment-only/identical pair: union 0 rendered, net +0.000, exit 0" do
      code, stdout, = run_diff(**twin_kwargs(head: "twin_2146_head",
                                             base: "twin_2146_head", format: "json"))
      expect(code).to eq(0)
      doc = JSON.parse(stdout)
      expect(doc["review_surface"]["union"]).to eq(0)
      expect(doc["summary"]["delta"]["net_log2_b_own"]).to eq(0.0)
      expect(doc["findings"]).to eq([])
    end
  end

  describe "the reusability envelope block (v0.16 T10, e2e over v6 caches)" do
    # A minimal serializer-v6 committed cache: aggregate + one fragment.
    # Score stamps are fixture stand-ins for ENGINE-published values (the
    # client only ever copies/subtracts them — L2/D17); `collapse` is kept
    # consistent with branches/arity so the stamps read FRESH (D-C3).
    def write_v6_cache(dir, nodes)
      frag_rel = ".archbuddy/app/api/w.rb.json"
      FileUtils.mkdir_p(File.join(dir, File.dirname(frag_rel)))
      File.write(File.join(dir, "archbuddy-findings.json"), JSON.pretty_generate(
        "serializer_version" => 6,
        "sources" => { "app/api/w.rb" => { "path" => frag_rel, "shard_mode" => "single" } }
      ))
      File.write(File.join(dir, frag_rel), JSON.pretty_generate(
        "serializer_version" => 6, "file" => "app/api/w.rb", "nodes" => nodes
      ))
    end

    def v6_node(symbol:, branches:, score:, score_raw:, score_band: nil,
                absorb: nil, absorb_raw: nil, entrypoint: false)
      { "symbol" => symbol, "kind" => "function", "class" => "W",
        "branches" => branches, "decisions" => 1, "entrypoint" => entrypoint,
        "entrypoint_kind" => entrypoint ? "grape" : nil, "escapes" => false,
        "outcome_arity" => 1, "toll_booth" => false, "quadrant" => nil,
        "leverage" => nil, "collapse" => branches.to_f.round(2),
        "score" => score, "score_band" => score_band, "score_raw" => score_raw,
        "absorb" => absorb, "absorb_raw" => absorb_raw }
    end

    it "emits the block (per-side provenance, raw-milli delta, L9-A absorb gate) and schema-validates" do
      Dir.mktmpdir do |dir|
        base_dir = File.join(dir, "base")
        head_dir = File.join(dir, "head")
        FileUtils.mkdir_p([base_dir, head_dir])
        write_v6_cache(base_dir, [
          v6_node(symbol: "W#go", branches: 8, score: -1.2, score_raw: -1.9,
                  score_band: -1, entrypoint: true)
        ])
        write_v6_cache(head_dir, [
          v6_node(symbol: "W#go", branches: 16, score: -1.5, score_raw: -2.2,
                  score_band: -2, entrypoint: true),
          v6_node(symbol: "W#booth", branches: 1, score: 0.0, score_raw: 0.0,
                  score_band: 0, absorb: 4.32, absorb_raw: 6.907)
        ])
        config = write_config(dir, <<~YAML)
          version: 1
          rules:
            ReusabilityScore: { absorb_min_score: 4 }
        YAML

        code, stdout, stderr = run_diff(target: head_dir, base_cache: base_dir,
                                        trust_cache: true, config: config,
                                        format: "json")
        expect(code).to eq(0)
        doc = JSON.parse(stdout)

        block = doc.fetch("reusability")
        expect(block["base"]).to eq(
          "source" => "injected-dir", "analyzed" => true, "serializer" => [6],
          "scored_nodes" => 1, "stale_stamps" => 0
        )
        expect(block["head"]["source"]).to eq("trusted-cache")
        expect(block["head"]["scored_nodes"]).to eq(2)
        expect(block["head"]["stale_stamps"]).to eq(0)

        grown = block["deltas"].find { |r| r["symbol"] == "W#go" }
        expect(grown["classification"]).to eq("GROWN")
        expect(grown["base"]).to eq("score" => -1.2, "score_raw" => -1.9)
        expect(grown["head"]).to eq("score" => -1.5, "score_raw" => -2.2)
        expect(grown["delta_raw_milli"]).to eq(-300) # (−2.2 − −1.9) in milli

        expect(block["absorb_candidates"]).to eq([
          { "file" => "app/api/w.rb", "symbol" => "W#booth", "score" => 0.0,
            "absorb" => 4.32, "absorb_raw" => 6.907 }
        ])
        expect(stderr).not_to include("reusability score block omitted")

        schema = File.expand_path("../fixtures/review/archbuddy-diff-report-1.schema.json", __dir__)
        require "json-schema"
        expect(JSON::Validator.fully_validate(schema, doc)).to eq([])
      end
    end

    it "gates absorb candidates at the default +5 param (4.32 stays a non-disclosure)" do
      Dir.mktmpdir do |dir|
        base_dir = File.join(dir, "base")
        head_dir = File.join(dir, "head")
        FileUtils.mkdir_p([base_dir, head_dir])
        twin_nodes = [
          v6_node(symbol: "W#go", branches: 8, score: -1.2, score_raw: -1.9,
                  entrypoint: true),
          v6_node(symbol: "W#booth", branches: 1, score: 0.0, score_raw: 0.0,
                  absorb: 4.32, absorb_raw: 6.907)
        ]
        write_v6_cache(base_dir, twin_nodes)
        write_v6_cache(head_dir, twin_nodes)
        code, stdout, = run_diff(target: head_dir, base_cache: base_dir,
                                 trust_cache: true, format: "json")
        expect(code).to eq(0)
        doc = JSON.parse(stdout)
        expect(doc["reusability"]["absorb_candidates"]).to eq([])
        expect(doc["reusability"]["deltas"]).to eq([]) # unchanged nodes never ride deltas
      end
    end

    it "omits the key on scoreless (pre-v6) sides with ONE stderr note — absent, never null" do
      code, stdout, stderr = run_diff(**twin_kwargs(format: "json"))
      expect(code).to eq(0)
      doc = JSON.parse(stdout)
      expect(doc).not_to have_key("reusability")
      note = "note: reusability score block omitted — no score stamps on " \
             "either side (serializer < v6 or vintage never analyzed)"
      expect(stderr.scan(note).size).to eq(1)
      expect(stdout[0]).to eq("{") # CLEAN-STDOUT: the document is stdout's only write
    end
  end

  describe "no-mutation + tmpdir hygiene" do
    def tree_digest(dir)
      Dir.glob(File.join(dir, "**", "*"), File::FNM_DOTMATCH).sort.map do |path|
        next unless File.file?(path)

        "#{path}:#{Digest::SHA256.file(path).hexdigest}"
      end.compact.join("\n")
    end

    it "leaves the target byte-identical and no archbuddy-diff-* scratch behind" do
      before_head = tree_digest(fixture("twin_2083_head"))
      before_base = tree_digest(fixture("twin_2083_base"))
      leftovers_before = Dir.glob(File.join(Dir.tmpdir, "archbuddy-diff-*"))

      code, = run_diff(**twin_kwargs)
      expect(code).to eq(0)

      expect(tree_digest(fixture("twin_2083_head"))).to eq(before_head)
      expect(tree_digest(fixture("twin_2083_base"))).to eq(before_base)
      expect(Dir.glob(File.join(Dir.tmpdir, "archbuddy-diff-*"))).to eq(leftovers_before)
    end
  end

  describe "two-graph all-ep wall budget (corpus-gated)" do
    SNAP_BASE = "fffa6bb655d7bf601366697a12aca3b14565cd13"
    SNAP_HEAD = "0146ad98bc6d52dc6fb78f4573dd90f698150091"

    it "runs the full in-process pipeline over full-nexus vintages in ≤ 2 s" do
      corpus = ENV["ARCHBUDDY_STUDY_CORPUS"]
      skip "ARCHBUDDY_STUDY_CORPUS not set — wall budget skipped" if corpus.nil? || corpus.empty?

      base_dir = File.join(corpus, "snapshots", SNAP_BASE)
      head_dir = File.join(corpus, "snapshots", SNAP_HEAD)
      raise "snapshot missing at #{base_dir}" unless File.directory?(base_dir)
      raise "snapshot missing at #{head_dir}" unless File.directory?(head_dir)

      orig = $stderr
      $stderr = StringIO.new
      begin
        t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        base_v = Archbuddy::Review::FragmentWalk.read(base_dir)
        head_v = Archbuddy::Review::FragmentWalk.read(head_dir)
        base_eps = base_v.graph.ep_metrics
        head_eps = head_v.graph.ep_metrics
        delta = Archbuddy::Review::Delta.new(base: base_v, head: head_v)
        delta.entries
        delta.ep_entries
        surface = delta.review_surface
        wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      ensure
        $stderr = orig
      end

      expect(head_eps.count).to eq(326) # the Q5 inventory canon holds en route
      expect(base_eps.count).to be_positive
      expect(surface[:union]).to be >= 0
      expect(wall).to be <= 2.0
    end
  end
end
