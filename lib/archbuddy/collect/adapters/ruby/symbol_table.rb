# frozen_string_literal: true

require_relative "vocab"
require_relative "grape_dsl"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # Catalogue of every class/module and method definition discovered by
        # the DefinitionPass (Pass 1). The ResolutionPass (Pass 2) consults it to
        # decide whether a call site targets an app symbol we actually know.
        class SymbolTable
          # A defined class or module, with the metadata the resolver needs.
          ClassEntry = Struct.new(
            :fq_name, :rel_file, :line, :superclass, keyword_init: true
          ) do
            def active_record?
              Vocab::ACTIVE_RECORD_BASES.include?(superclass.to_s)
            end

            def controller?
              Vocab::CONTROLLER_BASES.include?(superclass.to_s) ||
                fq_name.to_s.end_with?("Controller")
            end

            # True when this class is a Grape API (`class Foo < Grape::API`).
            # Grape endpoint verb-blocks live directly inside such a class; the
            # DefinitionPass mints a synthetic endpoint MethodEntry per block.
            def grape_api?
              GrapeDsl.grape_api_superclass?(superclass)
            end
          end

          # A defined method. `singleton` distinguishes `Foo.x` (true) from
          # `Foo#x` (false). `owner_fq` is the enclosing class/module fq name.
          # `branches`/`decisions` are the opaque per-method path-cost integers
          # computed by the BranchCounter (P3+P9): branches = Π(arm-count) total
          # execution paths (default 1), decisions = raw decision-point count
          # (default 0).
          # `endpoint` (default false) marks a synthetic Grape endpoint handler
          # block minted by the DefinitionPass — it has no DefNode of its own but
          # IS an addressable node (kind:"endpoint") and an entrypoint, and its
          # block body resolves to real edges in Pass 2.
          MethodEntry = Struct.new(
            :fq_symbol, :owner_fq, :name, :singleton, :rel_file, :line,
            :branches, :decisions, :endpoint, keyword_init: true
          ) do
            def initialize(*)
              super
              self.endpoint = false if endpoint.nil?
            end
          end

          def initialize
            @classes = {}  # fq_name => ClassEntry
            @methods = {}  # fq_symbol => MethodEntry
          end

          attr_reader :classes, :methods

          def add_class(entry)
            # First definition wins for metadata (reopened classes keep the
            # original def site for a stable class rollup id).
            @classes[entry.fq_name] ||= entry
          end

          def add_method(entry)
            @methods[entry.fq_symbol] ||= entry
          end

          def class_for(fq_name)
            @classes[fq_name]
          end

          def method_for(fq_symbol)
            @methods[fq_symbol]
          end

          def method?(fq_symbol)
            @methods.key?(fq_symbol)
          end

          # Walk the superclass chain (within known app classes) testing a
          # predicate; used so a model that extends an intermediate AR subclass
          # still counts as ActiveRecord.
          def chain_any?(fq_name)
            seen = {}
            current = @classes[fq_name]
            while current && !seen[current.fq_name]
              return true if yield(current)

              seen[current.fq_name] = true
              current = @classes[current.superclass]
            end
            false
          end

          def active_record_class?(fq_name)
            chain_any?(fq_name, &:active_record?)
          end

          def controller_class?(fq_name)
            chain_any?(fq_name, &:controller?)
          end
        end
      end
    end
  end
end
