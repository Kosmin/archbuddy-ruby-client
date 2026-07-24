# frozen_string_literal: true

require "archbuddy/review"

# v0.15 P2-T2 (corpus-gated): engine parity of the client traversal on the
# frozen nexus study snapshot `0146ad98…`. All expectations are HARD-CODED
# literals from the R2/R3 Phase-1 measurements (the spec reads NO engine
# findings file — privacy rails). Skips cleanly when ARCHBUDDY_STUDY_CORPUS
# is unset; the wall budgets are the regression alarm (measured 0.698 s cold
# for the [S] gates, 1.5–2.1 ms for the all-ep pass).
RSpec.describe "Review::Graph engine parity (corpus-gated)" do
  SNAPSHOT_SHA = "0146ad98bc6d52dc6fb78f4573dd90f698150091"

  def median(values)
    sorted = values.sort
    mid = sorted.size / 2
    sorted.size.odd? ? sorted[mid].to_f : (sorted[mid - 1] + sorted[mid]) / 2.0
  end

  it "reproduces the measured traversal + ep-fold surfaces" do
    corpus = ENV["ARCHBUDDY_STUDY_CORPUS"]
    skip "ARCHBUDDY_STUDY_CORPUS not set — corpus parity skipped" if corpus.nil? || corpus.empty?

    snapshot = File.join(corpus, "snapshots", SNAPSHOT_SHA)
    raise "snapshot missing at #{snapshot} — wrong ARCHBUDDY_STUDY_CORPUS?" unless File.directory?(snapshot)

    vintage = Archbuddy::Review::FragmentWalk.read(snapshot)
    graph = vintage.graph

    t0 = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    # ---- [S] carried gates -------------------------------------------------
    expect(graph.union_reach_count).to eq(927)
    expect(graph.max_blast).to eq(15)

    top5 = graph.blast_by_symbol.sort_by { |sym, blast| [-blast, sym] }.first(5)
    expect(top5[0]).to eq(["Rpc::Response.create", 15])
    expect(top5[1..3].map(&:last)).to all(eq(14))
    expect(top5[1..3].map(&:first)).to contain_exactly(
      "OrderingClient#client", "OrderingClient#call", "OrderingClient#build_grpc_options"
    )
    expect(top5[4]).to eq(["Api::V1::Locations#collection", 8])

    depth_by_kind = graph.eps.group_by(&:entrypoint_kind).transform_values do |eps|
      depths = eps.map { |ep| graph.depth(ep.symbol) }
      [depths.size, (depths.sum.to_f / depths.size).round(1), median(depths).round(1)]
    end
    expect(depth_by_kind["grape"]).to eq([314, 2.4, 2.0])
    expect(depth_by_kind["controllers"]).to eq([4, 1.0, 1.0])
    expect(depth_by_kind["jobs"]).to eq([1, 3.0, 3.0])
    expect(depth_by_kind["top_level"]).to eq([7, 1.0, 1.0])

    top_ep, top_subtree = graph.subtree_log2_by_ep.max_by { |_sym, v| v }
    expect(top_ep).to eq("Api::V1::Promotions#PATCH[0]")
    expect(top_subtree).to be_within(0.001).of(55.585)

    base_wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t0
    expect(base_wall).to be <= 5.0

    # ---- v0.15 ep-fold extension gates --------------------------------------
    t1 = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    metrics = graph.ep_metrics
    ep_wall = Process.clock_gettime(Process::CLOCK_MONOTONIC) - t1

    expect(metrics.count).to eq(326)
    expect(graph.unreachable_from_entrypoints[:nodes]).to eq(1439)
    expect(graph.unreachable_from_entrypoints[:share]).to be_within(1e-12).of(1439.0 / 2366)
    expect(graph.unreachable_from_entrypoints[:files]).to eq(265)

    # The all-ep pass adds <= 0.5 s to the [S] budget (measured 1.5–2.1 ms —
    # headroom is the alarm).
    expect(ep_wall).to be <= 0.5
  end
end
