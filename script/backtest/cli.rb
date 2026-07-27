# frozen_string_literal: true

require_relative "corpus"
# snapshot_reader/repos/preflight load archbuddy (and the engine gem) — the
# tier implementations require them at registration time; the env-gating
# path stays dependency-free.

module Backtest
  # `script/backtest.rb` entry: env gating (A6), flag parsing, tier dispatch.
  #
  # Exit map: 0 ran-or-skipped-gracefully · 1 ≥1 gate boolean false ·
  # 2 corpus/tool error.
  module CLI
    DEFAULT_OUT = "tmp/backtest"
    TIERS = {} # tier name → callable(corpus:, opts:) → exit code (0/1/2)

    module_function

    def register_tier(name, callable)
      TIERS[name.to_s] = callable
    end

    # Tier implementations load archbuddy (and the engine gem) — required
    # only AFTER the env gate passes so the graceful-skip path stays
    # dependency-free.
    def load_tiers
      Dir[File.join(__dir__, "tier*.rb")].sort.each { |file| require file }
    end

    def run(argv)
      opts = parse(argv)
      return 2 if opts.nil?

      corpus_root = ENV.fetch("ARCHBUDDY_STUDY_CORPUS", nil)
      if corpus_root.nil? || corpus_root.empty?
        warn "note: backtest skipped: ARCHBUDDY_STUDY_CORPUS not set"
        return 0
      end

      corpus = Corpus.new(corpus_root)
      begin
        corpus.validate!
      rescue Corpus::CorpusError => e
        warn "error: #{e.message}"
        return 2
      end

      load_tiers

      tiers = opts[:tier] == "all" ? %w[0 1 2 3] : [opts[:tier]]
      codes = tiers.map { |tier| run_tier(tier, corpus, opts) }

      # `--tier all` also assembles the adoption document + machine twin
      # (P3-T8) from the tier outputs just written.
      if opts[:tier] == "all"
        require_relative "report"
        codes << Report.generate(out: opts[:out] || DEFAULT_OUT)
      end
      codes.max || 0
    end

    def run_tier(tier, corpus, opts)
      callable = TIERS[tier]
      if callable.nil?
        warn "note: tier #{tier} not registered in this build — skipped"
        return 0
      end

      callable.call(corpus: corpus, opts: opts)
    end

    # @return [Hash, nil] nil on usage error (caller exits 2)
    def parse(argv)
      opts = { tier: "all", sample: nil, pairs: "base-merge", out: DEFAULT_OUT, strict: false }
      args = argv.dup
      until args.empty?
        arg = args.shift
        case arg
        when "--tier"
          value = args.shift
          unless %w[0 1 2 3 all].include?(value)
            warn "error: unknown --tier '#{value}' (0|1|2|3|all)"
            return nil
          end
          opts[:tier] = value
        when "--sample"
          opts[:sample] = Integer(args.shift, exception: false) ||
                          (warn("error: --sample wants an integer") || (return nil))
        when "--pairs"
          value = args.shift
          unless %w[base-merge merge-parent].include?(value)
            warn "error: unknown --pairs '#{value}' (base-merge|merge-parent)"
            return nil
          end
          opts[:pairs] = value
        when "--out"
          opts[:out] = args.shift or (warn("error: --out wants a dir") || (return nil))
        when "--strict"
          opts[:strict] = true
        else
          warn "error: unknown flag '#{arg}'"
          return nil
        end
      end
      opts
    end
  end
end
