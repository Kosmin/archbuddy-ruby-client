# frozen_string_literal: true

require "prism"

module Archbuddy
  module Reflect
    # Constants ASSIGNED in application source: `COLORS = [...]`, `Purchase::STATUS = {...}`.
    #
    # WHY THIS EXISTS ALONGSIDE THE BOOT PROBE. `TracePoint(:class)` reports every
    # class and module body the interpreter opens, with its file — authoritative
    # provenance for anything that IS a class or module. It is structurally blind
    # to every other constant: an array, a hash, a frozen string, a configured
    # client object never opens a class body, so no runtime hook reports it.
    # Measured consequence of relying on the probe alone: `DATADOG_METRICS` (97
    # call sites) and `COLORS` (47) were classified as EXITS from the very app
    # that defines them.
    #
    # The two sources are COMPLEMENTARY, not alternatives:
    #   probe  -> classes/modules, with file provenance, including dynamic ones
    #   here   -> plain constants, which no runtime hook can see
    #
    # This also has to live on the ARCHBUDDY side rather than in the probe: the
    # probe executes inside the TARGET's Ruby (a Rails app may be on 2.7, which
    # ships no Prism), so it must stay stdlib-only.
    module ConstantScan
      module_function

      # @return [Hash{String => String}] constant path => relative file
      def scan(root, dirs: %w[app lib config])
        root = File.expand_path(root)
        out = {}
        dirs.each do |d|
          Dir.glob(File.join(root, d, "**", "*.rb")).each do |file|
            harvest(file, root, out)
          end
        end
        out
      end

      def harvest(file, root, out)
        src = File.read(file)
        res = Prism.parse(src)
        rel = file.sub("#{root}/", "")
        ns = []
        walk = lambda do |n|
          return unless n.is_a?(Prism::Node)

          if n.is_a?(Prism::ModuleNode) || n.is_a?(Prism::ClassNode)
            ns.push(n.constant_path.slice.sub(/\A::/, ""))
            n.compact_child_nodes.each { |c| walk.call(c) }
            ns.pop
            return
          end
          record(n, ns, rel, out)
          n.compact_child_nodes.each { |c| walk.call(c) }
        end
        walk.call(res.value)
        out
      rescue StandardError
        out
      end

      # Both spellings are recorded — bare and namespace-qualified — because a
      # reference may appear either way and Ruby resolves the bare form through
      # lexical nesting.
      def record(node, ns, rel, out)
        case node
        when Prism::ConstantWriteNode
          name = node.name.to_s
          out[name] ||= rel
          out[(ns + [name]).join("::")] ||= rel unless ns.empty?
        when Prism::ConstantPathWriteNode
          out[node.target.slice.to_s.sub(/\A::/, "")] ||= rel
        end
      end
    end
  end
end
