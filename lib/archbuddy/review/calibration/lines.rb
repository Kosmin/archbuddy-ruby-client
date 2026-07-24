# frozen_string_literal: true

module Archbuddy
  module Review
    module Calibration
      # The honest-copy calibration line renderer. Emission order pinned
      # (G4/R53): L-NET, L-Q4, L-BUGFIX, L-UC-Q4, L-RS, L-DIV, L-FB-NONE.
      #
      # Rendering laws (Q6, spec-gated):
      #   R-HONEST-1 — the latency multiplier exponentiates ONLY
      #     `delta.net_log2` (the L-NET input). It NEVER exponentiates a
      #     Σ-over-cone level, a lint-mode level, or any components value
      #     (the worst real ep at 55.585 log2 would fabricate ×352).
      #   R-HONEST-2 — a line quoting NO study value carries NO provenance
      #     suffix; `" — " + provenance` attaches exactly to lines that quote
      #     study numbers.
      module Lines
        module_function

        # @param resolved [Calibration::Resolved]
        # @param findings [Array<#rule>] REQUIRED (empty array = clean run)
        # @param delta [#net_log2, nil]
        # @param review_surface [{union: Integer, q4_count: Integer}, nil]
        # @return [Array<String>] pre-rendered advisory lines
        def build(resolved:, findings:, delta: nil, review_surface: nil)
          raise ArgumentError, "findings is required (pass [] for a clean run)" if findings.nil?
          return [] if resolved.source == "none"

          values = resolved.values
          lines = []
          lines << l_net(values, delta, resolved)
          lines << l_q4(values, findings, resolved)
          lines << l_bugfix(values, findings, resolved)
          lines << l_uc_q4(values, findings, resolved)
          lines << l_rs(values, review_surface, resolved)
          lines << l_div(values, findings, resolved)
          lines << l_fb_none(findings, resolved)
          lines.compact
        end

        # The Q9 leaderboard column helper (presenter-only, R36): the short
        # clause; the full L-UC-Q4 sentence renders once in the calibration
        # footer, never per row.
        def cost_note(max_cone_node_log2:)
          return nil if max_cone_node_log2.nil?

          max_cone_node_log2 > 5.0 ? "contains a Q4-boundary node" : nil
        end

        # ---- templates -------------------------------------------------------

        def l_net(values, delta, resolved)
          return nil if delta.nil?

          net = delta.net_log2
          return nil if net.abs < 0.005

          multiplier = values["latency_multiplier_per_log2_unit"]
          return nil if multiplier.nil?

          line = format("net %+.3f log2 units → ×%.2f expected review-latency multiplier",
                        net, multiplier**net)
          ci = values["latency_multiplier_ci95"]
          line += format(" (95%% CI ×%.2f–×%.2f)", ci[0]**net, ci[1]**net) if ci
          with_provenance(line, resolved)
        end

        def l_q4(values, findings, resolved)
          k = findings.count { |f| f.rule == "ExponentialNode" }
          return nil if k.zero?

          clauses = []
          med = values["latency_arm_medians_hours"]
          clauses << format("Q4-touching PRs merged at median %.1fh vs %.1fh (Q1)", med[0], med[1]) if med
          cost = values["cost_per_line_ratio_q4_vs_q1"]
          if cost
            clauses << format("cost ×%.1f review-window hours per changed line " \
                              "(elapsed clock, not engineer-hours)", cost)
          end
          return nil if clauses.empty?

          with_provenance(
            format("%d node(s) above the Q4 boundary (b_own > 2^5 = 32): ", k) + clauses.join(" and "),
            resolved
          )
        end

        def l_bugfix(values, findings, resolved)
          k = findings.count { |f| f.rule == "ExponentialNode" }
          return nil if k.zero?

          ratio = values["bugfix_rate_ratio_q4_vs_q1"]
          return nil if ratio.nil?

          with_provenance(
            format("Q4-touching code carried ×%.2f the bugfix rate%s", ratio, caveat_for(resolved)),
            resolved
          )
        end

        def l_uc_q4(values, findings, resolved)
          k = findings.count do |f|
            f.rule == "UseCaseComplexity" && q4_component?(component_value(f, "max_cone_node_log2"))
          end
          return nil if k.zero?

          clauses = []
          med = values["latency_arm_medians_hours"]
          clauses << format("PRs touching such code merged at median %.1fh vs %.1fh (Q1)", med[0], med[1]) if med
          cost = values["cost_per_line_ratio_q4_vs_q1"]
          if cost
            clauses << format("cost ×%.1f review-window hours per changed line " \
                              "(elapsed clock, not engineer-hours)", cost)
          end
          return nil if clauses.empty?

          with_provenance(
            format("%d use case(s) contain a node above the Q4 boundary (b_own > 2^5 = 32): ", k) +
              clauses.join(" and "),
            resolved
          )
        end

        def l_rs(values, review_surface, resolved)
          return nil if review_surface.nil?

          union = review_surface[:union]
          return nil if union.nil? || union < 1

          line = format("re-verify %d use case(s) to land this change", union)
          kq4 = review_surface[:q4_count]
          med = values["latency_arm_medians_hours"]
          if kq4 && kq4 >= 1 && med
            line += format(" — %d of them contain a Q4-boundary node " \
                           "(such PRs merged at median %.1fh vs %.1fh)", kq4, med[0], med[1])
            with_provenance(line, resolved) # calibrated only with the clause
          else
            line # UNcalibrated count — NO provenance (R-HONEST-2)
          end
        end

        def l_div(values, findings, resolved)
          div_findings = findings.select { |f| f.rule == "UseCaseDividend" }
          return nil if div_findings.empty?

          worst = div_findings.max_by { |f| component_value(f, "dividend") || -Float::INFINITY }
          dividend = component_value(worst, "dividend")
          return nil if dividend.nil?

          threshold = worst.threshold_raw
          div_str = dividend == dividend.to_i ? dividend.to_i.to_s : format("%.1f", dividend)

          q4_clause = ""
          calibrated = false
          contributor_log2 = first_contributor_value_log2(worst)
          ratio = values["bugfix_rate_ratio_q4_vs_q1"]
          if contributor_log2 && contributor_log2 > 5.0 && ratio
            q4_clause = format(" — its dominant contributor is above the Q4 boundary: " \
                               "×%.2f the bugfix rate%s", ratio, caveat_for(resolved))
            calibrated = true
          end

          line = format("%d use case(s) carry ≥×%d variety that exists only because decisions " \
                        "are inline (worst: %s ×%s, V_now 2^%.1f vs V_floor 2^%.1f)%s",
                        div_findings.size, threshold, worst.symbol, div_str,
                        component_value(worst, "v_now_log2"),
                        component_value(worst, "v_floor_log2"), q4_clause)
          # Without the q4 clause the line is a tool-fact (the dividend is the
          # tool's own engine-exact arithmetic, Q1) — no provenance.
          calibrated ? with_provenance(line, resolved) : line
        end

        def l_fb_none(findings, resolved)
          return nil unless resolved.source == "builtin-study-v1"

          k = findings.count { |f| f.rule == "FirewallBreaches" }
          return nil if k.zero?

          # Q6's explicit no-measured-cost note; quotes no study value — NO
          # provenance suffix. Under local/none a flavored note would be
          # fabricated (VALUE_KEYS carry no escape key).
          format("%d use case(s) report escape counts — no measured cost line for escape " \
                 "hatches (the 2025-10 → 2026-07 study did not measure escape outcomes)", k)
        end

        # ---- helpers ---------------------------------------------------------

        def with_provenance(line, resolved)
          "#{line} — #{resolved.provenance}"
        end

        def caveat_for(resolved)
          resolved.source == "builtin-study-v1" ? BUGFIX_CAVEAT : ""
        end

        def q4_component?(value)
          !value.nil? && value > 5.0
        end

        # Components arrive either as the I-P5' triple {value:, threshold:,
        # breached:} or (spec doubles) as a bare number — read both.
        def component_value(finding, key)
          components = finding.components
          return nil if components.nil?

          raw = components[key] || components[key.to_sym]
          return nil if raw.nil?

          raw.is_a?(Hash) ? (raw[:value] || raw["value"]) : raw
        end

        def first_contributor_value_log2(finding)
          contributor = finding.contributors&.first
          return nil if contributor.nil?

          if contributor.respond_to?(:value_log2)
            contributor.value_log2
          elsif contributor.is_a?(Hash)
            contributor[:value_log2] || contributor["value_log2"]
          end
        end
      end
    end
  end
end
