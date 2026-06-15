# frozen_string_literal: true

require "dry/cli"
require_relative "../archbuddy"
require_relative "cli/collect"

module Archbuddy
  # dry-cli command registry (D48). Phase B Track-1 wires only `collect`; the
  # `report` command is registered by the Reporter track.
  module CLI
    extend Dry::CLI::Registry

    register "collect", Collect
  end
end
