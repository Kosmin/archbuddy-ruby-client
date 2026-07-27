# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "cli"
require_relative "corpus"
require_relative "snapshot_reader"
require_relative "head_scorer"
require_relative "repos"
require_relative "tier2"

module Backtest
  # Tier 3 — the forced-decrease ratchet counterfactual on the redeem file
  # (7 corpus PRs), replayed through the REAL ComplexityRatchet rule, plus
  # the v0.15 entrypoints-budget variant row (Q5/[S:F7]/[S:F12] — the
  # `[0]`-bearing symbol through exact-string-first matching).
  module Tier3
    SCOPE_FILE = Tier2::REDEEM_FILE

    module_function

    def fixture_config(name)
      path = File.expand_path("../../spec/fixtures/backtest/#{name}", __dir__)
      Archbuddy::Config.load(target_root: File.dirname(path), config_path: path)
    end

    # PRs whose pr_files include the scope file, ordered by merged_at.
    def scope_prs(corpus)
      keys = corpus.pr_files.select { |row| row["path"] == SCOPE_FILE }
                   .map { |row| [row["repo"], row["pr_number"]] }.to_set
      corpus.prs.select { |pr| keys.include?([pr["repo"], pr["pr_number"]]) }
            .sort_by { |pr| pr["merged_at"].to_s }
    end

    # Verdict extracted from the REAL rule's ratchet entries (never harness math).
    def ratchet_verdict(base_v, head_v, config)
      delta = Archbuddy::Review::Delta.new(base: base_v, head: head_v)
      result = Tier2.quiet do
        Archbuddy::Review::RuleEngine.evaluate(vintage: head_v, delta: delta,
                                               config: config, todo: nil)
      end
      entry = result.ratchet.first
      entry && { "verdict" => entry.verdict.to_s,
                 "observed_log2" => entry.observed_log2&.round(6) }
    end

    def run(corpus:, opts:, scorer: nil, repos: nil, parent_resolver: nil)
      repos ||= Repos.from_env
      if repos.empty?
        warn "note: tier3 skipped: ARCHBUDDY_STUDY_REPOS not set (head scoring unavailable)"
        return 0
      end

      out_dir = File.expand_path(opts[:out] || CLI::DEFAULT_OUT)
      scorer ||= HeadScorer.new(repos: repos, out: out_dir)
      parent_resolver ||= Tier2.default_parent_resolver

      config0 = fixture_config("gate_ratchet_0.yml")
      config_neg1 = fixture_config("gate_ratchet_neg1.yml")

      prs = scope_prs(corpus)
      if prs.empty?
        warn "error: 0 PRs touch this scope (#{SCOPE_FILE}) — t3_seven_prs fails"
        write_json(out_dir, rows: [], gates: { "t3_seven_prs" => false })
        return 1
      end

      rows = []
      prs.each do |pr|
        base_dir = corpus.snapshot_dir(pr["base_sha"])
        next unless File.exist?(File.join(base_dir, "archbuddy-findings.json"))

        head_result = scorer.score(pr["repo"], pr["merge_commit_sha"])
        next unless head_result.ok?

        base_v = SnapshotReader.read(base_dir)
        head_v = SnapshotReader.read(head_result.dir)
        at0 = ratchet_verdict(base_v, head_v, config0)
        at_neg1 = ratchet_verdict(base_v, head_v, config_neg1)
        rows << {
          "pr" => "#{pr['repo']}##{pr['pr_number']}",
          "merged_at" => pr["merged_at"],
          "merge_sha" => pr["merge_commit_sha"][0, 8],
          "delta_log2" => at0 && at0["observed_log2"],
          "verdict_at_0" => at0 && at0["verdict"],
          "verdict_at_neg1" => at_neg1 && at_neg1["verdict"]
        }
      end

      pr2083 = rows.find { |row| row["merge_sha"].start_with?("f61b758c") }

      # the entrypoints-budget variant on the CLEAN (merge^1, merge) pair
      ep_row = ep_budget_row(scorer, parent_resolver)

      gates = {
        "t3_seven_prs" => rows.size == 7,
        "pr2083_breach_at_0" => !pr2083.nil? && pr2083["verdict_at_0"] == "breach" &&
                                !pr2083["delta_log2"].nil? &&
                                (pr2083["delta_log2"] - 3.0).abs <= Tier2::LOG2_TOL,
        "pr2083_breach_at_neg1" => !pr2083.nil? && pr2083["verdict_at_neg1"] == "breach",
        "t3_ep_budget_breach" => !ep_row.nil? && ep_row["verdict"] == "breach" &&
                                 (ep_row["observed_log2"].to_f - 3.0).abs <= Tier2::LOG2_TOL
      }

      write_json(out_dir, rows: rows, gates: gates, ep_budget: ep_row)

      puts "tier3: #{rows.size} scope PRs, gates #{gates.count { |_k, v| v }}/#{gates.size} true"
      gates.each { |name, ok| warn "error: tier3 gate #{name} false" unless ok }
      gates.values.all? ? 0 : 1
    end

    def ep_budget_row(scorer, parent_resolver)
      merge1 = parent_resolver.call(Tier2::ARCHIVE_REPO, Tier2::MERGE_2083)
      return nil if merge1.nil?

      base_v = Tier2.read_scored(scorer, Tier2::ARCHIVE_REPO, merge1)
      head_v = Tier2.read_scored(scorer, Tier2::ARCHIVE_REPO, Tier2::MERGE_2083)
      return nil if base_v.nil? || head_v.nil?

      ratchet_verdict(base_v, head_v, fixture_config("gate_ratchet_ep0.yml"))
    end

    def write_json(out_dir, rows:, gates:, ep_budget: nil)
      FileUtils.mkdir_p(out_dir)
      table = +"| PR | merged_at | Δ scope Σlog2 | verdict@0 | verdict@−1 |\n"
      table << "|---|---|---|---|---|\n"
      rows.each do |row|
        table << "| #{row['pr']} | #{row['merged_at']} | #{row['delta_log2']} " \
                 "| #{row['verdict_at_0']} | #{row['verdict_at_neg1']} |\n"
      end
      doc = { "rows" => rows.size, "trajectory" => rows, "gates" => gates,
              "trajectory_markdown" => table }
      doc["ep_budget"] = ep_budget if ep_budget
      File.write(File.join(out_dir, "tier3.json"), JSON.pretty_generate(doc))
    end
  end

  CLI.register_tier("3", lambda do |corpus:, opts:|
    Tier3.run(corpus: corpus, opts: opts)
  end)
end
