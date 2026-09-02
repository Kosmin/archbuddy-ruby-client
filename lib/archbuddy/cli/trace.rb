# frozen_string_literal: true

require "dry/cli"
require "shellwords"
require_relative "../reflect"

module Archbuddy
  module CLI
    # `archbuddy trace PATH -- <command>` — OBSERVE what bag-backed receivers
    # actually return.
    #
    # WHY A WRAPPER AND NOT A BOOT. Every other probe in this tool boots the app
    # and asks it questions; that is enough for anything a CLASS knows. It is not
    # enough here. `context.merchant` has no method to find — the value was put
    # into an instance hash by a caller in another file — so the only way to
    # learn its type is to be present while the code RUNS. This command therefore
    # wraps whatever the project already uses to run code (its test suite, a rake
    # task, a script) rather than trying to drive the app itself.
    #
    # WHAT IT COSTS. Almost nothing, and that is a deliberate design result
    # rather than luck: the probe attaches TARGETED TracePoints, one per bag
    # source's `method_missing`, so the VM fires the hook for that method alone.
    # Measured on a real service, 1.0x wall clock against 4.3x for a global
    # `:return` trace over the same workload.
    #
    # WHAT IT IS BOUNDED BY. What executes. An untested path contributes nothing,
    # which is the honest trade for the one fact static analysis cannot reach —
    # and the reason the result is written to its own file that nothing requires.
    class Trace < Dry::CLI::Command
      desc "Run a command with receiver-type tracing enabled (needs `archbuddy reflect` first)"

      argument :path, required: true, desc: "Path to the application root"
      option :out, desc: "Output path (default: PATH/.archbuddy/receiver_types.json)"

      example [
        "~/app -- bundle exec rspec",
        "~/app -- bin/rails runner 'SomeInteractor.call(id: 1)'"
      ]

      def call(path:, out: nil, args: [], **)
        root = File.expand_path(path)
        abort "archbuddy trace: #{root} is not a directory" unless File.directory?(root)

        command = args.dup
        command.shift if command.first == "--"
        abort usage_hint if command.empty?

        preflight(root)

        probe = File.expand_path("../reflect/trace_probe.rb", __dir__)
        target_out = out || File.join(root, ".archbuddy", "receiver_types.json")

        # OUR OWN RUBY MUST NOT FOLLOW US IN. archbuddy runs on one Ruby and the
        # traced project on another; inheriting our GEM_HOME/BUNDLE_*/RBENV_*
        # made a Ruby 2.7 target load OUR bundler and die on `rubygems/uri`,
        # which reads as "the project is broken" rather than "we poisoned it".
        # Same variables, same reason, as Reflect::Runner strips.
        stripped = Archbuddy::Reflect::Runner::LEAKY_VARS.to_h { |k| [k, nil] }
        env = stripped.merge(
          "ARCHBUDDY_TRACE"      => "1",
          "ARCHBUDDY_TRACE_ROOT" => root,
          "ARCHBUDDY_TRACE_OUT"  => target_out,
          # The probe goes in via RUBYOPT, which is one of the variables we just
          # cleared — so it is set AFTER the merge, deliberately.
          "RUBYOPT"              => "-r#{probe}"
        )

        warn "archbuddy trace: running `#{command.join(' ')}` with receiver tracing"
        system(env, *command, chdir: root)
        report(target_out)
      end

      private

      # The bag-source list comes from the boot manifest, so a missing or
      # unclassified manifest means the probe would attach to nothing. Said
      # plainly here rather than discovered as an empty result.
      def preflight(root)
        manifest = File.join(root, ".archbuddy", "reflection.json")
        return warn "archbuddy trace: no #{manifest} — run `archbuddy reflect` first" unless File.file?(manifest)

        sources = ArchbuddyTraceProbe.bag_sources(root)
        return warn "archbuddy trace: reflection.json lists no `bag` sources; nothing to trace" if sources.empty?

        warn "archbuddy trace: watching method_missing on #{sources.length} bag source(s): #{sources.join(', ')}"
      end

      def report(out)
        types = Archbuddy::Reflect::ReceiverTypes.from_file(out)
        if types.empty?
          warn "archbuddy trace: no receiver types observed. The traced command may not have " \
               "exercised any bag-backed receiver — a trace only sees what runs."
          return
        end

        s = types.stats
        puts "wrote #{out}"
        puts "  (receiver, name) pairs: #{s[:pairs]}"
        puts "  single observed type:   #{s[:unambiguous]}  (usable to type a receiver)"
        puts "  AMBIGUOUS:              #{s[:ambiguous]}  (more than one type seen — left unresolved, not guessed)"
        puts "  unattached bag sources: #{s[:unattached]}" if s[:unattached].positive?
      end

      def usage_hint
        "archbuddy trace: give a command to run, e.g.\n" \
          "  archbuddy trace . -- bundle exec rspec\n" \
          "A trace can only observe what executes, so the command IS the coverage."
      end
    end
  end
end
