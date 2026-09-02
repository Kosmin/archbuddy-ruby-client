# frozen_string_literal: true

require "prism"
require_relative "../root_seeder"
require_relative "../root_dsl/gem_reentry"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module RootSeeders
          # Seeds classes named by an ORGANIZER macro as :organized ingress
          # roots.
          #
          # `organize A, B, C` is Interactor::Organizer's entire interface: the
          # GEM calls each of those in turn. The declaring class never mentions
          # them again, so the graph had no edge and no root for them — measured
          # on one service, 25 declarations naming 90 interactors, of which 44
          # had no caller at all and carried 108 branches outside every route.
          #
          # WHY A ROOT AND NOT AN EDGE, which is the whole design question here.
          # An edge from the organizer to each organized class would assert that
          # the organizer CALLS them, and it does not — it hands a list to a gem
          # which calls them, in an order and under conditions that live in the
          # gem. Drawing that edge would put gem control flow into the app graph
          # and make the organizer's cost the sum of its steps, which is a claim
          # about the gem's behaviour rather than the app's. Seeding each as its
          # own ingress root says the true and weaker thing: this code runs, from
          # outside, and here is its own cost.
          #
          # NEVER-FABRICATE (L4): the organized class's entry method must
          # provably exist in the table, or the constant is DECLINED. An
          # `organize` naming a class defined in a sibling engine, or one whose
          # `#call` we never parsed, seeds nothing.
          class OrganizedSeeder < RootSeeder
            def self.root_type = :organized

            def root_type = :organized

            def seed(table, fragments: nil, root: nil)
              return if fragments.nil?

              scan = Scan.new
              fragments.each { |fragment| fragment.parsed_value.accept(scan) }

              scan.constants.each do |const_fq|
                fq = resolve_entry(table, const_fq) or next

                table.mark_entrypoint(fq, :organized)
              end
            end

            private

            # The organized class's entry method, resolved along the ANCESTOR
            # CHAIN rather than only on the class itself.
            #
            # An interactor commonly inherits `#call` from an in-app base class,
            # and an own-class-only test declines exactly those — the same
            # ownership-versus-ancestry mistake that has cost this codebase four
            # separate wrong answers.
            def resolve_entry(table, const_fq)
              entry = RootDsl::GemReentry::ORGANIZED_ENTRY
              direct = "#{const_fq}##{entry}"
              return direct if table.method?(direct)

              table.ancestor_method_fq(const_fq, entry)
            end

            # One walk collecting every constant named by an organizer macro.
            # NOT scoped by namespace: `organize` names constants that are
            # already written as the author qualified them, and re-qualifying
            # against the enclosing module would invent a name.
            class Scan < Prism::Visitor
              attr_reader :constants

              def initialize
                @constants = []
                super()
              end

              def visit_call_node(node)
                if RootDsl::GemReentry.organizer_macro?(node.name)
                  @constants.concat(RootDsl::GemReentry.organized_constants(node))
                end
                super
              end
            end
          end
        end
      end
    end
  end
end
