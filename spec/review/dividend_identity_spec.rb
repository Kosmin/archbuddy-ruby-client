# frozen_string_literal: true

require "stringio"
require "archbuddy/review"

# v0.15 P2-N1 (§5-C27 — the ONE shared identity gate, glob-driven so
# later-arriving fixtures are covered automatically; the assertions are the
# P1-N2/P2-N1 shared contract):
#
#   ∀ fixture vintage ∀ ep with a computed fold:
#     vty_floor_log ≤ vty_log + 1e-9
#     dividend ≥ 1.0
#     dividend_log2 == (vty_log − vty_floor_log)/ln(2) ± 1e-6
#
# The property caught a REAL closure-capture bug in R2's probe — it is the
# behavioral tripwire for the fold lambdas.
#
# V15-F7 glob floors (BINDING): matched dirs ≥ 6; ≥ 1 vintage with non-nil
# variety members; per-ep nil-skip (v1_small's N/A shape is legal); corrupt/
# tolerated-or-excluded explicitly. An empty or all-nil glob can never
# vacuously pass.
RSpec.describe "dividend identity property (Q1)" do
  FIXTURES = File.expand_path("../fixtures/review/vintages", __dir__)

  def read_quietly(dir)
    orig = $stderr
    $stderr = StringIO.new
    Archbuddy::Review::FragmentWalk.read(dir)
  ensure
    $stderr = orig
  end

  it "holds for every ep of every fixture vintage" do
    dirs = Dir[File.join(FIXTURES, "*")].select { |d| File.directory?(d) }.sort
    expect(dirs.size).to be >= 6 # V15-F7 floor — the glob can never go vacuous

    vintages_with_variety = 0
    eps_checked = 0

    dirs.each do |dir|
      vintage = read_quietly(dir)
      # corrupt/ is TOLERATED explicitly: it reads with loud whole-file
      # exclusions and still yields a legal vintage.
      expect(vintage.corrupt_files).not_to be_empty if File.basename(dir) == "corrupt"

      metrics = vintage.graph.ep_metrics
      non_nil = metrics.values.count { |row| !row.vty_log.nil? }
      vintages_with_variety += 1 if non_nil.positive?

      metrics.each do |(file, ep_symbol), row|
        next if row.vty_log.nil? # the legal N/A shape (v1_small etc.)

        eps_checked += 1
        expect(row.vty_floor_log).to be <= row.vty_log + 1e-9,
                                     "floor > vty at #{dir} #{file} #{ep_symbol}"
        # Published precision (M14, disclosed): raw exp() may land 1 ulp
        # below 1.0 when the gap carries −1e-16-scale fold noise; the
        # identity holds at the round(6) the gate and components publish.
        expect(row.dividend.round(6)).to be >= 1.0,
                                         "dividend < 1 at #{dir} #{file} #{ep_symbol}"
        expect(row.dividend_log2).to be_within(1e-6)
          .of((row.vty_log - row.vty_floor_log) / Math.log(2)),
                                     "dividend_log2 drifted at #{dir} #{file} #{ep_symbol}"
      end
    end

    expect(vintages_with_variety).to be >= 1 # V15-F7: never all-nil-vacuous
    expect(eps_checked).to be >= 1
  end
end
