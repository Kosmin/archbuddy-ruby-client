# frozen_string_literal: true

module Archbuddy
  module Review
    # The review-side formatter registry (P5) — a SEPARATE class from the
    # report registry (R1 §2: registering review formats there would force
    # cross-nil-tolerance). Same open/closed pattern verbatim.
    class Formatter
      # The one render-input struct both commands build (R30 home).
      # Members nil per mode: :use_cases is diff-nil; :review_surface /
      # :disclosures are lint-nil; :delta_summary/:delta_top/:delta_index
      # lint-nil ([S:F11] — delta_index feeds node findings' values only).
      ReviewContext = Struct.new(
        :command, :target, :config_path, :advisory, :fail_level, :base, :head,
        :findings, :grandfathered, :not_evaluable, :delta_summary, :delta_top,
        :ratchet, :excluded_files, :calibration, :exit_code, :tool, :delta_index,
        :use_cases, :review_surface, :disclosures,
        keyword_init: true
      )

      FORMATS = {}

      class << self
        def register(name, klass)
          FORMATS[name.to_s] = klass
        end

        def for(name)
          FORMATS.fetch(name.to_s) do
            raise ArgumentError,
                  "unknown format #{name.inspect}; available: #{FORMATS.keys.sort.join(', ')}"
          end
        end

        def registered
          FORMATS.keys.sort
        end
      end

      # @param context [ReviewContext]
      def initialize(context)
        @context = context
      end

      def render
        raise NotImplementedError, "#{self.class} must implement #render"
      end

      private

      attr_reader :context

      # Deterministic finding order: severity rank desc, file, symbol
      # (nil file/symbol — the :pr findings — sort last).
      def sorted_findings
        rank = Config::Schema::SEVERITIES
        (context.findings || []).sort_by do |f|
          [-rank.fetch(f.severity, 0), f.file.to_s, f.symbol.to_s]
        end
      end

      def counts
        tally = { error: 0, warn: 0, info: 0 }
        (context.findings || []).each do |f|
          tally[f.severity] += 1 if tally.key?(f.severity)
        end
        tally
      end
    end
  end
end
