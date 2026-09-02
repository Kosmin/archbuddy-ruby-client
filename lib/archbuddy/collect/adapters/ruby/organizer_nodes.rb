# frozen_string_literal: true

require "prism"
require_relative "root_dsl/gem_reentry"

module Archbuddy
  module Collect
    module Adapters
      module Ruby
        # ORGANIZER SEQUENCES, as nodes and edges rather than as bare roots.
        #
        # `organize A, B, C` is Interactor::Organizer's whole interface, and the
        # organizer's behaviour IS that sequence — the gem is a trampoline, not a
        # participant with logic of its own. So the honest model is an edge from
        # the organizer to each step, exactly as `delegate` gets an edge even
        # though a gem generated the forwarding method.
        #
        # WHY THIS WAS ROOTS FIRST, and what changed. Seeding each step as its
        # own ingress root made them reachable but left them disconnected: the
        # organizer had no cost, the steps had no caller, and a reader asking
        # "what does Clawback do" got nothing. Edges give discoverability and put
        # the sequence's cost where it belongs. The earlier caution — that an
        # edge would import gem control flow — does not survive contact with what
        # `organize` means: the steps run because this class listed them, in the
        # order this class listed them, both facts stated in app source.
        #
        # THE EDGE NEEDS A SOURCE, WHICH DID NOT EXIST. An organizer declares no
        # `def call` — `Interactor::Organizer` supplies it, so it is gem-defined
        # and correctly excluded from generated-node minting (which requires an
        # application definition site). Verified on a real service: all 25
        # organizer classes had NO `#call` node at all. So one is minted here,
        # the same way a rake task is minted for a surface with no DefNode.
        #
        # No branch counts: a sequence has no decision points, so RawNode's
        # defaults (1 branch, 0 decisions) are exactly right. The organizer's
        # cost then comes from its edges and their subtrees, which is the point.
        module OrganizerNodes
          Organizer = Struct.new(:class_fq, :call_fq, :rel_file, :line, :step_fqs,
                                 keyword_init: true)

          module_function

          # @param fragments [Array<Collect::Fragment>]
          # @param table [Ruby::SymbolTable] after the definition pass
          # @return [Array<Organizer>]
          def build(fragments:, table:)
            return [] if fragments.nil?

            scan = Scan.new
            fragments.each do |f|
              scan.rel_file = f.rel_file
              f.parsed_value.accept(scan)
            end

            scan.declarations.filter_map do |class_fq, decl|
              next unless table.class_for(class_fq) # never parsed — not ours to mint

              Organizer.new(
                class_fq: class_fq,
                call_fq:  "#{class_fq}##{RootDsl::GemReentry::ORGANIZED_ENTRY}",
                rel_file: decl[:rel_file], line: decl[:line],
                step_fqs: decl[:constants].filter_map { |c| step_entry(table, c) }.uniq
              )
            end
          end

          # A step's entry method, resolved along the ANCESTOR CHAIN.
          #
          # An interactor commonly inherits `#call` from an in-app base class,
          # and an own-class-only test declines exactly those — the
          # ownership-versus-ancestry mistake this codebase has paid for
          # repeatedly. A step we cannot find is DROPPED, not invented: an
          # `organize` naming a class from a sibling engine seeds no edge.
          def step_entry(table, const_fq)
            entry = RootDsl::GemReentry::ORGANIZED_ENTRY
            direct = "#{const_fq}##{entry}"
            return direct if table.method?(direct)

            table.ancestor_method_fq(const_fq, entry)
          end

          # Collects class_fq => { rel_file:, line:, constants: } for every
          # `organize` declaration. The rel_file/line anchor the minted node at
          # the declaration, so the id-map points at code a reader can open.
          class Scan < Prism::Visitor
            attr_reader :declarations
            # Set by the caller before each fragment. One scan across all
            # fragments (namespaces do not span files, so nothing leaks) with
            # the current file supplied from outside.
            attr_accessor :rel_file

            def initialize
              @namespace    = []
              @declarations = {}
              @rel_file     = nil
              super()
            end

            def visit_class_node(node) = with_namespace(node) { super }
            def visit_module_node(node) = with_namespace(node) { super }

            def visit_call_node(node)
              collect(node) if RootDsl::GemReentry.organizer_macro?(node.name)
              super
            end

            private

            def with_namespace(node)
              @namespace.push(node.constant_path.slice)
              yield
            ensure
              @namespace.pop
            end

            def collect(node)
              return if @namespace.empty?

              consts = RootDsl::GemReentry.organized_constants(node)
              return if consts.empty?

              d = (@declarations[@namespace.join("::")] ||=
                     { rel_file: @rel_file, line: node.location.start_line, constants: [] })
              d[:constants].concat(consts)
            end
          end
        end
      end
    end
  end
end
