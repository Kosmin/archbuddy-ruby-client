# frozen_string_literal: true

require "architecture_auditor"

module Archbuddy
  # The Reporter (Phase C). Joins the engine's opaque findings.yml back to real
  # symbols via the SECRET id-map.yml, ranks the resulting bottlenecks by their
  # (verbatim, never recomputed — D17) clutter_score, and renders a report.
  #
  # The Reporter is the SECOND and only other consumer of id-map.yml besides the
  # collector. Every de-anonymized output it produces (terminal text, yaml/json
  # exports, .dot graphs) contains real file/symbol names and is therefore
  # SECRET/local-only (D16/D21) — never committed, never sent externally.
  module Report
    # The 8 metric keys, in canonical order, that the Reporter DISPLAYS per
    # bottleneck (D43). This is a NAMED CONSTANT — not an inline literal — so the
    # client-half of the 4c metric-kernel consistency test can assert it equals
    # the engine's source-of-truth `ArchitectureAuditor::Analyze::METRIC_KEYS`.
    # If the engine and client ever drift on the metric set, that spec fails CI.
    #
    # NOTE: kept as strings because findings.yml carries string metric keys; the
    # 4c spec compares against the engine's symbol set via `.map(&:to_sym)`.
    METRIC_KEYS_FOR_DISPLAY = %w[
      path_length
      fan_in
      fan_out
      centrality
      instability
      in_cycle
      orphan
      dead
    ].freeze

    autoload :Model,       "archbuddy/report/model"
    autoload :Scores,      "archbuddy/report/scores"
    autoload :Reconnect,   "archbuddy/report/reconnect"
    autoload :Ranker,      "archbuddy/report/ranker"
    autoload :Explanation, "archbuddy/report/explanation"
    autoload :Formatter,   "archbuddy/report/formatter"

    module Formatters
      autoload :TerminalFormatter, "archbuddy/report/formatters/terminal_formatter"
      autoload :YamlFormatter,     "archbuddy/report/formatters/yaml_formatter"
      autoload :JsonFormatter,     "archbuddy/report/formatters/json_formatter"
      autoload :DotFormatter,      "archbuddy/report/formatters/dot_formatter"
      autoload :HtmlFormatter,     "archbuddy/report/formatters/html_formatter"
    end
  end
end
