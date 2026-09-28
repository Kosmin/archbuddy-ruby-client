# frozen_string_literal: true

require "spec_helper"
require "archbuddy/reflect"
require "archbuddy/collect/adapters/ruby/symbol_table"

# The reopened-class blind spot.
#
#   # engine/app/models/order.rb
#   class Order < ApplicationRecord ... end
#   # app/models/order.rb
#   class Order ... end          # <- all this service parses
#
# The second file is the only one in the collection root, so the parsed
# superclass is nil and every chain-walked predicate answers false for a class
# that is plainly an ORM model. Measured on one service: 215 of 997 parsed
# classes, and a graph holding 19 database nodes.
RSpec.describe Archbuddy::Reflect::Ancestry do
  def rb = Archbuddy::Collect::Adapters::Ruby

  def reopened_table(ancestry: nil)
    t = rb::SymbolTable.new(ancestry: ancestry)
    # No superclass — this is the REOPENING, which is all the parser sees.
    t.add_class(rb::SymbolTable::ClassEntry.new(fq_name: "Order",
                                                rel_file: "app/models/order.rb", line: 3))
    t
  end

  describe ".from_manifest" do
    it "reads the superclasses section" do
      expect(described_class.from_manifest({ "superclasses" => { "Order" => "ApplicationRecord" } }))
        .to eq({ "Order" => "ApplicationRecord" })
    end

    # A manifest captured before schema 5 must behave exactly as before.
    it "is empty for a manifest with no superclasses section" do
      expect(described_class.from_manifest({ "methods" => [] })).to eq({})
    end

    it "is empty for nil and for a non-hash section" do
      expect(described_class.from_manifest(nil)).to eq({})
      expect(described_class.from_manifest({ "superclasses" => [] })).to eq({})
    end

    # Never fabricate a link out of a malformed entry.
    it "drops entries that are not two non-empty strings" do
      manifest = { "superclasses" => { "A" => "B", "" => "B", "C" => "", "D" => 3, "E" => nil } }
      expect(described_class.from_manifest(manifest)).to eq({ "A" => "B" })
    end
  end

  describe "SymbolTable#chain_any? with reflection ancestry" do
    it "declines on a reopened model when reflection did not run" do
      expect(reopened_table.active_record_class?("Order")).to be false
    end

    it "types a reopened model through the reflection link" do
      t = reopened_table(ancestry: { "Order" => "ApplicationRecord" })
      expect(t.active_record_class?("Order")).to be true
    end

    # The link lands on a class this run never parsed, and must still be walked.
    it "walks through unparsed intermediates to reach the base" do
      t = reopened_table(ancestry: { "Order" => "Platform::Record",
                                     "Platform::Record" => "ActiveRecord::Base" })
      expect(t.active_record_class?("Order")).to be true
    end

    it "still declines when nothing above is an ORM base" do
      t = reopened_table(ancestry: { "Order" => "Object" })
      expect(t.active_record_class?("Order")).to be false
    end

    # PARSED WINS: reflection describes a boot that may have loaded a different
    # revision than the source in front of us.
    it "prefers the parsed superclass over the reflection link" do
      t = rb::SymbolTable.new(ancestry: { "Widget" => "ApplicationRecord" })
      t.add_class(rb::SymbolTable::ClassEntry.new(fq_name: "Widget", rel_file: "app/widget.rb",
                                                  line: 1, superclass: "Object"))
      expect(t.active_record_class?("Widget")).to be false
    end

    it "terminates on a cycle in the reflection map" do
      t = reopened_table(ancestry: { "Order" => "A", "A" => "Order" })
      expect(t.active_record_class?("Order")).to be false
    end

    # Method lookup needs the real MRO, mixins included; the ancestry map has no
    # mixin order, so extending the walk there could name a method that never
    # runs. Declining is the honest answer.
    it "does NOT extend ancestor_method_fq through the reflection link" do
      t = reopened_table(ancestry: { "Order" => "Base" })
      t.add_class(rb::SymbolTable::ClassEntry.new(fq_name: "Base", rel_file: "app/base.rb", line: 1))
      t.add_method(rb::SymbolTable::MethodEntry.new(fq_symbol: "Base#save", owner_fq: "Base",
                                                    name: "save", singleton: false,
                                                    rel_file: "app/base.rb", line: 2))
      expect(t.ancestor_method_fq("Order", "save")).to be_nil
    end
  end
end
