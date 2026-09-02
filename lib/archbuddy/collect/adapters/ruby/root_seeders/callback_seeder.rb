# frozen_string_literal: true

require "prism"
require_relative "../root_seeder"
require_relative "../root_dsl/gem_reentry"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module RootSeeders
          # Seeds framework-CALLBACK targets as :callbacks ingress roots.
          #
          # `validate :valid_earn_loyalty` means ActiveModel will call
          # `#valid_earn_loyalty`. Nothing in the application ever does, so the
          # method sat unreachable with its branches outside every route — the
          # gem is the caller, and the graph does not model gem internals by
          # design. The right answer is not to traverse into the gem but to
          # recognise the RETURN direction as an INGRESS ROOT, which is exactly
          # how controllers and jobs are already handled.
          #
          # AN AST-SHAPED SEEDER: the declaration is a macro CALL in a class
          # body, so the evidence is in the AST, not in the table's structural
          # facts. Mirrors MiddlewareSeeder's one re-walk over the fragments.
          #
          # NEVER-FABRICATE (L4): the named method must provably exist on the
          # declaring class — `table.method?("Fq#name")` — or the declaration is
          # DECLINED. That gate is load-bearing here and not a formality:
          # `before_action :authenticate!` routinely names a method an
          # APPLICATION BASE CLASS or a gem supplies, and seeding a root for a
          # method this class does not define would invent an entrypoint.
          class CallbackSeeder < RootSeeder
            def self.root_type = :callbacks

            def root_type = :callbacks

            def seed(table, fragments: nil, root: nil)
              return if fragments.nil?

              scan = Scan.new
              fragments.each { |fragment| fragment.parsed_value.accept(scan) }

              scan.targets.each do |class_fq, names|
                names.each do |name|
                  fq = "#{class_fq}##{name}"
                  next unless table.method?(fq) # L4 gate — decline

                  table.mark_entrypoint(fq, :callbacks)
                end
              end
            end

            # One walk, collecting class_fq => Set<method name> for every
            # callback macro declared in a class or module body.
            class Scan < Prism::Visitor
              attr_reader :targets

              def initialize
                @namespace = []
                @targets   = {}
                super()
              end

              def visit_class_node(node) = with_namespace(node) { super }
              def visit_module_node(node) = with_namespace(node) { super }

              def visit_call_node(node)
                collect(node) if RootDsl::GemReentry.callback_macro?(node.name)
                super
              end

              private

              def with_namespace(node)
                @namespace.push(node.constant_path.slice)
                yield
              ensure
                @namespace.pop
              end

              # A callback declared OUTSIDE any class body has no declaring class
              # to resolve the symbol against, so there is nothing to seed.
              def collect(node)
                return if @namespace.empty?

                names = RootDsl::GemReentry.callback_targets(node)
                return if names.empty?

                (@targets[@namespace.join("::")] ||= []).concat(names)
              end
            end
          end
        end
      end
    end
  end
end
