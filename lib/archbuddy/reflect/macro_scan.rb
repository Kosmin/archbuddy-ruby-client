# frozen_string_literal: true

require "prism"

module Archbuddy
  module Reflect
    # Harvests macro CALL SITES from source: class => generated-method-name => macro.
    #
    # Attribution must come from the call site the developer WROTE (`has_many
    # :line_items` in the model), never from the generated method's
    # `source_location` — for an ActiveRecord association that location points
    # inside the gem, which can never yield the word "has_many". Matching the
    # reflected method NAME against the macro's symbol ARGUMENTS works regardless
    # of where the generating code lives.
    module MacroScan
      KNOWN = %w[attr_accessor attr_reader attr_writer has_many has_one belongs_to
                 has_and_belongs_to_many delegate scope def_delegator def_delegators].freeze
      WRITER_MACROS = %w[attr_accessor attr_writer].freeze
      # Macros that FORWARD: the generated method calls the same-named method on
      # another object, named by the `to:` keyword.
      FORWARDING_MACROS = %w[delegate def_delegator def_delegators].freeze

      # Both outputs of one pass over the sources. They answer different
      # questions — "which macro made this method" (attribution) versus "where
      # does this method forward to" (a call edge) — and are kept apart for that
      # reason, but they are harvested together because re-globbing and
      # re-parsing an entire application to ask the second question would double
      # the cost of every collect.
      Result = Struct.new(:macros, :delegations, keyword_init: true)

      module_function

      # @return [Hash{String => Hash{String => String}}] class => method => macro
      def scan(files, read: ->(f) { File.read(f) })
        scan_all(files, read: read).macros
      end

      # @return [Result] `macros` as above; `delegations` is class => method =>
      #   the `to:` TARGET METHOD NAME the developer wrote.
      def scan_all(files, read: ->(f) { File.read(f) })
        out = Hash.new { |h, k| h[k] = {} }
        del = Hash.new { |h, k| h[k] = {} }
        files.each do |f|
          src = begin
            read.call(f)
          rescue StandardError
            next
          end
          harvest(src, out, del)
        end
        Result.new(macros: out, delegations: del)
      end

      def harvest(src, out, del = Hash.new { |h, k| h[k] = {} })
        res = begin
          Prism.parse(src)
        rescue StandardError
          return out
        end
        ns = []
        walk = lambda do |n|
          return unless n.is_a?(Prism::Node)

          if n.is_a?(Prism::ModuleNode) || n.is_a?(Prism::ClassNode)
            ns.push(n.constant_path.slice)
            n.compact_child_nodes.each { |c| walk.call(c) }
            ns.pop
            return
          end
          record(n, ns, out, del) if n.is_a?(Prism::CallNode)
          n.compact_child_nodes.each { |c| walk.call(c) }
        end
        walk.call(res.value)
        out
      end

      def record(node, ns, out, del = Hash.new { |h, k| h[k] = {} })
        macro = node.name.to_s
        return unless KNOWN.include?(macro) && !ns.empty?

        cls    = ns.join("::")
        target = FORWARDING_MACROS.include?(macro) ? delegation_target(node) : nil
        (node.arguments&.arguments || []).grep(Prism::SymbolNode).each do |sym|
          name = sym.unescaped.to_s
          out[cls][name] = macro
          out[cls]["#{name}="] = macro if WRITER_MACROS.include?(macro)
          del[cls][name] = target if target
        end
      end

      # The `to:` argument of a delegation macro, when it names a METHOD.
      #
      # `delegate :merchant, to: :purchase` means the generated `merchant` calls
      # `purchase` and then `merchant` on the result — a call edge the parser can
      # read straight off the source the developer wrote, with no boot required.
      #
      # DECLINES rather than guesses on every other form. `to: :class`,
      # `to: Foo`, and a string target all reach a receiver that is not a method
      # on this class, so naming one would invent an edge. Absent is the honest
      # answer; the bytecode tier can still recover those cases from the method
      # the macro actually produced.
      def delegation_target(node)
        kw = (node.arguments&.arguments || []).grep(Prism::KeywordHashNode).first
        return nil unless kw

        pair = kw.elements.grep(Prism::AssocNode).find do |a|
          a.key.is_a?(Prism::SymbolNode) && a.key.unescaped.to_s == "to"
        end
        return nil unless pair&.value.is_a?(Prism::SymbolNode)

        target = pair.value.unescaped.to_s
        # `to: :class` delegates to the receiver's CLASS, not to a sibling
        # method — a different kind of hop, and one this rule must not claim.
        target == "class" ? nil : target
      end
    end
  end
end
