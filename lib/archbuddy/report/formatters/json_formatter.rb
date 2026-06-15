# frozen_string_literal: true

require "json"
require_relative "../formatter"
require_relative "structured_export"

module Archbuddy
  module Report
    module Formatters
      # De-anonymized JSON export (SECRET/local-only — contains real symbols).
      # Pretty-printed for human/local consumption.
      class JsonFormatter < Formatter
        def render
          doc = StructuredExport.build(context, metric_keys)
          "#{JSON.pretty_generate(doc)}\n"
        end
      end
    end
  end
end

Archbuddy::Report::Formatter.register(
  "json", Archbuddy::Report::Formatters::JsonFormatter
)
