# frozen_string_literal: true

require "spec_helper"
require "prism"
require "archbuddy/collect/adapters/ruby/symbol_table"
require "archbuddy/collect/adapters/ruby/resolver"

# R4.4 — an ORM chain rooted at a model constant.
#
#   Order.unscoped.find(id).recalculate_total
#
# Measured on a real service, that ONE unresolved call site orphaned the
# costliest subtree in the codebase: 8.16e+11 paths, 151,250x the entire scored
# production cost, invisible because the target had no in-edge. The job calling
# it was already a rooted entrypoint; only the receiver was untypeable.
RSpec.describe "R4.4 ORM chain receiver" do
  def rb = Archbuddy::Collect::Adapters::Ruby

  def table
    @table ||= begin
      t = rb::SymbolTable.new
      t.add_class(rb::SymbolTable::ClassEntry.new(fq_name: "Order", rel_file: "app/models/order.rb",
                                                  line: 1, superclass: "ApplicationRecord"))
      t.add_class(rb::SymbolTable::ClassEntry.new(fq_name: "Plain", rel_file: "app/plain.rb", line: 1))
      t.add_method(rb::SymbolTable::MethodEntry.new(fq_symbol: "Order#recalculate_total", owner_fq: "Order",
                                                    name: "recalculate_total", rel_file: "app/models/order.rb",
                                                    line: 107))
      t.add_method(rb::SymbolTable::MethodEntry.new(fq_symbol: "Plain#go", owner_fq: "Plain",
                                                    name: "go", rel_file: "app/plain.rb", line: 3))
      t
    end
  end

  def resolve(source)
    node = Prism.parse(source).value.statements.body.first
    ctx = rb::RubyResolver::CallContext.new(name: node.name, receiver: node.receiver,
                                            enclosing_class: "SomeJob", table: table, node: node)
    rb::RubyResolver.new(table).resolve(ctx)
  end

  it "types the exact shape that orphaned the subtree" do
    r = resolve("Order.unscoped.find(id).recalculate_total")
    expect([r.tier, r.target_fq]).to eq([:orm_chain, "Order#recalculate_total"])
  end

  it "types a single-hop record verb" do
    expect(resolve("Order.find(id).recalculate_total").target_fq).to eq("Order#recalculate_total")
  end

  it "walks several relation verbs before the record verb collapses them" do
    r = resolve("Order.unscoped.where(x: 1).order(:id).first.recalculate_total")
    expect(r.target_fq).to eq("Order#recalculate_total")
  end

  it "DECLINES a chain that ends on a relation — an instance method on a Relation is a scope" do
    expect(resolve("Order.where(x: 1).recalculate_total").tier)
      .to eq(rb::RubyResolver::UNRESOLVED_TIER)
  end

  it "DECLINES a chain through a scalar verb — pluck is not the model" do
    expect(resolve("Order.pluck(:id).recalculate_total").tier)
      .to eq(rb::RubyResolver::UNRESOLVED_TIER)
  end

  it "DECLINES when the root constant is not a proven ActiveRecord class" do
    # `Plain` is parsed but has no ORM base class; typing it would invent an edge.
    expect(resolve("Plain.find(id).go").tier).to eq(rb::RubyResolver::UNRESOLVED_TIER)
  end

  it "DECLINES when the method does not exist on the model" do
    expect(resolve("Order.find(id).no_such_method").tier)
      .to eq(rb::RubyResolver::UNRESOLVED_TIER)
  end

  it "DECLINES a chain continuing PAST a record — that needs association types" do
    # `find(id).account.name`: typing `account` is a different question.
    expect(resolve("Order.find(id).account.name").tier)
      .to eq(rb::RubyResolver::UNRESOLVED_TIER)
  end

  it "DECLINES when any hop takes a block — the value may not be the model" do
    expect(resolve("Order.where(x: 1).find { |p| p.ok? }.recalculate_total").tier)
      .to eq(rb::RubyResolver::UNRESOLVED_TIER)
  end

  it "resolves an INHERITED method along the ancestor chain" do
    table.add_class(rb::SymbolTable::ClassEntry.new(fq_name: "Sub", rel_file: "app/sub.rb",
                                                    line: 1, superclass: "Order"))
    expect(resolve("Sub.find(id).recalculate_total").target_fq).to eq("Order#recalculate_total")
  end
end
