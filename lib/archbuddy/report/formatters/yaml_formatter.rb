# frozen_string_literal: true

require "architecture_auditor"
require_relative "../formatter"
require_relative "structured_export"

module Archbuddy
  module Report
    module Formatters
      # De-anonymized YAML export (SECRET/local-only — contains real symbols).
      # Serialized deterministically via the contract Serializer (D30) so the
      # output is stable and diffable.
      class YamlFormatter < Formatter
        def render
          doc = StructuredExport.build(context, metric_keys)
          ArchitectureAuditor::Contract::Serializer.dump(doc)
        end
      end
    end
  end
end

Archbuddy::Report::Formatter.register(
  "yaml", Archbuddy::Report::Formatters::YamlFormatter
)
