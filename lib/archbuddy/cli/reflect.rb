# frozen_string_literal: true

require "dry/cli"
require "json"
require "fileutils"
require_relative "../reflect"

module Archbuddy
  module CLI
    # `archbuddy reflect PATH` — BOOT REFLECTION.
    #
    # Boots the target application in its OWN process and records every method
    # its classes actually expose, including the ones static parsing can never
    # see because a macro generated them when the class body executed
    # (attr_accessor, has_many, delegate, scopes, define_method). On a Rails model
    # those are the majority of the public surface.
    #
    # Writes `.archbuddy/reflection.json`, which `collect` picks up automatically
    # on its next run. Requires only that the app BOOTS — no test suite, no
    # traffic, no fixtures.
    class Reflect < Dry::CLI::Command
      desc "Boot the app and record its real method table (finds macro-generated methods)"

      argument :path, required: true, desc: "Path to the application root"

      option :boot, desc: "Boot strategy: rails|sinatra|rackup|gem|require_glob (default: auto-detect)"
      option :command, desc: "Custom boot command; overrides --boot entirely"
      option :require, type: :array, default: [], desc: "Explicit file(s) to require before reflecting"
      option :eager, desc: "Ruby expression evaluated after the requires (e.g. an eager-load hook)"
      option :timeout, default: "300", desc: "Seconds to allow the app to boot"
      option :exec_prefix, desc: "Wrap the boot (e.g. 'devbox run --', 'nix develop -c'); auto-detected"

      def call(path:, boot: nil, command: nil, require: [], eager: nil, timeout: "300",
               exec_prefix: nil, **)
        root = File.expand_path(path)
        abort "archbuddy reflect: #{root} is not a directory" unless File.directory?(root)

        config = { "boot" => boot, "command" => command, "requires" => require, "eager" => eager }.compact
        strategy = Archbuddy::Reflect::Registry.for(root, config: config)
        result = Archbuddy::Reflect::Runner.new(root, strategy, timeout: timeout.to_i,
                                                exec_prefix: exec_prefix).run

        # A boot failure is NOT fatal to the tool, but it IS fatal to this
        # command: there is nothing to write. Exit non-zero so a CI step fails
        # loudly rather than silently producing no manifest.
        unless result.ok?
          warn result.error
          exit 1
        end

        out = File.join(root, ".archbuddy", "reflection.json")
        FileUtils.mkdir_p(File.dirname(out))
        File.write(out, JSON.pretty_generate(result.manifest))

        macros = Archbuddy::Reflect::MacroScan.scan(Dir.glob(File.join(root, "**", "*.rb")))
        table = Archbuddy::Reflect::MethodTable.from_manifest(result.manifest, macro_calls: macros)
        s = table.stats
        puts "wrote #{out}"
        puts "  strategy:         #{strategy.key}"
        puts "  classes:          #{s[:classes]}"
        puts "  methods:          #{s[:methods]}"
        puts "  proven crossings: #{s[:proven_crossings]}  (owned here, defined in a gem)"
        puts "  relations:        #{s[:relations]}  (has_many/belongs_to -> database exits)"
        puts "  trivial accessors:#{s[:trivial]}  (attr_* -> data access, not graph nodes)"
        puts "run `archbuddy collect #{path}` to fold these into the graph"
      end
    end
  end
end
