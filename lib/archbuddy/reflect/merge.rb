# frozen_string_literal: true

module Archbuddy
  module Reflect
    # Classifies every reflected method against the STATIC parse.
    #
    # The discriminator is source LINE, not name. `attr_accessor :customer` and a
    # hand-written `def customer=(v)` both produce a method called `customer=`;
    # they are indistinguishable by name and trivially separable by line — the
    # generated one points at the macro call, the real one at its own `def`.
    #
    # That distinction matters architecturally: a generated RELATION
    # (has_many/belongs_to) is a database exit and one of the most significant
    # things in the file. "Generated" is therefore not a synonym for "ignore" —
    # we classify by WHAT generated it, which is why the generator line is kept.
    #
    # POSITION CHANGED — trivial accessors DO become nodes now (GeneratedNodes).
    # This comment used to say they should not, on the grounds that they would
    # "inflate counts and dilute every metric". That was written when the
    # alternative was the shared `<external>` sink, where omitting them cost
    # nothing. Under the per-caller analysis boundary it is no longer true: a
    # call to an unminted `attr_reader` does not vanish, it becomes a
    # `<boundary:unknown:...>` node — the SAME node count, cost 1 either way,
    # but labelled "tracking stopped here" when we know exactly what it is. The
    # count argument survived the change in what the alternative was; the
    # accuracy argument did not. Measured on one service: 80 trivial accessors
    # against 787 delegations, so the count was never the deciding term anyway.
    class Merge
      # Macros whose products are pure data access — no control flow, no I/O.
      TRIVIAL_MACROS = %w[attr_accessor attr_reader attr_writer].freeze
      # Macros whose products cross a boundary (DB / another object).
      RELATION_MACROS = %w[has_many has_one belongs_to has_and_belongs_to_many].freeze
      DELEGATION_MACROS = %w[delegate def_delegator def_delegators].freeze

      Entry = Struct.new(:cls, :name, :scope, :file, :line, :kind, :macro, keyword_init: true)

      # @param manifest [Hash] probe output
      # @param def_lines [Hash{String => Hash{Integer => Array<String>}}] rel_file =>
      #   line => the method NAMES declared by `def` on that line
      # @param macro_calls [Hash{String => Hash{String => String}}] class name =>
      #   generated-method-name => macro name. Built by the STATIC pass from call
      #   sites like `has_many :line_items` / `attr_accessor :customer`, i.e. from
      #   the SOURCE the developer actually wrote.
      def initialize(manifest, def_lines, macro_calls: {})
        @manifest = manifest
        @def_lines = def_lines
        @macro_calls = macro_calls
      end

      # @return [Array<Entry>]
      def classify
        (@manifest["methods"] || []).map do |m|
          file = m["file"]
          line = m["line"]
          if file.nil? || line.nil?
            # nil source_location == C-defined. Recorded explicitly rather than
            # dropped silently, so a consumer can see it was considered.
            next Entry.new(cls: m["class"], name: m["name"], scope: m["scope"],
                           file: nil, line: nil, kind: :native, macro: nil)
          end

          if real_def?(file, line, m["name"])
            Entry.new(cls: m["class"], name: m["name"], scope: m["scope"],
                      file: file, line: line, kind: :real_def, macro: nil)
          else
            macro = @macro_calls.dig(m["class"], m["name"])
            Entry.new(cls: m["class"], name: m["name"], scope: m["scope"],
                      file: file, line: line, kind: kind_for(macro), macro: macro)
          end
        end.compact
      end

      # Summary counts — what boot reflection ADDED over the static parse.
      def summary
        classify.group_by(&:kind).transform_values(&:size)
      end

      private

      # A method is a REAL definition only when the `def` at that line declares
      # THIS name. Line presence alone is not enough: `def self.has_many(n) =
      # define_method(n){...}` both IS a def and GENERATES a differently-named
      # method on the same line, so a bare line check misreports the generated
      # one as hand-written.
      def real_def?(file, line, name)
        entry = (@def_lines[file] || {})[line]
        return false if entry.nil?

        Array(entry).include?(name)
      end

      def kind_for(macro)
        return :generated_trivial if TRIVIAL_MACROS.include?(macro)
        return :generated_relation if RELATION_MACROS.include?(macro)
        return :generated_delegation if DELEGATION_MACROS.include?(macro)

        :generated_other
      end

      # Macro attribution comes from the STATIC call site, never from the
      # generating line.
      #
      # WHY: `source_location` on a generated method points at wherever
      # `define_method` was invoked — which for `has_many` is inside the
      # ActiveRecord gem, not the model. Reading that line yields the gem's
      # internals, never "has_many". The developer-authored `has_many :line_items`
      # IS statically visible in the model, so we match the reflected method NAME
      # against the macro call's symbol ARGUMENTS instead. That works no matter
      # where the generating code lives.
    end
  end
end
