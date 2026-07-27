# frozen_string_literal: true

require "dry/cli"
require "tmpdir"
require "fileutils"
require_relative "../review"

module Archbuddy
  module CLI
    # `archbuddy diff [TARGET] [BASE_REF]` — the PR-shaped architecture review
    # (v0.15 P2-T11). Two-vintage pipeline: resolve base (injected > committed >
    # stateless) and head (trust-cache > tracked+clean > manifest-fresh >
    # re-collect), build the first-class Delta (node + ep surfaces), evaluate
    # the 7-rule family, thread review_surface/disclosures/calibration into the
    # ReviewContext, render ONE document to stdout, and exit via the
    # finding-or-breach math ([S:C5] — `Findings#exit_code` is the single
    # owner; L3 advisory default when no config gates).
    #
    # CLEAN-STDOUT (P5): stdout receives EXACTLY ONE write — the rendered
    # document; every note/warning/error goes to stderr. On ANY exit-2 path
    # stdout emits NOTHING.
    class Diff < Dry::CLI::Command
      desc "Review the architecture delta between a base ref and the working tree. " \
           "BASE_REF defaults to the first of origin/main, origin/master, main, master; " \
           "the diff base is git merge-base BASE_REF HEAD (triple-dot semantics, like " \
           "diff-cover --compare-branch)."

      argument :target, required: false, default: ".",
                        desc: "Target directory (default: .)"
      argument :base_ref, required: false,
                          desc: "Base ref (default: first of origin/main, origin/master, main, master)"

      option :format, desc: "Output format: terminal|markdown|json (default: config all.format, else terminal)"
      option :config, desc: "Path to the .archbuddy.yml config file"
      option :base_cache, desc: "Directory holding a pre-collected base vintage (archbuddy-findings.json)"
      option :trust_cache, type: :boolean, default: false,
                           desc: "Trust the head working-tree cache WITHOUT a freshness check"
      option :fail_level, desc: "Gate at this severity: none|info|warn|error"
      option :advisory, type: :boolean, default: false, desc: "Never gate (= --fail-level none)"
      option :todo, desc: "Path to the value-pinned todo document"
      option :no_todo, type: :boolean, default: false, desc: "Ignore any todo document"

      FAIL_LEVELS = %w[none info warn error].freeze

      def call(target: ".", base_ref: nil, **opts)
        run(target, base_ref, opts)
      rescue Config::ValidationError, Review::VintageError => e
        warn e.message.start_with?("error:") ? e.message : "error: #{e.message}"
        exit 2
      rescue StandardError => e
        warn "error: #{e.class}: #{e.message}"
        warn e.backtrace.join("\n") if ENV["ARCHBUDDY_DEBUG"] == "1"
        exit 2
      end

      private

      def run(target_arg, base_ref, opts)
        validate_flags!(opts)
        target = validate_target!(target_arg)
        config = Config.load(target_root: target, config_path: opts[:config],
                             cli: cli_overrides(opts))
        format = config.format
        validate_format!(format)
        todo = config.todo_path && Config::Todo.load(config.todo_path)

        scratch = Dir.mktmpdir("archbuddy-diff-")
        begin
          base_v, base_label = Review::VintageSource.base(
            target: target, scratch: scratch, base_ref: base_ref,
            base_cache: opts[:base_cache]
          )
          head_v, head_label = Review::VintageSource.head(
            target: target, scratch: scratch, trust_cache: opts[:trust_cache]
          )
          delta = Review::Delta.new(base: base_v, head: head_v)
          evaluation = Review::RuleEngine.evaluate(vintage: head_v, delta: delta,
                                                   config: config, todo: todo)
          warn "note: #{Review::RuleEngine::Q8_REASON}" if head_v.eps.empty? && !head_v.empty?

          exit_code = evaluation.exit_code(config.effective_fail_level)
          context = build_context(
            target: target, opts: opts, config: config, base_v: base_v,
            base_label: base_label, head_v: head_v, head_label: head_label,
            delta: delta, evaluation: evaluation, exit_code: exit_code
          )
          $stdout.puts Review::Formatter.for(format).new(context).render
          exit exit_code
        ensure
          FileUtils.remove_entry(scratch) if scratch && File.directory?(scratch)
        end
      end

      # ---- validation ----------------------------------------------------------

      def validate_flags!(opts)
        if opts[:todo] && opts[:no_todo]
          warn "error: --todo and --no-todo are mutually exclusive"
          exit 2
        end
        level = opts[:fail_level]
        return if level.nil? || FAIL_LEVELS.include?(level.to_s)

        warn "error: unknown fail level '#{level}' (none|info|warn|error)"
        exit 2
      end

      # W1 discipline: TARGET is validated, never CWD-coupled; a ref-shaped
      # argument gets the did-you-mean.
      def validate_target!(arg)
        path = File.expand_path(arg)
        return path if File.directory?(path)

        cwd_root = Review::Git.repo_root(Dir.pwd)
        if cwd_root && Review::Git.resolve_ref(cwd_root, arg)
          warn "error: '#{arg}' is not a directory — did you mean 'archbuddy diff . #{arg}'?"
        else
          warn "error: target '#{arg}' is not a directory"
        end
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

      def build_context(target:, opts:, config:, base_v:, base_label:, head_v:,
                        head_label:, delta:, evaluation:, exit_code:)
        Review::Formatter::ReviewContext.new(
          command: "diff", target: target, config_path: opts[:config],
          advisory: !!opts[:advisory], fail_level: config.effective_fail_level,
          base: base_label.merge(sources_count: base_v.meta[:sources_count]),
          head: head_label.merge(sources_count: head_v.meta[:sources_count]),
          findings: evaluation.findings, grandfathered: evaluation.grandfathered,
          not_evaluable: evaluation.not_evaluable, ratchet: evaluation.ratchet,
          excluded_files: delta.excluded_files,
          delta_summary: delta_summary(delta, head_v),
          delta_top: delta_top(delta), delta_index: delta_index(delta),
          calibration: calibration_block(config, evaluation, delta, base_v, head_v),
          exit_code: exit_code, tool: tool_block,
          use_cases: nil, # diff never renders the leaderboard (Q9(iv))
          review_surface: evaluation.review_surface,
          disclosures: delta.disclosures
        )
      end

      def delta_summary(delta, head_v)
        summary = { counts: delta.counts, net_log2: delta.net_log2 }
        unreachable = head_v.edges? ? head_v.graph.unreachable_from_entrypoints : nil
        summary[:unreachable_from_entrypoints] = unreachable if unreachable
        summary
      end

      def delta_top(delta)
        delta.entries.sort_by { |e| [-e.delta_log2.abs, e.file, e.symbol] }
             .first(20).map do |e|
          { file: e.file, symbol: e.symbol, classification: e.classification,
            base_branches: e.base_branches, head_branches: e.head_branches,
            delta_log2: e.delta_log2 }
        end
      end

      # [S:F11]: values.base_branches for node findings only.
      def delta_index(delta)
        delta.entries.to_h do |e|
          [[e.file, e.symbol],
           { base_branches: e.base_branches, head_branches: e.head_branches }]
        end
      end

      # R18 two-step + the I-C7 rs input ({union:, q4_count:}; nil when the
      # block is nil — zero-ep heads carry the honesty via Q8 notes instead).
      # Absent module ⇒ the none-block ([S:R18] — the calibration umbrella
      # requires land with P3-T2's Wave-7 append, [S:F1] exception).
      def calibration_block(config, evaluation, delta, base_v, head_v)
        unless defined?(Review::Calibration)
          return { source: "none", provenance: nil, lines: [] }
        end

        resolved = Review::Calibration.resolve(config.calibration)
        lines = Review::Calibration::Lines.build(
          resolved: resolved, findings: evaluation.findings, delta: delta,
          review_surface: rs_input(evaluation, base_v, head_v)
        )
        { source: resolved.source, provenance: resolved.provenance, lines: lines }
      end

      # q4_count = review-surface eps whose side-appropriate
      # ep_metrics.max_cone_node.log2 is STRICTLY above 5.0 (the Q4 boundary);
      # REMOVED eps read the base side, everything else the head side.
      def rs_input(evaluation, base_v, head_v)
        surface = evaluation.review_surface
        return nil unless surface

        q4_count = (surface[:eps] || []).count do |row|
          side = row[:classification] == :removed ? base_v : head_v
          metrics = side.edges? ? side.graph.ep_metrics[[row[:file], row[:ep_symbol]]] : nil
          log2 = metrics && metrics.max_cone_node && metrics.max_cone_node[:log2]
          !log2.nil? && log2 > 5.0
        end
        { union: surface[:union], q4_count: q4_count }
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
