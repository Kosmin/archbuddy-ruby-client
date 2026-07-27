# frozen_string_literal: true

require_relative "whitelist_reader"

module Backtest
  # The corpus access layer every tier uses: required-file validation, the
  # per-file column allowlists (A6 — the ONE place they live), and readers.
  # The corpus is READ-ONLY; nothing here ever writes into it.
  class Corpus
    class CorpusError < StandardError; end

    # Per-file allowlists (A6 whitelist + the one P3 extension: `merged_at`
    # for Tier-3 chronology — a timestamp is not author data).
    # `merge_latency_hours` (M10): the FROZEN study prs.csv spells the
    # latency column that way; same metric class as latency_hours.
    ALLOWLISTS = {
      "prs.csv" => %w[repo pr_number latency_hours merge_latency_hours churn arm
                      is_bugfix base_sha merge_commit_sha size_stratum merged_at].freeze,
      "h2_pr_table.csv" => %w[repo pr_number t_quartile t_max_log2_b_own latency_hours
                              churn in_t2_corpus].freeze,
      "pr_predictors.csv" => %w[repo pr_number base_sha pr_max_log2_b_own arm].freeze,
      "pr_files.csv" => %w[repo pr_number path file_class change_type previous_path].freeze
    }.freeze

    REQUIRED = (ALLOWLISTS.keys.map { |f| File.join("data", "derived", f) } + ["snapshots"]).freeze

    def initialize(root)
      @root = File.expand_path(root)
    end

    attr_reader :root

    # @raise [CorpusError] when the corpus is missing required files or empty
    def validate!
      missing = REQUIRED.reject { |rel| File.exist?(File.join(@root, rel)) }
      unless missing.empty?
        raise CorpusError, "corpus at #{@root} is missing: #{missing.join(', ')}"
      end

      raise CorpusError, "corpus has 0 PRs — wrong ARCHBUDDY_STUDY_CORPUS?" if prs.empty?

      true
    end

    def prs
      @prs ||= reader("prs.csv").rows
    end

    def pr_files
      @pr_files ||= reader("pr_files.csv").rows
    end

    def pr_predictors
      @pr_predictors ||= reader("pr_predictors.csv").rows
    end

    def h2_pr_table
      @h2_pr_table ||= reader("h2_pr_table.csv").rows
    end

    def snapshot_dir(sha)
      File.join(@root, "snapshots", sha)
    end

    def reader(csv_name)
      WhitelistReader.new(
        File.join(@root, "data", "derived", csv_name),
        allow: ALLOWLISTS.fetch(csv_name)
      )
    end
  end
end
