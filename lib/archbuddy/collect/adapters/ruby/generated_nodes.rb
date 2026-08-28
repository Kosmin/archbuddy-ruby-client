# frozen_string_literal: true

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # WHICH MACRO-GENERATED METHODS DESERVE A GRAPH NODE, and what each one
        # calls.
        #
        # A method a macro produced has no `def` in source, so the definition
        # pass never mints a node for it. Measured on one service that is 888
        # application functions absent from the graph entirely — and, because
        # `reflect_internal` refuses to draw an edge to a node that was never
        # parsed, 2,277 receiverless call sites left unresolved for want of a
        # target that does exist in the running program.
        #
        # THIS IS NOT INVENTING NODES. Every method minted here is one the
        # BOOTED APPLICATION owns, at a definition site inside application
        # source, on a class the static pass already parsed. Reflection says the
        # method exists; the macro call site is in the source a reader can open.
        # What we decline to do is mint a node for a method whose owning class we
        # never parsed — that is someone else's code, and anchoring a node there
        # would put a file/line in the id-map that points at nothing.
        #
        # SEPARATE FROM THE ADAPTER because this is a POLICY question ("does this
        # method belong in the graph?") and the adapter's job is construction.
        # Keeping it here means the four rules below can be read, and tested,
        # without building a symbol table or a RawNode.
        module GeneratedNodes
          # `fq`         — where the node lives (owner-based, matching R3.5)
          # `forwards_to`— fq of the method this one calls on self, or nil.
          #                The SECOND hop (`via`, on the forwarded receiver) is
          #                deliberately NOT represented: its receiver's type is
          #                exactly what we do not know, and naming a target for
          #                it would be the guess this whole design refuses.
          Minted = Struct.new(:fq, :owner, :name, :scope, :rel_file, :line, :macro,
                              :forwards_to, keyword_init: true)

          module_function

          # @param reflection [Reflect::MethodTable]
          # @param forwarding [Reflect::Forwarding::Table]
          # @param table [Ruby::SymbolTable] the static parse
          # @return [Array<Minted>]
          def build(reflection:, forwarding:, table:)
            return [] if reflection.nil?

            seen = {}
            reflection.app_methods.each do |f|
              fq = f.target_fq
              next if fq.nil?           # no owner recorded — nothing to anchor
              next if seen.key?(fq)     # one node per fq, first wins
              next if table.method?(fq) # the static pass already has it: a real `def`
              next unless table.class_for(f.owner) # owner never parsed — not ours to mint

              seen[fq] = Minted.new(
                fq: fq, owner: f.owner, name: f.name, scope: f.scope,
                rel_file: f.file, line: f.line, macro: f.macro,
                forwards_to: forwarding&.fact(f.cls, f.name)&.to
              )
            end
            resolve_forwards!(seen, table)
          end

          # SECOND PASS, and it has to be second. `delegate :merchant, to: :program`
          # sitting next to `delegate :program, to: :earn` means one generated
          # method forwards to another — so a target checked against the static
          # table alone would be dropped precisely in the chained case this
          # exists to recover. Targets therefore resolve against static nodes
          # UNION the ones just minted.
          #
          # `to` is called on SELF inside the generated body, so it names an
          # instance method of the owner. A target we still cannot find leaves
          # `forwards_to` nil: an edge to nowhere is worse than no edge, and the
          # unresolved-call accounting already reports the gap.
          def resolve_forwards!(seen, table)
            seen.each_value do |m|
              next if m.forwards_to.nil?

              fq = "#{m.owner}##{m.forwards_to}"
              m.forwards_to = (table.method?(fq) || seen.key?(fq)) ? fq : nil
            end
            seen.values
          end
        end
      end
    end
  end
end
