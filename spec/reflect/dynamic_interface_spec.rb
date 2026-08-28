# frozen_string_literal: true

require "spec_helper"
require "archbuddy/reflect"

# VERBATIM `method_missing` disassembly captured from a booted Rails 6.1 app on
# Ruby 2.7.5. The classifier's whole job is to read what CRuby really emits for
# these three shapes, so fixtures we invented would only test our idea of them.
DELEGATOR_MM = <<~D
  == disasm: #<ISeq:method_missing@/ruby/2.7.0/delegate.rb:78 (78,17)-(89,5)> (catch: FALSE)
  local table (size: 5, argc: 1 [opts: 0, rest: 1, post: 0, block: 2, kw: -1@-1, kwrest: -1])
  0000 putobject                              true                      (  79)[LiCa]
  0004 putself                                                          (  80)[Li]
  0005 send                                   <calldata!mid:__getobj__, argc:0, FCALL>, block in method_missing
  0009 setlocal_WC_0                          target@4                  (  80)
  0022 opt_send_without_block                 <calldata!mid:target_respond_to?, argc:3, FCALL|ARGS_SIMPLE>
  0037 send                                   <calldata!mid:__send__, argc:2, ARGS_SPLAT|ARGS_BLOCKARG>, nil
  0040 leave                                                            (  89)[Re]
D

# ActiveStorage reaches its wrapped object through `attachment`, not
# `__getobj__` — the same SHAPE under a different name, which is why the rule
# must be structural.
DELEGATOR_MM_OTHER_NAME = <<~D
  0000 putself                                                          ( 309)[LiCa]
  0001 opt_send_without_block                 <calldata!mid:attachment, argc:0, FCALL|VCALL|ARGS_SIMPLE>
  0006 opt_send_without_block                 <calldata!mid:respond_to?, argc:1, ARGS_SIMPLE>
  0014 send                                   <calldata!mid:public_send, argc:2, ARGS_SPLAT|ARGS_BLOCKARG>, nil
  0017 leave
D

# OpenStruct: no re-dispatch anywhere, and the answer lives in @table — an
# instance hash whoever built the object filled in.
BAG_MM = <<~D
  0000 getlocal_WC_0                          mid@0                     (  --)
  0005 getinstancevariable                    @table, <is:0>
  0008 opt_send_without_block                 <calldata!mid:key?, argc:1, ARGS_SIMPLE>
  0012 getinstancevariable                    @table, <is:1>
  0020 opt_send_without_block                 <calldata!mid:new_ostruct_member!, argc:1, FCALL|ARGS_SIMPLE>
  0030 leave
D

# ActiveModel's attribute methods: dynamic, but neither shape — it consults
# framework metadata, which bytecode cannot lead us to.
UNKNOWN_MM = <<~D
  0000 putself
  0001 opt_send_without_block                 <calldata!mid:respond_to_without_attributes?, argc:1, FCALL|ARGS_SIMPLE>
  0009 opt_send_without_block                 <calldata!mid:matched_attribute_method, argc:1, FCALL|ARGS_SIMPLE>
  0015 opt_send_without_block                 <calldata!mid:attribute_missing, argc:2, FCALL|ARGS_SIMPLE>
  0020 leave
D

RSpec.describe ArchbuddyReflectProbe, "#classify_dynamism" do
  it "reads a DELEGATOR and names the method that fetches what it forwards to" do
    expect(described_class.classify_dynamism(DELEGATOR_MM))
      .to eq("kind" => "delegator", "via" => "__getobj__")
  end

  it "reads a delegator whose unwrap has a DIFFERENT NAME — the rule is structural" do
    # No vocabulary predicts `attachment`; what identifies it is a dynamic
    # re-dispatch plus a receiverless call producing the thing dispatched onto.
    expect(described_class.classify_dynamism(DELEGATOR_MM_OTHER_NAME))
      .to eq("kind" => "delegator", "via" => "attachment")
  end

  it "does not mistake a guard PREDICATE for the unwrap call" do
    expect(described_class.classify_dynamism(DELEGATOR_MM)["via"]).not_to eq("target_respond_to?")
  end

  it "reads a BAG, and records the instance state the answer actually lives in" do
    expect(described_class.classify_dynamism(BAG_MM))
      .to eq("kind" => "bag", "reads" => ["@table"])
  end

  it "declines `class` as an unwrap — it names no wrapped object" do
    # Barby::Barcode re-dispatches after consulting self.class. Structurally a
    # delegator, but `via: class` would promise a type lookup that cannot exist.
    disasm = <<~D
      0000 putself
      0001 opt_send_without_block                 <calldata!mid:class, argc:0, FCALL|VCALL|ARGS_SIMPLE>
      0009 send                                   <calldata!mid:send, argc:2, ARGS_SPLAT>, nil
      0012 leave
    D
    expect(described_class.classify_dynamism(disasm)).to eq("kind" => "unknown")
  end

  it "says UNKNOWN rather than guessing when it is neither shape" do
    expect(described_class.classify_dynamism(UNKNOWN_MM)).to eq("kind" => "unknown")
  end

  it "treats BasicObject's default as NOT dynamic — otherwise every class qualifies" do
    expect(described_class.dynamism_owner(Class.new)).to be_nil
  end

  it "walks the ANCESTOR CHAIN, which is the case that motivated this" do
    # Interactor::Context declares no method_missing of its own; it inherits one
    # from OpenStruct. An ownership test reports it as an ordinary class.
    ostruct_like = Class.new { def method_missing(*) = nil }
    subclass     = Class.new(ostruct_like)
    expect(subclass.instance_methods(false)).not_to include(:method_missing)
    expect(described_class.dynamism_owner(subclass)).to eq(ostruct_like)
  end
end

RSpec.describe Archbuddy::Reflect::DynamicInterface do
  def build(classes: {}, sources: {})
    described_class.from_manifest("dynamic_interfaces" => { "classes" => classes, "sources" => sources })
  end

  let(:table) do
    build(
      classes: { "Interactor::Context" => "OpenStruct", "Merchant" => "ActiveModel::AttributeMethods",
                 "RewardDecorator" => "Draper::AutomaticDelegation" },
      sources: { "OpenStruct" => { "kind" => "bag", "reads" => ["@table"] },
                 "ActiveModel::AttributeMethods" => { "kind" => "unknown" },
                 "Draper::AutomaticDelegation" => { "kind" => "delegator", "via" => "object" } }
    )
  end

  it "reports the source of a class's dynamism, not just that it has one" do
    expect(table.source_of("Interactor::Context")).to eq("OpenStruct")
    expect(table.kind_of("Interactor::Context")).to eq(:bag)
  end

  it "names the unwrap for a delegator — the one thing worth typing" do
    expect(table.unwrap_of("RewardDecorator")).to eq("object")
  end

  it "offers no unwrap for a bag, because there is nothing to unwrap" do
    expect(table.unwrap_of("Interactor::Context")).to be_nil
  end

  it "treats an ordinary class as ordinary" do
    expect(table.dynamic?("Purchase::Compute::UpdateStatus")).to be(false)
    expect(table.kind_of("Purchase::Compute::UpdateStatus")).to be_nil
  end

  it "makes a manifest without the section behave exactly as before it existed" do
    t = described_class.from_manifest("methods" => [])
    expect(t).to be_empty
    expect(t.dynamic?("Anything")).to be(false)
    expect(t.stats[:classes]).to eq(0)
  end

  it "ranks sources by REACH so the unknown bucket reads as a worklist" do
    ranked = table.sources_by_reach
    expect(ranked.map { |r| r[:source] }).to contain_exactly(
      "OpenStruct", "ActiveModel::AttributeMethods", "Draper::AutomaticDelegation"
    )
    expect(ranked.first[:reach]).to eq(1)
  end

  # Exception owns a C-defined method_missing that 1,302 error classes inherit
  # on a real service. True, and useless — an exception is never the receiver of
  # a call we were trying to resolve — so it must not head the worklist.
  it "keeps NATIVE out of the ranking while still counting it" do
    t = build(
      classes: { "SomeError" => "Exception", "Ctx" => "OpenStruct" },
      sources: { "Exception" => { "kind" => "native" }, "OpenStruct" => { "kind" => "bag" } }
    )
    expect(t.sources_by_reach.map { |r| r[:source] }).to eq(["OpenStruct"])
    expect(t.stats).to include(native: 1, bag: 1, classes: 2)
    expect(t.sources_by_reach(kinds: nil).map { |r| r[:source] }).to contain_exactly("Exception", "OpenStruct")
  end

  it "ranks by a supplied WEIGHT, because classes and call sites are different questions" do
    weights = { "Interactor::Context" => 2170, "Merchant" => 877, "RewardDecorator" => 201 }
    ranked = table.sources_by_reach(weight: ->(cls) { weights[cls] })
    expect(ranked.map { |r| [r[:source], r[:reach]] }).to eq(
      [["OpenStruct", 2170], ["ActiveModel::AttributeMethods", 877], ["Draper::AutomaticDelegation", 201]]
    )
  end

  it "counts by kind so the undecidable share is visible at a glance" do
    expect(table.stats).to include(classes: 3, sources: 3, bag: 1, unknown: 1, delegator: 1)
  end
end
