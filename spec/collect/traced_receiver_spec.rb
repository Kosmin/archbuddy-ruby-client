# frozen_string_literal: true

require "spec_helper"
require "prism"
require "archbuddy/reflect"
require "archbuddy/collect/adapters/ruby/symbol_table"
require "archbuddy/collect/adapters/ruby/resolver"

# R4.9 — the ONE tier that consumes evidence from an execution rather than from
# source. It exists for `purchase.recompute!` where `purchase` came out of an
# Interactor context: a value a caller in another file put into an instance
# hash, so there is no method to find, no owner to look up and no bytecode to
# read. Nothing static reaches it.
RSpec.describe "R4.9 traced receiver" do
  # Not a top-level constant: another spec file already defines `M` on Object,
  # and two files racing to own one generic name is a collision waiting to land.
  def rb = Archbuddy::Collect::Adapters::Ruby

  def table
    @table ||= begin
      t = rb::SymbolTable.new
      t.add_class(rb::SymbolTable::ClassEntry.new(fq_name: "Job", rel_file: "app/job.rb", line: 1))
      t.add_class(rb::SymbolTable::ClassEntry.new(fq_name: "Purchase", rel_file: "app/purchase.rb", line: 1))
      # The delegate-generated receiver, anchored at the `delegate` line.
      t.add_method(rb::SymbolTable::MethodEntry.new(fq_symbol: "Job#purchase", owner_fq: "Job",
                                                   name: "purchase", rel_file: "app/job.rb", line: 3))
      t.add_method(rb::SymbolTable::MethodEntry.new(fq_symbol: "Purchase#recompute!", owner_fq: "Purchase",
                                                   name: "recompute!", rel_file: "app/purchase.rb", line: 9))
      t
    end
  end

  def trace(rows)
    Archbuddy::Reflect::ReceiverTypes.from_manifest("returns" => rows)
  end

  def observed(cls, file: "app/job.rb", line: 3, name: "purchase")
    trace([{ "file" => file, "line" => line, "name" => name, "observed" => cls }])
  end

  def resolve(source, traced_types:, enclosing: "Job")
    node = Prism.parse(source).value.statements.body.first
    ctx = rb::RubyResolver::CallContext.new(name: node.name, receiver: node.receiver,
                                           enclosing_class: enclosing, table: table, node: node)
    rb::RubyResolver.new(table, reflection: nil, traced_types: traced_types).resolve(ctx)
  end

  it "resolves a chained call through a receiver whose type was OBSERVED" do
    r = resolve("purchase.recompute!", traced_types: observed({ "Purchase" => 40 }))
    expect([r.tier, r.target_fq]).to eq([:traced_receiver, "Purchase#recompute!"])
  end

  it "DECLINES when two flows put different types under the same address" do
    # The union is the true answer. A majority vote over runtime samples would
    # be a fabrication wearing a measurement's clothes.
    r = resolve("purchase.recompute!", traced_types: observed({ "Purchase" => 90, "Receipt" => 2 }))
    expect(r.tier).to eq(rb::RubyResolver::UNRESOLVED_TIER)
  end

  it "behaves EXACTLY as before when no trace was run — the normal case" do
    r = resolve("purchase.recompute!", traced_types: nil)
    expect(r.tier).to eq(rb::RubyResolver::UNRESOLVED_TIER)
  end

  it "joins on the ADDRESS, so an observation about a DIFFERENT line does not apply" do
    # Two classes can both have a `purchase` receiver. Keying by name alone
    # would let one class's runtime behaviour type the other's call site.
    r = resolve("purchase.recompute!", traced_types: observed({ "Purchase" => 40 }, line: 999))
    expect(r.tier).to eq(rb::RubyResolver::UNRESOLVED_TIER)
  end

  it "declines a DEEPER receiver expression — it has no single address" do
    r = resolve("context.purchase.recompute!", traced_types: observed({ "Purchase" => 40 }))
    expect(r.tier).to eq(rb::RubyResolver::UNRESOLVED_TIER)
  end

  it "declines when the receiver takes ARGUMENTS — a different call, not an accessor" do
    r = resolve("purchase(1).recompute!", traced_types: observed({ "Purchase" => 40 }))
    expect(r.tier).to eq(rb::RubyResolver::UNRESOLVED_TIER)
  end

  it "declines when the called name does not exist on the observed class" do
    # Observing the receiver's type is not licence to invent a target on it.
    r = resolve("purchase.no_such_method", traced_types: observed({ "Purchase" => 40 }))
    expect(r.tier).to eq(rb::RubyResolver::UNRESOLVED_TIER)
  end

  it "declines when the receiver itself was never parsed — no address to look up" do
    r = resolve("unparsed_thing.recompute!", traced_types: observed({ "Purchase" => 40 }))
    expect(r.tier).to eq(rb::RubyResolver::UNRESOLVED_TIER)
  end

  it "never lets a trace override a target the SOURCE can resolve" do
    # R3 and R3.4 both answer before R4.9 is reached; a trace is weaker
    # evidence than parsed source and must not outrank it.
    table.add_method(rb::SymbolTable::MethodEntry.new(fq_symbol: "Job#recompute!", owner_fq: "Job",
                                                     name: "recompute!", rel_file: "app/job.rb", line: 20))
    r = resolve("recompute!", traced_types: observed({ "Purchase" => 40 }))
    expect([r.tier, r.target_fq]).to eq([:self_instance, "Job#recompute!"])
  end
end
