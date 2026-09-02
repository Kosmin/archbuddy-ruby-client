# frozen_string_literal: true

require "prism"
require_relative "../root_seeder"
require_relative "../root_dsl/gem_reentry"
require_relative "../organizer_nodes"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        module RootSeeders
          # Seeds the ORGANIZER's own `#call` as an :organized ingress root.
          #
          # THE STEPS ARE EDGES, NOT ROOTS — see OrganizerNodes, which mints the
          # organizer's `#call` and links one edge per organized step. Seeding
          # the steps was the first design and it was the weaker one: they became
          # reachable but stayed disconnected, so the organizer had no cost and a
          # reader asking "what does Clawback do" got nothing back.
          #
          # WHAT IS LEFT FOR A ROOT is the organizer itself. Measured on a real
          # service: of 25 organizers, 18 ARE invoked from app source (and now
          # get their in-edge from R4's const-instance fallback, since the minted
          # `#call` exists), and 7 are not — dispatched from a sibling engine or
          # dynamically. Those 7 anchor nothing without a root, and their whole
          # step sequence would go unreachable with them.
          #
          # Seeding all 25 rather than only the 7 mirrors JobSeeder exactly: a
          # job's `#perform` is seeded whether or not something also calls it
          # directly, because being an ingress is a property of the DECLARATION,
          # not of whether a caller happens to exist elsewhere in the tree.
          #
          # NEVER-FABRICATE (L4): gated on the minted `#call` actually being in
          # the table. If OrganizerNodes declined to mint it — the class was
          # never parsed — this seeds nothing.
          class OrganizedSeeder < RootSeeder
            def self.root_type = :organized

            def root_type = :organized

            def seed(table, fragments: nil, root: nil)
              return if fragments.nil?

              OrganizerNodes.build(fragments: fragments, table: table).each do |organizer|
                next unless table.method?(organizer.call_fq) # L4 gate — decline

                table.mark_entrypoint(organizer.call_fq, :organized)
              end
            end
          end
        end
      end
    end
  end
end
