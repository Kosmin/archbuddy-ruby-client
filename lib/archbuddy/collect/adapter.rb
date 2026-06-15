# frozen_string_literal: true

module Archbuddy
  module Collect
    # Result of an Adapter#collect run: neutral Raw* value objects in real
    # symbol space. This is the contract every language adapter must return —
    # the Anonymizer consumes it without knowing which language produced it.
    AdapterResult = Struct.new(:nodes, :edges, :entrypoints, keyword_init: true) do
      def initialize(*)
        super
        self.nodes       ||= []
        self.edges       ||= []
        self.entrypoints ||= []
      end
    end

    # Abstract Adapter — the language seam (D6).
    #
    # A future React/Node adapter implements this same interface: given a root
    # path and a Config, produce an AdapterResult of Raw* value objects. The
    # collector pipeline (Anonymizer + Emitter) is entirely language-agnostic.
    class Adapter
      attr_reader :root, :config

      def initialize(root, config)
        @root   = root
        @config = config
      end

      # @return [AdapterResult] neutral Raw* value objects (real symbol space).
      def collect
        raise NotImplementedError, "#{self.class}#collect must be implemented"
      end
    end
  end
end
