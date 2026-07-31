# frozen_string_literal: true

require "tmpdir"
require "json"
require "stringio"
require "fileutils"
require "open3"
require "archbuddy/cli"

# v0.15 P2-T13: the Q5-canon worked-example gates — always-run synthetic
# twins (authored by P2-T4, §5-C28; consumed here through the shipped CLI),
# the corpus-gated real #2083 snapshot pairing (node rows + the +14.0 and
# ==90 churn traps + the confinement-verified redeem vector), and the NEW
# (merge^1, merge) clean-pair gates via ARCHBUDDY_STUDY_REPOS (Q4 canon:
# #2083 RS 1/1, #2146 RS 2/2). Env-gated groups SKIP loudly when unset —
# the twins keep the entire canon always-enforced.
RSpec.describe "diff worked-example gates (Q5 canon)" do
  FIXTURES_WE = File.expand_path("../fixtures/review/vintages", __dir__)
  WE_REDEEM_FILE = "app/api/api/v1/redeem_templates.rb"
  WE_REDEEM_EP = "Api::V1::RedeemTemplates#PATCH[0]"

  WE_GIT_ENV = {
    "GIT_AUTHOR_NAME" => "spec", "GIT_AUTHOR_EMAIL" => "spec@example.invalid",
    "GIT_COMMITTER_NAME" => "spec", "GIT_COMMITTER_EMAIL" => "spec@example.invalid",
    "GIT_CONFIG_GLOBAL" => "/dev/null", "GIT_CONFIG_SYSTEM" => "/dev/null"
  }.freeze

  def fixture(name) = File.join(FIXTURES_WE, name)

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

  def git!(dir, *args)
    out, err, status = Open3.capture3(WE_GIT_ENV, "git", "-C", dir, *args)
    raise "git #{args.join(' ')} failed: #{err}" unless status.success?

    out.strip
  end

  # [S:C16] minimal in-spec parse: "org/name=/path[:prefix],…" → {key => [path, prefix]}.
  def study_repos
    raw = ENV.fetch("ARCHBUDDY_STUDY_REPOS", "")
    raw.split(",").to_h do |pair|
      key, value = pair.split("=", 2)
      path, prefix = value.to_s.split(":", 2)
      [key.to_s.strip, [path, prefix]]
    end
  end

  def worktree_count(repo)
    porcelain = git!(repo, "worktree", "list", "--porcelain")
    porcelain.scan(/^worktree /).size
  end

  def quiet_collect(dir, out)
    orig = $stderr
    $stderr = StringIO.new
    Archbuddy::Review::Collector.collect(source_root: dir, write_root: out)
  ensure
    $stderr = orig
  end

  # ---- (b) always-run synthetic gates ------------------------------------------

  describe "always-run synthetic twins (the A5 gates, amended to the 8-family)" do
    it "#2083-twin: the FULL Q5 canon through the shipped CLI" do
      Dir.mktmpdir do |dir|
        config = File.join(dir, ".archbuddy.yml")
        File.write(config, <<~YAML)
          version: 1
          rules:
            ComplexityRatchet:
              enabled: true
              severity: error
              budgets:
                - { paths: ["app/**/*"], max_increase_log2: 0.0 }
        YAML
        code, stdout, = run_diff(target: fixture("twin_2083_head"),
                                 base_cache: fixture("twin_2083_base"),
                                 trust_cache: true, config: config, format: "json")
        expect(code).to eq(1)
        doc = JSON.parse(stdout)

        # findings EXACTLY: EN(error) + MG(error) + UCC(warn) + UCD(warn)
        expect(doc["findings"].map { |f| f["rule"] }.sort)
          .to eq(%w[ExponentialNode MultiplicativeGrowth UseCaseComplexity UseCaseDividend])
        expect(doc["summary"]["counts"]["error"]).to eq(2)
        expect(doc["summary"]["counts"]["warn"]).to eq(2)

        ucc = doc["findings"].find { |f| f["rule"] == "UseCaseComplexity" }
        expect(ucc["severity"]).to eq("warn")
        expect(ucc["message"]).to include("(Q4 boundary)") # the Q4-trigger clause
        ucd = doc["findings"].find { |f| f["rule"] == "UseCaseDividend" }
        expect(ucd["severity"]).to eq("warn")
        expect(ucd["message"]).to include("×65536")

        ratchet = doc["ratchet"].fetch(0)
        expect(ratchet["verdict"]).to eq("breach") # net +3.000 vs budget +0.000
        expect(ratchet["observed_log2"]).to eq(3.0)
        expect(ratchet["budget_log2"]).to eq(0.0)

        expect(doc["review_surface"]["union"]).to eq(1)
        expect(doc["review_surface"]["sum"]).to eq(1)
        expect(doc["review_surface"]["unreachable_touched"]["count"]).to eq(1)
        expect(doc["summary"]["delta"]["net_log2_b_own"]).to eq(3.0)
        expect(doc["summary"]["disclosures"]["orphan_touched_files"])
          .to eq(["app/models/program/redeem/template.rb"])
      end
    end

    it "#2146-twin, NO config: zero findings from all eight rules, RS 2/2, net +1.000" do
      code, stdout, = run_diff(target: fixture("twin_2146_head"),
                               base_cache: fixture("twin_2146_base"),
                               trust_cache: true, format: "json")
      expect(code).to eq(0)
      doc = JSON.parse(stdout)
      expect(doc["findings"]).to eq([])
      expect(doc["review_surface"]["union"]).to eq(2)
      expect(doc["review_surface"]["sum"]).to eq(2)
      expect(doc["summary"]["delta"]["net_log2_b_own"]).to eq(1.0)

      top = doc["delta_top"].sort_by { |row| row["symbol"] }
      expect(top.map { |row| row["symbol"] })
        .to eq(%w[Api::V1::SegmentActivationPreferences#GET[0]
                  Api::V1::SegmentActivationPreferences#PATCH[0]])
      expect(top.map { |row| row["delta_log2"] }).to eq([0.0, 1.0])
    end
  end

  # ---- (c) corpus-gated real #2083 (snapshot pairing) --------------------------

  describe "corpus-gated real #2083 snapshot pairing (pr_base, merge)" do
    SNAP_HEAD_2083 = "f61b758c21d14580056812d4d63ab269aa5d7a37"
    SNAP_BASE_2083 = "68abf8310626a203ff3a1733d0bb96387904067f"

    it "reproduces the node rows + both churn traps + the confined redeem vector" do
      corpus = ENV["ARCHBUDDY_STUDY_CORPUS"]
      skip "ARCHBUDDY_STUDY_CORPUS not set — real #2083 gate skipped" if corpus.nil? || corpus.empty?

      head_snap = File.join(corpus, "snapshots", SNAP_HEAD_2083)
      base_snap = File.join(corpus, "snapshots", SNAP_BASE_2083)
      raise "snapshot missing at #{head_snap}" unless File.directory?(head_snap)
      raise "snapshot missing at #{base_snap}" unless File.directory?(base_snap)

      Dir.mktmpdir do |tmp|
        target = File.join(tmp, "head")
        FileUtils.mkdir_p(target)
        # Copy ONLY the aggregate + the exported detail dir — NEVER id-map.*
        FileUtils.cp(File.join(head_snap, "archbuddy-findings.json"), target)
        FileUtils.cp_r(File.join(head_snap, "archbuddy"), target)
        expect(Dir.glob(File.join(target, "**", "id-map*"))).to eq([]) # hygiene gate

        config = File.join(tmp, ".archbuddy.yml")
        File.write(config, <<~YAML)
          version: 1
          rules:
            ComplexityRatchet:
              budgets:
                - { paths: ["#{WE_REDEEM_FILE}", "app/models/program/redeem/template.rb"], max_increase_log2: 0.0 }
        YAML

        code, stdout, = run_diff(target: target, base_cache: base_snap,
                                 trust_cache: true, config: config, format: "json")
        expect(code).to eq(1)
        doc = JSON.parse(stdout)

        mg = doc["findings"].find do |f|
          f["rule"] == "MultiplicativeGrowth" && f["symbol"] == WE_REDEEM_EP
        end
        expect(mg).not_to be_nil
        expect(mg["values"]["base_branches"]).to eq(8192)
        expect(mg["values"]["head_branches"]).to eq(65_536)
        expect(mg["delta_log2"]).to eq(3.0)
        en = doc["findings"].find do |f|
          f["rule"] == "ExponentialNode" && f["symbol"] == WE_REDEEM_EP
        end
        expect(en).not_to be_nil

        ratchet = doc["ratchet"].fetch(0)
        expect(ratchet["verdict"]).to eq("breach") # scope net +3.000 vs +0.000
        expect(ratchet["observed_log2"]).to eq(3.0)
        expect(ratchet["budget_log2"]).to eq(0.0)

        # the +14.0 global churn trap — the number that justifies merge-base
        # isolation in live CI (asserted AS a trap, never as canon)
        expect(doc["summary"]["delta"]["net_log2_b_own"].round(1)).to eq(14.0)

        # ep-level rows valid at THIS pairing (in-process, same pair)
        base_v = Archbuddy::Review::FragmentWalk.read(base_snap)
        head_v = Archbuddy::Review::FragmentWalk.read(target)
        delta = Archbuddy::Review::Delta.new(base: base_v, head: head_v)
        entries = delta.ep_entries
        expect(entries.length).to eq(90) # the G7 ep churn trap (pr_base, merge)

        redeem = entries.find { |e| e.file == WE_REDEEM_FILE && e.ep_symbol == WE_REDEEM_EP }
        expect(redeem.classification).to eq(:matched)
        expect(redeem.base.branching_log2).to be_within(1e-6).of(13.0)
        expect(redeem.head.branching_log2).to be_within(1e-6).of(16.0)
        expect(redeem.base.mass).to eq(73)
        expect(redeem.head.mass).to eq(83)
        expect(redeem.base.files).to eq(1) # R4's confinement cross-check
        expect(redeem.head.files).to eq(1) # (mismatch = halt, never widen)
        expect(redeem.base.dividend).to be_within(1e-6).of(8192.0)
        expect(redeem.head.dividend).to be_within(1e-6).of(65_536.0)
        # review_surface deliberately NOT asserted here — churn-contaminated
        # pairing; the clean-pair gates below own the RS canon (Q4).
      end
    end
  end

  # ---- (d) clean-pair gates via ARCHBUDDY_STUDY_REPOS (Q4 canon) ---------------

  describe "clean-pair (merge^1, merge) gates on the archived repo" do
    ARCHIVE_KEY = "thanx/thanx-merchant-api-new"
    MERGE_2083 = "f61b758c21d1"
    MERGE1_2083 = "5f2b8a6f"
    MERGE_2146 = "83cc360c2879"
    BASE_2146 = "de9630a6f0b9"

    def with_worktree(repo, sha)
      before_count = worktree_count(repo)
      Dir.mktmpdir do |tmp|
        # realpath: macOS /var → /private/var must match git's toplevel,
        # or Git.prefix computes a bogus monorepo prefix.
        wt = File.join(File.realpath(tmp), "wt")
        git!(repo, "worktree", "add", "--detach", wt, sha)
        begin
          yield wt
        ensure
          git!(repo, "worktree", "remove", "--force", wt)
          expect(worktree_count(repo)).to eq(before_count) # hygiene
        end
      end
    end

    it "#2083 clean pair: RS ∪==1 AND Σ==1 + the full Q5 vector both sides" do
      path, _prefix = study_repos[ARCHIVE_KEY]
      skip "ARCHBUDDY_STUDY_REPOS without #{ARCHIVE_KEY} — clean-pair gate skipped" if path.nil?

      # the pinned merge^1 identity retires the canon assumption first
      expect(git!(path, "rev-parse", "#{MERGE_2083}^")).to start_with(MERGE1_2083)

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      with_worktree(path, MERGE_2083) do |head_wt|
        # the shipped CLI, both sides stateless
        code, stdout, = run_diff(target: head_wt, base_ref: MERGE1_2083, format: "json")
        expect(code).to eq(0) # advisory (no config)
        doc = JSON.parse(stdout)
        expect(doc["review_surface"]["union"]).to eq(1)
        expect(doc["review_surface"]["sum"]).to eq(1)

        # the full Q5 vector both sides (in-process over the same pair)
        Dir.mktmpdir do |caches|
          head_cache = File.join(caches, "head")
          quiet_collect(head_wt, head_cache)
          base_cache = File.join(caches, "base")
          with_worktree(path, MERGE1_2083) { |base_wt| quiet_collect(base_wt, base_cache) }

          base_v = Archbuddy::Review::FragmentWalk.read(base_cache)
          head_v = Archbuddy::Review::FragmentWalk.read(head_cache)
          delta = Archbuddy::Review::Delta.new(base: base_v, head: head_v)
          entries = delta.ep_entries
          expect(entries.length).to eq(1) # the clean window: exactly the redeem ep
          redeem = entries.first
          expect([redeem.file, redeem.ep_symbol]).to eq([WE_REDEEM_FILE, WE_REDEEM_EP])
          expect(redeem.classification).to eq(:matched)
          expect(redeem.base.branching_log2).to be_within(1e-6).of(13.0)
          expect(redeem.head.branching_log2).to be_within(1e-6).of(16.0)
          expect(redeem.base.mass).to eq(73)
          expect(redeem.head.mass).to eq(83)
          expect(redeem.base.reach).to eq(2)
          expect(redeem.head.reach).to eq(2)
          expect(redeem.base.files).to eq(1)
          expect(redeem.head.files).to eq(1)
          expect(redeem.base.depth).to eq(2)
          expect(redeem.head.depth).to eq(2)
          expect(redeem.base.dividend).to be_within(1e-6).of(8192.0)
          expect(redeem.head.dividend).to be_within(1e-6).of(65_536.0)
        end
      end
      wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      expect(wall).to be < 90.0
    end

    it "#2146 clean pair: RS ∪==2 AND Σ==2 + both Q5 head vectors, nil bases" do
      path, _prefix = study_repos[ARCHIVE_KEY]
      skip "ARCHBUDDY_STUDY_REPOS without #{ARCHIVE_KEY} — clean-pair gate skipped" if path.nil?

      t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      with_worktree(path, MERGE_2146) do |head_wt|
        code, stdout, = run_diff(target: head_wt, base_ref: BASE_2146, format: "json")
        expect(code).to eq(0)
        doc = JSON.parse(stdout)
        expect(doc["review_surface"]["union"]).to eq(2)
        expect(doc["review_surface"]["sum"]).to eq(2)
        expect(doc["summary"]["delta"]["nodes_new"]).to eq(2)
        expect(doc["summary"]["delta"]["net_log2_b_own"]).to eq(1.0)
        expect(doc["findings"].select { |f| f["severity"] == "error" }).to eq([])

        top = doc["delta_top"].sort_by { |row| row["symbol"] }
        expect(top.map { |row| row["symbol"] })
          .to eq(%w[Api::V1::SegmentActivationPreferences#GET[0]
                    Api::V1::SegmentActivationPreferences#PATCH[0]])
        expect(top.map { |row| row["delta_log2"] }).to eq([0.0, 1.0])

        Dir.mktmpdir do |caches|
          head_cache = File.join(caches, "head")
          quiet_collect(head_wt, head_cache)
          base_cache = File.join(caches, "base")
          with_worktree(path, BASE_2146) { |base_wt| quiet_collect(base_wt, base_cache) }

          base_v = Archbuddy::Review::FragmentWalk.read(base_cache)
          head_v = Archbuddy::Review::FragmentWalk.read(head_cache)
          delta = Archbuddy::Review::Delta.new(base: base_v, head: head_v)
          news = delta.ep_entries.select { |e| e.classification == :new }
                      .sort_by(&:ep_symbol)
          expect(news.map(&:ep_symbol))
            .to eq(%w[Api::V1::SegmentActivationPreferences#GET[0]
                      Api::V1::SegmentActivationPreferences#PATCH[0]])
          expect(news.map(&:base)).to eq([nil, nil])

          get, patch = news
          expect(get.head.branching_log2).to be_within(1e-6).of(0.0)
          expect(get.head.mass).to eq(7)
          expect([get.head.reach, get.head.files, get.head.depth]).to eq([1, 1, 1])
          expect(get.head.dividend).to be_within(1e-6).of(1.0)
          expect(patch.head.branching_log2).to be_within(1e-6).of(1.0)
          expect(patch.head.mass).to eq(22)
          expect([patch.head.reach, patch.head.files, patch.head.depth]).to eq([1, 1, 1])
          expect(patch.head.dividend).to be_within(1e-6).of(2.0)
        end
      end
      wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
      expect(wall).to be < 60.0
    end
  end

  # ---- (e) v0.16 end-to-end score battery (T12) --------------------------------
  #
  # The whole reusability-score feature exercised through the SHIPPED CLI over
  # committed v6 fixtures authored to X-6's worked values (the G-1 monster
  # canon: score −4.23 → −4.52, raw −15.0 → −18.75, band −4 → −5; a +5 absorb
  # booth callee). Rows a/b/c/g/h/i of the T12 matrix + byte-determinism; the
  # degenerate rows (d–f + the generation/class/arity corners) live in
  # diff_degenerate_spec.rb. Every value here is ENGINE-published and copied
  # verbatim — the client never computes a score (L2/D17).
  describe "v0.16 end-to-end score battery (T12)" do
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

    def diff_twin(**overrides)
      run_diff(**{ target: fixture("score_twin_head"), base_cache: fixture("score_twin_base"),
                   trust_cache: true }.merge(overrides))
    end

    # row (a): grown-monster PR ⇒ ReusabilityScore :info + envelope deltas + exit 0
    it "row a: grown monster ⇒ RS :info finding, envelope deltas, absorb candidate, exit 0" do
      code, stdout, = diff_twin(format: "json")
      expect(code).to eq(0) # default advisory — :info never gates (L7)
      doc = JSON.parse(stdout)

      rs = doc["findings"].select { |f| f["rule"] == "ReusabilityScore" }
      expect(rs.map { |f| f["symbol"] }).to eq(["Api::V1::Redeem#PATCH[0]"])
      expect(rs.first["severity"]).to eq("info")

      reuse = doc["reusability"]
      expect(reuse["base"]).to include("serializer" => [6], "scored_nodes" => 2, "stale_stamps" => 0)
      expect(reuse["head"]).to include("serializer" => [6], "scored_nodes" => 2, "stale_stamps" => 0)
      # the G-1 monster canon at published precision — the delta reads on raw
      expect(reuse["deltas"]).to eq([
        { "file" => "app/api/redeem.rb", "symbol" => "Api::V1::Redeem#PATCH[0]",
          "classification" => "GROWN",
          "base" => { "score" => -4.23, "score_raw" => -15.0 },
          "head" => { "score" => -4.52, "score_raw" => -18.75 },
          "delta_raw_milli" => -3750 }
      ])
      # L9-A absorb advisory (score ≥ 0 gate; never a finding)
      expect(reuse["absorb_candidates"]).to eq([
        { "file" => "app/api/redeem.rb", "symbol" => "Api::V1::Redeem#collection",
          "score" => 0.0, "absorb" => 5.0, "absorb_raw" => 6.907 }
      ])
    end

    # row (b): lint 13-key leaderboard row with the engine cone headline (D-C1)
    it "row b: lint leaderboard renders the 13-key row with the engine cone headline" do
      thirteen = %w[rank ep kind file branching_log2 mass reach files depth
                    dividend max_cone_node_log2 cost_note reusability_score]
      code, stdout, = run_lint(target: fixture("score_twin_head"),
                               trust_cache: true, format: "json")
      expect(code).to eq(0)
      row = JSON.parse(stdout)["use_cases"]["leaderboard"].fetch(0)
      expect(row.keys.sort).to eq(thirteen.sort)
      expect(row["ep"]).to eq("Api::V1::Redeem#PATCH[0]")
      # negative-first cone dominance: the −4.52 ep beats the 0.0 booth callee
      expect(row["reusability_score"]).to eq(-4.52)
    end

    # row (c): pre-v6 base + v6 head ⇒ one-sided provenance + null deltas
    it "row c: pre-v6 base + v6 head ⇒ one-sided provenance, null delta, no fabrication" do
      code, stdout, = diff_twin(base_cache: fixture("score_twin_v5_base"), format: "json")
      expect(code).to eq(0)
      reuse = JSON.parse(stdout)["reusability"]
      expect(reuse["base"]).to include("serializer" => [5], "scored_nodes" => 0)
      expect(reuse["head"]).to include("serializer" => [6], "scored_nodes" => 2)
      delta = reuse["deltas"].fetch(0)
      expect(delta["symbol"]).to eq("Api::V1::Redeem#PATCH[0]")
      expect(delta["base"]).to be_nil            # base unscored — honest one-sidedness
      expect(delta["head"]).to eq("score" => -4.52, "score_raw" => -18.75)
      expect(delta["delta_raw_milli"]).to be_nil # never fabricated across a v5 side
    end

    # row (g): the D-C5 debt-milli todo lifecycle (pin → skip → worsen →
    # refire) through the SHIPPED diff CLI's --todo transport. The unit-level
    # pin/skip/worsen/refire/heal grammar is exhaustively owned by
    # spec/review/reusability_score_spec.rb ("the D-C5 debt-milli todo
    # lifecycle" group, value_raw <= recorded verbatim); THIS row is its
    # end-to-end CLI companion — the SAME integer skip predicate riding the
    # GROWN monster (head debt milli 18750 = (−(−18.75) × 1000)) across both
    # sides of the pinned boundary. "worsen" is expressed as the current debt
    # exceeding a lower pinned baseline (the engine-published stamp is static —
    # the client never recomputes it, L2/D17), which is exactly the refire arm
    # of the predicate.
    it "row g: debt-milli todo lifecycle through the CLI — pin ⇒ skip, worsen ⇒ refire" do
      node = "app/api/redeem.rb: Api::V1::Redeem#PATCH[0]"
      Dir.mktmpdir do |dir|
        pin = lambda do |value|
          path = File.join(dir, "todo-#{value}.yml")
          File.write(path, <<~YAML)
            version: 1
            tool: "archbuddy 0.13.0"
            rule_count: 1
            node_count: 1
            rules:
              ReusabilityScore:
                - node: "#{node}"
                  value: #{value}
          YAML
          path
        end

        # PIN at the current debt (18750) ⇒ skip (value_raw == recorded); the
        # RS finding is grandfathered away, the skip row is disclosed.
        code, stdout, = diff_twin(todo: pin.call(18_750), format: "json")
        expect(code).to eq(0)
        doc = JSON.parse(stdout)
        expect(doc["findings"].select { |f| f["rule"] == "ReusabilityScore" }).to eq([])
        skip_row = doc["grandfathered"].find { |g| g["rule"] == "ReusabilityScore" }
        expect(skip_row).to include(
          "symbol" => "Api::V1::Redeem#PATCH[0]",
          "recorded" => 18_750, "current" => 18_750, "healed" => false
        )

        # WORSEN past a lower pin (18500) ⇒ re-fire with the :score_debt
        # message; still :info, so it never gates (L7).
        code, stdout, = diff_twin(todo: pin.call(18_500), format: "json")
        expect(code).to eq(0)
        refire = JSON.parse(stdout)["findings"].find { |f| f["rule"] == "ReusabilityScore" }
        expect(refire["symbol"]).to eq("Api::V1::Redeem#PATCH[0]")
        expect(refire["severity"]).to eq("info")
        expect(refire["value_raw"]).to eq(18_750)
        expect(refire["grandfathered"]).to be(true) # grandfathered-baseline re-fire
        expect(refire["message"]).to eq(
          "reusability debt worsened: raw -18.500 → -18.750 (pinned value exceeded)"
        )
      end
    end

    # row (h): Q8 product-copy law over terminal + markdown output
    it "row h: Q8 — no 'reuse more' anywhere in terminal/markdown; break-it-down present" do
      %w[terminal markdown].each do |fmt|
        code, stdout, = diff_twin(format: fmt)
        expect(code).to eq(0)
        expect(stdout.downcase).not_to include("reuse more") # Q8 rule 5 (score < 0)
        expect(stdout).to include("ReusabilityScore")
      end
      # the break-it-down verdict renders on the negative pole (terminal line)
      expect(diff_twin(format: "terminal")[1]).to include("break it down before growing it")
    end

    # row (i): clean-stdout + the exit ladder over every new path
    it "row i: clean stdout on all formats + the exit ladder (advisory 0 / opt-in gate 1)" do
      json_code, json_out, = diff_twin(format: "json")
      expect(json_code).to eq(0)
      expect(json_out[0]).to eq("{")            # stdout purity
      expect { JSON.parse(json_out) }.not_to raise_error

      %w[terminal markdown].each do |fmt|
        expect(diff_twin(format: fmt)[1]).not_to include("{\"") # no JSON on the human stream
      end

      # opt-in gate: severity error + default fail-level error ⇒ exit 1
      Dir.mktmpdir do |dir|
        config = File.join(dir, ".archbuddy.yml")
        File.write(config, <<~YAML)
          version: 1
          rules:
            ReusabilityScore:
              severity: error
        YAML
        code, stdout, = diff_twin(config: config, format: "json")
        expect(code).to eq(1)
        expect(JSON.parse(stdout)["exit_code"]).to eq(1)
      end
    end

    # byte-determinism: same-input reruns are byte-identical (E-12 posture, client side)
    it "byte-determinism: json and terminal reruns are byte-identical" do
      %w[json terminal].each do |fmt|
        expect(diff_twin(format: fmt)[1]).to eq(diff_twin(format: fmt)[1])
      end
    end
  end
end
