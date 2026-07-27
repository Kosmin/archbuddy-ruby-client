# frozen_string_literal: true

require "tmpdir"
require "json"
require "stringio"
require "fileutils"
require_relative "../../script/backtest/report"
require_relative "../../script/backtest/tier2"
require_relative "../../lib/archbuddy"

# v0.15 P3-T8: the report emitter — v0.15 section ORDER (2b between 2 and 3),
# both front-matter caveats, the arc sentence + repo-state caveat, the ep
# worked-example Q5 values, gates table ↔ json equality at 19 keys, honest
# missing-tier rendering, determinism, and the author-scan REJECTED path.
RSpec.describe Backtest::Report do
  def quiet
    orig = $stderr
    $stderr = StringIO.new
    result = yield
    [result, $stderr.string]
  ensure
    $stderr = orig
  end

  def leaderboard_row(rank)
    { "rank" => rank, "ep" => "Api::Ep#{rank}#GET[0]", "kind" => "grape",
      "file" => "app/api/ep#{rank}.rb", "branching_log2" => 20.0 - rank, "mass" => 30,
      "reach" => 2, "files" => 1, "depth" => 2, "dividend" => 64.0,
      "max_cone_node_log2" => 4.0, "cost_note" => nil }
  end

  def write_tiers(dir, arc_dividend: 131_072.0, with_rs_distribution: false)
    File.write(File.join(dir, "tier0.json"), JSON.generate(
                                               "compared" => 433, "matched" => 433,
                                               "gates" => { "t0_rollup_433" => true }
                                             ))
    File.write(File.join(dir, "tier1.json"), JSON.generate(
                                               "flagged" => 21, "edit_prs" => 239, "all_prs" => 433,
                                               "medians" => { "flagged" => 69.8075, "q1" => 21.8639 },
                                               "gates" => { "t1_flagged_21" => true, "t1_flag_set_q4" => true,
                                                            "t1_medians" => true },
                                               "inventory" => [
                                                 { "sha" => "7eca35c6ffff", "eps" => 282,
                                                   "leaderboard_top10" => (1..10).map { |i| leaderboard_row(i) } },
                                                 { "sha" => "0146ad98ffff", "eps" => 326,
                                                   "redeem" => { "dividend" => arc_dividend } }
                                               ]
                                             ))
    tier2 = {
      "pairs" => "base-merge",
      "association" => [{ "rule" => "ExponentialNode", "n_fired" => 2,
                          "median_latency_fired" => 60.0, "median_latency_not_fired" => 20.0 }],
      "method_caveat" => Backtest::Tier2::METHOD_CAVEAT,
      "pr2083" => { "restricted_net" => 3.0, "unrestricted_net" => 14.0 },
      "ep_rows" => {
        "redeem_merge1" => { "branching_log2" => 13.0, "mass" => 73, "reach" => 2,
                             "files" => 1, "depth" => 2, "dividend" => 8192.0 },
        "redeem_merge" => { "branching_log2" => 16.0, "mass" => 83, "reach" => 2,
                            "files" => 1, "depth" => 2, "dividend" => 65_536.0 },
        "rs2083" => { "union" => 1, "sum" => 1 },
        "rs2146" => { "union" => 2, "sum" => 2 },
        "uc2146" => { "GET[0]" => { "branching_log2" => 0.0, "mass" => 7 },
                      "PATCH[0]" => { "branching_log2" => 1.0, "mass" => 22 },
                      "net_log2" => 1.0 }
      },
      "diagnostics" => { "rs2083_file_level" => { "union" => 5, "sum" => 11 },
                         "rs2083_file_level_label" => "file-level variant — inflated by an " \
                                                      "unchanged shared helper (`#collection`, blast 5); diagnostic only, " \
                                                      "not the rule's number" },
      "gates" => {
        "pr2083_net_3000" => true, "pr2083_grown_patch0" => true, "pr2083_new_b1" => true,
        "pr2083_fires_exp_growth" => true, "pr2083_trap_14" => true,
        "uc2083_branching_13_16" => true, "uc2083_dividend_8192_65536" => true,
        "uc2083_mass_73_83" => true, "uc2083_shape_stable" => true,
        "rs2083_union_1_sum_1" => true, "rs2146_union_2_sum_2" => true,
        "uc2146_new_ep_values" => true
      }
    }
    if with_rs_distribution
      tier2["review_surface"] = { "n" => 400, "p50" => 1, "p75" => 2, "p90" => 4,
                                  "p95" => 6, "p99" => 12, "max" => 30 }
    end
    File.write(File.join(dir, "tier2.json"), JSON.generate(tier2))
    File.write(File.join(dir, "tier3.json"), JSON.generate(
                                               "rows" => 7,
                                               "trajectory_markdown" => "| PR | merged_at | Δ | v0 | v-1 |\n|---|---|---|---|---|\n",
                                               "ep_budget" => { "verdict" => "breach", "observed_log2" => 3.0 },
                                               "gates" => { "t3_seven_prs" => true, "pr2083_breach_at_0" => true,
                                                            "pr2083_breach_at_neg1" => true, "t3_ep_budget_breach" => true }
                                             ))
    dir
  end

  STUB_CLI_GATES = lambda do
    { "pr2083_cli_blocked" => true, "pr2146_cli_clean" => true }
  end

  it "renders the v0.15 section order with 2b between 2 and 3, all gates true, exit 0" do
    Dir.mktmpdir do |dir|
      write_tiers(dir)
      code, = quiet { described_class.generate(out: dir, cli_gate_runner: STUB_CLI_GATES) }
      expect(code).to eq(0)

      md = File.read(File.join(dir, "BACKTEST.md"), encoding: "UTF-8")
      order = [
        md.index("IN-SAMPLE DISCLOSURE"),
        md.index("observational, not causal"),
        md.index("## 2. The adoption pitch"),
        md.index("### 2b. The use-case leaderboard of the study era"),
        md.index("## 3. Tier 2"),
        md.index("## 4. Tier 3"),
        md.index("## 5. Worked examples"),
        md.index("## 6. Gates"),
        md.index("## 7. Method + privacy appendix")
      ]
      expect(order).not_to include(nil)
      expect(order).to eq(order.sort)

      # the arc + caveat, byte-asserted
      expect(md).to include(Backtest::Report::ARC_SENTENCE)
      expect(md).to include(Backtest::Report::REPO_STATE_CAVEAT)

      # ep worked-example values == the Q5 canon
      expect(md).to include("| branching_log2 | 13.0 | 16.0 |")
      expect(md).to include("| mass | 73 | 83 |")
      expect(md).to include("| V_now | 2^13 | 2^16 |")
      expect(md).to include("| dividend | ×8192 | ×65536 |")
      expect(md).to include("∪=1/Σ=1")
      expect(md).to include("RS ∪=2")

      # gates table ↔ json equality at the 19 keys
      json = JSON.parse(File.read(File.join(dir, "backtest.json"), encoding: "UTF-8"))
      expect(json["gates"].keys.sort).to eq(Backtest::Report::GATE_KEYS.sort)
      expect(json["gates"].size).to eq(19)
      json["gates"].each do |name, value|
        expect(md).to include("| #{name} | #{value} |")
      end
      expect(json["schema"]).to eq("archbuddy-backtest/1")
      expect(md).not_to include("generated_at") # determinism: no timestamps in the body
    end
  end

  it "renders honest fallbacks: missing tiers → _tier N not run_ + dependent gates false" do
    Dir.mktmpdir do |dir|
      write_tiers(dir)
      File.delete(File.join(dir, "tier2.json"))
      File.delete(File.join(dir, "tier3.json"))
      code, = quiet { described_class.generate(out: dir, cli_gate_runner: STUB_CLI_GATES) }
      expect(code).to eq(1) # dependent gates false, loudly

      md = File.read(File.join(dir, "BACKTEST.md"), encoding: "UTF-8")
      expect(md).to include("_tier 2 not run_")
      expect(md).to include("_tier 3 not run_")
      json = JSON.parse(File.read(File.join(dir, "backtest.json"), encoding: "UTF-8"))
      expect(json["gates"]["pr2083_net_3000"]).to be(false)
      expect(json["gates"]["t3_seven_prs"]).to be(false)
    end
  end

  it "renders the RS distribution only from a merge-parent sweep (honest skip otherwise)" do
    Dir.mktmpdir do |dir|
      write_tiers(dir)
      quiet { described_class.generate(out: dir, cli_gate_runner: STUB_CLI_GATES) }
      md = File.read(File.join(dir, "BACKTEST.md"), encoding: "UTF-8")
      expect(md).to include("_merge-parent sweep not run_")
    end

    Dir.mktmpdir do |dir|
      write_tiers(dir, with_rs_distribution: true)
      quiet { described_class.generate(out: dir, cli_gate_runner: STUB_CLI_GATES) }
      md = File.read(File.join(dir, "BACKTEST.md"), encoding: "UTF-8")
      expect(md).to include("ReviewSurface ∪ distribution (merge-parent sweep, n=400)")
      expect(md).not_to include("_merge-parent sweep not run_ (the ReviewSurface")
    end
  end

  it "exits 2 when the 2^17 arc value is not 131072 in the inventory" do
    Dir.mktmpdir do |dir|
      write_tiers(dir, arc_dividend: 65_536.0)
      code, err = quiet { described_class.generate(out: dir, cli_gate_runner: STUB_CLI_GATES) }
      expect(code).to eq(2)
      expect(err).to include("generation bug")
      expect(File.exist?(File.join(dir, "BACKTEST.md"))).to be(false)
    end
  end

  it "REJECTS a document carrying a seeded author identifier" do
    Dir.mktmpdir do |dir|
      write_tiers(dir)
      # seed a handle through a tier surface that renders verbatim
      tier3 = JSON.parse(File.read(File.join(dir, "tier3.json"), encoding: "UTF-8"))
      tier3["trajectory_markdown"] = "| PR by @seeded-handle |\n"
      File.write(File.join(dir, "tier3.json"), JSON.generate(tier3))

      code, err = quiet { described_class.generate(out: dir, cli_gate_runner: STUB_CLI_GATES) }
      expect(code).to eq(1)
      expect(err).to include("author-scan matched")
      expect(File.exist?(File.join(dir, "BACKTEST.md"))).to be(false)
      expect(File.exist?(File.join(dir, "BACKTEST.md.REJECTED"))).to be(true)
      json = JSON.parse(File.read(File.join(dir, "backtest.json"), encoding: "UTF-8"))
      expect(json["gates"]["author_scan_clean"]).to be(false)
    end
  end

  it "two consecutive generations are byte-identical (BACKTEST.md determinism)" do
    Dir.mktmpdir do |dir|
      write_tiers(dir)
      quiet { described_class.generate(out: dir, cli_gate_runner: STUB_CLI_GATES) }
      first = File.read(File.join(dir, "BACKTEST.md"), encoding: "UTF-8")
      quiet { described_class.generate(out: dir, cli_gate_runner: STUB_CLI_GATES) }
      expect(File.read(File.join(dir, "BACKTEST.md"), encoding: "UTF-8")).to eq(first)
    end
  end
end
