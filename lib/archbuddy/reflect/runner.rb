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

      # @param exec_prefix [String, nil] a command that wraps the boot, for
      #   projects whose toolchain is not on the ambient PATH — `devbox run --`,
      #   `nix develop -c`, `asdf exec`, `docker compose run --rm app`. The probe
      #   must execute in the TARGET's Ruby (a Rails app may be on 2.7 while
      #   archbuddy runs on 3.4), and that Ruby frequently only exists inside such
      #   an environment. Auto-detected from the project when not given.
      def initialize(root, strategy, timeout: 300, logger: nil, exec_prefix: nil)
        @root = File.expand_path(root)
        @strategy = strategy
        @timeout = timeout
        @logger = logger || ->(msg) { warn msg }
        @exec_prefix = exec_prefix || self.class.detect_prefix(@root)
      end

      # Detection is a convenience only — an explicit prefix always wins, and a
      # project with none simply runs bare, exactly as before.
      def self.detect_prefix(root)
        return "devbox run --" if File.file?(File.join(root, "devbox.json"))
        return "nix develop -c" if File.file?(File.join(root, "flake.nix"))

        nil
      end

      def run
        out = File.join(Dir.mktmpdir("archbuddy-reflect"), "reflection.json")
        cmd = command_for(out)
        via = @exec_prefix ? "#{@strategy.key} inside `#{@exec_prefix}`" : @strategy.key.to_s
        @logger.call("reflect: booting via #{via} (#{@strategy.describe(@root)})")
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
        base = File.file?(File.join(@root, "Gemfile.lock")) ? "bundle exec ruby" : "ruby"
        @exec_prefix ? "#{@exec_prefix} #{base}" : base
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

        # Written to a FILE rather than passed via `ruby -e`.
        # An exec wrapper re-splits its arguments, so a multi-line -e script is
        # mangled before Ruby ever sees it — observed with `devbox run --`, which
        # broke the script at the first newline and reported only a syntax caret.
        # A file has no quoting surface at all and behaves identically under every
        # wrapper.
        path = "#{out}.boot.rb"
        File.write(path, script)
        "#{ruby_prefix} #{Shellwords.escape(path)}"
      end
    end
  end
end
