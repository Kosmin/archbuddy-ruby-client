# frozen_string_literal: true

require "spec_helper"
require "support/golden_corpus"
require "json"
require "tmpdir"
require "fileutils"

# THE EMISSION BATTERY — AND THE REASON IT IS NOT ALL BOTH-POSTURES.
#
# `collector_spec.rb` writes every graph-emission expectation so it holds under
# BOTH engine postures, for a stated reason: the engine wave can land before,
# after or during this one and the suite stays green. That discipline is kept
# here (see "both postures, real pipeline" below) — but it is not sufficient on
# its own.
#
# Against a graph-1.6 engine the emission gate is CLOSED, so a purely
# posture-tolerant battery would exercise the `usage` branch ZERO times and
# still be green. The whole emission path could ship untested. So this file
# also drives the gate DIRECTLY — stubbing `graph_schema_accepts_usage?` true
# and false — and asserts the exact emitted hash in each case. Those examples
# are NOT vacuous under any engine.
#
# The four gate x population cells are all covered:
#
#                        | edge HAS classified sites | edge has ZERO
#   ---------------------+---------------------------+-------------------------
#   gate OPEN  (1.7)     | emit the histogram        | omit the key (never {})
#   gate CLOSED (1.6)    | omit; bytes unchanged     | omit; bytes unchanged
RSpec.describe "graph.yml usage emission (C10/C11)" do
  USAGE_ANONYMIZER = Archbuddy::Collect::Anonymizer
  USAGE_VALIDATOR  = ArchitectureAuditor::Contract::Validator
  USAGE_GOLDEN = Archbuddy::GoldenCorpus

  USAGE_LEGACY_EDGE_KEYS = %w[from to calls count self_time_ms].freeze

  USAGE_ANCHOR_SRC = <<~RUBY
    class Thing
      def helper
        1
      end

      def flag?
        true
      end

      def go
        helper
        x = helper
        helper if flag?
        x
      end

      def dual
        x = helper if helper
        x
      end
    end
  RUBY

  def in_repo(source)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "thing.rb"), source)
      yield dir
    end
  end

  def anonymize(dir)
    USAGE_ANONYMIZER.new(
      Archbuddy::Collect::Registry.for("ruby")
                                  .new(dir, Archbuddy::Collect::Config.new(language: "ruby"))
                                  .collect,
      tool: "archbuddy test", adapter: "ruby"
    ).call
  end

  def id_for(result, symbol)
    result.id_map["ids"].find { |_id, d| d["symbol"] == symbol }&.first
  end

  def graph_edge(result, from_sym, to_sym)
    from = id_for(result, from_sym)
    to   = id_for(result, to_sym)
    result.graph["edges"].find { |e| e["from"] == from && e["to"] == to }
  end

  # An AdapterResult carrying exactly the edges handed in — used for the
  # direct, gate-stubbed emission tests.
  def anonymize_edges(edges, nodes)
    USAGE_ANONYMIZER.new(
      Archbuddy::Collect::AdapterResult.new(nodes: nodes, edges: edges, entrypoints: [],
                                            diagnostics: {}),
      tool: "archbuddy test", adapter: "ruby"
    ).call
  end

  def raw_node(symbol)
    Archbuddy::Collect::Raw::RawNode.new(rel_file: "a.rb", symbol: symbol, line: 1, kind: "function")
  end

  # --- 1. both postures, through the REAL pipeline -------------------------

  describe "the real pipeline, valid under either engine posture" do
    it "emits the anchor's three histograms, or none of them" do
      in_repo(USAGE_ANCHOR_SRC) do |dir|
        result = anonymize(dir)
        go_helper  = graph_edge(result, "Thing#go", "Thing#helper")
        go_flag    = graph_edge(result, "Thing#go", "Thing#flag?")
        dual_helper = graph_edge(result, "Thing#dual", "Thing#helper")

        if USAGE_ANONYMIZER.graph_schema_accepts_usage?
          expect(go_helper["usage"]).to eq({ "effect" => 2, "value" => 1 })
          expect(go_flag["usage"]).to eq({ "predicate" => 1 })
          expect(dual_helper["usage"]).to eq({ "predicate" => 1, "value" => 1 })
        else
          expect(go_helper.keys).to match_array(USAGE_LEGACY_EDGE_KEYS)
          expect(go_flag.keys).to match_array(USAGE_LEGACY_EDGE_KEYS)
          expect(dual_helper.keys).to match_array(USAGE_LEGACY_EDGE_KEYS)
        end
      end
    end

    it "still validates against the installed engine schema" do
      in_repo(USAGE_ANCHOR_SRC) do |dir|
        result = anonymize(dir)
        expect { USAGE_VALIDATOR.validate!(:graph, result.graph) }.not_to raise_error
      end
    end

    it "never emits usage: {} on any golden corpus edge" do
      USAGE_GOLDEN.corpora.each do |name, spec|
        USAGE_GOLDEN.with_root(spec) do |root|
          adapter = Archbuddy::Collect::Registry.for("ruby").new(root, USAGE_GOLDEN.config_for(spec))
          graph   = USAGE_ANONYMIZER.new(adapter.collect, tool: "archbuddy test", adapter: "ruby").call.graph
          graph["edges"].each do |edge|
            expect(edge["usage"].nil? || !edge["usage"].empty?).to be(true), name
          end
        end
      end
    end
  end

  # --- 2/3/4. the gate driven DIRECTLY (never vacuous) ---------------------

  describe "gate OPEN, driven directly" do
    before { allow(USAGE_ANONYMIZER).to receive(:graph_schema_accepts_usage?).and_return(true) }

    it "emits EXACTLY the legacy keys plus a String-keyed histogram" do
      # The exact-hash assertion rules out three real bugs at once: Symbol keys
      # surviving a missing transform_keys (which a Ruby-hash comparison would
      # not catch but a YAML dump would), a zero-filled class appearing, and
      # `usage` emitted as {}.
      nodes = [raw_node("Thing#go"), raw_node("Thing#helper")]
      edge  = Archbuddy::Collect::Raw::RawEdge.new(
        from_key: nodes[0].real_key, to_key: nodes[1].real_key, calls: 3,
        usage: { value: 2, predicate: 1 }
      )
      result = anonymize_edges([edge], nodes)

      expect(result.graph["edges"].first).to eq(
        "from"         => id_for(result, "Thing#go"),
        "to"           => id_for(result, "Thing#helper"),
        "calls"        => 3,
        "count"        => nil,
        "self_time_ms" => nil,
        "usage"        => { "value" => 2, "predicate" => 1 }
      )
    end

    it "omits the key entirely for an edge with NO classified site — never {}" do
      nodes = [raw_node("Thing#go"), raw_node("Thing#helper")]
      unstamped = Archbuddy::Collect::Raw::RawEdge.new(
        from_key: nodes[0].real_key, to_key: nodes[1].real_key, calls: 1
      )
      result = anonymize_edges([unstamped], nodes)
      expect(result.graph["edges"].first.keys).to match_array(USAGE_LEGACY_EDGE_KEYS)
    end

    it "omits the key for a SYNTHESIZED edge (no AST call site behind it)" do
      # organizer_edges / generated_edges mint RawEdge(calls: 1) from a DSL or
      # metaprogramming declaration. There is no position to read, so there is
      # no usage — absent, never fabricated.
      nodes = [raw_node("Org#call"), raw_node("Step#run")]
      synthesized = Archbuddy::Collect::Raw::RawEdge.new(
        from_key: nodes[0].real_key, to_key: nodes[1].real_key, calls: 1
      )
      result = anonymize_edges([synthesized], nodes)
      expect(result.graph["edges"].first).not_to have_key("usage")
    end
  end

  describe "gate CLOSED, driven directly" do
    before { allow(USAGE_ANONYMIZER).to receive(:graph_schema_accepts_usage?).and_return(false) }

    it "emits exactly the pre-change five-key edge even WITH classified sites" do
      nodes = [raw_node("Thing#go"), raw_node("Thing#helper")]
      edge  = Archbuddy::Collect::Raw::RawEdge.new(
        from_key: nodes[0].real_key, to_key: nodes[1].real_key, calls: 3,
        usage: { value: 2, predicate: 1 }
      )
      result = anonymize_edges([edge], nodes)

      expect(result.graph["edges"].first).to eq(
        "from"         => id_for(result, "Thing#go"),
        "to"           => id_for(result, "Thing#helper"),
        "calls"        => 3,
        "count"        => nil,
        "self_time_ms" => nil
      )
    end
  end

  # --- C11: gate + vocabulary locks ---------------------------------------
  #
  # Item 2 below is an IMPROVEMENT on the four existing probes, which have no
  # equivalent. Without it the gate could sit permanently false for a reason
  # that has nothing to do with `usage` — a typo'd id, a missing required key —
  # and the field would silently never ship while every other example stayed
  # green.
  describe "C11 — the gate's own locks" do
    it "1. agrees with the installed validator (the family's standard lock)" do
      expect(USAGE_ANONYMIZER.graph_schema_accepts_usage?).to eq(
        USAGE_VALIDATOR.valid?(:graph, USAGE_ANONYMIZER::USAGE_PROBE_GRAPH)
      )
    end

    it "2. validates with the `usage` key REMOVED, under either posture" do
      baseline = Marshal.load(Marshal.dump(USAGE_ANONYMIZER::USAGE_PROBE_GRAPH))
      baseline["edges"][0].delete("usage")
      expect(USAGE_VALIDATOR.valid?(:graph, baseline)).to be(true)
    end

    it "3. locks the emitted vocabulary against the installed schema (both branches real)" do
      classes = Archbuddy::Collect::Adapters::Ruby::UsageWalker::CLASSES.map(&:to_s).sort
      schema  = JSON.parse(File.read(USAGE_VALIDATOR.schema_path(:graph)))
      declared = schema.dig("definitions", "edge", "properties")

      if declared&.key?("usage")
        # Engine declares the field: its key set must be EXACTLY ours. An empty
        # `properties` fails here rather than passing vacuously.
        expect(declared["usage"]["properties"].keys.sort).to eq(classes)
        expect(USAGE_ANONYMIZER.graph_schema_accepts_usage?).to be(true)
      else
        expect(USAGE_ANONYMIZER.graph_schema_accepts_usage?).to be(false)
      end
    end
  end
end
