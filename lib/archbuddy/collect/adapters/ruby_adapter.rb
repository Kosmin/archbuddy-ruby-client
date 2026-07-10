# frozen_string_literal: true

require "prism"
require "digest"
require_relative "../adapter"
require_relative "../raw"
require_relative "../fragment"
require_relative "../../cache/change_detector"
require_relative "../../cache/reader"
require_relative "ruby/file_enumerator"
require_relative "ruby/symbol_table"
require_relative "ruby/definition_pass"
require_relative "ruby/resolution_pass"
require_relative "ruby/entrypoint_detector"
require_relative "ruby/probe_registry"
require_relative "ruby/root_seeder_registry"
require_relative "ruby/route_catalogue"

module Archbuddy
  module Collect
    module Adapters
      # Orchestrates the Ruby static capture (K-6): enumerate .rb files, run
      # Pass 1 (definitions) across all files into a shared SymbolTable, then
      # Pass 2 (resolution) per file into a shared Accumulator, then assemble
      # neutral Raw* value objects (method nodes with class_id refs, synthesized
      # db_op nodes, and a SINGLE shared external sink) plus edges + entrypoints.
      #
      # No id minting happens here — that is the Anonymizer's sole job. Edges and
      # entrypoints reference nodes by their RawNode#real_key, computed once per
      # node so the wiring stays internally consistent.
      class RubyAdapter < Adapter
        # Real-space symbol for the single shared external sink (D24). One sink
        # for the whole graph; every unresolved call points here.
        EXTERNAL_SINK_SYMBOL = "<external>"

        # v0.8 (C1-1/C2): the whole-project capture is a two-phase pipeline —
        # a PER-FILE fragment builder (`collect_file_fragment`, the only per-file
        # step, cacheable) + a GLOBAL `assemble` over all fragments (SymbolTable
        # merge, resolution, edges, entrypoints — inherently cross-file).
        #
        # `mode`:
        #   :full        (default) — parse every enumerated file (first run / reset)
        #   :incremental (C2)      — reuse an UNCHANGED file's parse from the
        #                            machine-local `.archbuddy/.cache/` (content-hash
        #                            + collector-version gated); re-parse only
        #                            changed files. `assemble` is UNCHANGED — it
        #                            consumes fragments regardless of origin, so the
        #                            incremental result == a full recompute for the
        #                            changed set (the C2 reuse==recompute invariant).
        #
        # An empty/fully-stale cache in :incremental mode degrades to a FULL parse
        # (every file misses the reuse gate) — NOT an empty graph.
        #
        # @param mode [Symbol] :full | :incremental
        # @param base_ref [String, nil] optional git base ref (fast-path pre-filter)
        def collect(mode: :full, base_ref: nil)
          files = Ruby::FileEnumerator.new(root, config).files

          fragments =
            if mode == :incremental
              collect_incremental(files, base_ref: base_ref)
            else
              files.map { |abs, rel_file| collect_file_fragment(abs, rel_file) }
            end

          assemble(fragments)
        end

        # PER-FILE cache unit (C1-1). A pure function of ONE file's bytes: parse
        # it with Prism and capture the version-folded content hash (the C2 change
        # trigger). Reads NO cross-file state. `abs` is the absolute source path;
        # `rel_file` the repo-relative key. Returns a Collect::Fragment.
        #
        # `reader` (optional): when supplied, a hash-matching, version-matching
        # cached parse is REUSED verbatim instead of re-parsing; a fresh parse is
        # stored for next run. Same content_hash either way, so the fragment (and
        # thus the assembled graph) is byte-identical to a re-parse.
        def collect_file_fragment(abs, rel_file, reader: nil)
          source = File.read(abs)
          hash   = Cache::ChangeDetector.content_hash(source)

          parsed = reader&.reuse(rel_file, hash)
          if parsed.nil?
            parsed = Prism.parse(source).value
            reader&.store(rel_file, hash, parsed)
          end

          Fragment.new(rel_file: rel_file, content_hash: hash, parsed_value: parsed)
        end

        # GLOBAL assemble (C1-1). Runs the identical Pass-1 (definitions) + route
        # catalogue + Pass-2 (resolution) over the fragments' parsed ASTs — in
        # the fragments' given (deterministically-sorted) order — then builds the
        # neutral Raw* AdapterResult. Byte-identical to the old whole-project body
        # for the same fragment set (the C1-1 parity contract). `#collect`'s public
        # return type (AdapterResult) is unchanged so `cli/collect.rb` keeps working.
        def assemble(fragments)
          table = Ruby::SymbolTable.new
          run_definition_pass(fragments, table)
          run_route_catalogue(fragments, table)  # W4: seed routed actions before entrypoints
          run_root_seeders(table, fragments)     # v0.10 W1-B: categorize ingress roots

          acc = Ruby::Accumulator.new
          run_resolution_pass(fragments, table, acc)

          # Build nodes first, indexing each by its fq symbol -> real_key so edges
          # and entrypoints reference the exact same keys.
          nodes      = []
          key_for_fq = {}

          add_method_nodes(table, nodes, key_for_fq)
          add_db_op_nodes(table, acc, nodes, key_for_fq)
          external_key = add_external_sink(nodes)

          edges       = build_edges(acc, key_for_fq, external_key)
          entrypoints = build_entrypoints(table, key_for_fq)

          AdapterResult.new(
            nodes: nodes, edges: edges, entrypoints: entrypoints,
            # Honest about metaprogramming blind spots (D-intent): these call
            # sites were detected but produce no edges (we cannot statically
            # resolve their targets). Surfaced as a diagnostic count only —
            # never as graph content.
            diagnostics: {
              meta_sites_skipped: acc.meta_sites.length,
              # Per-probe-name tally of framework-probe-resolved call sites
              # (L5/P4). CLI/diagnostics-only — NEVER serialized into graph.yml.
              # {} when no probes are selected / none resolve a call.
              probe_edges: acc.probe_edges
            }
          )
        end

        private

        # C2 incremental build: reuse unchanged files' parses from the speed
        # cache, re-parse only changed files. The candidate set is (optionally)
        # narrowed by a git-diff fast path, but the content hash + collector
        # version in the Reader gate is AUTHORITATIVE — a file the fast path did
        # not flag but whose cache blob misses (hash/version mismatch, or no blob)
        # is still re-parsed via `collect_file_fragment`. Deleted files simply
        # never enumerate, so their fragments are dropped. The Reader stores every
        # fresh parse, so the NEXT run can reuse it.
        def collect_incremental(files, base_ref: nil)
          reader   = Cache::Reader.new(project_root: incremental_project_root)
          detector = Cache::ChangeDetector.new(project_root: incremental_project_root)

          enumerated  = files.map { |_abs, rel| rel }
          # Fast-path pre-filter is advisory: it may shrink which files we bother
          # to hash, but every enumerated file still gets a fragment (reused or
          # re-parsed) so `assemble` sees the WHOLE tree, never a partial graph.
          _candidates = detector.candidate_files(enumerated, base_ref: base_ref)

          files.map do |abs, rel_file|
            collect_file_fragment(abs, rel_file, reader: reader)
          end
        end

        # The audited project root for the machine-local `.cache/`. The adapter's
        # `root` may be a file or a dir; use its directory so `.archbuddy/.cache/`
        # anchors at the repo root the CLI runs in (CWD-relative, matching collect).
        def incremental_project_root
          File.directory?(root) ? root : File.dirname(root)
        end

        def run_definition_pass(fragments, table)
          fragments.each do |fragment|
            fragment.parsed_value.accept(Ruby::DefinitionPass.new(table, fragment.rel_file))
          end
        end

        # W4: Run the RouteCatalogue over every parsed file. The catalogue self-
        # selects (only acts on files containing routes.draw blocks) and seeds
        # (controller_fq, action) pairs into the SymbolTable only when the method
        # already exists there (L2 never-fabricate gate inside the catalogue).
        def run_route_catalogue(fragments, table)
          fragments.each do |fragment|
            fragment.parsed_value.accept(Ruby::RouteCatalogue.new(table, fragment.rel_file))
          end
        end

        # v0.10 W1-B: run the config-selected root seeders ONCE over the
        # fully-built table (they walk table.classes — superclass chains,
        # mixins, methods — so they need Pass 1 + the route catalogue done,
        # not a per-fragment visit). Fragments are passed through for
        # AST-shaped seeders (rake, later waves); table-walkers ignore them.
        # Empty selection (--root-types none) => [] => no-op.
        def run_root_seeders(table, fragments)
          Ruby::RootSeederRegistry.for(config).each do |seeder|
            seeder.seed(table, fragments: fragments)
          end
        end

        def run_resolution_pass(fragments, table, acc)
          # Build the config-selected probes ONCE (stateless; reused per file).
          # Empty in the seam wave (ProbeRegistry::PROBES == []) -> [] -> no-op.
          probes = Ruby::ProbeRegistry.for(config)
          fragments.each do |fragment|
            fragment.parsed_value.accept(Ruby::ResolutionPass.new(table, acc, probes: probes))
          end
        end

        def add_method_nodes(table, nodes, key_for_fq)
          table.methods.values.each do |m|
            class_ref = m.owner_fq && table.class_for(m.owner_fq)
            node = Raw::RawNode.new(
              rel_file:       m.rel_file,
              line:           m.line,
              symbol:         m.fq_symbol,
              kind:           endpoint?(table, m) ? "endpoint" : "function",
              class_rel_file: class_ref&.rel_file,
              class_line:     class_ref&.line,
              class_symbol:   class_ref&.fq_name,
              # Path-cost integers from the BranchCounter (P3+P9). db_op and
              # external sinks omit these and rely on the RawNode defaults (1/0).
              branches:       m.branches,
              decisions:      m.decisions
            )
            nodes << node
            key_for_fq[m.fq_symbol] = node.real_key
          end
        end

        def add_db_op_nodes(table, acc, nodes, key_for_fq)
          acc.db_ops.each do |symbol, meta|
            class_ref = meta[:class_fq] && table.class_for(meta[:class_fq])
            # Anchor the synthesized db_op at its owning class def site so its id
            # is stable and the id-map points somewhere real.
            node = Raw::RawNode.new(
              rel_file:       class_ref&.rel_file,
              line:           class_ref&.line,
              symbol:         symbol,
              kind:           "db_op",
              class_rel_file: class_ref&.rel_file,
              class_line:     class_ref&.line,
              class_symbol:   class_ref&.fq_name
              # L3 (v0.6): no sink_open — a db_op is a plain COST-1 terminal.
            )
            nodes << node
            key_for_fq[symbol] = node.real_key
          end
        end

        def add_external_sink(nodes)
          node = Raw::RawNode.new(
            rel_file: nil, line: nil, symbol: EXTERNAL_SINK_SYMBOL, kind: "external"
          )
          nodes << node
          node.real_key
        end

        # Collapse duplicate (from,to) call pairs into one edge with calls >= 1.
        def build_edges(acc, key_for_fq, external_key)
          counts = Hash.new(0)

          acc.calls.each do |call|
            from_key = key_for_fq[call[:from_fq]]
            next if from_key.nil?

            to_key =
              case call[:to][:type]
              when :method   then key_for_fq[call[:to][:fq]]
              when :db_op    then key_for_fq[call[:to][:fq]]
              when :external then external_key
              end
            next if to_key.nil?

            counts[[from_key, to_key]] += 1
          end

          counts.map do |(from_key, to_key), calls|
            Raw::RawEdge.new(from_key: from_key, to_key: to_key, calls: calls)
          end
        end

        def build_entrypoints(table, key_for_fq)
          Ruby::EntrypointDetector.new(config).detect(table).filter_map do |fq|
            key = key_for_fq[fq]
            key && Raw::RawEntrypoint.new(node_key: key)
          end
        end

        def endpoint?(table, method_entry)
          # A synthetic Grape endpoint handler block is an endpoint by
          # construction (F3); a controller action is an endpoint via the
          # existing controller-class check. Either makes kind:"endpoint".
          return true if method_entry.endpoint

          !method_entry.singleton &&
            method_entry.owner_fq &&
            table.controller_class?(method_entry.owner_fq)
        end
      end
    end
  end
end
