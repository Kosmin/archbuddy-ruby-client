# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "cli"
require_relative "corpus"
require_relative "../../lib/archbuddy" # engine gem + full client (standalone script path)
require_relative "snapshot_reader"

module Backtest
  # Tier 0 — the cross-implementation rollup: recompute per-PR
  # `T = max log2(branches) over PR-touched scored files` from the frozen
  # base fragments THROUGH THE PRODUCT READ PATH (SnapshotReader → Vintage),
  # and assert equality with the study's `pr_predictors.csv` (|Δ| ≤ 0.005 —
  # 2dp CSV printing; nil ↔ empty cell must match EXACTLY, a fabricated 0.0
  # fails by construction).
  module Tier0
    TOLERANCE = 0.005

    # The study's exact lookup dispatch (13_build_pr_predictors.py, M11 pin):
    # scorable_app rows ONLY; added/copied files NEVER look up at base;
    # renamed rows look up previous_path; mono paths lose the service prefix.
    SERVICE_PREFIX = "services/merchant-api/"
    ADDED_LIKE = %w[added copied].freeze

    module_function

    # @return [String, nil] the base-side lookup path for one pr_files row
    def lookup_path(row)
      return nil unless row["file_class"] == "scorable_app"
      return nil if ADDED_LIKE.include?(row["change_type"])

      raw = row["change_type"] == "renamed" ? row["previous_path"] : row["path"]
      return nil if raw.nil? || raw.empty?

      raw.start_with?(SERVICE_PREFIX) ? raw[SERVICE_PREFIX.length..] : raw
    end

    # @return [Hash{[repo, pr_number] => Float|nil}]
    def t_by_pr(corpus)
      files_by_pr = corpus.pr_files.each_with_object({}) do |row, acc|
        path = lookup_path(row)
        (acc[[row["repo"], row["pr_number"]]] ||= []) << path if path
      end

      out = {}
      corpus.pr_predictors.group_by { |row| row["base_sha"] }.each do |sha, prs|
        vintage = SnapshotReader.read(corpus.snapshot_dir(sha))
        by_file = vintage.nodes.group_by(&:file)
        prs.each do |pr|
          key = [pr["repo"], pr["pr_number"]]
          logs = (files_by_pr[key] || []).flat_map { |file| by_file.fetch(file, []) }
                                         .select { |n| n.branches.is_a?(Integer) && n.branches >= 1 }
                                         .map { |n| Math.log2(n.branches) }
          out[key] = logs.max
        end
      end
      out
    end

    def match?(ours, csv)
      blank = csv.nil? || csv.to_s.strip.empty?
      return blank if ours.nil?
      return false if blank

      (ours - Float(csv)).abs <= TOLERANCE
    end

    # @return [Integer] exit code (0 gate true / 1 mismatches)
    def run(corpus:, opts:)
      ts = t_by_pr(corpus)
      mismatches = []
      compared = 0
      corpus.pr_predictors.each do |pr|
        key = [pr["repo"], pr["pr_number"]]
        compared += 1
        next if match?(ts[key], pr["pr_max_log2_b_own"])

        mismatches << { "repo" => key[0], "pr_number" => key[1],
                        "ours" => ts[key], "csv" => pr["pr_max_log2_b_own"] }
      end

      matched = compared - mismatches.size
      out_dir = File.expand_path(opts[:out] || CLI::DEFAULT_OUT)
      FileUtils.mkdir_p(out_dir)
      doc = {
        "compared" => compared, "matched" => matched, "mismatches" => mismatches,
        "gates" => { "t0_rollup_433" => mismatches.empty? && compared.positive? }
      }
      File.write(File.join(out_dir, "tier0.json"), JSON.pretty_generate(doc))

      mismatches.each do |m|
        warn "error: tier0 mismatch #{m['repo']}##{m['pr_number']}: " \
             "ours=#{m['ours'].inspect} csv=#{m['csv'].inspect}"
      end
      puts "tier0: #{matched}/#{compared} matched"
      mismatches.empty? ? 0 : 1
    end
  end

  CLI.register_tier("0", lambda do |corpus:, opts:|
    Tier0.run(corpus: corpus, opts: opts)
  end)
end
