# frozen_string_literal: true

require "dry/cli"
require_relative "../archbuddy"
require_relative "cli/collect"
require_relative "cli/report"

module Archbuddy
  # dry-cli command registry (D48). Two commands: `collect` (the sole producer
  # of id-map.yml) and `report` (the second and only other consumer of it).
  module CLI
    extend Dry::CLI::Registry

    register "collect", Collect
    register "report", Report
  end
end
