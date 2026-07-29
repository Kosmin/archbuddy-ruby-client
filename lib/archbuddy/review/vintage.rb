# frozen_string_literal: true

module Archbuddy
  module Review
    # The per-node vintage table keyed (file, symbol) — the review identity
    # space (P3). Built by FragmentWalk (committed caches, study exports) or
    # directly (specs). Evaluability is DECLARED per node via `keys_present`
    # (key-presence-driven, never serializer-version-inferred: incremental
    # collects can leave mixed-version fragments in one cache).
    class Vintage
      # One vintage node. Absent fragment keys → nil AND absent from
      # `keys_present`; fragment `"class"` maps to `:klass`. v6 stamps add
      # the engine-published score triple `score`/`score_band`/`score_raw`
      # (findings-1.9 names verbatim, G1) — copied, never computed; a null
      # value means "analyzed, node unscored" (honest N/A, L6), an ABSENT
      # key means the fragment predates serializer v6.
      Node = Data.define(
        :file, :symbol, :kind, :klass, :branches, :decisions,
        :entrypoint, :entrypoint_kind, :escapes, :outcome_arity,
        :toll_booth, :quadrant, :leverage, :collapse,
        :score, :score_band, :score_raw,
        :serializer_version, :keys_present
      )

      attr_reader :nodes, :edges, :corrupt_files

      # @param nodes [Array<Node>]
      # @param edges [Array<Hash>] [{from:, to:, calls:}] — deduped [from,to,calls]
      # @param corrupt_files [Array<String>] whole-file exclusions (loud, never silent)
      # @param meta [Hash] {serializer_versions:, sources_count:}
      # @param edges_present [Boolean] ≥1 fragment carried an `edges` key (R31)
      def initialize(nodes:, edges:, corrupt_files: [], meta: {}, edges_present: nil)
        @nodes = nodes.freeze
        @edges = edges.freeze
        @corrupt_files = corrupt_files.freeze
        @meta = { serializer_versions: [], sources_count: 0 }.merge(meta).freeze
        @edges_present = edges_present.nil? ? !edges.empty? : edges_present
      end

      # @return [Node, nil]
      def [](file, symbol)
        by_identity[[file, symbol]]
      end

      # @return [Hash{[file, symbol] => Node}]
      def by_identity
        @by_identity ||= @nodes.each_with_object({}) do |node, acc|
          acc[[node.file, node.symbol]] ||= node
        end.freeze
      end

      # Fragment-local outgoing edges of one symbol, collapsed per (from, to)
      # with `calls` summed (R32 — CONTRACT.md edge collapse). Memoized.
      # mass = Σ calls; out_degree = count.
      # @return [Array<Hash>] [{to:, calls:}]
      def out_edges(symbol)
        out_edges_index.fetch(symbol, EMPTY_EDGES)
      end

      # Entrypoint nodes.
      def eps
        @eps ||= @nodes.select(&:entrypoint).freeze
      end

      # Distinct target-relative fragment files, sorted.
      def files
        @files ||= @nodes.map(&:file).uniq.sort.freeze
      end

      def empty?
        @nodes.empty?
      end

      def node_count
        @nodes.size
      end

      # true iff ≥1 fragment carried an `edges` key (R31) — the per-vintage
      # evaluability gate for cone/edge rules.
      def edges?
        @edges_present
      end

      # true iff ≥1 node carries a non-nil toll_booth stamp (R31) — the
      # vintage was analyzed at least once.
      def analyzed?
        return @analyzed if defined?(@analyzed)

        @analyzed = @nodes.any? { |n| !n.toll_booth.nil? }
      end

      # Lazy-memoized engine-exact traversal over this vintage's nodes+edges
      # (R7) — the ONE graph object every consumer shares.
      def graph
        @graph ||= Review::Graph.new(nodes: nodes, edges: edges)
      end

      # @return [Hash] {serializer_versions: [Integer], sources_count: Integer}
      def meta
        @meta
      end

      EMPTY_EDGES = [].freeze
      private_constant :EMPTY_EDGES

      private

      def out_edges_index
        @out_edges_index ||= begin
          index = {}
          @edges.group_by { |e| e[:from] }.each do |from, group|
            index[from] = group
                          .group_by { |e| e[:to] }
                          .map { |to, es| { to: to, calls: es.sum { |e| e[:calls].to_i } } }
                          .freeze
          end
          index.freeze
        end
      end
    end
  end
end
