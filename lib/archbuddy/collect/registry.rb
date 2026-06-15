# frozen_string_literal: true

module Archbuddy
  module Collect
    # One-line language wiring (D6). Adding a language is one entry here pointing
    # at its Adapter subclass — the rest of the pipeline is language-agnostic.
    module Registry
      ADAPTERS = {
        "ruby" => Adapters::RubyAdapter
      }.freeze

      module_function

      def for(language)
        ADAPTERS.fetch(language) do
          raise ArgumentError, "no adapter registered for language #{language.inspect}; " \
                               "known: #{ADAPTERS.keys.inspect}"
        end
      end
    end
  end
end
