# frozen_string_literal: true

require "spec_helper"
require "support/golden_corpus"
require "tmpdir"
require "fileutils"

# THE PER-EDGE HISTOGRAM — ADAPTER-RESULT LEVEL, SO THE ENGINE CANNOT MAKE IT
# VACUOUS.
#
# Everything here reads `AdapterResult#edges` directly, BEFORE the Anonymizer's
# schema-acceptance gate is consulted. That matters: the gate is CLOSED against
# a graph-1.6 engine, so an emission-level test of the same invariants would
# silently assert nothing. These run under either engine posture.
#
# Three hard rules, all gated rather than argued:
#
#   R2  every count is an Integer >= 1; a class with zero observed sites is
#       OMITTED (sparse).
#   R3  `usage` is NEVER {} — an edge with nothing classified carries nil.
#   R4  THE SUM INVARIANT: for every edge that CARRIES a histogram,
#       usage.values.sum == edge.calls. This holds because classification is
#       total over the sites the pre-scan reaches, and it is why `unknown` has
#       to be an explicit key — omitting it would break the sum and make "how
#       many sites went unclassified" unrecoverable.
#
# R4 is stated over edges that CARRY usage, never over every edge, because
# SYNTHESIZED edges (organizer / generated) are minted from a DSL declaration
# with no AST call site behind them. There is no position to read, so there is
# no usage — absent, never fabricated.
RSpec.describe "per-edge usage histogram (C4)" do
  USAGE_HIST_GOLDEN = Archbuddy::GoldenCorpus

  # Every golden corpus, at the AdapterResult level.
  def each_corpus_result
    USAGE_HIST_GOLDEN.corpora.each do |name, spec|
      USAGE_HIST_GOLDEN.with_root(spec) do |root|
        adapter = Archbuddy::Collect::Registry.for("ruby").new(root, USAGE_HIST_GOLDEN.config_for(spec))
        yield name, adapter.collect
      end
    end
  end

  def in_repo(source)
    Dir.mktmpdir do |dir|
      File.write(File.join(dir, "thing.rb"), source)
      yield dir
    end
  end

  def collect(dir)
    Archbuddy::Collect::Registry.for("ruby")
                                .new(dir, Archbuddy::Collect::Config.new(language: "ruby"))
                                .collect
  end

  # The hand-computed anchor. Every expectation below was derived by reading
  # the rule table, not by running the code and writing down what came out.
  USAGE_HIST_ANCHOR = <<~RUBY
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

  def edge_usage(result, from_sym, to_sym)
    from = result.nodes.find { |n| n.symbol == from_sym }
    to   = result.nodes.find { |n| n.symbol == to_sym }
    return nil if from.nil? || to.nil?

    result.edges.find { |e| e.from_key == from.real_key && e.to_key == to.real_key }
  end

  describe "the hand-computed anchor" do
    it "folds three sites with different positions into ONE sparse histogram" do
      # Rules out a DOMINANT-SCALAR design (which would collapse this to a
      # single value) and an all-inherit walker (which would read
      # {unknown: 2, value: 1}).
      in_repo(USAGE_HIST_ANCHOR) do |dir|
        edge = edge_usage(collect(dir), "Thing#go", "Thing#helper")
        expect(edge.calls).to eq(3)
        expect(edge.usage).to eq({ effect: 2, value: 1 })
      end
    end

    it "classifies the condition call as :predicate" do
      # Rules out a missing IfNode#predicate rule, which would read
      # {effect: 1}.
      in_repo(USAGE_HIST_ANCHOR) do |dir|
        edge = edge_usage(collect(dir), "Thing#go", "Thing#flag?")
        expect(edge.calls).to eq(1)
        expect(edge.usage).to eq({ predicate: 1 })
      end
    end

    it "keeps a two-class edge as TWO keys (`x = helper if helper`)" do
      # Rules out BOTH rejected designs at once: a dominant scalar collapses
      # the 2-key hash, and raw-edge unanimity-or-absent omits the key
      # entirely.
      in_repo(USAGE_HIST_ANCHOR) do |dir|
        edge = edge_usage(collect(dir), "Thing#dual", "Thing#helper")
        expect(edge.calls).to eq(2)
        expect(edge.usage).to eq({ predicate: 1, value: 1 })
      end
    end

    it "attaches the stamp to the EDGE, not the node (DIR-SPLIT)" do
      # `Thing#helper` has INBOUND edges carrying usage and ZERO outbound
      # edges; `Thing#go` is the mirror. A node-attached implementation cannot
      # reproduce "helper has usage in but none out."
      in_repo(USAGE_HIST_ANCHOR) do |dir|
        result = collect(dir)
        helper = result.nodes.find { |n| n.symbol == "Thing#helper" }
        go     = result.nodes.find { |n| n.symbol == "Thing#go" }

        inbound_helper  = result.edges.select { |e| e.to_key == helper.real_key }
        outbound_helper = result.edges.select { |e| e.from_key == helper.real_key }
        outbound_go     = result.edges.select { |e| e.from_key == go.real_key }
        inbound_go      = result.edges.select { |e| e.to_key == go.real_key }

        expect(inbound_helper).not_to be_empty
        expect(inbound_helper.map(&:usage)).to all(be_a(Hash))
        expect(outbound_helper).to be_empty
        expect(outbound_go).not_to be_empty
        expect(outbound_go.map(&:usage)).to all(be_a(Hash))
        expect(inbound_go).to be_empty
      end
    end
  end

  describe "the three hard rules over every golden corpus" do
    it "holds the SUM INVARIANT on every edge that carries a histogram (R4)" do
      checked = 0
      each_corpus_result do |name, result|
        result.edges.each do |edge|
          next if edge.usage.nil?

          checked += 1
          expect(edge.usage.values.sum).to eq(edge.calls),
                                           "#{name}: #{edge.usage.inspect} does not sum to #{edge.calls}"
        end
      end
      # The gate is only meaningful if it actually examined something.
      expect(checked).to be > 0
    end

    it "emits only Integers >= 1, never a zero-filled class (R2)" do
      each_corpus_result do |name, result|
        result.edges.each do |edge|
          next if edge.usage.nil?

          expect(edge.usage.values).to all(be_a(Integer)), name
          expect(edge.usage.values).to all(be >= 1), name
        end
      end
    end

    it "never carries an EMPTY histogram (R3)" do
      each_corpus_result do |name, result|
        result.edges.each do |edge|
          expect(edge.usage.nil? || !edge.usage.empty?).to be(true),
                                                           "#{name}: an edge carries usage: {}"
        end
      end
    end

    it "uses only the four closed vocabulary keys" do
      classes = Archbuddy::Collect::Adapters::Ruby::UsageWalker::CLASSES
      each_corpus_result do |name, result|
        result.edges.each do |edge|
          next if edge.usage.nil?

          expect(edge.usage.keys - classes).to eq([]), name
        end
      end
    end

    it "leaves usage_unmapped EMPTY on every corpus (TOTALITY)" do
      each_corpus_result do |name, result|
        expect(result.diagnostics[:usage_unmapped]).to eq({}),
                                                       "#{name}: #{result.diagnostics[:usage_unmapped].inspect}"
      end
    end
  end

  describe "the degenerate cases" do
    it "carries nil — never {} — on an edge with no classified call site" do
      # A synthesized edge has no AST call site behind it at all (R6).
      synthesized = Archbuddy::Collect::Raw::RawEdge.new(from_key: "a", to_key: "b", calls: 1)
      expect(synthesized.usage).to be_nil
    end

    it "carries nil — never {} — when an edge's call sites were ALL unmapped (THE DEFAULT-PROC TRAP)" do
      # THE CROSSING CELL, and the only example that kills the one real trap in
      # this fold. `usages` must be read with fetch(.., nil) on a PLAIN Hash: a
      # `Hash.new { |h,k| h[k] = Hash.new(0) }` default proc MATERIALIZES an
      # entry the instant it is read, so every edge would come out carrying
      # `usage: {}` instead of nil — fabricating a measurement nobody made.
      #
      # On every corpus available today each edge has at least one classified
      # site, so the trap is INVISIBLE to a corpus-wide scan: swapping in the
      # default proc leaves every other example in this file green. Forcing the
      # walker to classify nothing is what makes the assertion bite.
      allow(Archbuddy::Collect::Adapters::Ruby::UsageWalker).to receive(:classify).and_return({})

      in_repo(USAGE_HIST_ANCHOR) do |dir|
        result = collect(dir)
        expect(result.edges).not_to be_empty
        expect(result.edges.map(&:usage)).to all(be_nil)
        expect(result.edges.map(&:usage)).not_to include({})
        # The gap is DECLARED, not silent: every site is tallied by reason.
        expect(result.diagnostics[:usage_unmapped]).to eq({ walker_miss: result.diagnostics[:total_call_sites] })
        expect(result.diagnostics[:usage_counts]).to eq({})
      end
    end

    it "reports empty diagnostics counters on a corpus with no edges" do
      in_repo("CONSTANT = 1\n") do |dir|
        diagnostics = collect(dir).diagnostics
        expect(diagnostics[:usage_counts]).to eq({})
        expect(diagnostics[:usage_unmapped]).to eq({})
      end
    end
  end
end
