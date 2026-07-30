# frozen_string_literal: true

require "set"
require "archbuddy/review"

# Spec-only protocol doubles for the I-C1 (Vintage) and I-C4' (Delta) seams.
# Duck-typed to §2.3 — the engine and rules never notice the difference.
module ReviewStubs
  NODE_DEFAULTS = {
    kind: "function", klass: nil, branches: 1, decisions: 0,
    entrypoint: false, entrypoint_kind: nil, escapes: nil, outcome_arity: nil,
    toll_booth: nil, quadrant: nil, leverage: nil, collapse: nil,
    score: nil, score_band: nil, score_raw: nil, absorb: nil, absorb_raw: nil,
    serializer_version: 5
  }.freeze

  module_function

  # A Review::Vintage::Node with defaults; keys_present derived from the
  # non-nil payload (key-presence evaluability, P8).
  def stub_node(file:, symbol:, **overrides)
    attrs = NODE_DEFAULTS.merge(overrides)
    keys_present = attrs.reject { |_k, v| v.nil? }.keys + %i[file symbol]
    Archbuddy::Review::Vintage::Node.new(
      file: file, symbol: symbol,
      keys_present: attrs.key?(:keys_present) ? attrs.delete(:keys_present) : keys_present,
      **attrs.slice(*NODE_DEFAULTS.keys)
    )
  end

  EP_METRICS_DEFAULTS = {
    branching_log2: 0.0, mass: 0, reach: 1, files: 1, depth: 1, own_branches: 1,
    max_cone_node: nil, vty_log: nil, vty_floor_log: nil, dividend: nil,
    dividend_log2: nil, escapes_in_cone: [], entrypoint_kind: "api",
    top_nodes: [], top_dividend_nodes: nil, cone_size: 1
  }.freeze

  # An I-C3' EpMetrics row with defaults (max_cone_node derived from the ep's
  # own branches unless overridden) — the rule specs' fixture unit.
  def stub_ep_metrics(file:, symbol:, **overrides)
    attrs = EP_METRICS_DEFAULTS.merge(overrides)
    attrs[:max_cone_node] ||= {
      file: file, symbol: symbol, branches: attrs[:own_branches],
      log2: Math.log2([attrs[:own_branches], 1].max)
    }
    Archbuddy::Review::EpMetrics.new(**attrs)
  end

  class StubVintage
    def initialize(nodes: [], edges: true, analyzed: false, eps: nil, graph: nil,
                   corrupt_files: [], meta: {})
      @nodes = nodes
      @edges = edges
      @analyzed = analyzed
      @eps = eps
      @graph = graph
      @corrupt_files = corrupt_files
      @meta = { serializer_versions: [5], sources_count: nodes.size }.merge(meta)
    end

    attr_reader :nodes, :corrupt_files, :meta

    def eps
      @eps || @nodes.select(&:entrypoint)
    end

    def edges?
      @edges
    end

    def analyzed?
      @analyzed
    end

    def empty?
      @nodes.empty?
    end

    def node_count
      @nodes.size
    end

    def [](file, symbol)
      by_identity[[file, symbol]]
    end

    def by_identity
      @by_identity ||= @nodes.each_with_object({}) { |n, acc| acc[[n.file, n.symbol]] ||= n }
    end

    def files
      @nodes.map(&:file).uniq.sort
    end

    def out_edges(_symbol)
      []
    end

    # A StubGraph when given; else raises loudly — specs asserting the R52
    # lazy-graph predicate construct StubVintage WITHOUT a graph.
    def graph
      @graph || raise("vintage.graph touched — lazy-graph predicate violated (R52)")
    end
  end

  class StubGraph
    def initialize(ep_metrics: {}, unreachable_from_entrypoints: nil,
                   subtree_log2_by_ep: {}, depth_map: {})
      @ep_metrics = ep_metrics
      @unreachable = unreachable_from_entrypoints
      @subtree_log2_by_ep = subtree_log2_by_ep
      @depth_map = depth_map
    end

    attr_reader :ep_metrics, :subtree_log2_by_ep

    def unreachable_from_entrypoints
      @unreachable
    end

    def depth(symbol)
      @depth_map.fetch(symbol, 1)
    end

    def depth_by_symbol
      @depth_map
    end
  end

  class StubDelta
    def initialize(entries: [], ep_entries: [], review_surface: nil, disclosures: nil,
                   touched_files: nil, net_log2: 0.0, ep_deltas: {}, base: nil, head: nil)
      @entries = entries
      @ep_entries = ep_entries
      @review_surface = review_surface
      @disclosures = disclosures
      @touched_files = touched_files ||
                       Set.new(entries.map { |e| e.respond_to?(:file) ? e.file : e[:file] })
      @net_log2 = net_log2
      @ep_deltas = ep_deltas
      @base = base
      @head = head
    end

    attr_reader :entries, :ep_entries, :review_surface, :disclosures,
                :touched_files, :net_log2, :ep_deltas, :base, :head

    def counts
      tally = { new: 0, grown: 0, shrunk: 0, removed: 0 }
      @entries.each do |e|
        c = e.respond_to?(:classification) ? e.classification : e[:classification]
        tally[c] += 1 if tally.key?(c)
      end
      tally
    end

    def scope_net(paths:)
      @entries.select { |e| Archbuddy::Config::PathMatcher.match?(paths, e.file) }
              .sum(&:delta_log2)
    end

    def scope_match?(paths:)
      files = ((@base&.files || []) | (@head&.files || []))
      files = @touched_files.to_a if files.empty?
      files.any? { |f| Archbuddy::Config::PathMatcher.match?(paths, f) }
    end

    def excluded_files
      []
    end
  end
end
