# frozen_string_literal: true

require "stringio"
require "archbuddy/review"

# v0.15 P2-T2: Review::Graph — engine-exact condensation traversal + the
# per-entrypoint fold surface (I-C3').
#
# Depth semantics (V15-F1, BINDING): longest hops-to-sink INCLUDING the
# terminal external hop, floor 1 — sinks seed 0, +1 per hop, MAX combiner
# (engine path_count.rb#forward_depth_dp, published via
# project_scorer.rb#forward_depth_block as [exp(fd).round, 1].max).
RSpec.describe Archbuddy::Review::Graph do
  FIXTURES = File.expand_path("../fixtures/review/vintages", __dir__)

  def node(file:, symbol:, branches: 1, entrypoint: false, entrypoint_kind: nil,
           escapes: false, outcome_arity: 1)
    Archbuddy::Review::Vintage::Node.new(
      file: file, symbol: symbol, kind: "function", klass: nil,
      branches: branches, decisions: 0, entrypoint: entrypoint,
      entrypoint_kind: entrypoint_kind, escapes: escapes,
      outcome_arity: outcome_arity, toll_booth: nil, quadrant: nil,
      leverage: nil, collapse: nil, serializer_version: 5,
      keys_present: %w[branches symbol]
    )
  end

  def edge(from, to, calls = 1)
    { from: from, to: to, calls: calls }
  end

  describe "depth (hops-to-sink, terminal external hop counts, floor 1)" do
    it "computes the diamond a->b->d, a->c->d, d-><ext> per the canon definition" do
      nodes = %w[a b c d].map { |s| node(file: "x.rb", symbol: s, branches: 2) }
      graph = described_class.new(nodes: nodes,
                                  edges: [edge("a", "b"), edge("a", "c"),
                                          edge("b", "d"), edge("c", "d"),
                                          edge("d", "ext.sink")])
      # V15-F1 canon (mirrors the engine forward_depth_dp — sinks seed 0 hops):
      # ext = 0 (floored 1 at publish), d = 1 (the terminal external hop
      # COUNTS), b = c = 2, a = 3.
      expect(graph.depth("a")).to eq(3)
      expect(graph.depth("b")).to eq(2)
      expect(graph.depth("c")).to eq(2)
      expect(graph.depth("d")).to eq(1)
    end

    it "floors a leaf-only node at depth 1" do
      graph = described_class.new(nodes: [node(file: "x.rb", symbol: "leaf")], edges: [])
      expect(graph.depth("leaf")).to eq(1)
    end

    it "gives SCC members one shared level and does not hang on cycles" do
      nodes = %w[m n] .map { |s| node(file: "x.rb", symbol: s, branches: 2) }
      graph = described_class.new(nodes: nodes,
                                  edges: [edge("m", "n"), edge("n", "m")])
      expect(graph.depth("m")).to eq(graph.depth("n"))
    end
  end

  describe "per-ep subtree fold (externals excluded from weights)" do
    it "sums log2 b_own over cone app nodes" do
      nodes = [
        node(file: "x.rb", symbol: "ep", branches: 4, entrypoint: true, entrypoint_kind: "grape"),
        node(file: "x.rb", symbol: "n1", branches: 2)
      ]
      graph = described_class.new(nodes: nodes,
                                  edges: [edge("ep", "n1"), edge("n1", "ext.sink")])
      expect(graph.subtree_log2_by_ep).to eq("ep" => 3.0)
      expect(graph.reach_count_by_ep).to eq("ep" => 2)
      expect(graph.union_reach_count).to eq(2)
    end
  end

  describe "duplicate-symbol vertex space (first-def-wins by (file, symbol))" do
    it "keeps one vertex from the sorted-first file and warns exactly once" do
      nodes = [
        node(file: "b.rb", symbol: "Dup#x", branches: 8),
        node(file: "a.rb", symbol: "Dup#x", branches: 2)
      ]
      stderr = StringIO.new
      orig = $stderr
      $stderr = stderr
      begin
        graph = described_class.new(nodes: nodes, edges: [])
        expect(graph.node_by_symbol["Dup#x"].file).to eq("a.rb")
        expect(graph.node_by_symbol["Dup#x"].branches).to eq(2)
      ensure
        $stderr = orig
      end
      warnings = stderr.string.scan(/^warning: duplicate symbol 'Dup#x' across files — graph uses a\.rb$/)
      expect(warnings.size).to eq(1)
    end
  end

  describe "the v5_small hand-computed ep-fold row" do
    let(:vintage) { Archbuddy::Review::FragmentWalk.read(File.join(FIXTURES, "v5_small")) }
    let(:graph) { vintage.graph }
    let(:row) { graph.ep_metrics[["app/api/widgets.rb", "Api::Widgets#GET[0]"]] }

    it "computes the pinned row: branching_log2 3.0, mass 4, reach 2, depth 2 (V15-F1)" do
      expect(row.branching_log2).to eq(3.0)
      expect(row.mass).to eq(4)
      expect(row.reach).to eq(2)
      expect(row.files).to eq(2)
      expect(row.depth).to eq(2)
      expect(row.own_branches).to eq(4)
      expect(row.cone_size).to eq(2)
      expect(row.entrypoint_kind).to eq("grape")
    end

    it "attributes escapes_in_cone to the planted escapes:true node" do
      expect(row.escapes_in_cone).to eq(
        [{ file: "app/models/widget_helper.rb", symbol: "Api::WidgetHelper#lookup" }]
      )
    end

    it "picks the b=4 ep as max_cone_node" do
      expect(row.max_cone_node).to eq(
        file: "app/api/widgets.rb", symbol: "Api::Widgets#GET[0]", branches: 4, log2: 2.0
      )
      expect(row.top_nodes.map { |n| n[:symbol] })
        .to eq(["Api::Widgets#GET[0]", "Api::WidgetHelper#lookup"])
    end

    it "stages the variety members nil until P2-N1 (the legal N/A shape)" do
      expect(row.vty_log).to be_nil
      expect(row.vty_floor_log).to be_nil
      expect(row.dividend).to be_nil
      expect(row.dividend_log2).to be_nil
      expect(row.top_dividend_nodes).to be_nil
      expect(row.v_now_log2).to be_nil
      expect(row.v_floor_log2).to be_nil
    end

    it "computes a self-only cone honestly (reach 1, mass 0, depth 1)" do
      job = graph.ep_metrics[["app/jobs/sync_job.rb", "SyncJob#perform"]]
      expect(job.reach).to eq(1)
      expect(job.files).to eq(1)
      expect(job.mass).to eq(0)
      expect(job.depth).to eq(1)
      expect(job.branching_log2).to eq(0.0)
    end

    it "reports unreachable_from_entrypoints over the in-tree population" do
      expect(graph.unreachable_from_entrypoints)
        .to eq(nodes: 4, share: 4.0 / 7, files: 0)
    end
  end

  describe "one-computation (Q9): the subtree fold runs EXACTLY once" do
    it "shares the memo between #subtree_log2_by_ep and #ep_metrics" do
      vintage = Archbuddy::Review::FragmentWalk.read(File.join(FIXTURES, "v5_small"))
      graph = vintage.graph
      expect(graph).to receive(:compute_subtree_fold).once.and_call_original

      by_ep = graph.subtree_log2_by_ep
      row = graph.ep_metrics[["app/api/widgets.rb", "Api::Widgets#GET[0]"]]
      expect(row.branching_log2).to eq(by_ep["Api::Widgets#GET[0]"])
    end
  end

  describe "zero-entrypoint degenerate (Q8 — never interprets an empty seed set)" do
    let(:graph) { Archbuddy::Review::FragmentWalk.read(File.join(FIXTURES, "zero_ep")).graph }

    it "returns empty/zero seed-relative folds, never 'everything unreachable'" do
      expect(graph.ep_metrics).to eq({})
      expect(graph.unreachable_from_entrypoints).to be_nil
      expect(graph.subtree_log2_by_ep).to eq({})
      expect(graph.union_reach_count).to eq(0)
      expect(graph.blast_by_symbol.values).to all(eq(0))
      expect(graph.max_blast).to eq(0)
    end
  end

  describe "zero-node degenerate" do
    it "returns empty maps" do
      graph = described_class.new(nodes: [], edges: [])
      expect(graph.depth_by_symbol).to eq({})
      expect(graph.subtree_log2_by_ep).to eq({})
      expect(graph.union_reach_count).to eq(0)
      expect(graph.blast_by_symbol).to eq({})
      expect(graph.ep_metrics).to eq({})
      expect(graph.unreachable_from_entrypoints).to be_nil
    end
  end

  describe "blast (transpose of ep reach over app nodes)" do
    it "counts eps whose reflexive cone contains each app node" do
      nodes = [
        node(file: "x.rb", symbol: "ep1", branches: 2, entrypoint: true),
        node(file: "x.rb", symbol: "ep2", branches: 2, entrypoint: true),
        node(file: "x.rb", symbol: "shared", branches: 2),
        node(file: "x.rb", symbol: "lonely", branches: 2)
      ]
      graph = described_class.new(nodes: nodes,
                                  edges: [edge("ep1", "shared"), edge("ep2", "shared")])
      expect(graph.blast_by_symbol).to eq(
        "ep1" => 1, "ep2" => 1, "shared" => 2, "lonely" => 0
      )
      expect(graph.max_blast).to eq(2)
    end
  end
end
