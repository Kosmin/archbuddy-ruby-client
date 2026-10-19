# frozen_string_literal: true

require "yaml"
require "set"

module Archbuddy
  module Collect
    # THE ASSERTED-GRAPH OVERLAY (graph 1.8 `provenance`).
    #
    # A static parser cannot see every call. `send`/`public_send`, metaprogrammed
    # definitions, framework callback registration, DI wiring and cross-service
    # hops are invisible to it, and those holes are NOT uniformly distributed —
    # they cluster exactly where the architecture is most indirect, which is
    # where the complexity signals most need the edges. This overlay lets an
    # engineer or an AI agent ASSERT what the parser missed.
    #
    # IT IS AN INPUT, NOT A CACHE. The machine-local `.archbuddy/.cache/` holds
    # re-derivable parse blobs and is invalidated by content hash and collector
    # version. This file is the opposite on every axis: COMMITTED, hand-written,
    # reviewed like source, and NEVER auto-invalidated — because nothing can
    # re-derive it. Conflating the two would mean a re-collect silently discards
    # human knowledge. They therefore live in different places and obey
    # different rules.
    #
    # EVERY ASSERTION STAYS LABELLED. Asserted content carries the real
    # confidence of whoever wrote it, which is categorically not a parser's, so
    # `provenance: "manual"` rides on every node and edge this class adds and a
    # consumer can always separate the two. An overlay that blended into the
    # collected graph would be a fabrication channel — the one thing the whole
    # contract is built to prevent (L3: ABSENT over fabricated).
    #
    # IDENTITY IS THE SHARED MINT, NEVER A LOCAL SCHEME. Ids come from
    # ArchitectureAuditor::Contract::Ids over (rel_file, symbol) — byte-for-byte
    # the mint the collector uses (D25/D41). That is what makes an assertion
    # FUSE: write the same file+symbol the collector saw and the edge attaches to
    # the very same node, with no reconciliation pass and no fuzzy matching.
    # Measured over two independent collects of a 26k-symbol service, 100% of
    # symbols kept their id, so an overlay written today still attaches tomorrow.
    #
    # WHAT IT REFUSES TO DO. It never rewrites or deletes collected content, and
    # it never invents a node silently. An edge naming an endpoint the collector
    # did not emit is an ERROR unless that node is explicitly declared in
    # `nodes:` — otherwise a typo in a symbol would mint a plausible-looking id,
    # attach to nothing, and quietly add a phantom to the graph. Failing loud is
    # the only safe direction for a file whose entire purpose is to be trusted.
    class ManualOverlay
      FILENAME = "manual-graph.yml"
      SUPPORTED = %w[1.0].freeze
      KINDS = %w[function endpoint db_op external].freeze
      PROVENANCE = "manual"

      # Raised for any malformed overlay. The overlay is reviewed like source, so
      # a defect in it is a build error, never a warning that scrolls past.
      class Error < StandardError; end

      Report = Struct.new(:nodes_added, :edges_added, :edges_redundant, keyword_init: true)

      attr_reader :report

      def initialize(project_root:, workspace_dir: Archbuddy::Collect::DEFAULT_WORKSPACE_DIR)
        @path = File.join(File.expand_path(project_root), workspace_dir, FILENAME)
        @report = Report.new(nodes_added: 0, edges_added: 0, edges_redundant: 0)
      end

      def exist? = File.exist?(@path)

      # Returns an augmented Anonymizer::Result. A missing overlay is the normal
      # case and returns the input UNTOUCHED — zero cost, zero diff.
      def apply(result)
        return result unless exist?

        doc = load_document
        graph = result.graph
        id_map = result.id_map["ids"] || {}

        known = graph["nodes"].to_h { |n| [n["id"], true] }
        declared = index_declared_nodes(doc, known, id_map)
        new_edges = build_edges(doc, known.merge(declared.transform_values { true }), graph)

        return result if declared.empty? && new_edges.empty?

        Anonymizer::Result.new(
          graph: graph.merge(
            "nodes" => graph["nodes"] + declared.values,
            "edges" => graph["edges"] + new_edges
          ),
          id_map: { "ids" => id_map }
        )
      end

      private

      def load_document
        doc = YAML.safe_load_file(@path)
        raise Error, "#{FILENAME}: expected a mapping at the top level" unless doc.is_a?(Hash)

        version = doc["schema_version"]
        unless SUPPORTED.include?(version)
          raise Error, "#{FILENAME}: unsupported schema_version #{version.inspect} " \
                       "(supported: #{SUPPORTED.join(', ')})"
        end
        doc
      end

      # Declared nodes are the ONLY way a symbol the collector never saw may
      # enter the graph. Each is minted through the shared Ids mint and recorded
      # in the SECRET id-map so a report can de-anonymize it like any other node.
      def index_declared_nodes(doc, known, id_map)
        Array(doc["nodes"]).each_with_object({}) do |raw, acc|
          file, symbol = require_ref(raw, "nodes[]")
          kind = raw["kind"] or raise Error, "#{FILENAME}: nodes[] entry for #{symbol} needs a `kind`"
          unless KINDS.include?(kind)
            raise Error, "#{FILENAME}: nodes[] entry for #{symbol} has kind #{kind.inspect} " \
                         "(must be one of: #{KINDS.join(', ')})"
          end
          require_why(raw, "nodes[] entry for #{symbol}")

          id = mint(kind, file, symbol)
          # Declaring something the collector already found is a no-op, NOT an
          # error: the overlay may legitimately predate the parser catching up.
          next if known.key?(id) || acc.key?(id)

          id_map[id] = {
            "class_id" => nil, "entrypoint_kind" => nil, "escapes" => false,
            "file" => file, "kind" => kind, "line" => nil, "outcome_arity" => nil,
            "symbol" => symbol, "terminal_kind" => nil
          }
          acc[id] = {
            "id" => id, "kind" => kind, "class_id" => nil, "loc" => nil,
            "self_time_ms" => nil, "total_time_ms" => nil, "count" => nil,
            "provenance" => PROVENANCE
          }
          @report.nodes_added += 1
        end
      end

      def build_edges(doc, known, graph)
        existing = graph["edges"].to_h { |e| [[e["from"], e["to"]], true] }
        seen = Set.new

        Array(doc["edges"]).filter_map do |raw|
          from = resolve_endpoint(raw["from"], known, "edges[].from")
          to   = resolve_endpoint(raw["to"], known, "edges[].to")
          require_why(raw, "edges[] entry #{from} -> #{to}")

          # The collector already observed it. Leave the OBSERVED edge alone —
          # an overlay entry must never downgrade an observation to an assertion.
          if existing.key?([from, to])
            @report.edges_redundant += 1
            next
          end
          next unless seen.add?([from, to]) # idempotent: a repeated assertion is one edge

          @report.edges_added += 1
          { "from" => from, "to" => to, "calls" => 1, "count" => nil,
            "self_time_ms" => nil, "provenance" => PROVENANCE }
        end
      end

      def resolve_endpoint(raw, known, where)
        file, symbol = require_ref(raw, where)
        id = KINDS.filter_map { |k| i = mint(k, file, symbol); i if known.key?(i) }.first
        return id if id

        raise Error, <<~MSG.strip
          #{FILENAME}: #{where} names a node the collector never emitted:
            file:   #{file}
            symbol: #{symbol}
          If that is intentional, declare it under `nodes:` with a `kind`. If it is
          not, the file or symbol is misspelled — a typo here would mint a valid-looking
          id that attaches to nothing, so it is refused rather than guessed.
        MSG
      end

      def require_ref(raw, where)
        raise Error, "#{FILENAME}: #{where} must be a mapping with `file` and `symbol`" unless raw.is_a?(Hash)

        file = raw["file"]
        symbol = raw["symbol"]
        raise Error, "#{FILENAME}: #{where} is missing `file`"   if file.to_s.empty?
        raise Error, "#{FILENAME}: #{where} is missing `symbol`" if symbol.to_s.empty?

        [file, symbol]
      end

      # An assertion nobody can audit is worse than a missing edge: it moves the
      # score with no way to review why. The reason is therefore mandatory.
      def require_why(raw, where)
        return unless raw["why"].to_s.strip.empty?

        raise Error, "#{FILENAME}: #{where} needs a `why` explaining what the parser " \
                     "could not see (e.g. \"dispatched via send(params[:kind])\")"
      end

      def mint(kind, file, symbol)
        if kind == "external"
          ArchitectureAuditor::Contract::Ids.external_id(file, symbol)
        else
          ArchitectureAuditor::Contract::Ids.node_id(file, symbol)
        end
      end
    end
  end
end
