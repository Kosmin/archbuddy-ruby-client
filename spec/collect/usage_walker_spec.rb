# frozen_string_literal: true

require "spec_helper"
require "prism"

# THE CLASSIFICATION TABLE, ONE EXAMPLE PER ROW.
#
# Every fixture here is SYNTHETIC and inline — generic `compute` / `helper` /
# `flag?` names, no analysed-repo vocabulary anywhere.
#
# Two groups carry more weight than the rest:
#
#   * THE SEED ANCHOR. `def tail_only; helper; end` must classify `helper` as
#     :unknown. That single example rules out BOTH plausible wrong seeds at
#     once — seeding a def body :value gives :value, forcing every statement
#     :effect gives :effect. Nothing else in this file discriminates the def
#     tail, so it is mandatory.
#
#   * THE DEFAULT-DESCEND GROUP. The walker's default branch DESCENDS at
#     :unknown instead of stopping. A stopping default would silently drop
#     every CallNode under SuperNode / DefinedNode / RangeNode /
#     SingletonClassNode — nodes the resolution walk DOES record edges for — so
#     those examples assert PRESENCE in the map. Absence is the failure; the
#     class being :unknown is acceptable.
RSpec.describe Archbuddy::Collect::Adapters::Ruby::UsageWalker do
  USAGE_WALKER_CLASS = Archbuddy::Collect::Adapters::Ruby::UsageWalker

  # Classify every def in `source` and return { call name (Symbol) => [classes] }.
  def classify(source)
    parsed = Prism.parse(source).value
    map    = {}
    each_node(parsed) do |node|
      map.merge!(described_class.classify(node, seed: :unknown_def_tail)) if node.is_a?(Prism::DefNode)
    end

    by_name = Hash.new { |h, k| h[k] = [] }
    each_node(parsed) do |node|
      by_name[node.name] << map[node.node_id] if node.is_a?(Prism::CallNode) && map.key?(node.node_id)
    end
    by_name
  end

  # Names of every CallNode in `source` that the walker left OUT of the map.
  def unmapped_call_names(source)
    parsed = Prism.parse(source).value
    map    = {}
    each_node(parsed) do |node|
      map.merge!(described_class.classify(node, seed: :unknown_def_tail)) if node.is_a?(Prism::DefNode)
    end

    names = []
    seen_def = false
    each_node(parsed) do |node|
      seen_def ||= node.is_a?(Prism::DefNode)
      names << node.name if node.is_a?(Prism::CallNode) && !map.key?(node.node_id)
    end
    names
  end

  def each_node(node, &block)
    return if node.nil?

    block.call(node)
    return unless node.respond_to?(:compact_child_nodes)

    node.compact_child_nodes.each { |child| each_node(child, &block) }
  end

  describe "the closed vocabulary" do
    it "is exactly value/predicate/effect/unknown" do
      expect(described_class::CLASSES).to eq(%i[value predicate effect unknown])
    end

    it "never lets an internal propagation seed escape into a recorded class" do
      # :unknown_def_tail / :unknown_block_tail are kept distinct WHILE
      # propagating so a future diagnostic can name which irreducible case
      # produced an unknown — but they normalize at record time.
      source = <<~RUBY
        def m
          [1].map { inner }
          outer
        end
      RUBY
      classify(source).each_value do |classes|
        classes.each { |c| expect(described_class::CLASSES).to include(c) }
      end
    end
  end

  describe ":value positions" do
    {
      "assignment RHS"            => ["def m; x = compute; end", :compute],
      "call argument"             => ["def m; takes(compute); end", :compute],
      "splat argument"            => ["def m; takes(*compute); end", :compute],
      "keyword argument"          => ["def m; takes(k: compute); end", :compute],
      "block-pass argument"       => ["def m; takes(&compute); end", :compute],
      "array element"             => ["def m; [compute]; end", :compute],
      "explicit return"           => ["def m; return compute; end", :compute],
      "operator write RHS"        => ["def m; x += compute; end", :compute],
      "multi-write RHS"           => ["def m; a, b = compute; end", :compute],
      "or-write RHS"              => ["def m; @x ||= compute; end", :compute],
      "optional param default"    => ["def m(a = compute); end", :compute],
      "optional kwarg default"    => ["def m(a: compute); end", :compute],
      "for-loop collection"       => ["def m; for i in compute; nil; end; end", :compute],
      "singleton def receiver"    => ["def (compute).m; end", :compute],
      "non-bang call receiver"    => ["def m; compute.chain; end", :compute],
      "safe-navigation receiver"  => ["def m; compute&.chain; end", :compute]
    }.each do |label, (source, name)|
      it "classifies #{label} as :value" do
        expect(classify(source)[name]).to include(:value)
      end
    end

    it "classifies BOTH halves of a hash pair as :value" do
      got = classify("def m; { compute_key => compute_val }; end")
      expect(got[:compute_key]).to include(:value)
      expect(got[:compute_val]).to include(:value)
    end

    it "classifies a string-interpolation tail as :value" do
      expect(classify('def m; "x #{compute} y"; end')[:compute]).to include(:value)
    end

    it "classifies a yield argument as :value" do
      expect(classify("def m; yield compute; end")[:compute]).to include(:value)
    end

    it "overrides the positional ctx for an explicit return in non-final position" do
      # A `return` is never discarded, even when it sits where a bare statement
      # would be :effect.
      got = classify("def m; return compute if flag?; other; end")
      expect(got[:compute]).to eq([:value])
    end
  end

  describe ":predicate positions" do
    {
      "if condition"          => ["def m; if compute; 1; end; end", :compute],
      "unless condition"      => ["def m; unless compute; 1; end; end", :compute],
      "modifier-if condition" => ["def m; 1 if compute; end", :compute],
      "ternary condition"     => ["def m; compute ? 1 : 2; end", :compute],
      "while condition"       => ["def m; while compute; 1; end; end", :compute],
      "until condition"       => ["def m; until compute; 1; end; end", :compute],
      "case subject"          => ["def m; case compute; when 1; 2; end; end", :compute],
      "bang operand"          => ["def m; !compute; end", :compute],
      "not operand"           => ["def m; not compute; end", :compute],
      "and left operand"      => ["def m; compute && other; end", :compute],
      "or left operand"       => ["def m; compute || other; end", :compute],
      "pattern pin expression" => ["def m; case x; in ^(compute); 1; end; end", :compute]
    }.each do |label, (source, name)|
      it "classifies a #{label} as :predicate" do
        expect(classify(source)[name]).to include(:predicate)
      end
    end

    it "classifies a `when` condition as :predicate" do
      got = classify("def m; case compute_subj; when compute_when; 1; end; end")
      expect(got[:compute_subj]).to include(:predicate)
      expect(got[:compute_when]).to include(:predicate)
    end

    it "classifies a `!` RECEIVER as :predicate while a plain receiver stays :value" do
      # The one receiver position that is not :value — `!x` and `not x` both
      # parse to CallNode(name: :!, receiver: x), and it is x's TRUTHINESS that
      # is tested rather than x being consumed as data.
      expect(classify("def m; !compute; end")[:compute]).to eq([:predicate])
      expect(classify("def m; compute.size; end")[:compute]).to eq([:value])
    end
  end

  describe ":effect positions" do
    it "classifies a non-final statement as :effect" do
      got = classify("def m; compute; tail_call; end")
      expect(got[:compute]).to eq([:effect])
    end

    it "classifies EVERY while-body statement as :effect, including the last" do
      # A loop's value never depends on its body tail — this is resolved
      # locally, not passed through from the enclosing context.
      got = classify("def m; x = while cond; first; last_stmt; end; end")
      expect(got[:first]).to eq([:effect])
      expect(got[:last_stmt]).to eq([:effect])
      expect(got[:cond]).to eq([:predicate])
    end

    it "classifies every for-body statement as :effect" do
      expect(classify("def m; for i in list; compute; end; end")[:compute]).to eq([:effect])
    end

    it "classifies an ensure body as :effect regardless of the outer context" do
      got = classify("def m; x = begin; work; ensure; compute; end; end")
      expect(got[:compute]).to eq([:effect])
      expect(got[:work]).to eq([:value])
    end

    it "classifies a begin body as :effect when an else clause is present" do
      # Control reaches `else` only on success, so it is else's tail — not the
      # body's — that propagates.
      got = classify("def m; x = begin; compute_body; else; compute_else; end; end")
      expect(got[:compute_body]).to eq([:effect])
      expect(got[:compute_else]).to eq([:value])
    end
  end

  describe "the irreducible unknowns" do
    it "classifies the implicit def tail as :unknown (THE SEED ANCHOR)" do
      # Mandatory. :value here would mean the body was seeded :value; :effect
      # would mean every statement was forced :effect. Only :unknown is right —
      # the consumer is THIS method's caller, which is not in local scope.
      expect(classify("def tail_only; helper; end")[:helper]).to eq([:unknown])
    end

    it "classifies a block tail as :unknown" do
      expect(classify("def m; [1].map { compute }; end")[:compute]).to eq([:unknown])
    end

    it "classifies a lambda tail as :unknown" do
      expect(classify("def m; -> { compute }; end")[:compute]).to eq([:unknown])
    end

    it "inherits the def seed through an && right operand" do
      got = classify("def m; compute_a && compute_b; end")
      expect(got[:compute_a]).to eq([:predicate])
      expect(got[:compute_b]).to eq([:unknown])
    end
  end

  describe "inheritance through pass-through wrappers" do
    it "passes the enclosing context through parentheses" do
      expect(classify("def m; x = (compute); end")[:compute]).to eq([:value])
    end

    it "passes the enclosing context into both branches of an if" do
      got = classify("def m; x = if flag?; compute_a; else; compute_b; end; end")
      expect(got[:compute_a]).to eq([:value])
      expect(got[:compute_b]).to eq([:value])
    end

    it "passes the enclosing context into both halves of a rescue modifier" do
      got = classify("def m; x = compute_try rescue compute_fallback; end")
      expect(got[:compute_try]).to eq([:value])
      expect(got[:compute_fallback]).to eq([:value])
    end

    it "classifies a rescue exception match as :predicate and its body by inheritance" do
      source = <<~RUBY
        def m
          x = begin
            work
          rescue compute_err
            compute_handler
          end
        end
      RUBY
      got = classify(source)
      expect(got[:compute_err]).to eq([:predicate])
      expect(got[:compute_handler]).to eq([:value])
    end
  end

  describe "the nested-def STOP" do
    it "leaves an inner def's call sites out of the outer scope's map" do
      source = <<~RUBY
        def outer
          def inner
            compute
          end
          other
        end
      RUBY
      parsed = Prism.parse(source).value
      outer  = nil
      each_node(parsed) { |n| outer ||= n if n.is_a?(Prism::DefNode) }
      map = described_class.classify(outer, seed: :unknown_def_tail)

      inner_call = nil
      each_node(parsed) { |n| inner_call = n if n.is_a?(Prism::CallNode) && n.name == :compute }
      expect(map).not_to have_key(inner_call.node_id)
    end
  end

  describe "THE DEFAULT DESCENDS (a stopping default would delete edges)" do
    # Each construct below carries a CallNode that ResolutionPass DOES record
    # an edge for. PRESENCE in the map is the assertion; the class may be
    # :unknown. A no-op default would make every one of these absent, and the
    # hole would only detonate later as a non-empty usage_unmapped.
    {
      "super arguments"      => "def m; super(compute); end",
      "defined? operand"     => "def m; defined?(compute); end",
      "range endpoint"       => "def m; (1..compute); end",
      "singleton class body" => "def m; class << self; compute; end; end",
      "match-required value" => "def m; compute => x; end",
      "nested class body"    => "def m; Class.new { compute }; end"
    }.each do |label, source|
      it "keeps the call site inside #{label} in the map" do
        expect(unmapped_call_names(source)).not_to include(:compute)
      end
    end
  end

  describe "degenerate inputs" do
    it "returns {} for nil" do
      expect(described_class.classify(nil, seed: :unknown_def_tail)).to eq({})
    end

    it "returns {} for an empty def body" do
      parsed = Prism.parse("def m; end").value
      node   = nil
      each_node(parsed) { |n| node ||= n if n.is_a?(Prism::DefNode) }
      expect(described_class.classify(node, seed: :unknown_def_tail)).to eq({})
    end

    it "returns {} for a body with no call site" do
      # NB `1 + 2` would NOT qualify — an operator is a CallNode.
      parsed = Prism.parse("def m; @x = 3; :sym; end").value
      node   = nil
      each_node(parsed) { |n| node ||= n if n.is_a?(Prism::DefNode) }
      expect(described_class.classify(node, seed: :unknown_def_tail)).to eq({})
    end
  end

  # --- D-1 RATIFICATION GATE ----------------------------------------------
  #
  # L4 is the single-compute rule: thread existing folds rather than adding
  # traversals. The pre-scan is a NEW per-scope AST pass, so it is ratified
  # with a hard, executed bound rather than an argument.
  #
  # THE DISCRIMINATING PAIR. A total-count check alone ("we made N visits")
  # passes an implementation that walks half the tree twice. So this asserts
  # BOTH halves:
  #   (1) every visited node is visited EXACTLY ONCE — values.all?(eq(1));
  #   (2) the visited set is a SUBSET of the file's AST nodes — size <= total.
  # (1) alone would pass a walker that skipped half the file; (2) alone would
  # pass one that visited the same node twice and another not at all.
  describe "D-1: once-per-file visit bound" do
    # Counts `walk` entries per node_id by wrapping the walker's own recursion.
    class UsageCountingWalker < USAGE_WALKER_CLASS
      attr_reader :visits

      def initialize
        super
        @visits = Hash.new(0)
      end

      private

      def walk(node, ctx)
        @visits[node.node_id] += 1 unless node.nil?
        super
      end
    end

    def visit_counts(source)
      parsed = Prism.parse(source).value
      counts = Hash.new(0)
      each_node(parsed) do |node|
        next unless node.is_a?(Prism::DefNode)

        walker = UsageCountingWalker.new
        walker.walk_scope(node, :unknown_def_tail)
        walker.visits.each { |id, n| counts[id] += n }
      end
      counts
    end

    def ast_node_count(source)
      total = 0
      each_node(Prism.parse(source).value) { |_| total += 1 }
      total
    end

    let(:source) do
      <<~RUBY
        class Thing
          def helper; 1; end
          def flag?; true; end

          def go(limit = helper)
            helper
            x = helper
            helper if flag?
            [1, 2].each { |i| helper }
            case x
            when 1 then helper
            else helper
            end
            x
          end

          def dual
            x = helper if helper
            begin
              helper
            rescue StandardError
              helper
            ensure
              helper
            end
            x
          end
        end
      RUBY
    end

    it "visits every node it touches EXACTLY once" do
      expect(visit_counts(source).values).to all(eq(1))
    end

    it "touches no more nodes than the file's AST contains" do
      counts = visit_counts(source)
      expect(counts.size).to be <= ast_node_count(source)
      expect(counts.size).to be > 0
    end
  end
end
