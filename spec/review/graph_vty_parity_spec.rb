# frozen_string_literal: true

require "stringio"
require "archbuddy/review"

# v0.15 P2-N1 (corpus-gated): BLOCK-EXACT engine parity of the client variety
# fold on the frozen study snapshots. All expectations are HARD-CODED
# literals from R2 §2-§4 (the spec reads NO engine findings file — privacy
# rails + the F2 spy-ban posture hold). Skips cleanly when
# ARCHBUDDY_STUDY_CORPUS is unset. Wall ≤ 5 s (measured 44–75 ms end-to-end —
# headroom is the alarm).
RSpec.describe "Review::Graph variety-fold engine parity (corpus-gated)" do
  SNAP_2083_BASE = "68abf8310626a203ff3a1733d0bb96387904067f"
  SNAP_MONO = "0146ad98bc6d52dc6fb78f4573dd90f698150091"
  REDEEM_EP = "Api::V1::RedeemTemplates#PATCH[0]"

  def median(values)
    sorted = values.sort
    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid].to_f : (sorted[mid - 1] + sorted[mid]) / 2.0
  end

  def read_quietly(dir)
    orig = $stderr
    $stderr = StringIO.new
    Archbuddy::Review::FragmentWalk.read(dir)
  ensure
    $stderr = orig
  end

  it "reproduces the engine variety_mass block EXACTLY at published rounding" do
    corpus = ENV["ARCHBUDDY_STUDY_CORPUS"]
    skip "ARCHBUDDY_STUDY_CORPUS not set — variety parity skipped" if corpus.nil? || corpus.empty?

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    snapshot = File.join(corpus, "snapshots", SNAP_2083_BASE)
    raise "snapshot missing at #{snapshot}" unless File.directory?(snapshot)

    graph = read_quietly(snapshot).graph
    metrics = graph.ep_metrics
    rows = metrics.values

    # ---- block stats (R2 §2 literals; engine DescriptiveStats rounding) ----
    expect(rows.size).to eq(254)
    varieties = rows.map(&:published_variety)
    masses = rows.map(&:mass)
    costs = varieties.zip(masses).map { |v, m| v + m }
    dividends = rows.filter_map(&:dividend)

    variety_mean = varieties.sum / rows.size
    mass_mean = masses.sum.to_f / rows.size
    expect((variety_mean + mass_mean).round(2)).to eq(69.93) # score
    expect(median(costs).round(2)).to eq(17.0)
    expect(variety_mean.round(2)).to eq(41.04)
    expect(median(varieties).round(2)).to eq(2.0)
    expect(mass_mean.round(2)).to eq(28.89)
    expect(median(masses).round(2)).to eq(15.0)
    expect((dividends.sum / dividends.size).round(2)).to eq(40.24)
    expect(median(dividends).round(2)).to eq(2.0)

    capped = rows.count(&:capped?)
    expect(capped.to_f / rows.size).to eq(0.0)
    tainted = metrics.count { |(_f, sym), _row| graph.variety_fallback?(sym) }
    expect(tainted.to_f / rows.size).to eq(0.0)

    # ---- the Q5 per-ep spot gates -------------------------------------------
    redeem = metrics.find { |(_f, sym), _row| sym == REDEEM_EP }&.last
    expect(redeem).not_to be_nil
    expect(redeem.published_variety.round(6)).to eq(8192.0)  # V_now
    expect(Math.exp(redeem.vty_floor_log).round(6)).to eq(1.0) # V_floor
    expect(redeem.dividend.round(6)).to eq(8192.0)
    expect(redeem.branching_log2.round(6)).to eq(13.0)        # Σlog2

    # ---- the "it kept growing" datum (R2 §4) --------------------------------
    mono = File.join(corpus, "snapshots", SNAP_MONO)
    mono_metrics = read_quietly(mono).graph.ep_metrics
    mono_redeem = mono_metrics.find { |(_f, sym), _row| sym == REDEEM_EP }&.last
    expect(mono_redeem.dividend.round(6)).to eq(131_072.0) # 2^17

    wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    expect(wall).to be <= 5.0
  end
end
