# frozen_string_literal: true

require "json"
require "shellwords"
require "tmpdir"

module Archbuddy
  module Reflect
    # Boots the target app IN ITS OWN PROCESS and reads back the manifest.
    #
    # Runs out-of-process deliberately: the target app has its own Gemfile, its
    # own Ruby, and may conflict with archbuddy's dependencies. archbuddy stays a
    # static tool that never loads foreign code into itself — it shells out, and
    # the only thing that crosses back is a JSON file.
    #
    # Failure is LOUD and NON-FATAL: reflection is an ENRICHMENT of the static
    # graph, never a prerequisite, so a project that will not boot still collects
    # statically and is TOLD what was skipped and why.
    class Runner
      Result = Struct.new(:manifest, :strategy, :ok, :error, keyword_init: true) do
        def ok? = ok
      end

      PROBE = File.expand_path("probe.rb", __dir__)

      def initialize(root, strategy, timeout: 300, logger: nil)
        @root = File.expand_path(root)
        @strategy = strategy
        @timeout = timeout
        @logger = logger || ->(msg) { warn msg }
      end

      def run
        out = File.join(Dir.mktmpdir("archbuddy-reflect"), "reflection.json")
        cmd = command_for(out)
        @logger.call("reflect: booting via #{@strategy.key} (#{@strategy.describe(@root)})")
        # stderr is CAPTURED, not discarded: a skip that cannot say WHY is only
        # half-loud, and the boot error is the single most useful thing a user
        # needs in order to fix their reflect config.
        err_file = "#{out}.err"
        ok = system(cmd, chdir: @root, out: File::NULL, err: err_file)
        unless ok && File.file?(out)
          reason = File.file?(err_file) ? File.read(err_file).lines.first(3).join.strip : ""
          msg = "reflect: SKIPPED — the app did not boot under strategy '#{@strategy.key}'. " \
                "Static collection continues; generated methods (attr_*/has_many/delegate/scopes) " \
                "will be ABSENT from this graph, not zero. Re-run with reflect.boot set explicitly, " \
                "or reflect.command for a custom boot." +
                (reason.empty? ? "" : "\n  boot error: #{reason}")
          @logger.call(msg)
          return Result.new(manifest: nil, strategy: @strategy, ok: false, error: msg)
        end
        Result.new(manifest: JSON.parse(File.read(out)), strategy: @strategy, ok: true, error: nil)
      end

      private

      # Bundler is used ONLY when the project actually has a lockfile. A plain
      # Ruby project (no Gemfile.lock) would fail under `bundle exec`, and that
      # failure would look like "the app does not boot" when the real cause is
      # our own assumption.
      def ruby_prefix
        File.file?(File.join(@root, "Gemfile.lock")) ? "bundle exec ruby" : "ruby"
      end

      def command_for(out)
        spec = @strategy.spec(@root)
        return "#{spec[:command]} && cp .archbuddy/reflection.json #{Shellwords.escape(out)}" if spec[:command]

        script = +""
        script << "root = #{@root.dump}\n"
        spec[:requires].each { |r| script << "require File.join(root, #{r.dump})\n" }
        script << "#{spec[:eager]}\n" if spec[:eager]
        script << "ENV['ARCHBUDDY_REFLECT_ROOT'] = root\n"
        script << "ENV['ARCHBUDDY_REFLECT_OUT'] = #{out.dump}\n"
        script << "require #{PROBE.dump}\n"
        "#{ruby_prefix} -e #{Shellwords.escape(script)}"
      end
    end
  end
end
