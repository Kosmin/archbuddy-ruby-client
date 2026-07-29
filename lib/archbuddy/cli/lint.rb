# frozen_string_literal: true

require "dry/cli"
require "tmpdir"
require "fileutils"
require_relative "../review"

module Archbuddy
  module CLI
    # `archbuddy lint [TARGET]` — the whole-vintage review (v0.15 P1-T7).
    # Pipeline: validate target → Config.load → Todo.load (R14) →
    # VintageSource.head (R6 — the SAME acquisition seam as diff) →
    # RuleEngine.evaluate(delta: nil) → ReviewContext incl. the :use_cases
    # member (I-C5': the always-on Q9 leaderboard over the SAME memoized
    # vintage.graph the engine folds — §5-C31 one-computation) → ONE document
    # on stdout → exit via `Findings#exit_code` (L3 advisory default).
    #
    # Zero-ep honesty (Q8): `use_cases: {count: 0, leaderboard: []}`,
    # `unreachable: nil`, and the Q8 note on stderr — NEVER an
    # all-unreachable disclosure. 0-node precedence: the [S] empty-vintage
    # warning WINS and the Q8 note is suppressed.
    #
    # CLEAN-STDOUT (P5): stdout receives EXACTLY ONE write — the rendered
    # document; chatter goes to stderr with error:/warning:/note: prefixes.
    class Lint < Dry::CLI::Command
      desc "Review the current architecture vintage against the 8-rule family " \
           "(advisory unless a config file or --fail-level gates)"

      argument :target, required: false, default: ".",
                        desc: "Target directory (default: .)"

      option :format, desc: "Output format: terminal|markdown|json (default: config all.format, else terminal)"
      option :config, desc: "Path to the .archbuddy.yml config file"
      option :trust_cache, type: :boolean, default: false,
                           desc: "Trust the working-tree cache WITHOUT a freshness check"
      option :fail_level, desc: "Gate at this severity: none|info|warn|error"
      option :advisory, type: :boolean, default: false, desc: "Never gate (= --fail-level none)"
      option :todo, desc: "Path to the value-pinned todo document"
      option :no_todo, type: :boolean, default: false, desc: "Ignore any todo document"
      option :auto_gen_todo, type: :boolean, default: false,
                             desc: "Regenerate the todo from current breaching findings (P1-T8)"
      option :stamp, type: :boolean, default: false,
                     desc: "Stamp the generated todo with the invocation line (with --auto-gen-todo)"

      FAIL_LEVELS = %w[none info warn error].freeze

      def call(target: ".", **opts)
        run(target, opts)
      rescue Config::ValidationError, Review::VintageError => e
        warn e.message.start_with?("error:") ? e.message : "error: #{e.message}"
        exit 2
      rescue StandardError => e
        warn "error: #{e.class}: #{e.message}"
        warn e.backtrace.join("\n") if ENV["ARCHBUDDY_DEBUG"] == "1"
        exit 2
      end

      private

      def run(target_arg, opts)
        validate_flags!(opts)
        target = validate_target!(target_arg)
        config = Config.load(target_root: target, config_path: opts[:config],
                             cli: cli_overrides(opts))
        format = config.format
        validate_format!(format)

        scratch = Dir.mktmpdir("archbuddy-lint-")
        begin
          vintage, head_label = Review::VintageSource.head(
            target: target, scratch: scratch, trust_cache: opts[:trust_cache]
          )
          todo = if opts[:auto_gen_todo]
                   generate_todo(target_arg, target, opts, config, vintage)
                 else
                   config.todo_path && Config::Todo.load(config.todo_path)
                 end
          evaluation = Review::RuleEngine.evaluate(vintage: vintage, delta: nil,
                                                   config: config, todo: todo)
          emit_notes(vintage)

          exit_code = evaluation.exit_code(config.effective_fail_level)
          context = build_context(
            target: target, opts: opts, config: config, vintage: vintage,
            head_label: head_label, evaluation: evaluation, exit_code: exit_code
          )
          $stdout.puts Review::Formatter.for(format).new(context).render
          exit exit_code
        ensure
          FileUtils.remove_entry(scratch) if scratch && File.directory?(scratch)
        end
      end

      # The P1-T8 gen branch: evaluate WITHOUT the old todo → Todo.generate
      # (GRANDFATHERABLE findings; BREACHING components only — orphan-event
      # FirewallBreaches findings carry components nil and are never
      # generated, V15-F3) → atomic write (tmp+rename) → return the freshly
      # loaded todo so the normal report + gate math run against it (a fresh
      # todo grandfathers everything ⇒ exit 0 falls out).
      def generate_todo(target_arg, target, opts, config, vintage)
        baseline = Review::RuleEngine.evaluate(vintage: vintage, delta: nil,
                                               config: config, todo: nil)
        content = Config::Todo.generate(
          findings: baseline.findings,
          command_line: reconstruct_command_line(target_arg, opts),
          tool_version: "archbuddy #{Archbuddy::VERSION}",
          stamp: opts[:stamp]
        )
        path = config.todo_path || File.join(target, Config::DEFAULT_TODO_FILENAME)
        atomic_write(path, content)

        todo = Config::Todo.load(path)
        entries = todo.entries_by_rule.values.flatten
        warn "note: 0 violations to grandfather" if entries.empty?
        nodes = entries.map { |e| e["node"] }.uniq.size
        warn "note: wrote #{path}: #{entries.size} entries (#{nodes} nodes) " \
             "across #{todo.entries_by_rule.size} rules"
        todo
      end

      # Target as given + sorted flags (the embedded todo-header line).
      def reconstruct_command_line(target_arg, opts)
        flags = ["--auto-gen-todo"]
        flags << "--stamp" if opts[:stamp]
        flags << "--trust-cache" if opts[:trust_cache]
        flags << "--advisory" if opts[:advisory]
        flags << "--format #{opts[:format]}" if opts[:format]
        flags << "--config #{opts[:config]}" if opts[:config]
        flags << "--fail-level #{opts[:fail_level]}" if opts[:fail_level]
        flags << "--todo #{opts[:todo]}" if opts[:todo]
        (["archbuddy", "lint", target_arg] + flags.sort).join(" ")
      end

      # House writer style: tmp file in the same directory, then rename.
      def atomic_write(path, content)
        dir = File.dirname(path)
        tmp = File.join(dir, ".#{File.basename(path)}.tmp#{Process.pid}")
        File.write(tmp, content)
        File.rename(tmp, path)
      end

      # 0-node precedence pinned: the empty-vintage warning WINS; the Q8
      # note renders only for a nonempty zero-ep vintage.
      def emit_notes(vintage)
        if vintage.empty?
          warn "warning: vintage contains 0 nodes"
        elsif vintage.eps.empty?
          warn "note: #{Review::RuleEngine::Q8_REASON}"
        end
      end

      # ---- validation ----------------------------------------------------------

      def validate_flags!(opts)
        if opts[:todo] && opts[:no_todo]
          warn "error: --todo and --no-todo are mutually exclusive"
          exit 2
        end
        if opts[:auto_gen_todo] && opts[:no_todo]
          warn "error: --auto-gen-todo cannot be combined with --no-todo"
          exit 2
        end
        level = opts[:fail_level]
        return if level.nil? || FAIL_LEVELS.include?(level.to_s)

        warn "error: unknown fail level '#{level}' (none|info|warn|error)"
        exit 2
      end

      def validate_target!(arg)
        path = File.expand_path(arg)
        return path if File.directory?(path)

        warn "error: target '#{arg}' is not a directory"
        exit 2
      end

      def validate_format!(format)
        return if Review::Formatter.registered.include?(format)

        warn "error: unknown format '#{format}' (terminal|markdown|json)"
        exit 2
      end

      def cli_overrides(opts)
        cli = {}
        cli[:format] = opts[:format] if opts[:format]
        cli[:fail_level] = opts[:fail_level] if opts[:fail_level]
        cli[:advisory] = true if opts[:advisory]
        cli[:todo_path] = opts[:todo] if opts[:todo]
        cli[:no_todo] = true if opts[:no_todo]
        cli
      end

      # ---- context assembly ----------------------------------------------------

      def build_context(target:, opts:, config:, vintage:, head_label:,
                        evaluation:, exit_code:)
        Review::Formatter::ReviewContext.new(
          command: "lint", target: target, config_path: opts[:config],
          advisory: !!opts[:advisory], fail_level: config.effective_fail_level,
          base: nil,
          head: head_label.merge(sources_count: vintage.meta[:sources_count]),
          findings: evaluation.findings, grandfathered: evaluation.grandfathered,
          not_evaluable: evaluation.not_evaluable, ratchet: evaluation.ratchet,
          excluded_files: vintage.corrupt_files,
          delta_summary: nil, delta_top: nil, delta_index: nil,
          calibration: calibration_block(config, evaluation),
          exit_code: exit_code, tool: tool_block,
          use_cases: use_cases_member(vintage),
          review_surface: nil, disclosures: nil
        )
      end

      # I-C5': the always-on leaderboard — Q9 12-key rows (R39) sorted
      # branching_log2 DESC, ep ASC, read from the SAME memoized
      # vintage.graph the engine used (R52/§5-C31). `edges?` false → nil
      # (the engine's N/A notes carry the honesty); zero eps → count 0 +
      # `unreachable: nil` (Q8 — never an all-unreachable disclosure).
      def use_cases_member(vintage)
        return nil unless vintage.edges?

        metrics = vintage.graph.ep_metrics
        if metrics.empty?
          return { count: 0, leaderboard: [], unreachable: nil }
        end

        sorted = metrics.sort_by { |(_file, ep_symbol), m| [-m.branching_log2, ep_symbol.to_s] }
        rows = sorted.each_with_index.map do |((file, ep_symbol), m), index|
          leaderboard_row(index + 1, file, ep_symbol, m)
        end
        { count: metrics.size, leaderboard: rows,
          unreachable: vintage.graph.unreachable_from_entrypoints }
      end

      def leaderboard_row(rank, file, ep_symbol, metrics)
        max_cone_log2 = metrics.max_cone_node && metrics.max_cone_node[:log2]
        {
          "rank" => rank, "ep" => ep_symbol, "kind" => metrics.entrypoint_kind,
          "file" => file, "branching_log2" => metrics.branching_log2,
          "mass" => metrics.mass, "reach" => metrics.reach,
          "files" => metrics.files, "depth" => metrics.depth,
          "dividend" => metrics.dividend, "max_cone_node_log2" => max_cone_log2,
          "cost_note" => cost_note(max_cone_log2)
        }
      end

      # Presenter-only (I-C6/R36); absent module ⇒ nil (the calibration
      # umbrella requires land with P3-T2's Wave-7 append, [S:F1] exception).
      def cost_note(max_cone_node_log2)
        return nil unless defined?(Review::Calibration::Lines)

        Review::Calibration::Lines.cost_note(max_cone_node_log2: max_cone_node_log2)
      end

      # R18 two-step; lint passes delta: nil and review_surface: nil.
      def calibration_block(config, evaluation)
        unless defined?(Review::Calibration)
          return { source: "none", provenance: nil, lines: [] }
        end

        resolved = Review::Calibration.resolve(config.calibration)
        lines = Review::Calibration::Lines.build(
          resolved: resolved, findings: evaluation.findings,
          delta: nil, review_surface: nil
        )
        { source: resolved.source, provenance: resolved.provenance, lines: lines }
      end

      def tool_block
        {
          client: Archbuddy::VERSION,
          engine: defined?(ArchitectureAuditor::VERSION) ? ArchitectureAuditor::VERSION : nil,
          serializer: Cache::Writer::SERIALIZER_VERSION
        }
      end
    end
  end
end
