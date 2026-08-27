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

      module_function

      # @return [Hash{String => Hash{String => String}}]
      def scan(files, read: ->(f) { File.read(f) })
        out = Hash.new { |h, k| h[k] = {} }
        files.each do |f|
          src = begin
            read.call(f)
          rescue StandardError
            next
          end
          harvest(src, out)
        end
        out
      end

      def harvest(src, out)
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
          record(n, ns, out) if n.is_a?(Prism::CallNode)
          n.compact_child_nodes.each { |c| walk.call(c) }
        end
        walk.call(res.value)
        out
      end

      def record(node, ns, out)
        macro = node.name.to_s
        return unless KNOWN.include?(macro) && !ns.empty?

        cls = ns.join("::")
        (node.arguments&.arguments || []).grep(Prism::SymbolNode).each do |sym|
          name = sym.unescaped.to_s
          out[cls][name] = macro
          out[cls]["#{name}="] = macro if WRITER_MACROS.include?(macro)
        end
      end
    end
  end
end
