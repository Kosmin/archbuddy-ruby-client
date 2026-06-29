# frozen_string_literal: true

require "prism"
require_relative "vocab"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Per-AR-call sink descriptor (V4/P4). Pure: given one resolved AR
        # `Prism::CallNode`, classify the call's effect (op_kind) and, for
        # field-bearing writes, its write `specificity`:
        #
        #   specific    => the written field set is a STATICALLY-ENUMERABLE
        #                  symbol-keyed literal hash / bare symbols
        #                  (e.g. `update(name: x, email: y)` / `update_columns(:a, :b)`).
        #   open_ended  => the field set is NOT statically knowable: a variable
        #                  hash (`update(attrs)`), a `**splat`, a non-symbol key,
        #                  or a string/SQL payload (`update_all("status='x'")`).
        #
        # This is the bit the engine's V4 sink multiplier gates on (P2): an
        # open_ended WRITE sink hit by undifferentiated fan-in is the customizable
        # sink that gets charged; reads, destroys, no-field writes, and
        # distinctly-specified writes are factor 1. Per G1/CR-3 the collector
        # emits ONLY the derived `sink_open` boolean on the graph node; op_kind /
        # specificity are computed here purely to DERIVE it (the engine reads
        # `sink_open?` + topology, never these intermediate fields).
        #
        # The SAFE direction (research P4): DEFAULT to open_ended whenever the
        # argument shape is not provably a symbol-keyed literal hash / bare
        # symbol — never under-charge a sink that some caller can mass-assign.
        module DbOpSpec
          Spec = Struct.new(:op_kind, :specificity, keyword_init: true) do
            # The per-call open_ended-write bit the aggregate ORs together.
            def open_ended_write?
              op_kind == "write" && specificity == "open_ended"
            end
          end

          module_function

          # @param node [Prism::CallNode] a resolved AR call site.
          # @return [Spec]
          def for_call(node)
            name    = node.name.to_s
            op_kind = Vocab.ar_op_kind(name)

            # Reads, destroys, and writes that carry no inspectable field payload
            # (save/touch/find_or_create_by) have no specificity concern → n/a
            # (engine factor 1).
            return Spec.new(op_kind: op_kind, specificity: nil) unless Vocab.ar_field_write?(name)

            args = node.arguments&.arguments || []
            Spec.new(op_kind: op_kind, specificity: specificity_for(args))
          end

          # A field-write is "specific" only when EVERY argument is a
          # statically-enumerable field reference (symbol-keyed literal hash or
          # bare symbol). Any other shape → open_ended (SAFE default).
          def specificity_for(args)
            return "specific" if args.empty? # bare field-write touches no unknown columns

            open_ended = args.any? { |arg| open_ended_arg?(arg) }
            open_ended ? "open_ended" : "specific"
          end

          def open_ended_arg?(arg)
            case arg
            when Prism::KeywordHashNode, Prism::HashNode
              # Open iff any element is a splat (**x) or a non-symbol key.
              arg.elements.any? do |el|
                !(el.is_a?(Prism::AssocNode) && el.key.is_a?(Prism::SymbolNode))
              end
            when Prism::SymbolNode
              false # bare symbol field, e.g. update_columns(:a, :b)
            else
              # variable / call / ivar / splat / string-SQL / interpolation → open
              true
            end
          end
        end
      end
    end
  end
end
