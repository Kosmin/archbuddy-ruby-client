# frozen_string_literal: true

require "json"

module Archbuddy
  module Review
    # The A6 fragment-walk reader: builds a Review::Vintage from a committed
    # cache dir (aggregate + detail tree), keeping the (file, symbol) identity
    # that DetailTree#reassemble drops.
    #
    # POINTER-DRIVEN ONLY (G9): the walk reads exactly the aggregate's
    # `sources` pointers — never globs beyond a pointed shard dir. id-map.yml
    # sits beside study-snapshot aggregates and is structurally unreachable.
    #
    # Exported-layout fallback (G9): study snapshot exports keep dotted
    # `.archbuddy/…` pointer paths while the on-disk tree is un-dotted
    # `archbuddy/…`; an absent dotted path is retried with the un-dotted
    # prefix (one stderr note on first fallback).
    #
    # Corrupt/unreadable fragment ⇒ the WHOLE source file is excluded and
    # recorded (DELIBERATE divergence from DetailTree's silent skip: a
    # silently skipped base fragment would fabricate REMOVED nodes and
    # phantom ratchet credit).
    module FragmentWalk
      DOTTED_PREFIX   = ".archbuddy/"
      UNDOTTED_PREFIX = "archbuddy/"

      module_function

      # @param root [String] dir holding archbuddy-findings.json + detail tree
      # @return [Review::Vintage]
      # @raise [Review::VintageError] when the aggregate is missing/unparseable
      def read(root)
        root = File.expand_path(root)
        aggregate = load_aggregate(root)
        sources = aggregate["sources"] || {}

        state = WalkState.new
        sources.each do |rel_file, pointer|
          ingest_source(root, rel_file, pointer, state)
        end

        if state.branchless_count.positive?
          warn "warning: #{state.branchless_count} node(s) without branch data — excluded from delta math"
        end

        Vintage.new(
          nodes: state.nodes,
          edges: state.edges,
          corrupt_files: state.corrupt_files,
          edges_present: state.edges_present,
          meta: {
            serializer_versions: state.serializer_versions.to_a.sort,
            sources_count: sources.size
          }
        )
      end

      # Mutable accumulation for one read (module_function-friendly).
      class WalkState
        attr_reader :corrupt_files, :serializer_versions
        attr_accessor :edges_present, :branchless_count, :fallback_noted

        def initialize
          @by_identity = {}
          @edge_keys = {}
          @corrupt_files = []
          @serializer_versions = ::Set.new
          @edges_present = false
          @branchless_count = 0
          @fallback_noted = false
        end

        def add_node(node)
          key = [node.file, node.symbol]
          return if @by_identity.key?(key) # first wins (identical shard payloads)

          @by_identity[key] = node
          @branchless_count += 1 unless node.branches.is_a?(Integer) && node.branches >= 1
        end

        def add_edge(from, to, calls)
          key = [from, to, calls]
          @edge_keys[key] ||= { from: from, to: to, calls: calls }
        end

        def nodes
          @by_identity.values
        end

        def edges
          @edge_keys.values
        end
      end

      def load_aggregate(root)
        path = File.join(root, "archbuddy-findings.json")
        raise VintageError, "no readable archbuddy-findings.json at #{root}" unless File.file?(path)

        JSON.parse(File.read(path))
      rescue JSON::ParserError, SystemCallError, IOError
        raise VintageError, "no readable archbuddy-findings.json at #{root}"
      end

      # Read every fragment file one source pointer covers; on ANY unreadable
      # fragment the whole source file is excluded (loud), ingesting nothing.
      def ingest_source(root, rel_file, pointer, state)
        docs = []
        fragment_paths(root, pointer, state).each do |path|
          docs << JSON.parse(File.read(path))
        end
        docs.each { |doc| ingest_fragment(doc, rel_file, state) }
      rescue JSON::ParserError, SystemCallError, IOError
        state.corrupt_files << rel_file
        warn "warning: unreadable fragment for #{rel_file} — file excluded from review"
      end

      # The fragment file list a pointer covers: SINGLE mode → one file;
      # sharded modes → every *.json under the pointed dir, sorted. Trusts the
      # recorded shard_mode (never re-derives the layout). A missing path is
      # retried via the exported-layout prefix swap; still missing → raise
      # (handled as whole-file exclusion by the caller).
      def fragment_paths(root, pointer, state)
        rel = pointer && pointer["path"]
        raise IOError, "missing pointer" if rel.nil?

        abs = resolve_pointer(root, rel, state)
        raise Errno::ENOENT, rel if abs.nil?

        if pointer["shard_mode"] && pointer["shard_mode"] != "single"
          Dir.glob(File.join(abs, "**", "*.json")).sort
        elsif File.directory?(abs)
          Dir.glob(File.join(abs, "**", "*.json")).sort
        else
          [abs]
        end
      end

      # Dotted → un-dotted prefix swap (exported layout), one note per read.
      def resolve_pointer(root, rel, state)
        abs = File.join(root, rel)
        return abs if File.exist?(abs)

        return nil unless rel.start_with?(DOTTED_PREFIX)

        swapped = File.join(root, rel.sub(DOTTED_PREFIX, UNDOTTED_PREFIX))
        return nil unless File.exist?(swapped)

        unless state.fallback_noted
          warn "note: reading detail tree from 'archbuddy/' (exported layout)"
          state.fallback_noted = true
        end
        swapped
      end

      def ingest_fragment(doc, rel_file, state)
        state.serializer_versions << doc["serializer_version"] if doc["serializer_version"]
        state.edges_present = true if doc.key?("edges")

        file = doc["file"] || rel_file
        (doc["nodes"] || []).each do |raw|
          symbol = raw["symbol"]
          next if symbol.nil? # DetailTree precedent

          state.add_node(build_node(raw, file, doc["serializer_version"]))
        end

        (doc["edges"] || []).each do |edge|
          state.add_edge(edge["from"], edge["to"], edge["calls"])
        end
      end

      def build_node(raw, file, serializer_version)
        Vintage::Node.new(
          file: file,
          symbol: raw["symbol"],
          kind: raw["kind"],
          klass: raw["class"],
          branches: raw["branches"],
          decisions: raw["decisions"],
          entrypoint: raw["entrypoint"],
          entrypoint_kind: raw["entrypoint_kind"],
          escapes: raw["escapes"],
          outcome_arity: raw["outcome_arity"],
          toll_booth: raw["toll_booth"],
          quadrant: raw["quadrant"],
          leverage: raw["leverage"],
          collapse: raw["collapse"],
          score: raw["score"],
          score_band: raw["score_band"],
          score_raw: raw["score_raw"],
          absorb: raw["absorb"],
          absorb_raw: raw["absorb_raw"],
          serializer_version: serializer_version,
          keys_present: raw.keys.sort.freeze
        )
      end
    end
  end
end
