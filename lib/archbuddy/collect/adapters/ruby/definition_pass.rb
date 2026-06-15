# frozen_string_literal: true

require "prism"
require_relative "symbol_table"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Pass 1 (D23): walk class/module/def nodes building a SymbolTable of
        # fully-qualified symbols plus class metadata (superclass, controller?,
        # active_record?). Receiver shape is read here only to classify a def as
        # singleton (`Foo.x`) vs instance (`Foo#x`).
        #
        # One pass instance per file; the same SymbolTable is shared across files
        # so cross-file resolution works in Pass 2.
        class DefinitionPass < Prism::Visitor
          def initialize(symbol_table, rel_file)
            @table     = symbol_table
            @rel_file  = rel_file
            @namespace = [] # stack of constant name segments (e.g. ["Billing", "Invoice"])
            super()
          end

          def visit_module_node(node)
            name = constant_name(node.constant_path)
            push_namespace(name) do
              register_class(node, superclass: nil)
              super
            end
          end

          def visit_class_node(node)
            name = constant_name(node.constant_path)
            push_namespace(name) do
              register_class(node, superclass: node.superclass && constant_name(node.superclass))
              super
            end
          end

          def visit_def_node(node)
            singleton = !node.receiver.nil?
            owner_fq  = current_namespace
            sep       = singleton ? "." : "#"
            # A top-level def (no enclosing class) is owner-less; its fq symbol is
            # just the bare method name so resolution can still reference it.
            fq_symbol =
              if owner_fq.empty?
                node.name.to_s
              else
                "#{owner_fq}#{sep}#{node.name}"
              end

            @table.add_method(
              SymbolTable::MethodEntry.new(
                fq_symbol: fq_symbol,
                owner_fq:  owner_fq.empty? ? nil : owner_fq,
                name:      node.name.to_s,
                singleton: singleton,
                rel_file:  @rel_file,
                line:      node.location.start_line
              )
            )
            super
          end

          private

          def register_class(node, superclass:)
            fq = current_namespace
            return if fq.empty?

            @table.add_class(
              SymbolTable::ClassEntry.new(
                fq_name:    fq,
                rel_file:   @rel_file,
                line:       node.location.start_line,
                superclass: superclass
              )
            )
          end

          def push_namespace(name)
            @namespace.push(name)
            yield
          ensure
            @namespace.pop
          end

          def current_namespace
            @namespace.join("::")
          end

          # Render a constant path/read node to its source name
          # (e.g. "Billing::Invoice", "ApplicationRecord").
          def constant_name(const_node)
            const_node.slice
          end
        end
      end
    end
  end
end
