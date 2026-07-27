# frozen_string_literal: true

require "json"
require "set"
require "fileutils"
require "open3"
require "stringio"
require_relative "cli"
require_relative "corpus"
require_relative "snapshot_reader"
require_relative "head_scorer"
require_relative "repos"
require_relative "tier0"
require_relative "tier1"

module Backtest
  # Tier 2 — out-of-sample delta-rule replay ([S] P3-T6) + the v0.15
  # ep-level gate path ([D3]: (merge^1, merge) worktree pairs per Q4).
  #
  # Default pairing `(pr_base, merge)` restricted to PR-touched files (the
  # A5 trap fix); `--pairs merge-parent` isolates each PR exactly (double
  # collect cost) and is the ONLY mode that records per-PR RS/ep rows
  # (cone metrics ripple in multi-commit windows — 87/257 measured).
  module Tier2
    REDEEM_FILE = "app/api/api/v1/redeem_templates.rb"
    REDEEM_EP = "Api::V1::RedeemTemplates#PATCH[0]"
    TEMPLATE_FILE = "app/models/program/redeem/template.rb"

    ARCHIVE_REPO = "thanx/thanx-merchant-api-new"
    SNAP_BASE_2083 = "68abf8310626a203ff3a1733d0bb96387904067f"
    MERGE_2083 = "f61b758c21d14580056812d4d63ab269aa5d7a37"
    MERGE1_2083 = "5f2b8a6f" # merge^1 — identity asserted against rev-parse
    BASE_2146 = "de9630a6"
    MERGE_2146 = "83cc360c2879"

    LOG2_TOL = 0.0005

    METHOD_CAVEAT =
      "Method: (pr_base, merge) pairs restricted to PR-touched files; residual " \
      "confound — another PR merged in the same window touching the SAME file can " \
      "contribute; sensitivity mode `--pairs merge-parent` isolates PRs exactly at " \
      "double collect cost."
    NON_CAUSAL =
      "All outcome associations are observational, not causal: complex code attracts " \
      "harder changes; no randomization was performed."
    EP_ROWS_NOTE =
      "note: ep-level rows require --pairs merge-parent (cone metrics ripple in " \
      "multi-commit windows)"

    module_function

    # ---- vintage restriction (A5 trap fix; harness-side, no new Delta API) ----

    def restrict(vintage, files)
      nodes = vintage.nodes.select { |n| files.include?(n.file) }
      kept = nodes.map(&:symbol).to_set
      edges = (vintage.edges || []).select do |edge|
        from = edge[:from] || edge["from"]
        kept.include?(from)
      end
      Archbuddy::Review::Vintage.new(nodes: nodes, edges: edges,
                                     corrupt_files: vintage.corrupt_files,
                                     meta: vintage.meta, edges_present: vintage.edges?)
    end

    # Touched-file spellings for one PR: scorable_app paths (head names) ∪
    # previous_path (base names for renames), service prefix stripped.
    def touched_files(corpus, repo, pr_number)
      corpus.pr_files.each_with_object(Set.new) do |row, acc|
        next unless row["repo"] == repo && row["pr_number"] == pr_number
        next unless row["file_class"] == "scorable_app"

        [row["path"], row["previous_path"]].each do |raw|
          next if raw.nil? || raw.empty?

          acc << (raw.start_with?(Tier0::SERVICE_PREFIX) ? raw[Tier0::SERVICE_PREFIX.length..] : raw)
        end
      end
    end

    # The frozen study's prs.csv spells the column `merge_latency_hours`
    # (the fixture corpus uses the planned `latency_hours`) — read either,
    # never fabricate (M10).
    def latency_of(pr)
      %w[latency_hours merge_latency_hours].each do |key|
        next unless pr.key?(key)

        value = pr[key]
        return value unless value.nil? || value.empty?
      end
      nil
    end

    def ep_vector(metrics)
      {
        "branching_log2" => metrics.branching_log2.round(3),
        "mass" => metrics.mass, "reach" => metrics.reach,
        "files" => metrics.files, "depth" => metrics.depth,
        "dividend" => Tier1.published(metrics.dividend)
      }
    end

    # ---- the sweep -------------------------------------------------------------

    def sweep(corpus, opts, scorer, config, parent_resolver:)
      rows = []
      skipped = Hash.new { |acc, key| acc[key] = Hash.new(0) }
      evaluated_empty = 0
      merge_parent = opts[:pairs] == "merge-parent"
      warn EP_ROWS_NOTE unless merge_parent

      prs = corpus.prs.sort_by { |row| [row["repo"], row["pr_number"].to_i] }
      prs = prs.first(opts[:sample]) if opts[:sample]

      prs.each do |pr|
        outcome = sweep_pr(corpus, pr, scorer, config,
                           merge_parent: merge_parent, parent_resolver: parent_resolver)
        if outcome.key?(:skipped)
          skipped[outcome[:skipped].to_s][pr["arm"] || "unknown"] += 1
        else
          evaluated_empty += 1 if outcome[:row]["evaluated_empty"]
          rows << outcome[:row]
        end
      end
      [rows, skipped, evaluated_empty]
    end

    def sweep_pr(corpus, pr, scorer, config, merge_parent:, parent_resolver:)
      repo = pr["repo"]
      files = touched_files(corpus, repo, pr["pr_number"])
      return { skipped: :no_touched_files } if files.empty? && !merge_parent

      head_result = scorer.score(repo, pr["merge_commit_sha"])
      return { skipped: head_result.reason } unless head_result.ok?

      head_full = SnapshotReader.read(head_result.dir)

      if merge_parent
        parent = parent_resolver.call(repo, pr["merge_commit_sha"])
        return { skipped: :unresolvable_sha } if parent.nil?

        base_result = scorer.score(repo, parent)
        return { skipped: base_result.reason } unless base_result.ok?

        base_full = SnapshotReader.read(base_result.dir)
        return { skipped: :no_entrypoints } if head_full.eps.empty?

        evaluate_pair(pr, base_full, head_full, config, ep_rows: true)
      else
        base_dir = corpus.snapshot_dir(pr["base_sha"])
        unless File.exist?(File.join(base_dir, "archbuddy-findings.json"))
          return { skipped: :no_base_snapshot }
        end

        base_full = SnapshotReader.read(base_dir)
        base_v = restrict(base_full, files)
        head_v = restrict(head_full, files)
        evaluate_pair(pr, base_v, head_v, config, ep_rows: false)
      end
    end

    def evaluate_pair(pr, base_v, head_v, config, ep_rows:)
      delta = Archbuddy::Review::Delta.new(base: base_v, head: head_v)
      result = quiet { Archbuddy::Review::RuleEngine.evaluate(vintage: head_v, delta: delta, config: config, todo: nil) }

      row = {
        "repo" => pr["repo"], "pr_number" => pr["pr_number"],
        "latency_hours" => latency_of(pr),
        "counts" => delta.counts.transform_keys(&:to_s),
        "net_log2" => delta.net_log2.round(6),
        "fired" => result.findings.map(&:rule).uniq.sort
      }
      # evaluated_empty: both restricted sides empty — recorded, counted
      # separately, NEVER contributes to association medians.
      row["evaluated_empty"] = true if base_v.nodes.empty? && head_v.nodes.empty?
      if ep_rows
        surface = delta.review_surface
        row["rs_union"] = surface[:union]
        row["rs_sum"] = surface[:sum]
        row["eps_metric_changed"] = delta.ep_entries.size
        row["unreachable_touched_nodes"] = surface[:unreachable_touched][:count]
      end
      { row: row }
    end

    # ---- embedded #2083 node gates ([S] A5 values + the +14.0 trap) -----------

    def pr2083_node_gates(corpus, scorer, config)
      pr = corpus.prs.find { |row| row["merge_commit_sha"].to_s.start_with?("f61b758c") }
      return [{}, { "error" => "PR with merge f61b758c not in corpus" }] if pr.nil?

      files = touched_files(corpus, pr["repo"], pr["pr_number"])
      base_full = SnapshotReader.read(corpus.snapshot_dir(pr["base_sha"]))
      head_result = scorer.score(pr["repo"], pr["merge_commit_sha"])
      return [{}, { "error" => "head score failed: #{head_result.reason}" }] unless head_result.ok?

      head_full = SnapshotReader.read(head_result.dir)

      base_v = restrict(base_full, files)
      head_v = restrict(head_full, files)
      delta = Archbuddy::Review::Delta.new(base: base_v, head: head_v)
      result = quiet { Archbuddy::Review::RuleEngine.evaluate(vintage: head_v, delta: delta, config: config, todo: nil) }

      grown = delta.entries.find do |e|
        e.classification == :grown && e.symbol == REDEEM_EP
      end
      new_entries = delta.entries.select { |e| e.classification == :new }
      fired = result.findings.map(&:rule).uniq

      unrestricted = Archbuddy::Review::Delta.new(base: base_full, head: head_full)

      gates = {
        "pr2083_net_3000" => (delta.net_log2 - 3.0).abs <= LOG2_TOL,
        "pr2083_grown_patch0" => !grown.nil? && grown.base_branches == 8192 &&
                                 grown.head_branches == 65_536 &&
                                 (grown.delta_log2 - 3.0).abs <= LOG2_TOL,
        "pr2083_new_b1" => new_entries.size == 1 && new_entries.first.head_branches == 1,
        "pr2083_fires_exp_growth" => (%w[ExponentialNode MultiplicativeGrowth] - fired).empty?,
        "pr2083_trap_14" => (unrestricted.net_log2 - 14.0).abs <= 0.05
      }
      detail = {
        "restricted_net" => delta.net_log2.round(6),
        "unrestricted_net" => unrestricted.net_log2.round(6),
        "fired" => fired.sort
      }
      [gates, detail]
    end

    # ---- the ep-level gate path ([D3]: (merge^1, merge) pairs, Q4/Q5) ---------

    def ep_gate_path(scorer, parent_resolver:)
      gates = {}
      rows = {}
      diagnostics = {}

      # #2083 clean pair — merge^1 resolved live, identity-checked
      merge1 = parent_resolver.call(ARCHIVE_REPO, MERGE_2083)
      unless merge1&.start_with?(MERGE1_2083)
        return [{ "error" => "#{MERGE_2083}^ != #{MERGE1_2083} (resolved: #{merge1.inspect})" }, {}, {}, nil]
      end

      base83 = read_scored(scorer, ARCHIVE_REPO, merge1)
      head83 = read_scored(scorer, ARCHIVE_REPO, MERGE_2083)
      base46 = read_scored(scorer, ARCHIVE_REPO, BASE_2146)
      head46 = read_scored(scorer, ARCHIVE_REPO, MERGE_2146)
      missing = { "2083 base" => base83, "2083 head" => head83,
                  "2146 base" => base46, "2146 head" => head46 }.select { |_k, v| v.nil? }
      unless missing.empty?
        return [{ "error" => "head-scoring failed: #{missing.keys.join(', ')}" }, {}, {}, nil]
      end

      redeem_base = base83.graph.ep_metrics[[REDEEM_FILE, REDEEM_EP]]
      redeem_head = head83.graph.ep_metrics[[REDEEM_FILE, REDEEM_EP]]
      delta83 = Archbuddy::Review::Delta.new(base: base83, head: head83)
      surface83 = delta83.review_surface
      delta46 = Archbuddy::Review::Delta.new(base: base46, head: head46)
      surface46 = delta46.review_surface

      rows["redeem_merge1"] = redeem_base && ep_vector(redeem_base)
      rows["redeem_merge"] = redeem_head && ep_vector(redeem_head)
      rows["rs2083"] = { "union" => surface83[:union], "sum" => surface83[:sum] }
      rows["rs2146"] = { "union" => surface46[:union], "sum" => surface46[:sum] }

      get46, patch46 = %w[GET PATCH].map do |verb|
        key = head46.graph.ep_metrics.keys.find { |(_f, sym)| sym.end_with?("SegmentActivationPreferences##{verb}[0]") }
        key && head46.graph.ep_metrics[key]
      end
      rows["uc2146"] = { "GET[0]" => get46 && ep_vector(get46),
                        "PATCH[0]" => patch46 && ep_vector(patch46),
                        "net_log2" => delta46.net_log2.round(6) }

      gates["uc2083_branching_13_16"] =
        !redeem_base.nil? && !redeem_head.nil? &&
        (redeem_base.branching_log2 - 13.0).abs <= LOG2_TOL &&
        (redeem_head.branching_log2 - 16.0).abs <= LOG2_TOL &&
        ((redeem_head.branching_log2 - redeem_base.branching_log2) - 3.0).abs <= LOG2_TOL
      gates["uc2083_dividend_8192_65536"] =
        Tier1.published(redeem_base&.dividend) == 8192.0 &&
        Tier1.published(redeem_head&.dividend) == 65_536.0
      gates["uc2083_mass_73_83"] = redeem_base&.mass == 73 && redeem_head&.mass == 83
      gates["uc2083_shape_stable"] =
        [redeem_base, redeem_head].all? { |m| m && m.reach == 2 && m.files == 1 && m.depth == 2 }
      gates["rs2083_union_1_sum_1"] = surface83[:union] == 1 && surface83[:sum] == 1
      gates["rs2146_union_2_sum_2"] = surface46[:union] == 2 && surface46[:sum] == 2
      gates["uc2146_new_ep_values"] =
        uc2146_ok?(get46, 0.0, 1.0, 7) && uc2146_ok?(patch46, 1.0, 2.0, 22) &&
        (delta46.net_log2 - 1.0).abs <= LOG2_TOL

      # pairing-consistency assert: merge^1 redeem row == Tier-1 base row
      tier1_row = Tier1::CANON[0][:redeem]
      consistent, message = pairing_consistent?(rows["redeem_merge1"], tier1_row)
      unless consistent
        warn "error: pairing-consistency mismatch (merge^1 vs Tier-1 base): #{message}"
        warn "  merge^1 row: #{rows['redeem_merge1'].inspect}"
        warn "  tier1 row:   #{tier1_row.inspect}"
        return [gates, rows, diagnostics, 2]
      end

      # the labeled file-level diagnostic (Q3 relabel — warning-class only)
      diagnostics["rs2083_file_level"] = file_level_rs(head83, [REDEEM_FILE, TEMPLATE_FILE])
      diagnostics["rs2083_file_level_label"] =
        "file-level variant — inflated by an unchanged shared helper (`#collection`, " \
        "blast 5); diagnostic only, not the rule's number"
      expected = { "union" => 5, "sum" => 11 }
      if diagnostics["rs2083_file_level"] != expected
        warn "warning: rs2083_file_level measured #{diagnostics['rs2083_file_level'].inspect} " \
             "vs expected #{expected.inspect} — diagnostic only, recorded as measured"
      end

      [gates, rows, diagnostics, nil]
    end

    def uc2146_ok?(metrics, branching, dividend, mass)
      !metrics.nil? &&
        (metrics.branching_log2 - branching).abs <= LOG2_TOL &&
        Tier1.published(metrics.dividend) == dividend &&
        metrics.mass == mass &&
        metrics.reach == 1 && metrics.files == 1 && metrics.depth == 1
    end

    # @return [[bool, String]]
    def pairing_consistent?(measured, tier1)
      return [false, "merge^1 redeem row absent"] if measured.nil?

      checks = {
        "branching_log2" => (measured["branching_log2"] - tier1[:branching_log2]).abs <= LOG2_TOL,
        "dividend" => measured["dividend"] == tier1[:dividend].to_f,
        "mass" => measured["mass"] == tier1[:mass],
        "reach" => measured["reach"] == tier1[:reach],
        "files" => measured["files"] == tier1[:files],
        "depth" => measured["depth"] == tier1[:depth]
      }
      bad = checks.reject { |_k, ok| ok }.keys
      [bad.empty?, bad.empty? ? "consistent" : "fields diverge: #{bad.join(', ')}"]
    end

    # File-level RS variant over all nodes in the touched files (head side):
    # union = distinct eps reaching ANY such node; sum = Σ ep-incidences.
    def file_level_rs(vintage, files)
      graph = vintage.graph
      union = Set.new
      sum = 0
      vintage.nodes.select { |n| files.include?(n.file) }.each do |node|
        node_comp = graph.comp_of[node.symbol]
        next if node_comp.nil?

        reaching = graph.ep_metrics.keys.select do |ep_key|
          ep_comp = graph.comp_of[ep_key.last]
          !ep_comp.nil? && graph.reachable_comps(ep_comp).include?(node_comp)
        end
        sum += reaching.size
        reaching.each { |key| union << key }
      end
      { "union" => union.size, "sum" => sum }
    end

    # ---- association table ------------------------------------------------------

    def association(rows)
      Archbuddy::Config::Schema::RULES.keys.sort.map do |rule|
        fired, quiet_rows = rows.partition { |row| row["fired"].include?(rule) }
        {
          "rule" => rule, "n_fired" => fired.size,
          "median_latency_fired" => Tier1.median(latencies(fired)),
          "median_latency_not_fired" => Tier1.median(latencies(quiet_rows))
        }
      end
    end

    def latencies(rows)
      rows.filter_map { |row| row["latency_hours"] && Float(row["latency_hours"]) }
    end

    def rs_distribution(rows)
      unions = rows.filter_map { |row| row["rs_union"] }.sort
      return nil if unions.empty?

      pct = ->(p) { unions[[(unions.size * p).ceil - 1, 0].max] }
      { "n" => unions.size, "p50" => pct.call(0.50), "p75" => pct.call(0.75),
        "p90" => pct.call(0.90), "p95" => pct.call(0.95), "p99" => pct.call(0.99),
        "max" => unions.last }
    end

    # ---- runner -------------------------------------------------------------------

    def read_scored(scorer, repo, sha)
      result = scorer.score(repo, sha)
      result.ok? ? SnapshotReader.read(result.dir) : nil
    end

    def default_parent_resolver
      lambda do |repo_key, sha|
        entry = Repos.from_env[repo_key]
        return nil if entry.nil?

        out, _err, status = Open3.capture3("git", "-C", entry.path, "rev-parse", "#{sha}^")
        status.success? ? out.strip : nil
      end
    end

    def quiet
      orig = $stderr
      $stderr = StringIO.new
      yield
    ensure
      $stderr = orig
    end

    def gate_config
      path = File.expand_path("../../spec/fixtures/backtest/gate_default.yml", __dir__)
      Archbuddy::Config.load(target_root: File.dirname(path), config_path: path)
    end

    def run(corpus:, opts:, scorer: nil, repos: nil, parent_resolver: nil)
      repos ||= Repos.from_env
      if repos.empty?
        warn "note: tier2 skipped: ARCHBUDDY_STUDY_REPOS not set (head scoring unavailable)"
        return 0
      end

      out_dir = File.expand_path(opts[:out] || CLI::DEFAULT_OUT)
      scorer ||= HeadScorer.new(repos: repos, out: out_dir)
      parent_resolver ||= default_parent_resolver
      config = gate_config

      rows, skipped, evaluated_empty = sweep(corpus, opts, scorer, config,
                                             parent_resolver: parent_resolver)
      node_gates, node_detail = pr2083_node_gates(corpus, scorer, config)
      ep_gates, ep_rows, diagnostics, exit2 = ep_gate_path(scorer, parent_resolver: parent_resolver)

      gates = node_gates.merge(ep_gates.reject { |k, _v| k == "error" })
      association_rows = rows.reject { |row| row["evaluated_empty"] }

      doc = {
        "pairs" => opts[:pairs],
        "rows" => rows,
        "skipped" => skipped,
        "evaluated_empty" => evaluated_empty,
        "association" => association(association_rows),
        "method_caveat" => METHOD_CAVEAT,
        "non_causal" => NON_CAUSAL,
        "gates" => gates,
        "pr2083" => node_detail,
        "ep_rows" => ep_rows,
        "diagnostics" => diagnostics
      }
      distribution = opts[:pairs] == "merge-parent" ? rs_distribution(rows) : nil
      doc["review_surface"] = distribution if distribution

      FileUtils.mkdir_p(out_dir)
      File.write(File.join(out_dir, "tier2.json"), JSON.pretty_generate(doc))

      return 2 if exit2
      if ep_gates.key?("error")
        warn "error: tier2 ep gate path failed: #{ep_gates['error']}"
        return 2
      end

      puts "tier2: #{rows.size} PR rows, gates #{gates.count { |_k, v| v }}/#{gates.size} true"
      gates.each { |name, ok| warn "error: tier2 gate #{name} false" unless ok }
      gates.values.all? ? 0 : 1
    end
  end

  CLI.register_tier("2", lambda do |corpus:, opts:|
    Tier2.run(corpus: corpus, opts: opts)
  end)
end
