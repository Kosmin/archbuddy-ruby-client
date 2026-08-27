# frozen_string_literal: true

module Archbuddy
  module Reflect
    # HOW to get a target application loaded, so the reflection probe has classes
    # to reflect over.
    #
    # The probe itself is framework-AGNOSTIC — it walks loaded Modules and reads
    # `source_location`. NOTHING about it knows Rails. The only framework-specific
    # part of boot reflection is the loading step, so that is the ONLY thing this
    # abstraction varies. A strategy is declarative wherever possible:
    #
    #   requires   — paths to require, in order, relative to the project root
    #   eager      — an optional Ruby expression evaluated after the requires, for
    #                frameworks with an explicit eager-load hook
    #   command    — the escape hatch: an arbitrary shell command that boots the
    #                app in its own process, for anything the declarative form
    #                cannot express
    #
    # Adding a framework is a subclass with #detect? and #spec — no change to the
    # probe, the CLI, or the manifest format.
    class BootStrategy
      # @return [Symbol] stable identifier, recorded in the manifest for provenance
      def key
        raise NotImplementedError, "#{self.class} must implement #key"
      end

      # @param root [String] project root
      # @return [Boolean] whether this strategy applies to the project
      def detect?(_root)
        false
      end

      # @return [Hash] { requires: [String], eager: String|nil, command: String|nil }
      def spec(_root)
        { requires: [], eager: nil, command: nil }
      end

      # Human-facing one-liner used in the loud-skip message when boot fails, so a
      # user is told what was ATTEMPTED rather than just that something broke.
      def describe(root)
        s = spec(root)
        return "runs: #{s[:command]}" if s[:command]

        parts = ["requires #{s[:requires].join(', ')}"]
        parts << "then #{s[:eager]}" if s[:eager]
        parts.join(", ")
      end
    end

    # Rails: config/environment.rb boots the app; eager_load! forces every class
    # body to execute, which is what materialises has_many/attr_accessor/scopes.
    class RailsBoot < BootStrategy
      def key = :rails

      def detect?(root)
        File.file?(File.join(root, "config", "environment.rb"))
      end

      def spec(_root)
        { requires: ["config/environment"],
          eager: "Rails.application.eager_load! if defined?(Rails)",
          command: nil }
      end
    end

    # Sinatra (and most rack apps): a single entry file that defines the app.
    # config.ru is Rack DSL rather than plain Ruby, so we prefer a real entry file
    # and fall back to evaluating config.ru through Rack::Builder.
    class SinatraBoot < BootStrategy
      ENTRIES = %w[app.rb application.rb server.rb main.rb].freeze

      def key = :sinatra

      def detect?(root)
        gemfile = File.join(root, "Gemfile")
        looks_sinatra = File.file?(gemfile) && File.read(gemfile).match?(/^\s*gem\s+["']sinatra["']/)
        looks_sinatra && ENTRIES.any? { |e| File.file?(File.join(root, e)) }
      rescue StandardError
        false
      end

      def spec(root)
        entry = ENTRIES.find { |e| File.file?(File.join(root, e)) }
        { requires: [entry].compact, eager: nil, command: nil }
      end
    end

    # Generic Rack: no framework detected but a config.ru exists.
    class RackupBoot < BootStrategy
      def key = :rackup

      def detect?(root)
        File.file?(File.join(root, "config.ru"))
      end

      def spec(_root)
        { requires: [],
          eager: 'require "rack"; Rack::Builder.parse_file("config.ru")',
          command: nil }
      end
    end

    # A packaged gem: require the gemspec's entry point, then every lib file, so
    # classes that autoload lazily are still materialised.
    class GemBoot < BootStrategy
      def key = :gem

      def detect?(root)
        !Dir.glob(File.join(root, "*.gemspec")).empty?
      end

      def spec(_root)
        { requires: [],
          eager: 'Dir.glob(File.join(root, "lib", "**", "*.rb")).sort.each { |f| require f rescue nil }',
          command: nil }
      end
    end

    # Last resort for a plain Ruby project: require every .rb under the source
    # dirs. Least precise (load-order errors are swallowed per-file) but needs no
    # framework at all.
    class RequireGlobBoot < BootStrategy
      def key = :require_glob

      def detect?(_root) = true   # always applicable; ordered LAST in the registry

      def spec(_root)
        { requires: [],
          eager: 'Dir.glob(File.join(root, "{lib,app,src}", "**", "*.rb")).sort.each { |f| require f rescue nil }',
          command: nil }
      end
    end

    # User-supplied, from config. Either an explicit require list + eager
    # expression, or a full shell command. Always wins over detection.
    class CustomBoot < BootStrategy
      def initialize(requires: [], eager: nil, command: nil)
        @requires = Array(requires)
        @eager = eager
        @command = command
        super()
      end

      def key = :custom
      def detect?(_root) = true
      def spec(_root) = { requires: @requires, eager: @eager, command: @command }
    end
  end
end
