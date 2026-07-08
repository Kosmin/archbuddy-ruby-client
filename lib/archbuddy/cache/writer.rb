# frozen_string_literal: true

require "fileutils"
require "set"
require "json"
require_relative "canonical_json"
require_relative "layout"

module Archbuddy
  module Cache
    # C1-2: writes the COMMITTED, REAL-NAME, line-free `.archbuddy/` cache by
    # transcoding the opaque interchange (graph + SECRET id-map [+ findings]) at
    # WRITE time (DE-ANON-AT-WRITE — CR-1). A fresh clone reads the committed
    # cache DIRECTLY with NO id-map.
    #
    # Inputs (all string-keyed hashes as produced upstream):
    #   graph    — opaque graph (Anonymizer#call.graph): nodes[], edges[], entrypoints[]
    #   id_map   — SECRET id-map (Anonymizer#call.id_map): {"ids" => {opaque=>desc}}
    #   findings — OPTIONAL opaque findings.yml doc (engine analyze). When present,
    #              the root aggregate carries de-anonymized scores + the
    #              multiplexer_proxy list; when nil, the aggregate carries the
    #              structural summary only (collect-time, pre-analyze).
    #
    # Outputs (real-name, LINE-FREE — line is display-only, stays in the gitignored
    # id-map, NEVER serialized here, so a pure line move produces ZERO committed
    # diff — the C1 value-level line-stability invariant):
    #   archbuddy-findings.json                  ROOT compact aggregate (pointers)
    #   .archbuddy/<mirrored-src>[.json | /…]    adaptively-sharded detail tree
    #
    # Canonical serialization (Cache::CanonicalJson): sorted object keys; arrays
    # canonically ordered HERE (nodes by symbol; edges by [from,to,calls] — the
    # C3 provably-total tiebreaker; proxies worst-first as the engine emits them);
    # fixed float precision. Two runs over the same tree → byte-identical bytes.
    class Writer
      # Bump when the committed serialization shape or canonical-ordering rule
      # changes, so a fragment written by an OLDER writer is NOT reused verbatim
      # by a newer collector (C2 collector-version stamp). Folded into the
      # fragment `content_hash` (C2 ChangeDetector) so a mismatch forces re-parse.
      SERIALIZER_VERSION = 1

      # @param project_root [String] the audited repo root (CWD by default).
      def initialize(project_root: Dir.pwd)
        @project_root = File.expand_path(project_root)
      end

      # Transcode + write the committed cache. Returns the repo-relative paths of
      # every committed file written (for the CLI + `--check`).
      #
      # @return [Hash] { aggregate: <rel>, fragments: [<rel>, …] }
      def write(graph:, id_map:, findings: nil)
        resolver  = Deanonymizer.new(id_map)
        by_file   = group_nodes_by_file(graph, resolver)
        edges     = deanonymize_edges(graph, resolver)
        entry_set = entrypoint_symbols(graph, resolver)

        pointers  = {}
        written   = []

        by_file.each do |rel_file, nodes|
          fragment = build_fragment(rel_file, nodes, edges, entry_set)
          mode, files = write_fragment(rel_file, fragment)
          pointers[rel_file] = { "path" => committed_path_for(rel_file, mode), "shard_mode" => mode }
          written.concat(files)
        end

        aggregate_rel = write_aggregate(pointers, findings, resolver)
        { aggregate: aggregate_rel, fragments: written }
      end

      private

      # --- fragment assembly (real-name, line-free) -----------------------------

      # Group de-anonymized method/db_op nodes by their owning source file. The
      # external sink (no file) is excluded from the committed detail tree — it
      # carries no app semantics and no real path.
      def group_nodes_by_file(graph, resolver)
        grouped = Hash.new { |h, k| h[k] = [] }
        (graph["nodes"] || []).each do |node|
          desc = resolver.describe(node["id"])
          file = desc && desc["file"]
          next if file.nil? # external sink / unmapped → not a committed source node

          grouped[file] << {
            "symbol"    => desc["symbol"],
            "kind"      => desc["kind"],
            # owning class REAL symbol (class-path key), nil for top-level
            "class"     => resolver.class_symbol(desc["class_id"]),
            # opaque path-cost integers carry no app semantics; keep them
            "branches"  => node["branches"],
            "decisions" => node["decisions"]
            # NO line — display-only, resolved at RENDER from the id-map.
          }
        end
        grouped
      end

      # De-anonymize every graph edge to real (from_symbol, to_symbol, calls).
      # An edge whose endpoint is unmapped (external sink) resolves to the sink's
      # placeholder symbol so the structural signal is preserved.
      def deanonymize_edges(graph, resolver)
        (graph["edges"] || []).map do |edge|
          {
            "from"  => resolver.symbol(edge["from"]),
            "to"    => resolver.symbol(edge["to"]),
            "calls" => edge["calls"]
          }
        end
      end

      def entrypoint_symbols(graph, resolver)
        (graph["entrypoints"] || []).map { |id| resolver.symbol(id) }.compact.to_set
      end

      # A single source file's committed fragment (real-name, line-free), with
      # canonical array ordering imposed here so the bytes are stable.
      def build_fragment(rel_file, nodes, all_edges, entry_set)
        node_symbols = nodes.map { |n| n["symbol"] }.to_set
        file_edges   = all_edges.select { |e| node_symbols.include?(e["from"]) }

        {
          "serializer_version" => SERIALIZER_VERSION,
          "file"               => rel_file,
          "nodes"              => nodes
                                    .map { |n| n.merge("entrypoint" => entry_set.include?(n["symbol"])) }
                                    .sort_by { |n| n["symbol"].to_s },
          "edges"              => file_edges.sort_by { |e| [e["from"].to_s, e["to"].to_s, e["calls"].to_i] }
        }
      end

      # --- committed write + adaptive sharding ---------------------------------

      # Write a fragment, choosing SINGLE vs per-class vs per-method by serialized
      # size (Layout, pure function → deterministic for `--check`). Returns the
      # [shard_mode, [rel_paths_written]].
      def write_fragment(rel_file, fragment)
        serialized = CanonicalJson.dump(fragment)

        if Layout.over_threshold?(serialized.bytesize)
          write_sharded(rel_file, fragment)
        else
          rel = Layout.single_path(rel_file)
          write_file(rel, serialized)
          [Layout::MODE_SINGLE, [rel]]
        end
      end

      # Split a large file per class (then per method for a class still over the
      # threshold). The file-level metadata rides a `_file.json` header so the
      # directory is self-describing without probing.
      def write_sharded(rel_file, fragment)
        dir = Layout.shard_dir(rel_file)
        written = []
        by_class = fragment["nodes"].group_by { |n| n["class"] || n["symbol"] }

        mode = Layout::MODE_PER_CLASS
        by_class.sort_by { |cls, _| cls.to_s }.each do |cls, cls_nodes|
          cls_edges = fragment["edges"].select { |e| cls_nodes.any? { |n| n["symbol"] == e["from"] } }
          cls_doc = {
            "serializer_version" => SERIALIZER_VERSION,
            "file"               => rel_file,
            "class"              => cls,
            "nodes"              => cls_nodes,
            "edges"              => cls_edges
          }
          cls_serialized = CanonicalJson.dump(cls_doc)
          safe_cls = sanitize(cls)

          if Layout.over_threshold?(cls_serialized.bytesize)
            mode = Layout::MODE_PER_METHOD
            cls_nodes.each do |node|
              method_doc = cls_doc.merge(
                "method" => node["symbol"],
                "nodes"  => [node],
                "edges"  => cls_edges.select { |e| e["from"] == node["symbol"] }
              )
              rel = File.join(dir, safe_cls, "#{sanitize(node["symbol"])}.json")
              write_file(rel, CanonicalJson.dump(method_doc))
              written << rel
            end
          else
            rel = File.join(dir, "#{safe_cls}.json")
            write_file(rel, cls_serialized)
            written << rel
          end
        end

        [mode, written.sort]
      end

      # --- root aggregate (compact: scores + smell + POINTERS) -----------------

      def write_aggregate(pointers, findings, resolver)
        rel = Layout::ROOT_AGGREGATE

        doc = {
          "serializer_version" => SERIALIZER_VERSION,
          # POINTERS into the detail tree — payload NOT inlined (stays small).
          "sources"            => pointers.sort.to_h
        }

        if findings
          # analyze/reset path: fold in the fresh de-anonymized scores + smell.
          scores = findings["scores"]
          if scores
            doc["scores"]              = headline_scores(scores)
            doc["multiplexer_proxies"] = deanon_proxies(scores, resolver)
          end
        else
          # collect path (no findings yet): PRESERVE any scores + smell already
          # committed by a prior analyze/reset, so a plain `collect` (e.g. an
          # incremental re-collect after a cosmetic edit) refreshes only the
          # structural pointers and does NOT clobber the aggregate's score block
          # — the C1 blank-line-clean invariant holds for the SAME committed doc.
          preserve_existing_scores(rel, doc)
        end

        write_file(rel, CanonicalJson.dump(doc))
        rel
      end

      # Carry forward the scores + multiplexer_proxies from an already-committed
      # aggregate (written by a previous analyze/reset) when the current write is
      # a collect-only (findings nil). No-op if there is no prior aggregate or it
      # carries no scores.
      def preserve_existing_scores(rel, doc)
        abs = File.join(@project_root, rel)
        return unless File.exist?(abs)

        prior = JSON.parse(File.read(abs))
        doc["scores"]              = prior["scores"]              if prior.key?("scores")
        doc["multiplexer_proxies"] = prior["multiplexer_proxies"] if prior.key?("multiplexer_proxies")
      rescue StandardError
        # A corrupt/absent prior aggregate → just write the structural doc.
        nil
      end

      # Headline (compact) dimension scores — grade + score numbers only; drop
      # the opaque hotspot id lists (those live in the detail tree / are opaque).
      def headline_scores(scores)
        out = {}
        %w[forward_discoverability reverse_traceability].each do |dim|
          d = scores[dim]
          next unless d

          out[dim] = { "grade" => d["grade"], "score" => d["score"] }
        end
        if (c = scores["connectivity"])
          out["connectivity"] = {
            "forward" => c["forward"], "reverse" => c["reverse"],
            "scored_nodes" => c["scored_nodes"], "total_nodes" => c["total_nodes"]
          }
        end
        out
      end

      # De-anonymize the E1 multiplexer_proxy list ({node, added_coupling},
      # worst-first) to real names, PRESERVING the engine's worst-first order
      # (verbatim — the client never recomputes). Empty [] passes through as [].
      def deanon_proxies(scores, resolver)
        (scores["multiplexer_proxies"] || []).map do |proxy|
          {
            "symbol"         => resolver.symbol(proxy["node"]),
            "added_coupling" => proxy["added_coupling"]
          }
        end
      end

      # --- filesystem + helpers ------------------------------------------------

      def committed_path_for(rel_file, mode)
        mode == Layout::MODE_SINGLE ? Layout.single_path(rel_file) : Layout.shard_dir(rel_file)
      end

      def write_file(rel_path, contents)
        abs = File.join(@project_root, rel_path)
        FileUtils.mkdir_p(File.dirname(abs))
        File.write(abs, contents)
      end

      # Make a real symbol safe as a single path segment (FQ separators ::, #, .,
      # etc.). Deterministic + reversible-enough for a committed filename; the
      # authoritative symbol is inside the JSON, this is just the shard filename.
      def sanitize(symbol)
        symbol.to_s.gsub(%r{[/\x00]}, "_").gsub("::", "__")
      end

      # Resolves opaque ids → real descriptors via the SECRET id-map. Mirrors the
      # report IdMapResolver shape but is used at WRITE time to de-anonymize the
      # committed cache (so the committed layer is real-name; the id-map itself
      # stays gitignored and is never committed).
      class Deanonymizer
        def initialize(id_map)
          @ids = (id_map || {})["ids"] || {}
        end

        def describe(opaque_id)
          @ids[opaque_id]
        end

        # Real symbol for an opaque id; a graceful placeholder for the external
        # sink / any unmapped id (never nil, so edges keep a stable endpoint).
        def symbol(opaque_id)
          desc = @ids[opaque_id]
          return desc["symbol"] if desc

          opaque_id.to_s.start_with?("ext_") ? "<external>" : "<external #{opaque_id}>"
        end

        # Real class symbol for a cls_ class_id (nil when top-level / unmapped).
        def class_symbol(class_id)
          return nil if class_id.nil?

          desc = @ids[class_id]
          desc && desc["symbol"]
        end
      end
    end
  end
end
