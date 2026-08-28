# frozen_string_literal: true

require "spec_helper"
require "archbuddy/reflect"

# The fixtures below are VERBATIM disassembly captured from a booted Rails 6.1
# application on Ruby 2.7.5 (`RubyVM::InstructionSequence.of(...).disasm`), not
# hand-written approximations. The rule under test exists to read what CRuby
# really emits for `delegate`, so a fixture we invented would test our idea of
# the bytecode rather than the bytecode.
REAL_DELEGATE_DISASM = <<~DISASM
  == disasm: #<ISeq:merchant@/app/interactors/purchase/compute/update_status.rb:11 (11,1168)-(11,1444)> (catch: TRUE)
  == catch table
  | catch type: rescue st: 0000 ed: 0017 sp: 0000 cont: 0018
  | == disasm: #<ISeq:rescue in merchant@/app/interactors/purchase/compute/update_status.rb:11> (catch: TRUE)
  | local table (size: 1, argc: 0 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
  | [ 1] $!@0
  | 0000 getlocal_WC_0                          $!@0                      (  11)
  | 0019 getlocal_WC_1                          _@2[Li]
  | 0021 opt_nil_p                              <calldata!mid:nil?, argc:0, ARGS_SIMPLE>
  | 0027 opt_send_without_block                 <calldata!mid:name, argc:0, ARGS_SIMPLE>
  | 0048 opt_send_without_block                 <calldata!mid:inspect, argc:0, FCALL|ARGS_SIMPLE>
  | 0056 opt_send_without_block                 <calldata!mid:to_s, argc:0, FCALL|ARGS_SIMPLE>
  | 0061 opt_send_without_block                 <calldata!mid:raise, argc:2, FCALL|ARGS_SIMPLE>
  | 0065 opt_send_without_block                 <calldata!mid:raise, argc:0, FCALL|VCALL|ARGS_SIMPLE>
  | catch type: retry  st: 0017 ed: 0018 sp: 0000 cont: 0000
  |------------------------------------------------------------------------
  local table (size: 4, argc: 0 [opts: 0, rest: 0, post: 0, block: 1, kw: -1@-1, kwrest: -1])
  [ 4] *@0<Rest>  [ 3] &@1<Block> [ 2] _@2        [ 1] e@3
  0000 putself                                                          (  11)[LiCa]
  0001 opt_send_without_block                 <calldata!mid:purchase, argc:0, FCALL|VCALL|ARGS_SIMPLE>
  0003 setlocal_WC_0                          _@2
  0005 getlocal_WC_0                          _@2
  0007 getlocal_WC_0                          *@0
  0009 splatarray                             false
  0011 getblockparamproxy                     &@1, 0
  0014 send                                   <calldata!mid:merchant, argc:1, ARGS_SPLAT|ARGS_BLOCKARG>, nil
  0017 nop
  0018 leave                                  [Re]
DISASM

# An ordinary hand-written method with real work in it.
REAL_NON_FORWARDER_DISASM = <<~DISASM
  == disasm: #<ISeq:active_page?@/app/helpers/application_helper.rb:4 (4,2)-(7,5)>
  local table (size: 1, argc: 1 [opts: 0, rest: -1, post: 0, block: -1, kw: -1@-1, kwrest: -1])
  0000 putself                                                          (   5)[LiCa]
  0001 opt_send_without_block                 <calldata!mid:params, argc:0, FCALL|VCALL|ARGS_SIMPLE>
  0003 putself
  0004 opt_send_without_block                 <calldata!mid:params, argc:0, FCALL|VCALL|ARGS_SIMPLE>
  0006 opt_send_without_block                 <calldata!mid:nil?, argc:0, ARGS_SIMPLE>
  0008 leave                                                            (   7)[Re]
DISASM

RSpec.describe ArchbuddyReflectProbe, "#parse_forward" do
  it "recovers the forwarding pair from REAL `delegate` bytecode" do
    expect(described_class.parse_forward(REAL_DELEGATE_DISASM))
      .to eq("to" => "purchase", "via" => "merchant")
  end

  it "ignores the catch-table clause, which is where the DelegationError noise lives" do
    # `nil?`, `name`, `inspect`, `to_s` and two `raise`s all appear in the
    # fixture. If they were counted the send total would be eight, not two, and
    # nothing would ever be recognised as a forwarder.
    expect(REAL_DELEGATE_DISASM).to include("mid:raise")
    expect(described_class.parse_forward(REAL_DELEGATE_DISASM)["to"]).to eq("purchase")
  end

  it "declines a method that does real work rather than forwarding" do
    expect(described_class.parse_forward(REAL_NON_FORWARDER_DISASM)).to be_nil
  end

  it "declines when the first send has a RECEIVER — that is not a self-forward" do
    disasm = <<~D
      0000 opt_getconstant_path                   <ic:0 Foo>
      0001 opt_send_without_block                 <calldata!mid:bar, argc:0, ARGS_SIMPLE>
      0003 opt_send_without_block                 <calldata!mid:baz, argc:0, ARGS_SIMPLE>
      0005 leave
    D
    expect(described_class.parse_forward(disasm)).to be_nil
  end

  it "reads a hand-rolled `define_method(:x) { y.z }` with the same rule, no vocabulary" do
    disasm = <<~D
      0000 putself
      0001 opt_send_without_block                 <calldata!mid:y, argc:0, FCALL|VCALL|ARGS_SIMPLE>
      0003 opt_send_without_block                 <calldata!mid:z, argc:0, ARGS_SIMPLE>
      0005 leave
    D
    expect(described_class.parse_forward(disasm)).to eq("to" => "y", "via" => "z")
  end

  it "is an ENRICHMENT: a Ruby without RubyVM yields nil, never an exception" do
    hide_const("RubyVM") if defined?(RubyVM)
    expect(described_class.forwards_for(String.instance_method(:upcase))).to be_nil
  end

  # REGRESSION. The forwarding gate must use `app_path?`, not `external_site`.
  # They disagree on exactly one population — gems installed UNDER the project
  # root — and that population is where ActiveRecord's association shim lives.
  # Gating on `external_site` yielded 30,930 facts out of a vendored gem tree
  # against 1,349 real ones, 25,546 of them naming AR's `#association` internals
  # as if it were the developer's delegation target.
  it "does not treat a gem vendored UNDER the project root as application source" do
    root = "/srv/app"
    vendored = "#{root}/.devbox/virtenv/ruby/gems/activerecord-6.1.7/lib/associations.rb"

    expect(described_class.app_path?(vendored, root)).to be(false)
    # external_site would have said "not external", which is the trap.
    expect(described_class.external_site([vendored, 1], root)).to be(false)
    expect(described_class.app_path?("#{root}/app/models/order.rb", root)).to be(true)
  end
end

RSpec.describe Archbuddy::Reflect::MacroScan, "delegation targets" do
  def scan(src)
    described_class.scan_all(["x.rb"], read: ->(_) { src })
  end

  it "reads the `to:` target off the macro call site" do
    r = scan(<<~RUBY)
      class Order
        delegate :merchant, :user, to: :purchase
      end
    RUBY
    expect(r.delegations["Order"]).to eq("merchant" => "purchase", "user" => "purchase")
  end

  it "still reports macro attribution unchanged — the two outputs are independent" do
    r = scan(<<~RUBY)
      class Order
        delegate :merchant, to: :purchase
        attr_accessor :total
      end
    RUBY
    expect(r.macros["Order"]).to include("merchant" => "delegate", "total" => "attr_accessor",
                                         "total=" => "attr_accessor")
    expect(r.delegations["Order"]).to eq("merchant" => "purchase")
  end

  it "keeps `scan` returning exactly the macro map it always did" do
    src = "class Order\n  delegate :merchant, to: :purchase\nend\n"
    expect(described_class.scan(["x.rb"], read: ->(_) { src }))
      .to eq("Order" => { "merchant" => "delegate" })
  end

  it "DECLINES `to: :class` — that hop reaches the class, not a sibling method" do
    r = scan("class Order\n  delegate :name, to: :class\nend\n")
    expect(r.delegations["Order"]).to be_empty
  end

  it "DECLINES a non-symbol target rather than inventing an edge" do
    r = scan("class Order\n  delegate :name, to: SOME_CONST\nend\n")
    expect(r.delegations["Order"]).to be_empty
  end
end

RSpec.describe Archbuddy::Reflect::Forwarding do
  def manifest(*methods)
    { "methods" => methods }
  end

  def entry(cls, name, forwards: nil)
    { "class" => cls, "name" => name }.tap { |h| h["forwards"] = forwards if forwards }
  end

  it "marks a fact AGREED when source text and compiled bytecode independently match" do
    t = described_class.from(
      manifest(entry("Order", "merchant", forwards: { "to" => "purchase", "via" => "merchant" })),
      delegations: { "Order" => { "merchant" => "purchase" } }
    )
    f = t.fact("Order", "merchant")
    expect([f.to, f.via, f.source]).to eq(%w[purchase merchant] + [:agreed])
  end

  it "emits NOTHING when the two derivations contradict each other" do
    t = described_class.from(
      manifest(entry("Order", "merchant", forwards: { "to" => "receipt", "via" => "merchant" })),
      delegations: { "Order" => { "merchant" => "purchase" } }
    )
    expect(t.fact("Order", "merchant")).to be_nil
    expect(t.conflicts.first).to include("Order#merchant")
    expect(t.stats[:conflicts]).to eq(1)
  end

  it "accepts bytecode alone — it reads DSLs the static vocabulary has never heard of" do
    t = described_class.from(
      manifest(entry("Order", "total", forwards: { "to" => "cart", "via" => "sum" }))
    )
    f = t.fact("Order", "total")
    expect([f.to, f.via, f.source]).to eq(%w[cart sum] + [:bytecode])
  end

  it "accepts static alone — it works on an application that cannot boot" do
    t = described_class.from(manifest(entry("Order", "merchant")),
                             delegations: { "Order" => { "merchant" => "purchase" } })
    f = t.fact("Order", "merchant")
    # `via` is the method's own name: that identity IS what `delegate` means.
    expect([f.to, f.via, f.source]).to eq(%w[purchase merchant] + [:static])
  end

  it "says nothing about a method neither source described" do
    t = described_class.from(manifest(entry("Order", "call")))
    expect(t.fact("Order", "call")).to be_nil
    expect(t).to be_empty
  end

  it "reports per-derivation counts so a silent tier failure is visible" do
    t = described_class.from(
      manifest(entry("A", "x", forwards: { "to" => "p", "via" => "x" }),
               entry("B", "y", forwards: { "to" => "q", "via" => "y" }),
               entry("C", "z")),
      delegations: { "A" => { "x" => "p" }, "C" => { "z" => "r" } }
    )
    expect(t.stats).to include(total: 3, agreed: 1, bytecode: 1, static: 1, conflicts: 0)
  end
end
