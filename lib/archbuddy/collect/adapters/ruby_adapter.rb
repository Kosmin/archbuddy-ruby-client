# frozen_string_literal: true

require "prism"
require_relative "../adapter"
require_relative "../raw"
require_relative "ruby/file_enumerator"
require_relative "ruby/symbol_table"
require_relative "ruby/definition_pass"
require_relative "ruby/resolution_pass"
require_relative "ruby/entrypoint_detector"

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

        def collect
          files  = Ruby::FileEnumerator.new(root, config).files
          parsed = parse_all(files)

          table = Ruby::SymbolTable.new
          run_definition_pass(parsed, table)

          acc = Ruby::Accumulator.new
          run_resolution_pass(parsed, table, acc)

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
            diagnostics: { meta_sites_skipped: acc.meta_sites.length }
          )
        end

        private

        def parse_all(files)
          files.map do |abs, rel_file|
            { rel_file: rel_file, value: Prism.parse(File.read(abs)).value }
          end
        end

        def run_definition_pass(parsed, table)
          parsed.each do |entry|
            entry[:value].accept(Ruby::DefinitionPass.new(table, entry[:rel_file]))
          end
        end

        def run_resolution_pass(parsed, table, acc)
          parsed.each do |entry|
            entry[:value].accept(Ruby::ResolutionPass.new(table, acc))
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
              class_symbol:   class_ref&.fq_name
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
          !method_entry.singleton &&
            method_entry.owner_fq &&
            table.controller_class?(method_entry.owner_fq)
        end
      end
    end
  end
end
