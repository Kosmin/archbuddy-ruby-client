# frozen_string_literal: true

module Archbuddy
  module Report
    # v0.11 (W-C, L6/L17): the ONE shared Business Impact presentation model,
    # consumed by BOTH formatters (terminal + HTML) so the five business
    # questions have exactly one phrasing, one nil-tolerance policy, and zero
    # analytic decisions — the formatters stay pure markup.
    #
    # The five questions (verbatim copy, pinned by spec):
    #   q1  new-feature complexity   — existing forward cost (mean/median/grade)
    #   q2  bug-fix complexity       — existing reverse cost (ditto)
    #   q3  breakability             — NEW blast radius (1.6)
    #   q4  new-feature path length  — NEW forward depth (1.6)
    #   q5  bug-fix trace depth      — NEW reverse depth (1.6)
    #   bf  branching footer         — NEW per-hop branching density b-bar,
    #                                  UNGRADED, median-first (L15)
    #
    # Every number is a VERBATIM engine figure (D17) — the only client
    # arithmetic is display formatting (ratio x 100, rounding). Conventions:
    #   * a capped MEAN is a LOWER BOUND (censored data); when
    #     `capped_fraction` > 0 the answer carries "N% of routes at cap
    #     (lower bound)", and at >= 0.5 the median cell renders "at cap"
    #     instead of a falsely-precise number.
    #   * the q3 denominator is `blast_radius.total_entrypoints` — NEVER
    #     derived from any other count (guard M5).
    #   * worst-offender reach and added_coupling are displayed SEPARATELY —
    #     the reach x amplification product is never computed (guard R7).
    #   * OMISSION, never fabrication: a question whose source struct or
    #     headline value is absent renders NO Question at all; zero answerable
    #     questions -> [] and both formatters omit the whole section, keeping
    #     v1 no-scores docs byte-identical.
    module BusinessImpact
      # One rendered question: `grade` is nil for ungraded rows (HTML uses it
      # for the color class only); `answer`/`detail_lines` are fully-formatted
      # strings so both formatters share one phrasing.
      Question = Struct.new(:id, :text, :grade, :answer, :detail_lines, keyword_init: true)

      # The verbatim question copy (L17 — specs pin these exact strings).
      Q1_TEXT = "Implementing a new feature: how much complexity will a developer face?"
      Q2_TEXT = "Fixing a bug: how hard is it to trace where the code you're changing is used?"
      Q3_TEXT = "Breaking something: how many use cases can a single change put at risk?"
      Q4_TEXT = "Implementing a new feature: how many steps does a new flow travel end-to-end?"
      Q5_TEXT = "Fixing a bug: how deep is the trace from a use case down to the code?"
      BF_TEXT = "Branching"

      # The share of capped routes at/above which the median itself sits at
      # the publish cap — rendering the capped number would be false precision.
      MEDIAN_AT_CAP_THRESHOLD = 0.5

      module_function

      # @param context [Formatter::RenderContext]
      # @return [Array<Question>] the answerable questions, in q1..bf order —
      #   [] when nothing is answerable (both formatters omit the section).
      def questions(context)
        [
          q1(context), q2(context), q3(context),
          q4(context), q5(context), bf(context)
        ].compact
      end

      # -- q1/q2: the two existing cost dimensions, reframed ------------------

      def q1(context)
        fwd = dimension(context, "forward_discoverability")
        ep  = context.entrypoints
        # entrypoints.mean/median ARE the forward dimension figures, committed
        # at analyze (v2 carries the median the v2 scores block dropped);
        # legacy/v1 docs fall back to the dimension itself — same number.
        mean   = (ep && ep.mean)   || fwd&.score
        median = (ep && ep.median) || fwd&.median
        return nil if mean.nil?

        capped = fwd&.capped_fraction || (ep && ep.capped_fraction)
        detail = ep&.by_category_cost_display
        # v0.12 (1.7): the Variety+Mass detail line rides AFTER the existing
        # by-category line (whose bytes are untouched); absent pre-1.7 and on
        # N/A, so pre-1.7 Q1 renders byte-identically to v0.10.0 (L7).
        detail_lines = detail ? ["by category: #{detail}"] : []
        vm_line = variety_mass_line(context.variety_mass)
        detail_lines << vm_line if vm_line
        Question.new(
          id: "q1", text: Q1_TEXT, grade: fwd&.grade,
          answer: cost_answer(mean: mean, grade: fwd&.grade, median: median,
                              median_grade: fwd&.median_grade, capped_fraction: capped),
          detail_lines: detail_lines
        )
      end

      def q2(context)
        rev = dimension(context, "reverse_traceability")
        return nil if rev.nil? || rev.score.nil?

        Question.new(
          id: "q2", text: Q2_TEXT, grade: rev.grade,
          answer: cost_answer(mean: rev.score, grade: rev.grade, median: rev.median,
                              median_grade: rev.median_grade,
                              capped_fraction: rev.capped_fraction),
          detail_lines: []
        )
      end

      # -- q3: blast radius ----------------------------------------------------

      def q3(context)
        br = context.blast_radius
        # The engine N/A form (zero entrypoints / nothing non-external
        # reached) carries null stats — reachability UNDEFINED, so the
        # question is OMITTED (never "0 use cases at risk").
        return nil if br.nil? || br.max.nil?

        Question.new(
          id: "q3", text: Q3_TEXT, grade: nil,
          answer: "the worst single node is reachable from #{br.max} of " \
                  "#{br.total_entrypoints} use cases (#{br.pct_display}) — " \
                  "p90 #{plain(br.p90)}, median #{plain(br.median)}",
          detail_lines: worst_offender_lines(br.worst)
        )
      end

      # -- q4/q5: depth --------------------------------------------------------

      def q4(context)
        fd = context.forward_depth
        return nil if fd.nil? || fd.median.nil?

        Question.new(
          id: "q4", text: Q4_TEXT, grade: nil,
          answer: "a typical use case is #{depth(fd.median)} functions deep " \
                  "(mean #{depth(fd.mean)}#{worst_clause(fd.max)})",
          detail_lines: depth_by_category_lines(fd.by_category)
        )
      end

      def q5(context)
        rd = context.reverse_depth
        return nil if rd.nil? || rd.median.nil?

        Question.new(
          id: "q5", text: Q5_TEXT, grade: nil,
          answer: "a typical trace is #{depth(rd.median)} functions deep " \
                  "(mean #{depth(rd.mean)}#{worst_clause(rd.max)})",
          detail_lines: []
        )
      end

      # -- bf: the ungraded branching footer (median-FIRST, L15) ---------------

      def bf(context)
        b = context.branching_factor
        return nil if b.nil? || b.median.nil?

        mean_clause = b.mean.nil? ? "" : "; mean #{plain(b.mean)}"
        Question.new(
          id: "bf", text: BF_TEXT, grade: nil,
          answer: "each step of tracing multiplies the choices " \
                  "×#{format('%.2f', b.median)} (median#{mean_clause})",
          detail_lines: []
        )
      end

      # -- shared formatting helpers -------------------------------------------

      # `cost mean {%.1f} ({grade}{, median: {letter}}) · median {N|at cap}
      #  {— P% of routes at cap (lower bound)}` — every clause drops
      # nil-tolerantly (copy degrades, never breaks).
      def cost_answer(mean:, grade:, median:, median_grade:, capped_fraction:)
        answer = +"cost mean #{format('%.1f', mean)}"
        answer << " (#{grade}#{median_letter_clause(median_grade)})" if grade
        answer << " · median #{median_cell(median, capped_fraction)}" unless median.nil?
        answer << cap_note(capped_fraction)
        answer
      end

      # v0.12 (1.7): the Variety+Mass reading beside the existing cost — the
      # owner's "complexity 57 = variety 16 + mass 41"-style line, every
      # number a VERBATIM engine figure (D17; the "=" is display only — the
      # engine caps variety BEFORE summing and publishes component stats over
      # the SAME capped per-row values, so score = variety.mean + mass.mean
      # within display rounding is the COMMON case, A7; when the three
      # figures don't reconcile the copy degrades to the comma form rather
      # than print a false equation). nil (no line) when the block is absent
      # (pre-1.7) or N/A — byte-identical absence. UNGRADED — no letter ever.
      def variety_mass_line(vm)
        return nil if vm.nil? || vm.score.nil?

        line = +"variety + mass: complexity #{format('%.1f', vm.score)}#{vm_equation(vm)}"
        line << " (median #{median_cell(vm.median, vm.capped_fraction)})" unless vm.median.nil?
        line << cap_note(vm.capped_fraction)
        line
      end

      # " = variety 16.0 + mass 41.0" — only when both component means are
      # published AND they reconcile with the composite within display
      # rounding (0.05); ", variety 16.0, mass 41.0" when published but
      # non-reconciling; "" when the engine published no components.
      def vm_equation(vm)
        v = vm.variety&.mean
        m = vm.mass&.mean
        return "" if v.nil? || m.nil?

        if (vm.score - (v + m)).abs <= 0.05
          " = variety #{format('%.1f', v)} + mass #{format('%.1f', m)}"
        else
          ", variety #{format('%.1f', v)}, mass #{format('%.1f', m)}"
        end
      end

      # ", median: A" — only when the ENGINE published the secondary letter
      # (1.6 `median_grade`; the client never grades — D17). "N/A" letters
      # accompany a nil score, where the question is already omitted.
      def median_letter_clause(median_grade)
        return "" if median_grade.nil? || median_grade == "N/A"

        ", median: #{median_grade}"
      end

      # The median number — or "at cap" when >= 50% of routes sit at the
      # publish cap (the capped median IS the cap; a precise-looking number
      # would be fabricated confidence).
      def median_cell(median, capped_fraction)
        at_cap = capped_fraction && capped_fraction >= MEDIAN_AT_CAP_THRESHOLD
        at_cap ? "at cap" : format("%.1f", median)
      end

      # " — 97.6% of routes at cap (lower bound)" when any route capped; ""
      # when uncapped or unknown (nil — never treated as 0, I2).
      def cap_note(capped_fraction)
        return "" if capped_fraction.nil? || capped_fraction.zero?

        " — #{format('%.1f', capped_fraction * 100)}% of routes at cap (lower bound)"
      end

      # ", worst 20" — dropped while the engine emits no depth max (C3;
      # 1.7 candidate).
      def worst_clause(max)
        max.nil? ? "" : ", worst #{plain(max)}"
      end

      # Top-3 worst offenders, reach + coupling displayed SEPARATELY (R7).
      def worst_offender_lines(worst)
        top = (worst || []).first(3)
        return [] if top.empty?

        entries = top.map do |w|
          coupling = w.added_coupling.nil? ? "" : ", +#{plain(w.added_coupling)} coupling"
          "#{w.symbol} (#{w.use_cases_affected} use cases#{coupling})"
        end
        ["worst offenders: #{entries.join('; ')}"]
      end

      # "by category: controllers mean 2.9 / median 2.0, …" — the q1
      # by-category compaction applied to a depth stat group; [] when the
      # engine emitted no grouping (honest absence).
      def depth_by_category_lines(by_category)
        return [] if by_category.nil? || by_category.empty?

        line = by_category.map do |cat, stats|
          "#{cat} mean #{depth(stats['mean'])} / median #{depth(stats['median'])}"
        end.join(", ")
        ["by category: #{line}"]
      end

      # Depths pin to one decimal ("2.0 functions deep" — L17 formats).
      def depth(value)
        return "—" if value.nil?

        format("%.1f", value)
      end

      # Integer-when-whole display for counts/percentile figures the copy
      # reads as counts ("p90 3, median 1") — verbatim otherwise.
      def plain(value)
        return "—" if value.nil?
        return value.to_i.to_s if (value % 1).zero?

        value.to_s
      end

      # Find one dimension row off the ordered DIMENSIONS array (nil when the
      # doc carries no scores block).
      def dimension(context, key)
        (context.scores || []).find { |d| d.key == key }
      end
    end
  end
end
