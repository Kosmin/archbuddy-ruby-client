# frozen_string_literal: true

require "json"
require "fileutils"
require_relative "cli"
require_relative "corpus"
require_relative "snapshot_reader"
require_relative "tier0"
require_relative "../../lib/archbuddy/review/calibration"
require_relative "../../lib/archbuddy/review/calibration/lines"

module Backtest
  # Tier 1 — base-side flag rates (STRICT > 2^5, A1) + the v0.15 use-case
  # inventory sub-step (Q5): the FULL per-ep table through the PRODUCT's ep
  # computation (Graph#ep_metrics — the P2-lane fold, never a probe) on the
  # three frozen study snapshots, asserted against the locked canon. Any
  # canon mismatch → exit 2 printing measured-vs-locked (halt-and-
  # investigate; NEVER a tolerance widen).
  module Tier1
    DISCLOSURE =
      "IN-SAMPLE DISCLOSURE: the ExponentialNode threshold (strictly > 2^5) is this " \
      "same corpus's frozen Q4 boundary; Tier 1 restates the study through the tool's " \
      "read/rollup/flag path and is NOT out-of-sample validation. Its non-circular " \
      "content: the cross-implementation reproduction (Tier 0) and the flag RATE — " \
      "the adoption noise cost."

    REDEEM_FILE = "app/api/api/v1/redeem_templates.rb"
    REDEEM_SYMBOL = "Api::V1::RedeemTemplates#PATCH[0]"

    LOG2_TOLERANCE = 0.0005
    MEDIAN_TOLERANCE = 0.001

    # The locked Q5 canon (01-calibration-outputs §Q3 + 01-vty-replica §4;
    # triple-computed R2+R3+R4). Ints exact, log2 ±0.0005, dividend exact.
    CANON = [
      { sha: "68abf8310626a203ff3a1733d0bb96387904067f", ep_count: 254,
        redeem: { branching_log2: 13.000, mass: 73, reach: 2, files: 1, depth: 2,
                  dividend: 8192, v_floor_log2: 0.0 } },
      { sha: "7eca35c6ef3abdfa017246bed440abf2e812d263", ep_count: 282,
        top_dividend: { symbol: REDEEM_SYMBOL, dividend: 65_536 } },
      { sha: "0146ad98bc6d52dc6fb78f4573dd90f698150091", ep_count: 326,
        redeem_dividend: 131_072, unreachable: { nodes: 1439, total: 2366 } }
    ].freeze

    LEADERBOARD_KEYS = %w[
      rank ep kind file branching_log2 mass reach files depth dividend
      max_cone_node_log2 cost_note
    ].freeze

    module_function

    # ---- flag arm ------------------------------------------------------------

    # STRICT > 5.0 (A1) — nil T never flags.
    def flagged_keys(ts)
      ts.select { |_key, t| !t.nil? && t > 5.0 }.keys.sort
    end

    def median(values)
      sorted = values.sort
      return nil if sorted.empty?

      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2.0
    end

    def markdown_block(flagged:, all_count:, edit_count:, flagged_median:, q1_median:)
      edit_rate = (flagged.to_f / edit_count * 100).round(1)
      all_rate = (flagged.to_f / all_count * 100).round(1)
      <<~MARKDOWN
        ### Tier 1 — base-side flag rates (ExponentialNode, strictly > 2^5)

        | metric | value |
        |---|---|
        | flagged (edit arm) | #{flagged}/#{edit_count} edit PRs = #{edit_rate}% |
        | flagged (all) | #{flagged}/#{all_count} all PRs = #{all_rate}% |
        | flagged median latency | #{flagged_median} h |
        | Q1 median latency | #{q1_median} h |

        #{DISCLOSURE}
      MARKDOWN
    end

    # ---- inventory (Q5 canon) -------------------------------------------------

    # @return [[rows, mismatches]] rows for tier1.json; mismatches ⇒ exit 2
    def inventory(corpus, canon: CANON)
      rows = []
      mismatches = []
      canon.each do |spec|
        dir = corpus.snapshot_dir(spec[:sha])
        unless File.exist?(File.join(dir, "archbuddy-findings.json"))
          mismatches << mismatch(spec[:sha], "snapshot", "missing", "present")
          next
        end

        vintage = SnapshotReader.read(dir)
        if vintage.eps.empty?
          rows << { "sha" => spec[:sha],
                    "not_evaluable" => "vintage has no entrypoints" }
          (spec.keys - [:sha]).each do |field|
            mismatches << mismatch(spec[:sha], field.to_s, "not_evaluable (zero entrypoints)",
                                   spec[field].inspect)
          end
          next
        end

        rows << check_snapshot(spec, vintage, mismatches)
      end
      [rows, mismatches]
    end

    def check_snapshot(spec, vintage, mismatches)
      metrics = vintage.graph.ep_metrics
      sha = spec[:sha]

      check(mismatches, sha, "ep_count", metrics.size, spec[:ep_count]) if spec[:ep_count]

      row = {
        "sha" => sha,
        "eps" => metrics.size,
        "unreachable" => unreachable_row(vintage),
        "leaderboard_top10" => leaderboard_top10(metrics)
      }

      redeem = metrics[[REDEEM_FILE, REDEEM_SYMBOL]]
      row["redeem"] = redeem_row(redeem) if redeem

      check_redeem(spec[:redeem], redeem, sha, mismatches) if spec[:redeem]
      check_top_dividend(spec[:top_dividend], metrics, sha, mismatches) if spec[:top_dividend]
      if spec[:redeem_dividend]
        measured = published(redeem&.dividend)
        check(mismatches, sha, "redeem_dividend", measured, spec[:redeem_dividend].to_f)
      end
      check_unreachable(spec[:unreachable], vintage, sha, mismatches) if spec[:unreachable]

      row
    end

    def check_redeem(locked, redeem, sha, mismatches)
      if redeem.nil?
        mismatches << mismatch(sha, "redeem", "absent", locked.inspect)
        return
      end

      check_log2(mismatches, sha, "redeem.branching_log2", redeem.branching_log2,
                 locked[:branching_log2])
      check(mismatches, sha, "redeem.mass", redeem.mass, locked[:mass])
      check(mismatches, sha, "redeem.reach", redeem.reach, locked[:reach])
      check(mismatches, sha, "redeem.files", redeem.files, locked[:files])
      check(mismatches, sha, "redeem.depth", redeem.depth, locked[:depth])
      check(mismatches, sha, "redeem.dividend", published(redeem.dividend),
            locked[:dividend].to_f)
      check_log2(mismatches, sha, "redeem.v_floor_log2", redeem.v_floor_log2,
                 locked[:v_floor_log2])
    end

    def check_top_dividend(locked, metrics, sha, mismatches)
      top = metrics.values.reject { |m| m.dividend.nil? }.max_by(&:dividend)
      top_key = metrics.find { |_k, m| m.equal?(top) }&.first
      measured_symbol = top_key&.last
      check(mismatches, sha, "top_dividend.symbol", measured_symbol, locked[:symbol])
      check(mismatches, sha, "top_dividend.dividend", published(top&.dividend),
            locked[:dividend].to_f)
    end

    def check_unreachable(locked, vintage, sha, mismatches)
      measured = vintage.graph.unreachable_from_entrypoints
      check(mismatches, sha, "unreachable.nodes", measured && measured[:nodes], locked[:nodes])
      expected_share = locked[:nodes].to_f / locked[:total]
      share = measured && measured[:share]
      if share.nil? || (share - expected_share).abs > 1e-9
        mismatches << mismatch(sha, "unreachable.share", share.inspect,
                               format("%.6f (%d/%d)", expected_share, locked[:nodes],
                                      locked[:total]))
      end
    end

    def unreachable_row(vintage)
      measured = vintage.graph.unreachable_from_entrypoints
      return nil if measured.nil?

      { "nodes" => measured[:nodes], "share" => measured[:share].round(4) }
    end

    # The 12-key normative row set (R39/G2), sorted branching_log2 DESC, ep ASC.
    def leaderboard_top10(metrics)
      ranked = metrics.sort_by { |(_f, sym), m| [-m.branching_log2, sym.to_s] }.first(10)
      ranked.each_with_index.map do |((file, sym), m), i|
        {
          "rank" => i + 1, "ep" => sym, "kind" => m.entrypoint_kind, "file" => file,
          "branching_log2" => m.branching_log2.round(3), "mass" => m.mass,
          "reach" => m.reach, "files" => m.files, "depth" => m.depth,
          "dividend" => published(m.dividend),
          "max_cone_node_log2" => m.max_cone_node[:log2].round(3),
          "cost_note" => Archbuddy::Review::Calibration::Lines.cost_note(
            max_cone_node_log2: m.max_cone_node[:log2]
          )
        }
      end
    end

    def redeem_row(m)
      {
        "branching_log2" => m.branching_log2.round(3), "mass" => m.mass,
        "reach" => m.reach, "files" => m.files, "depth" => m.depth,
        "dividend" => published(m.dividend), "dividend_log2" => m.dividend_log2&.round(3),
        "v_floor_log2" => m.v_floor_log2&.round(3)
      }
    end

    # Published rounding (mismatch M2): Math.exp does not round-trip integer
    # dividends bitwise (exp(log(8192)) == 8191.9999999999945, measured); every
    # canon "8192" went through published rounding. round(6) — the graph_vty
    # parity precedent — NEVER a widened tolerance on the canon literals.
    def published(dividend)
      dividend&.round(6)
    end

    def check(mismatches, sha, field, measured, locked)
      mismatches << mismatch(sha, field, measured.inspect, locked.inspect) unless measured == locked
    end

    def check_log2(mismatches, sha, field, measured, locked)
      ok = !measured.nil? && (measured - locked).abs <= LOG2_TOLERANCE
      mismatches << mismatch(sha, field, measured.inspect, locked.inspect) unless ok
    end

    def mismatch(sha, field, measured, locked)
      { "sha" => sha, "field" => field, "measured" => measured, "locked" => locked }
    end

    # ---- runner ---------------------------------------------------------------

    # @return [Integer] 0 gates true / 1 ≥1 gate false / 2 canon mismatch
    def run(corpus:, opts:, canon: CANON)
      # The Tier-1 flag universe is the study's T2 analysis corpus — the
      # h2_pr_table join on in_t2_corpus == "1" (the substrate's "239 edit
      # PRs": the edit-arm rows with usable T/latency; measured 239 of 248
      # edit / 433 all — flagged 21 there, 24 over all 433). An empty join
      # is a corrupt corpus, not a zero-rate report — exit 2 up front.
      h2 = corpus.h2_pr_table.select { |row| row["in_t2_corpus"] == "1" }
      if h2.empty?
        warn "error: corpus edit-arm join (in_t2_corpus rows) is empty — corrupt corpus?"
        return 2
      end

      ts = Tier0.t_by_pr(corpus)
      t2_keys = h2.map { |row| [row["repo"], row["pr_number"]] }
      flagged = flagged_keys(ts.slice(*t2_keys))
      all_count = corpus.pr_predictors.size
      edit_count = h2.size

      q4_set = h2.select { |row| row["t_quartile"] == "4" }
                 .map { |row| [row["repo"], row["pr_number"]] }.sort
      flagged_median = median(h2.select { |row| flagged.include?([row["repo"], row["pr_number"]]) }
                                .map { |row| Float(row["latency_hours"]) })
      q1_median = median(h2.select { |row| row["t_quartile"] == "1" }
                           .map { |row| Float(row["latency_hours"]) })

      inv_rows, inv_mismatches = inventory(corpus, canon: canon)

      gates = {
        "t1_flagged_21" => flagged.size == 21,
        "t1_flag_set_q4" => flagged == q4_set,
        "t1_medians" => medians_ok?(flagged_median, q1_median)
      }

      write_json(opts, flagged: flagged, all_count: all_count, edit_count: edit_count,
                 flagged_median: flagged_median, q1_median: q1_median, gates: gates,
                 inventory: inv_rows, mismatches: inv_mismatches)

      unless inv_mismatches.empty?
        inv_mismatches.each do |m|
          warn "error: tier1 inventory canon mismatch #{m['sha'][0, 8]} #{m['field']}: " \
               "measured #{m['measured']} vs locked #{m['locked']}"
        end
        return 2
      end

      puts "inventory: #{inv_rows.size} snapshots, redeem canon OK"
      edit_rate = (flagged.size.to_f / edit_count * 100).round(1)
      puts "tier1: flagged #{flagged.size}/#{all_count} (#{edit_rate}% of #{edit_count} edit)"
      gates.each do |name, ok|
        warn "error: tier1 gate #{name} false" unless ok
      end
      gates.values.all? ? 0 : 1
    end

    def medians_ok?(flagged_median, q1_median)
      !flagged_median.nil? && !q1_median.nil? &&
        (flagged_median - 69.8075).abs <= MEDIAN_TOLERANCE &&
        (q1_median - 21.8639).abs <= MEDIAN_TOLERANCE
    end

    def write_json(opts, flagged:, all_count:, edit_count:, flagged_median:, q1_median:,
                   gates:, inventory:, mismatches:)
      out_dir = File.expand_path(opts[:out] || CLI::DEFAULT_OUT)
      FileUtils.mkdir_p(out_dir)
      doc = {
        "flagged" => flagged.size,
        "flagged_keys" => flagged.map { |repo, pr| "#{repo}##{pr}" },
        "all_prs" => all_count, "edit_prs" => edit_count,
        "medians" => { "flagged" => flagged_median, "q1" => q1_median },
        "gates" => gates,
        "inventory" => inventory,
        "inventory_mismatches" => mismatches,
        "markdown_block" => markdown_block(flagged: flagged.size, all_count: all_count,
                                           edit_count: edit_count,
                                           flagged_median: flagged_median,
                                           q1_median: q1_median)
      }
      File.write(File.join(out_dir, "tier1.json"), JSON.pretty_generate(doc))
    end
  end

  CLI.register_tier("1", lambda do |corpus:, opts:|
    Tier1.run(corpus: corpus, opts: opts)
  end)
end
