# frozen_string_literal: true

require "prism"
require_relative "../adapter"
require_relative "../raw"
require_relative "ruby/file_enumerator"
require_relative "ruby/symbol_table"
require_relative "ruby/definition_pass"
require_relative "ruby/resolution_pass"
require_relative "ruby/entrypoint_detector"
require_relative "ruby/probe_registry"
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

        def collect
          files  = Ruby::FileEnumerator.new(root, config).files
          parsed = parse_all(files)

          table = Ruby::SymbolTable.new
          run_definition_pass(parsed, table)
          run_route_catalogue(parsed, table)  # W4: seed routed actions before entrypoints

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

        # W4: Run the RouteCatalogue over every parsed file. The catalogue self-
        # selects (only acts on files containing routes.draw blocks) and seeds
        # (controller_fq, action) pairs into the SymbolTable only when the method
        # already exists there (L2 never-fabricate gate inside the catalogue).
        def run_route_catalogue(parsed, table)
          parsed.each do |entry|
            entry[:value].accept(Ruby::RouteCatalogue.new(table, entry[:rel_file]))
          end
        end

        def run_resolution_pass(parsed, table, acc)
          # Build the config-selected probes ONCE (stateless; reused per file).
          # Empty in the seam wave (ProbeRegistry::PROBES == []) -> [] -> no-op.
          probes = Ruby::ProbeRegistry.for(config)
          parsed.each do |entry|
            entry[:value].accept(Ruby::ResolutionPass.new(table, acc, probes: probes))
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
