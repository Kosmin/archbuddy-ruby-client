# frozen_string_literal: true

require "dry/cli"
require_relative "../archbuddy"
require_relative "cli/collect"
require_relative "cli/analyze"
require_relative "cli/report"
require_relative "cli/diff"
require_relative "cli/lint"
require_relative "cli/reset"
require_relative "cli/reflect"
require_relative "cli/trace"

module Archbuddy
  # dry-cli command registry (D48). The v0.8 committed-cache CLI surface:
  #   collect [--changed|--check]  — assemble fragments → graph.yml + id-map.yml
  #                                  (--changed incremental; --check CI gate, R3)
  #   analyze                      — engine score + DE-ANON-AT-WRITE the committed
  #                                  real-name root archbuddy-findings.json
  #   report                       — render from the committed cache (no id-map),
  #                                  or the legacy findings.yml + id-map
  #   reset                        — full re-collect + analyze from scratch (L3)
  module CLI
    extend Dry::CLI::Registry

    register "collect", Collect
    register "analyze", Analyze
    register "report", Report
    register "diff", Diff
    register "lint", Lint
    register "reset", Reset
    register "reflect", Reflect
    register "trace", Trace
  end
end
