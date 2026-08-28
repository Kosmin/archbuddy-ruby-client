# frozen_string_literal: true

require_relative "reflect/probe"
require_relative "reflect/boot_strategy"
require_relative "reflect/registry"
require_relative "reflect/runner"
require_relative "reflect/merge"
require_relative "reflect/method_table"
require_relative "reflect/macro_scan"
require_relative "reflect/forwarding"
require_relative "reflect/dynamic_interface"
require_relative "reflect/constant_scan"

module Archbuddy
  # BOOT REFLECTION (v0.13-reflect).
  #
  # Closes the DEFINITION gap that static parsing cannot: methods which never
  # appear as `def` in source because a macro generated them at class-body
  # execution — attr_accessor, has_many, delegate, scopes, define_method. In a
  # Rails model these are the majority of the public surface.
  #
  # Requires only that the app BOOTS. No test suite, no traffic, no fixtures.
  # Distinct from (and cheaper than) TracePoint, which additionally needs the
  # relevant code PATHS to execute and so is bounded by coverage.
  module Reflect
  end
end
