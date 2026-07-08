# frozen_string_literal: true

require "dry/cli"
require_relative "../archbuddy"
require_relative "cli/collect"
require_relative "cli/report"
require_relative "cli/reset"

module Archbuddy
  # dry-cli command registry (D48). Commands: `collect` (the sole producer of
  # id-map.yml), `report` (the second and only other consumer of it), and
  # `reset` (v0.8 L3 — full re-collect + analyze from scratch).
  module CLI
    extend Dry::CLI::Registry

    register "collect", Collect
    register "report", Report
    register "reset", Reset
  end
end
